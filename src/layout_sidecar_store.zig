//! Filesystem-backed `.layouts.json` store.
//!
//! Parsing, revision handling, cache fallback, serialization and de-duplication
//! live together here.  The PCB page keeps only request/render policy; other
//! consumers can read the persisted model without compiling that page.

const std = @import("std");
const clock = @import("infra/clock.zig");
const infra_fs = @import("infra/fs.zig");
const log = @import("infra/log.zig");
const numeric = @import("numeric.zig");
const optimizer = @import("placement/optimizer.zig");
const paths = @import("paths.zig");
const pcb_part_json = @import("serve/pcb_part_json.zig");
const codec = @import("serve/layout_sidecar_json.zig");
const sketch_codec = @import("serve/shape_sketch_json.zig");
const model = @import("layout_sidecar_types.zig");

const PartPose = model.PartPose;
const SavedLayout = model.SavedLayout;
const SavedTrack = model.SavedTrack;
const SavedVia = model.SavedVia;
const LayoutScore = model.LayoutScore;

pub const layouts_ext = ".layouts.json";
pub const sidecar_max_bytes: usize = 16 << 20;
pub const kind_manual = "manual";
pub const kind_auto = "auto";
const max_auto_layouts: usize = 12;
const auto_ext = ".autolayout.json";

// ── Sidecar write serialization ──────────────────────────────────────────────
//
// Every sidecar mutation is a read-modify-write: read `rev` (and usually the
// whole layout list), decide, write `rev + 1`. Nothing about that is atomic on
// its own, and the server runs handlers on a thread pool with a detached regen
// thread beside them. Two saves that both observed `rev = 5` both passed the
// optimistic-concurrency guard, both wrote `rev = 6`, and both clients were told
// `6` — the first save's row simply vanished. The GET-side dedup rewrite and the
// regen thread's auto-record are worse still: they read-then-write the CURRENT
// rev, so they clobber a concurrent save without ever tripping the guard.
//
// The fix is a lock held across the whole check-then-write span, taken by the
// CALLER (the site that owns the read-modify-write), never inside the writers —
// `std.Io.Mutex` is not reentrant, and the writers are reached from inside
// already-locked spans. Long work (design resolve, solving, scoring, pouring)
// stays outside: those spans compute first and lock only around the
// read-modify-write, so the lock never serializes the editor.
//
// Slots, not a keyed registry: a fixed table hashed by (design, sub) needs no
// allocation, no map, and no entry lifetime, and a hash collision only
// over-serializes two unrelated designs — it can never under-serialize one,
// because the same sidecar always hashes to the same slot.
const sidecar_lock_slots = 16;
var sidecar_locks: [sidecar_lock_slots]infra_fs.Mutex = @splat(.{});

/// Held ownership of one sidecar's write lock. `defer guard.unlock()`.
pub const SidecarGuard = struct {
    mu: *infra_fs.Mutex,

    /// Release the sidecar lock.
    pub fn unlock(self: SidecarGuard) void {
        self.mu.unlock();
    }
};

/// The lock slot serializing `<design>[.<sub>].layouts.json`.
fn sidecarMutex(name: []const u8, sub: ?[]const u8) *infra_fs.Mutex {
    var hash = std.hash.Wyhash.init(0x5f_53_49_44_45_43_41_52);
    hash.update(name);
    hash.update("\x00");
    if (sub) |slug| hash.update(slug);
    return &sidecar_locks[@intCast(hash.final() % sidecar_lock_slots)];
}

/// The revision a client claims it last saw, read out of a request body's
/// `"rev"` field, or null when it sent none.
///
/// A JSON number reaches us as either an integer or a float depending on how
/// the client serialized it, and a float is narrowed through `checkedInt` so a
/// NaN or an out-of-range value is "no revision" rather than an out-of-range
/// cast. Absent, wrong-typed and unrepresentable all collapse to null, which
/// every caller treats as "the client is not asserting a revision" — the
/// optimistic guard then admits the write, exactly as it did before revisions
/// existed.
pub fn clientRev(value: ?std.json.Value) ?i64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| numeric.checkedInt(i64, f),
        else => null,
    };
}

/// Enter the read-compare-write critical section for one design's sidecar.
///
/// Take this around the WHOLE span — the `rev` read, the conflict comparison,
/// the history snapshot, the list read and the write — not just the write, or
/// the guard stays a lockless check-then-write. Never take it around solving,
/// scoring, or design resolution.
pub fn lockSidecar(name: []const u8, sub: ?[]const u8) SidecarGuard {
    const mu = sidecarMutex(name, sub);
    mu.lock();
    return .{ .mu = mu };
}

/// Optimizer parameters and poses persisted in the sidecar's cache slot.
pub const CacheSlot = struct {
    params: optimizer.Params,
    parts: ?[]const PartPose,
};

/// One parsed sidecar document, including revision and optional cache.
pub const SidecarDoc = struct {
    layouts: []const SavedLayout = &.{},
    cache: ?CacheSlot = null,
    rev: i64 = 0,
    /// Parsed from the same immutable bytes as `layouts`; manufacturing
    /// validation inspects this tree instead of rereading the sidecar.
    root: ?std.json.Value = null,
};

/// Compact pose exposed to KiCad synchronization callers.
pub const SyncPose = struct { x: f64, y: f64, rot: f64, side: optimizer.Side = .top };
/// Saved snapshot chosen for synchronization and an optional fuller fallback.
pub const SnapshotChoice = struct {
    chosen: *const SavedLayout,
    alt: ?*const SavedLayout = null,
    alt_n: usize = 0,
};

/// Resolve a design or scoped sub-block sidecar path.
pub fn layoutsSidecar(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    sub: ?[]const u8,
    ext: []const u8,
) ?[]u8 {
    const scope = sub orelse return paths.designSiblingPath(alloc, project_dir, name, ext) catch null;
    const src = paths.designSourcePath(alloc, project_dir, name) catch return null;
    defer alloc.free(src);
    const dir = std.fs.path.dirname(src) orelse ".";
    return std.fmt.allocPrint(alloc, "{s}/{s}.{s}{s}", .{ dir, name, scope, ext }) catch null;
}

/// Read a design's saved layouts, returning empty on absence or parse failure.
pub fn readLayouts(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) []const SavedLayout {
    return readLayoutsSub(alloc, project_dir, name, null);
}

/// Return whether a design has a saved row with the exact requested name.
pub fn hasSavedLayout(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, want: []const u8) bool {
    for (readLayouts(alloc, project_dir, name)) |layout| {
        if (std.mem.eql(u8, layout.name, want)) return true;
    }
    return false;
}

/// Read layouts from a design or sub-block scoped sidecar.
pub fn readLayoutsSub(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    sub: ?[]const u8,
) []const SavedLayout {
    return readSidecarDoc(alloc, project_dir, name, sub).layouts;
}

/// Parse a `.layouts.json` document, or null for malformed top-level JSON.
pub fn parseLayouts(alloc: std.mem.Allocator, data: []const u8) ?[]const SavedLayout {
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, data, .{}) catch return null;
    return layoutsFromRoot(alloc, root);
}

