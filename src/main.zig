const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const parser = @import("sexpr/parser.zig");
const printer = @import("sexpr/printer.zig");
const footprint_conv = @import("convert/footprint.zig");
const symbol_conv = @import("convert/symbol.zig");
const alt_functions = @import("convert/alt_functions.zig");
const serve_mod = @import("serve.zig");
const commands = @import("commands.zig");
const plugin_tokens = @import("serve/plugin_tokens.zig");
const auth = @import("serve/auth.zig");
const users = @import("serve/users.zig");
const passwords = @import("serve/passwords.zig");

// ── Constants ─────────────────────────────────────────────────────
const DEFAULT_SERVE_PORT: u16 = 7050;
const PARSE_PORT_RADIX: u8 = 10;
const FILTER_FLAG = "--filter";
const CONVERT_ERROR_FMT = "Convert error: {}\n";
const ERROR_READING_FMT = "Error reading {s}: {}\n";
const ALT_SOURCE_MAX_BYTES: usize = 20 * 1024 * 1024;

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
/// checkouts can share one passkey + session store. Returns `null` when the
/// env var is unset; the caller falls back to the `<project_dir>/auth`
/// default. Caller owns any returned slice (allocator-owned dupe).
fn readAuthDirEnv(allocator: std.mem.Allocator) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, "EDA_AUTH_DIR") catch null;
}

/// Resolve the auth directory from CLI args, env, or `<project_dir>/auth`.
/// Returns the same answer the long-running `serve` flow uses, so CLI helpers
/// (mint-invite, set-password) operate on the same files the server writes.
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
        try cmdConvertSymbol(allocator, args[2], optionalArg(args[3..], FILTER_FLAG));
    } else if (std.mem.eql(u8, command, "convert-package")) {
        if (args.len < 4) {
            std.debug.print("Usage: eda convert-package <file.kicad_sym> <file.kicad_mod> [--name <n>] [--filter <f>]\n", .{});
            std.process.exit(1);
        }
        const pkg_name = optionalArg(args[4..], "--name") orelse "package";
        const filter = optionalArg(args[4..], FILTER_FLAG);
        try cmdConvertPackage(allocator, args[2], args[3], pkg_name, filter);
    } else if (std.mem.eql(u8, command, "convert-pinout")) {
        if (args.len < 3) {
            std.debug.print("Usage: eda convert-pinout <file.kicad_sym> [--filter <name>]\n", .{});
            std.process.exit(1);
        }
        try cmdConvertPinout(allocator, args[2], optionalArg(args[3..], FILTER_FLAG));
    } else if (std.mem.eql(u8, command, "merge-alt-functions")) {
        if (args.len < 4) {
            std.debug.print("Usage: eda merge-alt-functions <pinout.sexp> <alts.csv|alts.xml> [--write]\n", .{});
            std.process.exit(1);
        }
        try cmdMergeAltFunctions(allocator, args[2], args[3], hasFlag(args[4..], "--write"));
    } else if (std.mem.eql(u8, command, "export-kicad")) {
        try commands.cmdExportKicad(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "export-review")) {
        try commands.cmdExportReview(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "serve")) {
        const project_dir = optionalArg(args[2..], "--project-dir") orelse ".";
        const port: u16 = if (optionalArg(args[2..], "--port")) |p|
            std.fmt.parseInt(u16, p, PARSE_PORT_RADIX) catch DEFAULT_SERVE_PORT
        else
            DEFAULT_SERVE_PORT;
        const auth_dir_override = optionalArg(args[2..], "--auth-dir") orelse readAuthDirEnv(allocator);
        try serve_mod.serve(allocator, port, project_dir, auth_dir_override);
    } else if (std.mem.eql(u8, command, "mint-plugin-token")) {
        const label = optionalArg(args[2..], "--label") orelse "plugin";
        const auth_dir = try resolveAuthDir(allocator, args[2..]);
        const raw = try plugin_tokens.mint(allocator, auth_dir, label);
        defer allocator.free(raw);
        const stdout = std.fs.File.stdout();
        try stdout.writeAll(raw);
        try stdout.writeAll("\n");
        try stdout.writeAll("Save this token — it will not be shown again.\n");
    } else if (std.mem.eql(u8, command, "mint-invite")) {
        try cmdMintInvite(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "set-password")) {
        try cmdSetPassword(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        try printUsage();
        std.process.exit(1);
    }
}

