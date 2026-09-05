//! Background composition of the system-review HTML dossier.
//!
//! `GET /systems/:name/dossier` used to compose its document inside the
//! request. Composition is `system_review_package.draftDossierHtml`, whose cost
//! is a complete per-board review snapshot plus a complete fabrication
//! readiness pass (DRC included) for every board the system names — measured at
//! 50-57 s for the two-board Board A system, warm or cold, on the deployed
//! ReleaseSafe binary. A browser asked to wait that long simply looks broken.
//!
//! So the page no longer composes: it reads this store. One composed document
//! per system is retained here, composed on a detached thread, saved atomically
//! below `out/dossier-cache/`, and replaced whole when a newer one finishes.
//! The contract the page implements over it:
//!
//!   * a composed copy is served immediately, byte-identical to the
//!     `review/<base>.html` member of the same system's `draft.zip` — the store
//!     retains the composer's output and never edits it;
//!   * a copy older than `revalidate_after_ms` gets a cheap project-tree
//!     fingerprint check. Unchanged inputs renew it; changed inputs mark the
//!     last good document stale until a reader explicitly regenerates it;
//!   * a server restart rehydrates a checksum-valid copy from the same tool
//!     build, marking it stale when the project-tree fingerprint moved;
//!   * a system-review mutation (document save, asset upload, attestation)
//!     marks the retained copy stale and retires an in-flight composition;
//!   * exactly ONE compose per system is ever in flight. A reload during a
//!     compose joins it rather than starting a second minute of board analysis.
//!
//! A composed document, a failure, and an in-flight compose are all per-system
//! state, so a broken or slow system never blocks another one.
//!
//! `background` is the switch that turns thread spawning on, mirroring the
//! `allocator`-is-the-switch convention of the serve-layer caches: a
//! default-constructed store (every handler test's `ServerState`) composes
//! nothing and starts no thread, so a test drives `begin`/`finish` explicitly
//! instead of racing a detached minute of analysis against its own fixture
//! directory.

const std = @import("std");
const build_id = @import("../build_id.zig");
const githash = @import("../githash.zig");
const atomic_write = @import("../infra/atomic_write.zig");
const clock = @import("../infra/clock.zig");
const infra_fs = @import("../infra/fs.zig");
const log = @import("../infra/log.zig");
const paths = @import("../paths.zig");
const review_html = @import("../system_review_html.zig");
const warm_sched = @import("warm_sched.zig");
const system_review_package = @import("../system_review_package.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// The allocator every retained document and map key uses. A composed dossier
/// must outlive both the request that asked for it and the thread that produced
/// it, so neither a request arena nor the compose thread's own arena will do.
// allocator-ok: process-lifetime by necessity — see the paragraph above.
const durable = std.heap.page_allocator;

/// How long a composed dossier is served without starting a background
/// recompose behind it. Composition is a minute of board analysis, so this is
/// the knob that keeps a reader hammering reload from queueing a minute of CPU
/// per keystroke while still making an ordinary revisit pick up current
/// evidence.
pub const revalidate_after_ms: i64 = 60 * 1000;
const outdated_validation_ms: i64 = -1;

/// How many times one compose may be attempted before its failure is reported.
/// Only `error.InputsChanged` is retried — the composer's own guard against a
/// board's inputs moving mid-analysis, which is a transient property of a busy
/// server rather than a statement about the workspace. Everything else is
/// reported on the first attempt.
const max_compose_attempts: u8 = 3;

/// A completed dossier is a derived result, not authored source. Persist it
/// below `out/` so a process restart can rehydrate the exact HTML instead of
/// repeating a minute of analysis. The envelope binds the bytes to both the
/// renderer build and a cheap, deterministic fingerprint of the project tree.
const cache_rel = "out/dossier-cache";
const cache_magic = "netlisp-dossier-cache-v1";
const cache_envelope_bytes: usize = 4 * 1024;
const max_cache_file_bytes: usize = review_html.max_html_bytes + cache_envelope_bytes;

const WorkspaceStamp = struct {
    path: []const u8,
    kind: std.Io.File.Kind,
    size: u64,
    mtime_ns: i128,
};

fn stampLessThan(_: void, a: WorkspaceStamp, b: WorkspaceStamp) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

/// Fingerprint every path that can feed a system review. This deliberately
/// over-invalidates (an unrelated board edit also moves the fingerprint), but
/// it is only a metadata walk and is vastly cheaper than re-running DRC. The
/// Git identity is included because the dossier prints it even when the tree's
/// file bytes have not changed.
fn workspaceFingerprint(allocator: std.mem.Allocator, project_dir: []const u8) ?[64]u8 {
    var stamps: std.ArrayList(WorkspaceStamp) = .empty;
    defer stamps.deinit(allocator);

    for ([_][]const u8{ "src", "lib" }) |root_name| {
        const root_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, root_name }) catch return null;
        defer allocator.free(root_path);
        var dir = infra_fs.cwd().openDir(root_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return null,
        };
        defer dir.close();
        var walker = dir.walk(allocator) catch return null;
        defer walker.deinit();
        while (walker.next() catch return null) |entry| {
            const stat = (infra_fs.Dir{ .d = entry.dir }).statFileNoFollow(entry.basename) catch return null;
            const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ root_name, entry.path }) catch return null;
            stamps.append(allocator, .{
                .path = path,
                .kind = entry.kind,
                .size = stat.size,
                .mtime_ns = stat.mtime.nanoseconds,
            }) catch return null;
        }
    }
    std.mem.sort(WorkspaceStamp, stamps.items, {}, stampLessThan);

    var hash = Sha256.init(.{});
    hash.update(cache_magic);
    for (stamps.items) |stamp| {
        hash.update(stamp.path);
        hash.update(&.{0});
        hash.update(@tagName(stamp.kind));
        hash.update(std.mem.asBytes(&stamp.size));
        hash.update(std.mem.asBytes(&stamp.mtime_ns));
    }
    const head = githash.fullHash(infra_fs.currentIo(), allocator, project_dir);
    if (head) |commit| {
        defer allocator.free(commit);
        hash.update(commit);
    } else {
        hash.update("git-unavailable");
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn cacheSafeName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or !std.ascii.isAlphanumeric(name[0])) return false;
    for (name[1..]) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.') continue;
        return false;
    }
    return true;
}

