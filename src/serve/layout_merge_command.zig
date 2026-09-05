//! Semantic named-layout transfer for monolithic `.layouts.json` sidecars.
//!
//! Git cannot merge two independent rows in the same generated JSON document
//! reliably.  This command reads one named row from a source sidecar and
//! upserts it through the same protected write path as the editor/CLI tools,
//! preserving every unrelated target layout, its cache, its current star, and
//! the revision/history safeguards.

const std = @import("std");
const exit = @import("../exit.zig");
const infra_fs = @import("../infra/fs.zig");
const json_writer = @import("../json_writer.zig");
const paths = @import("../paths.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");

const usage =
    "Usage: netlisp merge-layout [--project-dir <d>] <design> " ++
    "--from <source.layouts.json> --layout <name> [--star] [--dry-run]\n";
/// The sidecar read ceiling, taken from the authority every other reader uses.
/// This stood at 256 MiB, sixteen times the cap the viewer, the KiCad-sync seed
/// and the fab outputs read a `.layouts.json` with — so a source between the two
/// merged cleanly here and then read back as ZERO saved layouts everywhere else,
/// which is the exact silent strip `sidecar_max_bytes` exists to refuse loudly.
const max_sidecar_bytes: usize = pcb_layout_page.sidecar_max_bytes;

const RunError = std.mem.Allocator.Error || std.Io.Writer.Error;

const Args = struct {
    project_dir: []const u8 = ".",
    design: []const u8 = "",
    source: []const u8 = "",
    layout: []const u8 = "",
    star: bool = false,
    dry_run: bool = false,
};

const Delta = struct { before: i64, after: i64 };

const Report = struct {
    design: []const u8,
    layout: []const u8,
    source: []const u8,
    replaced: bool,
    starred: bool,
    dry_run: bool,
    layouts: Delta,
    rev: Delta,
};

/// Run the `merge-layout` CLI command and emit its semantic upsert report.
pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) RunError!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = parseArgs(argv);
    const report = merge(arena, args) catch |err| switch (err) {
        error.SourceTooBig => exit.fatal("merge-layout: source sidecar is too large: {s}\n", .{args.source}),
        error.SourceUnreadable => exit.fatal("merge-layout: cannot read source sidecar: {s}\n", .{args.source}),
        error.InvalidSource => exit.fatal("merge-layout: source is not a valid .layouts.json file: {s}\n", .{args.source}),
        error.LayoutNotFound => exit.fatal("merge-layout: layout \"{s}\" was not found in {s}\n", .{ args.layout, args.source }),
        error.TargetNotFound => exit.fatal("merge-layout: target design or module does not exist: {s}\n", .{args.design}),
        error.WriteFailed => exit.fatal("merge-layout: target sidecar did not retain layout \"{s}\"\n", .{args.layout}),
        error.CannotReadSidecar, error.InvalidSidecar, error.CannotWriteSidecar => exit.fatal("merge-layout: persistence failed: {s}\n", .{@errorName(err)}),
        error.OutOfMemory => return error.OutOfMemory,
    };
    try printReport(arena, report);
}

const MergeError = @import("../layout_sidecar_store.zig").StoreError || std.mem.Allocator.Error || error{
    SourceTooBig,
    SourceUnreadable,
    InvalidSource,
    LayoutNotFound,
    TargetNotFound,
    WriteFailed,
};

