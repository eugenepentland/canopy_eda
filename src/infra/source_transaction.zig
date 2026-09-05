//! Source mutations hold one project-directory lock from read through commit.
//! Directory flock coordinates server threads and independent CLI processes;
//! nesting lets HTTP adapters call the same locked core operations.
const std = @import("std");
const fs = @import("fs.zig");
const atomic = @import("atomic_write.zig");
const paths = @import("../paths.zig");
const parser = @import("../sexpr/parser.zig");

var mutex: fs.Mutex = .{};
threadlocal var depth: usize = 0;
threadlocal var project: []const u8 = "";

/// A lexical hold of the project's cross-process mutation lock.
pub const Guard = struct {
    directory: ?fs.Dir = null,

    /// Release this nesting level; the outer hold releases the OS lock.
    pub fn unlock(self: Guard) void {
        std.debug.assert(depth > 0);
        depth -= 1;
        if (self.directory) |dir| {
            std.debug.assert(depth == 0);
            const file: std.Io.File = .{ .handle = dir.d.handle, .flags = .{ .nonblocking = false } };
            file.unlock(fs.currentIo());
            dir.close();
            project = "";
            mutex.unlock();
        }
    }
};

/// Acquire before reading any file that the operation may later replace.
pub fn begin(project_dir: []const u8) error{CannotLockProject}!Guard {
    if (depth > 0) {
        if (!std.mem.eql(u8, project, project_dir)) return error.CannotLockProject;
        depth += 1;
        return .{};
    }
    mutex.lock();
    errdefer mutex.unlock();
    const dir = fs.cwd().openDir(project_dir, .{ .iterate = true }) catch return error.CannotLockProject;
    errdefer dir.close();
    const file: std.Io.File = .{ .handle = dir.d.handle, .flags = .{ .nonblocking = false } };
    file.lock(fs.currentIo(), .exclusive) catch return error.CannotLockProject;
    project = project_dir;
    depth = 1;
    return .{ .directory = dir };
}

/// Commit only inside a transaction, rejecting invalid source before replacement.
pub fn writeFile(allocator: std.mem.Allocator, path: []const u8, data: []const u8) (atomic.Error || error{ TransactionRequired, InvalidSource })!void {
    if (depth == 0) return error.TransactionRequired;
    if (std.mem.endsWith(u8, path, ".sexp")) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        _ = parser.parse(arena.allocator(), data) catch return error.InvalidSource;
    }
    try atomic.writeFile(path, data);
}

/// Content revision, stable across processes and server restarts.
pub fn revision(source: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Read a revision for an editable design or module source file.
pub fn revisionFor(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?[64]u8 {
    const path = paths.designSourcePath(allocator, project_dir, name) catch return null;
    defer allocator.free(path);
    const source = fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch return null;
    defer allocator.free(source);
    return revision(source);
}

// spec: Web Server - Source writes require a transaction and use exact content hashes for revision comparisons
test "source transaction rejects unheld writes and hashes exact bytes" {
    try std.testing.expectError(error.TransactionRequired, writeFile(std.testing.allocator, "unused.sexp", "()"));
    try std.testing.expect(!std.mem.eql(u8, &revision("old"), &revision("new")));
}

// spec: Web Server - Failed source commits preserve the previous file and nested mutation scopes retain one project lock
test "source transaction preserves files on rejected and failed commits" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "source.sexp" });
    defer a.free(path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source.sexp", .data = "(before)" });
    try std.testing.expectError(error.CannotLockProject, begin("/missing-eda-transaction-project"));
    const outer = try begin(root);
    defer outer.unlock();
    try std.testing.expectError(error.CannotLockProject, begin("/different-project"));
    {
        const inner = try begin(root);
        defer inner.unlock();
        try std.testing.expectError(error.InvalidSource, writeFile(a, path, "(broken"));
    }
    const unchanged = try tmp.dir.readFileAlloc(std.testing.io, "source.sexp", a, .limited(1024));
    defer a.free(unchanged);
    try std.testing.expectEqualStrings("(before)", unchanged);
    const missing = try std.fs.path.join(a, &.{ root, "missing", "source.sexp" });
    defer a.free(missing);
    try std.testing.expectError(error.FileNotFound, writeFile(a, missing, "(after)"));
    try writeFile(a, path, "(after)");
    const committed = try tmp.dir.readFileAlloc(std.testing.io, "source.sexp", a, .limited(1024));
    defer a.free(committed);
    try std.testing.expectEqualStrings("(after)", committed);
}

const AppendWorker = struct {
    fn run(allocator: std.mem.Allocator, project_dir: []const u8, path: []const u8, accepted: *std.atomic.Value(usize)) void {
        for (0..10) |_| {
            const guard = begin(project_dir) catch return;
            defer guard.unlock();
            const before = fs.cwd().readFileAlloc(allocator, path, 4096) catch return;
            defer allocator.free(before);
            const after = std.mem.concat(allocator, u8, &.{ before, "x" }) catch return;
            defer allocator.free(after);
            writeFile(allocator, path, after) catch return;
            _ = accepted.fetchAdd(1, .monotonic);
        }
    }
};

// spec: Web Server - Concurrent source mutations serialize their entire read-modify-write so every accepted change survives
test "source transaction concurrent read modify write loses no update" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "notes.md" });
    defer a.free(path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "notes.md", .data = "" });
    var accepted: std.atomic.Value(usize) = .init(0);
    const first = try std.Thread.spawn(.{}, AppendWorker.run, .{ a, root, path, &accepted });
    const second = std.Thread.spawn(.{}, AppendWorker.run, .{ a, root, path, &accepted }) catch |err| {
        first.join();
        return err;
    };
    first.join();
    second.join();
    try std.testing.expectEqual(@as(usize, 20), accepted.load(.acquire));
    const final = try tmp.dir.readFileAlloc(std.testing.io, "notes.md", a, .limited(4096));
    defer a.free(final);
    try std.testing.expectEqual(@as(usize, 20), final.len);
}
