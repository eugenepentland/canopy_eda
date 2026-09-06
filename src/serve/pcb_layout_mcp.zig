//! The agent-facing PCB layout tools: `set_part_poses`, `set_board_outline`,
//! `route_pcb`, `save_pcb_layout`, `clear_routes`, `add_tracks`,
//! `set_copper_zones`, `clean_route_topology`, `normalize_junctions`,
//! `restore_layout_snapshot`, `repair_land_transit` and `stitch_ground_pads`.
//!
//! Split out of `pcb_layout_page.zig` because these are a different surface
//! from the page: `mcp_tools.zig` dispatches `tools/call` (and `netlisp tool`)
//! straight into them with an arg object and a response buffer, so they never
//! see an `httpz` request, never render HTML, and answer with `{"ok":…}` JSON
//! instead of a status code. What they share with the viewer is the sidecar
//! and the routing helpers, which they reach through `pcb_layout_page.zig`.
//!
//! Fail-closed is the contract: every tool validates its whole request before
//! it writes, so an unknown net, an unresolvable ref or a rejected DRC gate
//! leaves `<design>.layouts.json` exactly as it was.

const std = @import("std");
const board_layers = @import("../board_layers.zig");
const clock = @import("../infra/clock.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const env_mod = @import("../eval/env.zig");
const optimizer = @import("../placement/optimizer.zig");
const router = @import("../placement/router.zig");
const route_cleanup = @import("../placement/route_cleanup.zig");
const land_transit = @import("../placement/land_transit.zig");
const rf_port_report = @import("../placement/rf_port_report.zig");
const drc = @import("../placement/drc.zig");
const drc_rules = @import("drc_rules.zig");
const route_cleanup_gate = @import("../route_cleanup_gate.zig");
const outline_mod = @import("../placement/outline.zig");
const perimeter_fence = @import("../placement/perimeter_fence.zig");
const pour = @import("../placement/pour.zig");
const fab_readiness = @import("../fab_readiness.zig");
const route_policy = @import("../placement/route_policy.zig");
const reference_guides = @import("../kicad_pcb/reference_guides.zig");
const pcb_snapshot = @import("../kicad_pcb/snapshot.zig");
const modules_mod = @import("modules.zig");
const serve_root = @import("../serve.zig");
const route_plan = @import("route_plan.zig");
const route_copper_state = @import("../route_copper_state.zig");
const route_result_stats = @import("route_result_stats.zig");
const history = @import("history.zig");
const numeric = @import("../numeric.zig");
const Server = serve_root.Server;
const sidecar_json = @import("layout_sidecar_json.zig");
const sidecar_store = @import("../layout_sidecar_store.zig");
const sidecar_types = @import("../layout_sidecar_types.zig");
const layout_layers = @import("layout_layers.zig");
const page = @import("pcb_layout_page.zig");
const infra_fs = @import("../infra/fs.zig");
const httpz = @import("httpz");
const saved_route_copper = @import("../saved_route_copper.zig");
const saved_zone = @import("saved_zone.zig");
const rf_path_solver = @import("../placement/rf_path_solver.zig");
const export_kicad = @import("../export_kicad.zig");
const geometry = @import("../placement/geometry.zig");

const jsonNum = sidecar_json.jsonNum;
const jsonSide = sidecar_json.jsonSide;
const jsonFlag = sidecar_json.jsonFlag;
const parseSavedOutline = sidecar_json.parseSavedOutline;
const parseOutlinePts = sidecar_json.parseOutlinePts;
const writeJsonStr = sidecar_json.writeJsonStr;

const HandlerError = page.HandlerError;
const PartPose = sidecar_types.PartPose;
const SavedPartEdgeDimension = sidecar_types.SavedPartEdgeDimension;
const SavedLayout = sidecar_types.SavedLayout;
const SavedTrack = sidecar_types.SavedTrack;
const SavedVia = sidecar_types.SavedVia;
const SavedZone = sidecar_types.SavedZone;
const SavedRoutes = sidecar_types.SavedRoutes;
const SavedRfPath = sidecar_types.SavedRfPath;
const SavedOutline = sidecar_types.SavedOutline;
const route_source_agent = sidecar_types.route_source_agent;
const layouts_ext = sidecar_store.layouts_ext;
const kind_manual = sidecar_store.kind_manual;
const blessedLayout = @import("../fab_package.zig").blessedLayout;

const SolvedRequest = page.SolvedRequest;
const solveForRequest = page.solveForRequest;
const resolveBlock = page.resolveBlock;
const routeWithSubcircuitSeeds = page.routeWithSubcircuitSeeds;
const writeRouteSeedStats = page.writeRouteSeedStats;
const routesWithPerimeter = page.routesWithPerimeter;
const starFirstEver = page.starFirstEver;
const parseJsonObject = page.parseJsonObject;
const outline_open = page.outline_open;
const pin_key_fmt = page.pin_key_fmt;
const readLayouts = sidecar_store.readLayouts;
const readSidecarDoc = sidecar_store.readSidecarDoc;
const readDesignDoc = sidecar_store.readDesignDoc;
const parseLayouts = sidecar_store.parseLayouts;
const lockSidecar = sidecar_store.lockSidecar;
const layoutsSidecar = sidecar_store.layoutsSidecar;
const sidecar_max_bytes = sidecar_store.sidecar_max_bytes;
const refPrefix = @import("pose_identity.zig").refPrefix;
const writeSavedOutlineJson = sidecar_json.writeSavedOutlineJson;
const posesFromPlacement = page.posesFromPlacement;
const mcpProtectedWrite = page.mcpProtectedWrite;
const mcpRestoreLayoutSnapshot = page.mcpRestoreLayoutSnapshot;
const netIndexByName = page.netIndexByName;
const restoreRoutes = page.restoreRoutes;
const CacheSlot = sidecar_store.CacheSlot;
const readLayoutRev = sidecar_store.readLayoutRev;
const readAutoPoses = sidecar_store.readAutoPoses;
const userZonesFrom = saved_zone.userZones;
const nameParam = page.nameParam;
const writeFabSelectionFixture = @import("pcb_layout_fab.zig").FabSelectionTestSupport.write;
const readCacheSlot = sidecar_store.readCacheSlot;
const route_source_human = sidecar_types.route_source_human;
const route_source_autorouter = sidecar_types.route_source_autorouter;
const writeFreshRfPathsJson = page.writeFreshRfPathsJson;

// ── CLI layout-mutation tools ──────────────────────────────────────────
//
// The read-only PCB tools (get_pcb_layout_image / describe_pcb_layout /
// compare_layout_to_starred) let an agent SEE a placement; these six let it
// EDIT one — set poses, draw a board outline, autoroute, save/star, clear
// copper, and run the pre-fab gate — so a design can go schematic → gated
// Gerbers with no browser. They persist into the same `<design>.layouts.json`
// sidecar the viewer writes, through the same save/route/fab helpers above, so
// a layout the agent builds loads unchanged in `/pcb-layout`.
//
// Each takes the CLI arg object + the response buffer and returns `ok`.
// Mutations write `<design>.layouts.json` and report the design's current
// `live_version` (the sidecar isn't the design source, so the counter is
// informational — the viewer picks up layout changes on its next load).

/// Shared error/response fragments for the layout tools (extracted so the
/// repeated-literal check stays quiet and the wording stays consistent).
pub const mcp_err_missing_name = "missing argument \"name\"";
const mcp_err_no_design = "no design or module by that name";
/// `mcpFailFmt` template for a design/module that fails to evaluate + solve.
const mcp_err_resolve_layout = "could not resolve layout: {s}";
/// `{"ok":true,"live_version":N,"layout":` — the opening the tools that report
/// only a layout name share (set_board_outline / route_pcb / clear_routes).
const mcp_ok_layout_fmt = "{{\"ok\":true,\"live_version\":{d},\"layout\":";

/// A single requested pose from `set_part_poses` (`x_mm`/`y_mm` in mm; `rot`/
/// `side`/`locked` optional — absent keeps the part's current value).
pub const McpReqPose = struct {
    ref: []const u8,
    has_xy: bool,
    x: f64,
    y: f64,
    has_rot: bool,
    rot: f64,
    has_side: bool,
    side: optimizer.Side,
    has_locked: bool,
    locked: bool,
};

/// `args.key` as a string (null when absent / not a string).
pub fn mcpArgStr(args_val: ?std.json.Value, key: []const u8) ?[]const u8 {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// `args.key` as a bool (absent / non-bool ⇒ false).
pub fn mcpArgBool(args_val: ?std.json.Value, key: []const u8) bool {
    return mcpArgBoolOpt(args_val, key) orelse false;
}

/// `args.key` as an OPTIONAL bool — null when absent (or non-bool), so a caller
/// can distinguish "not supplied" (fall back to a computed default) from an
/// explicit `false`. `route_pcb`'s `selected_only` uses this to default to
/// incremental whenever a scope was named.
fn mcpArgBoolOpt(args_val: ?std.json.Value, key: []const u8) ?bool {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return if (v == .bool) v.bool else null;
}

/// `args.key` as an optional JSON number. Unlike `jsonNum`, absence stays null
/// so coordinate-scoped mutations cannot silently target the origin.
fn mcpArgNumOpt(args_val: ?std.json.Value, key: []const u8) ?f64 {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return switch (v) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        else => null,
    };
}

/// `args.key` as a token list — a JSON string array or a comma-separated
/// string (trimmed, empties dropped). Absent ⇒ empty slice. The one spelling
/// every MCP layout/route tool parses its name-list arguments with.
pub fn mcpArgStrList(alloc: std.mem.Allocator, args_val: ?std.json.Value, key: []const u8) []const []const u8 {
    const av = args_val orelse return &.{};
    if (av != .object) return &.{};
    const v = av.object.get(key) orelse return &.{};
    var list: std.ArrayList([]const u8) = .empty;
    if (v == .array) {
        for (v.array.items) |it| {
            if (it == .string and it.string.len > 0) list.append(alloc, it.string) catch break;
        }
    } else if (v == .string) {
        var it = std.mem.tokenizeScalar(u8, v.string, ',');
        while (it.next()) |tok| {
            const t = std.mem.trim(u8, tok, " \t");
            if (t.len > 0) list.append(alloc, t) catch break;
        }
    }
    return list.toOwnedSlice(alloc) catch &.{};
}

/// Write an `{"ok":false,"error":<msg>}` envelope into `out` and return false
/// (the CLI layer flags the result `isError`). The single error spelling for
/// every layout tool.
pub fn mcpFail(out: *std.ArrayList(u8), alloc: std.mem.Allocator, msg: []const u8) (std.mem.Allocator.Error || std.Io.Writer.Error)!bool {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.writeAll("{\"ok\":false,\"error\":");
    try writeJsonStr(w, msg);
    try w.writeAll("}");
    try out.appendSlice(alloc, aw.written());
    return false;
}

/// `mcpFail` with a formatted message (built on `alloc`, then escaped).
fn mcpFailFmt(out: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !bool {
    const msg = std.fmt.allocPrint(alloc, fmt, args) catch "error";
    return mcpFail(out, alloc, msg);
}

/// Is `layout` the ★ entry of `name`'s sidecar? Read back AFTER a write so a
/// tool result reports the star as it actually landed on disk, not as asked.
fn mcpIsStarred(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, layout: []const u8) bool {
    for (readLayouts(alloc, project_dir, name)) |L| {
        if (std.mem.eql(u8, L.name, layout)) return L.default;
    }
    return false;
}

// twin-drift-ok: the shared body is the evaluator + ResolvedBlock preamble every
// design-resolving entry point opens with. This one only probes existence;
// `pcb_layout_page.fabViewFor` goes on to build a whole fab view from the block.
/// Does `name` resolve to a design or module at all? The existence guard the
/// layout-mutation tools run before touching a sidecar, so a typo'd name fails
/// with "no such design" instead of quietly minting one.
fn mcpBlockExists(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) bool {
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    return resolveBlock(alloc, project_dir, name, &eval, &module_res) != null;
}

/// The layout entry the agent's edits land on: the `layout` arg by name, else
/// the blessed snapshot (★ default → newest manual → any). Null when nothing
/// matches (a block with no saved layouts, or an unknown `layout` name — the
/// two are distinguished by the caller, which errors on a name it can't find).
pub fn mcpReadWorking(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    layout_arg: ?[]const u8,
) ?SavedLayout {
    const layouts = readLayouts(alloc, project_dir, name);
    if (layout_arg) |la| {
        for (layouts) |L| {
            if (std.mem.eql(u8, L.name, la)) return L;
        }
        return null;
    }
    if (blessedLayout(layouts)) |L| return L.*;
    return null;
}

/// The name the working layout is stored under (see `mcpReadWorking`): the
/// `layout` arg, else the blessed snapshot's name, else "layout" — the name a
/// block's first-ever layout is minted under, matching what the viewer's own
/// first save has always produced for a design.
pub fn mcpWorkingName(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    layout_arg: ?[]const u8,
) []const u8 {
    if (layout_arg) |la| return la;
    if (blessedLayout(readLayouts(alloc, project_dir, name))) |L| return L.name;
    return "layout";
}

fn mcpWorkingDimensions(working: ?SavedLayout) []const SavedPartEdgeDimension {
    return if (working) |layout| layout.dimensions else &.{};
}

/// Persist `entry` as the working layout: upsert by name (starring it clears
/// any other default), and star a block's first-ever layout so the page,
/// KiCad sync and fab outputs all reopen on it. Mirrors `saveNamedLayoutApi`.
pub fn mcpPersistWorking(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    entry_in: SavedLayout,
    star: bool,
) sidecar_store.StoreError!void {
    return persistWorking(false, alloc, project_dir, name, entry_in, star);
}

const routeArcOwnsTrack = @import("../saved_route_copper.zig").arcOwnsTrack;
const mcpNetNameAt = @import("../saved_route_copper.zig").netNameAt;
/// Convert physical route results into persistent, net-named copper records.
pub const mcpSavedRoutesFrom = @import("../saved_route_copper.zig").fromResult;

fn savedTrackCount(saved: ?SavedRoutes) usize {
    return if (saved) |s| s.tracks.len else 0;
}

fn savedViaCount(saved: ?SavedRoutes) usize {
    return if (saved) |s| s.vias.len else 0;
}

/// The set of net NAMES touched by any part in `moved` — the copper to
/// invalidate when those parts move (mirrors the viewer's `clearRouteFor`:
/// a moved part's nets' routed copper is stale, so it's dropped).
fn mcpNetsTouchingRefs(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    moved: *const std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!std.StringHashMapUnmanaged(void) {
    var set = std.StringHashMapUnmanaged(void).empty;
    for (placement.nets) |net| {
        for (net.pins) |pin| {
            if (moved.contains(pin.ref_des)) {
                try set.put(alloc, net.name, {});
                break;
            }
        }
    }
    return set;
}

/// Drop every track/via whose net is in `drop` from `sr`. Custom zones are
/// board geometry, not route-wave output, so they always survive a scoped clear
/// or reroute. Returns the surviving copper (null when nothing survives) and
/// how many track/via segments were dropped.
///
/// A via also goes when its FENCE tag (`f`, the RF net it flanks) is in the drop
/// set: an RF via fence is geometry of its trace, not of the ground net it
/// stitches, so moving an RF part must take its fence with its copper. Keyed on
/// `net` alone the fence would survive every reroute of the trace it hugs and
/// slowly become a row of vias beside nothing.
pub const McpDroppedRoutes = struct { routes: ?SavedRoutes, dropped: usize };
pub fn mcpDropRoutesForNets(
    alloc: std.mem.Allocator,
    sr: ?SavedRoutes,
    drop: *const std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!McpDroppedRoutes {
    const s = sr orelse return .{ .routes = null, .dropped = 0 };
    var tracks: std.ArrayList(SavedTrack) = .empty;
    var vias: std.ArrayList(SavedVia) = .empty;
    var rf_paths: std.ArrayList(SavedRfPath) = .empty;
    var dropped: usize = 0;
    for (s.tracks) |t| {
        if (t.net.len > 0 and drop.contains(t.net)) dropped += 1 else try tracks.append(alloc, t);
    }
    for (s.vias) |v| {
        const own = v.net.len > 0 and drop.contains(v.net);
        const fenced = v.f.len > 0 and drop.contains(v.f);
        if (own or fenced) dropped += 1 else try vias.append(alloc, v);
    }
    for (s.rf_paths) |path| if (!drop.contains(path.net)) try rf_paths.append(alloc, path);
    if (tracks.items.len == 0 and vias.items.len == 0 and s.zones.len == 0 and rf_paths.items.len == 0)
        return .{ .routes = null, .dropped = dropped };
    return .{
        .routes = .{
            .tracks = try tracks.toOwnedSlice(alloc),
            .vias = try vias.toOwnedSlice(alloc),
            .zones = s.zones,
            .rf_paths = try rf_paths.toOwnedSlice(alloc),
        },
        .dropped = dropped,
    };
}

/// Drop only vias of the selected nets whose centres lie within `radius` of
/// (`x`,`y`). This is the surgical counterpart to net-wide clearing: dense
/// boards often need one obsolete stitch removed without erasing hundreds of
/// unrelated GND segments. Tracks, zones, RF paths, and non-matching vias are
/// retained byte-for-byte.
pub fn mcpDropViasNear(
    alloc: std.mem.Allocator,
    sr: ?SavedRoutes,
    drop: *const std.StringHashMapUnmanaged(void),
    x: f64,
    y: f64,
    radius: f64,
) std.mem.Allocator.Error!McpDroppedRoutes {
    const s = sr orelse return .{ .routes = null, .dropped = 0 };
    var vias: std.ArrayList(SavedVia) = .empty;
    var dropped: usize = 0;
    const radius_sq = radius * radius;
    for (s.vias) |v| {
        const dx = v.x - x;
        const dy = v.y - y;
        const selected = v.net.len > 0 and drop.contains(v.net);
        if (selected and dx * dx + dy * dy <= radius_sq) {
            dropped += 1;
        } else {
            try vias.append(alloc, v);
        }
    }
    if (s.tracks.len == 0 and vias.items.len == 0 and s.zones.len == 0 and s.rf_paths.len == 0)
        return .{ .routes = null, .dropped = dropped };
    return .{
        .routes = .{
            .tracks = s.tracks,
            .vias = try vias.toOwnedSlice(alloc),
            .zones = s.zones,
            .rf_paths = s.rf_paths,
        },
        .dropped = dropped,
    };
}

/// Keep only the tracks/vias whose net is in `keep` (the fresh copper for the
/// `route_pcb` `nets` scope). Zones deliberately stay with the retained base,
/// avoiding duplicate board geometry when the two route sets merge. Null when
/// no track/via matches.
pub fn mcpKeepRoutesForNets(
    alloc: std.mem.Allocator,
    sr: SavedRoutes,
    keep: *const std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!?SavedRoutes {
    var tracks: std.ArrayList(SavedTrack) = .empty;
    var vias: std.ArrayList(SavedVia) = .empty;
    var rf_paths: std.ArrayList(SavedRfPath) = .empty;
    for (sr.tracks) |t| {
        if (t.net.len > 0 and keep.contains(t.net)) try tracks.append(alloc, t);
    }
    for (sr.vias) |v| {
        if (v.net.len > 0 and keep.contains(v.net)) try vias.append(alloc, v);
    }
    for (sr.rf_paths) |path| if (keep.contains(path.net)) try rf_paths.append(alloc, path);
    if (tracks.items.len == 0 and vias.items.len == 0 and rf_paths.items.len == 0) return null;
    return .{ .tracks = try tracks.toOwnedSlice(alloc), .vias = try vias.toOwnedSlice(alloc), .rf_paths = try rf_paths.toOwnedSlice(alloc) };
}

/// Concatenate two optional route sets (either may be null), carrying one copy
/// of the persistent custom zones. Scoped fresh copper normally has no zones;
/// the fallback handles a zone-only side if either helper is used independently.
pub fn mcpMergeRoutes(alloc: std.mem.Allocator, a: ?SavedRoutes, b: ?SavedRoutes) std.mem.Allocator.Error!?SavedRoutes {
    const ta = if (a) |x| x.tracks else &[_]SavedTrack{};
    const tb = if (b) |x| x.tracks else &[_]SavedTrack{};
    const va = if (a) |x| x.vias else &[_]SavedVia{};
    const vb = if (b) |x| x.vias else &[_]SavedVia{};
    const za = if (a) |x| x.zones else &[_]SavedZone{};
    const zb = if (b) |x| x.zones else &[_]SavedZone{};
    const zones = if (za.len > 0) za else zb;
    const ra = if (a) |x| x.rf_paths else &[_]SavedRfPath{};
    const rb = if (b) |x| x.rf_paths else &[_]SavedRfPath{};
    if (ta.len + tb.len == 0 and va.len + vb.len == 0 and zones.len == 0 and ra.len + rb.len == 0) return null;
    const tracks = try alloc.alloc(SavedTrack, ta.len + tb.len);
    @memcpy(tracks[0..ta.len], ta);
    @memcpy(tracks[ta.len..], tb);
    const vias = try alloc.alloc(SavedVia, va.len + vb.len);
    @memcpy(vias[0..va.len], va);
    @memcpy(vias[va.len..], vb);
    const rf_paths = try alloc.alloc(SavedRfPath, ra.len + rb.len);
    @memcpy(rf_paths[0..ra.len], ra);
    @memcpy(rf_paths[ra.len..], rb);
    return .{ .tracks = tracks, .vias = vias, .zones = zones, .rf_paths = rf_paths };
}

/// Parse the `poses` argument of `set_part_poses` into `[]McpReqPose`. Null
/// when the arg is absent or not an array. Non-object entries are skipped;
/// per-item `x_mm`/`y_mm` presence is validated by the caller.
pub fn mcpParsePoses(alloc: std.mem.Allocator, args_val: ?std.json.Value) ?[]McpReqPose {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get("poses") orelse return null;
    if (v != .array) return null;
    var list: std.ArrayList(McpReqPose) = .empty;
    for (v.array.items) |it| {
        if (it != .object) continue;
        const ref_v = it.object.get("ref") orelse it.object.get("origin") orelse continue;
        if (ref_v != .string) continue;
        const xv = it.object.get("x_mm");
        const yv = it.object.get("y_mm");
        const rv = it.object.get("rot");
        const sv = it.object.get("side");
        const lv = it.object.get("locked");
        list.append(alloc, .{
            .ref = ref_v.string,
            .has_xy = xv != null and yv != null,
            .x = jsonNum(xv),
            .y = jsonNum(yv),
            .has_rot = rv != null,
            .rot = jsonNum(rv),
            .has_side = sv != null,
            .side = jsonSide(sv),
            .has_locked = lv != null,
            .locked = jsonFlag(lv),
        }) catch return list.items;
    }
    return list.toOwnedSlice(alloc) catch null;
}

/// The origin part of a possibly-prefixed key: "buck/U1" → "U1"; "C3" → "C3".
/// Pairs with `refPrefix` so a request can name a part by its module-local
/// origin key ("buck/C_IN") the same way a saved pose stores it.
pub fn mcpOriginOf(s: []const u8) []const u8 {
    const p = refPrefix(s);
    return if (p.len > 0 and s.len > p.len) s[p.len + 1 ..] else s;
}

/// `set_part_poses` — batch pose update on the design's working (or named)
/// layout. Every `ref` is resolved against the current flatten (exact ref-des
/// first, then module-local origin key scoped by sub-block prefix); an unknown
/// ref fails the whole call (nothing is written). Unlisted parts keep their
/// poses; a moved part's nets' persisted copper is dropped (stale).
pub fn mcpSetPartPoses(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = mcpArgStr(args_val, "name") orelse return mcpFail(out, alloc, mcp_err_missing_name);
    const reqs = mcpParsePoses(alloc, args_val) orelse return mcpFail(out, alloc, "missing or malformed \"poses\" array");
    if (reqs.len == 0) return mcpFail(out, alloc, "\"poses\" is empty");
    const layout_arg = mcpArgStr(args_val, "layout");
    const copper_scope = mcpArgStr(args_val, "copper_scope") orelse "nets";
    const local_copper = std.mem.eql(u8, copper_scope, "local");
    if (!local_copper and !std.mem.eql(u8, copper_scope, "nets"))
        return mcpFail(out, alloc, "copper_scope must be nets or local");

    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = solveForRequest(alloc, project_dir, name, .{ .layout = layout_arg }, &eval, &module_res) catch |e|
        return mcpFailFmt(out, alloc, mcp_err_resolve_layout, .{@errorName(e)});
    const placement = solved.placement;
    const base = posesFromPlacement(alloc, placement) orelse return mcpFail(out, alloc, "out of memory building poses");

    // ref/origin → index into `base`, for O(1) resolve + patch.
    var idx_of = std.StringHashMapUnmanaged(usize).empty;
    var origin_of = std.StringHashMapUnmanaged(usize).empty;
    for (base, 0..) |p, i| {
        try idx_of.put(alloc, p.ref, i);
        if (p.origin.len > 0) {
            const key = try std.fmt.allocPrint(alloc, pin_key_fmt, .{ refPrefix(p.ref), p.origin });
            try origin_of.put(alloc, key, i);
        }
    }

    var windows: std.ArrayList(MoveWindow) = .empty;
    var moved = std.StringHashMapUnmanaged(void).empty;
    var updated: std.ArrayList([]const u8) = .empty;
    for (reqs) |rq| {
        if (!rq.has_xy) return mcpFailFmt(out, alloc, "pose for \"{s}\" is missing x_mm/y_mm", .{rq.ref});
        const i: usize = idx_of.get(rq.ref) orelse blk: {
            const key = try std.fmt.allocPrint(alloc, pin_key_fmt, .{ refPrefix(rq.ref), mcpOriginOf(rq.ref) });
            break :blk origin_of.get(key) orelse
                return mcpFailFmt(out, alloc, "unknown ref \"{s}\" — not a component or origin key in this design", .{rq.ref});
        };
        var p = &base[i];
        const before_x = p.x;
        const before_y = p.y;
        const before_rot = p.rot;
        const before_side = p.side;
        p.x = rq.x;
        p.y = rq.y;
        if (rq.has_rot) p.rot = rq.rot;
        if (rq.has_side) p.side = rq.side;
        if (rq.has_locked) p.locked = rq.locked;
        if (before_x != p.x or before_y != p.y or before_rot != p.rot or before_side != p.side) {
            try moved.put(alloc, p.ref, {});
            const part = placement.parts[i];
            const radius = std.math.hypot(part.hw, part.hh) + placement.rules.design.clearance;
            try windows.append(alloc, .{ .x = before_x, .y = before_y, .radius = radius });
            try windows.append(alloc, .{ .x = p.x, .y = p.y, .radius = radius });
        }
        try updated.append(alloc, p.ref);
    }

    // A moved part's nets' persisted copper is now stale — drop it, keeping
    // the working layout's outline / texts / other-net copper intact.
    const working = mcpReadWorking(alloc, project_dir, name, layout_arg);
    var drop = try mcpNetsTouchingRefs(alloc, placement, &moved);
    const routes = if (working) |w| w.routes else null;
    const filtered = if (local_copper)
        try mcpDropMovedCopper(alloc, routes, &drop, windows.items)
    else
        try mcpDropRoutesForNets(alloc, routes, &drop);

    var entry = working orelse SavedLayout{
        .name = mcpWorkingName(alloc, project_dir, name, layout_arg),
        .kind = kind_manual,
        .ts = 0,
        .score = null,
        .parts = base,
    };
    entry.parts = base;
    entry.routes = filtered.routes;
    entry.score = null;
    try mcpPersistWorking(alloc, project_dir, name, entry, false);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.print(mcp_ok_layout_fmt, .{serve_root.getLiveVersion(name)});
    try writeJsonStr(w, entry.name);
    try w.print(",\"total_parts\":{d},\"moved\":{d},\"routes_dropped\":{d},\"updated\":[", .{ base.len, moved.count(), filtered.dropped });
    for (updated.items, 0..) |r, i| {
        if (i > 0) try w.writeAll(",");
        try writeJsonStr(w, r);
    }
    try w.writeAll("]}");
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// A `rect` object's nested `pts` array, if any (null when `rect` is absent
/// or not an object). Split out so the polygon lookup stays one short line.
fn mcpNestedPts(rect_v: ?std.json.Value) ?std.json.Value {
    const r = rect_v orelse return null;
    if (r != .object) return null;
    return r.object.get("pts");
}

/// Parse `set_board_outline`'s outline argument (`av` is the args object): a
/// `pts` polygon (top-level or under `rect`) wins, its bbox filling the rect
/// fields; else the `rect` (or top-level) `{x,y,w,h}`. Same validation as the
/// sidecar reader (`parseOutlinePts` / `parseSavedOutline`), so it round-trips.
pub fn mcpParseOutlineArg(alloc: std.mem.Allocator, av: std.json.Value) ?SavedOutline {
    const rect_v: ?std.json.Value = av.object.get("rect");
    const pts_v: ?std.json.Value = av.object.get("pts") orelse mcpNestedPts(rect_v);
    if (pts_v) |pv| {
        const pts = parseOutlinePts(alloc, pv) orelse return null;
        const bb = outline_mod.bboxRect(pts);
        if (!(bb.w > 0) or !(bb.h > 0)) {
            alloc.free(pts);
            return null;
        }
        return .{ .x = bb.minx, .y = bb.miny, .w = bb.w, .h = bb.h, .pts = pts };
    }
    return parseSavedOutline(alloc, rect_v orelse av);
}

/// `set_board_outline` — write the working layout's board outline (a
/// `{x,y,w,h}` rect or a `pts` polygon ≥3 vertices). The outline becomes the
/// placement's `board_rect`/`board_poly`, so every renderer draws it and the
/// board-edge DRC + Gerber Edge.Cuts profile use it. Bootstraps a base
/// placement when the design has no layout yet.
pub fn mcpSetBoardOutline(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = mcpArgStr(args_val, "name") orelse return mcpFail(out, alloc, mcp_err_missing_name);
    const layout_arg = mcpArgStr(args_val, "layout");
    const av = args_val orelse return mcpFail(out, alloc, "missing outline");
    if (av != .object) return mcpFail(out, alloc, "missing rect/pts");

    // A `pts` polygon (top-level or under `rect`) wins; else the `rect`
    // (or top-level) `{x,y,w,h}`. `parseOutlinePts` + `parseSavedOutline`
    // do the validation the sidecar reader uses, so an outline set here reads
    // back identically.
    const outline = mcpParseOutlineArg(alloc, av) orelse
        return mcpFail(out, alloc, "invalid outline — need a positive-area rect {x,y,w,h} or a polygon pts of ≥3 vertices");
    // A polygon outline must be fab-legal: no self-crossing edges, non-zero area
    // (a rect has no `pts` and is always simple, so it skips this).
    if (outline.pts) |pts| {
        if (!outline_mod.valid(pts))
            return mcpFail(out, alloc, "invalid outline — the polygon self-intersects or has zero area");
    }

    if (!mcpBlockExists(alloc, project_dir, name)) return mcpFail(out, alloc, mcp_err_no_design);
    const working = mcpReadWorking(alloc, project_dir, name, layout_arg);
    const parts: []const PartPose = if (working) |wl| wl.parts else mcpBootstrapParts(alloc, project_dir, name, layout_arg) orelse
        return mcpFail(out, alloc, "could not resolve a placement to attach the outline to");

    const entry = SavedLayout{
        .name = mcpWorkingName(alloc, project_dir, name, layout_arg),
        .kind = kind_manual,
        .ts = 0,
        .score = null,
        .parts = parts,
        .routes = if (working) |wl| wl.routes else null,
        .outline = outline,
        .texts = if (working) |wl| wl.texts else &.{},
        .dimensions = mcpWorkingDimensions(working),
    };
    try mcpPersistWorking(alloc, project_dir, name, entry, false);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.print(mcp_ok_layout_fmt, .{serve_root.getLiveVersion(name)});
    try writeJsonStr(w, entry.name);
    try w.writeAll(outline_open);
    try writeSavedOutlineJson(w, outline);
    try w.writeAll("}");
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// Parse and validate `set_copper_zones`' complete replacement set. This tool
/// authors conductive pours only: every member needs a real net, a routable
/// (non-plane-claimed) copper layer, and a simple positive-area polygon.
pub fn mcpBuildCopperZones(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    placement: optimizer.Placement,
    args_val: ?std.json.Value,
) HandlerError!?[]const SavedZone {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const zv = av.object.get("zones") orelse return null;
    if (zv != .array) return null;
    var zones: std.ArrayList(SavedZone) = .empty;
    for (zv.array.items, 0..) |item, i| {
        if (item != .object) {
            _ = try mcpFailFmt(out, alloc, "zone {d} is not an object", .{i});
            return null;
        }
        const net_v = item.object.get("net") orelse {
            _ = try mcpFailFmt(out, alloc, "zone {d} is missing net", .{i});
            return null;
        };
        const layer_v = item.object.get("layer") orelse {
            _ = try mcpFailFmt(out, alloc, "zone {d} is missing layer", .{i});
            return null;
        };
        const poly_v = item.object.get("poly") orelse {
            _ = try mcpFailFmt(out, alloc, "zone {d} is missing poly", .{i});
            return null;
        };
        if (net_v != .string or layer_v != .string) {
            _ = try mcpFailFmt(out, alloc, "zone {d} net/layer must be strings", .{i});
            return null;
        }
        if (netIndexByName(placement, net_v.string) == null) {
            _ = try mcpFailFmt(out, alloc, "unknown net \"{s}\" in zone {d}", .{ net_v.string, i });
            return null;
        }
        if (placement.rules.signalIndexOfName(layer_v.string) == null) {
            _ = try mcpFailFmt(out, alloc, "unknown or plane-claimed copper layer \"{s}\" in zone {d}", .{ layer_v.string, i });
            return null;
        }
        const poly = parseOutlinePts(alloc, poly_v) orelse {
            _ = try mcpFailFmt(out, alloc, "zone {d} needs a poly of at least 3 [x,y] vertices", .{i});
            return null;
        };
        if (!outline_mod.valid(poly)) {
            _ = try mcpFailFmt(out, alloc, "zone {d} polygon self-intersects or has zero area", .{i});
            return null;
        }
        var priority: i64 = 0;
        if (item.object.get("priority")) |pv| priority = switch (pv) {
            .integer => |n| n,
            .float => |n| numeric.checkedInt(i64, n) orelse {
                _ = try mcpFailFmt(out, alloc, "zone {d} priority must be an integer", .{i});
                return null;
            },
            else => {
                _ = try mcpFailFmt(out, alloc, "zone {d} priority must be an integer", .{i});
                return null;
            },
        };
        var group: []const u8 = "";
        if (item.object.get("group")) |gv| {
            if (gv != .string) {
                _ = try mcpFailFmt(out, alloc, "zone {d} group must be a string", .{i});
                return null;
            }
            group = gv.string;
        }
        try zones.append(alloc, .{
            .net = net_v.string,
            .layer = layer_v.string,
            .poly = poly,
            .flags = .{ .filled = true },
            .g = group,
            .priority = priority,
        });
    }
    return try zones.toOwnedSlice(alloc);
}

/// Replace the saved layout's user copper pours without touching its poses,
/// tracks, vias, outline, or text. An empty `zones` array intentionally clears
/// every custom pour. This is the headless twin of drawing/editing pours in the
/// browser and gives agents an in-band path instead of hand-editing sidecars.
pub fn mcpSetCopperZones(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = mcpArgStr(args_val, "name") orelse return mcpFail(out, alloc, mcp_err_missing_name);
    const layout_arg = mcpArgStr(args_val, "layout");

    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = solveForRequest(alloc, project_dir, name, .{ .layout = layout_arg }, &eval, &module_res) catch |e|
        return mcpFailFmt(out, alloc, mcp_err_resolve_layout, .{@errorName(e)});
    const zones = (try mcpBuildCopperZones(alloc, out, solved.placement, args_val)) orelse {
        if (out.items.len > 0) return false;
        return mcpFail(out, alloc, "missing or malformed zones array");
    };
    const working = mcpReadWorking(alloc, project_dir, name, layout_arg);
    const old_routes = if (working) |w| w.routes else null;
    const old_tracks = if (old_routes) |r| r.tracks else &[_]SavedTrack{};
    const old_vias = if (old_routes) |r| r.vias else &[_]SavedVia{};
    const old_rf = if (old_routes) |r| r.rf_paths else &[_]SavedRfPath{};
    const routes: ?SavedRoutes = if (old_tracks.len + old_vias.len + old_rf.len + zones.len > 0) .{
        .tracks = old_tracks,
        .vias = old_vias,
        .zones = zones,
        .rf_paths = old_rf,
    } else null;
    const entry = SavedLayout{
        .name = mcpWorkingName(alloc, project_dir, name, layout_arg),
        .kind = kind_manual,
        .ts = 0,
        .score = if (working) |w| w.score else null,
        .parts = if (working) |w| w.parts else posesFromPlacement(alloc, solved.placement) orelse &.{},
        .routes = routes,
        .outline = if (working) |w| w.outline else null,
        .texts = if (working) |w| w.texts else &.{},
        .dimensions = mcpWorkingDimensions(working),
    };
    try mcpPersistWorking(alloc, project_dir, name, entry, false);

    const user_zones = userZonesFrom(alloc, solved.placement.rules, zones);
    var tally = fab_readiness.Tally{};
    var violations: []const drc.Violation = &.{};
    if (routes) |saved| if (restoreRoutes(alloc, saved, solved.placement.nets)) |rr| {
        tally = try fab_readiness.routableTally(alloc, solved.placement, .{
            .tracks = rr.tracks,
            .vias = rr.vias,
            .zones = user_zones,
        });
        violations = drc_rules.checkFilteredZones(alloc, project_dir, name, .{
            .placement = solved.placement,
            .routed = rr,
            .clearance = solved.placement.rules.design.routeParams().clearance,
            .zones = user_zones,
        });
    };

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.print(mcp_ok_layout_fmt, .{serve_root.getLiveVersion(name)});
    try writeJsonStr(w, entry.name);
    try w.print(",\"zones\":{d},\"routed\":{d},\"total\":{d},\"drc\":{d},\"drc_errors\":{d},\"open\":", .{
        zones.len,
        tally.routed,
        tally.total,
        violations.len,
        drc.errorCount(violations),
    });
    try mcpWriteStrArray(w, tally.open);
    try w.writeAll("}");
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// Base poses for a design with no working layout yet — solve fresh and take
/// the auto placement's poses (live ref-des + origin keys). Null on failure.
fn mcpBootstrapParts(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, layout_arg: ?[]const u8) ?[]const PartPose {
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = solveForRequest(alloc, project_dir, name, .{ .layout = layout_arg }, &eval, &module_res) catch return null;
    return posesFromPlacement(alloc, solved.placement);
}

// ── route_pcb scoping helpers ────────────────────────────────────────────────

/// Retained copper for the nets NOT in a scoped route — stamped as a physical
/// obstacle and echoed unchanged in the router's result.
pub const McpExistingCopper = struct {
    tracks: []const route_policy.ExistingTrack = &.{},
    vias: []const route_policy.ExistingVia = &.{},
};

/// Translate a completed saved layout into the normalized physical copper view
/// used by the reference-router experiment.  The conversion is deliberately
/// copper-only: target placement supplies the live terminals, while the saved
/// tracks/vias supply the topology the router should learn.
fn mcpReferenceSnapshot(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    saved: SavedRoutes,
) std.mem.Allocator.Error!pcb_snapshot.Snapshot {
    var segments: std.ArrayList(pcb_snapshot.Segment) = .empty;
    var arcs: std.ArrayList(pcb_snapshot.Arc) = .empty;
    for (saved.tracks) |track| {
        var layer_buf: [board_layers.name_buf_len]u8 = undefined;
        const layer = try alloc.dupe(u8, placement.rules.signalLayerName(track.l, &layer_buf));
        if (track.xm != null and track.ym != null) {
            try arcs.append(alloc, .{
                .start = .{ .x = track.x1, .y = track.y1 },
                .mid = .{ .x = track.xm.?, .y = track.ym.? },
                .end = .{ .x = track.x2, .y = track.y2 },
                .width = track.w,
                .layer = layer,
                .net = track.net,
            });
        } else {
            try segments.append(alloc, .{
                .start = .{ .x = track.x1, .y = track.y1 },
                .end = .{ .x = track.x2, .y = track.y2 },
                .width = track.w,
                .layer = layer,
                .net = track.net,
            });
        }
    }
    var vias = try alloc.alloc(pcb_snapshot.Via, saved.vias.len);
    for (saved.vias, 0..) |via, i| vias[i] = .{
        .at = .{ .x = via.x, .y = via.y },
        .size = via.d,
        .drill = via.drill,
        .net = via.net,
    };
    return .{
        .segments = try segments.toOwnedSlice(alloc),
        .arcs = try arcs.toOwnedSlice(alloc),
        .vias = vias,
    };
}

fn mcpConcat(comptime T: type, alloc: std.mem.Allocator, a: []const T, b: []const T) std.mem.Allocator.Error![]const T {
    if (a.len == 0) return b;
    if (b.len == 0) return a;
    const out = try alloc.alloc(T, a.len + b.len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return out;
}

/// Overlay learned path topology on the authored plan without erasing its wave
/// priorities, hard layer limits, via budgets, or lane reservations.
pub fn mcpApplyReferenceGuides(
    alloc: std.mem.Allocator,
    options: *route_policy.Options,
    placement: optimizer.Placement,
    saved: SavedRoutes,
) std.mem.Allocator.Error!usize {
    const snapshot = try mcpReferenceSnapshot(alloc, placement, saved);
    const learned = try reference_guides.build(alloc, placement, snapshot, &.{}, .path, 0.05);
    const policies = try alloc.alloc(route_policy.NetPolicy, placement.nets.len);
    for (policies, 0..) |*policy, i| {
        policy.* = if (i < options.net.len) options.net[i] else .{};
        if (i >= learned.policies.len or !learned.policies[i].replay_reference_copper) continue;
        const reference = learned.policies[i];
        if (policy.preferred_layers == 0) policy.preferred_layers = reference.preferred_layers;
        policy.waypoints = reference.waypoints;
        policy.branches = reference.branches;
        policy.replay_reference_copper = true;
    }
    options.net = policies;
    options.guides.tracks = try mcpConcat(route_policy.GuideTrack, alloc, options.guides.tracks, learned.tracks);
    options.guides.vias = try mcpConcat(route_policy.GuideVia, alloc, options.guides.vias, learned.vias);
    const layer_count: usize = placement.rules.signalLayerCount();
    const reserved = try alloc.alloc(route_policy.ReservedLane, learned.vias.len * layer_count);
    const via_claim = placement.rules.design.via_dia +
        2 * placement.rules.design.clearance + placement.rules.design.track_width;
    var reserve_i: usize = 0;
    for (learned.vias) |via| for (0..layer_count) |layer| {
        reserved[reserve_i] = .{
            .x1 = via.x,
            .y1 = via.y,
            .x2 = via.x,
            .y2 = via.y,
            .layer = @intCast(layer),
            .net = via.net,
            .width = @max(via_claim, via.dia),
        };
        reserve_i += 1;
    };
    options.guides.reserved = try mcpConcat(route_policy.ReservedLane, alloc, options.guides.reserved, reserved);
    return learned.guided_nets;
}

const McpReferenceLayoutInput = struct {
    project_dir: []const u8,
    name: []const u8,
    placement: optimizer.Placement,
    options: *route_policy.Options,
    reference_layout: ?[]const u8,
};

fn mcpApplyReferenceLayout(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    input: McpReferenceLayoutInput,
) HandlerError!?usize {
    const reference_name = input.reference_layout orelse return 0;
    var reference_routes: ?SavedRoutes = null;
    for (readLayouts(alloc, input.project_dir, input.name)) |candidate| {
        if (std.mem.eql(u8, candidate.name, reference_name)) {
            reference_routes = candidate.routes;
            break;
        }
    }
    const saved = reference_routes orelse {
        _ = try mcpFailFmt(out, alloc, "reference layout \"{s}\" does not exist or has no copper", .{reference_name});
        return null;
    };
    const guided = try mcpApplyReferenceGuides(alloc, input.options, input.placement, saved);
    if (guided == 0) {
        _ = try mcpFailFmt(out, alloc, "reference layout \"{s}\" has no usable routed-net topology", .{reference_name});
        return null;
    }
    return guided;
}

/// The full net NAMES a resolved scope mask selects, in net order — the keys the
/// SavedRoutes drop/keep/merge machinery matches on when persisting scoped copper.
fn scopeNetNames(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    mask: []const bool,
) std.mem.Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (mask, 0..) |on, ni| if (on and ni < placement.nets.len) {
        try list.append(alloc, placement.nets[ni].name);
    };
    return list.toOwnedSlice(alloc);
}

/// A resolved + validated ad-hoc route scope: `mask` and `names` select the same
/// nets (index mask + full names), `matched` counts them, and `has_scope` is
/// false only when no selector token was named (⇒ route the whole board).
pub const McpScope = struct {
    mask: []const bool,
    names: []const []const u8,
    matched: usize,
    has_scope: bool,
};

/// Resolve `groups` (generic net-class / criticality-class / sub-block / net
/// tokens) ∪ `nets` (explicit names) into a validated scope shared by `route_pcb`
/// and `clear_routes`. On an unknown token or a scope matching no net it writes
/// the `{ok:false}` error into `out` and returns null (the handler returns
/// false); a request with no selector returns `has_scope = false`.
pub fn mcpResolveRouteScope(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
    groups: []const []const u8,
    nets: []const []const u8,
) HandlerError!?McpScope {
    const rs = route_plan.resolveScope(alloc, block, placement, .{ .groups = groups, .nets = nets }) catch |e| {
        _ = try mcpFailFmt(out, alloc, "could not resolve route scope: {s}", .{@errorName(e)});
        return null;
    };
    const has_scope = rs.selectors > 0;
    if (has_scope) {
        if (rs.unknown.len > 0) {
            _ = try mcpFailFmt(out, alloc, "unknown route group/net: {s}", .{rs.unknown[0]});
            return null;
        }
        if (rs.matched == 0) {
            _ = try mcpFail(out, alloc, "route scope matched no nets on this board");
            return null;
        }
    }
    const pair_added = if (has_scope) route_plan.includeDiffPartners(placement, rs.mask) else 0;
    return .{
        .mask = rs.mask,
        .names = try scopeNetNames(alloc, placement, rs.mask),
        .matched = rs.matched + pair_added,
        .has_scope = has_scope,
    };
}

/// Write a JSON array of strings: `["a","b"]`.
pub fn mcpWriteStrArray(w: *std.Io.Writer, items: []const []const u8) std.Io.Writer.Error!void {
    try w.writeAll("[");
    for (items, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try writeJsonStr(w, s);
    }
    try w.writeAll("]");
}

/// Convert all non-selected working copper to retained maze obstacles.
pub fn mcpExistingCopper(
    alloc: std.mem.Allocator,
    routed: router.RouteResult,
    selected: []const bool,
) std.mem.Allocator.Error!McpExistingCopper {
    var tracks: std.ArrayList(route_policy.ExistingTrack) = .empty;
    var vias: std.ArrayList(route_policy.ExistingVia) = .empty;
    for (routed.tracks) |track| {
        const ni: usize = if (track.net >= 0) @intCast(track.net) else selected.len;
        if (ni < selected.len and selected[ni]) continue;
        try tracks.append(alloc, .{
            .x1 = track.x1,
            .y1 = track.y1,
            .x2 = track.x2,
            .y2 = track.y2,
            .layer = track.layer,
            .width = track.width,
            .net = track.net,
        });
    }
    for (routed.vias) |via| {
        const ni: usize = if (via.net >= 0) @intCast(via.net) else selected.len;
        if (ni < selected.len and selected[ni]) continue;
        try vias.append(alloc, .{
            .x = via.x,
            .y = via.y,
            .dia = via.dia,
            .drill = via.drill,
            .net = via.net,
        });
    }
    return .{ .tracks = tracks.items, .vias = vias.items };
}

/// Apply route_pcb's optional persisted-run effort override. False means the
/// caller supplied a string other than the two public tiers.
pub fn mcpApplyRouteEffort(options: *route_policy.Options, args_val: ?std.json.Value) bool {
    const word = mcpArgStr(args_val, "effort") orelse return true;
    if (std.mem.eql(u8, word, "one_shot") or std.mem.eql(u8, word, "one-shot")) {
        options.effort = .one_shot;
    } else if (std.mem.eql(u8, word, "standard")) {
        options.effort = .standard;
    } else return false;
    return true;
}

fn mcpSavedTraceMm(routes: ?SavedRoutes) f64 {
    var trace_mm: f64 = 0;
    const saved = routes orelse return trace_mm;
    for (saved.tracks) |track| trace_mm += std.math.hypot(track.x2 - track.x1, track.y2 - track.y1);
    return trace_mm;
}

/// Autoroute and persist the working PCB layout, applying any authored
/// `(pcb-plan (route …))` wave order and layer policy.
pub fn mcpRoutePcb(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    return routePcbWithCancel(alloc, project_dir, args_val, out, null);
}

pub fn routePcbWithCancel(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
    cancel: ?*std.atomic.Value(bool),
) HandlerError!bool {
    const started_ms = clock.milliTimestamp();
    const name = mcpArgStr(args_val, "name") orelse return mcpFail(out, alloc, mcp_err_missing_name);
    const layout_arg = mcpArgStr(args_val, "layout");
    const nets_arg = mcpArgStrList(alloc, args_val, "nets");
    const groups_arg = mcpArgStrList(alloc, args_val, "groups");
    const selected_only_opt = mcpArgBoolOpt(args_val, "selected_only");
    const reference_layout = mcpArgStr(args_val, "reference_layout");
    const defer_drc = mcpArgBool(args_val, "defer_drc");

    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = solveForRequest(alloc, project_dir, name, .{ .layout = layout_arg }, &eval, &module_res) catch |e|
        return mcpFailFmt(out, alloc, mcp_err_resolve_layout, .{@errorName(e)});
    const placement = solved.placement;
    const rp = placement.rules.design.routeParams();
    const lowered_plan = route_plan.lower(alloc, solved.block, solved.placement) catch |e|
        return mcpFailFmt(out, alloc, "could not resolve PCB plan: {s}", .{@errorName(e)});

    // Resolve the ad-hoc scope (groups ∪ nets); a bad token / empty match writes
    // its own error and returns null here.
    const rscope = (try mcpResolveRouteScope(alloc, out, solved.block, placement, groups_arg, nets_arg)) orelse
        return false;
    // Incremental by default whenever a scope was named: route only the scoped
    // nets and keep every other net's copper. `selected_only:false` opts back
    // into a whole-board re-route that merely ADOPTS the scoped nets' new copper.
    const selected_only = selected_only_opt orelse rscope.has_scope;
    if (selected_only and !rscope.has_scope)
        return mcpFail(out, alloc, "selected_only needs a nets or groups scope");

    const working = mcpReadWorking(alloc, project_dir, name, layout_arg);
    const prior_routes = if (working) |wl| wl.routes else null;
    var route_options = lowered_plan.options;
    route_options.stop.cancel = cancel;
    route_options.guides.saved_module_routes = mcpArgBoolOpt(args_val, "saved_module_routes") orelse true;
    if (!mcpApplyRouteEffort(&route_options, args_val))
        return mcpFail(out, alloc, "effort must be \"one_shot\" or \"standard\"");
    // Hand-authored pours are retained physical copper. Every CLI route sees
    // them as same-net maze sources just like the browser Route button does,
    // including an excluded In2.Cu pour that terminals reach through vias.
    route_options.existing_zones = solved.shown_zones.sources;
    const reference_guided = (try mcpApplyReferenceLayout(alloc, out, .{
        .project_dir = project_dir,
        .name = name,
        .placement = placement,
        .options = &route_options,
        .reference_layout = reference_layout,
    })) orelse return false;
    if (selected_only) {
        route_options.selected_nets = rscope.mask;
        if (prior_routes) |saved| if (restoreRoutes(alloc, saved, placement.nets)) |prior| {
            const existing = try mcpExistingCopper(alloc, prior, rscope.mask);
            route_options.existing_tracks = existing.tracks;
            route_options.existing_vias = existing.vias;
        };
    }
    // Through the shared seam's gate, not `router.routeWithOptions` directly:
    // the committed board must report the same oracle-checked `routed` count
    // the preview surfaces do (see `route_plan.routeLowered`).
    const seeded = routeWithSubcircuitSeeds(alloc, project_dir, solved.block, placement, rp, route_options) catch |e|
        return mcpFailFmt(out, alloc, "routing failed: {s}", .{@errorName(e)});
    const seed_stats = seeded.seeds;
    var routed = seeded.result;
    routed = (try perimeter_fence.append(alloc, placement, routed)).?;
    var fresh = try mcpSavedRoutesFrom(alloc, routed, placement.nets, prior_routes);
    // Autorouting replaces tracks/vias, never the user's custom polygons.
    fresh.zones = if (prior_routes) |saved| saved.zones else &.{};

    var merged: ?SavedRoutes = undefined;
    if (rscope.has_scope) {
        var keep = std.StringHashMapUnmanaged(void).empty;
        for (rscope.names) |n| try keep.put(alloc, n, {});
        const base_after_drop = try mcpDropRoutesForNets(alloc, prior_routes, &keep);
        const fresh_scoped = try mcpKeepRoutesForNets(alloc, fresh, &keep);
        merged = try mcpMergeRoutes(alloc, base_after_drop.routes, fresh_scoped);
    } else {
        merged = if (fresh.tracks.len == 0 and fresh.vias.len == 0 and fresh.zones.len == 0) null else fresh;
    }
    merged = routesWithPerimeter(alloc, placement, merged);

    const candidate = merged;
    const candidate_result = if (candidate) |sr| restoreRoutes(alloc, sr, placement.nets) else null;
    const candidate_tally = try route_copper_state.tally(alloc, placement, candidate_result, solved.shown_zones.user);
    // A cancelled candidate has not completed the validation/finishing pipeline.
    // Keep it measurable, but preserve the working sidecar byte-for-byte.
    if (routed.cancelled) merged = prior_routes;
    const committed = if (merged) |sr| restoreRoutes(alloc, sr, placement.nets) else null;
    const committed_tally = try route_copper_state.tally(alloc, placement, committed, solved.shown_zones.user);

    // Checkpoint routed copper before the optional full-board DRC report. DRC
    // is diagnostic here (route_pcb has never rolled copper back on a
    // finding), and a dense-board report can be much slower than a selected
    // route. Persisting first means a client timeout cannot erase a successful
    // automatic batch. `defer_drc` lets a checkpointed run return immediately;
    // the final candidate still goes through run_fab_readiness once all scopes
    // are complete.
    const entry = SavedLayout{
        .name = mcpWorkingName(alloc, project_dir, name, layout_arg),
        .kind = kind_manual,
        .ts = 0,
        .score = null,
        .parts = if (working) |wl| wl.parts else posesFromPlacement(alloc, placement) orelse &.{},
        .routes = merged,
        .outline = if (working) |wl| wl.outline else null,
        .texts = if (working) |wl| wl.texts else &.{},
        .dimensions = mcpWorkingDimensions(working),
    };
    if (!routed.cancelled) try mcpPersistWorking(alloc, project_dir, name, entry, false);

    // DRC-check exactly what was persisted unless this is a fast checkpoint.
    // Keep the direct pour-aware call visible at this mutation boundary: the
    // result is the report, not an error-union or a second generic DRC pass.
    var route_findings: []const drc.Violation = &.{};
    if (!defer_drc) if (merged) |saved| if (restoreRoutes(alloc, saved, placement.nets)) |restored| {
        const v = drc_rules.checkFilteredZones(alloc, project_dir, name, .{
            .placement = placement,
            .routed = restored,
            .clearance = rp.clearance,
            .zones = solved.shown_zones.user,
        });
        route_findings = v;
    };
    const trace_mm = mcpSavedTraceMm(merged);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.print(mcp_ok_layout_fmt, .{serve_root.getLiveVersion(name)});
    try writeJsonStr(w, entry.name);
    try w.print(",\"routed\":{d},\"total\":{d},", .{ committed_tally.routed, committed_tally.total });
    try route_result_stats.writeDrc(w, route_findings, @max(0, clock.milliTimestamp() - started_ms));
    try w.print(
        ",\"drc_deferred\":{},\"trace_mm\":{d:.3},\"tracks\":{d},\"vias\":{d},\"reference_guided\":{d},\"reference_replayed\":{d}" ++
            ",\"pcb_plan\":{s},\"plan_warnings\":{d},\"selected_only\":{s},\"selected\":{d},\"groups\":",
        .{
            defer_drc,
            trace_mm,
            savedTrackCount(merged),
            savedViaCount(merged),
            reference_guided,
            routed.reference_replayed.len,
            if (lowered_plan.applied) "true" else "false",
            lowered_plan.warnings,
            if (selected_only) "true" else "false",
            rscope.matched,
        },
    );
    try mcpWriteStrArray(w, groups_arg);
    // `scope` echoes the CONCRETE net names the scope resolved to (so the agent
    // sees exactly what routed), or "all" for a whole-board run.
    try w.writeAll(",\"scope\":");
    if (!rscope.has_scope) try w.writeAll("\"all\"") else try mcpWriteStrArray(w, rscope.names);
    try w.writeAll(",\"unrouted\":");
    try mcpWriteStrArray(w, committed_tally.open);
    try w.print(",\"applied\":{},\"cancelled\":{},\"candidate\":{{\"routed\":{d},\"total\":{d},\"tracks\":{d},\"vias\":{d},\"validation_complete\":{},\"unrouted\":", .{
        !routed.cancelled,          routed.cancelled,         candidate_tally.routed, candidate_tally.total,
        savedTrackCount(candidate), savedViaCount(candidate), !routed.cancelled,
    });
    try mcpWriteStrArray(w, candidate_tally.open);
    try w.writeAll("}");
    try writeRouteSeedStats(w, seed_stats);
    try w.writeAll("}");
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// `save_pcb_layout` — snapshot the working state as a named layout, optionally
/// starred. `layout_name` names it (default: keep the working layout's own name,
/// so a plain save updates in place rather than forking a copy); `star` marks it
/// the blessed board, clearing any other default. A block's first-ever layout is
/// starred regardless — something must be blessed for the page, the KiCad sync
/// and the fab outputs to resolve.
pub fn mcpSavePcbLayout(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = mcpArgStr(args_val, "name") orelse return mcpFail(out, alloc, mcp_err_missing_name);
    const layout_name = mcpArgStr(args_val, "layout_name");
    const star = mcpArgBool(args_val, "star");

    if (!mcpBlockExists(alloc, project_dir, name)) return mcpFail(out, alloc, mcp_err_no_design);
    const source_project = mcpArgStr(args_val, "source_project_dir") orelse project_dir;
    const source_layout = mcpArgStr(args_val, "layout");
    const importing = !std.mem.eql(u8, source_project, project_dir);
    if (importing and (layout_name == null or source_layout == null))
        return mcpFail(out, alloc, "importing requires an explicit source layout and new layout_name");
    const working = mcpReadWorking(alloc, source_project, name, source_layout) orelse
        return mcpFail(out, alloc, "no working layout to save — set poses (or an outline) first");

    // No `layout_name` = save the working layout back into itself. Naming one
    // forks the working state into a new snapshot alongside it — that fork is
    // how an agent banks a routing candidate before trying the next.
    const target_name: []const u8 = layout_name orelse working.name;
    var entry = working;
    entry.name = target_name;
    entry.kind = kind_manual;
    entry.ts = 0;
    if (importing) {
        mcpCreateWorking(alloc, project_dir, name, entry) catch |err| switch (err) {
            error.CandidateNameExists => return mcpFail(out, alloc, "candidate name already exists"),
            else => |other| return other,
        };
    } else {
        try mcpPersistWorking(alloc, project_dir, name, entry, star);
    }

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    // Report the star as it ENDED UP, not as asked: `starFirstEver` stars a
    // block's first-ever layout even when the caller didn't ask for it.
    const starred = mcpIsStarred(alloc, project_dir, name, target_name);
    try w.print("{{\"ok\":true,\"live_version\":{d},\"starred\":{s},\"layout\":", .{
        serve_root.getLiveVersion(name),
        if (starred) "true" else "false",
    });
    try writeJsonStr(w, target_name);
    try w.writeAll("}");
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// Resolve `groups` to concrete net names for `clear_routes`. This is the only
/// clear path that evaluates the design — group tokens need a solved placement
/// to classify nets — so it stays out of the fast `nets`-only path. Writes an
/// `{ok:false}` error into `out` and returns null on a bad token / unresolvable
/// design.
fn mcpClearGroupNames(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    project_dir: []const u8,
    name: []const u8,
    groups: []const []const u8,
) HandlerError!?[]const []const u8 {
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    // UNTESTED-ERROR: Existing CLI error-to-response adapter relocated without changing its recovery behavior.
    const solved = solveForRequest(alloc, project_dir, name, .{}, &eval, &module_res) catch |e| {
        _ = try mcpFailFmt(out, alloc, mcp_err_resolve_layout, .{@errorName(e)});
        return null;
    };
    const rscope = (try mcpResolveRouteScope(alloc, out, solved.block, solved.placement, groups, &.{})) orelse return null;
    return rscope.names;
}

/// Remove all route-wave output while retaining user-authored zone intent.
/// Null means no zone remains, so the layout truly has no route object.
pub fn mcpClearAllRoutedCopper(sr: SavedRoutes) ?SavedRoutes {
    if (sr.zones.len == 0) return null;
    return .{
        .tracks = &.{},
        .vias = &.{},
        .zones = sr.zones,
    };
}

/// `clear_routes` — drop all persisted routed tracks/vias from the working
/// layout, or only the copper of a `nets` / `groups` scope, keeping poses,
/// outline, texts, and user-authored copper zones. The inverse of `route_pcb`,
/// sharing its scope vocabulary; zones are layout intent and feed the next
/// route rather than being output of the route wave.
pub fn mcpClearRoutes(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = mcpArgStr(args_val, "name") orelse return mcpFail(out, alloc, mcp_err_missing_name);
    const layout_arg = mcpArgStr(args_val, "layout");
    const nets_arg = mcpArgStrList(alloc, args_val, "nets");
    const groups_arg = mcpArgStrList(alloc, args_val, "groups");
    const near_x = mcpArgNumOpt(args_val, "x");
    const near_y = mcpArgNumOpt(args_val, "y");
    const radius_arg = mcpArgNumOpt(args_val, "radius");
    const has_near = near_x != null or near_y != null or radius_arg != null;

    if (!mcpBlockExists(alloc, project_dir, name)) return mcpFail(out, alloc, mcp_err_no_design);
    const working = mcpReadWorking(alloc, project_dir, name, layout_arg) orelse
        return mcpFail(out, alloc, "no working layout to clear");

    // The net names to drop: explicit `nets` (verbatim) plus every net each
    // `groups` token resolves to.
    var drop = std.StringHashMapUnmanaged(void).empty;
    for (nets_arg) |n| try drop.put(alloc, n, {});
    if (groups_arg.len > 0) {
        const names = (try mcpClearGroupNames(alloc, out, project_dir, name, groups_arg)) orelse return false;
        for (names) |n| try drop.put(alloc, n, {});
    }
    const scoped = nets_arg.len > 0 or groups_arg.len > 0;

    if (has_near and (near_x == null or near_y == null))
        return mcpFail(out, alloc, "coordinate-scoped clear_routes requires both x and y");
    if (has_near and !scoped)
        return mcpFail(out, alloc, "coordinate-scoped clear_routes requires a nets or groups scope");
    const near_radius = radius_arg orelse 0.05;
    if (has_near) {
        if (!std.math.isFinite(near_x.?))
            return mcpFail(out, alloc, "coordinate-scoped clear_routes needs finite x/y and radius > 0");
        if (!std.math.isFinite(near_y.?))
            return mcpFail(out, alloc, "coordinate-scoped clear_routes needs finite x/y and radius > 0");
        if (!std.math.isFinite(near_radius) or near_radius <= 0)
            return mcpFail(out, alloc, "coordinate-scoped clear_routes needs finite x/y and radius > 0");
    }

    var cleared: usize = 0;
    var new_routes: ?SavedRoutes = null;
    if (has_near) {
        const res = try mcpDropViasNear(alloc, working.routes, &drop, near_x.?, near_y.?, near_radius);
        if (res.dropped == 0)
            return mcpFail(out, alloc, "no selected via found within radius of x/y");
        new_routes = res.routes;
        cleared = res.dropped;
    } else if (scoped) {
        const res = try mcpDropRoutesForNets(alloc, working.routes, &drop);
        new_routes = res.routes;
        cleared = res.dropped;
    } else if (working.routes) |sr| {
        cleared = sr.tracks.len + sr.vias.len;
        // A clean-slate route still needs its authored power pours. They are
        // route INPUT, not disposable output; retain them while clearing every
        // routed track/via/RF path. This also keeps an In3 power plan from
        // silently disappearing in the normal clear → route workflow.
        new_routes = mcpClearAllRoutedCopper(sr);
    }

    const entry = SavedLayout{
        .name = working.name,
        .kind = kind_manual,
        .ts = 0,
        .score = working.score,
        .parts = working.parts,
        .routes = new_routes,
        .outline = working.outline,
        .texts = working.texts,
        .dimensions = working.dimensions,
    };
    try mcpPersistWorking(alloc, project_dir, name, entry, false);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.print(mcp_ok_layout_fmt, .{serve_root.getLiveVersion(name)});
    try writeJsonStr(w, entry.name);
    try w.print(",\"cleared\":{d}}}", .{cleared});
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// One requested polyline of agent-authored copper: a net, a signal-layer NAME ("F.Cu"),
/// ≥2 points in board mm, and an optional width override (0 = the net's class).
pub const McpReqTrack = struct {
    net: []const u8,
    layer: []const u8,
    pts: []const [2]f64,
    width: f64 = 0,
};

/// One requested via (0 dia/drill = the net's `(net-class …)` via geometry).
pub const McpReqVia = struct {
    net: []const u8,
    x: f64,
    y: f64,
    dia: f64 = 0,
    drill: f64 = 0,
    /// Optional `"span":["F.Cu","In2.Cu"]` — the barrel's two copper layers as
    /// KiCad NAMES, resolved against this board's stackup (see `SavedVia.s`).
    span: ?[2][]const u8 = null,
};

/// A net's effective routing geometry — its `(net-class …)` overlay on the board
/// base params, mirroring `router.setNetParams` so hand copper defaults to
/// exactly what the autorouter would have drawn on that net.
const McpNetGeom = struct { width: f64, via_dia: f64, via_drill: f64 };

fn mcpNetGeom(placement: optimizer.Placement, ni: usize, rp: router.RouteParams) McpNetGeom {
    var g = McpNetGeom{ .width = rp.track_width, .via_dia = rp.via_dia, .via_drill = rp.via_drill };
    if (ni >= placement.rules.net.len) return g;
    const r = placement.rules.net[ni];
    if (r.width > 0) g.width = r.width;
    if (r.via_dia > 0) g.via_dia = r.via_dia;
    if (r.via_drill > 0) g.via_drill = r.via_drill;
    return g;
}

/// Parse one `points` array of `[x,y]` mm pairs. Null when it isn't an array of
/// 2-number arrays — malformed geometry must fail the request, never silently
/// drop a segment the agent believes it drew.
fn mcpParsePts(alloc: std.mem.Allocator, v: std.json.Value) ?[]const [2]f64 {
    if (v != .array) return null;
    var list: std.ArrayList([2]f64) = .empty;
    for (v.array.items) |p| {
        if (p != .array or p.array.items.len < 2) return null;
        list.append(alloc, .{ jsonNum(p.array.items[0]), jsonNum(p.array.items[1]) }) catch return null;
    }
    return list.toOwnedSlice(alloc) catch null;
}

/// Parse `add_tracks`' `tracks` argument. Absent → empty (vias-only is legal);
/// present but malformed in ANY member → null, so the handler rejects the whole
/// request rather than landing a partial route.
fn mcpParseAddTracks(alloc: std.mem.Allocator, args_val: ?std.json.Value) ?[]McpReqTrack {
    const av = args_val orelse return &.{};
    if (av != .object) return &.{};
    const v = av.object.get("tracks") orelse return &.{};
    if (v != .array) return null;
    var list: std.ArrayList(McpReqTrack) = .empty;
    for (v.array.items) |it| {
        if (it != .object) return null;
        const net_v = it.object.get("net") orelse return null;
        const layer_v = it.object.get("layer") orelse return null;
        const pts_v = it.object.get("points") orelse return null;
        if (net_v != .string or layer_v != .string) return null;
        const pts = mcpParsePts(alloc, pts_v) orelse return null;
        list.append(alloc, .{
            .net = net_v.string,
            .layer = layer_v.string,
            .pts = pts,
            .width = jsonNum(it.object.get("width")),
        }) catch return null;
    }
    return list.toOwnedSlice(alloc) catch null;
}

/// Parse `add_tracks`' optional `vias` argument, same all-or-nothing rule.
fn mcpParseAddVias(alloc: std.mem.Allocator, args_val: ?std.json.Value) ?[]McpReqVia {
    const av = args_val orelse return &.{};
    if (av != .object) return &.{};
    const v = av.object.get("vias") orelse return &.{};
    if (v != .array) return null;
    var list: std.ArrayList(McpReqVia) = .empty;
    for (v.array.items) |it| {
        if (it != .object) return null;
        const net_v = it.object.get("net") orelse return null;
        if (net_v != .string) return null;
        const xv = it.object.get("x") orelse return null;
        const yv = it.object.get("y") orelse return null;
        list.append(alloc, .{
            .net = net_v.string,
            .x = jsonNum(xv),
            .y = jsonNum(yv),
            .dia = jsonNum(it.object.get("dia")),
            .drill = jsonNum(it.object.get("drill")),
            .span = layout_layers.parseSpanArg(it.object.get("span")) orelse return null,
        }) catch return null;
    }
    return list.toOwnedSlice(alloc) catch null;
}

/// Validate every requested track/via against the design's nets + stackup and
/// lower them to persisted copper. Writes its own error and returns null on the
/// first unknown net / unknown layer / too-short polyline, so a bad request
/// never half-lands.
pub fn mcpBuildAddedCopper(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    placement: optimizer.Placement,
    rp: router.RouteParams,
    reqs: []const McpReqTrack,
    vreqs: []const McpReqVia,
) HandlerError!?SavedRoutes {
    var tracks: std.ArrayList(SavedTrack) = .empty;
    var vias: std.ArrayList(SavedVia) = .empty;
    for (reqs) |t| {
        const ni = netIndexByName(placement, t.net) orelse {
            _ = try mcpFailFmt(out, alloc, "unknown net \"{s}\" — no such net in this design", .{t.net});
            return null;
        };
        const layer = placement.rules.signalIndexOfName(t.layer) orelse {
            _ = try mcpFailFmt(out, alloc, "unknown copper layer \"{s}\" on net \"{s}\"", .{ t.layer, t.net });
            return null;
        };
        if (t.pts.len < 2) {
            _ = try mcpFailFmt(out, alloc, "track on net \"{s}\" needs at least 2 points", .{t.net});
            return null;
        }
        const g = mcpNetGeom(placement, @intCast(ni), rp);
        const w = if (t.width > 0) t.width else g.width;
        for (t.pts[1..], 0..) |p, i| {
            try tracks.append(alloc, .{
                .x1 = t.pts[i][0],
                .y1 = t.pts[i][1],
                .x2 = p[0],
                .y2 = p[1],
                .l = layer,
                .w = w,
                .net = t.net,
                .source = route_source_agent,
            });
        }
    }
    for (vreqs) |v| {
        const ni = netIndexByName(placement, v.net) orelse {
            _ = try mcpFailFmt(out, alloc, "unknown net \"{s}\" — no such net in this design", .{v.net});
            return null;
        };
        const g = mcpNetGeom(placement, @intCast(ni), rp);
        // An unknown span name rejects the whole request rather than silently
        // landing a through via where a blind one was asked for.
        var span: ?[2]u8 = null;
        if (v.span) |names| span = layout_layers.resolveSpan(placement.rules, names) orelse {
            _ = try mcpFailFmt(out, alloc, "unknown copper layer in the via span [\"{s}\",\"{s}\"] on net \"{s}\"", .{ names[0], names[1], v.net });
            return null;
        };
        try vias.append(alloc, .{
            .x = v.x,
            .y = v.y,
            .d = if (v.dia > 0) v.dia else g.via_dia,
            .drill = if (v.drill > 0) v.drill else g.via_drill,
            .net = v.net,
            .source = route_source_agent,
            .s = span,
        });
    }
    return .{ .tracks = try tracks.toOwnedSlice(alloc), .vias = try vias.toOwnedSlice(alloc) };
}

/// `add_tracks` — draw agent-authored copper onto the working layout: polylines
/// (and optional vias) APPENDED to the layout's persisted tracks/vias, then
/// DRC-checked and persisted. The write-side counterpart of `clear_routes`.
///
/// This is the seam that lets an agent finish a net the autorouter gave up on.
/// Every remedy the stuck-net diagnostics emit re-runs the AUTOROUTER, so when
/// they report `cdt_geometry_limit` ("no priority edit reopens it — move the
/// part or widen the channel") there was previously no tool that could put
/// copper down at all; hand routing existed only in the browser.
///
/// These additions receive the `agent` source tag, distinct from browser-drawn
/// `human` copper and native `autorouter` output. The result reports
/// post-edit `routed`/`total`/`open` from the shared
/// connectivity oracle, so a caller sees immediately whether its copper closed
/// the net instead of having to re-describe the board.
/// Fab-blocking DRC on the board as it stands BEFORE this edit — the number a
/// hand-drawn addition must not exceed to be kept. Geometry only, per
/// `drc.errorCount`: an open net is not a reason to undo copper.
fn mcpBaselineErrors(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    solved: SolvedRequest,
    working: ?SavedLayout,
    rp: router.RouteParams,
) usize {
    const w = working orelse return 0;
    const r = w.routes orelse return 0;
    const rr = restoreRoutes(alloc, r, solved.placement.nets) orelse return 0;
    return drc.errorCount(drc_rules.checkFilteredZones(alloc, project_dir, name, .{
        .placement = solved.placement,
        .routed = rr,
        .clearance = rp.clearance,
        .zones = solved.shown_zones.user,
    }));
}

fn landTransitCount(violations: []const drc.Violation) usize {
    return drc.countKind(violations, .land_transit);
}

fn landTransitCountForNet(violations: []const drc.Violation, net: i32) usize {
    var count: usize = 0;
    for (violations) |violation| {
        if (violation.kind == .land_transit and violation.who.net_a == net) count += 1;
    }
    return count;
}

fn danglingCountForNet(violations: []const drc.Violation, net: i32) usize {
    var count: usize = 0;
    for (violations) |violation| {
        if (violation.kind == .dangling_copper and violation.who.net_a == net) count += 1;
    }
    return count;
}

fn padBoxGap(a: router.PadObs, b: router.PadObs) f64 {
    const dx = @max(@max(a.x0 - b.x1, b.x0 - a.x1), 0);
    const dy = @max(@max(a.y0 - b.y1, b.y0 - a.y1), 0);
    return std.math.hypot(dx, dy);
}

fn trackHasLandTransit(track: router.Track, pads: []const router.PadObs) bool {
    for (pads) |pad| {
        if (pad.thru or pad.net != track.net or pad.layer != track.layer) continue;
        const land = land_transit.Land{ .x0 = pad.x0, .y0 = pad.y0, .x1 = pad.x1, .y1 = pad.y1, .poly = pad.poly };
        if (land_transit.segmentOffence(
            land,
            .{ track.x1, track.y1 },
            .{ track.x2, track.y2 },
            track.width / 2,
        ) != null) return true;
    }
    return false;
}

fn mcpCopperViolations(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    solved: SolvedRequest,
    routed: router.RouteResult,
    clearance: f64,
) []const drc.Violation {
    const filled = drc_rules.checkFilteredZones(alloc, project_dir, name, .{
        .placement = solved.placement,
        .routed = routed,
        .clearance = clearance,
        .zones = solved.shown_zones.user,
    });
    // Fab readiness also reports the raw, no-zone `dangling_copper` hygiene
    // findings. Include those exact track identities in the cleanup plan even
    // when a surrounding pour would suppress them in the fill-aware pass. The
    // acceptance gate below remains fill-honest and rejects any deletion that
    // loses a routed net, so this only closes the reporting/cleanup mismatch.
    const bare = drc_rules.apply(
        alloc,
        drc_rules.load(alloc, project_dir, name),
        drc_rules.checkGeometry(alloc, solved.placement, routed, clearance) catch &.{},
    );
    var combined: std.ArrayList(drc.Violation) = .empty;
    combined.appendSlice(alloc, filled) catch return filled;
    for (bare) |finding| {
        if (finding.kind != .dangling_copper or finding.who.track_a < 0) continue;
        var duplicate = false;
        for (filled) |existing| {
            if (existing.kind == .dangling_copper and existing.who.track_a == finding.who.track_a) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) combined.append(alloc, finding) catch return filled;
    }
    return combined.toOwnedSlice(alloc) catch filled;
}

const LandRepairEvaluation = struct {
    violations: []const drc.Violation,
    errors: usize,
    tally: fab_readiness.Tally,
};

/// The `dangling_copper` reading either side of one refused candidate, kept so
/// the tool can name what it declined to do instead of silently keeping the old
/// copper.
const LandRepairDangling = struct {
    before: usize,
    after: usize,

    fn growth(self: LandRepairDangling) usize {
        return self.after - self.before;
    }
};

const LandRepairBoard = struct {
    tracks: *std.ArrayList(router.Track),
    evaluation: LandRepairEvaluation,
    /// The worst dangling-copper growth any candidate for the net currently
    /// under repair was refused for, or null when nothing was refused for that
    /// reason. `repairLandTransitNet` clears it before each net.
    dangling_refusal: ?LandRepairDangling = null,
};

/// One net whose repair the dangling-copper clause turned down, as the tool
/// reports it.
const LandRepairRefusal = struct {
    net: []const u8,
    dangling: LandRepairDangling,
};

const LandRepairNetResult = struct {
    changed: bool = false,
    rejected: bool = false,
    segments_reanchored: usize = 0,
    tracks_pruned: usize = 0,
    dangling_refusal: ?LandRepairDangling = null,
};

const LandRepairContext = struct {
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    solved: SolvedRequest,
    restored: router.RouteResult,
    pads: []const router.PadObs,
    clearance: f64,
    selected: []bool,
};

fn evaluateLandRepair(
    ctx: LandRepairContext,
    tracks: []const router.Track,
) std.mem.Allocator.Error!LandRepairEvaluation {
    var candidate = ctx.restored;
    candidate.tracks = tracks;
    const violations = mcpCopperViolations(ctx.alloc, ctx.project_dir, ctx.name, ctx.solved, candidate, ctx.clearance);
    return .{
        .violations = violations,
        .errors = drc.errorCount(violations),
        .tally = try fab_readiness.routableTally(ctx.alloc, ctx.solved.placement, .{
            .tracks = candidate.tracks,
            .vias = candidate.vias,
            .zones = ctx.solved.shown_zones.user,
        }),
    };
}

/// How much `dangling_copper` this candidate ADDS to one net, or null when it
/// adds none.
///
/// `land_transit.anchorSegment` rewrites an offending segment into
/// `a → p → centre → q → b` and keeps both original endpoints, so nothing is
/// torn off — but where the neighbouring copper already lapped the land, the
/// detour through the centre duplicates a path the pad itself was already
/// providing, and every piece of that loop becomes a deletion-invariant
/// section. On examples/blinky-breakout the whole-board pass turned 5
/// `land_transit` findings into 13 `dangling_copper` ones that way and called
/// it a success, because both kinds are warn-severity and the gate counted only
/// errors. A repair that spends more copper hygiene than it buys is not a
/// repair.
fn landRepairDanglingGrowth(
    candidate: LandRepairEvaluation,
    baseline: LandRepairEvaluation,
    net: i32,
) ?LandRepairDangling {
    const reading = LandRepairDangling{
        .before = danglingCountForNet(baseline.violations, net),
        .after = danglingCountForNet(candidate.violations, net),
    };
    return if (reading.after > reading.before) reading else null;
}

fn landRepairSafe(candidate: LandRepairEvaluation, baseline: LandRepairEvaluation, net: i32) bool {
    return candidate.errors <= baseline.errors and candidate.tally.routed >= baseline.tally.routed and
        candidate.tally.total == baseline.tally.total and
        landRepairDanglingGrowth(candidate, baseline, net) == null;
}

/// Record why a candidate for `net` was turned down, when the reason was the
/// dangling-copper clause. Keeps the largest growth seen, so the reported
/// before/after is the worst thing the tool declined to persist.
fn noteLandRepairRefusal(board: *LandRepairBoard, candidate: LandRepairEvaluation, net: i32) void {
    const grown = landRepairDanglingGrowth(candidate, board.evaluation, net) orelse return;
    if (board.dangling_refusal) |seen| {
        if (grown.growth() <= seen.growth()) return;
    }
    board.dangling_refusal = grown;
}

fn landRepairReduced(candidate: LandRepairEvaluation, baseline: LandRepairEvaluation, net: i32) bool {
    return landTransitCountForNet(candidate.violations, net) < landTransitCountForNet(baseline.violations, net);
}

fn pruneLandTransitTracks(
    ctx: LandRepairContext,
    net: i32,
    board: *LandRepairBoard,
) std.mem.Allocator.Error!usize {
    var pruned: usize = 0;
    var track_i: usize = 0;
    while (track_i < board.tracks.items.len) {
        const track = board.tracks.items[track_i];
        if (track.net != net or !trackHasLandTransit(track, ctx.pads)) {
            track_i += 1;
            continue;
        }
        const snapshot = try ctx.alloc.dupe(router.Track, board.tracks.items);
        _ = board.tracks.orderedRemove(track_i);
        const candidate = try evaluateLandRepair(ctx, board.tracks.items);
        if (landRepairReduced(candidate, board.evaluation, net) and landRepairSafe(candidate, board.evaluation, net)) {
            board.evaluation = candidate;
            pruned += 1;
        } else {
            noteLandRepairRefusal(board, candidate, net);
            board.tracks.* = std.ArrayList(router.Track).fromOwnedSlice(snapshot);
            track_i += 1;
        }
    }
    return pruned;
}

fn tryWholeLandTransitRepair(
    ctx: LandRepairContext,
    net_i: usize,
    board: *LandRepairBoard,
) std.mem.Allocator.Error!?usize {
    const net: i32 = @intCast(net_i);
    const snapshot = try ctx.alloc.dupe(router.Track, board.tracks.items);
    ctx.selected[net_i] = true;
    const snapped = route_cleanup.snapLandTransitEndpoints(ctx.pads, board.tracks, ctx.selected);
    ctx.selected[net_i] = false;
    var candidate = try evaluateLandRepair(ctx, board.tracks.items);
    if (landTransitCountForNet(candidate.violations, net) == 0 and landRepairSafe(candidate, board.evaluation, net)) {
        board.evaluation = candidate;
        return snapped.segments_reanchored;
    }

    noteLandRepairRefusal(board, candidate, net);
    board.tracks.* = std.ArrayList(router.Track).fromOwnedSlice(snapshot);
    const second_snapshot = try ctx.alloc.dupe(router.Track, board.tracks.items);
    ctx.selected[net_i] = true;
    const repaired = try route_cleanup.reanchorLandTransit(ctx.alloc, ctx.pads, board.tracks, ctx.selected);
    ctx.selected[net_i] = false;
    candidate = try evaluateLandRepair(ctx, board.tracks.items);
    if (landTransitCountForNet(candidate.violations, net) == 0 and landRepairSafe(candidate, board.evaluation, net)) {
        board.evaluation = candidate;
        return repaired.segments_reanchored;
    }
    noteLandRepairRefusal(board, candidate, net);
    board.tracks.* = std.ArrayList(router.Track).fromOwnedSlice(second_snapshot);
    return null;
}

fn repairLandTransitByPad(
    ctx: LandRepairContext,
    net_i: usize,
    board: *LandRepairBoard,
) std.mem.Allocator.Error!usize {
    const net: i32 = @intCast(net_i);
    var segments: usize = 0;
    var round: usize = 0;
    var progressed = true;
    while (progressed and round < 3) : (round += 1) {
        progressed = false;
        for (ctx.pads, 0..) |pad, pad_i| {
            if (pad.net != net or pad.thru) continue;
            const snapshot = try ctx.alloc.dupe(router.Track, board.tracks.items);
            ctx.selected[net_i] = true;
            const repaired = try route_cleanup.reanchorLandTransit(ctx.alloc, ctx.pads[pad_i .. pad_i + 1], board.tracks, ctx.selected);
            ctx.selected[net_i] = false;
            if (repaired.segments_reanchored == 0) continue;
            const candidate = try evaluateLandRepair(ctx, board.tracks.items);
            if (landRepairReduced(candidate, board.evaluation, net) and landRepairSafe(candidate, board.evaluation, net)) {
                board.evaluation = candidate;
                segments += repaired.segments_reanchored;
                progressed = true;
            } else {
                noteLandRepairRefusal(board, candidate, net);
                board.tracks.* = std.ArrayList(router.Track).fromOwnedSlice(snapshot);
            }
        }
    }
    return segments;
}

fn repairLandTransitByPair(
    ctx: LandRepairContext,
    net_i: usize,
    board: *LandRepairBoard,
) std.mem.Allocator.Error!usize {
    const net: i32 = @intCast(net_i);
    var segments: usize = 0;
    for (ctx.pads, 0..) |first_pad, first_i| {
        if (first_pad.net != net or first_pad.thru) continue;
        for (ctx.pads[first_i + 1 ..]) |second_pad| {
            const compatible = second_pad.net == net and !second_pad.thru and second_pad.layer == first_pad.layer;
            if (!compatible or padBoxGap(first_pad, second_pad) > 0.25) continue;
            const snapshot = try ctx.alloc.dupe(router.Track, board.tracks.items);
            ctx.selected[net_i] = true;
            const repaired = try route_cleanup.reanchorLandPair(ctx.alloc, .{ first_pad, second_pad }, board.tracks, ctx.selected);
            ctx.selected[net_i] = false;
            if (repaired.segments_reanchored == 0) continue;
            const candidate = try evaluateLandRepair(ctx, board.tracks.items);
            if (landRepairReduced(candidate, board.evaluation, net) and landRepairSafe(candidate, board.evaluation, net)) {
                board.evaluation = candidate;
                segments += repaired.segments_reanchored;
            } else {
                noteLandRepairRefusal(board, candidate, net);
                board.tracks.* = std.ArrayList(router.Track).fromOwnedSlice(snapshot);
            }
        }
    }
    return segments;
}

fn repairLandTransitNet(
    ctx: LandRepairContext,
    net_i: usize,
    board: *LandRepairBoard,
) std.mem.Allocator.Error!LandRepairNetResult {
    const net: i32 = @intCast(net_i);
    var result = LandRepairNetResult{};
    board.dangling_refusal = null;
    result.tracks_pruned = try pruneLandTransitTracks(ctx, net, board);
    result.changed = result.tracks_pruned > 0;
    if (landTransitCountForNet(board.evaluation.violations, net) == 0) return result;

    if (try tryWholeLandTransitRepair(ctx, net_i, board)) |count| {
        result.changed = true;
        result.segments_reanchored += count;
        return result;
    }
    result.segments_reanchored += try repairLandTransitByPad(ctx, net_i, board);
    result.segments_reanchored += try repairLandTransitByPair(ctx, net_i, board);
    result.changed = result.changed or result.segments_reanchored > 0;
    result.rejected = landTransitCountForNet(board.evaluation.violations, net) > 0;
    // A refusal exists to explain copper the tool KEPT, so it is reported only
    // while the finding the refused candidate would have removed is still on
    // the board. A net some other candidate went on to clean needs no excuse.
    if (result.rejected) result.dangling_refusal = board.dangling_refusal;
    return result;
}

/// The outcome of the trace-deletion phase of `clean_route_topology`: the
/// last candidate attempted, its full-board evidence, and the nets the retry
/// had to withhold from the plan.
const TracePhase = struct {
    candidate: router.RouteResult,
    violations: []const drc.Violation,
    tally: fab_readiness.Tally,
    safe: bool,
    rounds: usize,
    stub_tracks_removed: usize,
    nets_excluded: []const []const u8,
};

/// Run the trace-deletion phase, retried PER NET. The redundancy plan is
/// advisory and the gate is the authority, and on real hand-edited boards
/// they disagree: the topology graph credits a connection net_open's
/// fabricated-copper raster does not, so deleting that net's
/// "deletion-invariant" sections opens it (board-a, 2026-08: three such
/// nets vetoed a 152-section cleanup outright), and a section can carry a
/// decoupling cap's same-face bypass leg the net graph never modelled. One
/// unsound net must not hold every other net's junk hostage: each refused
/// attempt excludes exactly the nets the gate's own evidence names — newly
/// open in the tally, or with a grown bypass_open count — and tries again
/// without them; their sections stay on the board and stay reported. Any
/// other regression (a new error-severity finding, a changed net total)
/// still refuses the whole phase, as before.
/// Everything the trace phase judges against: the board as restored, the
/// full-board evidence taken before any deletion, and the caller's net scope.
const TraceIn = struct {
    project_dir: []const u8,
    name: []const u8,
    solved: SolvedRequest,
    restored: router.RouteResult,
    before_violations: []const drc.Violation,
    before_tally: fab_readiness.Tally,
    selected: []const bool,
    clearance: f64,
};

fn cleanupTracePhase(alloc: std.mem.Allocator, in: TraceIn) HandlerError!TracePhase {
    var out = TracePhase{
        .candidate = in.restored,
        .violations = in.before_violations,
        .tally = in.before_tally,
        .safe = false,
        .rounds = 0,
        .stub_tracks_removed = 0,
        .nets_excluded = &.{},
    };
    var excluded: std.ArrayList([]const u8) = .empty;
    var scope: []const bool = in.selected;
    const round_limit = in.restored.tracks.len + 1;
    const retry_limit = 8;
    var retries: usize = 0;
    while (retries < retry_limit) : (retries += 1) {
        out.candidate = in.restored;
        out.violations = in.before_violations;
        out.rounds = 0;
        out.stub_tracks_removed = 0;
        while (out.rounds < round_limit) : (out.rounds += 1) {
            const applied = try route_cleanup_gate.applyTrackPlan(alloc, out.candidate, out.violations, scope);
            out.stub_tracks_removed += applied.stub_tracks_removed;
            if (applied.routed.tracks.len == out.candidate.tracks.len) break;
            out.candidate = applied.routed;
            out.violations = mcpCopperViolations(alloc, in.project_dir, in.name, in.solved, out.candidate, in.clearance);
        }
        out.tally = try fab_readiness.routableTally(alloc, in.solved.placement, .{
            .tracks = out.candidate.tracks,
            .vias = out.candidate.vias,
            .zones = in.solved.shown_zones.user,
        });
        out.safe = route_cleanup_gate.gateSafe(in.before_violations, in.before_tally, out.violations, out.tally);
        if (out.safe) break;
        const opened = try route_cleanup_gate.newlyOpenNets(alloc, in.solved.placement.nets, in.before_tally.open, out.tally.open);
        const bypass_hit = try route_cleanup_gate.bypassRegressedNets(alloc, in.solved.placement.nets.len, in.before_violations, out.violations);
        if (opened.len == 0 and bypass_hit.len == 0) break;
        var narrowed = try alloc.alloc(bool, in.solved.placement.nets.len);
        if (scope.len == 0) {
            @memset(narrowed, true);
        } else {
            @memcpy(narrowed, scope);
        }
        for ([2][]const usize{ opened, bypass_hit }) |offenders| {
            for (offenders) |net_i| {
                if (!narrowed[net_i]) continue;
                narrowed[net_i] = false;
                try excluded.append(alloc, in.solved.placement.nets[net_i].name);
            }
        }
        scope = narrowed;
    }
    out.nets_excluded = try excluded.toOwnedSlice(alloc);
    return out;
}

/// Apply or preview the exact jointly-safe redundant-section plan emitted by
/// fabricated-fill DRC, guarded by a second full DRC/connectivity comparison.
pub fn mcpCleanRouteTopology(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = mcpArgStr(args_val, "name") orelse return mcpFail(out, alloc, mcp_err_missing_name);
    const layout_arg = mcpArgStr(args_val, "layout");
    const dry_run = mcpArgBool(args_val, "dry_run");
    const requested_nets = mcpArgStrList(alloc, args_val, "nets");
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = solveForRequest(alloc, project_dir, name, .{ .layout = layout_arg }, &eval, &module_res) catch |e|
        return mcpFailFmt(out, alloc, mcp_err_resolve_layout, .{@errorName(e)});
    const working = mcpReadWorking(alloc, project_dir, name, layout_arg) orelse
        return mcpFail(out, alloc, "no saved layout to clean");
    const saved_routes = working.routes orelse return mcpFail(out, alloc, "saved layout has no copper to clean");
    const restored = restoreRoutes(alloc, saved_routes, solved.placement.nets) orelse
        return mcpFail(out, alloc, "could not restore saved copper");
    var selected: []const bool = &.{};
    if (requested_nets.len > 0) {
        const mask = try alloc.alloc(bool, solved.placement.nets.len);
        @memset(mask, false);
        var matched: usize = 0;
        for (solved.placement.nets, 0..) |net, net_i| {
            for (requested_nets) |wanted| {
                if (!std.ascii.eqlIgnoreCase(net.name, wanted) and
                    !std.ascii.eqlIgnoreCase(router.shortName(net.name), wanted)) continue;
                if (!mask[net_i]) matched += 1;
                mask[net_i] = true;
                break;
            }
        }
        if (matched == 0) return mcpFail(out, alloc, "nets scope matched no board net");
        selected = mask;
    }
    const rp = solved.placement.rules.design.routeParams();
    const before_violations = mcpCopperViolations(alloc, project_dir, name, solved, restored, rp.clearance);
    const before_tally = try fab_readiness.routableTally(alloc, solved.placement, .{
        .tracks = restored.tracks,
        .vias = restored.vias,
        .zones = solved.shown_zones.user,
    });
    var cleanup_candidates_before: usize = 0;
    for (before_violations) |violation| {
        if (violation.kind == .dangling_copper and violation.who.track_a >= 0)
            cleanup_candidates_before += 1;
    }
    // Trace and via cleanup are separately gated transactions. A stale trace
    // redundancy verdict must not prevent independently safe via pruning (and
    // vice versa): reject only the phase that regressed full-board DRC or fab
    // connectivity, then continue the next phase from the last accepted board.
    const trace = try cleanupTracePhase(alloc, .{
        .project_dir = project_dir,
        .name = name,
        .solved = solved,
        .restored = restored,
        .before_violations = before_violations,
        .before_tally = before_tally,
        .selected = selected,
        .clearance = rp.clearance,
    });
    const trace_candidate = trace.candidate;
    const trace_safe = trace.safe;
    const trace_attempted = trace_candidate.tracks.len < restored.tracks.len;
    var cleaned = if (trace_safe) trace_candidate else restored;
    const via_before_violations = if (trace_safe) trace.violations else before_violations;
    const via_before_tally = if (trace_safe) trace.tally else before_tally;
    const via_candidate = try route_cleanup_gate.applyViaPlan(
        alloc,
        solved.placement.nets,
        cleaned,
        via_before_violations,
        selected,
    );
    const via_attempted = via_candidate.vias.len < cleaned.vias.len;
    const via_violations = if (via_attempted)
        mcpCopperViolations(alloc, project_dir, name, solved, via_candidate, rp.clearance)
    else
        via_before_violations;
    const via_tally = if (via_attempted)
        try fab_readiness.routableTally(alloc, solved.placement, .{
            .tracks = via_candidate.tracks,
            .vias = via_candidate.vias,
            .zones = solved.shown_zones.user,
        })
    else
        via_before_tally;
    const via_safe = route_cleanup_gate.gateSafe(via_before_violations, via_before_tally, via_violations, via_tally);
    if (via_safe) cleaned = via_candidate;
    const after_violations = if (via_safe) via_violations else via_before_violations;
    const after_tally = if (via_safe) via_tally else via_before_tally;
    const tracks_rolled_back = trace_attempted and !trace_safe;
    const vias_rolled_back = via_attempted and !via_safe;
    const stub_tracks_removed = if (trace_safe) trace.stub_tracks_removed else 0;
    var candidate_error_kinds: std.ArrayList([]const u8) = .empty;
    var candidate_error_details: std.ArrayList([]const u8) = .empty;
    for (after_violations) |violation| {
        if (violation.severity == .err and violation.kind != .net_open) {
            try candidate_error_kinds.append(alloc, @tagName(violation.kind));
            if (violation.who.track_a >= 0 and @as(usize, @intCast(violation.who.track_a)) < cleaned.tracks.len) {
                const track = cleaned.tracks[@intCast(violation.who.track_a)];
                try candidate_error_details.append(alloc, try std.fmt.allocPrint(
                    alloc,
                    "{s} net {d}: ({d},{d}) to ({d},{d}) L{d} W{d}",
                    .{ @tagName(violation.kind), violation.who.net_a, track.x1, track.y1, track.x2, track.y2, track.layer, track.width },
                ));
            }
        }
    }
    const would_change = cleaned.tracks.len < restored.tracks.len or cleaned.vias.len < restored.vias.len;
    const changed = would_change and !dry_run;
    if (changed) {
        var persisted = try mcpSavedRoutesFrom(alloc, cleaned, solved.placement.nets, saved_routes);
        persisted.zones = saved_routes.zones;
        try mcpPersistWorking(alloc, project_dir, name, .{
            .name = working.name,
            .kind = kind_manual,
            .ts = 0,
            .score = working.score,
            .parts = working.parts,
            .routes = persisted,
            .outline = working.outline,
            .texts = working.texts,
            .dimensions = working.dimensions,
        }, false);
    }

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.print(mcp_ok_layout_fmt, .{serve_root.getLiveVersion(name)});
    try writeJsonStr(w, working.name);
    try w.print(
        ",\"redundant_before\":{d},\"redundant_after\":{d},\"tracks_removed\":{d}," ++
            "\"vias_removed\":{d},\"drc_errors_before\":{d},\"candidate_drc_errors\":{d}," ++
            "\"routed_before\":{d},\"candidate_routed\":{d},\"total_before\":{d}," ++
            "\"candidate_total\":{d},\"candidate_redundant\":{d},\"cleanup_rounds\":{d},\"stub_tracks_removed\":{d},\"dry_run\":{},\"would_change\":{},\"changed\":{},\"rolled_back\":{}," ++
            "\"tracks_rolled_back\":{},\"vias_rolled_back\":{},\"track_candidate_removed\":{d},\"via_candidate_removed\":{d}," ++
            "\"cleanup_candidates_before\":{d},\"candidate_open\":",
        .{
            drc.countKind(before_violations, .dangling_copper),
            drc.countKind(after_violations, .dangling_copper),
            restored.tracks.len - cleaned.tracks.len,
            restored.vias.len - cleaned.vias.len,
            drc.errorCount(before_violations),
            drc.errorCount(after_violations),
            before_tally.routed,
            after_tally.routed,
            before_tally.total,
            after_tally.total,
            drc.countKind(after_violations, .dangling_copper),
            trace.rounds,
            stub_tracks_removed,
            dry_run,
            would_change,
            changed,
            tracks_rolled_back or vias_rolled_back,
            tracks_rolled_back,
            vias_rolled_back,
            restored.tracks.len - trace_candidate.tracks.len,
            (if (trace_safe) trace_candidate.vias.len else restored.vias.len) - via_candidate.vias.len,
            cleanup_candidates_before,
        },
    );
    try mcpWriteStrArray(w, after_tally.open);
    try w.writeAll(",\"trace_nets_excluded\":");
    try mcpWriteStrArray(w, trace.nets_excluded);
    try w.writeAll(",\"candidate_error_kinds\":");
    try mcpWriteStrArray(w, candidate_error_kinds.items);
    try w.writeAll(",\"candidate_error_details\":");
    try mcpWriteStrArray(w, candidate_error_details.items);
    try w.writeAll("}");
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// Turn weak same-net trace/trace and trace/via overlaps in persisted copper
/// into exact centreline joins. This is deliberately opt-in: unlike the
/// autorouter's generated-copper pass, every selected saved track is mutable.
/// The candidate is committed only when connectivity and error DRC do not
/// regress, and dry-run exercises the identical candidate and gate.
pub fn mcpNormalizeJunctions(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = mcpArgStr(args_val, "name") orelse return mcpFail(out, alloc, mcp_err_missing_name);
    const layout_arg = mcpArgStr(args_val, "layout");
    const dry_run = mcpArgBool(args_val, "dry_run");
    const requested_nets = mcpArgStrList(alloc, args_val, "nets");
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = solveForRequest(alloc, project_dir, name, .{ .layout = layout_arg }, &eval, &module_res) catch |e|
        return mcpFailFmt(out, alloc, mcp_err_resolve_layout, .{@errorName(e)});
    const working = mcpReadWorking(alloc, project_dir, name, layout_arg) orelse
        return mcpFail(out, alloc, "no saved layout to normalize");
    const saved_routes = working.routes orelse return mcpFail(out, alloc, "saved layout has no copper to normalize");
    const restored = restoreRoutes(alloc, saved_routes, solved.placement.nets) orelse
        return mcpFail(out, alloc, "could not restore saved copper");

    var selected: []const bool = &.{};
    if (requested_nets.len > 0) {
        const mask = try alloc.alloc(bool, solved.placement.nets.len);
        @memset(mask, false);
        var matched: usize = 0;
        for (solved.placement.nets, 0..) |net, net_i| {
            for (requested_nets) |wanted| {
                if (!std.ascii.eqlIgnoreCase(net.name, wanted) and
                    !std.ascii.eqlIgnoreCase(router.shortName(net.name), wanted)) continue;
                if (!mask[net_i]) matched += 1;
                mask[net_i] = true;
                break;
            }
        }
        if (matched == 0) return mcpFail(out, alloc, "nets scope matched no board net");
        selected = mask;
    }

    const rp = solved.placement.rules.design.routeParams();
    const before_violations = mcpCopperViolations(alloc, project_dir, name, solved, restored, rp.clearance);
    const before_tally = try fab_readiness.routableTally(alloc, solved.placement, .{
        .tracks = restored.tracks,
        .vias = restored.vias,
        .zones = solved.shown_zones.user,
    });
    var tracks: std.ArrayList(router.Track) = .empty;
    try tracks.appendSlice(alloc, restored.tracks);
    var mutable: std.ArrayList(bool) = .empty;
    for (restored.tracks) |track| {
        const selected_track = track.net >= 0 and (selected.len == 0 or
            (@as(usize, @intCast(track.net)) < selected.len and selected[@intCast(track.net)]));
        try mutable.append(alloc, selected_track);
    }
    try router.canonicalizeTraceJunctions(alloc, &tracks, &mutable, restored.vias);
    var candidate = restored;
    candidate.tracks = try tracks.toOwnedSlice(alloc);
    const after_violations = mcpCopperViolations(alloc, project_dir, name, solved, candidate, rp.clearance);
    const after_tally = try fab_readiness.routableTally(alloc, solved.placement, .{
        .tracks = candidate.tracks,
        .vias = candidate.vias,
        .zones = solved.shown_zones.user,
    });
    const safe = drc.errorCount(after_violations) <= drc.errorCount(before_violations) and
        after_tally.routed >= before_tally.routed and after_tally.total == before_tally.total;
    const would_change = safe and candidate.tracks.len != restored.tracks.len;
    const changed = would_change and !dry_run;
    if (changed) {
        var persisted = try mcpSavedRoutesFrom(alloc, candidate, solved.placement.nets, saved_routes);
        persisted.zones = saved_routes.zones;
        try mcpPersistWorking(alloc, project_dir, name, .{
            .name = working.name,
            .kind = kind_manual,
            .ts = 0,
            .score = working.score,
            .parts = working.parts,
            .routes = persisted,
            .outline = working.outline,
            .texts = working.texts,
            .dimensions = working.dimensions,
        }, false);
    }

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.print(mcp_ok_layout_fmt, .{serve_root.getLiveVersion(name)});
    try writeJsonStr(w, working.name);
    try w.print(
        ",\"implicit_before\":{d},\"implicit_after\":{d},\"tracks_added\":{d}," ++
            "\"routed_before\":{d},\"candidate_routed\":{d},\"total\":{d}," ++
            "\"dry_run\":{},\"would_change\":{},\"changed\":{},\"rolled_back\":{}}}",
        .{
            drc.countKind(before_violations, .implicit_junction),
            drc.countKind(after_violations, .implicit_junction),
            candidate.tracks.len - restored.tracks.len,
            before_tally.routed,
            after_tally.routed,
            after_tally.total,
            dry_run,
            would_change,
            changed,
            !safe,
        },
    );
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// HTTP twin of `normalize_junctions`. The path supplies the design name; the
/// JSON body accepts the same optional layout, dry_run, and nets fields as the
/// CLI action so browser tooling and agents exercise one implementation.
pub fn normalizeJunctionsApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = nameParam(req, res) orelse return;
    var root = parseJsonObject(req, res) orelse return;
    root.object.put(req.arena, "name", .{ .string = name }) catch {
        res.status = 500;
        res.body = "could not prepare normalization request";
        return;
    };
    var out: std.ArrayList(u8) = .empty;
    const ok = try mcpNormalizeJunctions(req.arena, ctx.project_dir, root, &out);
    res.content_type = .JSON;
    res.body = out.items;
    if (!ok) res.status = 400;
}

/// Repair persisted same-net copper that laps an SMD land instead of entering
/// it through the pad centre. Each affected net is an independent transaction:
/// the rewrite is kept only when it removes every land-transit finding on that
/// net, does not increase error-severity DRC, does not lose a connected net,
/// and does not grow that net's `dangling_copper` count. That last clause is
/// what stops the tool trading one warning for three: both kinds are
/// warn-severity, so an error-only gate scored a centre-detour that duplicated
/// the pad's own connection as an improvement. A net refused for it is named in
/// `refused` with its before/after dangling reading, rather than the old copper
/// being kept without a word.
pub fn mcpRepairLandTransit(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = mcpArgStr(args_val, "name") orelse return mcpFail(out, alloc, mcp_err_missing_name);
    const layout_arg = mcpArgStr(args_val, "layout");
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = solveForRequest(alloc, project_dir, name, .{ .layout = layout_arg }, &eval, &module_res) catch |e|
        return mcpFailFmt(out, alloc, mcp_err_resolve_layout, .{@errorName(e)});
    const placement = solved.placement;
    const working = mcpReadWorking(alloc, project_dir, name, layout_arg) orelse
        return mcpFail(out, alloc, "no saved layout to repair");
    const saved_routes = working.routes orelse return mcpFail(out, alloc, "saved layout has no copper to repair");
    const restored = restoreRoutes(alloc, saved_routes, placement.nets) orelse
        return mcpFail(out, alloc, "could not restore saved copper");
    const rp = placement.rules.design.routeParams();
    const pads = try router.buildObstacles(alloc, placement.parts, placement.nets);
    var tracks = std.ArrayList(router.Track).fromOwnedSlice(try alloc.dupe(router.Track, restored.tracks));
    const selected = try alloc.alloc(bool, placement.nets.len);
    @memset(selected, false);
    const touched = try alloc.alloc(bool, placement.nets.len);
    @memset(touched, false);
    const repair_ctx = LandRepairContext{
        .alloc = alloc,
        .project_dir = project_dir,
        .name = name,
        .solved = solved,
        .restored = restored,
        .pads = pads,
        .clearance = rp.clearance,
        .selected = selected,
    };

    var board = LandRepairBoard{
        .tracks = &tracks,
        .evaluation = try evaluateLandRepair(repair_ctx, tracks.items),
    };
    const warnings_before = landTransitCount(board.evaluation.violations);
    const routed_before = board.evaluation.tally.routed;
    const tracks_before = tracks.items.len;
    var accepted: std.ArrayList([]const u8) = .empty;
    var rejected: std.ArrayList([]const u8) = .empty;
    var refused: std.ArrayList(LandRepairRefusal) = .empty;
    var segments_reanchored: usize = 0;
    var tracks_pruned: usize = 0;

    for (placement.nets, 0..) |net, net_i| {
        const ni: i32 = @intCast(net_i);
        if (landTransitCountForNet(board.evaluation.violations, ni) == 0) continue;
        const result = try repairLandTransitNet(repair_ctx, net_i, &board);
        if (result.changed) {
            touched[net_i] = true;
            segments_reanchored += result.segments_reanchored;
            tracks_pruned += result.tracks_pruned;
            try accepted.append(alloc, net.name);
        }
        if (result.rejected) try rejected.append(alloc, net.name);
        if (result.dangling_refusal) |reading|
            try refused.append(alloc, .{ .net = net.name, .dangling = reading });
    }

    var current = restored;
    var kept_arcs: std.ArrayList(router.Arc) = .empty;
    for (restored.arcs) |arc| {
        if (arc.net >= 0 and @as(usize, @intCast(arc.net)) < touched.len and touched[@intCast(arc.net)]) continue;
        try kept_arcs.append(alloc, arc);
    }
    var kept_outcomes: std.ArrayList(rf_port_report.Outcome) = .empty;
    for (restored.rf_port_outcomes) |outcome| {
        if (outcome.net >= 0 and @as(usize, @intCast(outcome.net)) < touched.len and touched[@intCast(outcome.net)]) continue;
        try kept_outcomes.append(alloc, outcome);
    }
    current.tracks = board.tracks.items;
    current.arcs = kept_arcs.items;
    current.rf_port_outcomes = kept_outcomes.items;
    var persisted = try mcpSavedRoutesFrom(alloc, current, placement.nets, saved_routes);
    persisted.zones = saved_routes.zones;
    if (accepted.items.len > 0) {
        const entry = SavedLayout{
            .name = working.name,
            .kind = kind_manual,
            .ts = 0,
            .score = working.score,
            .parts = working.parts,
            .routes = persisted,
            .outline = working.outline,
            .texts = working.texts,
            .dimensions = working.dimensions,
        };
        try mcpPersistWorking(alloc, project_dir, name, entry, false);
    }

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.print(mcp_ok_layout_fmt, .{serve_root.getLiveVersion(name)});
    try writeJsonStr(w, working.name);
    try w.print(
        ",\"warnings_before\":{d},\"warnings_after\":{d},\"segments_reanchored\":{d},\"tracks_pruned\":{d}," ++
            "\"tracks_before\":{d},\"tracks_after\":{d},\"drc_errors\":{d},\"routed_before\":{d}," ++
            "\"routed\":{d},\"total\":{d},\"accepted\":",
        .{
            warnings_before,
            landTransitCount(board.evaluation.violations),
            segments_reanchored,
            tracks_pruned,
            tracks_before,
            board.tracks.items.len,
            board.evaluation.errors,
            routed_before,
            board.evaluation.tally.routed,
            board.evaluation.tally.total,
        },
    );
    try mcpWriteStrArray(w, accepted.items);
    try w.writeAll(",\"rejected\":");
    try mcpWriteStrArray(w, rejected.items);
    try w.writeAll(",\"refused\":[");
    for (refused.items, 0..) |entry, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"net\":");
        try writeJsonStr(w, entry.net);
        try w.print(
            ",\"dangling_before\":{d},\"dangling_after\":{d}}}",
            .{ entry.dangling.before, entry.dangling.after },
        );
    }
    try w.writeAll("]}");
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// Add the ground-plane barrels required by the board's authored
/// `(ground-via-max MM)` rule to an existing saved layout. The same router
/// post-pass runs automatically on fresh whole-board routes; this mutation is
/// the safe upgrade path for a hand-finished layout that must not be rerouted.
pub fn mcpStitchGroundPads(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = mcpArgStr(args_val, "name") orelse return mcpFail(out, alloc, mcp_err_missing_name);
    const layout_arg = mcpArgStr(args_val, "layout");
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = solveForRequest(alloc, project_dir, name, .{ .layout = layout_arg }, &eval, &module_res) catch |e|
        return mcpFailFmt(out, alloc, mcp_err_resolve_layout, .{@errorName(e)});
    const placement = solved.placement;
    const max_distance = placement.rules.design.pour.ground_via_max;
    if (!(max_distance > 0)) return mcpFail(out, alloc, "design has no positive (ground-via-max MM) rule");
    const working = mcpReadWorking(alloc, project_dir, name, layout_arg) orelse
        return mcpFail(out, alloc, "no saved layout to stitch");
    const saved_routes = working.routes orelse return mcpFail(out, alloc, "saved layout has no copper to stitch");
    const restored = restoreRoutes(alloc, saved_routes, placement.nets) orelse
        return mcpFail(out, alloc, "could not restore saved copper");
    const rp = placement.rules.design.routeParams();
    const before_violations = mcpCopperViolations(alloc, project_dir, name, solved, restored, rp.clearance);
    const before_tally = try fab_readiness.routableTally(alloc, placement, .{
        .tracks = restored.tracks,
        .vias = restored.vias,
        .zones = solved.shown_zones.user,
    });
    const candidate = try router.addGroundPadStitches(alloc, placement, restored);
    const after_violations = mcpCopperViolations(alloc, project_dir, name, solved, candidate, rp.clearance);
    const after_tally = try fab_readiness.routableTally(alloc, placement, .{
        .tracks = candidate.tracks,
        .vias = candidate.vias,
        .zones = solved.shown_zones.user,
    });
    const safe = drc.errorCount(after_violations) <= drc.errorCount(before_violations) and
        drc.countKind(after_violations, .ground_via_distance) <= drc.countKind(before_violations, .ground_via_distance) and
        after_tally.routed >= before_tally.routed and after_tally.total == before_tally.total;
    const changed = safe and (candidate.vias.len > restored.vias.len or candidate.tracks.len > restored.tracks.len);
    if (changed) {
        var persisted = try mcpSavedRoutesFrom(alloc, candidate, placement.nets, saved_routes);
        persisted.zones = saved_routes.zones;
        try mcpPersistWorking(alloc, project_dir, name, .{
            .name = working.name,
            .kind = kind_manual,
            .ts = 0,
            .score = working.score,
            .parts = working.parts,
            .routes = persisted,
            .outline = working.outline,
            .texts = working.texts,
            .dimensions = working.dimensions,
        }, false);
    }

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.print(mcp_ok_layout_fmt, .{serve_root.getLiveVersion(name)});
    try writeJsonStr(w, working.name);
    try w.print(
        ",\"max_distance_mm\":{d},\"warnings_before\":{d},\"warnings_after\":{d}," ++
            "\"vias_added\":{d},\"tracks_added\":{d},\"drc_errors\":{d}," ++
            "\"routed\":{d},\"total\":{d},\"changed\":{},\"rolled_back\":{}}}",
        .{
            max_distance,
            drc.countKind(before_violations, .ground_via_distance),
            drc.countKind(if (safe) after_violations else before_violations, .ground_via_distance),
            if (changed) candidate.vias.len - restored.vias.len else 0,
            if (changed) candidate.tracks.len - restored.tracks.len else 0,
            if (safe) drc.errorCount(after_violations) else drc.errorCount(before_violations),
            if (safe) after_tally.routed else before_tally.routed,
            before_tally.total,
            changed,
            !safe,
        },
    );
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// `add_tracks` — append hand-drawn copper to a design's layout.
///
/// The mutation counterpart of `clear_routes`, and the seam that breaks a
/// closed loop: when the autorouter reports a net it cannot close, this is how
/// an agent (or a human) lays the copper itself. Validation is all-or-nothing,
/// and copper that raises the error-severity DRC count is rolled back unless
/// the caller passes `"rollback_on_drc": false`.
pub fn mcpAddTracks(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) HandlerError!bool {
    const name = mcpArgStr(args_val, "name") orelse return mcpFail(out, alloc, mcp_err_missing_name);
    const layout_arg = mcpArgStr(args_val, "layout");
    const reqs = mcpParseAddTracks(alloc, args_val) orelse
        return mcpFail(out, alloc, "malformed \"tracks\" — each entry needs {\"net\",\"layer\",\"points\":[[x,y],…]}");
    const vreqs = mcpParseAddVias(alloc, args_val) orelse
        return mcpFail(out, alloc, "malformed \"vias\" — each entry needs {\"net\",\"x\",\"y\"}");
    if (reqs.len == 0 and vreqs.len == 0)
        return mcpFail(out, alloc, "nothing to add — supply \"tracks\" and/or \"vias\"");

    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = solveForRequest(alloc, project_dir, name, .{ .layout = layout_arg }, &eval, &module_res) catch |e|
        return mcpFailFmt(out, alloc, mcp_err_resolve_layout, .{@errorName(e)});
    const placement = solved.placement;
    const rp = placement.rules.design.routeParams();

    const added = (try mcpBuildAddedCopper(alloc, out, placement, rp, reqs, vreqs)) orelse return false;
    const working = mcpReadWorking(alloc, project_dir, name, layout_arg);
    // Additive: hand copper joins the layout's existing tracks/vias (and never
    // touches its custom pours, which mcpMergeRoutes carries over).
    const merged = try mcpMergeRoutes(alloc, if (working) |wl| wl.routes else null, added);

    // DRC + connectivity on exactly what gets persisted, so the reported
    // numbers describe the board the caller just changed.
    var candidate_findings: []const drc.Violation = &.{};
    var drc_count: usize = 0;
    var drc_errs: usize = 0;
    var tally = fab_readiness.Tally{};
    if (merged) |m| {
        if (restoreRoutes(alloc, m, placement.nets)) |rr| {
            const v = drc_rules.checkFilteredZones(alloc, project_dir, name, .{
                .placement = placement,
                .routed = rr,
                .clearance = rp.clearance,
                .zones = solved.shown_zones.user,
            });
            candidate_findings = v;
            drc_count = v.len;
            drc_errs = drc.errorCount(v);
            // Pours count as connecting copper — see ShownCopper.zones.
            tally = try fab_readiness.routableTally(alloc, placement, .{
                .tracks = rr.tracks,
                .vias = rr.vias,
                .arcs = rr.arcs,
                .rf_paths = rr.rf_port_outcomes,
                .zones = solved.shown_zones.user,
            });
        }
    }

    // Hand copper that makes the board WORSE is undone by default. There is no
    // per-edit undo otherwise — `clear_routes` is per-net, so reverting one bad
    // polyline means wiping every track on that net — which makes the
    // draw/measure/adjust loop an agent needs unsafe to iterate. Errors, not
    // warnings: a sharp-bend or diff-skew finding is not a reason to reject
    // good copper. Pass `"rollback_on_drc": false` to keep copper regardless.
    const rollback = mcpArgBoolOpt(args_val, "rollback_on_drc") orelse true;
    const before_errs = mcpBaselineErrors(alloc, project_dir, name, solved, working, rp);
    const rolled_back = rollback and drc_errs > before_errs;
    const entry_name = mcpWorkingName(alloc, project_dir, name, layout_arg);
    if (!rolled_back) {
        const entry = SavedLayout{
            .name = entry_name,
            .kind = kind_manual,
            .ts = 0,
            .score = if (working) |wl| wl.score else null,
            .parts = if (working) |wl| wl.parts else posesFromPlacement(alloc, placement) orelse &.{},
            .routes = merged,
            .outline = if (working) |wl| wl.outline else null,
            .texts = if (working) |wl| wl.texts else &.{},
            .dimensions = mcpWorkingDimensions(working),
        };
        try mcpPersistWorking(alloc, project_dir, name, entry, false);
    }

    const prior = solved.restored.routes;
    const committed_tally = if (rolled_back)
        try route_copper_state.tally(alloc, placement, prior, solved.shown_zones.user)
    else
        tally;
    const committed_findings = if (rolled_back) drc_rules.checkFilteredZones(alloc, project_dir, name, .{
        .placement = placement,
        .routed = prior orelse .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 },
        .clearance = rp.clearance,
        .zones = solved.shown_zones.user,
    }) else candidate_findings;

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.print(mcp_ok_layout_fmt, .{serve_root.getLiveVersion(name)});
    try writeJsonStr(w, entry_name);
    // `drc` is every violation; `drc_errors` is the fab-blocking subset. A
    // caller deciding whether to keep hand copper should gate on the ERROR
    // count — a sharp-bend or diff-skew warning is not a reason to roll back.
    try w.print(
        ",\"added_tracks\":{d},\"added_vias\":{d},\"drc\":{d},\"drc_errors\":{d},\"drc_errors_before\":{d},\"rolled_back\":{},\"routed\":{d},\"total\":{d},\"open\":",
        .{ if (rolled_back) @as(usize, 0) else added.tracks.len, if (rolled_back) @as(usize, 0) else added.vias.len, committed_findings.len, drc.errorCount(committed_findings), before_errs, rolled_back, committed_tally.routed, committed_tally.total },
    );
    try mcpWriteStrArray(w, committed_tally.open);
    try w.print(",\"applied\":{},\"candidate\":{{\"added_tracks\":{d},\"added_vias\":{d},\"drc\":{d},\"drc_errors\":{d},\"routed\":{d},\"total\":{d},\"open\":", .{
        !rolled_back, added.tracks.len, added.vias.len, drc_count, drc_errs, tally.routed, tally.total,
    });
    try mcpWriteStrArray(w, tally.open);
    try w.writeAll(",\"drc_list\":");
    try route_result_stats.writeFindings(w, candidate_findings, .{ .nets = placement.nets, .parts = placement.parts });
    try w.writeAll("}");
    try w.writeAll("}");
    try out.appendSlice(alloc, aw.written());
    return true;
}

// spec: Web Server - A CLI layout mutation snapshots the sidecar to history and bumps the rev like a viewer Save
test "CLI persist bumps the sidecar rev and snapshots history" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/foo.layouts.json", .data = "{\"layouts\":[]}" });

    // Two CLI persists: each stamps disk rev + 1 (0→1→2), so an open editor
    // tab holding the old rev 409s on its next save instead of clobbering.
    const parts = [_]PartPose{.{ .ref = "U1", .x = 1, .y = 2, .rot = 0 }};
    const entry = SavedLayout{ .name = "layout", .kind = kind_manual, .ts = 1, .score = null, .parts = &parts, .default = true };
    try mcpPersistWorking(alloc, project, "foo", entry, true);
    try std.testing.expectEqual(@as(i64, 1), readLayoutRev(alloc, project, "foo", null));
    try mcpPersistWorking(alloc, project, "foo", entry, true);
    try std.testing.expectEqual(@as(i64, 2), readLayoutRev(alloc, project, "foo", null));

    // The pre-write sidecar landed in history/ (recoverable like a viewer Save).
    const snaps = try history.listLayoutSnapshots(alloc, project, "foo");
    try std.testing.expect(snaps.len >= 1);
}

// spec: Web Server - A CLI layout mutation refreshes the auto-layout cache poses so a default read reflects the write
test "CLI persist refreshes the auto cache poses so a default read sees the mutation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try tmp.dir.createDirPath(std.testing.io, "src");

    // A sidecar whose optimizer-cache slot holds a STALE pose (an earlier solve)
    // and a tuning weight. This cache is the scene a default CLI read renders —
    // `get_pcb_layout_image` / `describe_pcb_layout` default `rough`, so
    // `solveForRequest` seeds from `readAutoPoses` (the cache), not the starred
    // layout.
    const stale = "{\"layouts\":[],\"cache\":{\"params\":{\"loop_w\":7.5}," ++
        "\"parts\":[{\"ref\":\"U1\",\"x\":0,\"y\":0,\"rot\":0}]}}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/foo.layouts.json", .data = stale });
    const before = readAutoPoses(alloc, project, "foo") orelse return error.TestNoCache;
    try std.testing.expectEqual(@as(usize, 1), before.len);
    try std.testing.expectEqual(@as(f64, 0), before[0].x);

    // A CLI mutation persists U1 at a distinctive new pose (as set_part_poses does).
    const parts = [_]PartPose{.{ .ref = "U1", .x = 42, .y = 7, .rot = 90 }};
    const entry = SavedLayout{ .name = "layout", .kind = kind_manual, .ts = 1, .score = null, .parts = &parts, .default = true };
    try mcpPersistWorking(alloc, project, "foo", entry, true);

    // Read-after-write: the cache the default read consults now carries the
    // mutation, not the pre-mutation pose (bug #2 would leave x at 0).
    const after = readAutoPoses(alloc, project, "foo") orelse return error.TestNoCache;
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqual(@as(f64, 42), after[0].x);
    try std.testing.expectEqual(@as(f64, 7), after[0].y);

    // Only the poses are swapped — the stored tuning weight survives the refresh.
    const slot = readCacheSlot(alloc, project, "foo") orelse return error.TestNoCache;
    try std.testing.expectEqual(@as(f64, 7.5), slot.params.loop_w);
}

// spec: Web Server - An unscoped route_pcb call immediately after clear_routes routes the whole board and echoes scope "all"
test "clear_routes group scope reports an unresolvable design instead of clearing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    // mcpClearGroupNames is the only clear path that evaluates the design, so a
    // name that resolves to nothing has to surface as an {ok:false} message
    // rather than as a silent empty scope that would clear the whole board.
    var out: std.ArrayList(u8) = .empty;
    const names = try mcpClearGroupNames(alloc, &out, project, "nope", &.{"power"});
    try std.testing.expect(names == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "could not resolve layout") != null);
}

test "mcp clear_routes then unscoped route_pcb routes the whole board" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try writeFabSelectionFixture(tmp.dir);

    const args = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"name\":\"fabsel\"}", .{});

    // Drop the ★ row's persisted copper (the fixture's three SIG tracks)…
    var cleared: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpClearRoutes(alloc, project, args, &cleared));
    try std.testing.expect(std.mem.indexOf(u8, cleared.items, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, cleared.items, "\"cleared\":3") != null);

    // …then immediately route with NO nets/groups — the sequence that used to
    // segfault the server. No scope means a whole-board route: both nets close
    // (SIG traced, GND by plane vias), echoed as scope "all", nothing unrouted.
    var routed: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpRoutePcb(alloc, project, args, &routed));
    try std.testing.expect(std.mem.indexOf(u8, routed.items, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, routed.items, "\"scope\":\"all\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, routed.items, "\"selected_only\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, routed.items, "\"routed\":2,\"total\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, routed.items, "\"unrouted\":[]") != null);
}

