//! Contained workspace assets shared by system-review HTTP and package code.
//!
//! Assets are deliberately flat, bounded, non-active files. Enumeration fails
//! closed on every unsupported name, kind, symlink, or content signature so a
//! draft, attestation, and final release always see the same deterministic set.

const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const system_review = @import("system_review.zig");

/// Per-file ceiling shared by upload and package enumeration.
pub const max_asset_bytes: usize = 8 * 1024 * 1024;
/// Maximum number of files in one system workspace.
pub const max_asset_count: usize = 64;
/// Aggregate workspace-asset ceiling.
pub const max_total_bytes: usize = 32 * 1024 * 1024;
/// Maximum portable flat filename length.
pub const max_filename_bytes: usize = 192;

/// Non-active asset formats accepted by both browser and package paths.
///
/// PDF and SVG are intentionally excluded because they can carry active
/// content; CSV is excluded because spreadsheet formula execution is not
/// safely distinguishable from ordinary review data at this boundary.
pub const Kind = enum { png, jpeg, text };

/// One validated allocator-owned workspace asset.
pub const Asset = struct {
    name: []const u8,
    relative_path: []const u8,
    data: []const u8,
};

/// Resolve an accepted filename to its content kind.
pub fn kind(filename: []const u8) ?Kind {
    if (std.ascii.endsWithIgnoreCase(filename, ".png")) return .png;
    if (std.ascii.endsWithIgnoreCase(filename, ".jpg")) return .jpeg;
    if (std.ascii.endsWithIgnoreCase(filename, ".jpeg")) return .jpeg;
    if (std.ascii.endsWithIgnoreCase(filename, ".txt")) return .text;
    return null;
}

/// True for a portable, flat, non-hidden supported asset filename.
pub fn validFilename(filename: []const u8) bool {
    if (filename.len == 0 or filename.len > max_filename_bytes) return false;
    if (filename[0] == '.' or std.mem.indexOf(u8, filename, "..") != null) return false;
    for (filename) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        if (byte == '-' or byte == '_' or byte == '.') continue;
        return false;
    }
    return kind(filename) != null;
}

/// Validate the file signature or non-active UTF-8 profile for `asset_kind`.
pub fn validContent(asset_kind: Kind, body: []const u8) bool {
    return switch (asset_kind) {
        .png => body.len >= 8 and std.mem.eql(u8, body[0..8], "\x89PNG\r\n\x1a\n"),
        .jpeg => body.len >= 3 and body[0] == 0xff and body[1] == 0xd8 and body[2] == 0xff,
        .text => validText(body),
    };
}

/// Construct the sole project-relative storage path for an asset.
pub fn relativePath(
    allocator: std.mem.Allocator,
    system_name: []const u8,
    filename: []const u8,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "src/systems/{s}/assets/{s}", .{ system_name, filename });
}

const ResolveError = @typeInfo(@typeInfo(@TypeOf(resolveContainedPathAllocImpl)).@"fn".return_type.?).error_union.error_set;

/// Canonicalize an existing relative path and require it to remain below the
/// canonical project root. Parent symlinks that escape the project fail.
pub fn resolveContainedPathAlloc(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    relative: []const u8,
) ResolveError![]const u8 {
    return resolveContainedPathAllocImpl(allocator, project_dir, relative);
}

fn resolveContainedPathAllocImpl(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    relative: []const u8,
) ![]const u8 {
    if (!system_review.isSafeRelativePath(relative)) return error.UnsafePath;
    const root = try infra_fs.canonicalPathAlloc(allocator, project_dir);
    defer allocator.free(root);
    const joined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, relative });
    defer allocator.free(joined);
    const canonical = try infra_fs.canonicalPathAlloc(allocator, joined);
    defer allocator.free(canonical);
    if (!containedBy(root, canonical)) return error.UnsafePath;
    // `realPathFileAlloc` owns a sentinel byte. This API deliberately returns
    // an ordinary slice, so duplicate it rather than erasing the sentinel and
    // later freeing the allocation at the wrong length.
    return allocator.dupe(u8, canonical);
}

const ReadContainedError = @typeInfo(@typeInfo(@TypeOf(readContainedFileImpl)).@"fn".return_type.?).error_union.error_set;

/// Read one existing project-relative file after canonical containment, and
/// require the named path itself (including every parent) to be nonsymlinked.
pub fn readContainedFile(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    relative: []const u8,
    max_bytes: usize,
) ReadContainedError![]const u8 {
    return readContainedFileImpl(allocator, project_dir, relative, max_bytes);
}

fn readContainedFileImpl(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    relative: []const u8,
    max_bytes: usize,
) ![]const u8 {
    const resolved = try resolveExactContainedPathAlloc(allocator, project_dir, relative);
    defer allocator.free(resolved);
    const root = try infra_fs.canonicalPathAlloc(allocator, project_dir);
    defer allocator.free(root);
    var project = try infra_fs.cwd().openDir(root, .{ .follow_symlinks = false });
    defer project.close();
    return project.readFileAllocSecure(allocator, relative, max_bytes);
}