fn merge(alloc: std.mem.Allocator, args: Args) MergeError!Report {
    const target = paths.designSourcePath(alloc, args.project_dir, args.design) catch return error.TargetNotFound;
    infra_fs.cwd().access(target, .{}) catch return error.TargetNotFound;
    const data = infra_fs.cwd().readFileAlloc(alloc, args.source, max_sidecar_bytes) catch |err| switch (err) {
        error.FileTooBig => return error.SourceTooBig,
        else => return error.SourceUnreadable,
    };
    const source_layouts = pcb_layout_page.parseLayouts(alloc, data) orelse return error.InvalidSource;
    var picked: ?pcb_layout_page.SavedLayout = null;
    for (source_layouts) |layout| {
        if (std.mem.eql(u8, layout.name, args.layout)) {
            picked = layout;
            break;
        }
    }
    var entry = picked orelse return error.LayoutNotFound;

    const before = pcb_layout_page.readLayouts(alloc, args.project_dir, args.design);
    const rev_before = pcb_layout_page.readLayoutRev(alloc, args.project_dir, args.design, null);
    var replaced = false;
    var target_was_starred = false;
    for (before) |layout| {
        if (std.mem.eql(u8, layout.name, entry.name)) {
            replaced = true;
            target_was_starred = layout.default;
            break;
        }
    }

    // A source's star belongs to the source project.  The target keeps its own
    // default unless --star explicitly transfers that decision too.
    entry.default = false;
    if (!args.dry_run) try pcb_layout_page.mcpPersistWorking(alloc, args.project_dir, args.design, entry, args.star);

    const after = if (args.dry_run) before else pcb_layout_page.readLayouts(alloc, args.project_dir, args.design);
    const rev_after = if (args.dry_run) rev_before else pcb_layout_page.readLayoutRev(alloc, args.project_dir, args.design, null);
    var retained = args.dry_run;
    var starred = false;
    for (after) |layout| {
        if (std.mem.eql(u8, layout.name, entry.name)) {
            retained = true;
            starred = layout.default;
        }
    }
    if (!retained) return error.WriteFailed;
    if (!args.dry_run and rev_after <= rev_before) return error.WriteFailed;
    var predicted_star = args.star or target_was_starred;
    if (!replaced and before.len == 0) predicted_star = true;
    return .{
        .design = args.design,
        .layout = entry.name,
        .source = args.source,
        .replaced = replaced,
        .starred = if (args.dry_run) predicted_star else starred,
        .dry_run = args.dry_run,
        .layouts = .{
            .before = @intCast(before.len),
            .after = @intCast(if (args.dry_run and !replaced) before.len + 1 else after.len),
        },
        .rev = .{
            .before = rev_before,
            .after = rev_after,
        },
    };
}

fn parseArgs(argv: []const []const u8) Args {
    var out = Args{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--project-dir")) {
            out.project_dir = takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--from")) {
            out.source = takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--layout")) {
            out.layout = takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--star")) {
            out.star = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            out.dry_run = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            exit.fatal("merge-layout: unknown flag \"{s}\"\n{s}", .{ arg, usage });
        } else if (out.design.len == 0) {
            out.design = arg;
        } else {
            exit.fatal("merge-layout: unexpected argument \"{s}\"\n{s}", .{ arg, usage });
        }
    }
    if (out.design.len == 0 or out.source.len == 0 or out.layout.len == 0)
        exit.fatal("merge-layout: design, --from, and --layout are required\n{s}", .{usage});
    return out;
}

fn takeValue(argv: []const []const u8, i: *usize, flag: []const u8) []const u8 {
    if (i.* + 1 >= argv.len) exit.fatal("merge-layout: {s} needs a value\n{s}", .{ flag, usage });
    i.* += 1;
    return argv[i.*];
}

fn printReport(alloc: std.mem.Allocator, report: Report) RunError!void {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"ok\":true,\"design\":");
    try json_writer.writeString(w, report.design);
    try w.writeAll(",\"layout\":");
    try json_writer.writeString(w, report.layout);
    try w.writeAll(",\"source\":");
    try json_writer.writeString(w, report.source);
    try w.print(
        ",\"replaced\":{s},\"starred\":{s},\"dry_run\":{s},\"layouts_before\":{d},\"layouts_after\":{d},\"rev_before\":{d},\"rev_after\":{d}}}",
        .{
            if (report.replaced) "true" else "false",
            if (report.starred) "true" else "false",
            if (report.dry_run) "true" else "false",
            report.layouts.before,
            report.layouts.after,
            report.rev.before,
            report.rev.after,
        },
    );
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(infra_fs.currentIo(), &buf);
    try stdout.interface.writeAll(out.written());
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}