// spec: serve/mcp_tools - clean_route_topology removes deletion-invariant saved trace sections and recursively exposed loose stubs transactionally without rerouting the board
// spec: serve/mcp_tools - clean_route_topology supports a non-persisting dry run and an optional net-name scope
test "mcp clean_route_topology removes a saved branch and is idempotent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try writeFabSelectionFixture(tmp.dir);

    const add_args = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"name\":\"fabsel\",\"layout\":\"routed\",\"tracks\":[{\"net\":\"SIG\",\"layer\":\"F.Cu\",\"points\":[[4.52,3],[4.52,2]],\"width\":0.2}]," ++
            "\"vias\":[{\"net\":\"SIG\",\"x\":7,\"y\":3},{\"net\":\"GND\",\"x\":5.48,\"y\":5}]}",
        .{},
    );
    var added: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpAddTracks(alloc, project, add_args, &added));
    try std.testing.expect(std.mem.indexOf(u8, added.items, "\"added_tracks\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, added.items, "\"added_vias\":2") != null);

    // Dry-run computes the same jointly-safe plan but leaves the row untouched.
    const dry_args = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"name\":\"fabsel\",\"layout\":\"routed\",\"dry_run\":true,\"nets\":[\"SIG\"]}",
        .{},
    );
    var preview: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpCleanRouteTopology(alloc, project, dry_args, &preview));
    try std.testing.expect(std.mem.indexOf(u8, preview.items, "\"dry_run\":true,\"would_change\":true,\"changed\":false") != null);
    try std.testing.expectEqual(@as(usize, 4), mcpReadWorking(alloc, project, "fabsel", "routed").?.routes.?.tracks.len);
    try std.testing.expectEqual(@as(usize, 2), mcpReadWorking(alloc, project, "fabsel", "routed").?.routes.?.vias.len);

    const clean_args = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"name\":\"fabsel\",\"layout\":\"routed\"}",
        .{},
    );
    var first: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpCleanRouteTopology(alloc, project, clean_args, &first));
    try std.testing.expect(std.mem.indexOf(u8, first.items, "\"redundant_before\":1,\"redundant_after\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.items, "\"tracks_removed\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.items, "\"vias_removed\":1") != null);
    const first_json = try std.json.parseFromSliceLeaky(std.json.Value, alloc, first.items, .{});
    try std.testing.expectEqual(
        first_json.object.get("routed_before").?.integer,
        first_json.object.get("candidate_routed").?.integer,
    );
    try std.testing.expect(std.mem.indexOf(u8, first.items, "\"changed\":true,\"rolled_back\":false") != null);
    const persisted = mcpReadWorking(alloc, project, "fabsel", "routed").?.routes.?;
    try std.testing.expectEqual(@as(usize, 1), persisted.vias.len);
    try std.testing.expectEqualStrings("GND", persisted.vias[0].net);

    var second: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpCleanRouteTopology(alloc, project, clean_args, &second));
    try std.testing.expect(std.mem.indexOf(u8, second.items, "\"redundant_before\":0,\"redundant_after\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.items, "\"tracks_removed\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.items, "\"vias_removed\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.items, "\"changed\":false,\"rolled_back\":false") != null);
}