fn layoutsFromRoot(alloc: std.mem.Allocator, root: std.json.Value) ?[]const SavedLayout {
    if (root != .object) return null;
    const value = root.object.get("layouts") orelse return null;
    if (value != .array) return null;
    const default_name: []const u8 = blk: {
        const found = root.object.get("default") orelse break :blk "";
        break :blk if (found == .string) found.string else "";
    };
    var list: std.ArrayList(SavedLayout) = .empty;
    for (value.array.items) |item| {
        if (item != .object) continue;
        const name_value = item.object.get("name") orelse continue;
        if (name_value != .string) continue;
        const kind: []const u8 = blk: {
            const found = item.object.get("kind") orelse break :blk kind_auto;
            break :blk if (found == .string and std.mem.eql(u8, found.string, kind_manual)) kind_manual else kind_auto;
        };
        var score: ?LayoutScore = null;
        if (item.object.get("hpwl") != null) score = .{
            .hpwl = codec.jsonNum(item.object.get("hpwl")),
            .loop = codec.jsonNum(item.object.get("loop")),
            .caps = numeric.toCount(@max(@floor(codec.jsonNum(item.object.get("caps"))), 0)),
            .objective = codec.jsonNum(item.object.get("objective")),
        };
        const parts = codec.parsePartPoses(alloc, item.object.get("parts")) orelse &[_]PartPose{};
        const rough_value = item.object.get("rough");
        const rough = if (rough_value) |rv| rv == .bool and rv.bool else false;
        list.append(alloc, .{
            .name = name_value.string,
            .kind = kind,
            .ts = numeric.checkedInt(i64, codec.jsonNum(item.object.get("ts"))) orelse 0,
            .score = score,
            .parts = parts,
            .default = default_name.len > 0 and std.mem.eql(u8, name_value.string, default_name),
            .rough = rough,
            .routes = codec.parseSavedRoutes(alloc, item.object.get("routes")),
            .outline = codec.parseSavedOutline(alloc, item.object.get("outline")),
            .fabrication_layers = codec.parseSavedFabricationLayers(alloc, item.object.get("fabrication_layers")),
            .heatsink = codec.parseSavedHeatsink(item.object.get("heatsink")),
            .texts = codec.parseSavedTexts(alloc, item.object.get("texts")),
            .dimensions = codec.parsePartEdgeDimensions(alloc, item.object.get("dimensions")),
        }) catch return list.items;
    }
    return list.toOwnedSlice(alloc) catch null;
}

const ParseFailureCoverage = struct {
    incomplete: bool = false,
    zone_layers: bool = false,
    zone_sketch: bool = false,
};

fn rawReleaseSketch(root: std.json.Value) ?std.json.Value {
    const layouts = root.object.get("layouts") orelse return null;
    for (layouts.array.items) |row| {
        if (row != .object) continue;
        const name = row.object.get("name") orelse continue;
        if (name != .string or !std.mem.eql(u8, name.string, "release")) continue;
        const routes = row.object.get("routes") orelse return null;
        const zones = routes.object.get("zones") orelse return null;
        if (zones.array.items.len < 2) return null;
        return zones.array.items[1].object.get("sketch");
    }
    return null;
}

fn partialSelectedParseCoverage(test_allocator: std.mem.Allocator, root: std.json.Value) ParseFailureCoverage {
    var coverage = ParseFailureCoverage{};
    const raw_sketch = rawReleaseSketch(root) orelse return coverage;
    for (0..256) |fail_index| {
        var arena_state = std.heap.ArenaAllocator.init(test_allocator);
        defer arena_state.deinit();
        var failing = std.testing.FailingAllocator.init(arena_state.allocator(), .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        const layouts = layoutsFromRoot(allocator, root) orelse continue;
        for (layouts) |layout| {
            if (!std.mem.eql(u8, layout.name, "release")) continue;
            if (!failing.has_induced_failure) continue;
            const complete = codec.selectedLayoutParsedEvidence(allocator, root, layout);
            if (!complete) coverage.incomplete = true;
            const routes = layout.routes orelse continue;
            if (routes.zones.len < 2) continue;
            const zone = routes.zones[1];
            if (!complete and zone.layers.len != 2) coverage.zone_layers = true;
            if (!complete) {
                const parsed_sketch = zone.sketch orelse {
                    coverage.zone_sketch = true;
                    continue;
                };
                if (!sketch_codec.matches(raw_sketch, parsed_sketch)) coverage.zone_sketch = true;
            }
        }
    }
    return coverage;
}

// spec: fabrication-release - allocation failure while parsing a valid selected sidecar row is non-waivable incomplete evidence rather than silently dropped copper or silk
test "selected sidecar typed parsing is proven one-to-one with raw manufacturing data" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const source =
        "{\"default\":\"release\",\"layouts\":[" ++
        "{\"name\":\"older\",\"parts\":[{\"ref\":\"U1\",\"x\":0,\"y\":0,\"rot\":0}]}," ++
        "{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}]," ++
        "\"routes\":{\"tracks\":[{\"x1\":0,\"y1\":0,\"x2\":1,\"y2\":1,\"w\":0.2,\"net\":\"N\"}]," ++
        "\"zones\":[{\"net\":\"GND\",\"layer\":\"F.Cu\",\"poly\":[[0,0],[2,0],[2,2]]}," ++
        "{\"net\":\"GND\",\"layer\":\"F.Cu\",\"layers\":[\"F.Cu\",\"B.Cu\"],\"poly\":[[0,0],[4,0],[4,4],[0,4]]," ++
        "\"sketch\":{\"version\":1,\"points\":[{\"id\":1,\"x\":0,\"y\":0},{\"id\":2,\"x\":4,\"y\":0},{\"id\":3,\"x\":4,\"y\":4},{\"id\":4,\"x\":0,\"y\":4}]," ++
        "\"curves\":[{\"id\":11,\"kind\":\"line\",\"a\":1,\"b\":2},{\"id\":12,\"kind\":\"line\",\"a\":2,\"b\":3},{\"id\":13,\"kind\":\"line\",\"a\":3,\"b\":4},{\"id\":14,\"kind\":\"line\",\"a\":4,\"b\":1}],\"constraints\":[]}}]}," ++
        "\"texts\":[{\"text\":\"REV A\",\"x\":1,\"y\":2,\"rot\":0,\"size\":1}]}]}";
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), source, .{});
    const coverage = partialSelectedParseCoverage(std.testing.allocator, root);
    try std.testing.expect(coverage.incomplete);
    try std.testing.expect(coverage.zone_layers);
    try std.testing.expect(coverage.zone_sketch);
}

