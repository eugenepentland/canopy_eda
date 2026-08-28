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

const Sha256 = std.crypto.hash.sha2.Sha256;

const ReadState = enum { bytes, exists, alias, absent };

/// One immutable file image actually returned to a release evaluator/parser.
const ReadTraceEntry = struct {
    path: []const u8,
    sha256: [Sha256.digest_length]u8,
    size: usize,
    state: ReadState = .bytes,
};

const DirectoryMember = struct {
    name: []const u8,
    kind: std.Io.File.Kind,
};

const DirectoryTrace = struct {
    path: []const u8,
    members: std.ArrayList(DirectoryMember) = .empty,
    complete: bool = false,
};

/// Per-thread trace of exact filesystem bytes consumed by a release snapshot.
/// Request evaluation is synchronous on one worker thread. A second scope on
/// the same thread invalidates both traces instead of stealing the ambient
/// filesystem capability; no trace may outlive or move away from its owner
/// thread.
pub const ReadTrace = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(ReadTraceEntry) = .empty,
    directories: std.ArrayList(DirectoryTrace) = .empty,
    consistent: bool = true,
    owner_thread: ?std.Thread.Id = null,
    started: bool = false,

    /// Create an inactive trace that owns all recorded path and digest data.
    pub fn init(allocator: std.mem.Allocator) ReadTrace {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ReadTrace) void {
        if (self.started) self.end();
        for (self.entries.items) |entry| self.allocator.free(entry.path);
        self.entries.deinit(self.allocator);
        for (self.directories.items) |*directory| {
            self.allocator.free(directory.path);
            for (directory.members.items) |member| self.allocator.free(member.name);
            directory.members.deinit(self.allocator);
        }
        self.directories.deinit(self.allocator);
    }

    /// Begin tracing reads on this request thread.
    pub fn begin(self: *ReadTrace) void {
        if (self.started or active_read_trace != null) {
            self.consistent = false;
            if (active_read_trace) |active| active.consistent = false;
            return;
        }
        self.owner_thread = std.Thread.getCurrentId();
        self.started = true;
        active_read_trace = self;
    }

    /// Stop tracing on the same owner thread that began this request scope.
    pub fn end(self: *ReadTrace) void {
        if (!self.started) return;
        if (self.owner_thread == null or self.owner_thread.? != std.Thread.getCurrentId() or active_read_trace != self) {
            self.consistent = false;
            return;
        }
        active_read_trace = null;
        self.owner_thread = null;
        self.started = false;
    }

    fn record(self: *ReadTrace, path: []const u8, bytes: []const u8) std.mem.Allocator.Error!void {
        var content_digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(bytes, &content_digest, .{});
        for (self.entries.items) |*entry| {
            if (!std.mem.eql(u8, entry.path, path)) continue;
            if (entry.state == .absent) {
                self.consistent = false;
            } else if (entry.state == .exists) {
                entry.state = .bytes;
                entry.sha256 = content_digest;
                entry.size = bytes.len;
            } else if (entry.size != bytes.len or !std.mem.eql(u8, &entry.sha256, &content_digest)) {
                self.consistent = false;
            }
            return;
        }
        try self.entries.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, path),
            .sha256 = content_digest,
            .size = bytes.len,
        });
    }

    fn recordState(self: *ReadTrace, path: []const u8, state: ReadState) std.mem.Allocator.Error!void {
        for (self.entries.items) |entry| {
            if (!std.mem.eql(u8, entry.path, path)) continue;
            const stronger_presence = (entry.state == .bytes or entry.state == .alias) and state == .exists;
            if (entry.state != state and !stronger_presence) self.consistent = false;
            return;
        }
        try self.entries.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, path),
            .sha256 = @splat(0),
            .size = 0,
            .state = state,
        });
    }

    fn logicalPath(self: *ReadTrace, dir: std.Io.Dir, sub_path: []const u8) ?[]u8 {
        var absolute_base: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const base_len = dir.realPathFile(currentIo(), ".", &absolute_base) catch {
            self.consistent = false;
            return null;
        };
        return std.fs.path.resolve(self.allocator, &.{ absolute_base[0..base_len], sub_path }) catch {
            self.consistent = false;
            return null;
        };
    }

    fn recordCandidate(self: *ReadTrace, dir: std.Io.Dir, sub_path: []const u8, state: ReadState) void {
        const candidate = self.logicalPath(dir, sub_path) orelse return;
        defer self.allocator.free(candidate);
        self.recordState(candidate, state) catch {
            self.consistent = false;
        };
    }

    fn recordResolution(self: *ReadTrace, dir: std.Io.Dir, sub_path: []const u8, resolved: []const u8) void {
        const logical = self.logicalPath(dir, sub_path) orelse return;
        defer self.allocator.free(logical);
        if (std.mem.eql(u8, logical, resolved)) return;
        var target_digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(resolved, &target_digest, .{});
        for (self.entries.items) |*entry| {
            if (!std.mem.eql(u8, entry.path, logical)) continue;
            if (entry.state == .exists) {
                entry.state = .alias;
                entry.sha256 = target_digest;
                entry.size = resolved.len;
            } else if (entry.state != .alias or entry.size != resolved.len or !std.mem.eql(u8, &entry.sha256, &target_digest)) {
                self.consistent = false;
            }
            return;
        }
        self.entries.append(self.allocator, .{
            .path = self.allocator.dupe(u8, logical) catch {
                self.consistent = false;
                return;
            },
            .sha256 = target_digest,
            .size = resolved.len,
            .state = .alias,
        }) catch {
            self.consistent = false;
        };
    }

    fn beginDirectory(self: *ReadTrace, dir: std.Io.Dir) ?usize {
        var absolute_path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_len = dir.realPathFile(currentIo(), ".", &absolute_path) catch {
            self.consistent = false;
            return null;
        };
        const path = self.allocator.dupe(u8, absolute_path[0..path_len]) catch {
            self.consistent = false;
            return null;
        };
        self.directories.append(self.allocator, .{ .path = path }) catch {
            self.allocator.free(path);
            self.consistent = false;
            return null;
        };
        return self.directories.items.len - 1;
    }

    fn directoryMember(self: *ReadTrace, index: usize, entry: std.Io.Dir.Entry) void {
        const name = self.allocator.dupe(u8, entry.name) catch {
            self.consistent = false;
            return;
        };
        self.directories.items[index].members.append(self.allocator, .{ .name = name, .kind = entry.kind }) catch {
            self.allocator.free(name);
            self.consistent = false;
        };
    }

    fn finishDirectory(self: *ReadTrace, index: usize, complete: bool) void {
        self.directories.items[index].complete = complete;
        if (!complete) self.consistent = false;
    }

    /// Canonical digest of the exact path+byte identities that were consumed.
    pub fn digest(self: *const ReadTrace) [64]u8 {
        var hash = Sha256.init(.{});
        var previous: ?[]const u8 = null;
        for (0..self.entries.items.len) |_| {
            var next: ?*const ReadTraceEntry = null;
            for (self.entries.items) |*entry| {
                if (previous) |path| {
                    if (std.mem.order(u8, entry.path, path) != .gt) continue;
                }
                if (next) |selected| {
                    if (std.mem.order(u8, entry.path, selected.path) != .lt) continue;
                }
                next = entry;
            }
            const entry = next orelse break;
            var length: [8]u8 = undefined;
            std.mem.writeInt(u64, &length, @intCast(entry.path.len), .little);
            hash.update(&length);
            hash.update(entry.path);
            hash.update(@tagName(entry.state));
            hash.update(&entry.sha256);
            previous = entry.path;
        }
        previous = null;
        for (0..self.directories.items.len) |_| {
            var next: ?*const DirectoryTrace = null;
            for (self.directories.items) |*directory| {
                if (previous) |path| {
                    if (std.mem.order(u8, directory.path, path) != .gt) continue;
                }
                if (next) |selected| {
                    if (std.mem.order(u8, directory.path, selected.path) != .lt) continue;
                }
                next = directory;
            }
            const directory = next orelse break;
            hash.update("directory");
            hash.update(directory.path);
            var member_previous: ?[]const u8 = null;
            for (0..directory.members.items.len) |_| {
                var member_next: ?*const DirectoryMember = null;
                for (directory.members.items) |*member| {
                    if (member_previous) |name| {
                        if (std.mem.order(u8, member.name, name) != .gt) continue;
                    }
                    if (member_next) |selected| {
                        if (std.mem.order(u8, member.name, selected.name) != .lt) continue;
                    }
                    member_next = member;
                }
                const member = member_next orelse break;
                hash.update(member.name);
                hash.update(@tagName(member.kind));
                member_previous = member.name;
            }
            previous = directory.path;
        }
        var digest_bytes: [Sha256.digest_length]u8 = undefined;
        hash.final(&digest_bytes);
        return std.fmt.bytesToHex(digest_bytes, .lower);
    }

    /// Digest recorded for one exact absolute path, when it was consumed.
    pub fn digestForPath(self: *const ReadTrace, path: []const u8) ?[64]u8 {
        for (self.entries.items) |entry| {
            if (!std.mem.eql(u8, entry.path, path)) continue;
            if (entry.state != .bytes) return null;
            return std.fmt.bytesToHex(entry.sha256, .lower);
        }
        return null;
    }

    /// Canonical closure digest for a named set of expected input paths.
    pub fn closureDigest(self: *const ReadTrace, paths: []const []const u8) [64]u8 {
        var hash = Sha256.init(.{});
        for (paths) |path| {
            var length: [8]u8 = undefined;
            std.mem.writeInt(u64, &length, @intCast(path.len), .little);
            hash.update(&length);
            hash.update(path);
            if (self.digestForPath(path)) |content| hash.update(&content) else hash.update("not-consumed");
        }
        var digest_bytes: [Sha256.digest_length]u8 = undefined;
        hash.final(&digest_bytes);
        return std.fmt.bytesToHex(digest_bytes, .lower);
    }

    /// Re-read every consumed path and prove it still has the exact bytes the
    /// parser saw. Call only after `end`, so verification reads are not traced.
    pub fn verify(self: *const ReadTrace) bool {
        if (!self.consistent or self.entries.items.len == 0) return false;
        for (self.entries.items) |entry| {
            if (entry.state == .absent) {
                std.Io.Dir.cwd().access(currentIo(), entry.path, .{}) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return false,
                };
                return false;
            }
            if (entry.state == .exists) {
                std.Io.Dir.cwd().access(currentIo(), entry.path, .{}) catch return false;
                continue;
            }
            if (entry.state == .alias) {
                var resolved: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const resolved_len = std.Io.Dir.cwd().realPathFile(currentIo(), entry.path, &resolved) catch return false;
                var target_digest: [Sha256.digest_length]u8 = undefined;
                Sha256.hash(resolved[0..resolved_len], &target_digest, .{});
                if (resolved_len != entry.size or !std.mem.eql(u8, &entry.sha256, &target_digest)) return false;
                continue;
            }
            const limit = std.math.add(usize, entry.size, 1) catch return false;
            const current = std.Io.Dir.cwd().readFileAlloc(currentIo(), entry.path, self.allocator, .limited64(limit)) catch return false;
            defer self.allocator.free(current);
            var current_digest: [Sha256.digest_length]u8 = undefined;
            Sha256.hash(current, &current_digest, .{});
            if (current.len != entry.size or !std.mem.eql(u8, &entry.sha256, &current_digest)) return false;
        }
        for (self.directories.items) |directory| {
            if (!directory.complete) return false;
            var current = std.Io.Dir.cwd().openDir(currentIo(), directory.path, .{ .iterate = true }) catch return false;
            defer current.close(currentIo());
            var iterator = current.iterate();
            var count: usize = 0;
            while (iterator.next(currentIo()) catch return false) |entry| {
                count += 1;
                var found = false;
                for (directory.members.items) |member| {
                    if (member.kind == entry.kind and std.mem.eql(u8, member.name, entry.name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) return false;
            }
            if (count != directory.members.items.len) return false;
        }
        return true;
    }
};

