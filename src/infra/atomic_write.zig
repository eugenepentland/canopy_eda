//! Atomic file replacement: the one writer for the hand-authored files the
//! server rewrites in place — `src/<design>.sexp`, `lib/components/<part>.sexp`
//! and the `<design>.notes.md` sidecar.
//!
//! The hazard this closes: `createFile(path, .{})` TRUNCATES the target to zero
//! length, and the `writeAll` that refills it is a separate syscall. A crash, an
//! OOM, a short write, a full disk — or the `pkill netlisp` habit the deploy
//! notes bless — landing between the two leaves the user's design empty or half
//! written, and the previous bytes are unrecoverable: these files are the source
//! of truth, and the schematic, the netlist, the BOM and the board are all
//! derived from them. Here every write is staged in a temporary file in the
//! target's OWN directory, fsync'd, and only then renamed over the target. A
//! rename within one filesystem is atomic, so every reader — and every crash —
//! sees either all of the old bytes or all of the new ones, never a prefix. The
//! temporary has to be a sibling precisely because rename is atomic only within
//! a filesystem, and only a sibling is guaranteed to share one.
//!
//! This WRAPS `infra/fs.zig`'s `AtomicFile` rather than owning a second
//! tmp+rename of its own:
//!   * `infra/fs.zig` is this tree's I/O capability boundary — where
//!     `currentIo()` and the fabrication-release read trace live. A private
//!     `createFile` + `rename` pair here would be a second, untraced filesystem
//!     path in a tree that deliberately has exactly one.
//!   * its temporary name is a fresh random `u64`, retried on collision, and is
//!     created in the destination's directory already. That is strictly stronger
//!     than the pid+counter name this module would otherwise have to mint.
//!   * its `deinit` closes and unlinks the temporary on every failure path, so
//!     an abandoned write leaves no residue to be mistaken for a design file.
//! The one thing it does not do is fsync: `AtomicFile.finish` flushes the writer
//! and renames, which orders the bytes against other PROCESSES but not against a
//! power loss — the rename can reach the disk before the data does. That single
//! missing step is what this module adds, so everything else stays shared rather
//! than copied. Copying is the mistake the eight hand-rolled tmp+rename variants
//! in this tree already made, and `serve/board_backup.zig`'s fixed `<path>.tmp`
//! is what it costs: two concurrent writers of one path collide on that name.
//!
//! What this does NOT give you is mutual exclusion. Atomicity means no reader
//! ever sees a torn file; it says nothing about two writers that each read the
//! same source, each edit their own copy, and each rename. The second rename
//! wins whole and the first edit is silently lost. Serialising the
//! read-modify-write of one design needs a lock keyed by design path, which
//! belongs above this module, not in it.
//!
//! Usage:
//!     const atomic_write = @import("../infra/atomic_write.zig");
//!     try atomic_write.writeFile(path, new_source);

const std = @import("std");
const infra_fs = @import("fs.zig");
const log = @import("log.zig");

/// Staging buffer for the writer that fronts the temporary file, sized like the
/// other staged writers in this tree (`id_insert.zig`). A slice larger than the
/// buffer is handed to the file in one go rather than copied through it, so this
/// only bounds the syscall count for small writes; it is not a size limit.
const write_buffer_bytes: usize = 4 * 1024;

/// Misuse of the staging API: `write` or `commit` on a `Staged` whose `begin`
/// never succeeded. Returned rather than asserted so a mistake surfaces as one
/// failed save instead of a killed server process.
pub const StageError = error{NotStaged};

/// Opening the temporary failed — same causes as opening the target itself
/// would have had (missing directory, permissions, no space, read-only mount).
pub const InitError = infra_fs.AtomicFile.InitError;
/// Staging bytes failed. The target has not been touched.
pub const WriteError = infra_fs.File.WriteError || StageError;
/// The final flush or the rename failed. The target still holds its old bytes.
pub const CommitError = infra_fs.AtomicFile.FinishError || StageError;