// spec: Web Server - Reading a saved layout back out of its sidecar drops the collapsed sub-micron crumbs its copper carries, so an old board opens healed without its file being edited
test "reading a sidecar heals a board whose copper carries drag crumbs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // The barracuda crumb: a segment dragged onto its own end, sitting on a
    // through via. Reading it back must not put that island on the board.
    const source =
        "{\"default\":\"release\",\"layouts\":[{\"name\":\"release\",\"kind\":\"manual\"," ++
        "\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}],\"routes\":{\"tracks\":[" ++
        "{\"x1\":180,\"y1\":93.1,\"x2\":182.21,\"y2\":93.1,\"l\":1,\"w\":0.127,\"net\":\"V_5VA\",\"id\":\"seg-run\"}," ++
        "{\"x1\":182.21,\"y1\":93.1,\"x2\":182.21,\"y2\":93.1,\"l\":1,\"w\":0.127,\"net\":\"V_5VA\",\"id\":\"seg-crumb\"}]}}]}";
    const layouts = parseLayouts(arena_state.allocator(), source).?;
    try std.testing.expectEqual(@as(usize, 1), layouts.len);
    const tracks = layouts[0].routes.?.tracks;
    try std.testing.expectEqual(@as(usize, 1), tracks.len);
    try std.testing.expectEqualStrings("seg-run", tracks[0].id);
}

/// Parse the sidecar cache object and its placement parameters.
pub fn parseCacheSlot(alloc: std.mem.Allocator, value: std.json.Value) ?CacheSlot {
    if (value != .object) return null;
    var params = optimizer.Params{};
    if (value.object.get("params")) |po| if (po == .object) parseCacheParams(po, &params);
    return .{ .params = params, .parts = codec.parsePartPoses(alloc, value.object.get("parts")) };
}

fn parseCacheParams(object: std.json.Value, params: *optimizer.Params) void {
    if (object.object.get("loop_w")) |v| params.loop_w = codec.jsonNum(v);
    if (object.object.get("w_congest")) |v| params.w_congest = codec.jsonNum(v);
    if (object.object.get("cap_w_max")) |v| params.cap_w_max = codec.jsonNum(v);
    if (object.object.get("grid")) |v| params.grid_courtyards = v == .bool and v.bool;
    if (object.object.get("w_align")) |v| {
        const align_value = codec.jsonNum(v);
        if (align_value >= 0 and align_value != 0.5) params.w_align = align_value;
    }
}

/// Read the embedded cache, falling back to a legacy standalone cache file.
pub fn readCacheSlot(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?CacheSlot {
    return readSidecarDoc(alloc, project_dir, name, null).cache orelse readLegacyCacheSlot(alloc, project_dir, name);
}

fn readLegacyCacheSlot(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?CacheSlot {
    const path = paths.designSiblingPath(alloc, project_dir, name, auto_ext) catch return null;
    defer alloc.free(path);
    const data = infra_fs.cwd().readFileAlloc(alloc, path, sidecar_max_bytes) catch return null;
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, data, .{}) catch return null;
    return parseCacheSlot(alloc, root);
}

/// Read the optimistic-concurrency revision, defaulting to zero.
pub fn readLayoutRev(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    sub: ?[]const u8,
) i64 {
    return readSidecarDoc(alloc, project_dir, name, sub).rev;
}

fn revFromRoot(root: std.json.Value) i64 {
    if (root != .object) return 0;
    const value = root.object.get("rev") orelse return 0;
    return switch (value) {
        .integer => |integer| integer,
        .float => |float| numeric.checkedInt(i64, float) orelse 0,
        else => 0,
    };
}

/// Read one design document with its legacy cache fallback applied.
pub fn readDesignDoc(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) SidecarDoc {
    var doc = readSidecarDoc(alloc, project_dir, name, null);
    if (doc.cache == null) doc.cache = readLegacyCacheSlot(alloc, project_dir, name);
    return doc;
}

/// Read and parse one sidecar in a single filesystem pass.
pub fn readSidecarDoc(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    sub: ?[]const u8,
) SidecarDoc {
    var doc = SidecarDoc{};
    const path = layoutsSidecar(alloc, project_dir, name, sub, layouts_ext) orelse return doc;
    defer alloc.free(path);
    const data = infra_fs.cwd().readFileAlloc(alloc, path, sidecar_max_bytes) catch |err| {
        if (err != error.FileNotFound) log.warn("layouts: cannot read {s}: {s} — reading as NO saved layouts", .{ path, @errorName(err) });
        return doc;
    };
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, data, .{}) catch {
        log.warn("layouts: {s} did not parse — reading as NO saved layouts", .{path});
        return doc;
    };
    doc.root = root;
    if (layoutsFromRoot(alloc, root)) |layouts| doc.layouts = layouts;
    if (root == .object) {
        if (root.object.get("cache")) |cache| doc.cache = parseCacheSlot(alloc, cache);
    }
    doc.rev = revFromRoot(root);
    return doc;
}

fn writeFileAll(path: []const u8, data: []const u8) !void {
    var write_buf: [4096]u8 = undefined;
    var atomic = try infra_fs.cwd().atomicFile(path, .{ .write_buffer = &write_buf });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(data);
    try atomic.finish();
}

/// Best-effort persistence that preserves the design cache and revision.
pub fn writeLayouts(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, layouts: []const SavedLayout) void {
    writeLayoutsFile(alloc, project_dir, name, layouts, readCacheSlot(alloc, project_dir, name), readLayoutRev(alloc, project_dir, name, null));
}

/// Best-effort scoped persistence that preserves the current revision.
pub fn writeLayoutsSub(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    sub: ?[]const u8,
    layouts: []const SavedLayout,
) void {
    writeLayoutsSubRev(alloc, project_dir, name, sub, layouts, readLayoutRev(alloc, project_dir, name, sub));
}

/// Persist a design or sub-block sidecar with an explicit revision.
pub fn writeLayoutsSubRev(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    sub: ?[]const u8,
    layouts: []const SavedLayout,
    rev: i64,
) void {
    if (sub == null) return writeLayoutsFile(alloc, project_dir, name, layouts, readCacheSlot(alloc, project_dir, name), rev);
    const path = layoutsSidecar(alloc, project_dir, name, sub, layouts_ext) orelse return;
    defer alloc.free(path);
    var output: std.Io.Writer.Allocating = .init(alloc);
    writeLayoutsFileJsonRev(&output.writer, dedupedLayouts(alloc, layouts), null, rev) catch return;
    writeFileAll(path, output.written()) catch return;
}

/// Persist the complete design sidecar with layouts, cache, and revision.
pub fn writeLayoutsFile(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    layouts: []const SavedLayout,
    cache: ?CacheSlot,
    rev: i64,
) void {
    const path = paths.designSiblingPath(alloc, project_dir, name, layouts_ext) catch return;
    defer alloc.free(path);
    var output: std.Io.Writer.Allocating = .init(alloc);
    writeLayoutsFileJsonRev(&output.writer, dedupedLayouts(alloc, layouts), cache, rev) catch return;
    writeFileAll(path, output.written()) catch return;
}

/// Return layouts whose exact duplicate copper rows have been removed.
pub fn dedupedLayouts(alloc: std.mem.Allocator, layouts: []const SavedLayout) []const SavedLayout {
    const out = alloc.alloc(SavedLayout, layouts.len) catch return layouts;
    for (layouts, 0..) |layout, i| {
        out[i] = layout;
        const routes = layout.routes orelse continue;
        out[i].routes = .{
            .tracks = dedupedTracks(alloc, routes.tracks),
            .vias = dedupedVias(alloc, routes.vias),
            .zones = routes.zones,
            .rf_paths = routes.rf_paths,
        };
    }
    return out;
}

