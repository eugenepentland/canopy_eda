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
const pose_math = @import("../placement/pose_math.zig");
const board_layers = @import("../board_layers.zig");
const export_kicad = @import("../export_kicad.zig");
const flat_netlist = @import("../flat_netlist.zig");
const review = @import("../review.zig");
const numeric = @import("../numeric.zig");
const clock = @import("../infra/clock.zig");
const serve_root = @import("../serve.zig");
const modules = @import("modules.zig");
const pcb = @import("pcb_layout_page.zig");
const layout_save_layers = @import("../layout_save_layers.zig");
const sidecar_json = @import("layout_sidecar_json.zig");
const saved_zone = @import("saved_zone.zig");

const Server = serve_root.Server;
const SeedsJson = struct {
    poses: []const u8 = "{}",
    origin_poses: []const u8 = "{}",
    info: []const u8 = "{}",
    mods: []const u8 = "{}",
    routes: []const u8 = "{}",
    save_info: []const u8 = "{}",
};

/// GET /api/pcb-subseeds/:name — return current module layouts for Stamp.
/// Poses are supplied both by the endpoint's temporary ref-des and by stable
/// module-local origin key; an already-open board must use the latter because
/// its persisted ref-des assignment can differ from a fresh grid placement.
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
    const selected_group = pcb.queryOpt(req, "group");
    const selected_layout = pcb.queryOpt(req, "layout");
    const seeds = build(ctx.allocator, ctx.project_dir, name, block, placement, .{ .group = selected_group, .layout = selected_layout });
    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    try out.writer.print(
        "{{\"subseeds\":{s},\"subseedorigins\":{s},\"subseedinfo\":{s},\"submodules\":{s},\"subroutes\":{s},\"subsaveinfo\":{s}}}",
        .{ seeds.poses, seeds.origin_poses, seeds.info, seeds.mods, seeds.routes, seeds.save_info },
    );
    res.header("Cache-Control", "no-store");
    res.content_type = .JSON;
    res.body = out.written();
}

const CapturePose = pose_math.RigidPose;
const CaptureTarget = struct { ref: []const u8, pose: CapturePose };
const CaptureNetMap = struct { names: std.StringHashMapUnmanaged([]const u8) };
const StampSelection = struct { group: ?[]const u8 = null, layout: ?[]const u8 = null };

fn parseObject(req: *httpz.Request, res: *httpz.Response) ?std.json.Value {
    const body = pcb.bodyParam(req, res) orelse return null;
    const root = std.json.parseFromSliceLeaky(std.json.Value, req.arena, body, .{}) catch {
        res.status = 400;
        res.body = "bad JSON";
        return null;
    };
    if (root != .object) {
        res.status = 400;
        res.body = "expected JSON object";
        return null;
    }
    return root;
}

fn capturePose(part: anytype) CapturePose {
    return .{ .x = part.x, .y = part.y, .rot = pose_math.rigidNorm(part.rot), .back = part.side == .bottom };
}

fn captureTargets(alloc: std.mem.Allocator, placement: optimizer.Placement) std.mem.Allocator.Error!std.StringHashMapUnmanaged(CaptureTarget) {
    var out = std.StringHashMapUnmanaged(CaptureTarget).empty;
    for (placement.parts, 0..) |part, i| {
        if (i >= placement.instances.len) break;
        const origin = placement.instances[i].origin_key;
        if (origin.len > 0) try out.put(alloc, origin, .{ .ref = part.ref_des, .pose = capturePose(part) });
    }
    return out;
}

fn captureParts(
    alloc: std.mem.Allocator,
    submitted: []const pcb.PartPose,
    targets: *const std.StringHashMapUnmanaged(CaptureTarget),
) (std.mem.Allocator.Error || error{NoMatchingParts})!struct { parts: []const pcb.PartPose, transform: CapturePose } {
    var source_anchor: ?pcb.PartPose = null;
    var target_anchor: ?CaptureTarget = null;
    for (submitted) |part| {
        if (part.origin.len == 0) continue;
        if (targets.get(part.origin)) |target| {
            source_anchor = part;
            target_anchor = target;
            break;
        }
    }
    const source = source_anchor orelse return error.NoMatchingParts;
    const target = target_anchor orelse return error.NoMatchingParts;
    const transform = pose_math.rigidCompose(target.pose, pose_math.rigidInverse(capturePose(source)));
    var out: std.ArrayList(pcb.PartPose) = .empty;
    for (submitted) |part| {
        const mapped = targets.get(part.origin) orelse continue;
        const pose = pose_math.rigidCompose(transform, capturePose(part));
        try out.append(alloc, .{
            .ref = mapped.ref,
            .x = pose.x,
            .y = pose.y,
            .rot = pose.rot,
            .origin = part.origin,
            .side = if (pose.back) .bottom else .top,
            .locked = part.locked,
        });
    }
    if (out.items.len == 0) return error.NoMatchingParts;
    return .{ .parts = try out.toOwnedSlice(alloc), .transform = transform };
}

