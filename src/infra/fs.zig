//! Filesystem port. All filesystem access in production code goes through
//! this module so Guardian's `ban-fs` check has one whitelisted entry point.
//! Zig 0.17 makes filesystem operations explicit `std.Io` operations; this
//! adapter preserves the existing call shape while keeping that dependency in
//! one place.
//!
//! Usage:
//!     const infra_fs = @import("infra/fs.zig");
//!     const file = try infra_fs.cwd().createFile(path, .{});
//!     const data = try infra_fs.cwd().readFileAlloc(allocator, path, max);

const std = @import("std");
const builtin = @import("builtin");

/// Return the active I/O capability. Tests use the runner-owned capability;
/// executable roots expose the one supplied by `std.process.Init`.
pub fn currentIo() std.Io {
    if (builtin.is_test) return std.testing.io;
    return @import("root").process_io;
}

/// Compatibility wrapper for Zig 0.17's I/O-backed synchronization. Existing
/// server state uses uncancelable critical sections, matching the old
/// `std.Thread.Mutex.lock` semantics.
pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    /// Enter an uncancelable critical section using the active I/O capability.
    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(currentIo());
    }

    /// Leave the critical section and wake a waiting task if necessary.
    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(currentIo());
    }
};

/// Compatibility wrapper for Zig 0.17's I/O-backed condition variables.
pub const Condition = struct {
    inner: std.Io.Condition = .init,

    /// Atomically unlock `mutex`, wait, and relock it without cancellation.
    pub fn wait(self: *Condition, mutex: *Mutex) void {
        self.inner.waitUncancelable(currentIo(), &mutex.inner);
    }

    /// Wake one task waiting on this condition.
    pub fn signal(self: *Condition) void {
        self.inner.signal(currentIo());
    }

    /// Wake every task waiting on this condition.
    pub fn broadcast(self: *Condition) void {
        self.inner.broadcast(currentIo());
    }
};

/// File handle bound to the active root I/O capability.
pub const File = struct {
    f: std.Io.File,

    pub const OpenError = std.Io.File.OpenError;
    pub const ReadError = std.Io.File.Reader.Error;
    pub const WriteError = @typeInfo(@typeInfo(@TypeOf(std.Io.File.writeStreamingAll)).@"fn".return_type.?).error_union.error_set;

    /// Close this handle using the active I/O capability.
    pub fn close(self: File) void {
        self.f.close(currentIo());
    }

    /// Stream every byte to the file or return the precise writer error.
    pub fn writeAll(self: File, bytes: []const u8) WriteError!void {
        try self.f.writeStreamingAll(currentIo(), bytes);
    }

    /// Read metadata for this open file.
    pub fn stat(self: File) std.Io.File.StatError!std.Io.File.Stat {
        return self.f.stat(currentIo());
    }

    /// Flush file contents and metadata to durable storage.
    pub fn sync(self: File) std.Io.File.SyncError!void {
        return self.f.sync(currentIo());
    }

    /// Replace the file's permissions.
    pub fn chmod(self: File, permissions: std.Io.File.Permissions) std.Io.File.SetPermissionsError!void {
        return self.f.setPermissions(currentIo(), permissions);
    }
};

/// Directory iterator bound to the active root I/O capability.
pub const Iterator = struct {
    it: std.Io.Dir.Iterator,

    pub const Error = std.Io.Dir.Iterator.Error;

    /// Return the next directory entry, or null after the final entry.
    pub fn next(self: *Iterator) Error!?std.Io.Dir.Entry {
        return self.it.next(currentIo());
    }
};

/// Recursive directory walker bound to the active root I/O capability.
pub const Walker = struct {
    walker: std.Io.Dir.Walker,

    pub const Error = std.mem.Allocator.Error || std.Io.Dir.Iterator.Error || std.Io.Dir.OpenError;

    /// Return the next recursive entry, or null when walking is complete.
    pub fn next(self: *Walker) Error!?std.Io.Dir.Walker.Entry {
        return self.walker.next(currentIo());
    }

    /// Release walker allocations and open directory handles.
    pub fn deinit(self: *Walker) void {
        self.walker.deinit();
    }
};

/// Buffer supplied for the writer owned by an atomic-file transaction.
pub const AtomicFileOptions = struct {
    write_buffer: []u8,
};

/// Compatibility wrapper for the former `std.fs.AtomicFile`: callers keep a
/// buffered `file_writer`, and `finish` flushes it before atomically replacing
/// the destination.
pub const AtomicFile = struct {
    inner: std.Io.File.Atomic,
    file_writer: std.Io.File.Writer,

    pub const InitError = std.Io.Dir.CreateFileAtomicError;
    pub const FinishError = File.WriteError || std.Io.File.Atomic.ReplaceError;

    /// Abandon this atomic write and release its temporary resources.
    pub fn deinit(self: *AtomicFile) void {
        self.inner.deinit(currentIo());
    }

    /// Flush buffered data and atomically replace the destination file.
    pub fn finish(self: *AtomicFile) FinishError!void {
        self.file_writer.interface.flush() catch |err| switch (err) {
            error.WriteFailed => return self.file_writer.err.?,
        };
        try self.inner.replace(currentIo());
    }
};