test "route topology cleanup includes newly exposed stubs and honors net scope" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 1 },
        .{ .x1 = 4, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const findings = [_]drc.Violation{
        .{ .x = 0.5, .y = 0, .gap = 0, .clearance = 0, .kind = .dangling_copper, .who = .{ .track_a = 0 } },
        .{ .x = 2.5, .y = 0, .gap = 0, .clearance = 0, .kind = .copper_stub, .who = .{ .track_a = 1 } },
        .{ .x = 4.5, .y = 0, .gap = 0, .clearance = 0, .kind = .copper_stub, .who = .{ .track_a = 2 } },
    };
    const applied = try route_cleanup_gate.applyTrackPlan(
        alloc,
        .{ .tracks = &tracks, .vias = &.{}, .routed = 2, .total = 2 },
        &findings,
        &.{ true, false },
    );

    try std.testing.expectEqual(@as(usize, 1), applied.routed.tracks.len);
    try std.testing.expectEqual(@as(i32, 1), applied.routed.tracks[0].net);
    try std.testing.expectEqual(@as(usize, 1), applied.stub_tracks_removed);
}

// spec: serve/mcp_tools - normalize_junctions CLI/HTTP actions explicitly repair saved implicit joins, support dry-run/net scope, and persist only a connectivity- and DRC-safe candidate
test "normalize_junctions dry-runs and repairs saved copper" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try writeFabSelectionFixture(tmp.dir);

    const add_args = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"name\":\"fabsel\",\"layout\":\"routed\",\"tracks\":[{\"net\":\"SIG\",\"layer\":\"F.Cu\",\"points\":[[7,2],[7,4]],\"width\":0.2}]}",
        .{},
    );
    var added: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpAddTracks(alloc, project, add_args, &added));

    const dry_args = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"name\":\"fabsel\",\"layout\":\"routed\",\"dry_run\":true,\"nets\":[\"SIG\"]}",
        .{},
    );
    var preview: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpNormalizeJunctions(alloc, project, dry_args, &preview));
    try std.testing.expect(std.mem.indexOf(u8, preview.items, "\"implicit_before\":1,\"implicit_after\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, preview.items, "\"dry_run\":true,\"would_change\":true,\"changed\":false") != null);
    try std.testing.expectEqual(@as(usize, 4), mcpReadWorking(alloc, project, "fabsel", "routed").?.routes.?.tracks.len);

    const apply_args = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"name\":\"fabsel\",\"layout\":\"routed\",\"nets\":[\"SIG\"]}",
        .{},
    );
    var normalized: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpNormalizeJunctions(alloc, project, apply_args, &normalized));
    try std.testing.expect(std.mem.indexOf(u8, normalized.items, "\"implicit_before\":1,\"implicit_after\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, normalized.items, "\"changed\":true,\"rolled_back\":false") != null);
    try std.testing.expectEqual(@as(usize, 5), mcpReadWorking(alloc, project, "fabsel", "routed").?.routes.?.tracks.len);
}

