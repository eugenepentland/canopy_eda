//! `export_kicad_sch` CLI tool — the agent-facing twin of `netlisp
//! export-kicad-sch` and `GET /api/kicad-sch/:name`.
//!
//! Two shapes, chosen by whether the caller names an `output_dir`:
//!
//!  * **Without one** it is a read: the export runs, self-checks, and reports
//!    a compact summary — the file list with byte counts, the sheet/component
//!    /vendor-body tallies. It deliberately does not return file *content*: a
//!    real board is a megabyte of s-expressions across twenty sheets, which is
//!    a context budget spent on bytes no agent reads.
//!  * **With one** it writes the sheets and their project sidecars into that
//!    directory, which is the point of the tool: an agent hands a KiCad user a
//!    directory to open.
//!
//! `output_dir` is the only path in the CLI surface that writes outside the
//! project tree, so it is fenced deliberately (`validateOutputDir`): absolute
//! only, no `..` segment, no NUL, and **refused when it points inside the
//! project directory**. That last rule is the important one — this is an
//! export, not a design edit. The project repo's auto-commit seam watches for
//! files that became dirty during a mutation, and an export dropping twenty
//! `.kicad_sch` files into `projects/designs` would be committed as if the
//! agent had authored them. Writing outside the project dir leaves that seam
//! with nothing to see, which is exactly right.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const export_kicad_sch = @import("../export_kicad_sch.zig");
const kicad_sch_export = @import("kicad_sch_export.zig");

/// Errors the handler can surface: allocation, the JSON writer's, and every
/// way the export itself can fail.
pub const KicadSchToolError = kicad_sch_export.ExportZipError;

/// Longest `output_dir` accepted, matching the VFS path cap.
const max_path_bytes: usize = 1024;

/// Why an `output_dir` was refused. Each maps to one sentence in the error
/// result, so a caller learns the rule rather than just "denied".
const DirDenial = enum {
    empty,
    too_long,
    not_absolute,
    parent_traversal,
    invalid_byte,
    inside_project,

    fn reason(self: DirDenial) []const u8 {
        return switch (self) {
            .empty => "output_dir must not be empty",
            .too_long => "output_dir is too long",
            .not_absolute => "output_dir must be an absolute path",
            .parent_traversal => "output_dir must not contain a '..' segment",
            .invalid_byte => "output_dir must not contain NUL or a backslash",
            .inside_project => "output_dir must be outside the project directory " ++
                "(this is an export, not a design edit — write it somewhere else and copy it in)",
        };
    }
};

/// Fence an agent-supplied export directory. Absolute, traversal-free, and
/// outside the project tree; see the module header for why the last rule is
/// not negotiable.
pub fn validateOutputDir(dir: []const u8, project_dir: []const u8) ?DirDenial {
    if (dir.len == 0) return .empty;
    if (dir.len > max_path_bytes) return .too_long;
    if (!std.fs.path.isAbsolute(dir)) return .not_absolute;
    if (std.mem.indexOfScalar(u8, dir, 0) != null) return .invalid_byte;
    if (std.mem.indexOfScalar(u8, dir, '\\') != null) return .invalid_byte;
    var it = std.mem.splitScalar(u8, dir, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return .parent_traversal;
    }
    if (underPath(dir, project_dir)) return .inside_project;
    return null;
}

/// True when `dir` is `root` or sits beneath it, comparing whole path
/// segments so `/p/designs-scratch` is not read as being inside `/p/designs`.
fn underPath(dir: []const u8, root: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, root, "/");
    if (trimmed.len == 0) return false;
    if (!std.mem.startsWith(u8, dir, trimmed)) return false;
    return dir.len == trimmed.len or dir[trimmed.len] == '/';
}

