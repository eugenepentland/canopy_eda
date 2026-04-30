//! Incremental-sync endpoints for a KiCad plugin (or any HTTP client) that
//! wants to mirror a design with minimal transfer. The plugin fetches a small
//! manifest of content-addressed hashes, compares against its local cache,
//! and only pulls the objects it doesn't already have.
//!
//!   GET /api/sync-manifest/:name  — JSON index: netlist sha + per-footprint
//!                                    + per-model shas. Always small.
//!   GET /api/netlist/:name        — KiCad netlist text. ETag = sha256.
//!   GET /api/object/:sha          — raw bytes of a previously manifested
//!                                    footprint (.kicad_mod) or STEP model.
//!
//! The sha-to-bytes/path mapping is populated lazily when a manifest is
//! requested; the object endpoint returns 404 for shas we've never seen.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const log = @import("../infra/log.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const env_mod = @import("../eval/env.zig");
const export_kicad = @import("../export_kicad.zig");
const netlist_mod = @import("../export_kicad_netlist.zig");
const fp_mod = @import("../export_kicad_footprint.zig");
const model_mod = @import("../export_kicad_model.zig");
const bom = @import("../bom.zig");
const parser_mod = @import("../sexpr/parser.zig");
const env_mod_node = @import("../sexpr/ast.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

// ── Constants ─────────────────────────────────────────────────────
const HTTP_NOT_FOUND: u16 = 404;
const HTTP_BAD_REQUEST: u16 = 400;
const HTTP_NOT_MODIFIED: u16 = 304;
const HTTP_INTERNAL_ERROR: u16 = 500;
const MAX_FOOTPRINT_BYTES: usize = 1024 * 1024;
const MAX_STEP_FILE_BYTES: usize = 50 * 1024 * 1024;
const MAX_OBJECT_BYTES: usize = 100 * 1024 * 1024;
const HEADER_CACHE_CONTROL = "Cache-Control";
const HEADER_CORS_ALLOW_ORIGIN = "access-control-allow-origin";
const ERR_BUILD_ERROR = "Build error";
const ERR_NOT_A_DESIGN = "Not a design";
const PATH_FMT_SEXP = "{s}/src/{s}.sexp";
const PATH_FMT_BOM = "{s}/src/{s}.bom";
const PATH_FMT_FP_SEXP = "{s}/lib/footprints/{s}.sexp";
const OP_SET_FIELD = "set_field";

/// Error set for HTTP handlers in this module.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    std.fs.File.WriteError || std.fs.File.OpenError || std.fs.File.ReadError ||
    std.fs.Dir.MakeError || std.fs.Dir.StatFileError ||
    error{ FileTooBig, StreamTooLong, EndOfStream, InvalidEscapeSequence, NotOpenForReading, ReadOnlyFileSystem, LinkQuotaExceeded };

fn warnResolveIdentities(name: []const u8, err: anyerror) void {
    log.warn("resolveIdentities {s} failed: {s}", .{ name, @errorName(err) });
}

// ── Object cache ────────────────────────────────────────────────────────
// Populated by syncManifestApi; read by objectApi. A single mutex guards
// the map and all value strings (which are allocated with page_allocator
// to survive past the request that produced them).

const ObjectKind = enum { footprint, model };

const Object = struct {
    kind: ObjectKind,
    /// Footprints: raw .kicad_mod bytes. Models: absolute path on disk.
    data: []const u8,
};

var cache_mu: std.Thread.Mutex = .{};
var object_cache: std.StringHashMapUnmanaged(Object) = .empty;

fn cachePutFootprint(sha: []const u8, bytes: []const u8) void {
    cache_mu.lock();
    defer cache_mu.unlock();
    const alloc = std.heap.page_allocator;
    const key_dup = alloc.dupe(u8, sha) catch return;
    const val_dup = alloc.dupe(u8, bytes) catch return;
    const gop = object_cache.getOrPut(alloc, key_dup) catch return;
    if (gop.found_existing) {
        // Already cached — free our duplicates.
        alloc.free(key_dup);
        alloc.free(val_dup);
        return;
    }
    gop.value_ptr.* = .{ .kind = .footprint, .data = val_dup };
}

fn cachePutModel(sha: []const u8, path: []const u8) void {
    cache_mu.lock();
    defer cache_mu.unlock();
    const alloc = std.heap.page_allocator;
    const key_dup = alloc.dupe(u8, sha) catch return;
    const path_dup = alloc.dupe(u8, path) catch return;
    const gop = object_cache.getOrPut(alloc, key_dup) catch return;
    if (gop.found_existing) {
        alloc.free(key_dup);
        alloc.free(path_dup);
        return;
    }
    gop.value_ptr.* = .{ .kind = .model, .data = path_dup };
}

fn cacheGet(sha: []const u8) ?Object {
    cache_mu.lock();
    defer cache_mu.unlock();
    return object_cache.get(sha);
}

// ── Endpoints ──────────────────────────────────────────────────────────

/// GET /api/sync-manifest/:name — return the list of every footprint
/// (`.kicad_mod`) and STEP model the design references, each with a
/// content sha and size, so a remote sync client can `/api/object/:sha`
/// only the blobs it doesn't already cache locally.
pub fn syncManifestApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };

    const board_path = try std.fmt.allocPrint(ctx.allocator, PATH_FMT_SEXP, .{ ctx.project_dir, name });
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();

    const result = eval.evalFile(board_path) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = ERR_BUILD_ERROR;
        return;
    };
    const block = switch (result) {
        .design_block => |b| b,
        .board => |b| b.design,
        else => {
            res.status = HTTP_INTERNAL_ERROR;
            res.body = ERR_NOT_A_DESIGN;
            return;
        },
    };

    // Resolve BOM identities so footprint + mpn fields are populated — matches
    // what /api/export-netlist does.
    const bom_path = try std.fmt.allocPrint(ctx.allocator, PATH_FMT_BOM, .{ ctx.project_dir, name });
    defer ctx.allocator.free(bom_path);
    bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir) catch |e| warnResolveIdentities(name, e);

    // Flatten hierarchy to enumerate footprints actually used by instances.
    var instances: std.ArrayListUnmanaged(export_kicad.FlatInstance) = .empty;
    defer instances.deinit(ctx.allocator);
    try netlist_mod.collectInstances(ctx.allocator, block, "", &instances);

    var model_cfg = export_kicad.loadModelConfig(ctx.allocator, ctx.project_dir);
    defer model_cfg.deinit();

    // Manifest entries we'll emit.
    var fp_entries: std.ArrayListUnmanaged(FootprintEntry) = .empty;
    defer fp_entries.deinit(ctx.allocator);
    var model_entries: std.ArrayListUnmanaged(ModelEntry) = .empty;
    defer model_entries.deinit(ctx.allocator);

    var seen_fps = std.StringHashMap(void).init(ctx.allocator);
    defer seen_fps.deinit();
    var seen_models = std.StringHashMap(void).init(ctx.allocator);
    defer seen_models.deinit();

    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        if (seen_fps.contains(inst.footprint)) continue;
        try seen_fps.put(inst.footprint, {});

        const fp_path = try std.fmt.allocPrint(ctx.allocator, PATH_FMT_FP_SEXP, .{ ctx.project_dir, inst.footprint });
        defer ctx.allocator.free(fp_path);
        const fp_source = infra_fs.cwd().readFileAlloc(ctx.allocator, fp_path, MAX_FOOTPRINT_BYTES) catch continue;
        defer ctx.allocator.free(fp_source);

        const kicad_name = netlist_mod.extractFootprintName(ctx.allocator, fp_source) catch try ctx.allocator.dupe(u8, inst.footprint);

        const mcfg = model_cfg.get(inst.footprint);
        const model_name = if (mcfg) |c|
            (c.model orelse fp_mod.findModelFile(ctx.allocator, ctx.project_dir, inst.footprint, inst.component))
        else
            fp_mod.findModelFile(ctx.allocator, ctx.project_dir, inst.footprint, inst.component);

        const mod_bytes = model_mod.buildKicadMod(
            ctx.allocator,
            ctx.project_dir,
            inst.footprint,
            fp_source,
            model_name,
            if (mcfg) |c| c.offset else null,
            if (mcfg) |c| c.rotation else null,
        ) catch continue;
        defer ctx.allocator.free(mod_bytes);

        const sha = try sha256Hex(ctx.allocator, mod_bytes);
        try fp_entries.append(ctx.allocator, .{
            .kicad_name = try ctx.allocator.dupe(u8, kicad_name),
            .sha = sha,
            .size = mod_bytes.len,
        });
        cachePutFootprint(sha, mod_bytes);

        // Track the 3D model too. findModelFile may return a caller-owned
        // buffer (mcfg==null branch) — in that case free after dedup check.
        if (model_name) |mname| {
            const keep_mname = mcfg != null; // mcfg's string is owned by config map
            if (seen_models.contains(mname)) {
                if (!keep_mname) ctx.allocator.free(mname);
                continue;
            }
            try seen_models.put(try ctx.allocator.dupe(u8, mname), {});
            const step_path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/models/{s}", .{ ctx.project_dir, mname });
            defer ctx.allocator.free(step_path);
            const step_bytes = infra_fs.cwd().readFileAlloc(ctx.allocator, step_path, MAX_STEP_FILE_BYTES) catch {
                if (!keep_mname) ctx.allocator.free(mname);
                continue;
            };
            defer ctx.allocator.free(step_bytes);
            const step_sha = try sha256Hex(ctx.allocator, step_bytes);
            try model_entries.append(ctx.allocator, .{
                .name = try ctx.allocator.dupe(u8, mname),
                .sha = step_sha,
                .size = step_bytes.len,
            });
            cachePutModel(step_sha, step_path);
            if (!keep_mname) ctx.allocator.free(mname);
        }
    }

    // Netlist sha (bytes not cached here; netlistApi recomputes).
    const netlist = export_kicad.exportNetlistOnly(ctx.allocator, block, ctx.project_dir, name) catch "";
    defer if (netlist.len > 0) ctx.allocator.free(netlist);
    const netlist_sha = try sha256Hex(ctx.allocator, netlist);

    // ── Build response ─────────────────────────────────────────────────
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);

    const version = serve_root.getLiveVersion(name);
    try w.print("{{\"version\":{d},\"netlist\":{{\"sha\":\"{s}\",\"size\":{d}}},\"footprints\":[", .{ version, netlist_sha, netlist.len });
    for (fp_entries.items, 0..) |e, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"name\":", .{});
        try writeJsonString(w, e.kicad_name);
        try w.print(",\"sha\":\"{s}\",\"size\":{d}}}", .{ e.sha, e.size });
    }
    try w.writeAll("],\"models\":[");
    for (model_entries.items, 0..) |e, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try writeJsonString(w, e.name);
        try w.print(",\"sha\":\"{s}\",\"size\":{d}}}", .{ e.sha, e.size });
    }
    try w.writeAll("]}");

    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.body = buf.items;
}