fn cacheDirPath(allocator: std.mem.Allocator, project_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/" ++ cache_rel, .{project_dir});
}

fn cacheFilePath(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/" ++ cache_rel ++ "/{s}.cache", .{ project_dir, name });
}

const Cached = struct {
    storage: []const u8,
    html: []const u8,
    composed_ms: i64,
    fingerprint: [64]u8,
    outdated: bool,
};

fn nextLine(cursor: *[]const u8) ?[]const u8 {
    const end = std.mem.indexOfScalar(u8, cursor.*, '\n') orelse return null;
    const line = cursor.*[0..end];
    cursor.* = cursor.*[end + 1 ..];
    return line;
}

fn loadCache(project_dir: []const u8, name: []const u8) ?Cached {
    if (!cacheSafeName(name)) return null;
    const path = cacheFilePath(durable, project_dir, name) catch return null;
    defer durable.free(path);
    const storage = infra_fs.cwd().readFileAlloc(durable, path, max_cache_file_bytes) catch return null;
    var keep_storage = false;
    defer if (!keep_storage) durable.free(storage);

    var cursor: []const u8 = storage;
    const magic = nextLine(&cursor) orelse return null;
    const tool_build = nextLine(&cursor) orelse return null;
    const composed_raw = nextLine(&cursor) orelse return null;
    const fingerprint_raw = nextLine(&cursor) orelse return null;
    const html_sha_raw = nextLine(&cursor) orelse return null;
    if (!std.mem.eql(u8, magic, cache_magic)) return null;
    if (!std.mem.eql(u8, tool_build, build_id.current())) return null;
    if (fingerprint_raw.len != 64 or html_sha_raw.len != 64) return null;
    if (cursor.len == 0 or cursor.len > review_html.max_html_bytes) return null;
    const composed_ms = std.fmt.parseInt(i64, composed_raw, 10) catch return null;
    if (composed_ms <= 0) return null;

    var html_digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(cursor, &html_digest, .{});
    const html_sha = std.fmt.bytesToHex(html_digest, .lower);
    if (!std.mem.eql(u8, &html_sha, html_sha_raw)) return null;

    var arena = std.heap.ArenaAllocator.init(durable);
    defer arena.deinit();
    const current = workspaceFingerprint(arena.allocator(), project_dir);
    var fingerprint: [64]u8 = undefined;
    @memcpy(&fingerprint, fingerprint_raw);
    keep_storage = true;
    return .{
        .storage = storage,
        .html = cursor,
        .composed_ms = composed_ms,
        .fingerprint = fingerprint,
        .outdated = current == null or !std.mem.eql(u8, &current.?, fingerprint_raw),
    };
}

fn deleteCache(project_dir: []const u8, name: []const u8) void {
    if (!cacheSafeName(name)) return;
    const path = cacheFilePath(durable, project_dir, name) catch return;
    defer durable.free(path);
    infra_fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.warn("dossier cache: could not remove {s} ({s})", .{ name, @errorName(err) }),
    };
}