// Release evaluation is synchronous inside one server/MCP handler. The
// filesystem adapter is intentionally the sole owner of this thread-local
// capability because threading it through every parser would let untraced
// fallback readers coexist with traced ones. ReadTrace.begin/end enforce
// single-scope, owner-thread, and bounded-lifetime invariants; Guardian pins the
// identifier to this file so container nesting cannot hide another instance.
threadlocal var active_read_trace: ?*ReadTrace = null;

/// Return the active I/O capability. Tests use the runner-owned capability;
/// executable roots expose the one supplied by `std.process.Init`.
pub fn currentIo() std.Io {
    if (builtin.is_test) return std.testing.io;
    return @import("root").process_io;
}

// spec: fabrication-release - consumed-input closure identity is independent of filesystem read order
test "read trace digest sorts canonical paths" {
    var first = ReadTrace.init(std.testing.allocator);
    defer first.deinit();
    try first.record("/project/src/design.sexp", "source");
    try first.record("/project/src/design.bom", "bom");

    var second = ReadTrace.init(std.testing.allocator);
    defer second.deinit();
    try second.record("/project/src/design.bom", "bom");
    try second.record("/project/src/design.sexp", "source");

    try std.testing.expectEqual(first.digest(), second.digest());
}

test "nested read traces invalidate both scopes without stealing reads" {
    var outer = ReadTrace.init(std.testing.allocator);
    defer outer.deinit();
    var inner = ReadTrace.init(std.testing.allocator);
    defer inner.deinit();
    outer.begin();
    defer outer.end();
    inner.begin();
    try std.testing.expect(active_read_trace == &outer);
    try std.testing.expect(!outer.consistent);
    try std.testing.expect(!inner.consistent);
    inner.end();
    try std.testing.expect(active_read_trace == &outer);
}