/// GET /api/sync-netlist/:name — same payload as `exportNetlistApi` but
/// adds a content-hash `ETag` and honours `If-None-Match` (returns 304)
/// so a client polling for changes only re-downloads when the netlist
/// has actually mutated.
pub fn netlistApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };

    const board_path = try std.fmt.allocPrint(ctx.allocator, PATH_FMT_SEXP, .{ ctx.project_dir, name });
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    const result = eval.evalFile(board_path) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = ERR_BUILD_ERROR;
        return;
    };
    const block = switch (result) {
        .design_block => |b| b,
        .board => |b| b.design,
        else => {
            res.status = HTTP_INTERNAL_ERROR;
            res.body = ERR_NOT_A_DESIGN;
            return;
        },
    };

    const bom_path = try std.fmt.allocPrint(ctx.allocator, PATH_FMT_BOM, .{ ctx.project_dir, name });
    defer ctx.allocator.free(bom_path);
    bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir) catch |e| warnResolveIdentities(name, e);

    const netlist = export_kicad.exportNetlistOnly(ctx.allocator, block, ctx.project_dir, name) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "Export error";
        return;
    };

    const sha = try sha256Hex(ctx.allocator, netlist);
    // ETag values are quoted per RFC 7232.
    const etag = try std.fmt.allocPrint(ctx.allocator, "\"{s}\"", .{sha});

    // Conditional GET: match against If-None-Match.
    if (req.header("if-none-match")) |inm| {
        if (std.mem.eql(u8, std.mem.trim(u8, inm, " "), etag)) {
            res.status = HTTP_NOT_MODIFIED;
            res.header("ETag", etag);
            res.header(HEADER_CACHE_CONTROL, "no-cache");
            return;
        }
    }

    res.header("Content-Type", "text/plain; charset=utf-8");
    res.header("ETag", etag);
    res.header(HEADER_CACHE_CONTROL, "no-cache");
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.body = netlist;
}