/// Everything `writeFile` can fail with.
pub const Error = InitError || WriteError || CommitError;

/// One staged replacement of one file: bytes go to a sibling temporary until
/// `commit` renames it over the target.
///
/// The writer's buffer lives inline, so a `Staged` must be initialised in place
/// (`var staged: Staged = .{}; try staged.begin(path);`) and must not be copied
/// or moved once `begin` has succeeded — the writer points into `buffer`.
pub const Staged = struct {
    /// Zero-initialised rather than `undefined`: this is the writer's staging
    /// buffer, so it is written before it is read either way, and a definite
    /// value keeps the module clear of the unsafe-ops budget. At 4 KiB the
    /// clear is far below the cost of the file write and fsync that follow.
    buffer: [write_buffer_bytes]u8 = std.mem.zeroes([write_buffer_bytes]u8),
    /// Non-null exactly between a successful `begin` and whichever of
    /// `commit`/`abandon` closes the transaction. The optional IS the open
    /// flag: it makes "no transaction" unrepresentable as a live `AtomicFile`
    /// rather than tracking validity in a parallel bool, and it guards the
    /// double-`deinit` that would otherwise follow a `defer abandon()` after a
    /// successful `commit`.
    af: ?infra_fs.AtomicFile = null,

    /// Open the sibling temporary that will become `path`. Fails exactly where
    /// `createFile` would: a missing parent directory is `error.FileNotFound`,
    /// nothing here creates directories.
    pub fn begin(self: *Staged, path: []const u8) InitError!void {
        self.af = try infra_fs.cwd().atomicFile(path, .{ .write_buffer = &self.buffer });
    }

    /// Stage `bytes`. Nothing is visible at the target until `commit`, so a
    /// caller may write in as many pieces as it likes.
    pub fn write(self: *Staged, bytes: []const u8) WriteError!void {
        const af = if (self.af) |*a| a else return error.NotStaged;
        af.file_writer.interface.writeAll(bytes) catch |err| switch (err) {
            // The generic writer erases the cause; `file_writer.err` kept it.
            error.WriteFailed => return af.file_writer.err.?,
        };
    }

    /// Flush, fsync, then rename the temporary over the target. On any failure
    /// the transaction stays open so a `defer abandon()` still unlinks the
    /// temporary, and the target keeps its previous contents.
    pub fn commit(self: *Staged) CommitError!void {
        const af = if (self.af) |*a| a else return error.NotStaged;
        // Flush first: buffered bytes are not in the file yet, and fsync only
        // makes durable what the file already holds.
        af.file_writer.interface.flush() catch |err| switch (err) {
            error.WriteFailed => return af.file_writer.err.?,
        };
        // Durability before visibility. Without this the rename can reach the
        // disk ahead of the data and a power loss publishes a file whose
        // contents were never written. Best-effort, matching
        // `serve/board_backup.zig`: a filesystem that does not implement fsync
        // (the in-memory ones some sandboxes mount) must not fail a user's save
        // for a reason the user cannot act on — the rename is still atomic
        // there, only its durability is the filesystem's problem.
        const staged_file = infra_fs.File{ .f = af.inner.file };
        staged_file.sync() catch |e| log.warn(
            "atomic write: fsync of the staged file failed: {s}",
            .{@errorName(e)},
        );
        // Re-flushes (a no-op now) and renames.
        try af.finish();
        // `finish` leaves the directory handle open; std's contract is to
        // `deinit` even after a successful finish.
        af.deinit();
        self.af = null;
    }

    /// Drop a staged write: close and unlink the temporary, leaving the target
    /// exactly as it was. A no-op after `commit` and on a `Staged` whose `begin`
    /// failed, so callers can `defer` it unconditionally.
    pub fn abandon(self: *Staged) void {
        const af = if (self.af) |*a| a else return;
        af.deinit();
        self.af = null;
    }
};