fn persistCache(
    project_dir: []const u8,
    name: []const u8,
    composed_ms: i64,
    fingerprint: [64]u8,
    html: []const u8,
) !void {
    if (!cacheSafeName(name)) return error.InvalidSystemName;
    const dir_path = try cacheDirPath(durable, project_dir);
    defer durable.free(dir_path);
    try infra_fs.cwd().makePath(dir_path);
    const path = try cacheFilePath(durable, project_dir, name);
    defer durable.free(path);

    var html_digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(html, &html_digest, .{});
    const html_sha = std.fmt.bytesToHex(html_digest, .lower);
    const header = try std.fmt.allocPrint(
        durable,
        "{s}\n{s}\n{d}\n{s}\n{s}\n",
        .{ cache_magic, build_id.current(), composed_ms, &fingerprint, &html_sha },
    );
    defer durable.free(header);

    var staged: atomic_write.Staged = .{};
    defer staged.abandon();
    try staged.begin(path);
    try staged.write(header);
    try staged.write(html);
    try staged.commit();
}

/// Whether a failed attempt should be composed again. Only the composer's
/// mid-analysis consistency guard qualifies: `error.InputsChanged` says a
/// board's consumed-input closure moved between `analyze`'s two fabrication
/// passes.
///
/// It once said less than that. Until the `src/` basename index stopped
/// probing the tree inside whichever read trace happened to be open
/// (`paths.ensureSrcIndex`), an unrelated request landing mid-compose could
/// move the closure over a tree nobody had touched, and this retry was the
/// mitigation for a guard that lied. It no longer is: a minute-long compose
/// concurrent with a steady request stream now holds one closure throughout.
///
/// What remains is the honest case the guard is FOR. A compose reads the
/// workspace for a minute or more without holding a lock over it, so a save,
/// an autolayout write or a git operation genuinely can land between the two
/// passes. Recomposing is the right answer to that — the next attempt simply
/// sees the post-mutation tree — and it stays bounded so a workspace being
/// edited continuously reports instead of looping. Every other failure — an
/// invalid manifest, a missing board, a package over its ceiling — would fail
/// identically on the next attempt, so it is reported at once.
fn retryable(err: anyerror, attempt: u8) bool {
    return err == error.InputsChanged and attempt < max_compose_attempts;
}

/// One system's slot: the last composed document, or the last compose failure,
/// plus whether a compose is in flight right now. `gen` versions the slot so an
/// `invalidate` landing mid-compose retires that compose's result instead of
/// publishing a document composed from pre-mutation inputs.
const Entry = struct {
    gen: u32 = 0,
    composing: bool = false,
    storage: ?[]const u8 = null,
    html: ?[]const u8 = null,
    composed_ms: i64 = 0,
    validated_ms: i64 = 0,
    fingerprint: ?[64]u8 = null,
    outdated: bool = false,
    err: ?anyerror = null,
};

/// A consistent read of one system's slot. `html` is copied into the caller's
/// allocator under the lock, because a finishing compose frees the bytes the
/// slot previously held — so a caller that only wants the STATE asks for no
/// copy and reads `has_document` instead of paying a megabyte-scale memcpy.
pub const View = struct {
    gen: u32,
    composing: bool,
    has_document: bool,
    html: ?[]const u8,
    composed_ms: i64,
    validated_ms: i64,
    err: ?anyerror,

    /// Whether the retained document predates a known project change.
    pub fn outdated(self: View) bool {
        return self.validated_ms == outdated_validation_ms;
    }

    /// Whether this view needs a cheap freshness check or is already known
    /// outdated. A slot with no result is stale so its first request composes.
    pub fn stale(self: View, now_ms: i64) bool {
        if (self.outdated()) return true;
        if (self.validated_ms == 0) return true;
        return now_ms -| self.validated_ms >= revalidate_after_ms;
    }

    /// Whole seconds since this document (or failure) was composed, for the
    /// status endpoint's freshness reporting. Null when nothing is recorded.
    pub fn ageSeconds(self: View, now_ms: i64) ?i64 {
        if (self.composed_ms == 0) return null;
        return @divFloor(@max(now_ms - self.composed_ms, 0), 1000);
    }
};

