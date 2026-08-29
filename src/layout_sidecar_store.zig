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

/// Remove same-hole, same-net vias while preserving first-row provenance.
pub fn dedupedVias(alloc: std.mem.Allocator, vias: []const SavedVia) []const SavedVia {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var out: std.ArrayList(SavedVia) = .empty;
    for (vias) |via| {
        const key = std.fmt.allocPrint(alloc, "{d},{d},{d},{d},{s}", .{ via.x, via.y, via.d, via.drill, via.net }) catch return vias;
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
    if (deduped.len != raw.len) writeLayoutsSub(alloc, project_dir, name, sub, deduped);
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
    const existing = readLayouts(alloc, project_dir, name);
    const score = LayoutScore{
        .hpwl = placement.score.hpwl_mm,
        .loop = placement.score.loop_mm,
        .caps = placement.score.loop_caps,
        .objective = placement.breakdown.objective,
    };
    const parts = posesFromPlacement(alloc, placement) orelse return;
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
