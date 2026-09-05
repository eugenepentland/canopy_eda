//! Revision-checked package persistence; one locked transaction owns all assets.
const std = @import("std");
const fs = @import("../infra/fs.zig");
const atomic = @import("../infra/atomic_write.zig");
const transaction = @import("../infra/source_transaction.zig");
const gen = @import("package_generator.zig");
const library = @import("library.zig");

/// Errors from validation, revision checks, staging, and optional component linking.
pub const Error = std.json.ParseError(std.json.Scanner) || @import("../sexpr/parser.zig").ParseError ||
    std.mem.Allocator.Error || std.Io.Writer.Error || std.Io.Dir.ReadFileAllocError || fs.Dir.MakeError || fs.Dir.DeleteFileError || atomic.Error || @import("pcb_step_export.zig").ExportError ||
    error{ InvalidName, RecipeTooLarge, UnsupportedSchema, InvalidArtwork, InvalidFootprint, CannotLockProject, DimensionsNotVerified, InvalidPackage, RevisionRequired, RevisionConflict, GeneratedAssetChanged, NameAlreadyExists, RollbackFailed, InvalidModelConfig, InvalidPinout, InvalidComponent, PinoutMismatch };

pub const Files = struct { recipe: []const u8, footprint: []const u8, model: []const u8, config: []const u8 };

/// Resolve only project-local package paths, with the library's basename rules.
pub fn paths(a: std.mem.Allocator, project: []const u8, name: []const u8) (std.mem.Allocator.Error || error{InvalidName})!Files {
    if (!library.isSafeLibName(name) or name.len > 100) return error.InvalidName;
    return .{
        .recipe = try std.fmt.allocPrint(a, "{s}/lib/packages/{s}.json", .{ project, name }),
        .footprint = try std.fmt.allocPrint(a, "{s}/lib/footprints/{s}.sexp", .{ project, name }),
        .model = try std.fmt.allocPrint(a, "{s}/lib/models/{s}.step", .{ project, name }),
        .config = try std.fmt.allocPrint(a, "{s}/lib/models/model-config.json", .{project}),
    };
}
fn read(a: std.mem.Allocator, path: []const u8) !?[]const u8 {
    return fs.cwd().readFileAlloc(a, path, 64 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}
fn hash(a: std.mem.Allocator, data: []const u8) ![]const u8 {
    return a.dupe(u8, &transaction.revision(data));
}

/// Load a recipe with the exact revision required by a subsequent save.
pub fn load(a: std.mem.Allocator, project: []const u8, name: []const u8) Error!gen.Recipe {
    const files = try paths(a, project, name);
    const bytes = (try read(a, files.recipe)) orelse return error.FileNotFound;
    var r = try gen.parse(a, bytes);
    if (!std.mem.eql(u8, r.name, name)) return error.InvalidName;
    r.revision = try hash(a, bytes);
    return r;
}
const Change = struct { path: []const u8, bytes: []const u8, before: ?[]const u8 = null, staged: atomic.Staged = .{} };
fn commit(a: std.mem.Allocator, changes: []Change) !void {
    defer for (changes) |*c| c.staged.abandon();
    for (changes) |*c| {
        c.before = try read(a, c.path);
        try fs.cwd().makePath(std.fs.path.dirname(c.path) orelse return error.InvalidName);
        try c.staged.begin(c.path);
        try c.staged.write(c.bytes);
    }
    try finishChanges(changes);
}
fn abandonChanges(changes: []Change) void {
    for (changes) |*c| c.staged.abandon();
}
fn rollback(changes: []const Change) !void {
    var failed = false;
    for (changes) |old| {
        if (old.before) |bytes| {
            atomic.writeFile(old.path, bytes) catch {
                failed = true;
            };
        } else fs.cwd().deleteFile(old.path) catch {
            failed = true;
        };
    }
    if (failed) return error.RollbackFailed;
}
fn finishChanges(changes: []Change) !void {
    for (changes, 0..) |*c, i| {
        c.staged.commit() catch |err| {
            try rollback(changes[0..i]);
            return err;
        };
    }
}

fn configBytes(a: std.mem.Allocator, path: []const u8, name: []const u8) ![]const u8 {
    var value = if (try read(a, path)) |bytes| try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) else std.json.Value{ .object = .empty };
    if (value != .object) return error.InvalidModelConfig;
    const filename = try std.fmt.allocPrint(a, "{s}.step", .{name});
    var entry = value.object.get(name) orelse try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"offset\":[0,0,0],\"rotation\":[0,0,0]}", .{});
    if (entry != .object) return error.InvalidModelConfig;
    try entry.object.put(a, "model", .{ .string = filename });
    try value.object.put(a, name, entry);
    return std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2 });
}

/// Save the recipe and generated assets under a cross-process project lock.
/// Existing output hashes catch edits made outside the package builder.
pub fn save(a: std.mem.Allocator, project: []const u8, input: gen.Recipe) Error!gen.Recipe {
    return saveAttached(a, project, input, null);
}