fn captureNetMap(
    alloc: std.mem.Allocator,
    group: []const u8,
    parent: optimizer.Placement,
    target: optimizer.Placement,
) std.mem.Allocator.Error!CaptureNetMap {
    var target_ref_origin = std.StringHashMapUnmanaged([]const u8).empty;
    for (target.instances) |instance| try target_ref_origin.put(alloc, instance.ref_des, instance.origin_key);
    var target_pin_net = std.StringHashMapUnmanaged([]const u8).empty;
    for (target.nets) |net| for (net.pins) |pin| {
        const origin = target_ref_origin.get(pin.ref_des) orelse continue;
        const key = try std.fmt.allocPrint(alloc, "{s}\x00{s}", .{ origin, pin.pin });
        try target_pin_net.put(alloc, key, net.name);
    };
    var parent_ref_origin = std.StringHashMapUnmanaged([]const u8).empty;
    for (parent.instances) |instance| if (inGroup(instance.ref_des, group))
        try parent_ref_origin.put(alloc, instance.ref_des, instance.origin_key);
    var names = std.StringHashMapUnmanaged([]const u8).empty;
    var ambiguous = std.StringHashMapUnmanaged(void).empty;
    for (parent.nets) |net| for (net.pins) |pin| {
        const origin = parent_ref_origin.get(pin.ref_des) orelse continue;
        const key = try std.fmt.allocPrint(alloc, "{s}\x00{s}", .{ origin, pin.pin });
        const target_name = target_pin_net.get(key) orelse continue;
        if (names.get(net.name)) |prior| {
            if (!std.mem.eql(u8, prior, target_name)) try ambiguous.put(alloc, net.name, {});
        } else try names.put(alloc, net.name, target_name);
    };
    var it = ambiguous.keyIterator();
    while (it.next()) |name| _ = names.remove(name.*);
    return .{ .names = names };
}

fn capturedNet(map: *const CaptureNetMap, parent_name: []const u8) ?[]const u8 {
    if (parent_name.len == 0) return "";
    return map.names.get(parent_name);
}

