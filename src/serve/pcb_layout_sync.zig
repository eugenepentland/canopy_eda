//! Inbound KiCad layout sync for the PCB editor. The endpoint evaluates the
//! named design, opens its declared `(kicad-pcb ...)` file read-only, and runs
//! the same pure importer as `netlisp import-kicad-layout`. A dry run returns a
//! complete accounting report; an apply replaces the design's single starred
//! layout after an optimistic-revision check and snapshots the old sidecar.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const paths = @import("../paths.zig");
const json_writer = @import("../json_writer.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const env_mod = @import("../eval/env.zig");
const eval_modules = @import("../eval/modules.zig");
const export_kicad = @import("../export_kicad.zig");
const export_kicad_netlist = @import("../export_kicad_netlist.zig");
const optimizer = @import("../placement/optimizer.zig");
const snapshot = @import("../kicad_pcb/snapshot.zig");
const import_layout = @import("../kicad_pcb/import_layout.zig");
const import_layout_json = @import("../kicad_pcb/import_layout_json.zig");
const pcb_layout_import = @import("pcb_layout_import.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const history = @import("history.zig");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;

const board_max_bytes: usize = 64 * 1024 * 1024;

const ImportedBoard = struct {
    board_path: []const u8,
    imported: import_layout.Imported,
};

const RequestBody = struct {
    rev: ?i64 = null,
};

/// Router-facing callable without growing the repository's public function
/// API: the HTTP seam is registered by `serve.zig`, not a library contract.
pub const importKicadLayoutApi = importKicadLayoutApiImpl;

fn importKicadLayoutApiImpl(
    ctx: *Server,
    req: *httpz.Request,
    res: *httpz.Response,
) pcb_layout_page.HandlerError!void {
    const name = req.param("name") orelse return jsonErrorAlloc(req, res, 404, "design not found");
    const body = parseRequest(req) orelse return jsonErrorAlloc(req, res, 400, "invalid JSON body");
    const dry_run = queryFlag(req, "dry_run");
    const disk_rev = pcb_layout_page.readLayoutRev(req.arena, ctx.project_dir, name, null);
    if (!dry_run) if (body.rev) |rev| {
        if (rev != disk_rev) return writeConflict(req, res, disk_rev);
    };

    var eval = Evaluator.init(req.arena, ctx.project_dir);
    defer eval.deinit();
    const loaded = loadImportedBoard(req.arena, &eval, ctx.project_dir, name) catch |err| {
        return importError(req, res, &eval, err);
    };

    var written = false;
    var new_rev = disk_rev;
    if (!dry_run) {
        snapshotExistingLayout(req.arena, ctx.project_dir, name);
        written = pcb_layout_import.writeImportedStarredLayout(
            req.arena,
            ctx.project_dir,
            name,
            loaded.imported,
        );
        if (!written) return jsonErrorAlloc(req, res, 500, "could not write the imported layout");
        new_rev = pcb_layout_page.readLayoutRev(req.arena, ctx.project_dir, name, null);
        _ = serve_root.bumpLiveVersion(name);
    }
    try writeResponse(req, res, .{
        .name = name,
        .loaded = loaded,
        .dry_run = dry_run,
        .written = written,
        .rev = new_rev,
    });
}

fn parseRequest(req: *httpz.Request) ?RequestBody {
    const source = req.body() orelse return .{};
    if (std.mem.trim(u8, source, " \t\r\n").len == 0) return .{};
    return std.json.parseFromSliceLeaky(RequestBody, req.arena, source, .{
        .ignore_unknown_fields = true,
    }) catch null;
}

fn queryFlag(req: *httpz.Request, key: []const u8) bool {
    const q = req.query() catch return false;
    return q.get(key) != null;
}

fn loadImportedBoard(
    arena: std.mem.Allocator,
    eval: *Evaluator,
    project_dir: []const u8,
    name: []const u8,
) anyerror!ImportedBoard {
    const source_path = try paths.designSourcePath(arena, project_dir, name);
    const value = try eval.evalFile(source_path);
    const block = switch (value) {
        .design_block => |design| design,
        else => blk: {
            const standalone = try eval_modules.instantiateStandalone(eval, name);
            break :blk switch (standalone) {
                .design_block => |design| design,
                else => return error.NotDesign,
            };
        },
    };
    const board_path = block.kicad_pcb_path orelse return error.MissingKicadPcb;
    const board_source = try infra_fs.cwd().readFileAlloc(arena, board_path, board_max_bytes);
    const board = try snapshot.parse(arena, board_source);

    var instances: std.ArrayList(export_kicad.FlatInstance) = .empty;
    try export_kicad_netlist.collectInstances(arena, block, "", &instances);
    var nets: std.ArrayList(export_kicad.FlatNet) = .empty;
    try export_kicad.flattenAndMergeNets(arena, block, &nets);
    const imported = try import_layout.build(arena, .{
        .board = board,
        .instances = instances.items,
        .nets = nets.items,
        .rules = try boardRulesFor(arena, block),
    }, .{});
    return .{ .board_path = board_path, .imported = imported };
}

/// The layer-map slice of the design's board rules, for the importer's
/// signal-layer naming alone (`signalLayerCount` / `signalLayerName`). No
/// implicit rail plane: naming a layer never asks what a plane carries.
fn boardRulesFor(
    arena: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
) std.mem.Allocator.Error!optimizer.BoardRules {
    if (!block.stackup.present) return .{};
    const planes = try arena.alloc(optimizer.PlaneAt, block.stackup.planes.len);
    const plane_nets = try arena.alloc([]const u8, block.stackup.planes.len);
    for (block.stackup.planes, planes, plane_nets) |declared, *plane, *net| {
        plane.* = .{ .index = declared.index, .net = declared.net };
        net.* = declared.net;
    }
    return .{
        .plane_nets = plane_nets,
        .copper_layers = block.stackup.layers,
        .planes = .{ .declared = planes },
    };
}

fn snapshotExistingLayout(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) void {
    const sidecar = paths.designSiblingPath(
        arena,
        project_dir,
        name,
        pcb_layout_page.layouts_ext,
    ) catch return;
    _ = history.snapshotLayouts(arena, project_dir, name, sidecar) catch null;
}

fn importError(
    req: *httpz.Request,
    res: *httpz.Response,
    eval: *const Evaluator,
    err: anyerror,
) pcb_layout_page.HandlerError!void {
    const status: u16 = switch (err) {
        error.InvalidName => 404,
        error.MissingKicadPcb, error.NotDesign => 400,
        error.FileNotFound => 404,
        error.FileTooBig, error.StreamTooLong => 413,
        error.InvalidPcbRoot,
        error.UnexpectedEof,
        error.UnexpectedRparen,
        error.UnexpectedCharacter,
        error.UnterminatedString,
        error.InvalidNumber,
        error.TooDeep,
        => 422,
        else => 500,
    };
    const message = switch (err) {
        error.MissingKicadPcb => "design has no (kicad-pcb \"...\") sync target",
        error.NotDesign => "source did not evaluate to a design",
        error.FileNotFound => "KiCad PCB file was not found",
        error.FileTooBig, error.StreamTooLong => "KiCad PCB file is larger than 64 MiB",
        error.InvalidPcbRoot => "file is not a KiCad PCB",
        else => if (eval.last_error) |diag| diag.message else @errorName(err),
    };
    try jsonErrorAlloc(req, res, status, message);
}

fn jsonErrorAlloc(
    req: *httpz.Request,
    res: *httpz.Response,
    status: u16,
    message: []const u8,
) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    var out: std.Io.Writer.Allocating = .init(req.arena);
    const w = &out.writer;
    try w.writeAll("{\"ok\":false,\"error\":");
    try json_writer.writeString(w, message);
    try w.writeByte('}');
    res.status = status;
    res.content_type = .JSON;
    res.body = out.written();
}

fn writeConflict(
    req: *httpz.Request,
    res: *httpz.Response,
    rev: i64,
) pcb_layout_page.HandlerError!void {
    res.status = 409;
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(
        req.arena,
        "{{\"ok\":false,\"error\":\"layout changed; reload before syncing\",\"rev\":{d}}}",
        .{rev},
    );
}

const ResponseInput = struct {
    name: []const u8,
    loaded: ImportedBoard,
    dry_run: bool,
    written: bool,
    rev: i64,
};

fn writeResponse(
    req: *httpz.Request,
    res: *httpz.Response,
    input: ResponseInput,
) pcb_layout_page.HandlerError!void {
    var out: std.Io.Writer.Allocating = .init(req.arena);
    const w = &out.writer;
    try writeResponseJson(w, input);
    res.content_type = .JSON;
    res.body = out.written();
}

fn writeResponseJson(w: anytype, input: ResponseInput) json_writer.WriteError!void {
    try w.writeAll("{\"ok\":true,\"design\":");
    try json_writer.writeString(w, input.name);
    try w.writeAll(",\"board_path\":");
    try json_writer.writeString(w, input.loaded.board_path);
    try w.print(
        ",\"dry_run\":{},\"written\":{},\"rev\":{d},\"stats\":" ++
            "{{\"parts\":{d},\"tracks\":{d},\"vias\":{d}," ++
            "\"outline_points\":{d}}},\"report\":",
        .{
            input.dry_run,
            input.written,
            input.rev,
            input.loaded.imported.poses.len,
            input.loaded.imported.tracks.len,
            input.loaded.imported.vias.len,
            input.loaded.imported.outline.pts.len,
        },
    );
    try import_layout_json.writeReport(w, input.loaded.imported.report);
    try w.writeByte('}');
}

// spec: kicad_pcb/import-layout - the inbound HTTP preview reports geometry without claiming it was written
test "inbound KiCad layout response carries preview stats" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const imported = import_layout.Imported{
        .poses = &.{.{ .ref = "U1", .origin = "u1" }},
        .tracks = &.{.{ .net = "SIG" }},
        .vias = &.{.{ .net = "SIG" }},
        .outline = .{ .pts = &.{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 3 }, .{ 0, 3 } } },
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    try writeResponseJson(&out.writer, .{
        .name = "demo",
        .loaded = .{ .board_path = "/tmp/demo.kicad_pcb", .imported = imported },
        .dry_run = true,
        .written = false,
        .rev = 7,
    });
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    try std.testing.expect(parsed.object.get("dry_run").?.bool);
    try std.testing.expect(!parsed.object.get("written").?.bool);
    try std.testing.expectEqual(@as(i64, 7), parsed.object.get("rev").?.integer);
    const stats = parsed.object.get("stats").?.object;
    try std.testing.expectEqual(@as(i64, 1), stats.get("parts").?.integer);
    try std.testing.expectEqual(@as(i64, 4), stats.get("outline_points").?.integer);
}