/// Save a package and optionally link a component whose pinout matches its pad IDs.
pub fn saveAttached(a: std.mem.Allocator, project: []const u8, input: gen.Recipe, component: ?[]const u8) Error!gen.Recipe {
    const guard = try transaction.begin(project);
    defer guard.unlock();
    if (!input.dimensions_verified) return error.DimensionsNotVerified;
    const result = try gen.generate(a, input);
    if (gen.hasErrors(result.diagnostics)) return error.InvalidPackage;
    const files = try paths(a, project, input.name);
    if (try read(a, files.recipe)) |bytes| {
        const expected = input.revision orelse return error.RevisionRequired;
        if (!std.mem.eql(u8, expected, &transaction.revision(bytes))) return error.RevisionConflict;
        const old = try gen.parse(a, bytes);
        const fp = (try read(a, files.footprint)) orelse return error.GeneratedAssetChanged;
        const model = (try read(a, files.model)) orelse return error.GeneratedAssetChanged;
        if (!std.mem.eql(u8, old.footprint_hash, &transaction.revision(fp)) or !std.mem.eql(u8, old.model_hash, &transaction.revision(model))) return error.GeneratedAssetChanged;
    } else {
        if (input.revision != null) return error.RevisionConflict;
        if (try read(a, files.footprint) != null or try read(a, files.model) != null) return error.NameAlreadyExists;
    }
    var saved = input;
    saved.revision = null;
    saved.footprint_hash = try hash(a, result.footprint);
    saved.model_hash = try hash(a, result.step);
    const bytes = try std.json.Stringify.valueAlloc(a, saved, .{ .whitespace = .indent_2 });
    var changes = [_]Change{
        .{ .path = files.footprint, .bytes = result.footprint },
        .{ .path = files.model, .bytes = result.step },
        .{ .path = files.config, .bytes = try configBytes(a, files.config, input.name) },
        .{ .path = files.recipe, .bytes = bytes },
    };
    if (component) |name| {
        const change = try @import("package_component.zig").prepare(a, project, name, input, result.pads);
        var all: [5]Change = undefined;
        @memcpy(all[0..4], &changes);
        all[4] = .{ .path = change.path, .bytes = change.bytes };
        try commit(a, &all);
    } else try commit(a, &changes);
    saved.revision = try hash(a, bytes);
    return saved;
}

// spec: IC package builder - Concurrent access uses project locks and exact revisions; external edits and existing asset names prevent replacement
test "IC package save revisions collisions and external edits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var r = gen.template(.qfn);
    r.name = "package-test";
    try std.testing.expectError(error.DimensionsNotVerified, save(a, root, r));
    r.dimensions_verified = true;
    const first = try save(a, root, r);
    try std.testing.expect(first.revision != null);
    try std.testing.expectError(error.RevisionRequired, save(a, root, r));
    var next = try load(a, root, r.name);
    next.lands.length = 0.8;
    const second = try save(a, root, next);
    try std.testing.expect(!std.mem.eql(u8, first.revision.?, second.revision.?));
    try std.testing.expectError(error.RevisionConflict, save(a, root, first));
    const files = try paths(a, root, r.name);
    const fp = (try read(a, files.footprint)).?;
    try atomic.writeFile(files.footprint, try std.mem.concat(a, u8, &.{ fp, "; manual change\n" }));
    try std.testing.expectError(error.GeneratedAssetChanged, save(a, root, second));
    const missing = try paths(a, root, "collision");
    try atomic.writeFile(missing.footprint, "(footprint \"collision\")");
    r.name = "collision";
    try std.testing.expectError(error.NameAlreadyExists, save(a, root, r));
    try std.testing.expectError(error.InvalidName, paths(a, root, "../escape"));
    try std.testing.expectError(error.FileNotFound, load(a, root, "absent"));
}

// spec: IC package builder - I/O failure stages all files before replacement and preserves previous library bytes on a failed save
test "IC package failed staging leaves all assets unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var r = gen.template(.dfn);
    r.dimensions_verified = true;
    const saved = try save(a, root, r);
    const files = try paths(a, root, r.name);
    const before = (try read(a, files.footprint)).?;
    try atomic.writeFile(files.config, "[]");
    try std.testing.expectError(error.InvalidModelConfig, save(a, root, saved));
    try std.testing.expectEqualStrings(before, (try read(a, files.footprint)).?);
    const obstacle = try std.fs.path.join(a, &.{ root, "obstacle" });
    try atomic.writeFile(obstacle, "not a directory");
    var changes = [_]Change{ .{ .path = files.footprint, .bytes = "should not commit" }, .{ .path = try std.fs.path.join(a, &.{ obstacle, "file" }), .bytes = "new" } };
    const attempt = commit(a, &changes);
    try std.testing.expectError(error.NotDir, attempt);
    try std.testing.expectEqualStrings(before, (try read(a, files.footprint)).?);
}

// spec: IC package builder - Rollback after a staged rename failure
test "IC package rollback after a staged rename failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const first = try std.fs.path.join(a, &.{ root, "first" });
    const second = try std.fs.path.join(a, &.{ root, "second" });
    try atomic.writeFile(first, "before");
    var changes = [_]Change{ .{ .path = first, .bytes = "after", .before = "before" }, .{ .path = second, .bytes = "second" } };
    defer abandonChanges(&changes);
    for (&changes) |*c| {
        try c.staged.begin(c.path);
        try c.staged.write(c.bytes);
    }
    // Fault injection at the commit seam: the second staged file disappears.
    changes[1].staged.abandon();
    try std.testing.expectError(error.NotStaged, finishChanges(&changes));
    try std.testing.expectEqualStrings("before", (try read(a, first)).?);
    // A missing parent during rollback must surface as incomplete recovery.
    const absent = try std.fs.path.join(a, &.{ root, "removed-directory", "first" });
    const lost = [_]Change{.{ .path = absent, .bytes = "after", .before = "before" }};
    try std.testing.expectError(error.RollbackFailed, rollback(&lost));
}

// spec: IC package builder - Invalid and oversized dimensions, overlapping copper, duplicate numbering, and malformed recipes fail before persistence
test "IC package invalid geometry cannot save" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var r = gen.template(.qfn);
    r.dimensions_verified = true;
    r.body.height = -1;
    try std.testing.expectError(error.InvalidPackage, save(a, root, r));
}