/// GET /api/object/:sha — content-addressed fetch for any footprint or
/// STEP model the most recent `syncManifestApi` call advertised. Rejects
/// non-hex shas to block path-traversal attempts on the cache.
pub fn objectApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const sha = req.param("sha") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };
    // Guard against path traversal — sha should be pure hex.
    for (sha) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) {
            res.status = HTTP_BAD_REQUEST;
            res.body = "invalid sha";
            return;
        }
    }

    const obj = cacheGet(sha) orelse {
        res.status = HTTP_NOT_FOUND;
        res.body = "unknown object (fetch /api/sync-manifest first)";
        return;
    };

    const bytes: []const u8 = switch (obj.kind) {
        .footprint => obj.data,
        .model => blk: {
            const data = infra_fs.cwd().readFileAlloc(ctx.allocator, obj.data, MAX_OBJECT_BYTES) catch {
                res.status = HTTP_INTERNAL_ERROR;
                res.body = "model read error";
                return;
            };
            break :blk data;
        },
    };

    // Content-addressed: the bytes for a given sha are immutable forever.
    const etag = try std.fmt.allocPrint(ctx.allocator, "\"{s}\"", .{sha});
    res.header("Content-Type", "application/octet-stream");
    res.header("ETag", etag);
    res.header(HEADER_CACHE_CONTROL, "public, max-age=31536000, immutable");
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.body = bytes;
}