/// Remove byte-identical track geometry while preserving first-row order.
///
/// The key names every field that makes a segment a different piece of copper —
/// both endpoints, the arc midpoint (present/absent as well as its value), the
/// layer, the width and the net. `g`/`source`/`id` are provenance and row
/// identity, deliberately left out for the same reason `dedupedVias` leaves out
/// `f`/`g`: two segments on the same layer between the same points at the same
/// width on the same net are ONE trace however they got there, and keying on
/// provenance would let a re-Stamp or an autoroute re-run persist a second copy
/// on top of the first. Unlike a via's `s`, a track carries no
/// electrically-distinguishing field outside this key.
pub fn dedupedTracks(alloc: std.mem.Allocator, tracks: []const SavedTrack) []const SavedTrack {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var out: std.ArrayList(SavedTrack) = .empty;
    for (tracks) |track| {
        const key = std.fmt.allocPrint(alloc, "{d},{d},{},{d},{d},{d},{d},{d},{d},{s}", .{
            track.x1,          track.y1,  track.xm != null and track.ym != null, track.xm orelse 0,
            track.ym orelse 0, track.x2,  track.y2,                              track.l,
            track.w,           track.net,
        }) catch return tracks;
        const found = seen.getOrPut(alloc, key) catch return tracks;
        if (found.found_existing) continue;
        out.append(alloc, track) catch return tracks;
    }
    return out.items;
}

/// Remove same-hole, same-net, same-SPAN vias while preserving first-row provenance.
///
/// The span (`SavedVia.s` — the `[from, to]` routable layer pair) is part of the
/// key because it is ELECTRICAL, not provenance: a through via `0..N` and a
/// blind/buried via `0..1` in the same hole on the same net connect different
/// layers, and the standalone via tool and the KiCad import can both produce
/// that pair. Keying without it collapsed them onto whichever came first and
/// silently rewrote the board's layer connectivity — invisible until fab,
/// because `s` round-trips correctly through parse and emit everywhere else.
/// A span-less via (`null`) keys distinctly from any explicit span.
pub fn dedupedVias(alloc: std.mem.Allocator, vias: []const SavedVia) []const SavedVia {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var out: std.ArrayList(SavedVia) = .empty;
    for (vias) |via| {
        // −1,−1 is the "no explicit span" sentinel; real span indices are u8.
        const span: [2]i16 = if (via.s) |s| .{ s[0], s[1] } else .{ -1, -1 };
        const key = std.fmt.allocPrint(alloc, "{d},{d},{d},{d},{s},{d},{d}", .{
            via.x, via.y, via.d, via.drill, via.net, span[0], span[1],
        }) catch return vias;
        const found = seen.getOrPut(alloc, key) catch return vias;
        if (found.found_existing) continue;
        out.append(alloc, via) catch return vias;
    }
    return out.items;
}

fn writeCacheSlotJson(w: *std.Io.Writer, cache: CacheSlot) std.Io.Writer.Error!void {
    try w.print("{{\"params\":{{\"loop_w\":{d},\"w_align\":{d},\"w_congest\":{d},\"cap_w_max\":{d},\"grid\":{s}}},\"parts\":[", .{
        cache.params.loop_w,
        cache.params.w_align,
        cache.params.w_congest,
        cache.params.cap_w_max,
        if (cache.params.grid_courtyards) "true" else "false",
    });
    for (cache.parts orelse &[_]PartPose{}, 0..) |part, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"ref\":");
        try codec.writeJsonStr(w, part.ref);
        try w.print(",\"x\":{d},\"y\":{d},\"rot\":{d}", .{ part.x, part.y, part.rot });
        try pcb_part_json.writePoseSideLocked(w, part.side, part.locked);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

/// Serialize a revision-zero sidecar document.
pub fn writeLayoutsFileJson(w: *std.Io.Writer, layouts: []const SavedLayout, cache: ?CacheSlot) std.Io.Writer.Error!void {
    return writeLayoutsFileJsonRev(w, layouts, cache, 0);
}

/// Serialize the canonical sidecar document with an explicit revision.
pub fn writeLayoutsFileJsonRev(
    w: *std.Io.Writer,
    layouts: []const SavedLayout,
    cache: ?CacheSlot,
    rev: i64,
) std.Io.Writer.Error!void {
    try w.writeByte('{');
    if (rev > 0) try w.print("\"rev\":{d},", .{rev});
    for (layouts) |layout| {
        if (!layout.default) continue;
        try w.writeAll("\"default\":");
        try codec.writeJsonStr(w, layout.name);
        try w.writeByte(',');
        break;
    }
    if (cache) |slot| {
        try w.writeAll("\"cache\":");
        try writeCacheSlotJson(w, slot);
        try w.writeByte(',');
    }
    try w.writeAll("\"layouts\":[");
    for (layouts, 0..) |layout, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try codec.writeJsonStr(w, layout.name);
        try w.writeAll(",\"kind\":");
        try codec.writeJsonStr(w, layout.kind);
        try w.print(",\"ts\":{d}", .{layout.ts});
        if (layout.rough) try w.writeAll(",\"rough\":true");
        if (layout.routes) |routes| {
            try w.writeAll(",\"routes\":");
            try codec.writeSavedRoutesJson(w, routes);
        }
        if (layout.outline) |outline| {
            try w.writeAll(",\"outline\":");
            try codec.writeSavedOutlineJson(w, outline);
        }
        if (layout.fabrication_layers.len > 0) {
            try w.writeAll(",\"fabrication_layers\":");
            try codec.writeSavedFabricationLayersJson(w, layout.fabrication_layers);
        }
        if (layout.heatsink) |heatsink| {
            try w.writeAll(",\"heatsink\":");
            try codec.writeSavedHeatsinkJson(w, heatsink);
        }
        if (layout.texts.len > 0) {
            try w.writeAll(",\"texts\":");
            try codec.writeSavedTextsJson(w, layout.texts);
        }
        if (layout.dimensions.len > 0) {
            try w.writeAll(",\"dimensions\":");
            try codec.writePartEdgeDimensionsJson(w, layout.dimensions);
        }
        if (layout.score) |score| try w.print(",\"hpwl\":{d},\"loop\":{d},\"caps\":{d},\"objective\":{d}", .{ score.hpwl, score.loop, score.caps, score.objective });
        try w.writeAll(",\"parts\":[");
        for (layout.parts, 0..) |part, pi| {
            if (pi > 0) try w.writeByte(',');
            try w.writeAll("{\"ref\":");
            try codec.writeJsonStr(w, part.ref);
            try w.print(",\"x\":{d},\"y\":{d},\"rot\":{d}", .{ part.x, part.y, part.rot });
            try pcb_part_json.writePoseSideLocked(w, part.side, part.locked);
            if (part.origin.len > 0) {
                try w.writeAll(",\"origin\":");
                try codec.writeJsonStr(w, part.origin);
            }
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}");
}