const EnumerateError = @typeInfo(@typeInfo(@TypeOf(enumerateImpl)).@"fn".return_type.?).error_union.error_set;

/// Enumerate the complete sorted asset set. A missing `assets/` directory is
/// empty; every present entry must be a flat safe regular file.
pub fn enumerate(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    system_name: []const u8,
) EnumerateError![]const Asset {
    return enumerateImpl(allocator, project_dir, system_name);
}

fn enumerateImpl(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    system_name: []const u8,
) ![]const Asset {
    if (!simpleName(system_name)) return error.InvalidSystemName;
    const workspace_relative = try std.fmt.allocPrint(allocator, "src/systems/{s}", .{system_name});
    defer allocator.free(workspace_relative);
    const workspace = try resolveContainedPathAlloc(allocator, project_dir, workspace_relative);
    defer allocator.free(workspace);
    const assets_relative = try std.fmt.allocPrint(allocator, "{s}/assets", .{workspace_relative});
    defer allocator.free(assets_relative);

    var workspace_dir = try infra_fs.cwd().openDir(workspace, .{ .iterate = true });
    defer workspace_dir.close();
    const has_assets = try validateAssetDirectory(&workspace_dir);
    if (!has_assets) return &.{};

    const assets_dir_path = try exactContainedPath(allocator, project_dir, assets_relative);
    defer allocator.free(assets_dir_path);
    var assets_dir = try infra_fs.cwd().openDir(assets_dir_path, .{ .iterate = true });
    defer assets_dir.close();

    var names: std.ArrayList([]const u8) = .empty;
    var iterator = assets_dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) return error.UnsafeAssetEntry;
        if (!validFilename(entry.name)) return error.UnsupportedAsset;
        if (names.items.len >= max_asset_count) return error.TooManyAssets;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessName);

    var result: std.ArrayList(Asset) = .empty;
    var total_bytes: usize = 0;
    for (names.items) |name| {
        const relative = try relativePath(allocator, system_name, name);
        const resolved = try exactContainedPath(allocator, project_dir, relative);
        defer allocator.free(resolved);
        const data = readContainedFile(allocator, project_dir, relative, max_asset_bytes) catch |err| switch (err) {
            error.FileTooBig => return error.AssetTooLarge,
            else => return err,
        };
        if (!validContent(kind(name).?, data)) return error.InvalidAssetContent;
        if (data.len > max_total_bytes - total_bytes) return error.AssetsTooLarge;
        total_bytes += data.len;
        try result.append(allocator, .{ .name = name, .relative_path = relative, .data = data });
    }
    return result.toOwnedSlice(allocator);
}

const ReadAssetError = @typeInfo(@typeInfo(@TypeOf(readAssetImpl)).@"fn".return_type.?).error_union.error_set;

/// Read and validate one exact nonsymlink workspace asset.
pub fn readAsset(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    system_name: []const u8,
    filename: []const u8,
) ReadAssetError!Asset {
    return readAssetImpl(allocator, project_dir, system_name, filename);
}

fn readAssetImpl(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    system_name: []const u8,
    filename: []const u8,
) !Asset {
    if (!simpleName(system_name)) return error.InvalidSystemName;
    if (!validFilename(filename)) return error.UnsupportedAsset;
    const relative = try relativePath(allocator, system_name, filename);
    errdefer allocator.free(relative);
    const resolved = try exactContainedPath(allocator, project_dir, relative);
    defer allocator.free(resolved);
    const data = readContainedFile(allocator, project_dir, relative, max_asset_bytes) catch |err| switch (err) {
        error.FileTooBig => return error.AssetTooLarge,
        else => return err,
    };
    errdefer allocator.free(data);
    if (!validContent(kind(filename).?, data)) return error.InvalidAssetContent;
    return .{ .name = filename, .relative_path = relative, .data = data };
}

/// Reject an upload that would put the bounded current set over count or
/// aggregate byte limits.
pub fn validateAddition(existing: []const Asset, added_bytes: usize) error{ TooManyAssets, AssetsTooLarge }!void {
    if (existing.len >= max_asset_count) return error.TooManyAssets;
    var total: usize = 0;
    for (existing) |asset| {
        if (asset.data.len > max_total_bytes - total) return error.AssetsTooLarge;
        total += asset.data.len;
    }
    if (added_bytes > max_total_bytes - total) return error.AssetsTooLarge;
}

fn exactContainedPath(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    relative: []const u8,
) ![]const u8 {
    return resolveExactContainedPathAlloc(allocator, project_dir, relative) catch |err| switch (err) {
        error.UnsafePath => error.UnsafeAssetEntry,
        else => return err,
    };
}

