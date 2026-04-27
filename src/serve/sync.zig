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

    const board_path = try std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.sexp", .{ ctx.project_dir, name });
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();

    const result = eval.evalFile(board_path) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "Build error";
        return;
    };
    const block = switch (result) {
        .design_block => |b| b,
        .board => |b| b.design,
        else => {
            res.status = HTTP_INTERNAL_ERROR;
            res.body = "Not a design";
            return;
        },
    };

    // Resolve BOM identities so footprint + mpn fields are populated — matches
    // what /api/export-netlist does.
    const bom_path = try std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.bom", .{ ctx.project_dir, name });
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

        const fp_path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/footprints/{s}.sexp", .{ ctx.project_dir, inst.footprint });
        defer ctx.allocator.free(fp_path);
        const fp_source = infra_fs.cwd().readFileAlloc(ctx.allocator, fp_path, MAX_FOOTPRINT_BYTES) catch continue;
        defer ctx.allocator.free(fp_source);

        const kicad_name = netlist_mod.extractFootprintName(ctx.allocator, fp_source) catch try ctx.allocator.dupe(u8, inst.footprint);

        const mcfg = model_cfg.get(inst.footprint);
        const model_name = if (mcfg) |c| (c.model orelse fp_mod.findModelFile(ctx.allocator, ctx.project_dir, inst.footprint, inst.component)) else fp_mod.findModelFile(ctx.allocator, ctx.project_dir, inst.footprint, inst.component);

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

    const board_path = try std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.sexp", .{ ctx.project_dir, name });
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    const result = eval.evalFile(board_path) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "Build error";
        return;
    };
    const block = switch (result) {
        .design_block => |b| b,
        .board => |b| b.design,
        else => {
            res.status = HTTP_INTERNAL_ERROR;
            res.body = "Not a design";
            return;
        },
    };

    const bom_path = try std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.bom", .{ ctx.project_dir, name });
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