/// Compare the visible placement score terms using the panel's tolerance.
pub fn sameLayoutScore(a: ?LayoutScore, b: ?LayoutScore) bool {
    const left = a orelse return false;
    const right = b orelse return false;
    return @abs(left.objective - right.objective) < 0.1 and
        @abs(left.hpwl - right.hpwl) < 0.1 and
        @abs(left.loop - right.loop) < 0.1;
}

fn layoutMoreRecentlyEdited(_: void, a: SavedLayout, b: SavedLayout) bool {
    return a.ts > b.ts;
}

fn preferDuplicateLayout(incoming: SavedLayout, kept: SavedLayout, incoming_manual: bool, kept_manual: bool) bool {
    if (incoming_manual and !kept_manual) return true;
    if (!incoming.default) return false;
    return !kept_manual and !kept.default;
}

/// Collapse auto/manual duplicate arrangements without merging two manuals.
pub fn dedupLayouts(alloc: std.mem.Allocator, layouts: []const SavedLayout) []const SavedLayout {
    var out: std.ArrayList(SavedLayout) = .empty;
    for (layouts) |layout| {
        var merged = false;
        for (out.items) |*kept| {
            if (!sameLayoutScore(kept.score, layout.score)) continue;
            if (std.mem.eql(u8, kept.kind, kind_manual) and std.mem.eql(u8, layout.kind, kind_manual)) continue;
            const keep_default = kept.default or layout.default;
            const incoming_manual = std.mem.eql(u8, layout.kind, kind_manual);
            const kept_manual = std.mem.eql(u8, kept.kind, kind_manual);
            if (preferDuplicateLayout(layout, kept.*, incoming_manual, kept_manual)) kept.* = layout;
            kept.default = keep_default;
            merged = true;
            break;
        }
        if (!merged) out.append(alloc, layout) catch return layouts;
    }
    return out.items;
}

/// Return the de-duplicated, newest-first rows shown in the panel.
pub fn displayLayouts(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    sub: ?[]const u8,
    raw: []const SavedLayout,
) []const SavedLayout {
    const deduped = dedupLayouts(alloc, raw);
    // This is a WRITE on a plain GET render, and `raw` was read before any lock
    // existed. Writing `deduped` straight back would erase a save that landed in
    // between — and it would do so without ever consulting `rev`, so the save's
    // own optimistic-concurrency guard could not catch it. Re-read and re-dedup
    // under the lock instead: only rows still on disk can be collapsed, and if
    // the fresh copy has no duplicates the render writes nothing at all.
    if (deduped.len != raw.len) {
        const guard = lockSidecar(name, sub);
        defer guard.unlock();
        const fresh = readLayoutsSub(alloc, project_dir, name, sub);
        const fresh_deduped = dedupLayouts(alloc, fresh);
        if (fresh_deduped.len != fresh.len)
            writeLayoutsSub(alloc, project_dir, name, sub, fresh_deduped);
    }
    const sorted = alloc.dupe(SavedLayout, deduped) catch return deduped;
    std.sort.insertion(SavedLayout, sorted, {}, layoutMoreRecentlyEdited);
    return sorted;
}

fn posesFromPlacement(alloc: std.mem.Allocator, placement: optimizer.Placement) ?[]PartPose {
    const parts = alloc.alloc(PartPose, placement.parts.len) catch return null;
    for (placement.parts, 0..) |part, i| parts[i] = .{
        .ref = part.ref_des,
        .x = part.x,
        .y = part.y,
        .rot = part.rot,
        .origin = if (i < placement.instances.len) placement.instances[i].origin_key else "",
        .side = part.side,
        .locked = part.locked,
    };
    return parts;
}

/// Record a generated placement in bounded auto history when it is novel.
pub fn recordAutoLayout(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    placement: optimizer.Placement,
    params: optimizer.Params,
) void {
    const score = LayoutScore{
        .hpwl = placement.score.hpwl_mm,
        .loop = placement.score.loop_mm,
        .caps = placement.score.loop_caps,
        .objective = placement.breakdown.objective,
    };
    const parts = posesFromPlacement(alloc, placement) orelse return;
    // Read-modify-write on the same file a save writes, reached from the
    // detached regen thread as well as the render path — and it stamps the
    // CURRENT rev, so without this it clobbers a concurrent save silently.
    // Solving already finished in the caller; only the file work is inside.
    const guard = lockSidecar(name, null);
    defer guard.unlock();
    const existing = readLayouts(alloc, project_dir, name);
    for (existing, 0..) |layout, i| {
        if (!sameLayoutScore(layout.score, score)) continue;
        if (params.rough and !layout.rough) {
            tagRough(alloc, project_dir, name, existing, i);
        } else if (i == 0 and (layout.score == null or layout.score.?.objective <= 0)) {
            backfillNewestScore(alloc, project_dir, name, existing, score);
        }
        return;
    }
    const now = clock.timestamp();
    const entry = SavedLayout{
        .name = fmtAutoName(alloc, now) catch return,
        .kind = kind_auto,
        .ts = now,
        .score = score,
        .parts = parts,
        .rough = params.rough,
    };
    var out: std.ArrayList(SavedLayout) = .empty;
    out.append(alloc, entry) catch return;
    var autos: usize = 1;
    for (existing) |layout| {
        if (std.mem.eql(u8, layout.kind, kind_auto)) {
            if (autos >= max_auto_layouts and !layout.default) continue;
            autos += 1;
        }
        out.append(alloc, layout) catch break;
    }
    writeLayouts(alloc, project_dir, name, out.items);
}

fn tagRough(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, existing: []const SavedLayout, idx: usize) void {
    const out = alloc.dupe(SavedLayout, existing) catch return;
    out[idx].rough = true;
    writeLayouts(alloc, project_dir, name, out);
}

fn backfillNewestScore(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, existing: []const SavedLayout, score: LayoutScore) void {
    const out = alloc.dupe(SavedLayout, existing) catch return;
    out[0].score = score;
    writeLayouts(alloc, project_dir, name, out);
}

fn fmtAutoName(alloc: std.mem.Allocator, timestamp: i64) std.mem.Allocator.Error![]const u8 {
    const epoch = clock.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const day = epoch.getDaySeconds();
    const month_day = epoch.getEpochDay().calculateYearDay().calculateMonthDay();
    return std.fmt.allocPrint(alloc, "auto · {s} {d} {d:0>2}:{d:0>2}:{d:0>2}", .{
        monthAbbrev(month_day.month),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    });
}

fn monthAbbrev(month: clock.epoch.Month) []const u8 {
    return switch (month) {
        .jan => "Jan",
        .feb => "Feb",
        .mar => "Mar",
        .apr => "Apr",
        .may => "May",
        .jun => "Jun",
        .jul => "Jul",
        .aug => "Aug",
        .sep => "Sep",
        .oct => "Oct",
        .nov => "Nov",
        .dec => "Dec",
    };
}