/// Replace `path` with exactly `bytes`, or leave it untouched.
///
/// Same contract as `createFile` + `writeAll` for permissions (a fresh file gets
/// the default mode) and for a missing parent directory (`error.FileNotFound`).
/// The difference is the failure mode: a failure anywhere leaves the previous
/// file whole instead of truncated.
pub fn writeFile(path: []const u8, bytes: []const u8) Error!void {
    var staged: Staged = .{};
    // Unconditional: a failed `begin` leaves nothing to clean up, a failed
    // `write`/`commit` unlinks the temporary, and a successful `commit` has
    // already closed the transaction.
    defer staged.abandon();
    try staged.begin(path);
    try staged.write(bytes);
    try staged.commit();
}

// ── tests ──────────────────────────────────────────────────────────

/// Test helper: absolute path to `name` inside `root`.
fn pathInForTest(arena: std.mem.Allocator, root: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ root, name });
}

/// Test helper: how many entries the directory holds. A staged write must leave
/// nothing behind it, so this count is the residue check — a temporary that
/// outlived its transaction shows up as an extra entry.
fn countEntriesForTest(dir: std.Io.Dir) !usize {
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(std.testing.io)) |_| n += 1;
    return n;
}

// spec: infra/atomic-write - writeFile replaces the target with exactly the new bytes, an empty body included
test "writeFile replaces the target with exactly the new bytes" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    const arena = aa.allocator();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const path = try pathInForTest(arena, root, "design.sexp");

    try writeFile(path, "(design-block \"A\")");
    try std.testing.expectEqualStrings(
        "(design-block \"A\")",
        try tmp.dir.readFileAlloc(std.testing.io, "design.sexp", arena, .limited64(1024)),
    );

    // A second write replaces the file rather than appending to or extending it,
    // and the shorter body must not leave a tail of the longer one behind.
    try writeFile(path, "(design-block \"B\" (note \"longer than the first\"))");
    try writeFile(path, "(design-block \"C\")");
    try std.testing.expectEqualStrings(
        "(design-block \"C\")",
        try tmp.dir.readFileAlloc(std.testing.io, "design.sexp", arena, .limited64(1024)),
    );

    // An empty body is a legal write — clearing a notes scratchpad produces one
    // — and must land as an empty file rather than be skipped as a no-op.
    try writeFile(path, "");
    try std.testing.expectEqualStrings(
        "",
        try tmp.dir.readFileAlloc(std.testing.io, "design.sexp", arena, .limited64(1024)),
    );
    try std.testing.expectEqual(@as(usize, 1), try countEntriesForTest(tmp.dir));
}

// spec: infra/atomic-write - an oversized body larger than the staging buffer lands whole
test "an oversized body larger than the staging buffer lands whole" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    const arena = aa.allocator();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const path = try pathInForTest(arena, root, "design.sexp");

    // Several buffers' worth plus a partial one: the buffer bounds the syscall
    // count, never the document size, and a real design source clears it easily.
    const big = try arena.alloc(u8, write_buffer_bytes * 3 + 7);
    for (big, 0..) |*b, i| b.* = @intCast('a' + i % 26);

    try writeFile(path, big);
    try std.testing.expectEqualStrings(
        big,
        try tmp.dir.readFileAlloc(std.testing.io, "design.sexp", arena, .limited64(1 << 20)),
    );
    try std.testing.expectEqual(@as(usize, 1), try countEntriesForTest(tmp.dir));
}

