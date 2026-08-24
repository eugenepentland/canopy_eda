//! Fresh module-layout seeds for the PCB editor's Stamp action.
//!
//! The full board page embeds an initial palette preview, but an already-open
//! board must not keep using it after a module is saved in another tab. This
//! endpoint rebuilds only the small pose/copper maps from current sidecars.

const std = @import("std");
const httpz = @import("httpz");
const paths = @import("../paths.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const env = @import("../eval/env.zig");
const optimizer = @import("../placement/optimizer.zig");
const export_kicad = @import("../export_kicad.zig");
const serve_root = @import("../serve.zig");
const modules = @import("modules.zig");
const pcb = @import("pcb_layout_page.zig");

const Server = serve_root.Server;
const SeedsJson = struct {
    poses: []const u8 = "{}",
    info: []const u8 = "{}",
    mods: []const u8 = "{}",
    routes: []const u8 = "{}",
};

/// GET /api/pcb-subseeds/:name — return current module layouts for Stamp.
pub fn pcbSubSeedsApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) pcb.HandlerError!void {
    const name = pcb.nameParam(req, res) orelse return;
    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        ctx.allocator.destroy(mr.eval);
    };
    const block = resolveBlock(ctx.allocator, ctx.project_dir, name, &eval, &module_res) orelse {
        res.status = 500;
        res.body = "Could not evaluate design";
        return;
    };
    // Grid placement is deterministic O(n) and supplies only structural data:
    // flattened refs/origin keys, parent nets, and destination net rules.
    const placement = optimizer.gridPlace(ctx.allocator, block, ctx.project_dir, .{}) catch {
        res.status = 500;
        res.body = "Placement failed";
        return;
    };
    const seeds = build(ctx.allocator, ctx.project_dir, block, placement);
    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    try out.writer.print(
        "{{\"subseeds\":{s},\"subseedinfo\":{s},\"submodules\":{s},\"subroutes\":{s}}}",
        .{ seeds.poses, seeds.info, seeds.mods, seeds.routes },
    );
    res.header("Cache-Control", "no-store");
    res.content_type = .JSON;
    res.body = out.written();
}

fn resolveBlock(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    eval: *Evaluator,
    module_res: *?modules.ResolvedBlock,
) ?*env.DesignBlock {
    if (paths.designSourcePath(alloc, project_dir, name)) |path| {
        defer alloc.free(path);
        if (eval.evalFile(path)) |result| {
            if (result == .design_block) return result.design_block;
        } else |_| {}
    } else |_| {}
    module_res.* = modules.resolveModuleBlock(alloc, project_dir, name);
    return if (module_res.*) |mr| mr.block else null;
}

fn build(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    block: *const env.DesignBlock,
    placement: optimizer.Placement,
) SeedsJson {
    var poses: std.Io.Writer.Allocating = .init(alloc);
    var info: std.Io.Writer.Allocating = .init(alloc);
    var routes: std.Io.Writer.Allocating = .init(alloc);
    poses.writer.writeByte('{') catch return .{};
    info.writer.writeByte('{') catch return .{};
    routes.writer.writeByte('{') catch return .{};
    var pose_first = true;
    var info_first = true;
    var route_first = true;
    var parent_pin_nets: ?std.StringHashMapUnmanaged([]const u8) = null;

    for (block.sub_blocks) |sb| {
        const seeds = pcb.subBlockPoseByOriginKey(alloc, project_dir, sb) orelse continue;
        var ref_of_origin = std.StringHashMapUnmanaged([]const u8).empty;
        var count: usize = 0;
        for (placement.instances) |inst| {
            if (!inGroup(inst.ref_des, sb.name) or inst.origin_key.len == 0) continue;
            const pose = seeds.map.get(inst.origin_key) orelse continue;
            ref_of_origin.put(alloc, inst.origin_key, inst.ref_des) catch return .{};
            if (!pose_first) poses.writer.writeByte(',') catch return .{};
            pose_first = false;
            count += 1;
            pcb.writeJsonStr(&poses.writer, inst.ref_des) catch return .{};
            poses.writer.print(":{{\"x\":{d},\"y\":{d},\"rot\":{d}", .{ pose.x, pose.y, pose.rot }) catch return .{};
            if (pose.side == .bottom) poses.writer.writeAll(",\"side\":\"bottom\"") catch return .{};
            poses.writer.writeByte('}') catch return .{};
        }
        if (count == 0) continue;
        writeInfo(&info.writer, sb.name, seeds, count, &info_first) catch return .{};
        if (seeds.routes) |saved| {
            if (parent_pin_nets == null) parent_pin_nets = parentPinNetMap(alloc, placement);
            const pin_nets = if (parent_pin_nets) |*map| map else continue;
            if (!route_first) routes.writer.writeByte(',') catch return .{};
            route_first = false;
            pcb.writeJsonStr(&routes.writer, sb.name) catch return .{};
            routes.writer.writeByte(':') catch return .{};
            writeRoutes(&routes.writer, alloc, sb.name, saved, .{
                .pin_nets = seeds.pin_nets,
                .ref_of_origin = &ref_of_origin,
                .parent_pin_nets = pin_nets,
                .parent_nets = placement.nets,
                .parent_rules = placement.rules.net,
            }) catch return .{};
        }
    }
    poses.writer.writeByte('}') catch return .{};
    info.writer.writeByte('}') catch return .{};
    routes.writer.writeByte('}') catch return .{};
    return .{
        .poses = poses.written(),
        .info = info.written(),
        .mods = buildModules(alloc, block),
        .routes = routes.written(),
    };
}