/// Read cached placement poses for a design.
pub fn readAutoPoses(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?[]const optimizer.RefPose {
    return cachePoses(alloc, readCacheSlot(alloc, project_dir, name));
}

/// Convert an optional cache slot into optimizer reference poses.
pub fn cachePoses(alloc: std.mem.Allocator, cache: ?CacheSlot) ?[]const optimizer.RefPose {
    const slot = cache orelse return null;
    const parts = slot.parts orelse return null;
    return refPosesFromParts(alloc, parts);
}

/// Convert persisted part poses into optimizer reference poses.
pub fn refPosesFromParts(alloc: std.mem.Allocator, parts: []const PartPose) ?[]const optimizer.RefPose {
    const out = alloc.alloc(optimizer.RefPose, parts.len) catch return null;
    for (parts, 0..) |part, i| out[i] = .{
        .ref = part.ref,
        .x = part.x,
        .y = part.y,
        .rot = part.rot,
        .side = part.side,
        .locked = part.locked,
    };
    return out;
}

/// Choose default, manual, saved, then cached poses for synchronization.
pub fn chooseSyncPoses(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?[]const optimizer.RefPose {
    const layouts = readLayouts(alloc, project_dir, name);
    for (layouts) |layout| if (layout.default and layout.parts.len > 0) return refPosesFromParts(alloc, layout.parts);
    for (layouts) |layout| if (std.mem.eql(u8, layout.kind, kind_manual) and layout.parts.len > 0) return refPosesFromParts(alloc, layout.parts);
    for (layouts) |layout| if (layout.parts.len > 0) return refPosesFromParts(alloc, layout.parts);
    const poses = readAutoPoses(alloc, project_dir, name) orelse return null;
    return if (poses.len > 0) poses else null;
}

/// Choose the module snapshot with starred priority and coverage evidence.
pub fn chooseModuleSnapshot(
    layouts: []const SavedLayout,
    origin_of: *const std.StringHashMapUnmanaged([]const u8),
) ?SnapshotChoice {
    var starred: ?*const SavedLayout = null;
    var starred_score: usize = 0;
    var best: ?*const SavedLayout = null;
    var best_score: usize = 0;
    for (layouts) |*layout| {
        var score: usize = 0;
        for (layout.parts) |part| {
            const origin = origin_of.get(part.ref) orelse continue;
            if (origin.len > 0) score += 1;
        }
        if (score == 0) continue;
        if (layout.default) {
            starred = layout;
            starred_score = score;
            continue;
        }
        const current = best orelse {
            best = layout;
            best_score = score;
            continue;
        };
        const manual_wins_tie = score == best_score and
            std.mem.eql(u8, layout.kind, kind_manual) and
            !std.mem.eql(u8, current.kind, kind_manual);
        if (score > best_score or manual_wins_tie) {
            best = layout;
            best_score = score;
        }
    }
    if (starred) |layout| return .{
        .chosen = layout,
        .alt = if (best != null and best_score > starred_score) best else null,
        .alt_n = if (best != null and best_score > starred_score) best_score else 0,
    };
    return .{ .chosen = best orelse return null };
}

test "sidecar store removes identical copper while preserving order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const duplicate = SavedTrack{ .x1 = 1, .y1 = 2, .x2 = 3, .y2 = 4, .w = 0.2, .net = "GND" };
    const tracks = [_]SavedTrack{ duplicate, duplicate, .{ .x1 = 1, .y1 = 2, .x2 = 3, .y2 = 4, .l = 1, .w = 0.2, .net = "GND" } };
    try std.testing.expectEqual(@as(usize, 2), dedupedTracks(alloc, &tracks).len);
}

// A via's `s` layer span is ELECTRICAL: `[0,1]` is a blind via joining the top
// two layers and `[0,3]` a through via joining top to bottom. They can share a
// hole position, diameter, drill and net — the standalone via tool and the KiCad
// import both produce that pair — and the dedup key omitted `s`, so the second
// row was silently discarded on every save and the board's layer connectivity
// quietly changed. `s` round-trips correctly through emit and parse, so nothing
// downstream could reveal the loss before fabrication.
// spec: Web Server - Two saved vias that differ only in their layer span are different copper and both survive a sidecar save round-trip
test "the sidecar keeps two same-hole vias whose layer spans differ" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const blind = SavedVia{ .x = 5, .y = 6, .d = 0.4, .drill = 0.2, .net = "GND", .s = .{ 0, 1 } };
    var through = blind;
    through.s = .{ 0, 3 };
    var spanless = blind;
    spanless.s = null;

    // Genuine duplicates (including two identical spans) still collapse; the
    // three distinct spans — blind, through, and "no explicit span" — do not.
    const vias = [_]SavedVia{ blind, blind, through, spanless };
    const kept = dedupedVias(alloc, &vias);
    try std.testing.expectEqual(@as(usize, 3), kept.len);

    // Survives the actual save round-trip: serialize the sidecar, parse it back,
    // and both barrels are still there with their spans intact.
    const layouts = [_]SavedLayout{.{
        .name = "release",
        .kind = kind_manual,
        .ts = 0,
        .score = null,
        .parts = &.{},
        .routes = .{ .tracks = &.{}, .vias = &vias },
    }};
    var out: std.Io.Writer.Allocating = .init(alloc);
    try writeLayoutsFileJsonRev(&out.writer, dedupedLayouts(alloc, &layouts), null, 7);
    const parsed = parseLayouts(alloc, out.written()) orelse return error.TestExpectedParsedSidecar;
    try std.testing.expectEqual(@as(usize, 1), parsed.len);
    const round_tripped = (parsed[0].routes orelse return error.TestExpectedRoutes).vias;
    try std.testing.expectEqual(@as(usize, 3), round_tripped.len);
    try std.testing.expectEqual(@as(?[2]u8, .{ 0, 1 }), round_tripped[0].s);
    try std.testing.expectEqual(@as(?[2]u8, .{ 0, 3 }), round_tripped[1].s);
    try std.testing.expectEqual(@as(?[2]u8, null), round_tripped[2].s);
}

/// Source text of one function, from its signature to the next declaration.
fn storeFunctionBody(source: []const u8, signature: []const u8, next: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, source, signature) orelse return error.TestExpectedFunction;
    const tail = source[start..];
    const end = std.mem.indexOf(u8, tail, next) orelse return error.TestExpectedFunctionEnd;
    return tail[0..end];
}