// spec: serve/mcp_tools - restore_layout_snapshot restores protected PCB layout history after snapshotting the current sidecar and bumping its revision
test "mcp restore_layout_snapshot round-trips a protected sidecar" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try writeFabSelectionFixture(tmp.dir);
    const sidecar = try std.fmt.allocPrint(alloc, "{s}/src/fabsel.layouts.json", .{project});
    const id = (try history.snapshotLayouts(alloc, project, "fabsel", sidecar)) orelse return error.TestExpectedEqual;

    const clear_args = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"name\":\"fabsel\",\"layout\":\"routed\"}", .{});
    var cleared: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpClearRoutes(alloc, project, clear_args, &cleared));
    try std.testing.expect(mcpReadWorking(alloc, project, "fabsel", "routed").?.routes == null);
    const rev_before = readLayoutRev(alloc, project, "fabsel", null);

    var args_text: std.Io.Writer.Allocating = .init(alloc);
    try args_text.writer.writeAll("{\"name\":\"fabsel\",\"id\":");
    try writeJsonStr(&args_text.writer, id);
    try args_text.writer.writeAll("}");
    const restore_args = try std.json.parseFromSliceLeaky(std.json.Value, alloc, args_text.written(), .{});
    var restored: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpRestoreLayoutSnapshot(alloc, project, restore_args, &restored));
    try std.testing.expectEqual(rev_before + 1, readLayoutRev(alloc, project, "fabsel", null));
    try std.testing.expectEqual(@as(usize, 3), mcpReadWorking(alloc, project, "fabsel", "routed").?.routes.?.tracks.len);
}