fn inGroup(ref: []const u8, group: []const u8) bool {
    return ref.len > group.len and std.mem.startsWith(u8, ref, group) and ref[group.len] == '/';
}

fn writeInfo(
    w: *std.Io.Writer,
    group: []const u8,
    seeds: pcb.SubBlockSeeds,
    count: usize,
    first: *bool,
) std.Io.Writer.Error!void {
    if (!first.*) try w.writeByte(',');
    first.* = false;
    try pcb.writeJsonStr(w, group);
    try w.writeAll(":{\"layout\":");
    try pcb.writeJsonStr(w, seeds.layout_name);
    try w.print(",\"starred\":{},\"n\":{d}", .{ seeds.starred, count });
    if (seeds.alt_name.len > 0) {
        try w.writeAll(",\"alt\":");
        try pcb.writeJsonStr(w, seeds.alt_name);
        try w.print(",\"alt_n\":{d}", .{seeds.alt_n});
    }
    try w.writeByte('}');
}

fn buildModules(alloc: std.mem.Allocator, block: *const env.DesignBlock) []const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    out.writer.writeByte('{') catch return "{}";
    var first = true;
    for (block.sub_blocks) |sb| {
        if (sb.source.len == 0) continue;
        if (!first) out.writer.writeByte(',') catch return "{}";
        first = false;
        pcb.writeJsonStr(&out.writer, sb.name) catch return "{}";
        out.writer.writeByte(':') catch return "{}";
        pcb.writeJsonStr(&out.writer, sb.source) catch return "{}";
    }
    out.writer.writeByte('}') catch return "{}";
    return out.written();
}

fn parentPinNetMap(alloc: std.mem.Allocator, placement: optimizer.Placement) ?std.StringHashMapUnmanaged([]const u8) {
    var out = std.StringHashMapUnmanaged([]const u8).empty;
    for (placement.nets) |net| for (net.pins) |pin| {
        const key = std.fmt.allocPrint(alloc, "{s}\x00{s}", .{ pin.ref_des, pin.pin }) catch return null;
        out.put(alloc, key, net.name) catch return null;
    };
    return out;
}

const RouteMap = struct {
    pin_nets: []const pcb.SubPinNet,
    ref_of_origin: *const std.StringHashMapUnmanaged([]const u8),
    parent_pin_nets: *const std.StringHashMapUnmanaged([]const u8),
    parent_nets: []const export_kicad.FlatNet,
    parent_rules: []const optimizer.NetRule,
};

