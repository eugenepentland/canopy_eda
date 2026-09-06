//! CLI seam for `backfill-layouts`: run `serve/layout_backfill.zig` over one
//! block or over every design and module in the project, and print one JSON
//! result to stdout. Read-only over the archives it mines (`history/` and git);
//! the only file it writes is each block's own `.layouts.json`, and `--dry-run`
//! suppresses even that.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const exit = @import("../exit.zig");
const json_writer = @import("../json_writer.zig");
const mcp_tools = @import("mcp_tools.zig");
const modules = @import("modules.zig");
const layout_backfill = @import("layout_backfill.zig");

/// Most block names one invocation may name explicitly. Past this, run the
/// whole-project form (no names) instead of listing them out.
const max_named_blocks: usize = 64;

const usage =
    "Usage: netlisp backfill-layouts [--project-dir <d>] [<block>…] " ++
    "[--dry-run] [--limit <n>]\n";

/// Errors the command can propagate; everything user-facing goes through
/// `exit.fatal` instead.
pub const RunError = std.mem.Allocator.Error || std.Io.Writer.Error;

const Args = struct {
    project_dir: []const u8 = ".",
    /// Named blocks to process; empty means every design and module found.
    blocks: []const []const u8 = &.{},
    dry_run: bool = false,
    limit: usize = (layout_backfill.Options{}).limit,
};

/// One block's outcome, kept so the whole run can be reported in one object.
const Row = struct {
    name: []const u8,
    report: layout_backfill.Report,
};

/// Run `backfill-layouts` end to end (see module docs).
pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) RunError!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = parseArgs(argv);

    const blocks = if (args.blocks.len > 0) args.blocks else discoverBlocks(arena, args.project_dir);
    if (blocks.len == 0) exit.fatal(
        "backfill-layouts: no designs or modules found under {s}\n",
        .{args.project_dir},
    );

    var rows: std.ArrayList(Row) = .empty;
    for (blocks) |name| {
        const report = layout_backfill.backfill(arena, args.project_dir, name, .{
            .limit = args.limit,
            .dry_run = args.dry_run,
        });
        if (report.added > 0 or report.over_limit > 0) try rows.append(arena, .{ .name = name, .report = report });
    }
    try printResult(arena, args, blocks.len, rows.items);
}

/// Every block whose layouts could be backfilled: the project's designs plus
/// the `lib/modules` names, deduplicated (a module used by a design appears in
/// both listings). A block with no sidecar simply reports nothing.
fn discoverBlocks(arena: std.mem.Allocator, project_dir: []const u8) []const []const u8 {
    var seen = std.StringHashMapUnmanaged(void).empty;
    var out: std.ArrayList([]const u8) = .empty;
    const summaries = mcp_tools.listDesignSummaries(arena, project_dir) catch &[_]mcp_tools.DesignSummary{};
    for (summaries) |s| appendUnique(arena, &seen, &out, s.name);
    for (moduleNames(arena, project_dir)) |m| appendUnique(arena, &seen, &out, m.name);
    return out.items;
}

fn appendUnique(
    arena: std.mem.Allocator,
    seen: *std.StringHashMapUnmanaged(void),
    out: *std.ArrayList([]const u8),
    name: []const u8,
) void {
    if (name.len == 0 or seen.contains(name)) return;
    seen.put(arena, name, {}) catch return;
    out.append(arena, name) catch return;
}

/// Names of every reusable module, via the same cached collector the home page
/// uses. Empty when the project has no `lib/modules` — a legitimate shape.
fn moduleNames(arena: std.mem.Allocator, project_dir: []const u8) []const modules.ModuleEntry {
    return modules.collectModules(arena, project_dir) catch &.{};
}

/// Parse the argument vector, exiting with usage on anything malformed.
fn parseArgs(argv: []const []const u8) Args {
    var out = Args{};
    var buf: [max_named_blocks][]const u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--project-dir")) {
            out.project_dir = takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const v = takeValue(argv, &i, arg);
            out.limit = std.fmt.parseInt(usize, v, 10) catch
                exit.fatal("backfill-layouts: --limit expects a number, got \"{s}\"\n", .{v});
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            out.dry_run = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            exit.fatal("backfill-layouts: unknown flag \"{s}\"\n{s}", .{ arg, usage });
        } else if (n < buf.len) {
            buf[n] = arg;
            n += 1;
        }
    }
    out.blocks = buf[0..n];
    return out;
}

fn takeValue(argv: []const []const u8, i: *usize, flag: []const u8) []const u8 {
    if (i.* + 1 >= argv.len) exit.fatal("backfill-layouts: {s} needs a value\n{s}", .{ flag, usage });
    i.* += 1;
    return argv[i.*];
}

/// One JSON object on stdout: the totals plus a row per block that gained
/// layouts, so a run is machine-readable and diffable.
fn printResult(arena: std.mem.Allocator, args: Args, scanned: usize, rows: []const Row) RunError!void {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const w = &out.writer;
    var added: usize = 0;
    var over: usize = 0;
    var written: usize = 0;
    for (rows) |r| {
        added += r.report.added;
        over += r.report.over_limit;
        if (r.report.written) written += 1;
    }
    try w.print(
        "{{\"ok\":true,\"dry_run\":{s},\"limit\":{d},\"scanned\":{d}," ++
            "\"blocks_changed\":{d},\"layouts_added\":{d},\"over_limit\":{d},\"sidecars_written\":{d},\"blocks\":[",
        .{ if (args.dry_run) "true" else "false", args.limit, scanned, rows.len, added, over, written },
    );
    for (rows, 0..) |r, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try json_writer.writeString(w, r.name);
        try w.print(
            ",\"existing\":{d},\"added\":{d},\"from_history\":{d},\"from_git\":{d},\"over_limit\":{d},\"written\":{s}}}",
            .{
                r.report.existing, r.report.added,      r.report.from_history,
                r.report.from_git, r.report.over_limit, if (r.report.written) "true" else "false",
            },
        );
    }
    try w.writeAll("]}");

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(infra_fs.currentIo(), &stdout_buffer);
    try stdout_writer.interface.writeAll(out.written());
    try stdout_writer.interface.writeByte('\n');
    try stdout_writer.interface.flush();
}

// ── Tests ───────────────────────────────────────────────────────────────────

// spec: serve/layout-backfill - the argument parser reads the project dir, named blocks, dry-run flag, and limit
test "parseArgs reads the project dir, named blocks, dry-run flag and limit" {
    const args = parseArgs(&.{ "--project-dir", "projects/designs", "board-a", "board-d", "--dry-run", "--limit", "5" });
    try std.testing.expectEqualStrings("projects/designs", args.project_dir);
    try std.testing.expect(args.dry_run);
    try std.testing.expectEqual(@as(usize, 5), args.limit);
    try std.testing.expectEqual(@as(usize, 2), args.blocks.len);
    try std.testing.expectEqualStrings("board-a", args.blocks[0]);
    try std.testing.expectEqualStrings("board-d", args.blocks[1]);

    // Bare invocation: whole project, live run, default limit.
    const bare = parseArgs(&.{});
    try std.testing.expectEqualStrings(".", bare.project_dir);
    try std.testing.expect(!bare.dry_run);
    try std.testing.expectEqual(@as(usize, 0), bare.blocks.len);
    try std.testing.expectEqual((layout_backfill.Options{}).limit, bare.limit);
}