/// The per-system dossier slots, held in `ServerState` so they live for the
/// server's lifetime without a module-level global (`route_live`'s convention).
/// All access is serialized by `mutex`.
pub const Store = struct {
    mutex: infra_fs.Mutex = .{},
    map: std.StringHashMapUnmanaged(Entry) = .empty,
    /// Whether `spawn` may start a detached compose thread. Off by default so a
    /// bare `ServerState` is inert; `serve()` turns it on.
    background: bool = false,
    /// Borrowed for the server's lifetime. Null keeps a default-constructed
    /// handler-test store entirely in memory and performs no filesystem I/O.
    project_dir: ?[]const u8 = null,

    fn getOrPutLocked(self: *Store, name: []const u8) ?*Entry {
        const gop = self.map.getOrPut(durable, name) catch return null;
        if (!gop.found_existing) {
            // Borrow the caller's name until the durable dupe lands, so a
            // failed dupe can still remove the entry through a valid key.
            gop.key_ptr.* = name;
            gop.value_ptr.* = .{};
            gop.key_ptr.* = durable.dupe(u8, name) catch {
                _ = self.map.remove(name);
                return null;
            };
        }
        return gop.value_ptr;
    }

    /// Claim the single compose slot for `name`, returning the generation the
    /// caller must quote back to `finish`. Null when a compose is already in
    /// flight (the join case — the caller starts nothing) or when the slot
    /// could not be allocated.
    pub fn begin(self: *Store, name: []const u8) ?u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.getOrPutLocked(name) orelse return null;
        if (entry.composing) return null;
        entry.composing = true;
        entry.gen +%= 1;
        return entry.gen;
    }

    /// Publish generation `gen`'s outcome: `html` (durable-owned, ownership
    /// taken) on success, or `err` on failure. The compose slot is released
    /// either way, because the one worker holding it has exited. A result whose
    /// generation was superseded by `invalidate` is discarded rather than
    /// published — its inputs are known to be out of date.
    pub fn finish(self: *Store, name: []const u8, gen: u32, html: ?[]const u8, err: ?anyerror) void {
        var arena = std.heap.ArenaAllocator.init(durable);
        defer arena.deinit();
        const fingerprint = if (html != null and self.project_dir != null)
            workspaceFingerprint(arena.allocator(), self.project_dir.?)
        else
            null;
        self.finishStamped(name, gen, html, err, fingerprint);
    }

    fn finishStamped(
        self: *Store,
        name: []const u8,
        gen: u32,
        html: ?[]const u8,
        err: ?anyerror,
        fingerprint: ?[64]u8,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.map.getPtr(name) orelse {
            if (html) |bytes| durable.free(bytes);
            return;
        };
        entry.composing = false;
        if (entry.gen != gen) {
            if (html) |bytes| durable.free(bytes);
            return;
        }
        if (entry.storage) |old| durable.free(old);
        entry.storage = html;
        entry.html = html;
        entry.err = err;
        entry.composed_ms = clock.milliTimestamp();
        entry.validated_ms = entry.composed_ms;
        entry.fingerprint = fingerprint;
        entry.outdated = false;
        if (self.project_dir) |project_dir| {
            if (html) |bytes| {
                if (fingerprint) |fp| {
                    persistCache(project_dir, name, entry.composed_ms, fp, bytes) catch |persist_err| {
                        log.warn("dossier cache: could not persist {s} ({s})", .{ name, @errorName(persist_err) });
                        deleteCache(project_dir, name);
                    };
                } else deleteCache(project_dir, name);
            } else deleteCache(project_dir, name);
        }
    }

    /// A consistent snapshot of `name`'s slot. A composed document is copied
    /// into `allocator` (the request arena) when one is supplied; pass null to
    /// read the state alone, which is what the polled status endpoint wants —
    /// it never serves the document, and copying a megabyte every two seconds
    /// to answer "is it there yet" would be the wrong kind of cheap. An unknown
    /// system reads as an empty slot rather than an error, because the first
    /// request for a system is exactly that.
    pub fn snapshot(self: *Store, allocator: ?std.mem.Allocator, name: []const u8) View {
        self.mutex.lock();
        defer self.mutex.unlock();
        var entry = self.map.getPtr(name);
        if (entry == null) if (self.project_dir) |project_dir| {
            entry = self.getOrPutLocked(name);
            if (entry) |slot| if (loadCache(project_dir, name)) |cached| {
                slot.storage = cached.storage;
                slot.html = cached.html;
                slot.composed_ms = cached.composed_ms;
                slot.validated_ms = if (cached.outdated) 0 else clock.milliTimestamp();
                slot.fingerprint = cached.fingerprint;
                slot.outdated = cached.outdated;
            };
        };
        const current = entry orelse return .{
            .gen = 0,
            .composing = false,
            .has_document = false,
            .html = null,
            .composed_ms = 0,
            .validated_ms = 0,
            .err = null,
        };
        const copied: ?[]const u8 = if (allocator) |a|
            (if (current.html) |bytes| (a.dupe(u8, bytes) catch null) else null)
        else
            null;
        // A copy that was ASKED for and failed to allocate must not read as
        // "nothing composed": report the allocation failure so the page answers
        // a diagnostic rather than silently starting another composition.
        const copy_failed = allocator != null and current.html != null and copied == null;
        return .{
            .gen = current.gen,
            .composing = current.composing,
            .has_document = current.html != null,
            .html = copied,
            .composed_ms = current.composed_ms,
            .validated_ms = if (current.outdated) outdated_validation_ms else current.validated_ms,
            .err = if (copy_failed) error.OutOfMemory else current.err,
        };
    }

    /// Renew a retained slot when its complete source-tree fingerprint is
    /// unchanged; otherwise mark its last good document explicitly outdated.
    /// This metadata-only check takes milliseconds and never starts DRC.
    pub fn revalidate(self: *Store, project_dir: []const u8, name: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.map.getPtr(name) orelse return false;
        const recorded = entry.fingerprint orelse return false;
        if (entry.html == null or entry.composing or entry.outdated) return false;
        if (clock.milliTimestamp() -| entry.validated_ms < revalidate_after_ms) return true;
        var arena = std.heap.ArenaAllocator.init(durable);
        defer arena.deinit();
        const current = workspaceFingerprint(arena.allocator(), project_dir) orelse return false;
        if (!std.mem.eql(u8, &recorded, &current)) {
            entry.outdated = true;
            entry.validated_ms = 0;
            return false;
        }
        entry.validated_ms = clock.milliTimestamp();
        return true;
    }

    /// Mark `name`'s last good document stale and retire any compose already in
    /// flight. A reader may keep using those explicit old results until they
    /// request regeneration; a slot with no document remains a cold miss.
    pub fn invalidate(self: *Store, name: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.map.getPtr(name)) |entry| {
            entry.err = null;
            entry.validated_ms = 0;
            entry.outdated = entry.html != null;
            if (entry.html == null) {
                entry.composed_ms = 0;
                entry.fingerprint = null;
            }
            entry.gen +%= 1;
        }
    }

    /// Release every retained document and key. Safe on a default-constructed
    /// store. Not safe while a compose thread is still running, which is why
    /// only `serve()`'s owned instance is ever torn down.
    pub fn deinit(self: *Store) void {
        var it = self.map.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.storage) |bytes| durable.free(bytes);
            durable.free(kv.key_ptr.*);
        }
        self.map.deinit(durable);
        self.map = .empty;
    }
};