fn captureRoutes(
    alloc: std.mem.Allocator,
    group: []const u8,
    submitted: ?pcb.SavedRoutes,
    transform: CapturePose,
    nets: *const CaptureNetMap,
) std.mem.Allocator.Error!?pcb.SavedRoutes {
    const routes = submitted orelse return null;
    var tracks: std.ArrayList(pcb.SavedTrack) = .empty;
    var vias: std.ArrayList(pcb.SavedVia) = .empty;
    var zones: std.ArrayList(pcb.SavedZone) = .empty;
    for (routes.tracks) |track| {
        if (!std.mem.eql(u8, track.g, group)) continue;
        const net = capturedNet(nets, track.net) orelse continue;
        const a = pose_math.rigidApply(transform, track.x1, track.y1);
        const b = pose_math.rigidApply(transform, track.x2, track.y2);
        const mid = if (track.xm != null and track.ym != null) pose_math.rigidApply(transform, track.xm.?, track.ym.?) else null;
        try tracks.append(alloc, .{
            .x1 = a[0],
            .y1 = a[1],
            .x2 = b[0],
            .y2 = b[1],
            .xm = if (mid) |point| point[0] else null,
            .ym = if (mid) |point| point[1] else null,
            .l = if (!transform.back) track.l else if (track.l == 0) 1 else if (track.l == 1) 0 else track.l,
            .w = track.w,
            .net = net,
            .source = track.source,
        });
    }
    for (routes.vias) |via| {
        if (!std.mem.eql(u8, via.g, group)) continue;
        const net = capturedNet(nets, via.net) orelse continue;
        const at = pose_math.rigidApply(transform, via.x, via.y);
        try vias.append(alloc, .{
            .x = at[0],
            .y = at[1],
            .d = via.d,
            .drill = via.drill,
            .net = net,
            .f = via.f,
            .source = via.source,
            .s = via.s,
        });
    }
    for (routes.zones) |zone| {
        if (!std.mem.eql(u8, zone.g, group)) continue;
        if (!zone.flags.filled or zone.flags.keepout) continue;
        const net = capturedNet(nets, zone.net) orelse continue;
        const poly = try alloc.alloc([2]f64, zone.poly.len);
        for (zone.poly, 0..) |point, i| poly[i] = pose_math.rigidApply(transform, point[0], point[1]);
        var legacy: [1][]const u8 = undefined;
        const source_layers = saved_zone.layers(&zone, &legacy);
        const layers = try alloc.alloc([]const u8, source_layers.len);
        for (source_layers, layers) |layer_name, *transformed| transformed.* = if (!transform.back)
            layer_name
        else if (std.mem.eql(u8, layer_name, board_layers.f_cu))
            board_layers.b_cu
        else if (std.mem.eql(u8, layer_name, board_layers.b_cu))
            board_layers.f_cu
        else
            layer_name;
        try zones.append(alloc, .{
            .net = net,
            .layer = if (layers.len > 0) layers[0] else "",
            .layers = if (layers.len > 1) layers else &.{},
            .poly = poly,
            .flags = .{ .filled = true },
            .priority = zone.priority,
        });
    }
    if (tracks.items.len == 0 and vias.items.len == 0 and zones.items.len == 0) return null;
    return .{ .tracks = try tracks.toOwnedSlice(alloc), .vias = try vias.toOwnedSlice(alloc), .zones = try zones.toOwnedSlice(alloc) };
}

fn findSubBlock(alloc: std.mem.Allocator, block: *const env.DesignBlock, group: []const u8) ?env.SubBlock {
    for (block.sub_blocks) |sub| {
        if (std.mem.eql(u8, sub.name, group)) return sub;
        const slug = review.slugify(alloc, sub.name) catch continue;
        if (std.mem.eql(u8, slug, group)) return sub;
    }
    return null;
}