fn writeRoutes(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    group: []const u8,
    saved: pcb.SavedRoutes,
    map: RouteMap,
) std.Io.Writer.Error!void {
    var names = std.StringHashMapUnmanaged([]const u8).empty;
    for (map.pin_nets) |pin| {
        if (names.contains(pin.net)) continue;
        const parent_ref = map.ref_of_origin.get(pin.origin_key) orelse continue;
        const key = std.fmt.allocPrint(alloc, "{s}\x00{s}", .{ parent_ref, pin.pad }) catch continue;
        const parent_net = map.parent_pin_nets.get(key) orelse continue;
        names.put(alloc, pin.net, parent_net) catch break;
    }
    try w.writeAll("{\"tracks\":[");
    for (saved.tracks, 0..) |track, i| {
        if (i > 0) try w.writeByte(',');
        const net = mappedNet(alloc, &names, group, track.net);
        const rule = netRule(map.parent_nets, map.parent_rules, net);
        try w.print("{{\"x1\":{d},\"y1\":{d},\"x2\":{d},\"y2\":{d},\"l\":{d},\"w\":{d},\"net\":", .{
            track.x1, track.y1, track.x2, track.y2, track.l, if (rule.width > 0) rule.width else track.w,
        });
        try pcb.writeJsonStr(w, net);
        if (track.source.len > 0) {
            try w.writeAll(",\"source\":");
            try pcb.writeJsonStr(w, track.source);
        }
        try w.writeByte('}');
    }
    try w.writeAll("],\"vias\":[");
    for (saved.vias, 0..) |via, i| {
        if (i > 0) try w.writeByte(',');
        const net = mappedNet(alloc, &names, group, via.net);
        const rule = netRule(map.parent_nets, map.parent_rules, net);
        try w.print("{{\"x\":{d},\"y\":{d},\"d\":{d},\"drill\":{d},\"net\":", .{
            via.x,                                                 via.y, if (rule.via_dia > 0) rule.via_dia else via.d,
            if (rule.via_drill > 0) rule.via_drill else via.drill,
        });
        try pcb.writeJsonStr(w, net);
        if (via.source.len > 0) {
            try w.writeAll(",\"source\":");
            try pcb.writeJsonStr(w, via.source);
        }
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

fn mappedNet(
    alloc: std.mem.Allocator,
    names: *const std.StringHashMapUnmanaged([]const u8),
    group: []const u8,
    net: []const u8,
) []const u8 {
    if (net.len == 0) return "";
    if (names.get(net)) |parent| return parent;
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ group, net }) catch net;
}

fn netRule(nets: []const export_kicad.FlatNet, rules: []const optimizer.NetRule, name: []const u8) optimizer.NetRule {
    for (nets, 0..) |net, i| {
        if (i >= rules.len) break;
        if (std.ascii.eqlIgnoreCase(net.name, name)) return rules[i];
    }
    return .{};
}

fn testApiBody(alloc: std.mem.Allocator, project_dir: []const u8) ![]const u8 {
    var state = serve_root.ServerState{};
    var server = Server{ .allocator = alloc, .project_dir = project_dir, .auth_dir = project_dir, .state = &state };
    var request = httpz.testing.init(.{});
    defer request.deinit();
    request.param("name", "board");
    try pcbSubSeedsApi(&server, request.req, request.res);
    try std.testing.expectEqual(@as(u16, 200), request.res.status);
    return alloc.dupe(u8, request.res.body);
}

fn seedXSum(alloc: std.mem.Allocator, body: []const u8) !f64 {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const values = parsed.value.object.get("subseeds").?.object;
    var sum: f64 = 0;
    var it = values.iterator();
    while (it.next()) |entry| {
        const x = entry.value_ptr.object.get("x").?;
        sum += switch (x) {
            .float => |v| v,
            .integer => |v| @floatFromInt(v),
            else => return error.TestUnexpectedResult,
        };
    }
    return sum;
}

test "subseed endpoint rereads a module layout saved after the board opened" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.createDirPath(std.testing.io, "lib/modules");
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/cap.sexp", .data =
        \\(component-family cap
        \\  (param-type capacitance)
        \\  (footprint "0402"))
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/0402.sexp", .data = "(component 0402 (footprint \"0402.kicad_mod\"))" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/modules/synthx.sexp", .data =
        \\(defmodule synthx ()
        \\  (design-block "SynthX"
        \\    (import cap)
        \\    (instance "C_A" (cap "10nF") (pin 1 "CTRL") (pin 2 "GND"))
        \\    (instance "C_B" (cap "20nF") (pin 1 "CTRL") (pin 2 "GND"))))
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/board.sexp", .data =
        \\(design-block "Board"
        \\  (hierarchical-ids)
        \\  (import synthx)
        \\  (sub-block "sm" (synthx)))
    });
    const layout_path = "lib/modules/synthx.layouts.json";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = layout_path, .data =
        \\{"default":"hand","layouts":[{"name":"hand","default":true,"parts":[
        \\ {"ref":"C1","x":1,"y":1,"rot":0,"origin":"C_A"},
        \\ {"ref":"C2","x":2,"y":2,"rot":0,"origin":"C_B"}]}]}
    });
    const before = try testApiBody(alloc, project_dir);
    try std.testing.expectEqual(@as(f64, 3), try seedXSum(alloc, before));

    // This is the other tab's completed Update: the already-open board makes
    // another endpoint request rather than reusing its page-load seed object.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = layout_path, .data =
        \\{"default":"hand","layouts":[{"name":"hand","default":true,"parts":[
        \\ {"ref":"C1","x":10,"y":1,"rot":0,"origin":"C_A"},
        \\ {"ref":"C2","x":20,"y":2,"rot":0,"origin":"C_B"}]}]}
    });
    const after = try testApiBody(alloc, project_dir);
    try std.testing.expectEqual(@as(f64, 30), try seedXSum(alloc, after));
}