/// `export_kicad_sch` — export `name`'s KiCad schematic, optionally writing it
/// to `output_dir`. Returns false (with a plain-text reason in `out`) on a
/// rejected argument or a failed export, matching the other tools' convention.
pub fn mcpExportKicadSch(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) KicadSchToolError!bool {
    const name = argStr(args_val, "name") orelse {
        try out.appendSlice(alloc, "missing required arg: name");
        return false;
    };
    const output_dir = argStr(args_val, "output_dir");
    if (output_dir) |dir| {
        if (validateOutputDir(dir, project_dir)) |denial| {
            const msg = try std.fmt.allocPrint(alloc, "error: {s}", .{denial.reason()});
            defer alloc.free(msg);
            try out.appendSlice(alloc, msg);
            return false;
        }
    }

    const opts = export_kicad_sch.Options{
        .flat = argBool(args_val, "flat") orelse false,
        .vendor = argBool(args_val, "vendor") orelse true,
    };
    // No `deps`: the CLI writes the export to disk once and has no store to
    // retain it in, so capturing a read-set would be pure cost.
    const result = kicad_sch_export.exportFor(alloc, project_dir, name, opts, null) catch |e| {
        const msg = try std.fmt.allocPrint(alloc, "error: export failed: {s}", .{@errorName(e)});
        defer alloc.free(msg);
        try out.appendSlice(alloc, msg);
        return false;
    };
    defer result.deinit(alloc);

    if (output_dir) |dir| {
        writeInto(alloc, result, dir) catch |e| {
            const msg = try std.fmt.allocPrint(alloc, "error: writing {s} failed: {s}", .{ dir, @errorName(e) });
            defer alloc.free(msg);
            try out.appendSlice(alloc, msg);
            return false;
        };
    }

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try writeSummary(&aw.writer, name, result, output_dir);
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// Write every sheet and sidecar into `dir` under its bare name, which is what
/// the root's `Sheetfile` links point at. A sidecar that already exists is
/// kept: re-exporting into a KiCad project directory must not clobber the
/// `.kicad_pro` a user has since edited.
fn writeInto(
    alloc: std.mem.Allocator,
    result: export_kicad_sch.Output,
    dir: []const u8,
) !void {
    try infra_fs.cwd().makePath(dir);
    for (result.files) |f| {
        const path = try std.fs.path.join(alloc, &.{ dir, f.name });
        defer alloc.free(path);
        try infra_fs.cwd().writeFile(.{ .sub_path = path, .data = f.bytes });
    }
    for (result.sidecars) |f| {
        const path = try std.fs.path.join(alloc, &.{ dir, f.name });
        defer alloc.free(path);
        if (infra_fs.cwd().access(path, .{})) |_| continue else |_| {}
        try infra_fs.cwd().writeFile(.{ .sub_path = path, .data = f.bytes });
    }
}

/// `{ok, name, sheets, components, vendor_bodies, instances, bytes_total,
/// files:[{name,bytes}], sidecars:[{name,bytes}], output_dir?}` — names and
/// sizes, never content.
fn writeSummary(
    w: *std.Io.Writer,
    name: []const u8,
    result: export_kicad_sch.Output,
    output_dir: ?[]const u8,
) std.Io.Writer.Error!void {
    try w.writeAll("{\"ok\":true,\"name\":");
    try pcb_layout_page.writeJsonStr(w, name);
    try w.print(",\"sheets\":{d},\"components\":{d},\"vendor_bodies\":{d},\"instances\":{d}", .{
        result.files.len,
        result.stats.components,
        result.stats.vendor_bodies,
        result.stats.instances,
    });
    try w.print(",\"bytes_total\":{d},\"files\":", .{totalBytes(result)});
    try writeFileList(w, result.files);
    try w.writeAll(",\"sidecars\":");
    try writeFileList(w, result.sidecars);
    if (output_dir) |dir| {
        try w.writeAll(",\"output_dir\":");
        try pcb_layout_page.writeJsonStr(w, dir);
        try w.writeAll(",\"written\":true");
    } else {
        try w.writeAll(",\"written\":false");
    }
    try w.writeByte('}');
}

fn writeFileList(w: *std.Io.Writer, files: []const export_kicad_sch.SchFile) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (files, 0..) |f, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try pcb_layout_page.writeJsonStr(w, f.name);
        try w.print(",\"bytes\":{d}}}", .{f.bytes.len});
    }
    try w.writeByte(']');
}

fn totalBytes(result: export_kicad_sch.Output) usize {
    var n: usize = 0;
    for (result.files) |f| n += f.bytes.len;
    for (result.sidecars) |f| n += f.bytes.len;
    return n;
}