/// POST /api/pcb-subcircuit-layout/:name — inverse Stamp into a new module layout.
pub fn saveSubcircuitLayoutApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) pcb.HandlerError!void {
    const parent_name = pcb.nameParam(req, res) orelse return;
    const root = parseObject(req, res) orelse return;
    const group_v = root.object.get("group") orelse {
        res.status = 400;
        res.body = "no sub-circuit";
        return;
    };
    const name_v = root.object.get("name") orelse {
        res.status = 400;
        res.body = "no layout name";
        return;
    };
    if (group_v != .string or name_v != .string) {
        res.status = 400;
        res.body = "bad sub-circuit save";
        return;
    }
    const layout_name = std.mem.trim(u8, name_v.string, " \t\n\r");
    if (layout_name.len == 0 or layout_name.len > 80) {
        res.status = 400;
        res.body = "bad layout name";
        return;
    }
    const submitted = sidecar_json.parsePartPoses(req.arena, root.object.get("parts")) orelse {
        res.status = 400;
        res.body = "no parts";
        return;
    };
    const client_rev: i64 = if (root.object.get("rev")) |value| switch (value) {
        .integer => |i| i,
        .float => |f| numeric.checkedInt(i64, f) orelse -1,
        else => -1,
    } else -1;
    if (client_rev < 0) {
        res.status = 400;
        res.body = "bad sub-circuit revision";
        return;
    }

    var parent_eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer parent_eval.deinit();
    var parent_module: ?modules.ResolvedBlock = null;
    defer if (parent_module) |resolved| {
        resolved.eval.deinit();
        ctx.allocator.destroy(resolved.eval);
    };
    const parent_block = resolveBlock(ctx.allocator, ctx.project_dir, parent_name, &parent_eval, &parent_module) orelse {
        res.status = 404;
        res.body = "design not found";
        return;
    };
    const sub = findSubBlock(req.arena, parent_block, group_v.string) orelse {
        res.status = 404;
        res.body = "sub-circuit not found";
        return;
    };
    const module_target = reusableModuleSource(sub.source);
    const target_slug = if (module_target) null else review.slugify(req.arena, sub.name) catch {
        res.status = 500;
        return;
    };
    const target_name = if (module_target) sub.source else parent_name;
    var target_module: ?modules.ResolvedBlock = null;
    defer if (target_module) |resolved| {
        resolved.eval.deinit();
        ctx.allocator.destroy(resolved.eval);
    };
    const target_block: *env.DesignBlock = if (module_target) blk: {
        target_module = modules.resolveModuleBlock(ctx.allocator, ctx.project_dir, sub.source);
        break :blk if (target_module) |resolved| resolved.block else {
            res.status = 404;
            res.body = "module could not be resolved";
            return;
        };
    } else sub.block;

    const disk_rev = pcb.readLayoutRev(req.arena, ctx.project_dir, target_name, target_slug);
    if (client_rev != disk_rev) {
        res.status = 409;
        res.content_type = .JSON;
        res.body = try std.fmt.allocPrint(req.arena, "{{\"error\":\"conflict\",\"rev\":{d}}}", .{disk_rev});
        return;
    }
    const existing = pcb.readLayoutsSub(req.arena, ctx.project_dir, target_name, target_slug);
    for (existing) |layout| if (std.mem.eql(u8, layout.name, layout_name)) {
        res.status = 422;
        res.body = "a layout with that name already exists";
        return;
    };
    const target_placement = optimizer.gridPlace(req.arena, target_block, ctx.project_dir, .{}) catch {
        res.status = 500;
        res.body = "could not build the sub-circuit placement";
        return;
    };
    const targets = try captureTargets(req.arena, target_placement);
    const captured = captureParts(req.arena, submitted, &targets) catch |err| switch (err) {
        error.NoMatchingParts => {
            res.status = 409;
            res.body = "the sub-circuit parts no longer match the module";
            return;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    const parent_placement = optimizer.gridPlace(req.arena, parent_block, ctx.project_dir, .{}) catch {
        res.status = 500;
        res.body = "could not map the parent board nets";
        return;
    };
    const net_map = try captureNetMap(req.arena, sub.name, parent_placement, target_placement);
    const routes = try captureRoutes(req.arena, sub.name, pcb.parseSavedRoutes(req.arena, root.object.get("routes")), captured.transform, &net_map);
    // Layer rules only — like the editor's save this stores the capture without
    // scoring it. Nothing downstream reads a module layout's score: the stamp
    // picks its snapshot by origin-key coverage and the ★ (`chooseModuleSnapshot`),
    // and `/api/pcb-rescore` declines sub circuits outright.
    // No stage sink: this path is the module-layout capture, not the editor's
    // autosave, so it has no `evt:"stages"` line to contribute phases to.
    const layers = layout_save_layers.savedLayoutLayers(ctx, req.arena, target_name, target_slug, null);
    const entry = pcb.SavedLayout{
        .name = layout_name,
        .kind = pcb.kind_manual,
        .ts = clock.timestamp(),
        .score = null,
        .parts = captured.parts,
        .routes = routes,
        .default = existing.len == 0,
    };
    if (sidecar_json.saveRejection(req.arena, layers, entry)) |message| {
        res.status = 400;
        res.body = message;
        return;
    }
    var out: std.ArrayList(pcb.SavedLayout) = .empty;
    try out.append(req.arena, entry);
    try out.appendSlice(req.arena, existing);
    const new_rev = try pcb.commitNamedLayoutMutation(req.arena, ctx.project_dir, target_name, target_slug, out.items, disk_rev);
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(req.arena, "{{\"ok\":true,\"rev\":{d},\"parts\":{d},\"copper\":{}}}", .{ new_rev, captured.parts.len, routes != null });
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
    parent_name: []const u8,
    block: *const env.DesignBlock,
    placement: optimizer.Placement,
    selection: StampSelection,
) SeedsJson {
    var poses: std.Io.Writer.Allocating = .init(alloc);
    var origin_poses: std.Io.Writer.Allocating = .init(alloc);
    var info: std.Io.Writer.Allocating = .init(alloc);
    var routes: std.Io.Writer.Allocating = .init(alloc);
    var save_info: std.Io.Writer.Allocating = .init(alloc);
    poses.writer.writeByte('{') catch return .{};
    origin_poses.writer.writeByte('{') catch return .{};
    info.writer.writeByte('{') catch return .{};
    routes.writer.writeByte('{') catch return .{};
    save_info.writer.writeByte('{') catch return .{};
    var pose_first = true;
    var origin_group_first = true;
    var info_first = true;
    var route_first = true;
    var save_first = true;
    var parent_pin_nets: ?std.StringHashMapUnmanaged([]const u8) = null;

    for (block.sub_blocks) |sb| {
        writeSaveInfo(&save_info.writer, alloc, project_dir, parent_name, sb, &save_first) catch return .{};
        const want = if (selection.group != null and std.mem.eql(u8, selection.group.?, sb.name)) selection.layout else null;
        const seeds = if (want) |layout|
            exactNamedSeeds(alloc, project_dir, sb, layout) orelse continue
        else
            pcb.subBlockPoseByOriginKey(alloc, project_dir, sb) orelse continue;
        var group_origins: std.Io.Writer.Allocating = .init(alloc);
        group_origins.writer.writeByte('{') catch return .{};
        var group_origin_first = true;
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
            if (!group_origin_first) group_origins.writer.writeByte(',') catch return .{};
            group_origin_first = false;
            pcb.writeJsonStr(&group_origins.writer, inst.origin_key) catch return .{};
            group_origins.writer.print(":{{\"x\":{d},\"y\":{d},\"rot\":{d}", .{ pose.x, pose.y, pose.rot }) catch return .{};
            if (pose.side == .bottom) group_origins.writer.writeAll(",\"side\":\"bottom\"") catch return .{};
            group_origins.writer.writeByte('}') catch return .{};
        }
        if (count == 0) continue;
        group_origins.writer.writeByte('}') catch return .{};
        if (!origin_group_first) origin_poses.writer.writeByte(',') catch return .{};
        origin_group_first = false;
        pcb.writeJsonStr(&origin_poses.writer, sb.name) catch return .{};
        origin_poses.writer.writeByte(':') catch return .{};
        origin_poses.writer.writeAll(group_origins.written()) catch return .{};
        writeInfo(&info.writer, sb.name, seeds, count, pcb.readLayouts(alloc, project_dir, sb.source), &info_first) catch return .{};
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
    origin_poses.writer.writeByte('}') catch return .{};
    info.writer.writeByte('}') catch return .{};
    routes.writer.writeByte('}') catch return .{};
    save_info.writer.writeByte('}') catch return .{};
    return .{
        .poses = poses.written(),
        .origin_poses = origin_poses.written(),
        .info = info.written(),
        .mods = buildModules(alloc, block),
        .routes = routes.written(),
        .save_info = save_info.written(),
    };
}

/// Resolve one exact saved module layout onto stable origin keys. This mirrors
/// the default resolver's bridge, but deliberately has no ★/cache fallback: a
/// picker choice must either produce the named arrangement or refuse to stamp.
fn exactNamedSeeds(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    sub_block: env.SubBlock,
    want: []const u8,
) ?pcb.SubBlockSeeds {
    const resolved = modules.resolveModuleBlock(alloc, project_dir, sub_block.source) orelse return null;
    defer {
        resolved.eval.deinit();
        alloc.destroy(resolved.eval);
    }
    var flat: std.ArrayList(flat_netlist.FlatInstance) = .empty;
    flat_netlist.collectInstances(alloc, resolved.block, "", &flat) catch return null;
    var origin_of = std.StringHashMapUnmanaged([]const u8).empty;
    for (flat.items) |instance| {
        const origin = alloc.dupe(u8, instance.origin_key) catch return null;
        origin_of.put(alloc, instance.ref_des, origin) catch return null;
    }

    var chosen: ?pcb.SavedLayout = null;
    for (pcb.readLayouts(alloc, project_dir, sub_block.source)) |layout| {
        if (std.mem.eql(u8, layout.name, want)) {
            chosen = layout;
            break;
        }
    }
    const layout = chosen orelse return null;
    var poses = std.StringHashMapUnmanaged(pcb.SyncPose).empty;
    for (layout.parts) |part| {
        const origin = origin_of.get(part.ref) orelse continue;
        if (origin.len == 0) continue;
        poses.put(alloc, origin, .{ .x = part.x, .y = part.y, .rot = part.rot, .side = part.side }) catch return null;
    }
    if (poses.count() == 0) return null;
    return .{
        .map = poses,
        .layout_name = layout.name,
        .starred = layout.default,
        .routes = layout.routes,
        .pin_nets = if (layout.routes != null) namedPinNets(alloc, resolved.block, &origin_of) else &.{},
    };
}

fn namedPinNets(
    alloc: std.mem.Allocator,
    block: *const env.DesignBlock,
    origin_of: *const std.StringHashMapUnmanaged([]const u8),
) []const pcb.SubPinNet {
    var nets: std.ArrayList(flat_netlist.FlatNet) = .empty;
    flat_netlist.collectNets(alloc, block, "", &nets) catch return &.{};
    var out: std.ArrayList(pcb.SubPinNet) = .empty;
    for (nets.items) |net| for (net.pins) |pin| {
        const origin = origin_of.get(pin.ref_des) orelse continue;
        if (origin.len == 0) continue;
        const net_name = alloc.dupe(u8, net.name) catch return &.{};
        const pad = alloc.dupe(u8, pin.pin) catch return &.{};
        out.append(alloc, .{ .net = net_name, .origin_key = origin, .pad = pad }) catch return &.{};
    };
    return out.toOwnedSlice(alloc) catch &.{};
}

fn reusableModuleSource(source: []const u8) bool {
    return source.len > 0 and std.mem.indexOfScalar(u8, source, '/') == null and
        !std.mem.endsWith(u8, source, ".sexp");
}

/// Fresh optimistic-concurrency revisions for the inverse of Stamp. The PCB
/// page fetches this immediately before Save to sub-circuit, so a second module
/// editor cannot be silently overwritten by an already-open parent board.
fn writeSaveInfo(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    parent_name: []const u8,
    sb: env.SubBlock,
    first: *bool,
) std.Io.Writer.Error!void {
    const module = reusableModuleSource(sb.source);
    const slug = if (module) null else review.slugify(alloc, sb.name) catch return;
    const target = if (module) sb.source else parent_name;
    const rev = pcb.readLayoutRev(alloc, project_dir, target, slug);
    if (!first.*) try w.writeByte(',');
    first.* = false;
    try pcb.writeJsonStr(w, sb.name);
    try w.print(":{{\"rev\":{d}}}", .{rev});
}

fn inGroup(ref: []const u8, group: []const u8) bool {
    return ref.len > group.len and std.mem.startsWith(u8, ref, group) and ref[group.len] == '/';
}

fn writeInfo(
    w: *std.Io.Writer,
    group: []const u8,
    seeds: pcb.SubBlockSeeds,
    count: usize,
    layouts: []const pcb.SavedLayout,
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
    try w.writeAll(",\"layouts\":[");
    for (layouts, 0..) |layout, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try pcb.writeJsonStr(w, layout.name);
        try w.print(",\"starred\":{}}}", .{layout.default});
    }
    try w.writeByte(']');
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
    try w.writeAll("],\"zones\":[");
    var zone_first = true;
    for (saved.zones) |zone| {
        // SavedRoutes.zones contains only user-authored/imported zone geometry;
        // declared stackup planes (including internal GND planes) live outside
        // SavedRoutes and can therefore never enter the Stamp payload. Keepouts
        // and unfilled sketches are not copper pours and are deliberately not
        // copied either.
        if (!zone.flags.filled or zone.flags.keepout) continue;
        if (zone.net.len == 0 or zone.poly.len < 3) continue;
        if (!zone_first) try w.writeByte(',');
        zone_first = false;
        const net = mappedNet(alloc, &names, group, zone.net);
        try w.writeAll("{\"net\":");
        try pcb.writeJsonStr(w, net);
        try w.writeAll(",\"layer\":");
        try pcb.writeJsonStr(w, saved_zone.primaryLayer(&zone));
        if (zone.layers.len > 1) {
            try w.writeAll(",\"layers\":[");
            for (zone.layers, 0..) |layer_name, li| {
                if (li > 0) try w.writeByte(',');
                try pcb.writeJsonStr(w, layer_name);
            }
            try w.writeByte(']');
        }
        try w.writeAll(",\"poly\":[");
        for (zone.poly, 0..) |point, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("[{d},{d}]", .{ point[0], point[1] });
        }
        try w.print("],\"filled\":true,\"keepout\":false,\"priority\":{d}}}", .{zone.priority});
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

test "subseed routes include only filled custom pours with parent net names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pour_poly = [_][2]f64{ .{ 1, 2 }, .{ 4, 2 }, .{ 4, 6 }, .{ 1, 6 } };
    const zones = [_]pcb.SavedZone{
        .{ .net = "VIN", .layer = "F.Cu", .poly = &pour_poly, .flags = .{ .filled = true }, .priority = 3 },
        .{ .net = "VIN", .layer = "F.Cu", .poly = &pour_poly, .flags = .{ .filled = true, .keepout = true } },
        .{ .net = "VIN", .layer = "F.Cu", .poly = &pour_poly },
    };
    const saved = pcb.SavedRoutes{ .tracks = &.{}, .vias = &.{}, .zones = &zones };
    const pin_nets = [_]pcb.SubPinNet{.{ .net = "VIN", .origin_key = "U1", .pad = "1" }};
    var ref_of_origin = std.StringHashMapUnmanaged([]const u8).empty;
    try ref_of_origin.put(alloc, "U1", "ldo/U24");
    var parent_pin_nets = std.StringHashMapUnmanaged([]const u8).empty;
    try parent_pin_nets.put(alloc, "ldo/U24\x001", "V_3P3");

    var out: std.Io.Writer.Allocating = .init(alloc);
    try writeRoutes(&out.writer, alloc, "ldo", saved, .{
        .pin_nets = &pin_nets,
        .ref_of_origin = &ref_of_origin,
        .parent_pin_nets = &parent_pin_nets,
        .parent_nets = &.{},
        .parent_rules = &.{},
    });
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.written(), .{});
    const stamped = parsed.value.object.get("zones").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), stamped.len);
    try std.testing.expectEqualStrings("V_3P3", stamped[0].object.get("net").?.string);
    try std.testing.expectEqualStrings("F.Cu", stamped[0].object.get("layer").?.string);
    try std.testing.expectEqual(@as(usize, 4), stamped[0].object.get("poly").?.array.items.len);
    try std.testing.expect(stamped[0].object.get("filled").?.bool);
    try std.testing.expect(!stamped[0].object.get("keepout").?.bool);
}