// The two writers that reach the sidecar WITHOUT a rev check: `displayLayouts`
// rewrites a de-duplicated list during a plain GET render, and `recordAutoLayout`
// appends an auto row from the detached regen thread. Both read-then-write the
// CURRENT rev, so an unheld one overwrites a save that landed in between and the
// save's own optimistic-concurrency guard never fires — the clobbered client is
// told its write succeeded. They must therefore hold the same lock the save
// path holds, and `displayLayouts` must re-read inside it, because the list it
// was handed was read before the hold began.
//
// Threads are absent from THIS assertion by design. That the lock orders real
// concurrent writers is proven at the end of this file, on real OS threads;
// what cannot be reached without a live `httpz` harness is these two specific
// call sites, so what is pinned here is the structure the runtime guarantee
// then rests on.
// spec: Web Server - The revision-free sidecar writers, the render dedup and the regenerate record, re-read under the sidecar lock rather than trusting a value read before it
test "the render and regenerate sidecar writers hold the sidecar lock" {
    const source = @embedFile("layout_sidecar_store.zig");

    const display = try storeFunctionBody(source, "pub fn displayLayouts(", "fn posesFromPlacement(");
    const display_lock = std.mem.indexOf(u8, display, "lockSidecar(name, sub)") orelse
        return error.TestExpectedDisplayLock;
    const display_reread = std.mem.indexOf(u8, display, "readLayoutsSub(alloc, project_dir, name, sub)") orelse
        return error.TestExpectedDisplayReread;
    const display_write = std.mem.indexOf(u8, display, "writeLayoutsSub(") orelse
        return error.TestExpectedDisplayWrite;
    try std.testing.expect(display_lock < display_reread);
    try std.testing.expect(display_reread < display_write);

    const record = try storeFunctionBody(source, "pub fn recordAutoLayout(", "fn tagRough(");
    const record_lock = std.mem.indexOf(u8, record, "lockSidecar(name, null)") orelse
        return error.TestExpectedRecordLock;
    const record_read = std.mem.indexOf(u8, record, "readLayouts(alloc, project_dir, name)") orelse
        return error.TestExpectedRecordRead;
    const record_write = std.mem.indexOf(u8, record, "writeLayouts(alloc, project_dir, name") orelse
        return error.TestExpectedRecordWrite;
    try std.testing.expect(record_lock < record_read);
    try std.testing.expect(record_read < record_write);
}

// spec: Web Server - One sidecar always hashes to one lock slot and its guard releases it, so a collision only over-serializes and can never deadlock
test "one sidecar always maps to one lock slot and the guard releases it" {
    // Correctness rests on STABILITY, not on distinctness: the same sidecar must
    // always resolve to the same slot, or two writers get into one file at once.
    // Two different sidecars landing on one slot is merely extra serialization,
    // so nothing here asserts they differ — that would only test the hash.
    try std.testing.expect(sidecarMutex("board", null) == sidecarMutex("board", null));
    try std.testing.expect(sidecarMutex("board", "buck") == sidecarMutex("board", "buck"));
    // The design and its sub circuits are separately keyed, so they can (and
    // usually do) proceed independently.
    const keys = [_]?[]const u8{ null, "buck", "ldo", "rf" };
    for (keys) |key| {
        try std.testing.expect(sidecarMutex("board", key) == sidecarMutex("board", key));
    }

    // Taking the same slot twice in sequence must not deadlock — the guard
    // really does release, which is what every `defer guard.unlock()` relies on.
    {
        const guard = lockSidecar("board", null);
        guard.unlock();
    }
    const second = lockSidecar("board", null);
    second.unlock();
}

// Moved here from `serve/pcb_layout_page.zig` so all three sidecar-lock
// structure assertions sit together, and so the page file — already at 96%
// of its hard size cap — stops growing for test text.
// The rev guard is worth nothing if the check and the write are separate
// critical sections: two saves that both read `rev = 5` both pass the
// comparison, both write `rev = 6`, and the first one's row is gone while both
// clients are told `6`. So the authoritative rev read, the comparison it feeds,
// the history snapshot and the write must all sit inside ONE hold — while the
// design resolve, which dominates this handler's cost, must stay outside it or
// every concurrent editor queues behind a block evaluation.
//
// That the lock actually serializes concurrent writers is proven on real OS
// threads at the end of this file. Driving THIS handler that way additionally
// needs a live `httpz` server, so what is pinned here is the wiring that puts
// the handler's own check-then-write inside that proven critical section, the
// way "layout save validates before snapshotting recovery history" does.
// spec: Web Server - A named layout save holds one sidecar lock across its whole revision check-then-write, so two saves that observed the same revision cannot both be accepted
test "the layout save holds one sidecar lock across its whole revision check-then-write" {
    const source = @embedFile("serve/pcb_layout_page.zig");
    const handler_start = std.mem.indexOf(u8, source, "pub fn saveNamedLayoutApi") orelse
        return error.TestExpectedSaveHandler;
    const handler_tail = source[handler_start..];
    const handler_end = std.mem.indexOf(u8, handler_tail, "pub fn pcbLayoutHistoryApi") orelse
        return error.TestExpectedHistoryHandler;
    const handler = handler_tail[0..handler_end];

    const lock = std.mem.indexOf(u8, handler, "const guard = lockSidecar(name, sub);") orelse
        return error.TestExpectedSidecarLock;
    const rev_read = std.mem.indexOf(u8, handler, "const disk_rev = readLayoutRev(") orelse
        return error.TestExpectedRevRead;
    const bump = std.mem.indexOf(u8, handler, "const new_rev = disk_rev + 1;") orelse
        return error.TestExpectedRevBump;
    const snapshot = std.mem.indexOf(u8, handler, "history.snapshotLayouts") orelse
        return error.TestExpectedHistorySnapshot;
    const write = std.mem.indexOf(u8, handler, "writeLayoutsSubRev(") orelse
        return error.TestExpectedLayoutWrite;

    // Read → compare → snapshot → write, all after the lock is taken.
    try std.testing.expect(lock < rev_read);
    try std.testing.expect(rev_read < bump);
    try std.testing.expect(bump < snapshot);
    try std.testing.expect(snapshot < write);
    // One writer only: a second one would be a second, unguarded critical section.
    try std.testing.expect(std.mem.indexOf(u8, handler[write + 1 ..], "writeLayoutsSubRev(") == null);
    // The lock is released by scope exit, so every early return under it (the
    // 409, the allocator errors on the merge) still unlocks.
    try std.testing.expect(std.mem.indexOf(u8, handler[lock..], "defer guard.unlock();") != null);

    // The block resolve — the expensive part — happens BEFORE the hold, along
    // with the cheap pre-check that fails an already-doomed save fast.
    const layers = std.mem.indexOf(u8, handler, "layout_save_layers.savedLayoutLayers(") orelse
        return error.TestExpectedLayerResolve;
    const precheck = std.mem.indexOf(u8, handler, "const seen_rev = readLayoutRev(") orelse
        return error.TestExpectedRevPrecheck;
    try std.testing.expect(layers < lock);
    try std.testing.expect(precheck < layers);
}

// ── The lock at runtime ──────────────────────────────────────────────────────
//
// Every assertion above pins STRUCTURE: that the source text takes the lock
// before it reads. Structure cannot show the lock actually ORDERS anything, so
// what follows drives the genuine read-modify-write from real OS threads against
// a real file and asserts the invariant the lock exists for.
//
// Real threads work here, and the reason is worth recording because the `std.Io`
// rewrite makes it non-obvious. `infra_fs.Mutex` wraps `std.Io.Mutex`, whose
// `lockUncancelable` is a compare-and-swap on an atomic state word that
// futex-waits when it loses the race; under test `infra_fs.currentIo()` returns
// `std.testing.io`, an `Io.Threaded` whose `futexWaitUncancelable` discards its
// userdata entirely and calls the plain OS futex. No thread-pool membership,
// fiber, or event loop is involved, so a bare `std.Thread` blocks and wakes
// correctly — the same basis on which `serve/thermal_cache.zig` already hammers
// an `infra_fs.Mutex` from four spawned threads.
//
// Scope: this proves the store-level critical section serializes concurrent
// writers. It does NOT drive `saveNamedLayoutApi` itself — that handler still
// wants a live server harness, which is why the structure assertions above stay.