// ── /api/sync-plan ──────────────────────────────────────────────────────
//
// Server-side diff for the Go sync agent. The client POSTs the current
// state of footprints on the open KiCad PCB; the server compares against
// the design's flattened netlist and returns a list of ops the client
// should apply (set_field / set_pad_net / add / swap_footprint / remove /
// flag_stale). New/swap ops carry their `.kicad_mod` text inline so the
// client never needs the `/api/object/:sha` fetch step.
//
// Companion to `tools/kicad-sync-go/`.

const PadAssign = struct { number: []const u8, net: []const u8 };

const BoardFp = struct {
    uuid: []const u8,
    ref: []const u8,
    value: []const u8,
    footprint_name: []const u8,
    pads: []const PadAssign,
};

const ParsedSyncPlan = struct {
    board: []const BoardFp,
    prune_stale: bool,
};

fn parsePadList(arena: std.mem.Allocator, pv: std.json.Value) std.mem.Allocator.Error![]const PadAssign {
    var pads_list: std.ArrayListUnmanaged(PadAssign) = .empty;
    if (pv != .array) return pads_list.items;
    for (pv.array.items) |p| {
        if (p != .object) continue;
        const num = jsonStr(p.object.get("number"));
        if (num.len == 0) continue;
        try pads_list.append(arena, .{ .number = num, .net = jsonStr(p.object.get("net")) });
    }
    return pads_list.items;
}

fn parseBoardEntry(arena: std.mem.Allocator, entry: std.json.Value) std.mem.Allocator.Error!?BoardFp {
    if (entry != .object) return null;
    const o = entry.object;
    const pads = if (o.get("pads")) |pv| try parsePadList(arena, pv) else &[_]PadAssign{};
    return BoardFp{
        .uuid = jsonStr(o.get("uuid")),
        .ref = jsonStr(o.get("ref")),
        .value = jsonStr(o.get("value")),
        .footprint_name = jsonStr(o.get("footprint_name")),
        .pads = pads,
    };
}

fn parseSyncPlanBody(arena: std.mem.Allocator, body: []const u8) !ParsedSyncPlan {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
    if (parsed.value != .object) return error.NotObject;

    const prune_stale = blk: {
        const v = parsed.value.object.get("prune_stale") orelse break :blk false;
        break :blk v == .bool and v.bool;
    };

    var board_list: std.ArrayListUnmanaged(BoardFp) = .empty;
    const bv = parsed.value.object.get("board") orelse {
        return .{ .board = board_list.items, .prune_stale = prune_stale };
    };
    if (bv != .array) return .{ .board = board_list.items, .prune_stale = prune_stale };

    for (bv.array.items) |entry| {
        const fp = (try parseBoardEntry(arena, entry)) orelse continue;
        try board_list.append(arena, fp);
    }
    return .{ .board = board_list.items, .prune_stale = prune_stale };
}

fn jsonStr(v: ?std.json.Value) []const u8 {
    const val = v orelse return "";
    return if (val == .string) val.string else "";
}

/// Strip the `lib:` prefix that netlist footprint specs carry (`"lib:R_0402"`
/// → `"R_0402"`). Inputs without a prefix pass through unchanged.
fn stripLibPrefix(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, ':')) |idx| return s[idx + 1 ..];
    return s;
}

const SyncPlanContext = struct {
    arena: std.mem.Allocator,
    project_dir: []const u8,
    model_cfg: *export_kicad.ModelConfigMap,
};

/// Build the `.kicad_mod` text the client needs to instantiate `fp_name`.
/// Returned slice is owned by `arena`; caller does not free explicitly.
fn loadKicadMod(
    spc: *SyncPlanContext,
    fp_name: []const u8,
    component: []const u8,
) ?[]const u8 {
    const fp_path = std.fmt.allocPrint(spc.arena, PATH_FMT_FP_SEXP, .{ spc.project_dir, fp_name }) catch return null;
    const fp_source = infra_fs.cwd().readFileAlloc(spc.arena, fp_path, MAX_FOOTPRINT_BYTES) catch return null;
    const mcfg = spc.model_cfg.get(fp_name);
    const model_name = if (mcfg) |c|
        (c.model orelse fp_mod.findModelFile(spc.arena, spc.project_dir, fp_name, component))
    else
        fp_mod.findModelFile(spc.arena, spc.project_dir, fp_name, component);
    return model_mod.buildKicadMod(
        spc.arena,
        spc.project_dir,
        fp_name,
        fp_source,
        model_name,
        if (mcfg) |c| c.offset else null,
        if (mcfg) |c| c.rotation else null,
    ) catch null;
}

