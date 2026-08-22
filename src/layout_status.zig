//! Read-only summary of a design/module's PCB-layout progress, drawn from its
//! `<name>.layouts.json` sidecar: whether a rough placement has been seeded
//! (`?rough=1`) and whether a finished layout has been starred (the layout
//! panel's ★ — i.e. the sidecar's top-level `"default"` entry, reused as the
//! human-finished marker). Read by the home page's design cards
//! (`serve/pages.zig`) and the block diagram (`diagram/collect.zig`).
//!
//! Not by the schematic page. It carried a "Module layouts" checklist that read
//! one sidecar per sub-block; that panel is gone, because the schematic page
//! renders the design's `.sexp` and nothing else. Its sub circuits link out to
//! `/pcb-layout/…` instead.
//!
//! The full sidecar shape lives in `serve/pcb_layout_page.zig`; this is a
//! deliberately tiny, dependency-light reader so a caller needn't pull in the
//! whole PCB-layout page module.
const std = @import("std");
const paths = @import("paths.zig");
const infra_fs = @import("infra/fs.zig");

/// Mirror of `serve/pcb_layout_page.sidecar_max_bytes`, duplicated rather than
/// imported so this stays the dependency-light reader described above. A routed
/// multi-layout board runs to megabytes; a smaller cap reads back as no layouts
/// at all, which here would silently report "no layout saved".
const sidecar_max_bytes: usize = 16 << 20;

/// At-a-glance state of a design/module's saved layouts.
pub const ModuleLayoutStatus = struct {
    /// At least one saved layout exists in the sidecar.
    present: bool = false,
    /// A Rough-seed layout has been recorded (an entry with `"rough":true`).
    rough: bool = false,
    /// A layout has been starred: the sidecar's top-level `"default"` names an
    /// existing entry (the ★ in the `/pcb-layout` panel, reused here as the
    /// "human finished it" marker).
    starred: bool = false,
    /// Number of saved layouts in the sidecar.
    count: usize = 0,
};

/// Read the layout status for `name` (a design under `src/` or a module under
/// `lib/modules/`). Returns an all-false status when the sidecar is missing or
/// unparseable. Allocation is on `alloc` (caller's arena); nothing is retained
/// past the call.
pub fn read(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) ModuleLayoutStatus {
    const path = paths.designSiblingPath(alloc, project_dir, name, ".layouts.json") catch return .{};
    defer alloc.free(path);
    const stamp = stampOf(path);
    if (Memo.get(path, stamp)) |hit| return hit;
    const data = infra_fs.cwd().readFileAlloc(alloc, path, sidecar_max_bytes) catch return .{};
    const st = parse(alloc, data);
    Memo.put(path, stamp, st);
    return st;
}

/// Summarize a `.layouts.json` body into a `ModuleLayoutStatus`. Split from
/// `read` so the JSON handling is exercised without touching the filesystem.
fn parse(alloc: std.mem.Allocator, data: []const u8) ModuleLayoutStatus {
    var st = ModuleLayoutStatus{};
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, data, .{}) catch return st;
    if (root != .object) return st;
    const arr = root.object.get("layouts") orelse return st;
    if (arr != .array) return st;

    st.count = arr.array.items.len;
    st.present = st.count > 0;
    for (arr.array.items) |it| {
        if (it != .object) continue;
        const rv = it.object.get("rough") orelse continue;
        if (rv == .bool and rv.bool) st.rough = true;
    }

    // Starred = the sidecar names a default layout that still exists.
    const dv = root.object.get("default") orelse return st;
    if (dv != .string or dv.string.len == 0) return st;
    for (arr.array.items) |it| {
        if (it != .object) continue;
        const nm = it.object.get("name") orelse continue;
        if (nm == .string and std.mem.eql(u8, nm.string, dv.string)) {
            st.starred = true;
            break;
        }
    }
    return st;
}

// ── Cross-request memo ─────────────────────────────────────────────────

/// The identity of a sidecar's contents. An absent file is a real answer (the
/// all-false status), so it is cached too — `present=false` re-reads once the
/// file appears.
const Stamp = struct {
    mtime_ns: i128,
    size: u64,
    present: bool,

    fn eql(a: Stamp, b: Stamp) bool {
        return a.present == b.present and a.mtime_ns == b.mtime_ns and a.size == b.size;
    }
};

fn stampOf(path: []const u8) Stamp {
    if (infra_fs.cwd().statFile(path)) |st| {
        return .{ .mtime_ns = st.mtime.nanoseconds, .size = st.size, .present = true };
    } else |_| {
        return .{ .mtime_ns = 0, .size = 0, .present = false };
    }
}