fn resolveExactContainedPathAlloc(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    relative: []const u8,
) ![]const u8 {
    if (!system_review.isSafeRelativePath(relative)) return error.UnsafePath;
    const root = try infra_fs.canonicalPathAlloc(allocator, project_dir);
    defer allocator.free(root);
    const expected = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, relative });
    defer allocator.free(expected);
    const resolved = try resolveContainedPathAlloc(allocator, project_dir, relative);
    if (!std.mem.eql(u8, expected, resolved)) {
        allocator.free(resolved);
        return error.UnsafePath;
    }
    return resolved;
}

fn validateAssetDirectory(workspace: *infra_fs.Dir) !bool {
    var iterator = workspace.iterate();
    while (try iterator.next()) |entry| {
        if (!std.mem.eql(u8, entry.name, "assets")) continue;
        if (entry.kind != .directory) return error.UnsafeAssetEntry;
        return true;
    }
    return false;
}

fn validText(body: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(body)) return false;
    for (body) |byte| {
        if (byte == 0) return false;
        if (byte < 0x20 and !allowedTextControl(byte)) return false;
    }
    return true;
}

fn allowedTextControl(byte: u8) bool {
    return byte == '\n' or byte == '\r' or byte == '\t';
}

fn containedBy(root: []const u8, child: []const u8) bool {
    return child.len > root.len and std.mem.startsWith(u8, child, root) and child[root.len] == '/';
}

fn simpleName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or !std.ascii.isAlphanumeric(name[0])) return false;
    for (name[1..]) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.') continue;
        return false;
    }
    return true;
}

fn lessName(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

test "workspace asset enumeration is flat validated sorted and bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "project/src/systems/demo/assets");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/src/systems/demo/assets/z.txt", .data = "last\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/src/systems/demo/assets/a.png", .data = "\x89PNG\r\n\x1a\n" });
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, "project", allocator);
    const assets = try enumerate(allocator, project, "demo");
    try std.testing.expectEqual(@as(usize, 2), assets.len);
    try std.testing.expectEqualStrings("a.png", assets[0].name);
    try std.testing.expectEqualStrings("src/systems/demo/assets/z.txt", assets[1].relative_path);
    try validateAddition(assets, 12);

    const at_count_limit: [max_asset_count]Asset = @splat(.{ .name = "x.txt", .relative_path = "x.txt", .data = "" });
    try std.testing.expectError(error.TooManyAssets, validateAddition(&at_count_limit, 1));
    try std.testing.expectError(error.AssetsTooLarge, validateAddition(&.{}, max_total_bytes + 1));
}

// spec: system-review - system-review file reads resolve canonically below the project root and reject parent-symlink escapes
test "contained reads reject a parent symlink outside the project" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.createDirPath(std.testing.io, "outside");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside/secret.txt", .data = "secret" });
    try tmp.dir.symLink(std.testing.io, "../outside", "project/src", .{ .is_directory = true });
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, "project", allocator);
    try std.testing.expectError(error.UnsafePath, readContainedFile(allocator, project, "src/secret.txt", 64));
}

test "contained reads reject an in-project file symlink" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "project/src/systems/demo");
    try tmp.dir.createDirPath(std.testing.io, "project/private");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/private/secret.md", .data = "secret" });
    try tmp.dir.symLink(
        std.testing.io,
        "../../../private/secret.md",
        "project/src/systems/demo/review.md",
        .{},
    );
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, "project", allocator);
    try std.testing.expectError(
        error.UnsafePath,
        readContainedFile(allocator, project, "src/systems/demo/review.md", 64),
    );
}

test "workspace assets reject symlinks unsupported files and nested entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "project/src/systems/demo/assets/nested");
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, "project", allocator);
    try std.testing.expectError(error.UnsafeAssetEntry, enumerate(allocator, project, "demo"));

    try tmp.dir.createDirPath(std.testing.io, "project/src/systems/unsupported/assets");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/src/systems/unsupported/assets/live.svg", .data = "<svg/>" });
    try std.testing.expectError(error.UnsupportedAsset, enumerate(allocator, project, "unsupported"));

    try tmp.dir.createDirPath(std.testing.io, "project/src/systems/bad_content/assets");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/src/systems/bad_content/assets/evidence.png", .data = "not a png" });
    try std.testing.expectError(error.InvalidAssetContent, enumerate(allocator, project, "bad_content"));

    try tmp.dir.createDirPath(std.testing.io, "project/src/systems/symlink/assets");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/src/systems/symlink/outside.txt", .data = "outside\n" });
    try tmp.dir.symLink(
        std.testing.io,
        "../outside.txt",
        "project/src/systems/symlink/assets/link.txt",
        .{},
    );
    try std.testing.expectError(error.UnsafeAssetEntry, enumerate(allocator, project, "symlink"));
}