/// What the detached compose thread owns. `project_dir` and `name` are durable
/// copies because both point into per-request storage at the call site, and the
/// thread outlives the response by about a minute.
const Task = struct {
    store: *Store,
    project_dir: []const u8,
    name: []const u8,
    gen: u32,

    fn run(self: Task) void {
        defer {
            // allocator-ok: releasing the process-lifetime copies `spawn` made.
            durable.free(self.project_dir);
            durable.free(self.name);
        }
        // A compose is a unit of work over the project tree, exactly like a
        // request, so it opens with what `Server.dispatch` opens every request
        // with: the src/ basename index revalidated once for this unit of work,
        // and the work counted as interactive so the startup and derived warm
        // sweeps yield to it the way they yield to a reader.
        warm_sched.enterInteractive();
        defer warm_sched.leaveInteractive();
        paths.beginRequest();
        // The compose owns its scratch and releases it before returning, so a
        // system's worth of board evidence is not retained past the one
        // document it produced.
        // allocator-ok: detached compose-thread scratch, released below.
        var arena = std.heap.ArenaAllocator.init(durable);
        defer arena.deinit();
        var attempt: u8 = 0;
        while (true) {
            attempt += 1;
            const before_fingerprint = workspaceFingerprint(arena.allocator(), self.project_dir);
            const composed = system_review_package.draftDossierHtml(
                arena.allocator(),
                self.project_dir,
                self.name,
            ) catch |err| {
                // `InputsChanged` says a board's consumed-input closure moved
                // between the two fabrication passes that sandwich the review
                // snapshot. A compose reads the workspace for a minute or more
                // without a lock over it, so a save landing in that window is a
                // real thing to survive: composing again reads the tree as it
                // now stands. Bounded, so a workspace under continuous edit
                // reports instead of looping. (Concurrent READS no longer reach
                // here — see `retryable` for the closure bug this outlived.)
                if (retryable(err, attempt)) {
                    log.warn(
                        "dossier compose: {s} lost its input closure, composing again ({d}/{d})",
                        .{ self.name, attempt + 1, max_compose_attempts },
                    );
                    _ = arena.reset(.retain_capacity);
                    continue;
                }
                self.store.finish(self.name, self.gen, null, err);
                return;
            };
            const after_fingerprint = workspaceFingerprint(arena.allocator(), self.project_dir);
            if (before_fingerprint != null and after_fingerprint != null and
                !std.mem.eql(u8, &before_fingerprint.?, &after_fingerprint.?))
            {
                if (attempt < max_compose_attempts) {
                    log.warn(
                        "dossier compose: {s} project inputs moved, composing again ({d}/{d})",
                        .{ self.name, attempt + 1, max_compose_attempts },
                    );
                    _ = arena.reset(.retain_capacity);
                    continue;
                }
                self.store.finish(self.name, self.gen, null, error.InputsChanged);
                return;
            }
            // allocator-ok: process-lifetime by necessity — the retained
            // document outlives this thread's arena and every request that
            // reads it.
            const owned = durable.dupe(u8, composed) catch {
                self.store.finish(self.name, self.gen, null, error.OutOfMemory);
                return;
            };
            self.store.finishStamped(self.name, self.gen, owned, null, after_fingerprint);
            return;
        }
    }
};

