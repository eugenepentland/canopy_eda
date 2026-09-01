//! Complete engineering handoff archive layered on the authorized fab package.
//!
//! The authorized fabrication ZIP stays byte-for-byte unchanged inside the
//! outer archive. This module adds the human-readable schematic, every
//! evaluated source file, saved layout/BOM/check sidecars, locally available
//! datasheets, a complete KiCad project (schematic, netlist, footprints and
//! component STEP models), and the exact full-board AP242 model produced by
//! the 3D viewer.

const std = @import("std");

const env = @import("eval/env.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;
const export_fab = @import("export_fab.zig");
const export_kicad = @import("export_kicad.zig");
const fab_release = @import("fab_release.zig");
const infra_fs = @import("infra/fs.zig");
const paths = @import("paths.zig");
const datasheet_ref = @import("serve/datasheet_ref.zig");

const archive_source_limit_bytes: usize = 16 * 1024 * 1024;
const archive_sidecar_limit_bytes: usize = 256 * 1024 * 1024;
const archive_datasheet_limit_bytes: usize = 64 * 1024 * 1024;
const archive_board_limit_bytes: usize = 256 * 1024 * 1024;

/// Resolved design and already-rendered documents added around one fab ZIP.
pub const Input = struct {
    project_dir: []const u8,
    name: []const u8,
    block: *const env.DesignBlock,
    evaluator: *const Evaluator,
    schematic_html: []const u8,
    board_step: []const u8,
    fab_id: []const u8,
};

/// Failures while composing the deterministic outer engineering archive.
pub const AppendError = error{ UnsafeArchivePath, InvalidName } ||
    std.mem.Allocator.Error || std.Io.Writer.Error || export_kicad.ExportError;

const Stats = struct {
    sources: usize = 0,
    sidecars: usize = 0,
    datasheets: usize = 0,
    remote_datasheets: usize = 0,
    missing_datasheets: usize = 0,
    kicad_files: usize = 0,
};

/// Add every non-fabrication artifact to an already-composed and authorized
/// fab package. The caller writes the one outer ZIP after this returns.
pub fn append(
    allocator: std.mem.Allocator,
    pkg: *export_fab.Package,
    input: Input,
) AppendError!void {
    var seen = std.StringHashMapUnmanaged(void).empty;
    defer seen.deinit(allocator);
    for (pkg.entries.items) |entry| try seen.put(allocator, entry.name, {});

    var stats: Stats = .{};
    try addUnique(pkg, &seen, "schematic/schematic.html", input.schematic_html);
    const step_name = try std.fmt.allocPrint(
        allocator,
        "3d/{s}_ID_{s}.step",
        .{ safeStem(input.name), input.fab_id },
    );
    try addUnique(pkg, &seen, step_name, input.board_step);

    const kicad = try export_kicad.exportKicadEntries(
        allocator,
        input.block,
        input.project_dir,
        input.name,
        .{ .schematic = true },
    );
    defer allocator.free(kicad);
    for (kicad) |entry| {
        const archive_name = try std.fmt.allocPrint(allocator, "engineering/kicad/{s}", .{entry.name});
        try addUnique(pkg, &seen, archive_name, entry.data);
        stats.kicad_files += 1;
    }

    try appendSources(allocator, pkg, &seen, input, &stats);
    try appendSidecars(allocator, pkg, &seen, input, &stats);
    const datasheet_notes = try appendDatasheets(allocator, pkg, &seen, input, &stats);
    try addUnique(pkg, &seen, "datasheets/README.txt", datasheet_notes);

    const readme = try renderReadme(allocator, input, stats);
    try addUnique(pkg, &seen, "README.md", readme);

    // The fab package's own checksums remain unchanged and continue to attest
    // only its release payload. This second manifest covers the complete
    // engineering archive, including those original fab checksums.
    var checksums: std.Io.Writer.Allocating = .init(allocator);
    try fab_release.writeChecksums(&checksums.writer, pkg.entries.items);
    try addUnique(pkg, &seen, "archive-checksums.sha256", checksums.written());
}

fn addUnique(
    pkg: *export_fab.Package,
    seen: *std.StringHashMapUnmanaged(void),
    name: []const u8,
    data: []const u8,
) !void {
    if (name.len == 0 or name[0] == '/' or std.mem.indexOf(u8, name, "..") != null) return error.UnsafeArchivePath;
    if (seen.contains(name)) return;
    try seen.put(pkg.arena, name, {});
    try pkg.addNamed(name, data);
}

fn safeStem(name: []const u8) []const u8 {
    if (name.len == 0) return "design";
    for (name) |c| {
        const punctuation = c == '-' or c == '_' or c == '.';
        if (!std.ascii.isAlphanumeric(c) and !punctuation) return "design";
    }
    return name;
}

fn appendSources(
    allocator: std.mem.Allocator,
    pkg: *export_fab.Package,
    seen: *std.StringHashMapUnmanaged(void),
    input: Input,
    stats: *Stats,
) !void {
    const root = try paths.designSourcePath(allocator, input.project_dir, input.name);
    defer allocator.free(root);
    try appendSourceFile(allocator, pkg, seen, input.project_dir, root, stats);

    var loaded: std.ArrayList([]const u8) = .empty;
    defer loaded.deinit(allocator);
    var it = input.evaluator.loaded_files.keyIterator();
    while (it.next()) |key| if (std.mem.endsWith(u8, key.*, ".sexp")) try loaded.append(allocator, key.*);
    std.mem.sort([]const u8, loaded.items, {}, lessThanString);
    for (loaded.items) |path| {
        if (!std.mem.endsWith(u8, path, ".sexp")) continue;
        try appendSourceFile(allocator, pkg, seen, input.project_dir, path, stats);
    }

    // Footprints are consumed by placement/KiCad export rather than always by
    // the evaluator, so collect their native netlisp sources explicitly.
    try appendFootprintSources(allocator, pkg, seen, input.project_dir, input.block, stats);
}

fn appendSourceFile(
    allocator: std.mem.Allocator,
    pkg: *export_fab.Package,
    seen: *std.StringHashMapUnmanaged(void),
    project_dir: []const u8,
    path: []const u8,
    stats: *Stats,
) !void {
    const data = infra_fs.cwd().readFileAlloc(allocator, path, archive_source_limit_bytes) catch return;
    const relative = projectRelative(project_dir, path);
    const name = try std.fmt.allocPrint(allocator, "sources/{s}", .{relative});
    const before = pkg.entries.items.len;
    try addUnique(pkg, seen, name, data);
    if (pkg.entries.items.len != before) stats.sources += 1;
}

fn appendFootprintSources(
    allocator: std.mem.Allocator,
    pkg: *export_fab.Package,
    seen: *std.StringHashMapUnmanaged(void),
    project_dir: []const u8,
    block: *const env.DesignBlock,
    stats: *Stats,
) !void {
    for (block.instances) |instance| if (instance.footprint.len > 0) {
        const path = try std.fmt.allocPrint(allocator, "{s}/lib/footprints/{s}.sexp", .{ project_dir, instance.footprint });
        try appendSourceFile(allocator, pkg, seen, project_dir, path, stats);
    };
    for (block.sub_blocks) |sub| try appendFootprintSources(allocator, pkg, seen, project_dir, sub.block, stats);
}

fn appendSidecars(
    allocator: std.mem.Allocator,
    pkg: *export_fab.Package,
    seen: *std.StringHashMapUnmanaged(void),
    input: Input,
    stats: *Stats,
) !void {
    const suffixes = [_][]const u8{
        ".layouts.json",   ".autolayout.json", ".bom",         ".checks.sexp",
        ".drc-rules.json", ".notes.md",        ".refdes.json",
    };
    for (suffixes) |suffix| {
        const path = paths.designSiblingPath(allocator, input.project_dir, input.name, suffix) catch continue;
        defer allocator.free(path);
        const data = infra_fs.cwd().readFileAlloc(allocator, path, archive_sidecar_limit_bytes) catch continue;
        const name = try std.fmt.allocPrint(allocator, "layout/{s}{s}", .{ safeStem(input.name), suffix });
        try addUnique(pkg, seen, name, data);
        stats.sidecars += 1;
    }
    if (input.block.kicad_pcb_path) |path| {
        const data = infra_fs.cwd().readFileAlloc(allocator, path, archive_board_limit_bytes) catch return;
        const name = try std.fmt.allocPrint(allocator, "layout/kicad/{s}", .{std.fs.path.basename(path)});
        try addUnique(pkg, seen, name, data);
        stats.sidecars += 1;
    }
}

fn appendDatasheets(
    allocator: std.mem.Allocator,
    pkg: *export_fab.Package,
    seen: *std.StringHashMapUnmanaged(void),
    input: Input,
    stats: *Stats,
) ![]const u8 {
    var refs = std.StringHashMapUnmanaged(void).empty;
    defer refs.deinit(allocator);
    try collectDatasheetRefs(allocator, input.block, &refs);

    var notes: std.Io.Writer.Allocating = .init(allocator);
    try notes.writer.writeAll(
        "Datasheets referenced by parts used in this design.\n" ++
            "Local PDFs are included byte-for-byte. Remote URLs are recorded rather than fetched during release.\n\n",
    );
    var ordered: std.ArrayList([]const u8) = .empty;
    defer ordered.deinit(allocator);
    var it = refs.keyIterator();
    while (it.next()) |key| try ordered.append(allocator, key.*);
    std.mem.sort([]const u8, ordered.items, {}, lessThanString);
    for (ordered.items) |reference| {
        if (datasheet_ref.isRemote(reference)) {
            try notes.writer.print("REMOTE  {s}\n", .{reference});
            stats.remote_datasheets += 1;
            continue;
        }
        if (!datasheet_ref.isLocal(reference)) {
            try notes.writer.print("INVALID {s}\n", .{reference});
            stats.missing_datasheets += 1;
            continue;
        }
        const path = try std.fmt.allocPrint(allocator, "{s}/lib/datasheets/{s}", .{ input.project_dir, reference });
        const data = infra_fs.cwd().readFileAlloc(allocator, path, archive_datasheet_limit_bytes) catch {
            try notes.writer.print("MISSING {s}\n", .{reference});
            stats.missing_datasheets += 1;
            continue;
        };
        const name = try std.fmt.allocPrint(allocator, "datasheets/{s}", .{reference});
        try addUnique(pkg, seen, name, data);
        try notes.writer.print("INCLUDED {s}\n", .{reference});
        stats.datasheets += 1;
    }
    return notes.written();
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn collectDatasheetRefs(
    allocator: std.mem.Allocator,
    block: *const env.DesignBlock,
    refs: *std.StringHashMapUnmanaged(void),
) !void {
    for (block.instances) |instance| for (instance.docs.datasheets) |reference| {
        try refs.put(allocator, reference, {});
    };
    for (block.sub_blocks) |sub| try collectDatasheetRefs(allocator, sub.block, refs);
}

fn projectRelative(project_dir: []const u8, path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, project_dir)) {
        const relative = std.mem.trimStart(u8, path[project_dir.len..], "/");
        if (relative.len > 0 and std.mem.indexOf(u8, relative, "..") == null) return relative;
    }
    if (std.mem.lastIndexOf(u8, path, "/lib/")) |index| return path[index + 1 ..];
    if (std.mem.lastIndexOf(u8, path, "/src/")) |index| return path[index + 1 ..];
    return std.fs.path.basename(path);
}