fn argStr(args_val: ?std.json.Value, key: []const u8) ?[]const u8 {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn argBool(args_val: ?std.json.Value, key: []const u8) ?bool {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return if (v == .bool) v.bool else null;
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Web Server - The export_kicad_sch tool refuses an output_dir that is relative, escapes through '..', or points inside the project directory
test "export_kicad_sch fences its output_dir" {
    const proj = "/srv/netlisp/projects/designs";
    // The rule that matters: an export must not land in the design repo, where
    // the auto-commit seam would take it for authored work.
    try testing.expectEqual(DirDenial.inside_project, validateOutputDir(proj, proj).?);
    try testing.expectEqual(DirDenial.inside_project, validateOutputDir(proj ++ "/out", proj).?);
    try testing.expectEqual(DirDenial.inside_project, validateOutputDir(proj ++ "/", proj).?);
    // Traversal, relative paths and junk bytes are refused before that.
    try testing.expectEqual(DirDenial.not_absolute, validateOutputDir("out/kicad", proj).?);
    try testing.expectEqual(DirDenial.parent_traversal, validateOutputDir("/tmp/../etc", proj).?);
    try testing.expectEqual(DirDenial.invalid_byte, validateOutputDir("/tmp/a\\b", proj).?);
    try testing.expectEqual(DirDenial.empty, validateOutputDir("", proj).?);
    // A sibling whose name merely starts with the project path is fine — the
    // comparison is by whole path segment.
    try testing.expect(validateOutputDir("/srv/netlisp/projects/designs-export", proj) == null);
    try testing.expect(validateOutputDir("/tmp/kicad-out", proj) == null);
    // Every denial explains the rule rather than just refusing.
    try testing.expect(DirDenial.inside_project.reason().len > 0);
}

// spec: Web Server - The export_kicad_sch tool is registered as a mutation, so writing an export is gated to writer roles
test "export_kicad_sch is registered as a mutation tool" {
    const mcp_tools = @import("mcp_tools.zig");
    // Registered at all — the table and the tools/list JSON are checked in
    // lockstep by mcp_tools' own test.
    try testing.expect(mcp_tools.isKnownTool("export_kicad_sch"));
    // …and as a mutation: without output_dir the call only reads, but the
    // write path exists, so the role gate has to see it as one.
    try testing.expect(mcp_tools.isMutationTool("export_kicad_sch"));
}

// spec: Web Server - The export_kicad_sch summary reports the file list with byte counts and the export's coverage tallies, never the sheet text
test "export_kicad_sch summarises without returning sheet content" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const files = [_]export_kicad_sch.SchFile{
        .{ .name = "demo.kicad_sch", .bytes = "(kicad_sch (version 20260306))" },
    };
    const sidecars = [_]export_kicad_sch.SchFile{
        .{ .name = "sym-lib-table", .bytes = "(sym_lib_table)" },
    };
    const result = export_kicad_sch.Output{
        .files = &files,
        .sidecars = &sidecars,
        .stats = .{ .components = 3, .vendor_bodies = 1, .instances = 7 },
    };

    var aw: std.Io.Writer.Allocating = .init(a);
    try writeSummary(&aw.writer, "demo", result, null);
    const json = aw.written();

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try testing.expectEqual(@as(i64, 1), o.get("sheets").?.integer);
    try testing.expectEqual(@as(i64, 3), o.get("components").?.integer);
    try testing.expectEqual(@as(i64, 1), o.get("vendor_bodies").?.integer);
    try testing.expectEqual(@as(i64, 7), o.get("instances").?.integer);
    try testing.expectEqual(@as(i64, 45), o.get("bytes_total").?.integer);
    try testing.expectEqual(false, o.get("written").?.bool);
    const first = o.get("files").?.array.items[0].object;
    try testing.expectEqualStrings("demo.kicad_sch", first.get("name").?.string);
    try testing.expectEqual(@as(i64, 30), first.get("bytes").?.integer);
    // The sheet's own text is never in the response — only its size.
    try testing.expect(std.mem.indexOf(u8, json, "kicad_sch (version") == null);
}