/// Build a structured JSON description of `fp_name` for the Go IPC agent.
/// Returns the JSON text or null when no `.sexp` source exists (vendor-only
/// footprints in `lib/sources/` aren't covered by v2). The JSON shape:
///
///   {"name":"R_0402","pads":[{"number":"1","type":"smd","shape":"rect",
///                              "pos":[x,y],"size":[w,h],"rotation":N,
///                              "drill":D,"layers":["F.Cu",...]}, ...]}
///
/// All distances in mm. Layers default to standard SMD/thru-hole sets when
/// the source doesn't list them explicitly.
fn loadFootprintDef(
    spc: *SyncPlanContext,
    fp_name: []const u8,
) ?[]const u8 {
    return loadFootprintDefImpl(spc, fp_name) catch null;
}

fn loadFootprintDefImpl(
    spc: *SyncPlanContext,
    fp_name: []const u8,
) !?[]const u8 {
    const fp_path = try std.fmt.allocPrint(spc.arena, PATH_FMT_FP_SEXP, .{ spc.project_dir, fp_name });
    const fp_source = infra_fs.cwd().readFileAlloc(spc.arena, fp_path, MAX_FOOTPRINT_BYTES) catch return null;

    const nodes = parser_mod.parse(spc.arena, fp_source) catch return null;
    if (nodes.len == 0 or !nodes[0].isForm("footprint")) return null;
    const children = nodes[0].asList() orelse return null;
    if (children.len < 2) return null;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(spc.arena);
    try w.writeAll("{\"name\":");
    try writeJsonString(w, fp_name);
    try w.writeAll(",\"pads\":[");
    var first_pad = true;
    for (children[2..]) |child| {
        if (!child.isForm("pad")) continue;
        try writePadJson(spc.arena, w, child, &first_pad);
    }
    try w.writeAll("]}");
    return buf.items;
}

/// Emit one pad entry as JSON. Schema:
///   {"number":"1","type":"smd","shape":"roundrect",
///    "pos":[x,y],"size":[w,h],"rotation":N,"drill":D,"layers":[...]}
/// Mirrors the field names the Go agent expects in eda.FootprintPad.
fn writePadJson(arena: std.mem.Allocator, w: anytype, pad: env_mod_node.Node, first: *bool) !void {
    const nodes = pad.asList() orelse return;
    if (nodes.len < 4) return;
    // (pad <num> <type> <shape> ...)
    const num = padNumberText(arena, nodes[1]) orelse return;
    const ptype = nodes[2].asAtom() orelse return;
    const shape = nodes[3].asAtom() orelse return;

    var pos_x: f64 = 0;
    var pos_y: f64 = 0;
    var pos_rot: f64 = 0;
    var size_w: f64 = 0;
    var size_h: f64 = 0;
    var drill_d: f64 = 0;

    for (nodes[4..]) |n| {
        if (n.isForm("pos")) {
            const pl = n.asList().?;
            if (pl.len >= 3) {
                pos_x = pl[1].asNumber() orelse 0;
                pos_y = pl[2].asNumber() orelse 0;
            }
            if (pl.len >= 4) pos_rot = pl[3].asNumber() orelse 0;
        } else if (n.isForm("size")) {
            const sl = n.asList().?;
            if (sl.len >= 3) {
                size_w = sl[1].asNumber() orelse 0;
                size_h = sl[2].asNumber() orelse 0;
            }
        } else if (n.isForm("drill")) {
            const dl = n.asList().?;
            if (dl.len >= 2) drill_d = dl[1].asNumber() orelse 0;
        }
    }

    if (!first.*) try w.writeAll(",");
    first.* = false;
    // Normalise the EDA-format short type names into KiCad-format full names
    // so the Go agent gets a stable vocabulary.
    const ptype_norm = if (std.mem.eql(u8, ptype, "thru")) "thru_hole" else if (std.mem.eql(u8, ptype, "np_thru")) "np_thru_hole" else ptype;
    try w.writeAll("{\"number\":");
    try writeJsonString(w, num);
    try w.writeAll(",\"type\":");
    try writeJsonString(w, ptype_norm);
    try w.writeAll(",\"shape\":");
    try writeJsonString(w, shape);
    try w.print(",\"pos\":[{d},{d}]", .{ pos_x, pos_y });
    try w.print(",\"size\":[{d},{d}]", .{ size_w, size_h });
    if (pos_rot != 0) try w.print(",\"rotation\":{d}", .{pos_rot});
    if (drill_d != 0) try w.print(",\"drill\":{d}", .{drill_d});

    // Default layer sets — the EDA `.sexp` format doesn't carry them per-pad.
    if (std.mem.eql(u8, ptype_norm, "smd")) {
        try w.writeAll(",\"layers\":[\"F.Cu\",\"F.Paste\",\"F.Mask\"]");
    } else {
        // thru_hole, np_thru_hole — multilayer.
        try w.writeAll(",\"layers\":[\"F.Cu\",\"B.Cu\",\"F.Mask\",\"B.Mask\"]");
    }
    try w.writeAll("}");
}

