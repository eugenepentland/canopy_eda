//! Sidecar write seam for `import-kicad-layout`: converts the pure importer's
//! output (`kicad_pcb/import_layout.Imported`) into the layout sidecar's
//! `SavedLayout` shape and persists it as the design's starred layout (its
//! other saved layouts are kept) with user-save rev semantics. Kept beside (not inside) `pcb_layout_page.zig`
//! so the page module's size stays ratcheted; the JSON shapes and rev/cache
//! rules all come from that module's pub seams.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const clock = @import("../infra/clock.zig");
const paths = @import("../paths.zig");
const outline_mod = @import("../placement/outline.zig");
const import_layout = @import("../kicad_pcb/import_layout.zig");
const page = @import("pcb_layout_page.zig");
const sidecar_store = @import("../layout_sidecar_store.zig");

/// The sidecar track element type, derived through the pub `SavedRoutes`
/// field so the 8-field struct itself can stay private to the page module
/// (its shape is ratcheted there).
const SavedTrack = @typeInfo(@FieldType(page.SavedRoutes, "tracks")).pointer.child;
const SavedZone = @typeInfo(@FieldType(page.SavedRoutes, "zones")).pointer.child;

/// Name given to the starred layout `import-kicad-layout` writes.
const imported_layout_name = "layout";

/// Land the layout imported from a routed KiCad board (the
/// `import-kicad-layout` CLI seam) as `name`'s starred board: the imported
/// poses, copper, and outline become a manual `"layout"` entry with the
/// default (★) flag set, the optimizer cache slot rides along unchanged, and
/// the sidecar `rev` is bumped with user-save semantics.
///
/// The design's OTHER saved layouts survive — the import claims the star, not
/// the whole sidecar. A board under autorouter work carries several named
/// candidates; taking KiCad's board as the system of record is a statement
/// about which one is blessed, not a licence to delete the alternatives.
/// Returns false when the sidecar could not be built or written.
pub fn writeImportedStarredLayout(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    imported: import_layout.Imported,
) bool {
    const layout = importedSavedLayout(alloc, imported) catch return false;
    // Read-modify-write: the rev, the cache slot and the existing rows are all
    // read, merged, and republished as `rev + 1`. The conversion above is pure,
    // so the hold starts here and covers only the transaction — a concurrent
    // save landing mid-merge would otherwise be overwritten whole. None of the
    // readers below takes this lock, so the hold cannot re-enter itself.
    const guard = sidecar_store.lockSidecar(name, null);
    defer guard.unlock();
    const rev = page.readLayoutRev(alloc, project_dir, name, null);
    const cache = page.readCacheSlot(alloc, project_dir, name);
    const merged = mergeStarred(alloc, page.readLayouts(alloc, project_dir, name), layout) catch return false;
    const path = paths.designSiblingPath(alloc, project_dir, name, page.layouts_ext) catch return false;
    defer alloc.free(path);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    page.writeLayoutsFileJsonRev(w, merged, cache, rev + 1) catch return false;
    writeFileAtomic(path, aw.written()) catch return false;
    return true;
}

/// `existing` with `entry` as its sole starred layout: overwriting the row of
/// the same name in place (a re-import updates the board it wrote last time)
/// or prepending it, and clearing every other row's ★.
fn mergeStarred(
    alloc: std.mem.Allocator,
    existing: []const page.SavedLayout,
    entry: page.SavedLayout,
) std.mem.Allocator.Error![]const page.SavedLayout {
    var out: std.ArrayList(page.SavedLayout) = .empty;
    var replaced = false;
    for (existing) |L| {
        if (!replaced and std.mem.eql(u8, L.name, entry.name)) {
            try out.append(alloc, entry);
            replaced = true;
        } else {
            var e = L;
            e.default = false;
            try out.append(alloc, e);
        }
    }
    if (!replaced) try out.insert(alloc, 0, entry);
    return out.toOwnedSlice(alloc);
}