// spec: serve/mcp_tools - stitch_ground_pads applies the autorouter's final ground-reference pass transactionally to a saved layout
test "mcp stitch_ground_pads upgrades saved copper and is idempotent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try writeFabSelectionFixture(tmp.dir);

    const args = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"name\":\"fabsel\",\"layout\":\"routed\"}",
        .{},
    );
    var first: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpStitchGroundPads(alloc, project, args, &first));
    try std.testing.expect(std.mem.indexOf(u8, first.items, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.items, "\"warnings_before\":2,\"warnings_after\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.items, "\"drc_errors\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.items, "\"changed\":true,\"rolled_back\":false") != null);

    var second: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpStitchGroundPads(alloc, project, args, &second));
    try std.testing.expect(std.mem.indexOf(u8, second.items, "\"warnings_before\":0,\"warnings_after\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.items, "\"vias_added\":0,\"tracks_added\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.items, "\"changed\":false,\"rolled_back\":false") != null);
}

/// One `repair_land_transit` board: 0402 caps on a real two-pad footprint, with
/// the caller supplying the instances, the saved poses, and the saved copper.
/// The two tests below need boards that differ only in how the offending
/// segment sits against the land, so everything that decides the outcome is in
/// the caller's three strings.
const LandTransitFixture = struct {
    /// `(instance …)` forms for the design block.
    instances: []const u8,
    /// The saved row's `parts` array body.
    parts: []const u8,
    /// The saved row's `tracks` array body.
    tracks: []const u8,
};