fn start(store: *Store, project_dir: []const u8, name: []const u8) bool {
    if (!store.background) return false;
    const gen = store.begin(name) orelse return false;
    // allocator-ok: process-lifetime by necessity — these outlive the request.
    const owned_dir = durable.dupe(u8, project_dir) catch {
        store.finish(name, gen, null, error.OutOfMemory);
        return false;
    };
    const owned_name = durable.dupe(u8, name) catch {
        durable.free(owned_dir);
        store.finish(name, gen, null, error.OutOfMemory);
        return false;
    };
    const task = Task{ .store = store, .project_dir = owned_dir, .name = owned_name, .gen = gen };
    const thread = std.Thread.spawn(.{}, Task.run, .{task}) catch |err| {
        log.warn("dossier compose: not started for {s} ({s})", .{ name, @errorName(err) });
        durable.free(owned_dir);
        durable.free(owned_name);
        store.finish(name, gen, null, err);
        return false;
    };
    thread.detach();
    return true;
}

/// Start composing a cold or failed slot, unless the retained document's cheap
/// fingerprint check shows it is still current. An outdated retained document
/// is not regenerated by opening it; only `regenerate` replaces it.
pub fn spawn(store: *Store, project_dir: []const u8, name: []const u8) void {
    if (store.revalidate(project_dir, name)) return;
    _ = start(store, project_dir, name);
}

/// Explicitly replace the last composed document. Returns true only when this
/// call claimed the per-system slot and detached a worker; false means the
/// store is inert, a worker already owns it, or thread startup failed.
pub fn regenerate(store: *Store, project_dir: []const u8, name: []const u8) bool {
    return start(store, project_dir, name);
}

