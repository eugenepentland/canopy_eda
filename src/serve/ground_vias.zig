//! Live, additive-only GND via seed endpoint for the hand-routing editor.

const std = @import("std");
const httpz = @import("httpz");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const ground_via_seed = @import("../ground_via_seed.zig");
const json_writer = @import("../json_writer.zig");
const modules_mod = @import("modules.zig");
const page = @import("pcb_layout_page.zig");
const sidecar_json = @import("layout_sidecar_json.zig");
const serve_root = @import("../serve.zig");

const Server = serve_root.Server;
const HandlerError = page.HandlerError;

fn posesFrom(arena: std.mem.Allocator, root: std.json.Value) std.mem.Allocator.Error![]const page.PartPose {
    const value = root.object.get("parts") orelse return &.{};
    if (value != .array) return &.{};
    var poses: std.ArrayList(page.PartPose) = .empty;
    for (value.array.items) |item| {
        if (item != .object) continue;
        const ref = item.object.get("ref") orelse continue;
        if (ref != .string) continue;
        try poses.append(arena, .{
            .ref = ref.string,
            .x = sidecar_json.jsonNum(item.object.get("x")),
            .y = sidecar_json.jsonNum(item.object.get("y")),
            .rot = sidecar_json.jsonNum(item.object.get("rot")),
            .side = sidecar_json.jsonSide(item.object.get("side")),
            .locked = sidecar_json.jsonFlag(item.object.get("locked")),
        });
    }
    return poses.toOwnedSlice(arena);
}

/// POST `/api/pcb-drc/:name/ground-vias`: return only the legal GND vias and
/// short pad joins that are absent from the submitted live board. Nothing is
/// persisted server-side.
pub fn api(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = page.nameParam(req, res) orelse return;
    const body = page.bodyParam(req, res) orelse return;
    const root = std.json.parseFromSliceLeaky(std.json.Value, req.arena, body, .{}) catch {
        res.status = 400;
        res.body = "invalid JSON";
        return;
    };
    if (root != .object) {
        res.status = 400;
        return;
    }
    const poses = try posesFrom(req.arena, root);
    if (poses.len == 0) {
        res.status = 400;
        res.body = "missing parts";
        return;
    }

    var eval = Evaluator.init(req.arena, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        req.arena.destroy(mr.eval);
    };
    const solved = page.solveForRequest(req.arena, ctx.project_dir, name, .{
        .sub = page.queryOpt(req, "sub"),
    }, &eval, &module_res) catch {
        res.status = 404;
        res.body = "design or sub-circuit not found";
        return;
    };
    const saved = page.parseSavedRoutes(req.arena, root) orelse
        page.SavedRoutes{ .tracks = &.{}, .vias = &.{} };
    const routed = page.restoreRoutes(req.arena, saved, solved.placement.nets) orelse
        page.restoreRoutes(req.arena, .{ .tracks = &.{}, .vias = &.{} }, solved.placement.nets).?;
    const outcome = ground_via_seed.generateLive(
        req.arena,
        ctx.project_dir,
        .{
            .block = solved.block,
            .fallback = solved.placement,
            .placement_params = solved.params,
            .poses = poses,
            .saved_outline = sidecar_json.parseSavedOutline(req.arena, root.object.get("outline")),
            .routed = routed,
            .geometry = .{
                .clearance = sidecar_json.jsonNum(root.object.get("clearance")),
                .via_dia = sidecar_json.jsonNum(root.object.get("via_dia")),
                .via_drill = sidecar_json.jsonNum(root.object.get("via_drill")),
            },
        },
    ) catch {
        res.status = 500;
        res.body = "GND via generation failed";
        return;
    };

    var aw: std.Io.Writer.Allocating = .init(req.arena);
    const w = &aw.writer;
    try w.print("{{\"candidates\":{d},\"duplicates\":{d},\"blocked\":{d},\"nearby\":{d},\"tracks\":[", .{
        outcome.candidates,
        outcome.duplicates,
        outcome.blocked,
        outcome.nearby,
    });
    for (outcome.tracks, 0..) |track, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"x1\":{d},\"y1\":{d},\"x2\":{d},\"y2\":{d},\"l\":{d},\"w\":{d},\"net\":", .{
            track.x1,
            track.y1,
            track.x2,
            track.y2,
            track.layer,
            track.width,
        });
        try json_writer.writeString(w, track.net);
        try w.writeByte('}');
    }
    try w.writeAll("],\"added\":[");
    for (outcome.vias, 0..) |via, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"x\":{d},\"y\":{d},\"d\":{d},\"drill\":{d},\"net\":", .{
            via.x,
            via.y,
            via.dia,
            via.drill,
        });
        try json_writer.writeString(w, via.net);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    res.content_type = .JSON;
    res.body = aw.written();
}

// spec: Web Server - The PCB hand-routing editor offers one undoable GND-vias action that seeds DRC-legal exposed-pad arrays and centred ground-pad barrels, then places nearest-legal barrels beside pads still failing the ground-via-distance rule without replacing submitted copper
test "ground-via endpoint asset uses its non-persisting DRC route" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "/api/pcb-drc/") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "/ground-vias") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "pcb-ground-vias") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(added.length||tracks.length){recordUndo();") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "g.tracks||[]") != null);
}