/// One writer in the lost-update stress test.
const SidecarStressWriter = struct {
    project_dir: []const u8,
    design: []const u8,
    id: usize,
    rounds: usize,
    go: *std.atomic.Value(bool),
    accepted: *std.atomic.Value(u64),
    /// Backing allocator for this writer's private arena, injected by the test
    /// rather than reached for here: the writers must share no allocator state,
    /// or a failure could come from allocator contention instead of the lock.
    gpa: std.mem.Allocator,

    fn run(self: SidecarStressWriter) void {
        // Per-thread arena: the writers then share no allocator state at all, so
        // nothing here can pass or fail for a reason other than the sidecar lock.
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        // Released together, so every writer's first round reaches the revision
        // read at the same instant — precisely the overlap the lock must absorb.
        while (!self.go.load(.acquire)) std.atomic.spinLoopHint();
        for (0..self.rounds) |round| {
            _ = arena_state.reset(.retain_capacity);
            if (self.writeRound(arena_state.allocator(), round)) _ = self.accepted.fetchAdd(1, .acq_rel);
        }
    }

    /// The real save shape: lock, read the revision, read the list, append this
    /// writer's own row, write back at `rev + 1`, confirm, unlock.
    fn writeRound(self: SidecarStressWriter, alloc: std.mem.Allocator, round: usize) bool {
        const row = std.fmt.allocPrint(alloc, "w{d}-{d}", .{ self.id, round }) catch return false;

        const guard = lockSidecar(self.design, null);
        defer guard.unlock();

        const disk_rev = readLayoutRev(alloc, self.project_dir, self.design, null);
        var out: std.ArrayList(SavedLayout) = .empty;
        out.appendSlice(alloc, readLayoutsSub(alloc, self.project_dir, self.design, null)) catch return false;
        out.append(alloc, .{
            .name = row,
            .kind = kind_manual,
            .ts = @intCast(round),
            .score = null,
            .parts = &.{},
        }) catch return false;

        const next = disk_rev + 1;
        writeLayoutsSubRev(alloc, self.project_dir, self.design, null, out.items, next);
        // `writeLayoutsSubRev` is best-effort and returns void, so the write is
        // confirmed from disk while the lock is still held. Counting only
        // confirmed writes is what keeps "the final revision equals the number of
        // accepted writes" an invariant rather than a tautology: a write that
        // never landed cannot quietly excuse a missing revision.
        return readLayoutRev(alloc, self.project_dir, self.design, null) == next;
    }
};

// Four writers released together, thirty rounds each: 120 read-modify-writes
// whose read-to-write window spans two whole-file reads, a JSON parse and an
// atomic rewrite. Against the pre-lock code the FIRST round alone loses three of
// the four writes — all four read revision 0, all four write revision 1, three
// rows vanish — and the remaining 119 rounds each re-run that race with the
// writers already in lockstep. So both assertions below fail immediately without
// the lock, and with it all 120 writes have to survive.
// spec: Web Server - Concurrent writers of one design's layout sidecar are serialized so that every accepted write advances the revision by exactly one and no write's saved row is overwritten by a peer that read the same revision
test "concurrent sidecar writers lose no accepted write" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "src", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/lockrace.sexp", .data = "(design-block \"D\")" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/lockrace.layouts.json", .data = "{\"layouts\":[]}" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    const writers = 4;
    const rounds = 30;
    var go: std.atomic.Value(bool) = .init(false);
    var accepted: std.atomic.Value(u64) = .init(0);

    var threads: [writers]std.Thread = undefined;
    // The page allocator is named HERE, in the test body, so each writer gets an
    // independent arena without this module reaching for a global allocator of
    // its own.
    const spawned = spawnStressWriters(&threads, root, rounds, &go, &accepted, std.heap.page_allocator);
    // Set unconditionally, so a writer that spawned before a failing peer is
    // released rather than spinning on a barrier that will never fill.
    go.store(true, .release);
    joinStressWriters(threads[0..spawned]);
    try testing.expectEqual(@as(usize, writers), spawned);

    const total = writers * rounds;
    try testing.expectEqual(@as(u64, total), accepted.load(.acquire));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Every accepted write advanced the revision by exactly one, so no writer
    // stamped a revision a peer had already claimed.
    try testing.expectEqual(@as(i64, total), readLayoutRev(alloc, root, "lockrace", null));

    // ...and no accepted write's row was dropped. A lost update loses a ROW, and
    // a revision that merely counts correctly could still be hiding one, so the
    // rows themselves are checked against the full expected set.
    const final = readLayoutsSub(alloc, root, "lockrace", null);
    try testing.expectEqual(@as(usize, total), final.len);
    try expectEveryStressRowPresent(alloc, final, writers, rounds);
}

/// Start one stress writer per slot, returning how many actually started. A
/// spawn failure stops the loop rather than propagating, so the caller can
/// release the barrier and join the writers that DID start — a test that leaves
/// threads spinning on a barrier nobody sets hangs the shard instead of failing.
/// Hoisted out of the test body: the spawn and join loops are two of the four
/// loops this one assertion needs, and `test-no-conditional` allows one.
fn spawnStressWriters(
    threads: []std.Thread,
    project_dir: []const u8,
    rounds: usize,
    go: *std.atomic.Value(bool),
    accepted: *std.atomic.Value(u64),
    gpa: std.mem.Allocator,
) usize {
    var spawned: usize = 0;
    while (spawned < threads.len) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, SidecarStressWriter.run, .{SidecarStressWriter{
            .project_dir = project_dir,
            .design = "lockrace",
            .id = spawned,
            .rounds = rounds,
            .go = go,
            .accepted = accepted,
            .gpa = gpa,
        }}) catch break;
    }
    return spawned;
}

/// Join every writer that started.
fn joinStressWriters(threads: []std.Thread) void {
    for (threads) |t| t.join();
}

/// Assert every writer's every round left its own row behind. A lost update
/// loses a ROW, and a revision that merely counts correctly could still be
/// hiding one, so the full expected set is checked rather than the count alone.
fn expectEveryStressRowPresent(
    alloc: std.mem.Allocator,
    final: []const SavedLayout,
    writers: usize,
    rounds: usize,
) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (final) |layout| try seen.put(alloc, layout.name, {});
    var buf: [32]u8 = undefined;
    var w: usize = 0;
    while (w < writers) : (w += 1) {
        var n: usize = 0;
        while (n < rounds) : (n += 1) {
            const want = try std.fmt.bufPrint(&buf, "w{d}-{d}", .{ w, n });
            if (!seen.contains(want)) return error.TestLostLayoutRow;
        }
    }
}
