//! Human-friendly package commands over the same structured operation service.
const std = @import("std");
const fs = @import("infra/fs.zig");
const exit = @import("exit.zig");
const atomic = @import("infra/atomic_write.zig");
const service = @import("serve/package_tools.zig");
const autocommit = @import("serve/autocommit.zig");

/// Invoke package templates/init/show/preview/check/save/export with ordinary CLI flags.
pub fn run(a: std.mem.Allocator, args: []const []const u8) (service.Error || std.Io.File.Writer.Error)!void {
    if (args.len == 0) exit.fatal("Usage: netlisp package templates|init|show|preview|check|save|export [recipe-or-name] [--family qfn|dfn|soic|tssop|qfp] [--project-dir DIR] [--output FILE] [--output-dir DIR] [--format step|kicad]\n", .{});
    const operation = if (std.mem.eql(u8, args[0], "export")) service.Operation.export_asset else std.meta.stringToEnum(service.Operation, args[0]) orelse exit.fatal("Unknown package command: {s}\n", .{args[0]});
    var project: []const u8 = ".";
    var output: ?[]const u8 = null;
    var output_dir: ?[]const u8 = null;
    var positional: ?[]const u8 = null;
    var input = std.json.Value{ .object = .empty };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!std.mem.startsWith(u8, arg, "--")) {
            if (positional != null) exit.fatal("Unexpected argument: {s}\n", .{arg});
            positional = arg;
            continue;
        }
        if (i + 1 >= args.len) exit.fatal("Missing value for {s}\n", .{arg});
        i += 1;
        const v = args[i];
        if (std.mem.eql(u8, arg, "--project-dir")) project = v else if (std.mem.eql(u8, arg, "--output")) output = v else if (std.mem.eql(u8, arg, "--output-dir")) output_dir = v else if (std.mem.eql(u8, arg, "--family") or std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "--name") or std.mem.eql(u8, arg, "--component")) try input.object.put(a, arg[2..], .{ .string = v }) else exit.fatal("Unknown option: {s}\n", .{arg});
    }
    switch (operation) {
        .check, .preview, .save => {
            const filename = positional orelse exit.fatal("A recipe filename is required\n", .{});
            const bytes = try fs.cwd().readFileAlloc(a, filename, 256 * 1024);
            try input.object.put(a, "recipe", try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}));
        },
        .show, .export_asset => try input.object.put(a, "name", .{ .string = positional orelse exit.fatal("A package name is required\n", .{}) }),
        else => {},
    }
    var session = if (operation == .save) autocommit.begin(a, project) else null;
    defer if (session) |*s| s.deinit();
    const bytes = service.execute(a, project, operation, input) catch |err| exit.fatal("package: {s}\n", .{service.message(err)});
    const result = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    const ok = if (result.object.get("ok")) |v| v == .bool and v.bool else true;
    if (ok and operation == .save) autocommit.commit(session, null, "package_save");
    var rendered = bytes;
    if (ok and operation == .preview) {
        const dir = output_dir orelse exit.fatal("preview requires --output-dir DIR\n", .{});
        try fs.cwd().makePath(dir);
        const svg_path = try std.fs.path.join(a, &.{ dir, "footprint.svg" });
        const step_path = try std.fs.path.join(a, &.{ dir, "model.step" });
        try atomic.writeFile(svg_path, result.object.get("svg").?.string);
        try atomic.writeFile(step_path, result.object.get("step").?.string);
        rendered = try std.json.Stringify.valueAlloc(a, .{ .ok = true, .svg = svg_path, .step = step_path, .diagnostics = result.object.get("diagnostics").? }, .{});
    }
    if (ok and operation == .export_asset) rendered = result.object.get("content").?.string;
    if (output) |path| {
        if (std.mem.eql(u8, path, "-")) try fsFile(rendered) else try atomic.writeFile(path, rendered);
    } else try fsFile(rendered);
    if (!ok) exit.failure();
}
fn fsFile(bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(fs.currentIo(), bytes);
    try std.Io.File.stdout().writeStreamingAll(fs.currentIo(), "\n");
}