fn writeLandTransitFixture(
    alloc: std.mem.Allocator,
    dir: std.Io.Dir,
    fixture: LandTransitFixture,
) !void {
    try dir.createDirPath(std.testing.io, "lib/components");
    try dir.createDirPath(std.testing.io, "lib/footprints");
    try dir.createDirPath(std.testing.io, "src");
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/cap.sexp", .data =
        \\(component-family cap
        \\  (param-type capacitance)
        \\  (footprint "0402"))
    });
    // A 0.56 x 0.62 land is well under `land_transit.paddle_min_half_mm` on
    // both axes, so the ray rule judges it.
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/footprints/0402.sexp", .data =
        \\(footprint "0402"
        \\  (pad 1 smd roundrect (pos -0.48 0.00) (size 0.56 0.62))
        \\  (pad 2 smd roundrect (pos 0.48 0.00) (size 0.56 0.62))
        \\  (courtyard (rect -0.91 -0.46 0.91 0.46)))
    });
    try dir.writeFile(std.testing.io, .{
        .sub_path = "src/landrep.sexp",
        .data = try std.fmt.allocPrint(alloc,
            \\(design-block "Land Repair"
            \\  (import cap)
            \\  (board (size 12 12))
            \\  (design-rules (stackup 2))
            \\{s})
        , .{fixture.instances}),
    });
    try dir.writeFile(std.testing.io, .{
        .sub_path = "src/landrep.layouts.json",
        .data = try std.fmt.allocPrint(
            alloc,
            "{{\"default\":\"routed\",\"layouts\":[{{\"name\":\"routed\",\"kind\":\"manual\",\"ts\":2," ++
                "\"default\":true,\"parts\":[{s}],\"routes\":{{\"tracks\":[{s}],\"vias\":[]}}}}]}}",
            .{ fixture.parts, fixture.tracks },
        ),
    });
}

// spec: serve/mcp_tools - repair_land_transit keeps a net's rewrite only when that net's dangling_copper count does not grow, so one land-transit warning is never traded for redundant copper
// spec: serve/mcp_tools - repair_land_transit names every net whose rewrite the dangling-copper clause refused, with that net's before/after dangling reading
test "repair_land_transit refuses a rewrite that manufactures redundant copper" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    // C1 pad 1 (SIG) lands at (4.52, 5) with its land spanning x 4.24..4.76.
    // SIG leaves it westward along the centre ray to (4.20, 5) and turns north
    // there — the corner sits in the land's own flank corridor, so the vertical
    // leg is a land transit. Re-anchoring that leg routes it out to the pad
    // centre and straight back, duplicating the escape the pad already carries:
    // two deletion-invariant sections bought with one warning.
    try writeLandTransitFixture(alloc, tmp.dir, .{
        .instances =
        \\  (instance "C1" (cap "10nF") (pin 1 "SIG") (pin 2 "GND"))
        \\  (instance "C2" (cap "10nF") (pin 1 "SIG") (pin 2 "GND"))
        ,
        .parts =
        \\{"ref":"C1","x":5,"y":5,"rot":0},{"ref":"C2","x":3.72,"y":3,"rot":180}
        ,
        .tracks =
        \\{"x1":4.52,"y1":5,"x2":4.20,"y2":5,"l":0,"w":0.2,"net":"SIG"},
        \\{"x1":4.20,"y1":5,"x2":4.20,"y2":3,"l":0,"w":0.2,"net":"SIG"},
        \\{"x1":5.48,"y1":5,"x2":5.48,"y2":7,"l":0,"w":0.2,"net":"GND"},
        \\{"x1":5.48,"y1":7,"x2":3.24,"y2":7,"l":0,"w":0.2,"net":"GND"},
        \\{"x1":3.24,"y1":7,"x2":3.24,"y2":3,"l":0,"w":0.2,"net":"GND"}
        ,
    });

    const args = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"name\":\"landrep\",\"layout\":\"routed\"}",
        .{},
    );
    var out: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpRepairLandTransit(alloc, project, args, &out));

    // The land transit survives, because the only rewrite on offer costs more
    // hygiene than it returns.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"warnings_before\":1,\"warnings_after\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"segments_reanchored\":0,\"tracks_pruned\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"tracks_before\":5,\"tracks_after\":5") != null);
    // …and the tool says so, rather than keeping the old copper without a word.
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.items,
        "\"accepted\":[],\"rejected\":[\"SIG\"],\"refused\":[{\"net\":\"SIG\",\"dangling_before\":0,\"dangling_after\":2}]",
    ) != null);
    const kept = mcpReadWorking(alloc, project, "landrep", "routed").?.routes.?;
    try std.testing.expectEqual(@as(usize, 5), kept.tracks.len);
    try std.testing.expectEqual(@as(f64, 4.20), kept.tracks[1].x1);
    try std.testing.expectEqual(@as(f64, 4.20), kept.tracks[1].x2);
}