fn cmdParse(allocator: std.mem.Allocator, path: []const u8) !void {
    const source = infra_fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
        std.debug.print(ERROR_READING_FMT, .{ path, err });
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
    const source = infra_fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
        std.debug.print(ERROR_READING_FMT, .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    const output = footprint_conv.convertFootprint(allocator, source) catch |err| {
        std.debug.print(CONVERT_ERROR_FMT, .{err});
        std.process.exit(1);
    };
    defer allocator.free(output);

    const file = std.fs.File.stdout();
    try file.writeAll(output);
}

fn cmdConvertPackage(allocator: std.mem.Allocator, sym_path: []const u8, fp_path: []const u8, name: []const u8, filter: ?[]const u8) !void {
    const sym_source = infra_fs.cwd().readFileAlloc(allocator, sym_path, 10 * 1024 * 1024) catch |err| {
        std.debug.print(ERROR_READING_FMT, .{ sym_path, err });
        std.process.exit(1);
    };
    defer allocator.free(sym_source);
    const fp_source = infra_fs.cwd().readFileAlloc(allocator, fp_path, 10 * 1024 * 1024) catch |err| {
        std.debug.print(ERROR_READING_FMT, .{ fp_path, err });
        std.process.exit(1);
    };
    defer allocator.free(fp_source);

    const output = symbol_conv.generatePackage(allocator, sym_source, fp_source, name, filter) catch |err| {
        std.debug.print(CONVERT_ERROR_FMT, .{err});
        std.process.exit(1);
    };
    defer allocator.free(output);

    const file = std.fs.File.stdout();
    try file.writeAll(output);
}

fn cmdMergeAltFunctions(allocator: std.mem.Allocator, pinout_path: []const u8, src_path: []const u8, write_back: bool) !void {
    const pinout_src = infra_fs.cwd().readFileAlloc(allocator, pinout_path, 10 * 1024 * 1024) catch |err| {
        std.debug.print(ERROR_READING_FMT, .{ pinout_path, err });
        std.process.exit(1);
    };
    defer allocator.free(pinout_src);
    const alt_src = infra_fs.cwd().readFileAlloc(allocator, src_path, ALT_SOURCE_MAX_BYTES) catch |err| {
        std.debug.print(ERROR_READING_FMT, .{ src_path, err });
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
        std.debug.print(ERROR_READING_FMT, .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    const output = symbol_conv.generatePinout(allocator, source, filter) catch |err| {
        std.debug.print(CONVERT_ERROR_FMT, .{err});
        std.process.exit(1);
    };
    defer allocator.free(output);

    const file = std.fs.File.stdout();
    try file.writeAll(output);
}

fn cmdConvertSymbol(allocator: std.mem.Allocator, path: []const u8, filter: ?[]const u8) !void {
    const source = infra_fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
        std.debug.print(ERROR_READING_FMT, .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    const output = symbol_conv.convertSymbol(allocator, source, filter) catch |err| {
        std.debug.print(CONVERT_ERROR_FMT, .{err});
        std.process.exit(1);
    };
    defer allocator.free(output);

    const file = std.fs.File.stdout();
    try file.writeAll(output);
}

fn cmdMintInvite(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    const role = optionalArg(args, "--role") orelse "writer";
    const created_by = optionalArg(args, "--created-by") orelse "cli";
    const auth_dir = try resolveAuthDir(allocator, args);

    if (users.Role.fromString(role) == null) {
        std.debug.print("Invalid --role {s}. Use: admin, writer, reader.\n", .{role});
        std.process.exit(1);
    }

    const token = auth.createInvite(allocator, auth_dir, created_by, role) catch |e| {
        std.debug.print("Failed to mint invite: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    defer allocator.free(token);

    const stdout = std.fs.File.stdout();
    try stdout.writeAll("Invite path: /auth/invite/");
    try stdout.writeAll(token);
    try stdout.writeAll("\n");
    try stdout.writeAll("Token: ");
    try stdout.writeAll(token);
    try stdout.writeAll("\n");
    try stdout.writeAll("Role: ");
    try stdout.writeAll(role);
    try stdout.writeAll("\nValid for 7 days, single-use. Prepend your server's origin to form the full URL.\n");
}

fn cmdSetPassword(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    const auth_dir = try resolveAuthDir(allocator, args);

    const email = optionalArg(args, "--email") orelse {
        std.debug.print("Usage: eda set-password --email <addr> --password <pw> [--role admin] [--auth-dir <d>]\n", .{});
        std.process.exit(1);
    };
    const password = optionalArg(args, "--password") orelse {
        std.debug.print("Usage: eda set-password --email <addr> --password <pw> [--role admin] [--auth-dir <d>]\n", .{});
        std.process.exit(1);
    };
    const role_str = optionalArg(args, "--role") orelse "writer";
    const role = users.Role.fromString(role_str) orelse {
        std.debug.print("Invalid --role {s}. Use: admin, writer, reader.\n", .{role_str});
        std.process.exit(1);
    };

    passwords.set(allocator, auth_dir, email, password) catch |e| switch (e) {
        error.PasswordTooShort => {
            std.debug.print("Password must be at least 8 characters.\n", .{});
            std.process.exit(1);
        },
        else => {
            std.debug.print("Failed to set password: {s}\n", .{@errorName(e)});
            std.process.exit(1);
        },
    };

    _ = users.ensureUser(allocator, auth_dir, email, role) catch |e| {
        std.debug.print("Warning: ensureUser failed: {s}\n", .{@errorName(e)});
    };

    const stdout = std.fs.File.stdout();
    try stdout.writeAll("Password set for ");
    try stdout.writeAll(email);
    try stdout.writeAll(" (role ");
    try stdout.writeAll(role.toString());
    try stdout.writeAll("). Sign in via /auth/login → \"Use password instead\".\n");
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
        \\  eda mint-invite [--project-dir <d>] [--role <r>] [--auth-dir <d>]  Mint a single-use invite (7-day TTL)
        \\  eda set-password --email <a> --password <p> [--role <r>] [--auth-dir <d>]  Set or reset a user's password
        \\  eda export-kicad --project-dir <d> --output-dir <out> <name>  Export KiCad netlist + footprints
        \\  eda export-review --project-dir <d> [--output-dir <out>] [--zip] <name>  Export design-review package (markdown + BOM CSV)
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
    _ = @import("eval/rails.zig");
    _ = @import("eval/test_point.zig");
    _ = @import("eval/power_config.zig");
    _ = @import("eval/electrical.zig");
    _ = @import("eval/power_budget.zig");
    _ = @import("eval/power_sequencing.zig");
    _ = @import("erc.zig");
    _ = @import("emit.zig");
    _ = @import("convert/footprint.zig");
    _ = @import("convert/symbol.zig");
    _ = @import("convert/alt_functions.zig");
    _ = @import("export_kicad.zig");
    _ = @import("serve.zig");
    _ = @import("render_json.zig");
    _ = @import("json_writer.zig");
    _ = @import("checks.zig");
}
