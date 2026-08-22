//! Complete command-line entry point for the structured EDA tool surface.
//!
//! `netlisp tool list` prints the machine-readable catalog. A tool is invoked
//! with `netlisp tool <name> --args '<json object>'`; `--args-file` avoids shell
//! quoting for larger payloads. Text results go to stdout. Image results are
//! represented as `{mime_type,base64}` JSON unless `--output` is supplied, in
//! which case the decoded bytes are written to that path (or to stdout for
//! `--output -`).

const std = @import("std");
const exit = @import("exit.zig");
const infra_fs = @import("infra/fs.zig");
const tool_dispatch = @import("serve/mcp_tools.zig");
const autocommit = @import("serve/autocommit.zig");

const max_args_file_bytes: usize = 16 * 1024 * 1024;

const RunError = std.mem.Allocator.Error ||
    infra_fs.File.WriteError ||
    std.Io.Dir.WriteFileError ||
    std.base64.Error;

const Invocation = struct {
    name: []const u8,
    project_dir: []const u8 = ".",
    args_json: []const u8 = "{}",
    args_file: ?[]const u8 = null,
    output: ?[]const u8 = null,
};

fn usage() noreturn {
    exit.fatal(
        "Usage: netlisp tool list | netlisp tool <name> [--project-dir <d>] [--args <json> | --args-file <path>] [--output <path|->]\n",
        .{},
    );
}

fn parseInvocation(args: []const []const u8) !Invocation {
    if (args.len == 0) return error.MissingToolName;
    var inv = Invocation{ .name = args[0] };
    var saw_args = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        if (i + 1 >= args.len) return error.MissingFlagValue;
        const value = args[i + 1];
        if (std.mem.eql(u8, flag, "--project-dir")) {
            inv.project_dir = value;
        } else if (std.mem.eql(u8, flag, "--args")) {
            if (saw_args) return error.DuplicateArguments;
            saw_args = true;
            inv.args_json = value;
        } else if (std.mem.eql(u8, flag, "--args-file")) {
            if (saw_args) return error.DuplicateArguments;
            saw_args = true;
            inv.args_file = value;
        } else if (std.mem.eql(u8, flag, "--output")) {
            inv.output = value;
        } else {
            return error.UnknownFlag;
        }
        i += 1;
    }
    return inv;
}

fn writeStdout(bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(infra_fs.currentIo(), bytes);
}

fn writeOutput(path: []const u8, bytes: []const u8) !void {
    if (std.mem.eql(u8, path, "-")) return writeStdout(bytes);
    try infra_fs.cwd().writeFile(.{ .sub_path = path, .data = bytes });
}

fn emitText(inv: Invocation, bytes: []const u8) !void {
    if (inv.output) |path| {
        try writeOutput(path, bytes);
        return;
    }
    try writeStdout(bytes);
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') try writeStdout("\n");
}

fn emitImage(allocator: std.mem.Allocator, inv: Invocation, mime: []const u8, base64: []const u8) !void {
    if (inv.output) |path| {
        const decoder = std.base64.standard.Decoder;
        const decoded = try allocator.alloc(u8, try decoder.calcSizeForSlice(base64));
        try decoder.decode(decoded, base64);
        try writeOutput(path, decoded);
        return;
    }
    try writeStdout("{\"mime_type\":\"");
    try writeStdout(mime);
    try writeStdout("\",\"base64\":\"");
    try writeStdout(base64);
    try writeStdout("\"}\n");
}

/// Run the structured tool CLI. The local process already has the invoking
/// user's filesystem authority, so no network role check is involved.
pub fn run(allocator: std.mem.Allocator, args: []const []const u8) RunError!void {
    if (args.len == 0) usage();
    if (std.mem.eql(u8, args[0], "list")) {
        if (args.len != 1) usage();
        try emitText(.{ .name = "list" }, tool_dispatch.tools_list_result);
        return;
    }

    const inv = parseInvocation(args) catch usage();
    if (!tool_dispatch.isKnownTool(inv.name)) {
        exit.fatal("tool: unknown tool '{s}'; run `netlisp tool list` for the catalog\n", .{inv.name});
    }

    const args_json = if (inv.args_file) |path|
        infra_fs.cwd().readFileAlloc(allocator, path, max_args_file_bytes) catch |err|
            exit.fatal("tool: cannot read arguments file {s}: {s}\n", .{ path, @errorName(err) })
    else
        inv.args_json;
    const args_value = std.json.parseFromSliceLeaky(std.json.Value, allocator, args_json, .{}) catch |err|
        exit.fatal("tool: arguments must be valid JSON: {s}\n", .{@errorName(err)});
    if (args_value != .object) exit.fatal("tool: arguments must be a JSON object\n", .{});

    const is_mutation = tool_dispatch.isMutationTool(inv.name);
    var ac_session = if (is_mutation) autocommit.begin(allocator, inv.project_dir) else null;
    defer if (ac_session) |*session| session.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const result = tool_dispatch.call(allocator, inv.project_dir, inv.name, args_value, &out);
    if (is_mutation and result.ok) autocommit.commit(ac_session, null, inv.name);

    if (result.image_mime) |mime|
        try emitImage(allocator, inv, mime, out.items)
    else
        try emitText(inv, out.items);
    if (!result.ok) exit.failure();
}

// spec: tool_cli - A structured tool invocation accepts one JSON source and the common project and output flags
test "tool invocation accepts one JSON source and the common output flags" {
    const inv = try parseInvocation(&.{
        "run_checks",
        "--project-dir",
        "demo",
        "--args-file",
        "request.json",
        "--output",
        "result.json",
    });
    try std.testing.expectEqualStrings("run_checks", inv.name);
    try std.testing.expectEqualStrings("demo", inv.project_dir);
    try std.testing.expectEqualStrings("request.json", inv.args_file.?);
    try std.testing.expectEqualStrings("result.json", inv.output.?);
    try std.testing.expectError(error.DuplicateArguments, parseInvocation(&.{ "build", "--args", "{}", "--args-file", "a.json" }));
    try std.testing.expectError(error.UnknownFlag, parseInvocation(&.{ "build", "--wat", "x" }));
}