// spec: system-review - a completed dossier persists atomically below out and is rehydrated after restart for the same tool build, marked stale when its project tree changed and rejected when its bytes are damaged
test "a completed dossier survives a store restart with explicit staleness" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "project/src/systems/demo");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "project/src/systems/demo/system.json",
        .data = "{\"name\":\"demo\"}",
    });
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, "project", std.testing.allocator);
    defer std.testing.allocator.free(project);
    const html = "<!doctype html><html><body>persisted dossier</body></html>";

    // The first process publishes the completed bytes and atomically saves the
    // same document beneath the project's derived-output directory.
    {
        var first = Store{ .project_dir = project };
        defer first.deinit();
        const gen = first.begin("demo").?;
        first.finish("demo", gen, try durable.dupe(u8, html), null);
        try tmp.dir.access(std.testing.io, "project/out/dossier-cache/demo.cache", .{});
    }

    // A fresh Store stands in for a restarted server. Its first snapshot
    // validates the envelope and source fingerprint, then serves exact HTML.
    {
        var restarted = Store{ .project_dir = project };
        defer restarted.deinit();
        const view = restarted.snapshot(std.testing.allocator, "demo");
        const loaded = view.html orelse return error.NothingComposed;
        defer std.testing.allocator.free(loaded);
        try std.testing.expectEqualStrings(html, loaded);
        try std.testing.expect(!view.stale(clock.milliTimestamp()));

        // Once the cheap validation window expires, unchanged inputs renew it
        // without claiming a composition slot.
        restarted.map.getPtr("demo").?.validated_ms = 0;
        try std.testing.expect(restarted.revalidate(project, "demo"));
        try std.testing.expect(!restarted.snapshot(null, "demo").composing);
    }

    // A cache produced by another executable is also a miss. Dossier markup
    // and its embedded tool identity can change between builds.
    {
        const mismatched = try tmp.dir.readFileAlloc(
            std.testing.io,
            "project/out/dossier-cache/demo.cache",
            std.testing.allocator,
            .limited64(max_cache_file_bytes),
        );
        defer std.testing.allocator.free(mismatched);
        const build_offset = cache_magic.len + 1;
        mismatched[build_offset] = if (mismatched[build_offset] == 'x') 'y' else 'x';
        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = "project/out/dossier-cache/demo.cache",
            .data = mismatched,
        });
        var other_build = Store{ .project_dir = project };
        defer other_build.deinit();
        try std.testing.expect(!other_build.snapshot(null, "demo").has_document);
    }
    {
        var current_build = Store{ .project_dir = project };
        defer current_build.deinit();
        const gen = current_build.begin("demo").?;
        current_build.finish("demo", gen, try durable.dupe(u8, html), null);
    }

    // A source edit keeps the last same-build copy readable, but admits it only
    // as explicitly outdated evidence.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "project/src/systems/demo/system.json",
        .data = "{\"name\":\"demo\",\"revision\":2}",
    });
    {
        var changed = Store{ .project_dir = project };
        defer changed.deinit();
        const stale = changed.snapshot(std.testing.allocator, "demo");
        const stale_html = stale.html orelse return error.NothingComposed;
        defer std.testing.allocator.free(stale_html);
        try std.testing.expectEqualStrings(html, stale_html);
        try std.testing.expect(stale.outdated());
    }

    // Re-publish against the new tree, then damage one body byte. The SHA-256
    // envelope rejects it rather than serving a partial/corrupt document.
    {
        var refreshed = Store{ .project_dir = project };
        defer refreshed.deinit();
        const gen = refreshed.begin("demo").?;
        refreshed.finish("demo", gen, try durable.dupe(u8, html), null);
    }
    const raw = try tmp.dir.readFileAlloc(
        std.testing.io,
        "project/out/dossier-cache/demo.cache",
        std.testing.allocator,
        .limited64(max_cache_file_bytes),
    );
    defer std.testing.allocator.free(raw);
    raw[raw.len - 1] ^= 1;
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "project/out/dossier-cache/demo.cache",
        .data = raw,
    });
    {
        var damaged = Store{ .project_dir = project };
        defer damaged.deinit();
        try std.testing.expect(!damaged.snapshot(null, "demo").has_document);
    }

    // Invalidation preserves a persistent copy even when this process never
    // hydrated it — exactly the mutation-before-first-read case.
    {
        var refreshed = Store{ .project_dir = project };
        defer refreshed.deinit();
        const gen = refreshed.begin("demo").?;
        refreshed.finish("demo", gen, try durable.dupe(u8, html), null);
    }
    var mutating = Store{ .project_dir = project };
    defer mutating.deinit();
    mutating.invalidate("demo");
    try tmp.dir.access(std.testing.io, "project/out/dossier-cache/demo.cache", .{});
}

// spec: system-review - one dossier composition per system is ever in flight, and a reload during one joins it rather than starting a second
test "the dossier store admits one compose per system and serves the finished document" {
    var store = Store{};
    defer store.deinit();

    // Nothing composed yet: an empty slot that reads as stale, so the first
    // request is what starts the first compose.
    const empty = store.snapshot(null, "demo");
    try std.testing.expect(!empty.has_document);
    try std.testing.expect(!empty.composing);
    try std.testing.expect(empty.stale(clock.milliTimestamp()));
    try std.testing.expect(empty.ageSeconds(clock.milliTimestamp()) == null);

    // One compose claims the slot; a second caller joins rather than starting
    // a second minute of board analysis.
    const gen = store.begin("demo").?;
    try std.testing.expect(store.begin("demo") == null);
    // A different system is unaffected by the busy one.
    const other = store.begin("otherdemo").?;
    try std.testing.expectEqual(gen, other);

    const in_flight = store.snapshot(null, "demo");
    try std.testing.expect(in_flight.composing);
    try std.testing.expect(!in_flight.has_document);

    // allocator-ok: the store takes ownership of durable-allocated documents.
    store.finish("demo", gen, try durable.dupe(u8, "<html>v1</html>"), null);
    const composed = store.snapshot(std.testing.allocator, "demo");
    const composed_html = composed.html orelse return error.NothingComposed;
    defer std.testing.allocator.free(composed_html);
    try std.testing.expect(!composed.composing);
    try std.testing.expectEqualStrings("<html>v1</html>", composed_html);
    try std.testing.expect(composed.err == null);
    // A fresh document is not recomposed behind the reader.
    try std.testing.expect(!composed.stale(clock.milliTimestamp()));
    try std.testing.expect(composed.stale(clock.milliTimestamp() + revalidate_after_ms));
    // The slot is free again, so a later revalidation may claim it.
    try std.testing.expect(store.begin("demo") != null);
}