fn testApiBody(alloc: std.mem.Allocator, project_dir: []const u8, group: ?[]const u8, layout: ?[]const u8) ![]const u8 {
    var state = serve_root.ServerState{};
    var server = Server{ .allocator = alloc, .project_dir = project_dir, .auth_dir = project_dir, .state = &state };
    var request = httpz.testing.init(.{});
    defer request.deinit();
    request.param("name", "board");
    if (group) |value| request.query("group", value);
    if (layout) |value| request.query("layout", value);
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

fn originSeedX(alloc: std.mem.Allocator, body: []const u8, group: []const u8, origin: []const u8) !f64 {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const groups = parsed.value.object.get("subseedorigins").?.object;
    const pose = groups.get(group).?.object.get(origin).?.object;
    return switch (pose.get("x").?) {
        .float => |v| v,
        .integer => |v| @floatFromInt(v),
        else => error.TestUnexpectedResult,
    };
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
    const before = try testApiBody(alloc, project_dir, null, null);
    try std.testing.expectEqual(@as(f64, 3), try seedXSum(alloc, before));
    try std.testing.expectEqual(@as(f64, 1), try originSeedX(alloc, before, "sm", "C_A"));

    // This is the other tab's completed Update: the already-open board makes
    // another endpoint request rather than reusing its page-load seed object.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = layout_path, .data =
        \\{"default":"hand","layouts":[{"name":"hand","default":true,"parts":[
        \\ {"ref":"C1","x":10,"y":1,"rot":0,"origin":"C_A"},
        \\ {"ref":"C2","x":20,"y":2,"rot":0,"origin":"C_B"}]},
        \\ {"name":"compact","parts":[
        \\ {"ref":"C1","x":100,"y":1,"rot":0,"origin":"C_A"},
        \\ {"ref":"C2","x":200,"y":2,"rot":0,"origin":"C_B"}],
        \\ "routes":{"tracks":[{"x1":100,"y1":1,"x2":200,"y2":2,"l":0,"w":0.25,"net":"CTRL"}],"vias":[]}}]}
    });
    const after = try testApiBody(alloc, project_dir, null, null);
    try std.testing.expectEqual(@as(f64, 30), try seedXSum(alloc, after));
    try std.testing.expectEqual(@as(f64, 10), try originSeedX(alloc, after, "sm", "C_A"));

    // The quick action still resolves the star, while an exact picker request
    // returns the named pose payload and advertises every compatible choice.
    const compact = try testApiBody(alloc, project_dir, "sm", "compact");
    try std.testing.expectEqual(@as(f64, 300), try seedXSum(alloc, compact));
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, compact, .{});
    defer parsed.deinit();
    const info = parsed.value.object.get("subseedinfo").?.object.get("sm").?.object;
    try std.testing.expectEqualStrings("compact", info.get("layout").?.string);
    try std.testing.expect(!info.get("starred").?.bool);
    try std.testing.expectEqual(@as(usize, 2), info.get("layouts").?.array.items.len);
    const tracks = parsed.value.object.get("subroutes").?.object.get("sm").?.object.get("tracks").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), tracks.len);
    try std.testing.expectEqual(@as(i64, 100), tracks[0].object.get("x1").?.integer);

    const missing = try testApiBody(alloc, project_dir, "sm", "not saved");
    const missing_parsed = try std.json.parseFromSlice(std.json.Value, alloc, missing, .{});
    defer missing_parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing_parsed.value.object.get("subseedorigins").?.object.count());
}