/// Pad numbers in EDA `.sexp` come in three flavors:
///   - bare digit token  (1, 2, …) — parsed as `int` by the sexpr parser
///   - bare alphanumeric (MP1, A1) — parsed as `atom`
///   - quoted             ("1A")    — parsed as `string`
/// Normalise all three to a heap-allocated text slice.
fn padNumberText(arena: std.mem.Allocator, n: env_mod_node.Node) ?[]const u8 {
    if (n.asAtom()) |a| return a;
    if (n.asString()) |s| return s;
    switch (n.tag) {
        .int => |i| return std.fmt.allocPrint(arena, "{d}", .{i}) catch null,
        else => return null,
    }
}

const SyncSummary = struct {
    updated: u32 = 0,
    added: u32 = 0,
    removed: u32 = 0,
    swapped: u32 = 0,
    flagged_stale: u32 = 0,
};

/// POST /api/sync-plan/:name — compare client board state against the
/// design's flattened netlist and return ops to apply. Auth-gated by
/// the same OAuth/plugin-token check used for the manifest endpoints.
pub fn syncPlanApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };
    const body = req.body() orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "missing body";
        return;
    };

    const parsed = parseSyncPlanBody(req.arena, body) catch {
        res.status = HTTP_BAD_REQUEST;
        res.body = "invalid request body";
        return;
    };

    const board_path = try std.fmt.allocPrint(req.arena, PATH_FMT_SEXP, .{ ctx.project_dir, name });
    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    const result = eval.evalFile(board_path) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = ERR_BUILD_ERROR;
        return;
    };
    const block = switch (result) {
        .design_block => |b| b,
        .board => |b| b.design,
        else => {
            res.status = HTTP_INTERNAL_ERROR;
            res.body = ERR_NOT_A_DESIGN;
            return;
        },
    };

    const bom_path = try std.fmt.allocPrint(req.arena, PATH_FMT_BOM, .{ ctx.project_dir, name });
    bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir) catch |e| warnResolveIdentities(name, e);

    var instances: std.ArrayListUnmanaged(export_kicad.FlatInstance) = .empty;
    try netlist_mod.collectInstances(req.arena, block, "", &instances);
    var nets: std.ArrayListUnmanaged(export_kicad.FlatNet) = .empty;
    try export_kicad.flattenAndMergeNets(req.arena, block, &nets);

    // (ref, pin) -> net_name. Empty net names are excluded (NC pads).
    var pad_net_map = std.StringHashMap([]const u8).init(req.arena);
    for (nets.items) |net| {
        if (net.name.len == 0) continue;
        for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(req.arena, "{s}|{s}", .{ pin.ref_des, pin.pin });
            try pad_net_map.put(key, net.name);
        }
    }

    var by_uuid = std.StringHashMap(BoardFp).init(req.arena);
    var by_ref = std.StringHashMap(BoardFp).init(req.arena);
    for (parsed.board) |bfp| {
        if (bfp.uuid.len > 0) try by_uuid.put(bfp.uuid, bfp);
        if (bfp.ref.len > 0) try by_ref.put(bfp.ref, bfp);
    }

    var model_cfg = export_kicad.loadModelConfig(req.arena, ctx.project_dir);
    defer model_cfg.deinit();
    var spc = SyncPlanContext{ .arena = req.arena, .project_dir = ctx.project_dir, .model_cfg = &model_cfg };

    var ops_buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = ops_buf.writer(req.arena);
    var first_op = true;
    var summary = SyncSummary{};
    var matched_uuids = std.StringHashMap(void).init(req.arena);

    try w.writeAll("[");

    var diff_ctx = DiffContext{
        .by_uuid = &by_uuid,
        .by_ref = &by_ref,
        .pad_net_map = &pad_net_map,
        .matched_uuids = &matched_uuids,
        .spc = &spc,
        .summary = &summary,
    };
    for (instances.items) |inst| try handleInstance(&diff_ctx, inst, &w, &first_op);

    // Stale: anything in `parsed.board` with a uuid not in the netlist.
    for (parsed.board) |bfp| {
        if (bfp.uuid.len == 0) continue;
        if (matched_uuids.contains(bfp.uuid)) continue;
        if (parsed.prune_stale) {
            try emitOp(&w, &first_op, "remove", .{.{ "uuid", bfp.uuid }});
            summary.removed += 1;
        } else {
            try emitOp(&w, &first_op, "flag_stale", .{ .{ "uuid", bfp.uuid }, .{ "ref", bfp.ref } });
            summary.flagged_stale += 1;
        }
    }

    try w.writeAll("]");

    // Final response envelope.
    var resp_buf: std.ArrayListUnmanaged(u8) = .empty;
    const rw = resp_buf.writer(ctx.allocator);
    const version = serve_root.getLiveVersion(name);
    try rw.print(
        "{{\"design_version\":{d},\"summary\":{{\"updated\":{d},\"added\":{d},\"removed\":{d},\"swapped\":{d},\"flagged_stale\":{d}}},\"ops\":",
        .{ version, summary.updated, summary.added, summary.removed, summary.swapped, summary.flagged_stale },
    );
    try rw.writeAll(ops_buf.items);
    try rw.writeAll("}");

    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.body = resp_buf.items;
}