/// Convert an `import_layout.Imported` into the sidecar's `SavedLayout`
/// shape: poses → `PartPose` (unlocked), copper → `SavedRoutes` (net names
/// carried), outline polygon → `SavedOutline` (bbox derived from the pts).
fn importedSavedLayout(
    alloc: std.mem.Allocator,
    imported: import_layout.Imported,
) std.mem.Allocator.Error!page.SavedLayout {
    const parts = try alloc.alloc(page.PartPose, imported.poses.len);
    for (imported.poses, parts) |pose, *part| part.* = .{
        .ref = pose.ref,
        .x = pose.x,
        .y = pose.y,
        .rot = pose.rot,
        .origin = pose.origin,
        .side = pose.side,
    };
    const tracks = try alloc.alloc(SavedTrack, imported.tracks.len);
    for (imported.tracks, tracks) |t, *track| track.* = .{
        .x1 = t.x1,
        .y1 = t.y1,
        .x2 = t.x2,
        .y2 = t.y2,
        .l = t.layer,
        .w = t.width,
        .net = t.net,
        .source = page.route_source_imported,
    };
    const vias = try alloc.alloc(page.SavedVia, imported.vias.len);
    for (imported.vias, vias) |v, *via| via.* = .{
        .x = v.x,
        .y = v.y,
        .d = v.dia,
        .drill = v.drill,
        .net = v.net,
        .source = page.route_source_imported,
    };
    const zones = try alloc.alloc(SavedZone, imported.zones.len);
    for (imported.zones, zones) |zone, *saved| saved.* = .{
        .net = zone.net,
        .layer = zone.layer,
        .poly = zone.poly,
        .flags = .{ .filled = zone.filled, .keepout = zone.keepout },
        .priority = zone.priority,
    };
    const routes: ?page.SavedRoutes = if (tracks.len + vias.len + zones.len > 0)
        .{ .tracks = tracks, .vias = vias, .zones = zones }
    else
        null;
    return .{
        .name = imported_layout_name,
        .kind = page.kind_manual,
        .ts = clock.timestamp(),
        .score = null,
        .parts = parts,
        .default = true,
        .routes = routes,
        .outline = importedOutline(imported.outline),
    };
}

/// The imported outline polygon as a `SavedOutline` (null when empty or
/// degenerate — the sidecar then simply carries no outline).
fn importedOutline(outline: import_layout.Outline) ?page.SavedOutline {
    if (outline.pts.len < 3) return null;
    const bb = outline_mod.bboxRect(outline.pts);
    if (!(bb.w > 0) or !(bb.h > 0)) return null;
    return .{ .x = bb.minx, .y = bb.miny, .w = bb.w, .h = bb.h, .pts = outline.pts };
}

/// Atomic tmp→rename sidecar write — twin of `pcb_layout_page.writeFileAll`
/// (kept private there): a reader always sees the old or new file whole.
fn writeFileAtomic(path: []const u8, data: []const u8) !void {
    var write_buf: [4096]u8 = undefined;
    var atomic = try infra_fs.cwd().atomicFile(path, .{ .write_buffer = &write_buf });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(data);
    try atomic.finish();
}

// ── Tests ───────────────────────────────────────────────────────────────────

const optimizer = @import("../placement/optimizer.zig");