/// Directory handle bound to the active root I/O capability.
pub const Dir = struct {
    d: std.Io.Dir,

    pub const AccessError = std.Io.Dir.AccessError;
    pub const CopyFileError = std.Io.Dir.CopyFileError;
    pub const DeleteFileError = std.Io.Dir.DeleteFileError;
    pub const MakeError = std.Io.Dir.CreateDirPathError;
    pub const OpenError = std.Io.Dir.OpenError;
    pub const RenameError = std.Io.Dir.RenameError;
    pub const StatFileError = std.Io.Dir.StatFileError;

    /// Close this directory handle.
    pub fn close(self: Dir) void {
        self.d.close(currentIo());
    }

    /// Read a bounded file into allocator-owned memory.
    pub fn readFileAlloc(self: Dir, allocator: std.mem.Allocator, sub_path: []const u8, max: usize) std.Io.Dir.ReadFileAllocError![]u8 {
        return self.d.readFileAlloc(currentIo(), sub_path, allocator, .limited64(max));
    }

    /// Check whether `sub_path` satisfies the requested access mode.
    pub fn access(self: Dir, sub_path: []const u8, options: std.Io.Dir.AccessOptions) AccessError!void {
        return self.d.access(currentIo(), sub_path, options);
    }

    /// Open a child directory with the supplied iteration options.
    pub fn openDir(self: Dir, sub_path: []const u8, options: std.Io.Dir.OpenOptions) OpenError!Dir {
        return .{ .d = try self.d.openDir(currentIo(), sub_path, options) };
    }

    /// Open an existing child file.
    pub fn openFile(self: Dir, sub_path: []const u8, options: std.Io.Dir.OpenFileOptions) File.OpenError!File {
        return .{ .f = try self.d.openFile(currentIo(), sub_path, options) };
    }

    /// Create or replace a child file according to `options`.
    pub fn createFile(self: Dir, sub_path: []const u8, options: std.Io.Dir.CreateFileOptions) File.OpenError!File {
        return .{ .f = try self.d.createFile(currentIo(), sub_path, options) };
    }

    /// Write an entire child file in one operation.
    pub fn writeFile(self: Dir, options: std.Io.Dir.WriteFileOptions) std.Io.Dir.WriteFileError!void {
        return self.d.writeFile(currentIo(), options);
    }

    /// Start non-recursive iteration over this directory.
    pub fn iterate(self: Dir) Iterator {
        return .{ .it = self.d.iterate() };
    }

    /// Start recursive iteration with allocator-owned traversal state.
    pub fn walk(self: Dir, allocator: std.mem.Allocator) std.mem.Allocator.Error!Walker {
        return .{ .walker = try self.d.walk(allocator) };
    }

    /// Read metadata for a child path.
    pub fn statFile(self: Dir, sub_path: []const u8) StatFileError!std.Io.Dir.Stat {
        return self.d.statFile(currentIo(), sub_path, .{});
    }

    /// Create a directory path and any missing parents.
    pub fn makePath(self: Dir, sub_path: []const u8) MakeError!void {
        return self.d.createDirPath(currentIo(), sub_path);
    }

    /// Delete one child file.
    pub fn deleteFile(self: Dir, sub_path: []const u8) DeleteFileError!void {
        return self.d.deleteFile(currentIo(), sub_path);
    }

    /// Recursively delete one child path.
    pub fn deleteTree(self: Dir, sub_path: []const u8) std.Io.Dir.DeleteTreeError!void {
        return self.d.deleteTree(currentIo(), sub_path);
    }

    /// Rename a child path within this directory.
    pub fn rename(self: Dir, old_sub_path: []const u8, new_sub_path: []const u8) RenameError!void {
        return self.d.rename(old_sub_path, self.d, new_sub_path, currentIo());
    }

    /// Copy one child file into another directory.
    pub fn copyFile(
        self: Dir,
        source_path: []const u8,
        dest_dir: Dir,
        dest_path: []const u8,
        options: std.Io.Dir.CopyFileOptions,
    ) CopyFileError!void {
        return self.d.copyFile(source_path, dest_dir.d, dest_path, currentIo(), options);
    }

    /// Begin an atomic replacement transaction for a child file.
    pub fn atomicFile(self: Dir, sub_path: []const u8, options: AtomicFileOptions) AtomicFile.InitError!AtomicFile {
        const inner = try self.d.createFileAtomic(currentIo(), sub_path, .{ .replace = true });
        return .{
            .file_writer = inner.file.writer(currentIo(), options.write_buffer),
            .inner = inner,
        };
    }
};

/// Return the process working-directory handle.
pub fn cwd() Dir {
    return .{ .d = .cwd() };
}