fn renderReadme(allocator: std.mem.Allocator, input: Input, stats: Stats) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\# {s} complete design archive
        \\
        \\This archive is the complete engineering handoff for fabrication ID `{s}`.
        \\
        \\- `fabrication/board-release.zip` is the byte-identical, release-authorized fab package (Gerber, drill, assembly, BOM, evidence, and fab checksums).
        \\- `schematic/schematic.html` is a self-contained, read-only HTML rendering of the schematic.
        \\- `sources/` mirrors the evaluated netlisp source tree, including native footprint sources ({d} files).
        \\- `layout/` contains saved layout, routing, BOM/check sidecars, and the linked KiCad PCB when available ({d} files).
        \\- `engineering/kicad/` is a complete KiCad project with schematic sheets, netlist, generated `.kicad_mod` footprints, and used component STEP models ({d} files).
        \\- `3d/` contains the complete assembled board AP242 STEP model from the PCB 3D viewer.
        \\- `datasheets/` contains every locally available PDF referenced by a used part ({d} included; {d} remote URL(s); {d} missing/invalid).
        \\- `archive-checksums.sha256` covers every member above; the original fab `checksums.sha256` remains scoped to the release payload.
        \\
        \\Remote datasheets are listed in `datasheets/README.txt` and are deliberately not downloaded during a revision-locked export.
        \\
    , .{
        input.name,
        input.fab_id,
        stats.sources,
        stats.sidecars,
        stats.kicad_files,
        stats.datasheets,
        stats.remote_datasheets,
        stats.missing_datasheets,
    });
}

test "project-relative archive names preserve the source tree" {
    try std.testing.expectEqualStrings("src/demo.sexp", projectRelative("/project", "/project/src/demo.sexp"));
    try std.testing.expectEqualStrings("lib/components/ic.sexp", projectRelative("elsewhere", "/shared/lib/components/ic.sexp"));
    try std.testing.expectEqualStrings("demo.sexp", projectRelative("elsewhere", "demo.sexp"));
}

test "unsafe design names never become archive paths" {
    try std.testing.expectEqualStrings("board-a", safeStem("board-a"));
    try std.testing.expectEqualStrings("design", safeStem("../board"));
    try std.testing.expectEqualStrings("design", safeStem("board/name"));
}
