//! Dependency-aware rendered-HTML cache for the assembly workspace.
//!
//! The page's PCB iframe already has its own cache, but the parent workspace
//! still re-evaluated the complete design and rebuilt its BOM/search index on
//! every open. This store retains that finished HTML and validates it against
//! the evaluator read-set, BOM siblings, rework-guide files, datasheet names,
//! and the design's live-edit version.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const cache_core = @import("cache_core.zig");
const paths = @import("../paths.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const page_cache = @import("page_cache.zig");

const max_entries: usize = 32;
const max_assembly_cache_bytes: usize = 32 * 1024 * 1024;
const cache_header = "X-Netlisp-Assembly-Page-Cache";

const Identity = struct { layout: ?[]const u8 };

pub const Entry = struct {
    html: []const u8,
    files: page_cache.FileSet,
    live_version: u32,
    used: u64,
};

/// The assembly client consumes these parameters from its own URL. Only
/// `layout` changes server-rendered HTML, and therefore participates in the
/// key; unknown parameters bypass so a future server-side feature cannot
/// accidentally reuse an older page shape.
const client_params = [_][]const u8{
    "board_rotation",
    "board_side",
    "guide",
    "mode",
    "models",
    "q",
    "target",
    "type",
};

fn identity(req: *httpz.Request) ?Identity {
    const q = req.query() catch return null;
    var it = q.iterator();
    outer: while (it.next()) |field| {
        if (std.mem.eql(u8, field.key, "layout")) continue;
        for (client_params) |allowed| {
            if (std.mem.eql(u8, field.key, allowed)) continue :outer;
        }
        return null;
    }
    const layout = q.get("layout");
    return .{ .layout = if (layout) |value| if (value.len > 0) value else null else null };
}

fn cacheKey(allocator: std.mem.Allocator, name: []const u8, ident: Identity) std.mem.Allocator.Error![]const u8 {
    if (ident.layout) |layout| return std.fmt.allocPrint(allocator, "{s}\x00layout\x00{s}", .{ name, layout });
    return std.fmt.allocPrint(allocator, "{s}\x00default", .{name});
}

pub const ServeIn = struct {
    scratch: std.mem.Allocator,
    name: []const u8,
    live_version: u32,
};

/// One server instance's bounded assembly-workspace cache.
pub const Store = struct {
    allocator: ?std.mem.Allocator = null,
    mutex: infra_fs.Mutex = .{},
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    bytes: usize = 0,
    use_clock: u64 = 0,

    fn nextUse(self: *Store) u64 {
        self.use_clock +%= 1;
        return self.use_clock;
    }

    /// Release one entry and un-charge its bytes. `pub` because it is the
    /// contract `cache_core`'s shared eviction sweep and teardown call back
    /// into; nothing outside this module has any reason to.
    pub fn freeEntry(self: *Store, allocator: std.mem.Allocator, key: []const u8, entry: Entry) void {
        self.bytes -= entry.html.len;
        allocator.free(key);
        allocator.free(entry.html);
        entry.files.deinit();
    }

    /// Evict least-recently-used until the store is back inside both budgets.
    /// `Entry` carries no `plain` flag: `layout` is the only key this store has
    /// a variant on, and a named board is no less worth keeping than the
    /// default one, so the shared sweep runs in plain recency order.
    fn trim(self: *Store, allocator: std.mem.Allocator) void {
        cache_core.evictLru(self, allocator, max_entries, max_assembly_cache_bytes);
    }

    /// Free all retained pages when the owning server stops.
    pub fn deinit(self: *Store) void {
        self.mutex.lock();
        cache_core.freeAll(self);
        self.mutex.unlock();
        self.* = .{};
    }

    /// Answer a valid hit into this request's arena. `miss_version` captures
    /// the version before a miss render so the later store can reject an edit
    /// that raced it.
    pub fn serve(
        self: *Store,
        in: ServeIn,
        req: *httpz.Request,
        res: *httpz.Response,
        miss_version: *?u32,
    ) bool {
        const allocator = self.allocator orelse return false;
        miss_version.* = null;
        const ident = identity(req) orelse {
            res.header(cache_header, "bypass");
            return false;
        };
        const key = cacheKey(in.scratch, in.name, ident) catch return false;
        defer in.scratch.free(key);

        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.entries.getPtr(key) orelse {
            miss_version.* = in.live_version;
            res.header(cache_header, "miss");
            return false;
        };
        if (entry.live_version != in.live_version or !entry.files.isValid()) {
            const removed = self.entries.fetchRemove(key).?;
            self.freeEntry(allocator, removed.key, removed.value);
            miss_version.* = in.live_version;
            res.header(cache_header, "miss");
            return false;
        }
        const body = in.scratch.dupe(u8, entry.html) catch {
            miss_version.* = in.live_version;
            res.header(cache_header, "miss");
            return false;
        };
        entry.used = self.nextUse();
        res.header(cache_header, "hit");
        res.content_type = .HTML;
        res.body = body;
        return true;
    }

    /// Retain a successful miss. Every allocation here is best-effort: cache
    /// failure falls back to the already-rendered response.
    pub fn store(self: *Store, in: anytype) void {
        const allocator = self.allocator orelse return;
        const live_version = in.live_version orelse return;
        if (in.res.status != 200 or in.res.content_type != .HTML or
            in.current_version != live_version or in.res.body.len > max_assembly_cache_bytes) return;
        const ident = identity(in.req) orelse return;

        var files = page_cache.capture(in.scratch, in.eval, in.project_dir, in.name) catch return;
        var files_owned = true;
        defer if (files_owned) files.deinit();
        const source = paths.designSourcePath(in.scratch, in.project_dir, in.name) catch return;
        defer in.scratch.free(source);
        const source_dir = std.fs.path.dirname(source) orelse ".";
        // Guide discovery depends on both guide filenames/content and whether
        // a same-prefix .sexp exists and therefore owns one of those guides.
        page_cache.appendDirFiles(&files, in.scratch, source_dir, ".rework.md") catch return;
        page_cache.appendDirListing(&files, source_dir, ".sexp") catch return;
        // The page embeds only links for declared PDFs that currently exist.
        const datasheets = std.fmt.allocPrint(in.scratch, "{s}/lib/datasheets", .{in.project_dir}) catch return;
        defer in.scratch.free(datasheets);
        page_cache.appendDirListing(&files, datasheets, ".pdf") catch return;
        if (in.current_version != live_version or !files.isValid()) return;

        const body = allocator.dupe(u8, in.res.body) catch return;
        var body_owned = true;
        defer if (body_owned) allocator.free(body);
        const scratch_key = cacheKey(in.scratch, in.name, ident) catch return;
        defer in.scratch.free(scratch_key);
        const key = allocator.dupe(u8, scratch_key) catch return;
        var key_owned = true;
        defer if (key_owned) allocator.free(key);

        self.mutex.lock();
        defer self.mutex.unlock();
        const gop = self.entries.getOrPut(allocator, key) catch return;
        if (gop.found_existing) {
            allocator.free(key);
            key_owned = false;
            self.bytes -= gop.value_ptr.html.len;
            allocator.free(gop.value_ptr.html);
            gop.value_ptr.files.deinit();
        } else {
            key_owned = false;
        }
        gop.value_ptr.* = .{
            .html = body,
            .files = files,
            .live_version = live_version,
            .used = self.nextUse(),
        };
        body_owned = false;
        files_owned = false;
        self.bytes += body.len;
        self.trim(allocator);
    }
};

test "assembly page cache keys only server-rendered query state" {
    var client = httpz.testing.init(.{});
    defer client.deinit();
    client.query("guide", "bypass");
    client.query("board_side", "bottom");
    try std.testing.expect(identity(client.req) != null);
    try std.testing.expect(identity(client.req).?.layout == null);

    var layout = httpz.testing.init(.{});
    defer layout.deinit();
    layout.query("layout", "RF-final");
    try std.testing.expectEqualStrings("RF-final", identity(layout.req).?.layout.?);

    var future = httpz.testing.init(.{});
    defer future.deinit();
    future.query("unknown-render-mode", "1");
    try std.testing.expect(identity(future.req) == null);
}

// spec: Web Server - Repeat assembly workspace loads reuse dependency-validated HTML and invalidate when rework-guide availability changes
test "assembly page cache hits then invalidates when a rework guide appears" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "src", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.sexp", .data = "(design-block \"Demo\")" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const source = try std.fmt.allocPrint(testing.allocator, "{s}/src/demo.sexp", .{root});
    defer testing.allocator.free(source);

    var eval_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer eval_arena.deinit();
    var eval = Evaluator.init(eval_arena.allocator(), root);
    defer eval.deinit();
    _ = eval.evalFile(source) catch {};

    var cache: Store = .{ .allocator = testing.allocator };
    defer cache.deinit();
    var first = httpz.testing.init(.{});
    defer first.deinit();
    var version: ?u32 = null;
    try testing.expect(!cache.serve(.{ .scratch = first.arena, .name = "demo", .live_version = 0 }, first.req, first.res, &version));
    first.res.status = 200;
    first.res.content_type = .HTML;
    first.res.body = "cached-assembly";
    cache.store(.{
        .scratch = first.arena,
        .project_dir = root,
        .name = "demo",
        .req = first.req,
        .eval = &eval,
        .res = first.res,
        .live_version = version,
        .current_version = @as(u32, 0),
    });

    var hit = httpz.testing.init(.{});
    defer hit.deinit();
    try testing.expect(cache.serve(.{ .scratch = hit.arena, .name = "demo", .live_version = 0 }, hit.req, hit.res, &version));
    try testing.expectEqualStrings("cached-assembly", hit.res.body);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.rework.md", .data = "# New guide" });
    var stale = httpz.testing.init(.{});
    defer stale.deinit();
    try testing.expect(!cache.serve(.{ .scratch = stale.arena, .name = "demo", .live_version = 0 }, stale.req, stale.res, &version));
}