/// Process-lifetime memo of parsed sidecars, keyed by path and validated by the
/// file's `(mtime, size)`.
///
/// Four booleans are all any caller wants, but the sidecar they live in is the
/// board's whole saved state: a routed multi-layout design runs to megabytes,
/// and the home page reads one per design AND per module (106 files, 10.8 MiB
/// on this project) on every load — 1.27 s of a 1.32 s page, spent building a
/// `std.json.Value` tree that is discarded four fields later. The parse result
/// is a pure function of the file's bytes, so it is re-derived only when those
/// bytes move. Same invalidation contract as `serve/page_cache.zig`, so a
/// layout save still shows up on the very next load.
///
/// State is container-scope inside this struct rather than passed in, because
/// `read` is called from plain renderers (`render_html`, `diagram/collect`)
/// that hold no server handle to thread a store through.
const Memo = struct {
    const Entry = struct { stamp: Stamp, status: ModuleLayoutStatus };

    // The memo must outlive the per-request arenas whose `alloc` produced each
    // parse, and it has the process's own lifetime.
    // allocator-ok: process-lifetime memo, deliberately not request-scoped.
    const store = std.heap.page_allocator;

    var mutex: infra_fs.Mutex = .{};
    var entries: std.StringHashMapUnmanaged(Entry) = .empty;

    /// The memoized status for `path`, or null when nothing is stored or the
    /// file has moved since it was.
    fn get(path: []const u8, stamp: Stamp) ?ModuleLayoutStatus {
        mutex.lock();
        defer mutex.unlock();
        const e = entries.get(path) orelse return null;
        if (!e.stamp.eql(stamp)) return null;
        return e.status;
    }

    /// Retain `status` for `path`. `ModuleLayoutStatus` is four scalars —
    /// nothing borrows the caller's arena — so the entry needs no deep copy and
    /// the memo grows only by one key per sidecar the process has ever read.
    fn put(path: []const u8, stamp: Stamp, status: ModuleLayoutStatus) void {
        const key = store.dupe(u8, path) catch return;
        mutex.lock();
        defer mutex.unlock();
        const gop = entries.getOrPut(store, key) catch {
            store.free(key);
            return;
        };
        if (gop.found_existing) store.free(key); // the map keeps the original key
        gop.value_ptr.* = .{ .stamp = stamp, .status = status };
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Web Server - The layout-status reader reuses a parsed layouts sidecar until that file's mtime or size changes
test "read caches a sidecar and re-reads it after the file changes" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "src", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/cachedemo.sexp", .data = "(design-block \"D\")" });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/cachedemo.layouts.json",
        .data =
        \\{"default":"hand","layouts":[{"name":"hand","kind":"manual","ts":2,"parts":[]}]}
        ,
    });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const first = read(alloc, root, "cachedemo");
    try testing.expect(first.starred);
    try testing.expectEqual(@as(usize, 1), first.count);

    // Second read of an unchanged file is served from the cache — same answer,
    // without re-parsing the (potentially multi-megabyte) sidecar.
    const cached = read(alloc, root, "cachedemo");
    try testing.expect(cached.starred);
    try testing.expectEqual(@as(usize, 1), cached.count);

    // Un-starring rewrites the sidecar: a different size, so the next read must
    // go back to disk rather than repeat the stale verdict.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/cachedemo.layouts.json",
        .data =
        \\{"layouts":[{"name":"hand","kind":"manual","ts":2,"parts":[]},{"name":"b","kind":"auto","ts":3,"parts":[]}]}
        ,
    });
    const after = read(alloc, root, "cachedemo");
    try testing.expect(!after.starred);
    try testing.expectEqual(@as(usize, 2), after.count);
}

// spec: Web Server - Module-layout status reads rough and starred flags from the layouts sidecar
test "parse reads rough and starred flags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const body =
        \\{"default":"hand","layouts":[
        \\ {"name":"rough seed","kind":"auto","ts":1,"rough":true,"parts":[]},
        \\ {"name":"hand","kind":"manual","ts":2,"parts":[]}
        \\]}
    ;
    const st = parse(alloc, body);
    try std.testing.expect(st.present);
    try std.testing.expect(st.rough);
    try std.testing.expect(st.starred);
    try std.testing.expectEqual(@as(usize, 2), st.count);
}

// spec: Web Server - Module-layout status reports neither rough nor starred when none recorded
test "parse with no rough and no default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const body =
        \\{"layouts":[{"name":"a","kind":"auto","ts":1,"parts":[]}]}
    ;
    const st = parse(alloc, body);
    try std.testing.expect(st.present);
    try std.testing.expect(!st.rough);
    try std.testing.expect(!st.starred);
    try std.testing.expectEqual(@as(usize, 1), st.count);
}

// spec: Web Server - Module-layout status of a missing sidecar is all-false
test "parse of empty or malformed body is all-false" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const st = parse(alloc, "not json");
    try std.testing.expect(!st.present);
    try std.testing.expect(!st.rough);
    try std.testing.expect(!st.starred);
    try std.testing.expectEqual(@as(usize, 0), st.count);
}