const DiffContext = struct {
    by_uuid: *std.StringHashMap(BoardFp),
    by_ref: *std.StringHashMap(BoardFp),
    pad_net_map: *std.StringHashMap([]const u8),
    matched_uuids: *std.StringHashMap(void),
    spc: *SyncPlanContext,
    summary: *SyncSummary,
};

fn matchInstance(d: *DiffContext, inst: export_kicad.FlatInstance, w: anytype, first: *bool) !?BoardFp {
    if (d.by_uuid.get(inst.uuid)) |m| return m;
    if (inst.ref_des.len == 0) return null;
    const m = d.by_ref.get(inst.ref_des) orelse return null;
    if (m.uuid.len == 0) {
        try emitOp(w, first, OP_SET_FIELD, .{
            .{ "uuid", m.uuid },
            .{ "field", "canopy_uuid" },
            .{ "value", inst.uuid },
        });
    }
    return m;
}

fn handleMatched(d: *DiffContext, inst: export_kicad.FlatInstance, m: BoardFp, fp_name_short: []const u8, w: anytype, first: *bool) !void {
    if (m.uuid.len > 0) try d.matched_uuids.put(m.uuid, {});
    if (!std.mem.eql(u8, m.footprint_name, fp_name_short)) {
        if (loadKicadMod(d.spc, fp_name_short, inst.component)) |kmod| {
            const fp_def = loadFootprintDef(d.spc, fp_name_short);
            try emitSwapOp(w, first, m.uuid, fp_name_short, kmod, fp_def, inst.ref_des, d.pad_net_map);
            d.summary.swapped += 1;
        }
    }
    if (!std.mem.eql(u8, m.ref, inst.ref_des)) {
        try emitOp(w, first, OP_SET_FIELD, .{
            .{ "uuid", inst.uuid },
            .{ "field", "reference" },
            .{ "value", inst.ref_des },
        });
    }
    if (!std.mem.eql(u8, m.value, inst.value)) {
        try emitOp(w, first, OP_SET_FIELD, .{
            .{ "uuid", inst.uuid },
            .{ "field", "value" },
            .{ "value", inst.value },
        });
    }
    try emitPadNetOps(w, first, inst.uuid, inst.ref_des, d.pad_net_map, m.pads);
    d.summary.updated += 1;
}

fn handleInstance(d: *DiffContext, inst: export_kicad.FlatInstance, w: anytype, first: *bool) !void {
    const fp_name_short = stripLibPrefix(inst.footprint);
    if (try matchInstance(d, inst, w, first)) |m| {
        try handleMatched(d, inst, m, fp_name_short, w, first);
        return;
    }
    const kmod = loadKicadMod(d.spc, fp_name_short, inst.component) orelse return;
    const fp_def = loadFootprintDef(d.spc, fp_name_short);
    try emitAddOp(w, first, inst, fp_name_short, kmod, fp_def, d.pad_net_map);
    d.summary.added += 1;
}

fn emitOp(w: anytype, first: *bool, op: []const u8, fields: anytype) !void {
    if (!first.*) try w.*.writeAll(",");
    first.* = false;
    try w.*.writeAll("{\"op\":\"");
    try w.*.writeAll(op);
    try w.*.writeAll("\"");
    inline for (fields) |kv| {
        try w.*.writeAll(",");
        try w.*.print("\"{s}\":", .{kv[0]});
        try writeJsonString(w.*, kv[1]);
    }
    try w.*.writeAll("}");
}