// spec: system-review - a system-review mutation marks the retained dossier stale and retires the compose in flight, so old results stay readable without being presented as current
test "invalidating a dossier slot preserves explicit stale results and retires the active compose" {
    var store = Store{};
    defer store.deinit();

    const first = store.begin("demo").?;
    // allocator-ok: the store takes ownership of durable-allocated documents.
    store.finish("demo", first, try durable.dupe(u8, "<html>v1</html>"), null);

    // A recompose is under way when the reader saves a document.
    const second = store.begin("demo").?;
    store.invalidate("demo");
    const retained = store.snapshot(std.testing.allocator, "demo");
    const retained_html = retained.html orelse return error.NothingComposed;
    defer std.testing.allocator.free(retained_html);
    try std.testing.expectEqualStrings("<html>v1</html>", retained_html);
    try std.testing.expect(retained.outdated());

    // The in-flight compose read pre-save inputs, so its result is discarded
    // rather than published over the invalidation.
    // allocator-ok: the store takes ownership of durable-allocated documents.
    store.finish("demo", second, try durable.dupe(u8, "<html>stale</html>"), null);
    const after_stale = store.snapshot(std.testing.allocator, "demo");
    const after_stale_html = after_stale.html orelse return error.NothingComposed;
    defer std.testing.allocator.free(after_stale_html);
    try std.testing.expectEqualStrings("<html>v1</html>", after_stale_html);
    try std.testing.expect(after_stale.outdated());
    try std.testing.expect(!after_stale.composing);

    // The recompose that starts after the save is the one that publishes, and
    // what it publishes is what the reader now gets.
    const third = store.begin("demo").?;
    // allocator-ok: the store takes ownership of durable-allocated documents.
    store.finish("demo", third, try durable.dupe(u8, "<html>v2</html>"), null);
    const fresh = store.snapshot(std.testing.allocator, "demo");
    const fresh_html = fresh.html orelse return error.NothingComposed;
    defer std.testing.allocator.free(fresh_html);
    try std.testing.expectEqualStrings("<html>v2</html>", fresh_html);
    try std.testing.expect(!fresh.outdated());
}

// spec: system-review - a dossier composition that lost its input closure to concurrent server work is composed again within a bounded number of attempts
test "only the composer's mid-analysis guard earns another compose attempt" {
    // The guard says "something moved under me", so the same inputs may well
    // compose cleanly on the next pass…
    try std.testing.expect(retryable(error.InputsChanged, 1));
    try std.testing.expect(retryable(error.InputsChanged, max_compose_attempts - 1));
    // …but not forever: a genuinely unstable tree reports instead of looping.
    try std.testing.expect(!retryable(error.InputsChanged, max_compose_attempts));
    // Everything else is a verdict about the workspace and would fail the same
    // way on every attempt, so it is reported on the first one.
    try std.testing.expect(!retryable(error.BoardNotFound, 1));
    try std.testing.expect(!retryable(error.InvalidManifest, 1));
    try std.testing.expect(!retryable(error.ArchiveTooLarge, 1));
    try std.testing.expect(!retryable(error.OutOfMemory, 1));
}

// spec: system-review - a failed dossier composition is recorded against its system and reported rather than retried on every reload
test "a failed dossier compose is retained as the slot's reported outcome" {
    var store = Store{};
    defer store.deinit();

    const gen = store.begin("demo").?;
    store.finish("demo", gen, null, error.InputsChanged);
    const failed = store.snapshot(null, "demo");
    try std.testing.expect(!failed.has_document);
    try std.testing.expect(!failed.composing);
    try std.testing.expectEqual(@as(anyerror, error.InputsChanged), failed.err.?);
    // Recorded, so it is not stale — a broken workspace is not recomposed on
    // every reload, only once the revalidation window has passed.
    try std.testing.expect(!failed.stale(clock.milliTimestamp()));
    try std.testing.expect(failed.ageSeconds(clock.milliTimestamp()).? >= 0);

    // A store with background composition off starts nothing, which is what
    // keeps a handler test from racing a detached compose against its fixture.
    store.invalidate("demo");
    spawn(&store, ".", "demo");
    try std.testing.expect(!store.snapshot(null, "demo").composing);
}