// spec: serve/mcp_tools - repair_land_transit persists a re-anchoring that removes the net's land transit without adding dangling copper
test "repair_land_transit persists a rewrite that costs no dangling copper" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    // The same land, this time crossed by copper that only passes through on
    // its way from C2's pad to C3's, 0.08 mm off the centre ray. Nothing else
    // touches the land, so splitting the run at the centre buys a clean land
    // and strands nothing.
    try writeLandTransitFixture(alloc, tmp.dir, .{
        .instances =
        \\  (instance "C1" (cap "10nF") (pin 1 "SIG") (pin 2 "GND"))
        \\  (instance "C2" (cap "10nF") (pin 1 "SIG") (pin 2 "GND"))
        \\  (instance "C3" (cap "10nF") (pin 1 "SIG") (pin 2 "GND"))
        ,
        .parts =
        \\{"ref":"C1","x":5,"y":5,"rot":180},{"ref":"C2","x":5.08,"y":2,"rot":180},
        \\{"ref":"C3","x":5.08,"y":8,"rot":180}
        ,
        .tracks =
        \\{"x1":5.56,"y1":2,"x2":5.56,"y2":8,"l":0,"w":0.2,"net":"SIG"},
        \\{"x1":4.52,"y1":5,"x2":2.5,"y2":5,"l":0,"w":0.2,"net":"GND"},
        \\{"x1":2.5,"y1":5,"x2":2.5,"y2":2,"l":0,"w":0.2,"net":"GND"},
        \\{"x1":2.5,"y1":2,"x2":4.60,"y2":2,"l":0,"w":0.2,"net":"GND"},
        \\{"x1":2.5,"y1":5,"x2":2.5,"y2":8,"l":0,"w":0.2,"net":"GND"},
        \\{"x1":2.5,"y1":8,"x2":4.60,"y2":8,"l":0,"w":0.2,"net":"GND"}
        ,
    });

    const args = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"name\":\"landrep\",\"layout\":\"routed\"}",
        .{},
    );
    var out: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpRepairLandTransit(alloc, project, args, &out));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"warnings_before\":1,\"warnings_after\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"segments_reanchored\":1,\"tracks_pruned\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"tracks_before\":6,\"tracks_after\":9") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"accepted\":[\"SIG\"],\"rejected\":[],\"refused\":[]") != null);
    try std.testing.expectEqual(
        @as(usize, 9),
        mcpReadWorking(alloc, project, "landrep", "routed").?.routes.?.tracks.len,
    );
}

// spec: Web Server - the outline write paths reject a self-intersecting or zero-area polygon but accept a concave one
test "outline write-path gate rejects a self-intersecting polygon, accepts a concave one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // A bow-tie polygon still parses (the reader is deliberately lenient), but
    // the shared write-path gate — outline_mod.valid, called by
    // saveNamedLayoutApi (→ HTTP 400) and mcpSetBoardOutline (→ CLI error) —
    // rejects it.
    const bowtie = try std.json.parseFromSliceLeaky(std.json.Value, alloc,
        \\{"pts":[[0,0],[10,10],[10,0],[0,10]]}
    , .{});
    const bo = mcpParseOutlineArg(alloc, bowtie) orelse return error.TestParseFailed;
    const bpts = bo.pts orelse return error.TestParseFailed;
    try std.testing.expect(!outline_mod.valid(bpts));

    // A concave-but-simple L polygon parses AND passes the gate.
    const l = try std.json.parseFromSliceLeaky(std.json.Value, alloc,
        \\{"pts":[[0,0],[40,0],[40,20],[20,20],[20,40],[0,40]]}
    , .{});
    const lo = mcpParseOutlineArg(alloc, l) orelse return error.TestParseFailed;
    const lpts = lo.pts orelse return error.TestParseFailed;
    try std.testing.expect(outline_mod.valid(lpts));
}

// spec: placement/rf-port-frame-routing - a route removed by the final DRC gate is never rendered, saved, replayed, or fabricated as an RF polygon
test "fresh route persistence omits DRC-gate-removed RF polygons" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const samples = [_]rf_path_solver.Sample{
        .{ .at = .{ 0, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 0.1 },
        .{ .at = .{ 1, 0 }, .s_mm = 1, .curvature = 0, .width_mm = 0.2 },
    };
    const outcomes = [_]rf_port_report.Outcome{.{
        .net = 0,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = 2, .gate_removed = true, .samples = &samples },
    }};
    const nets = [_]export_kicad.FlatNet{.{ .name = "RF", .pins = &.{} }};

    var json: std.Io.Writer.Allocating = .init(alloc);
    try writeFreshRfPathsJson(&json.writer, &outcomes, &nets);
    try std.testing.expectEqualStrings("[]", json.written());

    const routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 1, .rf_port_outcomes = &outcomes };
    const saved = try mcpSavedRoutesFrom(alloc, routed, &nets, null);
    try std.testing.expectEqual(@as(usize, 0), saved.rf_paths.len);
}

// spec: Web Server - A moved RF part drops its trace's fence with its copper, because a fence via is invalidated by the net it flanks and not by the ground net it stitches
test "scoped copper clearing drops a fence via by the net it flanks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const sr = SavedRoutes{
        .tracks = &[_]SavedTrack{.{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .w = 0.31, .net = "RF1_BPF" }},
        .vias = &[_]SavedVia{
            .{ .x = 1, .y = 0.6, .d = 0.4, .drill = 0.2, .net = "GND", .f = "RF1_BPF" },
            .{ .x = 9, .y = 9, .d = 0.4, .drill = 0.2, .net = "GND" }, // plain GND stitch
        },
    };
    // Moving the RF part invalidates RF1_BPF only — GND is untouched.
    var drop = std.StringHashMapUnmanaged(void).empty;
    try drop.put(alloc, "RF1_BPF", {});
    const res = try mcpDropRoutesForNets(alloc, sr, &drop);
    const kept = res.routes orelse return error.TestParseFailed;
    // The trace AND its fence go; the unrelated GND stitching via stays. Keyed on
    // `net` alone the fence would have survived beside nothing.
    try std.testing.expectEqual(@as(usize, 2), res.dropped);
    try std.testing.expectEqual(@as(usize, 0), kept.tracks.len);
    try std.testing.expectEqual(@as(usize, 1), kept.vias.len);
    try std.testing.expectApproxEqAbs(@as(f64, 9), kept.vias[0].x, 1e-9);
}

// spec: Web Server - coordinate-scoped clear_routes removes one selected via without erasing the rest of a dense shared net
test "coordinate-scoped via clearing is surgical" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const sr = SavedRoutes{
        .tracks = &[_]SavedTrack{
            .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .w = 0.25, .net = "GND" },
        },
        .vias = &[_]SavedVia{
            .{ .x = 1.0, .y = 1.0, .d = 0.4, .drill = 0.2, .net = "GND" },
            .{ .x = 1.2, .y = 1.0, .d = 0.4, .drill = 0.2, .net = "GND" },
            .{ .x = 1.0, .y = 1.0, .d = 0.4, .drill = 0.2, .net = "VCC" },
        },
    };
    var drop = std.StringHashMapUnmanaged(void).empty;
    try drop.put(alloc, "GND", {});
    const res = try mcpDropViasNear(alloc, sr, &drop, 1.0, 1.0, 0.05);
    const kept = res.routes orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 1), res.dropped);
    try std.testing.expectEqual(@as(usize, 1), kept.tracks.len);
    try std.testing.expectEqual(@as(usize, 2), kept.vias.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1.2), kept.vias[0].x, 1e-9);
    try std.testing.expectEqualStrings("VCC", kept.vias[1].net);
}

// Regression: zone replacement validates the complete set before persistence.
test "set_copper_zones validates nets inner layers and polygons" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const planes = [_]optimizer.PlaneAt{
        .{ .index = 2, .net = "GND" },
        .{ .index = 5, .net = "GND" },
    };
    var placement = addTracksFixture(&.{}, &add_tracks_nets, &.{});
    placement.rules = .{
        .plane_nets = &.{"GND"},
        .copper_layers = 6,
        .planes = .{ .declared = &planes },
    };

    var valid_out: std.ArrayList(u8) = .empty;
    const valid_json = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"zones\":[{\"net\":\"SIG\",\"layer\":\"In3.Cu\",\"priority\":4,\"group\":\"buck\",\"poly\":[[0,0],[8,0],[8,6],[0,6]]}]}",
        .{},
    );
    const zones = (try mcpBuildCopperZones(alloc, &valid_out, placement, valid_json)).?;
    try std.testing.expectEqual(@as(usize, 1), zones.len);
    try std.testing.expectEqualStrings("In3.Cu", zones[0].layer);
    try std.testing.expect(zones[0].flags.filled);
    try std.testing.expectEqual(@as(i64, 4), zones[0].priority);
    try std.testing.expectEqualStrings("buck", zones[0].g);

    var plane_out: std.ArrayList(u8) = .empty;
    const claimed_plane = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"zones\":[{\"net\":\"SIG\",\"layer\":\"In1.Cu\",\"poly\":[[0,0],[8,0],[0,6]]}]}",
        .{},
    );
    try std.testing.expect((try mcpBuildCopperZones(alloc, &plane_out, placement, claimed_plane)) == null);
    try std.testing.expect(std.mem.indexOf(u8, plane_out.items, "plane-claimed") != null);

    var net_out: std.ArrayList(u8) = .empty;
    const unknown_net = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"zones\":[{\"net\":\"NO_SUCH_NET\",\"layer\":\"In3.Cu\",\"poly\":[[0,0],[8,0],[0,6]]}]}",
        .{},
    );
    try std.testing.expect((try mcpBuildCopperZones(alloc, &net_out, placement, unknown_net)) == null);
    try std.testing.expect(std.mem.indexOf(u8, net_out.items, "unknown net") != null);

    var poly_out: std.ArrayList(u8) = .empty;
    const crossing = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        "{\"zones\":[{\"net\":\"SIG\",\"layer\":\"In3.Cu\",\"poly\":[[0,0],[8,6],[0,6],[8,0]]}]}",
        .{},
    );
    try std.testing.expect((try mcpBuildCopperZones(alloc, &poly_out, placement, crossing)) == null);
    try std.testing.expect(std.mem.indexOf(u8, poly_out.items, "self-intersects") != null);
}

// Regression: a clean-slate autoroute clears generated copper but keeps the
// user-authored pours that are inputs to the next route.
test "unscoped clear_routes preserves copper zones" {
    const poly = [_][2]f64{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 3 }, .{ 0, 3 } };
    const zones = [_]SavedZone{.{
        .net = "SIG",
        .layer = board_layers.f_cu,
        .poly = &poly,
        .flags = .{ .filled = true },
    }};
    const routes = SavedRoutes{
        .tracks = &.{.{ .x1 = 0, .y1 = 0, .x2 = 4, .y2 = 0, .w = 0.2, .net = "SIG" }},
        .vias = &.{.{ .x = 2, .y = 0, .d = 0.4, .net = "SIG" }},
        .zones = &zones,
    };
    const kept = mcpClearAllRoutedCopper(routes) orelse return error.TestNoSavedRoutes;
    try std.testing.expectEqual(@as(usize, 0), kept.tracks.len);
    try std.testing.expectEqual(@as(usize, 0), kept.vias.len);
    try std.testing.expectEqual(@as(usize, 1), kept.zones.len);
    try std.testing.expectEqualStrings(board_layers.f_cu, kept.zones[0].layer);

    try std.testing.expect(mcpClearAllRoutedCopper(.{ .tracks = &.{}, .vias = &.{} }) == null);
}

// spec: Web Server - The set_part_poses MCP tool parses each pose's ref, mm centre, and optional rot/side/locked (absent optionals stay unset)
test "mcp set_part_poses parses request poses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const body =
        \\{"poses":[{"ref":"C1","x_mm":1.5,"y_mm":2.5},
        \\{"ref":"mcu/U1","x_mm":0,"y_mm":0,"rot":90,"side":"bottom","locked":true}]}
    ;
    const j = try std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{});
    const poses = mcpParsePoses(alloc, j) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 2), poses.len);
    try std.testing.expectEqualStrings("C1", poses[0].ref);
    try std.testing.expect(poses[0].has_xy);
    try std.testing.expectEqual(@as(f64, 1.5), poses[0].x);
    try std.testing.expectEqual(@as(f64, 2.5), poses[0].y);
    // Absent optionals stay unset so the tool keeps the part's current values.
    try std.testing.expect(!poses[0].has_rot);
    try std.testing.expect(!poses[0].has_side);
    try std.testing.expect(!poses[0].has_locked);
    // Present optionals parse through.
    try std.testing.expect(poses[1].has_rot);
    try std.testing.expectEqual(@as(f64, 90), poses[1].rot);
    try std.testing.expectEqual(optimizer.Side.bottom, poses[1].side);
    try std.testing.expect(poses[1].has_locked and poses[1].locked);
}

// spec: Web Server - The set_board_outline MCP tool accepts a rect and a polygon pts, deriving the rect fields from the polygon bbox
test "mcp set_board_outline parses rect and polygon" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const jr = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"rect\":{\"x\":0,\"y\":0,\"w\":10,\"h\":20}}", .{});
    const o1 = mcpParseOutlineArg(alloc, jr) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(f64, 10), o1.w);
    try std.testing.expectEqual(@as(f64, 20), o1.h);
    try std.testing.expect(o1.pts == null);

    const jp = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"pts\":[[0,0],[4,0],[4,3]]}", .{});
    const o2 = mcpParseOutlineArg(alloc, jp) orelse return error.TestParseFailed;
    try std.testing.expect(o2.pts != null);
    try std.testing.expectEqual(@as(f64, 4), o2.w); // bbox width
    try std.testing.expectEqual(@as(f64, 3), o2.h); // bbox height

    // A degenerate rect (zero area) is rejected.
    const jbad = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"rect\":{\"x\":0,\"y\":0,\"w\":0,\"h\":0}}", .{});
    try std.testing.expect(mcpParseOutlineArg(alloc, jbad) == null);
}

// spec: Web Server - The route_pcb MCP tool serializes routed net indices back to net names, round-tripping through restoreRoutes
// spec: serve/mcp_tools - Saved-copper rewrites preserve stamp-group, fence-provenance, and via-span tags on unchanged geometry
test "mcp route_pcb copper round-trips net index and name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const nets = [_]export_kicad.FlatNet{
        .{ .name = "GND", .pins = &[_]export_kicad.FlatPin{} },
        .{ .name = "VBUS", .pins = &[_]export_kicad.FlatPin{} },
    };
    const rr = router.RouteResult{
        .tracks = &[_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 1, .width = 0.3, .net = 1 }},
        .vias = &[_]router.Via{.{ .x = 1, .y = 0, .dia = 0.6, .net = 1, .drill = 0.3 }},
        .routed = 1,
        .total = 1,
    };
    const prior_tracks = [_]SavedTrack{.{ .x1 = 3, .y1 = 0, .x2 = 0, .y2 = 0, .l = 1, .w = 0.3, .net = "VBUS", .g = "power-block", .source = route_source_human, .id = "seg-retained000001" }};
    const prior_vias = [_]SavedVia{.{ .x = 1, .y = 0, .d = 0.6, .drill = 0.3, .net = "VBUS", .g = "power-block", .f = "RF_OUT", .source = route_source_agent, .s = .{ 0, 1 }, .id = "via-retained000001" }};
    const sr = try mcpSavedRoutesFrom(alloc, rr, &nets, .{ .tracks = &prior_tracks, .vias = &prior_vias });
    try std.testing.expectEqualStrings("VBUS", sr.tracks[0].net);
    try std.testing.expectEqual(@as(u8, 1), sr.tracks[0].l);
    try std.testing.expectEqualStrings("VBUS", sr.vias[0].net);
    try std.testing.expectEqualStrings("power-block", sr.tracks[0].g);
    try std.testing.expectEqualStrings("power-block", sr.vias[0].g);
    try std.testing.expectEqualStrings("RF_OUT", sr.vias[0].f);
    try std.testing.expectEqualStrings(route_source_human, sr.tracks[0].source);
    try std.testing.expectEqualStrings("seg-retained000001", sr.tracks[0].id);
    try std.testing.expectEqualStrings(route_source_agent, sr.vias[0].source);
    try std.testing.expectEqual(@as(?[2]u8, .{ 0, 1 }), sr.vias[0].s);
    try std.testing.expectEqualStrings("via-retained000001", sr.vias[0].id);

    const fresh = try mcpSavedRoutesFrom(alloc, rr, &nets, null);
    try std.testing.expectEqualStrings(route_source_autorouter, fresh.tracks[0].source);
    try std.testing.expectEqualStrings(route_source_autorouter, fresh.vias[0].source);

    const legacy_tracks = [_]SavedTrack{.{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .l = 1, .w = 0.3, .net = "VBUS" }};
    const legacy_vias = [_]SavedVia{.{ .x = 1, .y = 0, .d = 0.6, .drill = 0.3, .net = "VBUS" }};
    const legacy = try mcpSavedRoutesFrom(alloc, rr, &nets, .{ .tracks = &legacy_tracks, .vias = &legacy_vias });
    try std.testing.expectEqualStrings("", legacy.tracks[0].source);
    try std.testing.expectEqualStrings("", legacy.vias[0].source);

    const restored = restoreRoutes(alloc, sr, &nets) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(i32, 1), restored.tracks[0].net);
    try std.testing.expectEqual(@as(i32, 1), restored.vias[0].net);
}

// spec: Web Server - route_pcb can learn hard path topology and reserve its proven transition sites from a completed saved reference layout while preserving authored wave/layer policy
// spec: Web Server - a reference-guided route reports how many nets received learned topology and how many required exact-copper fallback
test "mcp route_pcb overlays saved reference topology on authored policy" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R1", .kind = .passive, .hw = 1, .hh = 1, .pads = &pad, .fallback = false, .x = 4, .y = 0 },
    };
    const pins = [_]export_kicad.FlatPin{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "R1", .pin = "1" },
    };
    const nets = [_]export_kicad.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 5,
        .maxy = 1,
        .generated = false,
        .board_rect = .{ .minx = -1, .miny = -1, .w = 6, .h = 2 },
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };
    const saved = SavedRoutes{
        .tracks = &.{
            .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .l = 0, .w = 0.2, .net = "SIG" },
            .{ .x1 = 2, .y1 = 0, .x2 = 4, .y2 = 0, .l = 0, .w = 0.2, .net = "SIG" },
        },
        .vias = &.{.{ .x = 2, .y = 0, .d = 0.4, .drill = 0.2, .net = "SIG" }},
    };
    const base = [_]route_policy.NetPolicy{.{
        .wave = .{ .priority = 17, .before_planes = 1 },
        .allowed_layers = 1,
        .max_vias = 2,
    }};
    var options = route_policy.Options{ .net = &base };
    const guided = try mcpApplyReferenceGuides(alloc, &options, placement, saved);
    try std.testing.expectEqual(@as(usize, 1), guided);
    try std.testing.expectEqual(@as(u32, 17), options.net[0].wave.priority);
    try std.testing.expectEqual(@as(u64, 1), options.net[0].allowed_layers);
    try std.testing.expectEqual(@as(?u16, 2), options.net[0].max_vias);
    try std.testing.expect(options.net[0].replay_reference_copper);
    try std.testing.expectEqual(@as(usize, 2), options.guides.tracks.len);
    try std.testing.expectEqual(@as(usize, 2), options.guides.reserved.len);
}

// spec: Web Server - The route_pcb CLI tool preserves custom copper pours and passes them to the autorouter for whole-board and scoped routes
test "mcp route_pcb scoped copper preserves custom pours while dropping and merging by net" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const zone_poly = [_][2]f64{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } };
    const sr = SavedRoutes{
        .tracks = &[_]SavedTrack{
            .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .w = 0.2, .net = "A" },
            .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .w = 0.2, .net = "B" },
        },
        .vias = &.{},
        .zones = &.{.{ .net = "A", .layer = "In2.Cu", .poly = &zone_poly, .flags = .{ .filled = true } }},
    };
    var scope = std.StringHashMapUnmanaged(void).empty;
    try scope.put(alloc, "A", {});

    const dropped = try mcpDropRoutesForNets(alloc, sr, &scope);
    try std.testing.expectEqual(@as(usize, 1), dropped.dropped); // A removed
    const rem = dropped.routes orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 1), rem.tracks.len);
    try std.testing.expectEqualStrings("B", rem.tracks[0].net); // B kept
    try std.testing.expectEqual(@as(usize, 1), rem.zones.len); // custom pour kept

    const kept = try mcpKeepRoutesForNets(alloc, sr, &scope) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 1), kept.tracks.len);
    try std.testing.expectEqualStrings("A", kept.tracks[0].net);
    try std.testing.expectEqual(@as(usize, 0), kept.zones.len); // retained base owns it

    const merged = try mcpMergeRoutes(alloc, rem, kept) orelse return error.TestParseFailed;
    try std.testing.expectEqual(@as(usize, 2), merged.tracks.len); // B (prior) + A (fresh)
    try std.testing.expectEqual(@as(usize, 1), merged.zones.len);
}

/// A minimal placement + design block for the route-scope resolver tests: one
/// hub and two nets (an RF net the criticality classifier recognises by name,
/// and a plain signal net).
const scope_fixture_part = optimizer.Part{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false };

const scope_fixture_nets = [_]export_kicad.FlatNet{
    .{ .name = "RFOUT", .pins = &.{} },
    .{ .name = "SIG", .pins = &.{} },
};

pub fn scopeFixture(parts: *[1]optimizer.Part) struct { placement: optimizer.Placement, block: env_mod.DesignBlock } {
    parts.* = .{scope_fixture_part};
    return .{
        .placement = .{
            .parts = parts,
            .links = &.{},
            .loops = &.{},
            .stubs = &.{},
            .instances = &.{},
            .nets = &scope_fixture_nets,
            .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
            .minx = 0,
            .miny = 0,
            .maxx = 1,
            .maxy = 1,
            .generated = true,
        },
        .block = .{
            .name = "t",
            .instances = &.{},
            .nets = &.{},
            .ports = &.{},
            .notes = &.{},
            .groups = &.{},
            .sub_blocks = &.{},
        },
    };
}