fn emitAddOp(
    w: anytype,
    first: *bool,
    inst: export_kicad.FlatInstance,
    fp_name: []const u8,
    kmod: []const u8,
    fp_def_json: ?[]const u8,
    pad_net_map: *std.StringHashMap([]const u8),
) !void {
    if (!first.*) try w.*.writeAll(",");
    first.* = false;
    try w.*.writeAll("{\"op\":\"add\",\"uuid\":");
    try writeJsonString(w.*, inst.uuid);
    try w.*.writeAll(",\"ref\":");
    try writeJsonString(w.*, inst.ref_des);
    try w.*.writeAll(",\"value\":");
    try writeJsonString(w.*, inst.value);
    try w.*.writeAll(",\"footprint_name\":");
    try writeJsonString(w.*, fp_name);
    try w.*.writeAll(",\"kicad_mod\":");
    try writeJsonString(w.*, kmod);
    if (fp_def_json) |def| {
        try w.*.writeAll(",\"footprint_def\":");
        try w.*.writeAll(def);
    }
    try w.*.writeAll(",\"pad_nets\":");
    try writePadNetsArray(w.*, inst.ref_des, pad_net_map);
    try w.*.writeAll("}");
}

fn emitSwapOp(
    w: anytype,
    first: *bool,
    uuid: []const u8,
    fp_name: []const u8,
    kmod: []const u8,
    fp_def_json: ?[]const u8,
    ref_des: []const u8,
    pad_net_map: *std.StringHashMap([]const u8),
) !void {
    if (!first.*) try w.*.writeAll(",");
    first.* = false;
    try w.*.writeAll("{\"op\":\"swap_footprint\",\"uuid\":");
    try writeJsonString(w.*, uuid);
    try w.*.writeAll(",\"new_footprint_name\":");
    try writeJsonString(w.*, fp_name);
    try w.*.writeAll(",\"kicad_mod\":");
    try writeJsonString(w.*, kmod);
    if (fp_def_json) |def| {
        try w.*.writeAll(",\"footprint_def\":");
        try w.*.writeAll(def);
    }
    try w.*.writeAll(",\"pad_nets\":");
    try writePadNetsArray(w.*, ref_des, pad_net_map);
    try w.*.writeAll("}");
}

/// Emit one `set_pad_net` op per pad whose net assignment differs from
/// what the client reported. Pads only on one side (e.g. NC pads or pads
/// the client didn't list) are skipped.
fn emitPadNetOps(
    w: anytype,
    first: *bool,
    uuid: []const u8,
    ref_des: []const u8,
    pad_net_map: *std.StringHashMap([]const u8),
    client_pads: []const PadAssign,
) !void {
    var key_buf: [256]u8 = undefined;
    for (client_pads) |cp| {
        const key = std.fmt.bufPrint(&key_buf, "{s}|{s}", .{ ref_des, cp.number }) catch continue;
        const want = pad_net_map.get(key) orelse continue;
        if (std.mem.eql(u8, want, cp.net)) continue;
        try emitOp(w, first, "set_pad_net", .{
            .{ "uuid", uuid },
            .{ "pad", cp.number },
            .{ "net", want },
        });
    }
}

fn writePadNetsArray(
    w: anytype,
    ref_des: []const u8,
    pad_net_map: *std.StringHashMap([]const u8),
) !void {
    try w.writeAll("[");
    var it = pad_net_map.iterator();
    var first = true;
    while (it.next()) |entry| {
        // Keys have shape "ref|pin"; filter to this ref_des.
        const k = entry.key_ptr.*;
        const sep = std.mem.indexOfScalar(u8, k, '|') orelse continue;
        if (!std.mem.eql(u8, k[0..sep], ref_des)) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("[");
        try writeJsonString(w, k[sep + 1 ..]);
        try w.writeAll(",");
        try writeJsonString(w, entry.value_ptr.*);
        try w.writeAll("]");
    }
    try w.writeAll("]");
}

// ── helpers ─────────────────────────────────────────────────────────────

const FootprintEntry = struct {
    kicad_name: []const u8,
    sha: []const u8,
    size: usize,
};

const ModelEntry = struct {
    name: []const u8,
    sha: []const u8,
    size: usize,
};

fn sha256Hex(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(input, &digest, .{});
    const hex = "0123456789abcdef";
    var out = try allocator.alloc(u8, 64);
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out;
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{ch}),
        else => try w.writeByte(ch),
    };
    try w.writeAll("\"");
}