// spec: kicad_pcb/import-layout - the imported layout becomes the sole starred manual layout and bumps the rev
test "writeImportedStarredLayout round-trips one starred layout and bumps rev" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src");
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const imported = import_layout.Imported{
        .poses = &.{.{ .ref = "U1", .origin = "u1", .x = 10, .y = 20, .rot = 270, .side = .bottom }},
        .tracks = &.{.{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 1, .width = 0.2, .net = "VDD" }},
        .vias = &.{.{ .x = 5, .y = 0, .dia = 0.4, .drill = 0.2, .net = "VDD" }},
        .zones = &.{
            .{ .net = "GND", .layer = "In1.Cu", .poly = &.{ .{ 1, 1 }, .{ 9, 1 }, .{ 9, 8 } } },
            .{ .layer = "F.Cu", .poly = &.{ .{ 2, 2 }, .{ 3, 2 }, .{ 3, 3 } }, .keepout = true },
        },
        .outline = .{ .pts = &.{ .{ 0, 0 }, .{ 30, 0 }, .{ 30, 20 }, .{ 0, 20 } } },
    };
    try std.testing.expect(writeImportedStarredLayout(arena, project_dir, "demo", imported));
    try std.testing.expect(writeImportedStarredLayout(arena, project_dir, "demo", imported));
    const layouts = page.readLayouts(arena, project_dir, "demo");
    try std.testing.expectEqual(@as(usize, 1), layouts.len);
    try std.testing.expect(layouts[0].default);
    try std.testing.expectEqualStrings(page.kind_manual, layouts[0].kind);
    try std.testing.expectEqualStrings("U1", layouts[0].parts[0].ref);
    try std.testing.expectEqualStrings("u1", layouts[0].parts[0].origin);
    try std.testing.expectEqual(optimizer.Side.bottom, layouts[0].parts[0].side);
    try std.testing.expectEqual(@as(usize, 1), layouts[0].routes.?.tracks.len);
    try std.testing.expectEqual(@as(u8, 1), layouts[0].routes.?.tracks[0].l);
    try std.testing.expectEqualStrings("VDD", layouts[0].routes.?.vias[0].net);
    try std.testing.expectEqual(@as(usize, 2), layouts[0].routes.?.zones.len);
    try std.testing.expectEqualStrings("In1.Cu", layouts[0].routes.?.zones[0].layer);
    try std.testing.expect(layouts[0].routes.?.zones[1].flags.keepout);
    try std.testing.expectEqual(@as(usize, 4), layouts[0].outline.?.pts.?.len);
    // Two user-save writes onto a rev-less sidecar leave rev at 2.
    try std.testing.expectEqual(@as(i64, 2), page.readLayoutRev(arena, project_dir, "demo", null));
}

// spec: kicad_pcb/import-layout - the import keeps the design's other saved layouts, taking only the star from them
test "writeImportedStarredLayout keeps the design's other layouts and takes only the star" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src");
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    // A board mid-autoroute: two hand-saved routing candidates, one starred.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.layouts.json", .data =
        \\{"default":"route-a","layouts":[
        \\ {"name":"route-a","kind":"manual","ts":2,"parts":[{"ref":"U1","x":1,"y":1,"rot":0}]},
        \\ {"name":"route-b","kind":"manual","ts":1,"parts":[{"ref":"U1","x":2,"y":2,"rot":0}]}]}
    });

    const imported = import_layout.Imported{
        .poses = &.{.{ .ref = "U1", .origin = "u1", .x = 10, .y = 20, .rot = 0 }},
        .outline = .{ .pts = &.{ .{ 0, 0 }, .{ 30, 0 }, .{ 30, 20 }, .{ 0, 20 } } },
    };
    try std.testing.expect(writeImportedStarredLayout(arena, project_dir, "demo", imported));

    // The imported board joins the list as the ★; neither candidate is deleted,
    // and the star has moved off route-a onto it. `mergeStarred` prepends a
    // name it didn't find, so the order is imported-first then the survivors.
    const layouts = page.readLayouts(arena, project_dir, "demo");
    try std.testing.expectEqual(@as(usize, 3), layouts.len);
    try std.testing.expectEqualStrings(imported_layout_name, layouts[0].name);
    try std.testing.expect(layouts[0].default);
    try std.testing.expectEqualStrings("route-a", layouts[1].name);
    try std.testing.expect(!layouts[1].default);
    try std.testing.expectEqualStrings("route-b", layouts[2].name);
    try std.testing.expect(!layouts[2].default);
}