// spec: Web Server - The route_pcb scope resolver selects a group token's concrete nets and reports a whole-board route when no selector is given
test "mcp route scope resolves a group and defaults to whole board" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var parts: [1]optimizer.Part = undefined;
    const fx = scopeFixture(&parts);

    var out: std.ArrayList(u8) = .empty;
    const rf = (try mcpResolveRouteScope(alloc, &out, &fx.block, fx.placement, &.{"rf"}, &.{})) orelse
        return error.TestScopeNull;
    try std.testing.expect(rf.has_scope);
    try std.testing.expectEqual(@as(usize, 1), rf.matched);
    try std.testing.expectEqualStrings("RFOUT", rf.names[0]);

    // No selector token at all ⇒ a whole-board route (no error emitted).
    var out2: std.ArrayList(u8) = .empty;
    const whole = (try mcpResolveRouteScope(alloc, &out2, &fx.block, fx.placement, &.{}, &.{})) orelse
        return error.TestScopeNull;
    try std.testing.expect(!whole.has_scope);
    try std.testing.expectEqual(@as(usize, 0), out2.items.len);
}

// spec: Web Server - The route_pcb scope resolver rejects an unknown group or net token with an error and no scope
test "mcp route scope errors on an unknown token" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var parts: [1]optimizer.Part = undefined;
    const fx = scopeFixture(&parts);

    var out: std.ArrayList(u8) = .empty;
    const bad = try mcpResolveRouteScope(alloc, &out, &fx.block, fx.placement, &.{"nope"}, &.{});
    try std.testing.expect(bad == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "unknown route group/net") != null);
}

// spec: Web Server - The set_part_poses MCP tool resolves a part by module-local origin key when the ref-des is not an exact match
test "mcp origin-key strips the sub-block prefix" {
    try std.testing.expectEqualStrings("U1", mcpOriginOf("buck/U1"));
    try std.testing.expectEqualStrings("C3", mcpOriginOf("C3"));
    try std.testing.expectEqualStrings("C_IN", mcpOriginOf("mcu/sub/C_IN"));
}

test "mcpSetPartPoses rejects an empty poses array before resolving" {
    // `if (reqs.len == 0)` fails fast with `"poses" is empty`; an `==`->`!=`
    // flip lets an empty request through to layout resolution, which fails
    // with a different ("could not resolve") message instead.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"name\":\"x\",\"poses\":[]}", .{});
    const ok = try mcpSetPartPoses(alloc, "/no/such/project", args, &out);
    try std.testing.expect(!ok);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "is empty") != null);
}

/// A 2-layer, plane-free board carrying nets SIG (net 0) and RF (net 1) — the
/// fixture the `add_tracks` lowering scenarios draw copper on. `rules.net`
/// gives RF a `(net-class …)` rule so the width/via defaulting is observable.
pub fn addTracksFixture(parts: []optimizer.Part, nets: []const export_kicad.FlatNet, rules: []const optimizer.NetRule) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 12,
        .maxy = 6,
        .generated = false,
        .board_rect = .{ .minx = -2, .miny = -2, .w = 16, .h = 10 },
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2, .net = rules },
    };
}

pub const add_tracks_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};

pub fn addTracksParts() [2]optimizer.Part {
    return .{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &add_tracks_pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &add_tracks_pad, .fallback = false, .x = 10, .y = 0 },
    };
}

pub const add_tracks_nets = [_]export_kicad.FlatNet{
    .{ .name = "SIG", .pins = &.{} },
    .{ .name = "RF", .pins = &.{} },
};

// spec: Web Server - The add_tracks tool lowers a requested polyline into one persisted track segment per consecutive point pair
test "add_tracks lowers an N-point polyline into N-1 segments on the named layer" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;

    var parts = addTracksParts();
    const placement = addTracksFixture(&parts, &add_tracks_nets, &.{});
    // A 4-point L-shaped route on the bottom layer → 3 joined segments.
    const pts = [_][2]f64{ .{ 0, 0 }, .{ 3, 0 }, .{ 3, 4 }, .{ 10, 4 } };
    const reqs = [_]McpReqTrack{.{ .net = "SIG", .layer = "B.Cu", .pts = &pts }};

    const built = (try mcpBuildAddedCopper(alloc, &out, placement, .{}, &reqs, &.{})).?;
    try std.testing.expectEqual(@as(usize, 3), built.tracks.len);
    // Segments must CHAIN (each one's end is the next one's start), else the
    // copper lands as disconnected stubs and the net never closes.
    try std.testing.expectEqual(@as(f64, 0), built.tracks[0].x1);
    try std.testing.expectEqual(@as(f64, 3), built.tracks[0].x2);
    try std.testing.expectEqual(@as(f64, 3), built.tracks[1].x1);
    try std.testing.expectEqual(@as(f64, 4), built.tracks[1].y2);
    try std.testing.expectEqual(@as(f64, 10), built.tracks[2].x2);
    for (built.tracks) |t| {
        try std.testing.expectEqual(@as(u8, 1), t.l); // B.Cu
        try std.testing.expectEqualStrings("SIG", t.net);
        try std.testing.expectEqualStrings(route_source_agent, t.source);
    }
}

// spec: Web Server - The add_tracks tool defaults track width and via geometry to the net's declared net-class rule
test "add_tracks takes width and via size from the net-class rule unless overridden" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;

    var parts = addTracksParts();
    // Net 1 (RF) carries a class rule; net 0 (SIG) has none, so SIG falls back
    // to the board base params.
    const rules = [_]optimizer.NetRule{ .{}, .{ .width = 0.45, .via_dia = 0.6, .via_drill = 0.3 } };
    const placement = addTracksFixture(&parts, &add_tracks_nets, &rules);
    const base = router.RouteParams{ .track_width = 0.127, .via_dia = 0.4, .via_drill = 0.2 };

    const sig_pts = [_][2]f64{ .{ 0, 0 }, .{ 5, 0 } };
    const rf_pts = [_][2]f64{ .{ 0, 2 }, .{ 5, 2 } };
    const wide_pts = [_][2]f64{ .{ 0, 4 }, .{ 5, 4 } };
    const reqs = [_]McpReqTrack{
        .{ .net = "SIG", .layer = "F.Cu", .pts = &sig_pts },
        .{ .net = "RF", .layer = "F.Cu", .pts = &rf_pts },
        .{ .net = "RF", .layer = "F.Cu", .pts = &wide_pts, .width = 1.2 },
    };
    const vreqs = [_]McpReqVia{
        .{ .net = "SIG", .x = 5, .y = 0 },
        .{ .net = "RF", .x = 5, .y = 2 },
    };

    const built = (try mcpBuildAddedCopper(alloc, &out, placement, base, &reqs, &vreqs)).?;
    try std.testing.expectEqual(@as(f64, 0.127), built.tracks[0].w); // board default
    try std.testing.expectEqual(@as(f64, 0.45), built.tracks[1].w); // RF class width
    try std.testing.expectEqual(@as(f64, 1.2), built.tracks[2].w); // explicit override wins
    try std.testing.expectEqual(@as(f64, 0.4), built.vias[0].d); // board default via
    try std.testing.expectEqual(@as(f64, 0.6), built.vias[1].d); // RF class via
    try std.testing.expectEqual(@as(f64, 0.3), built.vias[1].drill);
    for (built.tracks) |t| try std.testing.expectEqualStrings(route_source_agent, t.source);
    try std.testing.expectEqualStrings(route_source_agent, built.vias[0].source);
    try std.testing.expectEqualStrings(route_source_agent, built.vias[1].source);
}

// spec: Web Server - Hand-added copper that raises the error-severity DRC count is rolled back rather than persisted, unless the caller opts out
test "add_tracks rolls back copper that raises the error count" {
    // The decision the handler makes, in isolation: keep copper only while the
    // error-severity count does not climb. There is no per-edit undo otherwise
    // (`clear_routes` is per-NET), so an agent drawing copper needs a bad edit
    // to cost nothing — that is what makes draw/measure/adjust safe to iterate.
    const keeps = struct {
        fn f(rollback: bool, before: usize, after: usize) bool {
            return !(rollback and after > before);
        }
    }.f;
    try std.testing.expect(keeps(true, 8, 8)); // unchanged: kept
    try std.testing.expect(keeps(true, 8, 7)); // improved: kept
    try std.testing.expect(!keeps(true, 8, 11)); // worse: rolled back
    // …and the opt-out keeps copper regardless, for a caller spending a known
    // budget deliberately.
    try std.testing.expect(keeps(false, 8, 11));
}

// spec: Web Server - The add_tracks result separates fab-blocking DRC errors from total violations
test "add_tracks reports drc_errors beside the total violation count" {
    // The two counts must be distinct fields: a caller deciding whether to keep
    // hand copper gates on ERRORS, because sharp-bend / diff-skew WARNINGS are
    // not fab-blocking and treating them as regressions rejects good routes.
    const vios = [_]drc.Violation{
        .{ .kind = .track_pad, .x = 1, .y = 1, .gap = 0.01, .clearance = 0.127, .severity = .err },
        .{ .kind = .sharp_bend, .x = 2, .y = 2, .gap = 0, .clearance = 0, .severity = .warn },
        .{ .kind = .track_track, .x = 3, .y = 3, .gap = 0.02, .clearance = 0.127, .severity = .err },
    };
    // 3 violations, but only 2 block fabrication.
    try std.testing.expectEqual(@as(usize, 2), drc.errorCount(&vios));
    // An all-warning list is reported as zero blocking errors, never as "clean"
    // by dropping the warnings from the total the caller also sees.
    try std.testing.expectEqual(@as(usize, 0), drc.errorCount(vios[1..2]));
    try std.testing.expectEqual(@as(usize, 0), drc.errorCount(&.{}));
}

// spec: Web Server - The add_tracks rollback gate counts only geometry violations, never an open net, so an unfinished escape stub is kept
test "add_tracks judges hand copper on geometry, not on the net still being open" {
    // Hand routing lands in steps. The first step out of a sealed fine-pitch
    // pad is a stub to a fanout via: geometrically perfect, and it raises the
    // OPEN-net count by one because the stub is its own island until the run
    // finishes. Counting that as a regression rolled the stub back and the
    // loop could never take a first step — measured on board-a's LMX2595
    // escape, which added zero clearance findings and was undone anyway.
    const stub_in_progress = [_]drc.Violation{
        .{ .kind = .net_open, .x = 1, .y = 1, .gap = 0.3, .clearance = 0, .severity = .err },
    };
    try std.testing.expectEqual(@as(usize, 0), drc.errorCount(&stub_in_progress));

    // A real clearance breach in the same list still counts, so the gate has
    // not been widened into "keep everything".
    const stub_plus_breach = [_]drc.Violation{
        .{ .kind = .net_open, .x = 1, .y = 1, .gap = 0.3, .clearance = 0, .severity = .err },
        .{ .kind = .track_pad, .x = 2, .y = 2, .gap = 0.01, .clearance = 0.127, .severity = .err },
    };
    try std.testing.expectEqual(@as(usize, 1), drc.errorCount(&stub_plus_breach));
}

// spec: Web Server - The add_tracks tool rejects an unknown net, an unknown copper layer, or a polyline shorter than two points without persisting anything
test "add_tracks rejects an unknown net, unknown layer, or single-point polyline" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var parts = addTracksParts();
    const placement = addTracksFixture(&parts, &add_tracks_nets, &.{});
    const good = [_][2]f64{ .{ 0, 0 }, .{ 5, 0 } };
    const lone = [_][2]f64{.{ 0, 0 }};

    // Unknown net — named in the error so the caller can fix the spelling.
    {
        var out: std.ArrayList(u8) = .empty;
        const reqs = [_]McpReqTrack{.{ .net = "NOPE", .layer = "F.Cu", .pts = &good }};
        try std.testing.expect((try mcpBuildAddedCopper(alloc, &out, placement, .{}, &reqs, &.{})) == null);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "unknown net") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "NOPE") != null);
    }
    // Unknown copper layer (In2.Cu does not exist on this 2-layer stackup).
    {
        var out: std.ArrayList(u8) = .empty;
        const reqs = [_]McpReqTrack{.{ .net = "SIG", .layer = "In2.Cu", .pts = &good }};
        try std.testing.expect((try mcpBuildAddedCopper(alloc, &out, placement, .{}, &reqs, &.{})) == null);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "unknown copper layer") != null);
    }
    // A 1-point polyline draws no segment — reject rather than silently no-op.
    {
        var out: std.ArrayList(u8) = .empty;
        const reqs = [_]McpReqTrack{.{ .net = "SIG", .layer = "F.Cu", .pts = &lone }};
        try std.testing.expect((try mcpBuildAddedCopper(alloc, &out, placement, .{}, &reqs, &.{})) == null);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "at least 2 points") != null);
    }
    // A via on an unknown net is refused too — the whole request fails, so a
    // valid track earlier in the same call is never half-persisted.
    {
        var out: std.ArrayList(u8) = .empty;
        const reqs = [_]McpReqTrack{.{ .net = "SIG", .layer = "F.Cu", .pts = &good }};
        const vreqs = [_]McpReqVia{.{ .net = "GHOST", .x = 1, .y = 1 }};
        try std.testing.expect((try mcpBuildAddedCopper(alloc, &out, placement, .{}, &reqs, &vreqs)) == null);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "GHOST") != null);
    }
}

// spec: Web Server - The route_pcb CLI tool can select a bounded retry tier, checkpoints routed copper before optional deferred DRC, and rejects unknown tiers
test "route_pcb applies and validates its effort override" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const good = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"effort\":\"one_shot\"}", .{});
    var options = route_policy.Options{};
    try std.testing.expect(mcpApplyRouteEffort(&options, good));
    try std.testing.expectEqual(route_policy.Effort.one_shot, options.effort);
    const checkpoint = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"defer_drc\":true}", .{});
    try std.testing.expect(mcpArgBool(checkpoint, "defer_drc"));

    const bad = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"effort\":\"turbo\"}", .{});
    try std.testing.expect(!mcpApplyRouteEffort(&options, bad));
}

// spec: Web Server - cancelled CLI routing preserves the sidecar and reports retained connectivity separately from its candidate
// spec: serve/route-analyze - diagnose_net inspects shown copper and reports the requested net's islands without a fresh route
// spec: Web Server - rejected manual copper reports zero applied objects retained connectivity and candidate DRC witnesses
test "routing audit mutation and inspection regressions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try writeFabSelectionFixture(tmp.dir);
    const sidecar_path = try std.fmt.allocPrint(alloc, "{s}/src/fabsel.layouts.json", .{project});
    const before = try infra_fs.cwd().readFileAlloc(alloc, sidecar_path, 1024 * 1024);
    const args = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"name\":\"fabsel\"}", .{});
    var cancel: std.atomic.Value(bool) = .init(true);
    var routed: std.ArrayList(u8) = .empty;
    try std.testing.expect(try routePcbWithCancel(alloc, project, args, &routed, &cancel));
    const response = (try std.json.parseFromSliceLeaky(std.json.Value, alloc, routed.items, .{})).object;
    try std.testing.expect(response.get("cancelled").?.bool);
    try std.testing.expect(!response.get("applied").?.bool);
    try std.testing.expectEqual(@as(i64, 1), response.get("routed").?.integer);
    try std.testing.expectEqual(@as(i64, 2), response.get("total").?.integer);
    try std.testing.expect(!response.get("candidate").?.object.get("validation_complete").?.bool);
    try std.testing.expectEqualStrings(before, try infra_fs.cwd().readFileAlloc(alloc, sidecar_path, 1024 * 1024));

    const analyze = @import("route_analyze_api.zig");
    const saved = try analyze.analyzeNetJson(alloc, project, "fabsel", "SIG", .{ .layout = "routed" });
    const open = try analyze.analyzeNetJson(alloc, project, "fabsel", "SIG", .{ .layout = "open" });
    try std.testing.expect(std.mem.indexOf(u8, saved, "\"status\":\"routed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, open, "\"status\":\"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, open, "\"islands\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, open, "\"fresh_route\":false") != null);

    const bad = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"name\":\"fabsel\",\"tracks\":[{\"net\":\"SIG\",\"layer\":\"F.Cu\",\"width\":0.2,\"points\":[[5.48,5],[10.48,5]]}]}", .{});
    var added: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpAddTracks(alloc, project, bad, &added));
    const edit = (try std.json.parseFromSliceLeaky(std.json.Value, alloc, added.items, .{})).object;
    try std.testing.expect(!edit.get("applied").?.bool);
    try std.testing.expectEqual(@as(i64, 0), edit.get("added_tracks").?.integer);
    try std.testing.expectEqual(@as(i64, 0), edit.get("drc_errors").?.integer);
    try std.testing.expectEqual(@as(i64, 1), edit.get("routed").?.integer);
    const candidate = edit.get("candidate").?.object;
    try std.testing.expect(candidate.get("drc_errors").?.integer > 0);
    try std.testing.expect(candidate.get("drc_list").?.array.items[0].object.contains("id"));
    try std.testing.expectEqualStrings(before, try infra_fs.cwd().readFileAlloc(alloc, sidecar_path, 1024 * 1024));
    const scope = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"name\":\"fabsel\",\"nets\":[\"GND\"]}", .{});
    var incremental: std.ArrayList(u8) = .empty;
    try std.testing.expect(try mcpRoutePcb(alloc, project, scope, &incremental));
    const committed = (try std.json.parseFromSliceLeaky(std.json.Value, alloc, incremental.items, .{})).object;
    try std.testing.expect(committed.get("applied").?.bool);
    try std.testing.expectEqual(@as(i64, 2), committed.get("routed").?.integer);
    try std.testing.expectEqual(@as(i64, 2), committed.get("total").?.integer);
}

pub const MoveWindow = struct { x: f64, y: f64, radius: f64 };

fn copperTouchesMove(windows: []const MoveWindow, t: SavedTrack) bool {
    // A saved arc may bow beyond its chord: clear it conservatively on a moved net.
    if (t.xm != null or t.ym != null) return true;
    for (windows) |box| {
        const r = box.radius + t.w / 2;
        if (@max(t.x1, t.x2) < box.x - r or @min(t.x1, t.x2) > box.x + r) continue;
        if (@max(t.y1, t.y2) < box.y - r or @min(t.y1, t.y2) > box.y + r) continue;
        return true;
    }
    return false;
}

pub fn mcpDropMovedCopper(
    alloc: std.mem.Allocator,
    sr: ?SavedRoutes,
    drop: *const std.StringHashMapUnmanaged(void),
    windows: []const MoveWindow,
) std.mem.Allocator.Error!McpDroppedRoutes {
    const saved = sr orelse return .{ .routes = null, .dropped = 0 };
    var tracks: std.ArrayList(SavedTrack) = .empty;
    var vias: std.ArrayList(SavedVia) = .empty;
    var rf_paths: std.ArrayList(SavedRfPath) = .empty;
    var dropped: usize = 0;
    for (saved.tracks) |t| {
        if (drop.contains(t.net) and copperTouchesMove(windows, t)) {
            dropped += 1;
        } else try tracks.append(alloc, t);
    }
    for (saved.vias) |v| {
        const point = SavedTrack{ .x1 = v.x, .y1 = v.y, .x2 = v.x, .y2 = v.y, .w = v.d };
        const nearby = drop.contains(v.net) and copperTouchesMove(windows, point);
        if (nearby or (v.f.len > 0 and drop.contains(v.f))) {
            dropped += 1;
        } else try vias.append(alloc, v);
    }
    // Swept RF paths are atomic, including their associated fence vias.
    for (saved.rf_paths) |path| if (!drop.contains(path.net)) try rf_paths.append(alloc, path);
    return .{ .routes = .{ .tracks = tracks.items, .vias = vias.items, .zones = saved.zones, .rf_paths = rf_paths.items }, .dropped = dropped };
}

pub fn mcpCreateWorking(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    entry: SavedLayout,
) (sidecar_store.StoreError || error{CandidateNameExists})!void {
    return persistWorking(true, alloc, project_dir, name, entry, false);
}

fn persistWorking(
    comptime create_only: bool,
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    entry_in: SavedLayout,
    star: bool,
) (if (create_only) sidecar_store.StoreError || error{CandidateNameExists} else sidecar_store.StoreError)!void {
    var entry = entry_in;
    entry.kind = kind_manual;
    // Every agent mutation is an edit, including an outline/route update to an
    // existing named layout. Refresh the timestamp so the editor's default
    // newest-edited-first ordering reflects the actual working layout.
    entry.ts = clock.timestamp();
    // Read the list, upsert one row, write it back with `rev + 1`: the same
    // read-modify-write `saveNamedLayoutApi` performs, so it takes the same
    // hold — an agent's CLI write and an open tab's save target one file.
    const guard = lockSidecar(name, null);
    defer guard.unlock();
    const existing = (try readSidecarDoc(alloc, project_dir, name, null)).layouts;
    var out: std.ArrayList(SavedLayout) = .empty;
    var replaced = false;
    for (existing) |L| {
        if (create_only and std.mem.eql(u8, L.name, entry.name)) return error.CandidateNameExists;
        if (!replaced and std.mem.eql(u8, L.name, entry.name)) {
            entry.default = star or L.default;
            replaced = true;
        } else {
            var e = L;
            if (star) e.default = false;
            out.append(alloc, e) catch return error.OutOfMemory;
        }
    }
    if (!replaced) entry.default = star;
    // Keep the physical history newest-first too, which resolves ties between
    // edits stamped during the same second before the stable display sort.
    out.insert(alloc, 0, entry) catch return error.OutOfMemory;
    starFirstEver(out.items);
    try mcpProtectedWrite(alloc, project_dir, name, out.items);
}

// spec: Web Server - Local pose copper invalidation preserves far trunks and other-net copper while removing moved-net copper near both poses and preserving layout metadata
test "local pose invalidation preserves distant rail trunks and foreign copper" {
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    var drop = std.StringHashMapUnmanaged(void).empty;
    try drop.put(a, "GND", {});
    const tracks = [_]SavedTrack{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .w = 0.2, .net = "GND" },
        .{ .x1 = 10, .y1 = 0, .x2 = 20, .y2 = 0, .w = 0.2, .net = "GND" },
        .{ .x1 = 0, .y1 = 1, .x2 = 1, .y2 = 1, .w = 0.2, .net = "SIG" },
    };
    const vias = [_]SavedVia{
        .{ .x = 0, .y = 0, .d = 0.4, .net = "GND" },
        .{ .x = 15, .y = 0, .d = 0.4, .net = "GND" },
    };
    const filtered = try mcpDropMovedCopper(a, .{ .tracks = &tracks, .vias = &vias }, &drop, &.{.{ .x = 0, .y = 0, .radius = 2 }});
    try std.testing.expectEqual(@as(usize, 2), filtered.dropped);
    try std.testing.expectEqualDeep(tracks[1], filtered.routes.?.tracks[0]);
    try std.testing.expectEqualDeep(tracks[2], filtered.routes.?.tracks[1]);
    try std.testing.expectEqualDeep(vias[1], filtered.routes.?.vias[0]);
}