// spec: serve/layout-merge - the argument parser reads project, source, layout, star and dry-run flags
test "parseArgs reads semantic layout transfer flags" {
    const args = parseArgs(&.{ "--project-dir", "/p", "board-a", "--from", "/tmp/source.layouts.json", "--layout", "final", "--star", "--dry-run" });
    try std.testing.expectEqualStrings("/p", args.project_dir);
    try std.testing.expectEqualStrings("board-a", args.design);
    try std.testing.expectEqualStrings("/tmp/source.layouts.json", args.source);
    try std.testing.expectEqualStrings("final", args.layout);
    try std.testing.expect(args.star and args.dry_run);
}

// spec: serve/layout-merge - an upsert replaces only its named row and preserves the target star
test "merge upserts one row and preserves unrelated layouts and target star" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.sexp", .data = "(design-block \"demo\")" });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/demo.layouts.json",
        .data = "{\"rev\":7,\"default\":\"kept\",\"layouts\":[" ++
            "{\"name\":\"kept\",\"kind\":\"manual\",\"ts\":1,\"parts\":[]}," ++
            "{\"name\":\"replace\",\"kind\":\"manual\",\"ts\":2,\"parts\":[]}]}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "source.layouts.json",
        .data = "{\"rev\":99,\"default\":\"replace\",\"layouts\":[" ++
            "{\"name\":\"replace\",\"kind\":\"manual\",\"ts\":3,\"parts\":[]," ++
            "\"routes\":{\"tracks\":[{\"x1\":1,\"y1\":2,\"x2\":3,\"y2\":4,\"w\":0.2,\"net\":\"N\"}],\"vias\":[]}}]}",
    });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const source = try std.fs.path.join(std.testing.allocator, &.{ root, "source.layouts.json" });
    defer std.testing.allocator.free(source);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const report = try merge(arena, .{ .project_dir = root, .design = "demo", .source = source, .layout = "replace" });
    try std.testing.expect(report.replaced);
    try std.testing.expectEqual(@as(i64, 2), report.layouts.after);
    try std.testing.expectEqual(@as(i64, 8), report.rev.after);
    const layouts = pcb_layout_page.readLayouts(arena, root, "demo");
    try std.testing.expectEqual(@as(usize, 2), layouts.len);
    var saw_kept = false;
    var saw_replacement = false;
    for (layouts) |layout| {
        if (std.mem.eql(u8, layout.name, "kept")) saw_kept = layout.default;
        if (std.mem.eql(u8, layout.name, "replace")) {
            saw_replacement = !layout.default and layout.routes != null and layout.routes.?.tracks.len == 1;
        }
    }
    try std.testing.expect(saw_kept);
    try std.testing.expect(saw_replacement);
}

// spec: serve/layout-merge - a dry run predicts its insert and leaves the target sidecar unchanged
test "merge dry run predicts an insert without writing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.sexp", .data = "(design-block \"demo\")" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.layouts.json", .data = "{\"rev\":4,\"layouts\":[]}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.layouts.json", .data = "{\"layouts\":[{\"name\":\"candidate\",\"kind\":\"manual\",\"ts\":1,\"parts\":[]}] }" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const source = try std.fs.path.join(std.testing.allocator, &.{ root, "source.layouts.json" });
    defer std.testing.allocator.free(source);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const report = try merge(arena, .{ .project_dir = root, .design = "demo", .source = source, .layout = "candidate", .dry_run = true });
    try std.testing.expectEqual(@as(i64, 1), report.layouts.after);
    try std.testing.expectEqual(@as(i64, 4), report.rev.after);
    try std.testing.expect(report.starred);
    try std.testing.expectEqual(@as(usize, 0), pcb_layout_page.readLayouts(arena, root, "demo").len);
}

// spec: serve/layout-merge - a missing target design is refused before any sidecar can be created
test "merge refuses a missing target design" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.layouts.json", .data = "{\"layouts\":[{\"name\":\"candidate\",\"kind\":\"manual\",\"ts\":1,\"parts\":[]}] }" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const source = try std.fs.path.join(std.testing.allocator, &.{ root, "source.layouts.json" });
    defer std.testing.allocator.free(source);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.TargetNotFound, merge(arena_state.allocator(), .{
        .project_dir = root,
        .design = "missing",
        .source = source,
        .layout = "candidate",
    }));
}