// spec: Web Server - Saving a rigid sub-circuit from its parent PCB is the inverse of Stamp: poses, group-owned copper, and local connected traces/vias return to module coordinates, including a board-side mirror; a copper run reaching any component outside the sub-circuit remains board-owned
test "sub-circuit capture rekeys poses and owned copper into module coordinates" {
    const alloc = std.testing.allocator;
    var targets = std.StringHashMapUnmanaged(CaptureTarget).empty;
    defer targets.deinit(alloc);
    const local_a = CapturePose{ .x = 10, .y = 20, .rot = 90, .back = false };
    const local_b = CapturePose{ .x = 12, .y = 20, .rot = 0, .back = false };
    try targets.put(alloc, "U-origin", .{ .ref = "U1", .pose = local_a });
    try targets.put(alloc, "R-origin", .{ .ref = "R1", .pose = local_b });
    const to_board = CapturePose{ .x = 100, .y = 50, .rot = 90, .back = true };
    const board_a = pose_math.rigidCompose(to_board, local_a);
    const board_b = pose_math.rigidCompose(to_board, local_b);
    const submitted = [_]pcb.PartPose{
        .{ .ref = "power/U42", .x = board_a.x, .y = board_a.y, .rot = board_a.rot, .origin = "U-origin", .side = .bottom },
        .{ .ref = "power/R87", .x = board_b.x, .y = board_b.y, .rot = board_b.rot, .origin = "R-origin", .side = .bottom },
    };
    const captured = try captureParts(alloc, &submitted, &targets);
    defer alloc.free(captured.parts);
    try std.testing.expectEqualStrings("U1", captured.parts[0].ref);
    try std.testing.expectEqualStrings("R1", captured.parts[1].ref);
    try std.testing.expectApproxEqAbs(local_b.x, captured.parts[1].x, 1e-9);
    try std.testing.expectEqual(optimizer.Side.top, captured.parts[1].side);

    var names = std.StringHashMapUnmanaged([]const u8).empty;
    defer names.deinit(alloc);
    try names.put(alloc, "PARENT_VOUT", "VOUT");
    const board_start = pose_math.rigidApply(to_board, 10, 20);
    const board_end = pose_math.rigidApply(to_board, 12, 20);
    const tracks = [_]pcb.SavedTrack{.{
        .x1 = board_start[0],
        .y1 = board_start[1],
        .x2 = board_end[0],
        .y2 = board_end[1],
        .l = 1,
        .w = 0.3,
        .net = "PARENT_VOUT",
        .g = "power",
    }};
    const routes = (try captureRoutes(alloc, "power", .{ .tracks = &tracks, .vias = &.{} }, captured.transform, &.{ .names = names })).?;
    defer alloc.free(routes.tracks);
    defer alloc.free(routes.vias);
    defer alloc.free(routes.zones);
    try std.testing.expectApproxEqAbs(@as(f64, 10), routes.tracks[0].x1, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 12), routes.tracks[0].x2, 1e-9);
    try std.testing.expectEqual(@as(u8, 0), routes.tracks[0].l);
    try std.testing.expectEqualStrings("VOUT", routes.tracks[0].net);
    try std.testing.expectEqualStrings("", routes.tracks[0].g);
}