fn endTraceOffOwnerThread(trace: *ReadTrace) void {
    trace.end();
}

test "read trace rejects an end call away from its owner thread" {
    var trace = ReadTrace.init(std.testing.allocator);
    defer trace.deinit();
    trace.begin();
    const other = try std.Thread.spawn(.{}, endTraceOffOwnerThread, .{&trace});
    other.join();
    try std.testing.expect(!trace.consistent);
    try std.testing.expect(trace.started);
    trace.end();
    try std.testing.expect(!trace.started);
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

    /// Write every byte at `offset`, leaving what precedes it untouched.
    ///
    /// This is how an append-only log line is added: `writeAll` streams from
    /// the handle's own position, which is 0 on a file opened with
    /// `.truncate = false`, so it would overwrite the head of the file instead
    /// of extending it. Positioned writes leave the handle's cursor alone,
    /// which also makes the call safe to repeat on one handle.
    pub fn writeAllAt(self: File, bytes: []const u8, offset: u64) std.Io.File.WritePositionalError!void {
        return self.f.writePositionalAll(currentIo(), bytes, offset);
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
    trace: ?*ReadTrace = null,
    directory_index: ?usize = null,
    finished: bool = false,

    pub const Error = std.Io.Dir.Iterator.Error;

    /// Return the next directory entry, or null after the final entry.
    pub fn next(self: *Iterator) Error!?std.Io.Dir.Entry {
        const entry = self.it.next(currentIo()) catch |err| {
            if (!self.finished) if (self.trace) |trace| if (self.directory_index) |index| {
                trace.finishDirectory(index, false);
                self.finished = true;
            };
            return err;
        };
        if (entry) |value| {
            if (self.trace) |trace| if (self.directory_index) |index| trace.directoryMember(index, value);
        } else if (!self.finished) {
            if (self.trace) |trace| if (self.directory_index) |index| trace.finishDirectory(index, true);
            self.finished = true;
        }
        return entry;
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
    trace_membership: bool = false,

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
        const bytes = self.d.readFileAlloc(currentIo(), sub_path, allocator, .limited64(max)) catch |err| {
            if (active_read_trace) |trace| switch (err) {
                error.FileNotFound => trace.recordCandidate(self.d, sub_path, .absent),
                else => trace.consistent = false,
            };
            return err;
        };
        errdefer allocator.free(bytes);
        if (active_read_trace) |trace| {
            trace.recordCandidate(self.d, sub_path, .exists);
            // Resolve through this exact directory handle after the successful
            // read. This preserves the identity of child-Dir reads such as
            // `lib/modules/<entry>.sexp`; recording only `entry.name` (or
            // omitting it) would let transient library bytes escape the
            // release snapshot. A resolution failure leaves ordinary reads
            // compatible, but makes the manufacturing trace fail closed.
            var absolute_path: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const path_len = self.d.realPathFile(currentIo(), sub_path, &absolute_path) catch {
                trace.consistent = false;
                return bytes;
            };
            trace.recordResolution(self.d, sub_path, absolute_path[0..path_len]);
            try trace.record(absolute_path[0..path_len], bytes);
        }
        return bytes;
    }

    /// Check whether `sub_path` satisfies the requested access mode.
    pub fn access(self: Dir, sub_path: []const u8, options: std.Io.Dir.AccessOptions) AccessError!void {
        self.d.access(currentIo(), sub_path, options) catch |err| {
            if (active_read_trace) |trace| switch (err) {
                error.FileNotFound => trace.recordCandidate(self.d, sub_path, .absent),
                else => trace.consistent = false,
            };
            return err;
        };
        if (active_read_trace) |trace| {
            trace.recordCandidate(self.d, sub_path, .exists);
            var absolute_path: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const path_len = self.d.realPathFile(currentIo(), sub_path, &absolute_path) catch {
                trace.consistent = false;
                return;
            };
            trace.recordResolution(self.d, sub_path, absolute_path[0..path_len]);
            trace.recordState(absolute_path[0..path_len], .exists) catch {
                trace.consistent = false;
            };
        }
    }

    /// Open a child directory with the supplied iteration options.
    pub fn openDir(self: Dir, sub_path: []const u8, options: std.Io.Dir.OpenOptions) OpenError!Dir {
        const opened = self.d.openDir(currentIo(), sub_path, options) catch |err| {
            if (active_read_trace) |trace| switch (err) {
                error.FileNotFound => trace.recordCandidate(self.d, sub_path, .absent),
                else => trace.consistent = false,
            };
            return err;
        };
        if (active_read_trace) |trace| {
            trace.recordCandidate(self.d, sub_path, .exists);
            var resolved: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const resolved_len = opened.realPathFile(currentIo(), ".", &resolved) catch {
                trace.consistent = false;
                return .{ .d = opened };
            };
            trace.recordResolution(self.d, sub_path, resolved[0..resolved_len]);
        }
        return .{
            .d = opened,
            .trace_membership = std.mem.endsWith(u8, sub_path, "lib/modules") or
                std.mem.endsWith(u8, sub_path, "lib\\modules"),
        };
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
        const trace = if (self.trace_membership) active_read_trace else null;
        return .{
            .it = self.d.iterate(),
            .trace = trace,
            .directory_index = if (trace) |value| value.beginDirectory(self.d) else null,
        };
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

/// Resolve an existing path to the same canonical absolute spelling used by
/// `ReadTrace` entries.
pub fn canonicalPathAlloc(allocator: std.mem.Allocator, path: []const u8) std.Io.Dir.RealPathFileAllocError![:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(currentIo(), path, allocator);
}

// spec: fabrication-release - exact read tracing retains child-directory identity and rejects an A/B/A byte sequence
test "read trace binds child Dir bytes and detects ABA consumption" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/modules");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/modules/demo.sexp", .data = "A" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const modules_path = try std.fs.path.join(allocator, &.{ root, "lib/modules" });
    const file_path = try std.fs.path.join(allocator, &.{ modules_path, "demo.sexp" });
    var modules = try cwd().openDir(modules_path, .{ .iterate = true });
    defer modules.close();

    var stable = ReadTrace.init(allocator);
    defer stable.deinit();
    stable.begin();
    const first = try modules.readFileAlloc(allocator, "demo.sexp", 16);
    stable.end();
    try std.testing.expectEqualStrings("A", first);
    try std.testing.expect(stable.digestForPath(file_path) != null);
    try std.testing.expect(stable.verify());

    var aba = ReadTrace.init(allocator);
    defer aba.deinit();
    aba.begin();
    _ = try modules.readFileAlloc(allocator, "demo.sexp", 16);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/modules/demo.sexp", .data = "B" });
    _ = try modules.readFileAlloc(allocator, "demo.sexp", 16);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/modules/demo.sexp", .data = "A" });
    aba.end();
    try std.testing.expect(!aba.consistent);
    try std.testing.expect(!aba.verify());
}

// spec: fabrication-release - release tracing binds directory membership and absent optional inputs to the exact evaluated snapshot
test "read trace rejects directory and negative-dependency ABA" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/modules");
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/modules/stable.sexp", .data = "stable" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/modules/policy.sexp", .data = "policy" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const modules_path = try std.fs.path.join(allocator, &.{ root, "lib/modules" });
    const stable_path = try std.fs.path.join(allocator, &.{ modules_path, "stable.sexp" });
    const checks_path = try std.fs.path.join(allocator, &.{ root, "src/board.checks.sexp" });

    var directory_aba = ReadTrace.init(allocator);
    defer directory_aba.deinit();
    directory_aba.begin();
    _ = try cwd().readFileAlloc(allocator, stable_path, 64);
    try tmp.dir.deleteFile(std.testing.io, "lib/modules/policy.sexp");
    var modules = try cwd().openDir(modules_path, .{ .iterate = true });
    var iterator = modules.iterate();
    while (try iterator.next()) |_| {}
    modules.close();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/modules/policy.sexp", .data = "policy" });
    directory_aba.end();
    try std.testing.expect(!directory_aba.verify());

    var negative_aba = ReadTrace.init(allocator);
    defer negative_aba.deinit();
    negative_aba.begin();
    _ = try cwd().readFileAlloc(allocator, stable_path, 64);
    try std.testing.expectError(error.FileNotFound, cwd().access(checks_path, .{}));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/board.checks.sexp", .data = "(assert true)" });
    negative_aba.end();
    try std.testing.expect(!negative_aba.verify());
}

fn consumeDirectoryMembership(path: []const u8) !void {
    var directory = try cwd().openDir(path, .{ .iterate = true });
    defer directory.close();
    var iterator = directory.iterate();
    while (try iterator.next()) |_| {}
}

// spec: fabrication-release - logical file and directory aliases retain their exact resolved target through release verification
test "read trace rejects symlink removal and retargeting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.createDirPath(std.testing.io, "lib/module-set-a");
    try tmp.dir.createDirPath(std.testing.io, "lib/module-set-b");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/a.sexp", .data = "same" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/b.sexp", .data = "same" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/module-set-a/policy.sexp", .data = "same" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/module-set-b/policy.sexp", .data = "same" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    const alias_path = try std.fs.path.join(allocator, &.{ root, "lib/components/alias.sexp" });
    const modules_path = try std.fs.path.join(allocator, &.{ root, "lib/modules" });

    try tmp.dir.symLink(std.testing.io, "a.sexp", "lib/components/alias.sexp", .{});
    var stable_file = ReadTrace.init(allocator);
    defer stable_file.deinit();
    stable_file.begin();
    _ = try cwd().readFileAlloc(allocator, alias_path, 64);
    stable_file.end();
    try std.testing.expect(stable_file.verify());

    var file_removed = ReadTrace.init(allocator);
    defer file_removed.deinit();
    file_removed.begin();
    _ = try cwd().readFileAlloc(allocator, alias_path, 64);
    try tmp.dir.deleteFile(std.testing.io, "lib/components/alias.sexp");
    file_removed.end();
    try std.testing.expect(!file_removed.verify());

    try tmp.dir.symLink(std.testing.io, "a.sexp", "lib/components/alias.sexp", .{});
    var file_retargeted = ReadTrace.init(allocator);
    defer file_retargeted.deinit();
    file_retargeted.begin();
    _ = try cwd().readFileAlloc(allocator, alias_path, 64);
    try tmp.dir.deleteFile(std.testing.io, "lib/components/alias.sexp");
    try tmp.dir.symLink(std.testing.io, "b.sexp", "lib/components/alias.sexp", .{});
    file_retargeted.end();
    try std.testing.expect(!file_retargeted.verify());
    try tmp.dir.deleteFile(std.testing.io, "lib/components/alias.sexp");

    try tmp.dir.symLink(std.testing.io, "module-set-a", "lib/modules", .{ .is_directory = true });
    var stable_directory = ReadTrace.init(allocator);
    defer stable_directory.deinit();
    stable_directory.begin();
    try consumeDirectoryMembership(modules_path);
    stable_directory.end();
    try std.testing.expect(stable_directory.verify());

    var directory_removed = ReadTrace.init(allocator);
    defer directory_removed.deinit();
    directory_removed.begin();
    try consumeDirectoryMembership(modules_path);
    try tmp.dir.deleteFile(std.testing.io, "lib/modules");
    directory_removed.end();
    try std.testing.expect(!directory_removed.verify());

    try tmp.dir.symLink(std.testing.io, "module-set-a", "lib/modules", .{ .is_directory = true });
    var directory_retargeted = ReadTrace.init(allocator);
    defer directory_retargeted.deinit();
    directory_retargeted.begin();
    try consumeDirectoryMembership(modules_path);
    try tmp.dir.deleteFile(std.testing.io, "lib/modules");
    try tmp.dir.symLink(std.testing.io, "module-set-b", "lib/modules", .{ .is_directory = true });
    directory_retargeted.end();
    try std.testing.expect(!directory_retargeted.verify());
}