// spec: infra/atomic-write - a staged write abandoned before commit, or stopped by a write error, leaves the previous file contents intact
test "a staged write abandoned before commit leaves the previous contents intact" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    const arena = aa.allocator();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const path = try pathInForTest(arena, root, "design.sexp");
    const original = "(design-block \"Hand authored\" (instance \"R1\" (res \"10k\")))";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "design.sexp", .data = original });

    {
        var staged: Staged = .{};
        try staged.begin(path);
        // The prefix a truncating `createFile` + `writeAll` would have left as
        // the whole file if the process died here.
        try staged.write("(design-bl");
        try std.testing.expectEqualStrings(
            original,
            try tmp.dir.readFileAlloc(std.testing.io, "design.sexp", arena, .limited64(1024)),
        );
        // Stands in for the crash: the replacement is never committed.
        staged.abandon();
    }

    try std.testing.expectEqualStrings(
        original,
        try tmp.dir.readFileAlloc(std.testing.io, "design.sexp", arena, .limited64(1024)),
    );
    try std.testing.expectEqual(@as(usize, 1), try countEntriesForTest(tmp.dir));
}

// spec: infra/atomic-write - neither a committed nor an abandoned write leaves a temporary file behind
test "neither a committed nor an abandoned write leaves a temporary file behind" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    const arena = aa.allocator();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const path = try pathInForTest(arena, root, "design.sexp");

    try writeFile(path, "(design-block \"A\")");
    try std.testing.expectEqual(@as(usize, 1), try countEntriesForTest(tmp.dir));

    var staged: Staged = .{};
    try staged.begin(path);
    try staged.write("(design-block \"B\")");
    // The temporary is a real sibling file while the write is in flight …
    try std.testing.expectEqual(@as(usize, 2), try countEntriesForTest(tmp.dir));
    staged.abandon();
    // … and is unlinked when the transaction is dropped.
    try std.testing.expectEqual(@as(usize, 1), try countEntriesForTest(tmp.dir));

    // A `begin` that fails outright must not leave a stray temporary either.
    var missing: Staged = .{};
    const nowhere = try pathInForTest(arena, root, "no-such-dir/design.sexp");
    try std.testing.expectError(error.FileNotFound, missing.begin(nowhere));
    missing.abandon();
    try std.testing.expectEqual(@as(usize, 1), try countEntriesForTest(tmp.dir));
}

// spec: infra/atomic-write - write and commit on a Staged whose begin never succeeded return NotStaged with no panic
test "write and commit on a Staged whose begin never succeeded return NotStaged" {
    var staged: Staged = .{};
    // Must itself be a safe no-op: callers `defer` it before `begin` can fail.
    defer staged.abandon();
    try std.testing.expectError(error.NotStaged, staged.write("bytes"));
    try std.testing.expectError(error.NotStaged, staged.commit());
}

// spec: infra/atomic-write - two concurrent writers staging one target use distinct temporaries and the later commit wins whole
test "two concurrent writers staging one target use distinct temporaries and the later commit wins whole" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    const arena = aa.allocator();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const path = try pathInForTest(arena, root, "design.sexp");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "design.sexp", .data = "(design-block \"orig\")" });

    var first: Staged = .{};
    try first.begin(path);
    defer first.abandon();
    var second: Staged = .{};
    try second.begin(path);
    defer second.abandon();

    try first.write("(design-block \"first\")");
    try second.write("(design-block \"second\")");

    // Target plus one temporary per writer. A fixed `<path>.tmp` name — the
    // shape `serve/board_backup.zig` still carries — would have collided these
    // two into one file, and each writer would be appending into the other's.
    try std.testing.expectEqual(@as(usize, 3), try countEntriesForTest(tmp.dir));

    try first.commit();
    try std.testing.expectEqualStrings(
        "(design-block \"first\")",
        try tmp.dir.readFileAlloc(std.testing.io, "design.sexp", arena, .limited64(1024)),
    );

    // The second commit lands whole — and overwrites the first writer's edit
    // completely. Atomicity is not mutual exclusion: a lost update still needs a
    // lock held across the read-modify-write, above this module.
    try second.commit();
    try std.testing.expectEqualStrings(
        "(design-block \"second\")",
        try tmp.dir.readFileAlloc(std.testing.io, "design.sexp", arena, .limited64(1024)),
    );
    try std.testing.expectEqual(@as(usize, 1), try countEntriesForTest(tmp.dir));
}
