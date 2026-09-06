//! Sub-circuit routing seeds: reusing a module's own saved copper when the
//! board that instantiates it is routed.
//!
//! Split out of `pcb_layout_page.zig`. A design that instantiates a module
//! whose module-scope layout is already routed should not re-derive that
//! copper; this module finds the rigid transform that maps the module's saved
//! parts onto the board's, replays its tracks and vias through it, and offers
//! them to the router as existing copper — then routes, and reports what was
//! actually used.
//!
//! Fail-closed and fresh-wins: a seed is only offered on a net whose board
//! identity matches, on a layer the board's policy allows, at the board's own
//! net-class geometry; a candidate that does not survive the fresh DRC pass is
//! dropped rather than persisted, and freshly routed copper always supersedes
//! a saved snapshot on the same net (a stale module snapshot must never poison
//! a valid bond). `SubcircuitRouteSeedStats` is what the route response reports.

const std = @import("std");
const env_mod = @import("../eval/env.zig");
const optimizer = @import("../placement/optimizer.zig");
const router = @import("../placement/router.zig");
const drc = @import("../placement/drc.zig");
const route_policy = @import("../placement/route_policy.zig");
const route_diagnose = @import("../placement/route_diagnose.zig");
const module_policy = @import("../placement/module_policy.zig");
const pour = @import("../placement/pour.zig");
const subcircuit_route = @import("subcircuit_route.zig");
const subcircuit_seed_drc = @import("../subcircuit_seed_drc.zig");
const route_plan = @import("route_plan.zig");
const drc_rules = @import("drc_rules.zig");
const net_names = @import("../net_name.zig");
const numeric = @import("../numeric.zig");
const clock = @import("../infra/clock.zig");
const netlist = @import("../export_kicad_netlist.zig");
const export_kicad = @import("../export_kicad.zig");
const sidecar_json = @import("layout_sidecar_json.zig");
const sidecar_store = @import("../layout_sidecar_store.zig");
const sidecar_types = @import("../layout_sidecar_types.zig");
const page = @import("pcb_layout_page.zig");
const pose_math = @import("../placement/pose_math.zig");
const pcb_layout_blob = @import("pcb_layout_blob.zig");
const saved_zone = @import("saved_zone.zig");
const geometry = @import("../placement/geometry.zig");
const fab_readiness = @import("../fab_readiness.zig");

const SavedVia = sidecar_types.SavedVia;
const SavedTrack = sidecar_types.SavedTrack;
const SavedRoutes = sidecar_types.SavedRoutes;
const SyncPose = sidecar_store.SyncPose;
const writeJsonStr = sidecar_json.writeJsonStr;
const shortName = net_names.leaf;
const savedZonePrimaryLayer = saved_zone.primaryLayer;
const pin_key_fmt = page.pin_key_fmt;
const SubPinNet = page.SubPinNet;
const SubBlockSeeds = page.SubBlockSeeds;
const subBlockPoseByOriginKey = page.subBlockPoseByOriginKey;

/// The Stamp palette's seed blobs: `poses` maps each sub-block's parent-frame
/// ref-des → its module-layout pose, `info` maps each sub-block name → which
/// module snapshot supplied the poses (`{layout, starred, n}`) so the button
/// can say what a Stamp will pull and how much of the group it covers, and
/// `mods` maps every sub-block name → its module source (palette name links).
pub const SubSeedsJson = struct { poses: []const u8 = "{}", info: []const u8 = "{}", mods: []const u8 = "{}", routes: []const u8 = "{}" };

/// JSON map of sub-block name → module source ("mcu" → "w55rp20"), for the
/// palette's name links to each module's own /pcb-layout page — emitted for
/// every sub-block, including ones with no stampable layout yet (that page is
/// exactly where you go to make one).
pub fn buildSubModulesJson(alloc: std.mem.Allocator, block: *const env_mod.DesignBlock) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    w.writeByte('{') catch return "{}";
    var first = true;
    for (block.sub_blocks) |sb| {
        if (sb.source.len == 0) continue;
        if (!first) w.writeByte(',') catch return "{}";
        first = false;
        writeJsonStr(w, sb.name) catch return "{}";
        w.writeByte(':') catch return "{}";
        writeJsonStr(w, sb.source) catch return "{}";
    }
    w.writeByte('}') catch return "{}";
    return aw.written();
}

/// Build the viewer's per-group "Stamp" seeds — drop a whole pre-laid
/// sub-circuit onto the board as a rigid cluster instead of laying its parts
/// out again. Built through the same origin_key bridge the KiCad sync seeds
/// from (subBlockPoseByOriginKey), so the poses match what a sync would stamp.
/// Both blobs are "{}" when nothing bridges.
pub fn buildSubSeedsJson(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    block: *const env_mod.DesignBlock,
    p: optimizer.Placement,
) SubSeedsJson {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    var iw_buf: std.Io.Writer.Allocating = .init(alloc);
    const iw = &iw_buf.writer;
    var rw_buf: std.Io.Writer.Allocating = .init(alloc);
    const rw = &rw_buf.writer;
    w.writeByte('{') catch return .{};
    iw.writeByte('{') catch return .{};
    rw.writeByte('{') catch return .{};
    var first = true;
    var ifirst = true;
    var rfirst = true;
    // Lazily-built parent "ref\x00pad" → net-name map (only when some module
    // snapshot actually carries copper to stamp).
    var dpin_net: ?std.StringHashMapUnmanaged([]const u8) = null;
    for (block.sub_blocks) |sb| {
        var s = subBlockPoseByOriginKey(alloc, project_dir, sb) orelse continue;
        var ok_ref = std.StringHashMapUnmanaged([]const u8).empty;
        var n: usize = 0;
        for (p.instances) |inst| {
            if (inst.ref_des.len <= sb.name.len) continue;
            if (!std.mem.startsWith(u8, inst.ref_des, sb.name) or inst.ref_des[sb.name.len] != '/') continue;
            if (inst.origin_key.len == 0) continue;
            const pose = s.map.get(inst.origin_key) orelse continue;
            ok_ref.put(alloc, inst.origin_key, inst.ref_des) catch return .{};
            if (!first) w.writeByte(',') catch return .{};
            first = false;
            n += 1;
            writeJsonStr(w, inst.ref_des) catch return .{};
            w.print(":{{\"x\":{d},\"y\":{d},\"rot\":{d}", .{ pose.x, pose.y, pose.rot }) catch return .{};
            if (pose.side == .bottom) w.writeAll(",\"side\":\"bottom\"") catch return .{};
            w.writeByte('}') catch return .{};
        }
        if (n == 0) continue;
        if (!ifirst) iw.writeByte(',') catch return .{};
        ifirst = false;
        writeJsonStr(iw, sb.name) catch return .{};
        iw.writeAll(":{\"layout\":") catch return .{};
        writeJsonStr(iw, s.layout_name) catch return .{};
        iw.print(",\"starred\":{},\"n\":{d}", .{ s.starred, n }) catch return .{};
        if (s.alt_name.len > 0) {
            iw.writeAll(",\"alt\":") catch return .{};
            writeJsonStr(iw, s.alt_name) catch return .{};
            iw.print(",\"alt_n\":{d}", .{s.alt_n}) catch return .{};
        }
        iw.writeByte('}') catch return .{};
        // The snapshot's copper, net names mapped onto this design's nets so
        // Stamp can carry the module's hand routing onto the board.
        if (s.routes) |sr| {
            if (dpin_net == null) dpin_net = designPinNetMap(alloc, p);
            const dm = if (dpin_net) |*m| m else continue;
            if (!rfirst) rw.writeByte(',') catch return .{};
            rfirst = false;
            writeJsonStr(rw, sb.name) catch return .{};
            rw.writeByte(':') catch return .{};
            const route_map = SubRouteMap{
                .pin_nets = s.pin_nets,
                .ok_ref = &ok_ref,
                .dpin_net = dm,
                .parent_nets = p.nets,
                .parent_rules = p.rules.net,
            };
            writeSubRoutesJson(rw, alloc, sb.name, sr, route_map) catch return .{};
        }
    }
    w.writeByte('}') catch return .{};
    iw.writeByte('}') catch return .{};
    rw.writeByte('}') catch return .{};
    return .{
        .poses = aw.written(),
        .info = iw_buf.written(),
        .mods = buildSubModulesJson(alloc, block),
        .routes = rw_buf.written(),
    };
}

/// Parent placement "ref\x00pad" → net NAME (raw flattened names, matching
/// the net names routed copper carries). Null on allocation failure.
fn designPinNetMap(alloc: std.mem.Allocator, p: optimizer.Placement) ?std.StringHashMapUnmanaged([]const u8) {
    var m = std.StringHashMapUnmanaged([]const u8).empty;
    for (p.nets) |net| {
        for (net.pins) |pin| {
            const key = std.fmt.allocPrint(alloc, pin_key_fmt, .{ pin.ref_des, pin.pin }) catch return null;
            m.put(alloc, key, net.name) catch return null;
        }
    }
    return m;
}

/// Serialize one module snapshot's copper for the Stamp palette: coordinates
/// stay module-local (the same frame as the seed poses — the client
/// translates by the stamp offset), net names are mapped module → parent via
/// the origin-key bridge, falling back to the "slug/NET" spelling a
/// module-private net flattens to in the parent anyway.
pub const SubRouteMap = struct {
    pin_nets: []const SubPinNet,
    ok_ref: *const std.StringHashMapUnmanaged([]const u8),
    dpin_net: *const std.StringHashMapUnmanaged([]const u8),
    parent_nets: []const export_kicad.FlatNet,
    parent_rules: []const optimizer.NetRule,
};

pub fn writeSubRoutesJson(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    slug: []const u8,
    sr: SavedRoutes,
    map: SubRouteMap,
) std.Io.Writer.Error!void {
    var net_map = std.StringHashMapUnmanaged([]const u8).empty;
    for (map.pin_nets) |ps| {
        if (net_map.contains(ps.net)) continue;
        const dref = map.ok_ref.get(ps.origin_key) orelse continue;
        const key = std.fmt.allocPrint(alloc, pin_key_fmt, .{ dref, ps.pad }) catch continue;
        const dn = map.dpin_net.get(key) orelse continue;
        net_map.put(alloc, ps.net, dn) catch break;
    }
    try w.writeAll("{\"tracks\":[");
    for (sr.tracks, 0..) |t, i| {
        if (i > 0) try w.writeAll(",");
        const net = mappedNet(alloc, &net_map, slug, t.net);
        const rule = netRuleNamed(map.parent_nets, map.parent_rules, net);
        const width = if (rule.width > 0) rule.width else t.w;
        try w.print(pcb_layout_blob.track_json_fmt, .{ t.x1, t.y1, t.x2, t.y2, t.l, width });
        try writeJsonStr(w, net);
        if (t.source.len > 0) {
            try w.writeAll(",\"source\":");
            try writeJsonStr(w, t.source);
        }
        try pcb_layout_blob.writeTrackSegmentId(w, t, i);
        try w.writeAll("}");
    }
    try w.writeAll(pcb_layout_blob.vias_arr_open);
    for (sr.vias, 0..) |vi, i| {
        if (i > 0) try w.writeAll(",");
        const net = mappedNet(alloc, &net_map, slug, vi.net);
        const rule = netRuleNamed(map.parent_nets, map.parent_rules, net);
        const dia = if (rule.via_dia > 0) rule.via_dia else vi.d;
        const drill = if (rule.via_drill > 0) rule.via_drill else vi.drill;
        try w.print(pcb_layout_blob.via_json_fmt, .{ vi.x, vi.y, dia, drill });
        try writeJsonStr(w, net);
        if (vi.source.len > 0) {
            try w.writeAll(",\"source\":");
            try writeJsonStr(w, vi.source);
        }
        try pcb_layout_blob.writeViaId(w, vi, i);
        try w.writeAll("}");
    }
    try w.writeAll("],\"zones\":[");
    var first_zone = true;
    for (sr.zones) |z| {
        // Stamp conductive custom pours only. Keepouts are contextual geometry,
        // while declared planes / stackup pours never live in SavedRoutes.zones
        // at all and therefore cannot leak into this payload.
        if (!z.flags.filled or z.flags.keepout) continue;
        if (z.net.len == 0 or z.poly.len < 3) continue;
        if (!first_zone) try w.writeByte(',') else first_zone = false;
        try w.writeAll("{\"net\":");
        try writeJsonStr(w, mappedNet(alloc, &net_map, slug, z.net));
        try w.writeAll(",\"layer\":");
        try writeJsonStr(w, savedZonePrimaryLayer(&z));
        if (z.layers.len > 1) {
            try w.writeAll(",\"layers\":[");
            for (z.layers, 0..) |layer_name, li| {
                if (li > 0) try w.writeByte(',');
                try writeJsonStr(w, layer_name);
            }
            try w.writeByte(']');
        }
        try w.writeAll(",\"poly\":[");
        for (z.poly, 0..) |point, pi| {
            if (pi > 0) try w.writeByte(',');
            try w.print(pcb_layout_blob.pt_pair_fmt, .{ point[0], point[1] });
        }
        try w.writeAll("],\"filled\":true,\"keepout\":false");
        if (z.priority != 0) try w.print(",\"priority\":{d}", .{z.priority});
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

fn netRuleNamed(
    nets: []const export_kicad.FlatNet,
    rules: []const optimizer.NetRule,
    name: []const u8,
) optimizer.NetRule {
    for (nets, 0..) |net, i| {
        if (i >= rules.len) break;
        if (std.ascii.eqlIgnoreCase(net.name, name)) return rules[i];
    }
    return .{};
}

/// A stamped-copper net name in the parent design's namespace: the bridged
/// parent net when a module pin on the net resolved, else "slug/NET" (the
/// flatten's stitching spelling for a module-private net), else "".
fn mappedNet(
    alloc: std.mem.Allocator,
    net_map: *const std.StringHashMapUnmanaged([]const u8),
    slug: []const u8,
    net: []const u8,
) []const u8 {
    if (net.len == 0) return "";
    if (net_map.get(net)) |m| return m;
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ slug, net }) catch net;
}

/// What automatic hierarchical routing recovered from isolated sub-circuit
/// passes and reusable module snapshots. Candidate counts are the copper before
/// board-level compatibility filtering; accepted counts are the same-net
/// sources actually handed to the global router.
pub const SubcircuitRouteSeedStats = struct {
    copper: struct {
        candidate_tracks: usize = 0,
        candidate_vias: usize = 0,
        accepted_nets: usize = 0,
        accepted_tracks: usize = 0,
        accepted_vias: usize = 0,
        rejected_nets: usize = 0,
    } = .{},
    phase: struct {
        attempted_subcircuits: usize = 0,
        completed_subcircuits: usize = 0,
        timed_out_subcircuits: usize = 0,
        deferred_supply_nets: usize = 0,
        accepted_carrier_drops: usize = 0,
    } = .{},
    /// Kept for response compatibility. Deterministic local-first routing never
    /// abandons all accepted local copper for a plain global candidate.
    fallback: bool = false,
};

const SeedTrack = subcircuit_route.SeedTrack;

const SeedVia = subcircuit_route.SeedVia;

const SeedAccumulator = struct {
    tracks: std.ArrayList(SeedTrack) = .empty,
    vias: std.ArrayList(SeedVia) = .empty,
    rejected: []bool,
    candidate: []bool,
    isolated: []const bool,
    supply: []const bool,
    stats: SubcircuitRouteSeedStats = .{},
};

const SeedContext = struct {
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    options: route_policy.Options,
    supply: []const bool,
    acc: *SeedAccumulator,
};

/// Rigid transform shared by module poses and their saved copper. This is the
/// server-side twin of the Stamp palette's `stampPose*` algebra: mirror local X
/// for a bottom-side group, then rotate in the board's y-down frame.
const SeedPose = struct {
    x: f64 = 0,
    y: f64 = 0,
    rot: f64 = 0,
    back: bool = false,

    fn linear(self: SeedPose, x: f64, y: f64) [2]f64 {
        const mx = if (self.back) -x else x;
        return pose_math.rotate(mx, y, self.rot);
    }

    fn apply(self: SeedPose, x: f64, y: f64) [2]f64 {
        const p = self.linear(x, y);
        return .{ p[0] + self.x, p[1] + self.y };
    }

    fn compose(self: SeedPose, other: SeedPose) SeedPose {
        const t = self.linear(other.x, other.y);
        return .{
            .x = t[0] + self.x,
            .y = t[1] + self.y,
            .rot = @mod(self.rot + (if (self.back) -other.rot else other.rot), 360.0),
            .back = self.back != other.back,
        };
    }

    fn inverse(self: SeedPose) SeedPose {
        var out = SeedPose{ .rot = @mod(if (self.back) self.rot else -self.rot, 360.0), .back = self.back };
        const t = out.linear(self.x, self.y);
        out.x = -t[0];
        out.y = -t[1];
        return out;
    }
};

const SeedHit = struct { part: usize, module: SyncPose };

const SeedNet = struct { parent: i32 = -1, compatible: bool = true, sampled: bool = false };

fn seedPoseFromSync(p: SyncPose) SeedPose {
    return .{ .x = p.x, .y = p.y, .rot = p.rot, .back = p.side == .bottom };
}

fn seedPoseFromPart(p: optimizer.Part) SeedPose {
    return .{ .x = p.x, .y = p.y, .rot = p.rot, .back = p.side == .bottom };
}

const seed_pose_tolerance_mm: f64 = 0.075;

fn seedPosesMatch(a: SeedPose, b: SeedPose) bool {
    if (a.back != b.back or std.math.hypot(a.x - b.x, a.y - b.y) > seed_pose_tolerance_mm) return false;
    const d = @abs(@mod(a.rot - b.rot + 540.0, 360.0) - 180.0);
    return d < 0.1;
}

fn subcircuitPartIndex(placement: optimizer.Placement, slug: []const u8, origin: []const u8) ?usize {
    for (placement.instances, 0..) |inst, i| {
        if (i >= placement.parts.len or inst.origin_key.len == 0 or !std.mem.eql(u8, inst.origin_key, origin)) continue;
        if (inst.ref_des.len > slug.len and std.mem.startsWith(u8, inst.ref_des, slug) and inst.ref_des[slug.len] == '/') return i;
    }
    return null;
}

fn boardNetAtPin(placement: optimizer.Placement, part: usize, pad: []const u8) ?usize {
    if (part >= placement.instances.len) return null;
    const ref = placement.instances[part].ref_des;
    for (placement.nets, 0..) |net, ni| for (net.pins) |pin| {
        if (std.mem.eql(u8, pin.ref_des, ref) and std.mem.eql(u8, pin.pin, pad)) return ni;
    };
    return null;
}

fn seedHits(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    slug: []const u8,
    seeds: SubBlockSeeds,
) std.mem.Allocator.Error![]const SeedHit {
    var out: std.ArrayList(SeedHit) = .empty;
    for (placement.instances, 0..) |inst, i| {
        if (i >= placement.parts.len or inst.origin_key.len == 0) continue;
        if (inst.ref_des.len <= slug.len or !std.mem.startsWith(u8, inst.ref_des, slug) or inst.ref_des[slug.len] != '/') continue;
        const pose = seeds.map.get(inst.origin_key) orelse continue;
        try out.append(alloc, .{ .part = i, .module = pose });
    }
    return out.toOwnedSlice(alloc);
}

fn seedTransformScore(placement: optimizer.Placement, hits: []const SeedHit, xf: SeedPose) usize {
    var score: usize = 0;
    for (hits) |hit| {
        const expected = xf.compose(seedPoseFromSync(hit.module));
        if (seedPosesMatch(expected, seedPoseFromPart(placement.parts[hit.part]))) score += 1;
    }
    return score;
}

fn bestSeedTransform(placement: optimizer.Placement, hits: []const SeedHit) ?SeedPose {
    var best: ?SeedPose = null;
    var best_score: usize = 0;
    var best_rank: f64 = -1;
    for (hits) |hit| {
        const board = seedPoseFromPart(placement.parts[hit.part]);
        const xf = board.compose(seedPoseFromSync(hit.module).inverse());
        const score = seedTransformScore(placement, hits, xf);
        const part = placement.parts[hit.part];
        const hub_rank: f64 = if (part.kind == .hub) 1.0e9 else 0.0;
        const rank = hub_rank + part.hw * part.hh;
        if (best == null or score > best_score or (score == best_score and rank > best_rank)) {
            best = xf;
            best_score = score;
            best_rank = rank;
        }
    }
    return best;
}

fn classifySeedNets(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    slug: []const u8,
    seeds: SubBlockSeeds,
    xf: SeedPose,
) std.mem.Allocator.Error!std.StringHashMapUnmanaged(SeedNet) {
    var out = std.StringHashMapUnmanaged(SeedNet).empty;
    for (seeds.pin_nets) |sample| {
        const gop = try out.getOrPut(alloc, sample.net);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const pi = subcircuitPartIndex(placement, slug, sample.origin_key) orelse {
            gop.value_ptr.compatible = false;
            continue;
        };
        const parent = boardNetAtPin(placement, pi, sample.pad) orelse {
            gop.value_ptr.compatible = false;
            continue;
        };
        if (gop.value_ptr.sampled and gop.value_ptr.parent != @as(i32, @intCast(parent))) gop.value_ptr.compatible = false;
        gop.value_ptr.parent = @intCast(parent);
        gop.value_ptr.sampled = true;
        const module_pose = seeds.map.get(sample.origin_key) orelse {
            gop.value_ptr.compatible = false;
            continue;
        };
        const expected = xf.compose(seedPoseFromSync(module_pose));
        if (!seedPosesMatch(expected, seedPoseFromPart(placement.parts[pi]))) gop.value_ptr.compatible = false;
    }
    return out;
}

fn seedNetEnabled(options: route_policy.Options, net: usize) bool {
    return options.selected_nets.len == 0 or (net < options.selected_nets.len and options.selected_nets[net]);
}

/// A saved module tree may seed the same local fragment a fresh isolated route
/// would: at least two terminals inside this first-level sub-circuit. The later
/// assembled-board pass joins any boundary legs to that frozen local source.
fn seedNetIsLocal(placement: optimizer.Placement, slug: []const u8, net: usize) bool {
    if (net >= placement.nets.len or placement.nets[net].pins.len < 2) return false;
    var local: usize = 0;
    for (placement.nets[net].pins) |pin| {
        if (pin.ref_des.len > slug.len and std.mem.startsWith(u8, pin.ref_des, slug) and pin.ref_des[slug.len] == '/') local += 1;
    }
    return local >= 2;
}

fn seedLayerAllowed(placement: optimizer.Placement, options: route_policy.Options, net: usize, layer: u8) bool {
    if (layer >= placement.rules.signalLayerCount()) return false;
    if (net >= options.net.len or options.net[net].allowed_layers == 0) return true;
    return layer < 64 and (options.net[net].allowed_layers & (@as(u64, 1) << @intCast(layer))) != 0;
}

/// Signal-layer indices are stackup-independent for the two outer layers:
/// 0=F.Cu and 1=B.Cu even on Board A's six-layer stack. A bottom-side rigid
/// stamp swaps those two; inner saved indices remain in the destination's
/// signal-layer namespace and are accepted only when that layer exists.
fn seedLayerFromModule(placement: optimizer.Placement, xf: SeedPose, saved: u8) ?u8 {
    const count = placement.rules.signalLayerCount();
    if (saved >= count) return null;
    return if (xf.back and saved < 2) 1 - saved else saved;
}

fn seedTrackWidth(placement: optimizer.Placement, params: router.RouteParams, net: usize, saved: f64) f64 {
    if (net < placement.rules.net.len and placement.rules.net[net].width > 0) return placement.rules.net[net].width;
    if (saved > 0) return saved;
    return params.track_width;
}

fn needsSavedSeedFallback(isolated: []const bool, net: usize) bool {
    return net >= isolated.len or !isolated[net];
}

fn seedViaGeometry(placement: optimizer.Placement, params: router.RouteParams, net: usize, saved: SavedVia) [2]f64 {
    const rule = if (net < placement.rules.net.len) placement.rules.net[net] else optimizer.NetRule{};
    const dia = if (rule.via_dia > 0) rule.via_dia else if (saved.d > 0) saved.d else params.via_dia;
    const drill = if (rule.via_drill > 0) rule.via_drill else if (saved.drill > 0) saved.drill else params.via_drill;
    return .{ dia, drill };
}

fn appendModuleSeedCopper(
    ctx: *SeedContext,
    slug: []const u8,
    seeds: SubBlockSeeds,
    xf: SeedPose,
) std.mem.Allocator.Error!void {
    const routes = seeds.routes orelse return;
    const nets = try classifySeedNets(ctx.alloc, ctx.placement, slug, seeds, xf);
    for (routes.tracks) |saved| {
        const mapped = nets.get(saved.net) orelse continue;
        if (!mapped.sampled or mapped.parent < 0) continue;
        const ni: usize = @intCast(mapped.parent);
        if (!seedNetEnabled(ctx.options, ni)) continue;
        const supply = ni < ctx.supply.len and ctx.supply[ni];
        if (supply and !subcircuit_route.savedSupplyFallbackAllowed(ctx.placement, ctx.options, slug, ni)) continue;
        if (!supply and ctx.placement.rules.carriesPlane(ctx.placement.nets[ni].name)) continue;
        // Accepted fresh copper is authoritative. A rejected local candidate
        // must leave this saved-module alternative available.
        if (!needsSavedSeedFallback(ctx.acc.isolated, ni)) continue;
        ctx.acc.candidate[ni] = true;
        ctx.acc.stats.copper.candidate_tracks += 1;
        if (!seedNetIsLocal(ctx.placement, slug, ni)) {
            ctx.acc.rejected[ni] = true;
            continue;
        }
        // A moved remote supply terminal does not invalidate unchanged local copper.
        if (!mapped.compatible and !supply) {
            ctx.acc.rejected[ni] = true;
            continue;
        }
        const layer = seedLayerFromModule(ctx.placement, xf, saved.l) orelse {
            ctx.acc.rejected[ni] = true;
            continue;
        };
        if (!seedLayerAllowed(ctx.placement, ctx.options, ni, layer)) {
            ctx.acc.rejected[ni] = true;
            continue;
        }
        const a = xf.apply(saved.x1, saved.y1);
        const b = xf.apply(saved.x2, saved.y2);
        try ctx.acc.tracks.append(ctx.alloc, .{ .net = ni, .copper = .{
            .x1 = a[0],
            .y1 = a[1],
            .x2 = b[0],
            .y2 = b[1],
            .layer = layer,
            .width = seedTrackWidth(ctx.placement, ctx.params, ni, saved.w),
            .net = @intCast(ni),
        } });
    }
    for (routes.vias) |saved| {
        const mapped = nets.get(saved.net) orelse continue;
        if (!mapped.sampled or mapped.parent < 0) continue;
        const ni: usize = @intCast(mapped.parent);
        if (!seedNetEnabled(ctx.options, ni)) continue;
        const supply = ni < ctx.supply.len and ctx.supply[ni];
        if (supply and !subcircuit_route.savedSupplyFallbackAllowed(ctx.placement, ctx.options, slug, ni)) continue;
        if (supply and !subcircuit_route.savedNetUsesMultipleLayers(routes.tracks, saved.net)) continue;
        if (!supply and ctx.placement.rules.carriesPlane(ctx.placement.nets[ni].name)) continue;
        if (!needsSavedSeedFallback(ctx.acc.isolated, ni)) continue;
        ctx.acc.candidate[ni] = true;
        ctx.acc.stats.copper.candidate_vias += 1;
        if (!seedNetIsLocal(ctx.placement, slug, ni)) {
            ctx.acc.rejected[ni] = true;
            continue;
        }
        if (!mapped.compatible and !supply) {
            ctx.acc.rejected[ni] = true;
            continue;
        }
        const p = xf.apply(saved.x, saved.y);
        const geom = seedViaGeometry(ctx.placement, ctx.params, ni, saved);
        try ctx.acc.vias.append(ctx.alloc, .{ .net = ni, .copper = .{
            .x = p[0],
            .y = p[1],
            .dia = geom[0],
            .drill = geom[1],
            .net = @intCast(ni),
        } });
    }
}

fn appendSubcircuitCandidate(
    ctx: *SeedContext,
    project_dir: []const u8,
    sb: env_mod.SubBlock,
) std.mem.Allocator.Error!void {
    const seeds = subBlockPoseByOriginKey(ctx.alloc, project_dir, sb) orelse return;
    if (!seeds.starred or seeds.routes == null or seeds.pin_nets.len == 0) return;
    const hits = try seedHits(ctx.alloc, ctx.placement, sb.name, seeds);
    const xf = bestSeedTransform(ctx.placement, hits) orelse return;
    try appendModuleSeedCopper(ctx, sb.name, seeds, xf);
}

fn validateSeedCandidates(ctx: SeedContext) std.mem.Allocator.Error!void {
    try subcircuit_seed_drc.reject(ctx.alloc, .{
        .placement = ctx.placement,
        .params = ctx.params,
        .options = ctx.options,
        .rejected = ctx.acc.rejected,
        .tracks = ctx.acc.tracks.items,
        .vias = ctx.acc.vias.items,
        .track_list = &ctx.acc.tracks,
        .via_list = &ctx.acc.vias,
        .candidate = ctx.acc.candidate,
    });
}

// spec: serve/subcircuit-route - saved module copper can replace a rejected fresh candidate but cannot supersede or collide with accepted fresh copper
test "hierarchical saved fallback follows fresh DRC acceptance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.8, .h = 0.8 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "m/A", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false },
        .{ .ref_des = "m/B", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 4 },
        .{ .ref_des = "m/C", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .y = 3 },
        .{ .ref_des = "m/D", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 4, .y = 3 },
    };
    const a_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "m/A", .pin = "1" }, .{ .ref_des = "m/B", .pin = "1" } };
    const b_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "m/C", .pin = "1" }, .{ .ref_des = "m/D", .pin = "1" } };
    const nets = [_]optimizer.FlatNet{ .{ .name = "m/FIRST", .pins = &a_pins }, .{ .name = "m/SECOND", .pins = &b_pins } };
    var instances: [4]export_kicad.FlatInstance = undefined;
    var poses = std.StringHashMapUnmanaged(SyncPose).empty;
    var pin_nets: [4]SubPinNet = undefined;
    for (parts, 0..) |part, i| {
        const origin = part.ref_des[2..];
        instances[i] = .{ .ref_des = part.ref_des, .origin_key = origin, .component = "pad", .value = "", .footprint = "", .properties = &.{}, .uuid = "" };
        try poses.put(alloc, origin, .{ .x = part.x, .y = part.y, .rot = 0 });
        pin_nets[i] = .{ .net = if (i < 2) "FIRST" else "SECOND", .origin_key = origin, .pad = "1" };
    }
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &instances,
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 5,
        .maxy = 4,
        .generated = false,
        .rules = .{ .copper_layers = 2, .plane_nets = &.{} },
    };
    var rejected = [_]bool{ false, false };
    var candidate = [_]bool{ true, true };
    var acc = SeedAccumulator{ .rejected = &rejected, .candidate = &candidate, .isolated = &.{ true, true }, .supply = &.{ false, false } };
    try acc.tracks.appendSlice(alloc, &.{
        .{ .net = 0, .copper = .{ .x1 = 0, .y1 = 0, .x2 = 4, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 } },
        .{ .net = 1, .copper = .{ .x1 = 0, .y1 = 3, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 1 } },
        .{ .net = 1, .copper = .{ .x1 = 2, .y1 = 0, .x2 = 4, .y2 = 3, .layer = 0, .width = 0.2, .net = 1 } },
    });
    var ctx = SeedContext{ .alloc = alloc, .placement = placement, .params = .{}, .options = .{}, .supply = acc.supply, .acc = &acc };
    try validateSeedCandidates(ctx);
    try std.testing.expect(!rejected[0] and rejected[1]);
    acc.isolated = try subcircuit_seed_drc.retainAccepted(SeedAccumulator, alloc, &acc);
    try std.testing.expect(acc.isolated[0] and !acc.isolated[1]);
    try std.testing.expectEqual(@as(usize, 1), acc.tracks.items.len);
    // Without a fallback, the discarded fresh candidate must still report as
    // rejected, not as an accepted net with no copper.
    try subcircuit_seed_drc.rejectEmpty(SeedAccumulator, alloc, &acc);
    try std.testing.expect(rejected[1]);
    rejected[1] = false;
    const saved = [_]SavedTrack{
        .{ .x1 = 0, .y1 = 0, .x2 = 4, .y2 = 0, .l = 0, .w = 0.4, .net = "FIRST" },
        .{ .x1 = 0, .y1 = 3, .x2 = 4, .y2 = 3, .l = 0, .w = 0.2, .net = "SECOND" },
    };
    const seeds = SubBlockSeeds{ .map = poses, .layout_name = "saved", .starred = true, .pin_nets = &pin_nets, .routes = .{ .tracks = &saved, .vias = &.{} } };
    try appendModuleSeedCopper(&ctx, "m", seeds, .{});
    try validateSeedCandidates(ctx);
    try subcircuit_seed_drc.rejectEmpty(SeedAccumulator, alloc, &acc);
    try std.testing.expect(!rejected[0] and !rejected[1]);
    try std.testing.expectEqual(@as(usize, 2), acc.tracks.items.len);
    try std.testing.expectEqual(@as(f64, 0.2), acc.tracks.items[0].copper.width);
    var options = route_policy.Options{};
    try mergeAcceptedSeeds(alloc, &options, &acc);
    const retained = try route_plan.retainedCopper(alloc, options, &.{});
    const tally = try fab_readiness.routableTally(alloc, placement, retained);
    try std.testing.expectEqual(@as(usize, 2), tally.routed);

    // A conflicting fallback is refused without evicting the fresh survivor.
    acc.tracks.items[1].copper.y2 = 0;
    try validateSeedCandidates(ctx);
    try std.testing.expect(!rejected[0] and rejected[1]);
}

fn sameSeedTrack(a: route_policy.ExistingTrack, b: route_policy.ExistingTrack) bool {
    return a.net == b.net and a.layer == b.layer and a.width == b.width and
        a.x1 == b.x1 and a.y1 == b.y1 and a.x2 == b.x2 and a.y2 == b.y2;
}

fn sameSeedVia(a: route_policy.ExistingVia, b: route_policy.ExistingVia) bool {
    return a.net == b.net and a.x == b.x and a.y == b.y and a.dia == b.dia and a.drill == b.drill;
}

fn containsSeedTrack(items: []const route_policy.ExistingTrack, want: route_policy.ExistingTrack) bool {
    for (items) |item| if (sameSeedTrack(item, want)) return true;
    return false;
}

fn containsSeedVia(items: []const route_policy.ExistingVia, want: route_policy.ExistingVia) bool {
    for (items) |item| if (sameSeedVia(item, want)) return true;
    return false;
}

fn mergeAcceptedSeeds(
    alloc: std.mem.Allocator,
    options: *route_policy.Options,
    acc: *SeedAccumulator,
) std.mem.Allocator.Error!void {
    var tracks: std.ArrayList(route_policy.ExistingTrack) = .empty;
    try tracks.appendSlice(alloc, options.existing_tracks);
    var vias: std.ArrayList(route_policy.ExistingVia) = .empty;
    try vias.appendSlice(alloc, options.existing_vias);
    const accepted_vias = try alloc.alloc(u16, acc.rejected.len);
    @memset(accepted_vias, 0);
    for (acc.tracks.items) |item| {
        if (acc.rejected[item.net]) continue;
        if (containsSeedTrack(tracks.items, item.copper)) continue;
        try tracks.append(alloc, item.copper);
        acc.stats.copper.accepted_tracks += 1;
    }
    for (acc.vias.items) |item| {
        if (acc.rejected[item.net]) continue;
        if (containsSeedVia(vias.items, item.copper)) continue;
        try vias.append(alloc, item.copper);
        accepted_vias[item.net] +|= 1;
        acc.stats.copper.accepted_vias += 1;
        if (item.carrier_drop) acc.stats.phase.accepted_carrier_drops += 1;
    }
    const policies = try alloc.dupe(route_policy.NetPolicy, options.net);
    for (accepted_vias, 0..) |count, ni| if (count > 0 and ni < policies.len) {
        if (policies[ni].max_vias) |limit| policies[ni].max_vias = limit -| count;
    };
    options.net = policies;
    options.existing_tracks = tracks.items;
    options.existing_vias = vias.items;
}

/// Route every sub-circuit first in a component-only view, then add compatible
/// starred module copper only for nets without accepted fresh local copper. The
/// assembled board's rules and DRC are authoritative: disallowed layers / via
/// budgets reject a net, and a board DRC error drops that net's local copper
/// before the global maze sees it.
pub fn addSubcircuitRouteSeeds(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
    params: router.RouteParams,
    options: *route_policy.Options,
) std.mem.Allocator.Error!SubcircuitRouteSeedStats {
    if (block.sub_blocks.len == 0 or placement.nets.len == 0) return .{};
    const rejected = try alloc.alloc(bool, placement.nets.len);
    @memset(rejected, false);
    const candidate = try alloc.alloc(bool, placement.nets.len);
    @memset(candidate, false);
    const supply = try alloc.alloc(bool, placement.nets.len);
    var detected = try module_policy.analyze(alloc, placement);
    defer detected.deinit(alloc);
    for (supply, 0..) |*yes, ni| {
        yes.* = if (ni < detected.net_class.len) switch (detected.net_class[ni]) {
            .ground, .power, .input_rail => true,
            else => false,
        } else false;
    }
    const local = try subcircuit_route.routeAllClassified(alloc, block, placement, params, options.*, supply);
    @memcpy(candidate, local.nets);
    var acc = SeedAccumulator{ .rejected = rejected, .candidate = candidate, .isolated = local.nets, .supply = supply };
    try acc.tracks.appendSlice(alloc, local.tracks);
    try acc.vias.appendSlice(alloc, local.vias);
    acc.stats.copper.candidate_tracks = local.tracks.len;
    acc.stats.copper.candidate_vias = local.vias.len;
    acc.stats.phase.attempted_subcircuits = local.phase.attempted_subcircuits;
    acc.stats.phase.completed_subcircuits = local.phase.completed_subcircuits;
    acc.stats.phase.timed_out_subcircuits = local.phase.timed_out_subcircuits;
    acc.stats.phase.deferred_supply_nets = local.phase.deferred_supply_nets;
    var ctx = SeedContext{ .alloc = alloc, .placement = placement, .params = params, .options = options.*, .supply = supply, .acc = &acc };
    try validateSeedCandidates(ctx);
    acc.isolated = try subcircuit_seed_drc.retainAccepted(SeedAccumulator, alloc, &acc);
    const fresh_tracks = acc.tracks.items.len;
    const fresh_vias = acc.vias.items.len;
    for (block.sub_blocks) |sb| try appendSubcircuitCandidate(&ctx, project_dir, sb);
    // Fresh survivors precede saved alternatives, preserving their channels
    // when a fallback collides. Avoid repeating the gate with no added copper.
    if (acc.tracks.items.len != fresh_tracks or acc.vias.items.len != fresh_vias)
        try validateSeedCandidates(ctx);
    try subcircuit_seed_drc.rejectEmpty(SeedAccumulator, alloc, &acc);
    for (local.complete_planes, 0..) |complete, ni| {
        if (complete and rejected[ni]) acc.stats.phase.deferred_supply_nets += 1;
    }
    try mergeAcceptedSeeds(alloc, options, &acc);
    for (candidate, 0..) |was_candidate, ni| if (was_candidate) {
        if (rejected[ni]) acc.stats.copper.rejected_nets += 1 else acc.stats.copper.accepted_nets += 1;
    };
    const global_scope = try alloc.alloc(bool, placement.nets.len);
    if (options.selected_nets.len == 0)
        @memset(global_scope, true)
    else for (global_scope, 0..) |*yes, ni|
        yes.* = ni < options.selected_nets.len and options.selected_nets[ni];
    // The whole retained bundle, pours included: the same oracle describe and
    // fabrication run, which reads a net joined through a pour as connected.
    const retained = try route_plan.retainedCopper(alloc, options.*, try route_plan.retainedZones(alloc, placement, options.*));
    const connectivity = try fab_readiness.netConnectivity(alloc, placement, retained);
    for (local.complete_planes, 0..) |complete, ni| {
        // The same oracle used by describe/fabrication decides whether the
        // retained local drops really joined every terminal. Complete carrier
        // nets stay frozen; only a physically open carrier re-enters the global
        // plane pass, where retainedStubMm prevents duplicate barrels.
        if (!complete or rejected[ni] or ni >= connectivity.len) continue;
        if (!connectivity[ni].routable or connectivity[ni].connected) {
            global_scope[ni] = false;
        } else {
            acc.stats.phase.deferred_supply_nets += 1;
        }
    }
    options.selected_nets = global_scope;
    return acc.stats;
}

fn seedWasUsed(stats: SubcircuitRouteSeedStats) bool {
    return !stats.fallback and (stats.copper.accepted_tracks > 0 or stats.copper.accepted_vias > 0);
}

pub fn armRouteDeadline(options: *route_policy.Options) void {
    if (options.stop.deadline_ns != 0 or options.stop.max_route_ms == 0) return;
    options.stop.deadline_ns = clock.nanoTimestamp() +
        @as(i128, @intCast(options.stop.max_route_ms)) * @as(i128, clock.ns_per_ms);
}

/// Run every sub-circuit locally, freeze its accepted copper, then run exactly
/// one assembled-board route. The local phase internally reserves three
/// quarters of any authored deadline for this global pass.
pub fn routeWithSubcircuitSeeds(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
    params: router.RouteParams,
    base_options: route_policy.Options,
) std.mem.Allocator.Error!struct { result: router.RouteResult, seeds: SubcircuitRouteSeedStats = .{} } {
    var bounded_base = base_options;
    armRouteDeadline(&bounded_base);
    var seeded_options = bounded_base;
    const stats = try addSubcircuitRouteSeeds(alloc, project_dir, block, placement, params, &seeded_options);
    return .{ .result = try route_plan.routeLowered(alloc, placement, params, seeded_options), .seeds = stats };
}

/// Diagnostic twin of `routeWithSubcircuitSeeds`, preserving the same strict
/// local-then-global order and one-global-candidate contract.
pub fn diagnoseWithSubcircuitSeeds(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
    params: router.RouteParams,
    base_options: route_policy.Options,
) std.mem.Allocator.Error!struct { diagnostic: route_plan.PlannedDiagnostic, seeds: SubcircuitRouteSeedStats = .{} } {
    var bounded_base = base_options;
    armRouteDeadline(&bounded_base);
    var seeded_options = bounded_base;
    const stats = try addSubcircuitRouteSeeds(alloc, project_dir, block, placement, params, &seeded_options);
    return .{ .diagnostic = try route_plan.routeLoweredDiagnostic(alloc, placement, params, seeded_options), .seeds = stats };
}

pub fn writeRouteSeedStats(w: *std.Io.Writer, stats: SubcircuitRouteSeedStats) std.Io.Writer.Error!void {
    try w.print(
        ",\"subcircuit_seeds\":{{\"candidate_tracks\":{d},\"candidate_vias\":{d}," ++
            "\"accepted_nets\":{d},\"accepted_tracks\":{d},\"accepted_vias\":{d},\"rejected_nets\":{d}," ++
            "\"attempted_subcircuits\":{d},\"completed_subcircuits\":{d},\"timed_out_subcircuits\":{d}," ++
            "\"deferred_supply_nets\":{d},\"accepted_carrier_drops\":{d},\"used\":{},\"fallback\":{}}}",
        .{
            stats.copper.candidate_tracks,
            stats.copper.candidate_vias,
            stats.copper.accepted_nets,
            stats.copper.accepted_tracks,
            stats.copper.accepted_vias,
            stats.copper.rejected_nets,
            stats.phase.attempted_subcircuits,
            stats.phase.completed_subcircuits,
            stats.phase.timed_out_subcircuits,
            stats.phase.deferred_supply_nets,
            stats.phase.accepted_carrier_drops,
            seedWasUsed(stats),
            stats.fallback,
        },
    );
}

// spec: Web Server - Route responses report attempted, completed, and timed-out local sub-circuits, deferred supply nets, and accepted carrier drops while the compatibility fallback flag remains false
test "route response exposes deterministic local phase statistics" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeRouteSeedStats(&aw.writer, .{ .phase = .{ .attempted_subcircuits = 3, .completed_subcircuits = 2, .timed_out_subcircuits = 1, .deferred_supply_nets = 4, .accepted_carrier_drops = 5 } });
    const json = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"attempted_subcircuits\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"accepted_carrier_drops\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"fallback\":false") != null);
}

// spec: Web Server - A fresh isolated candidate supersedes saved module copper on the same net, including supply nets, so stale snapshots cannot poison valid bypass bonds.
test "fresh isolated supply copper suppresses its saved snapshot" {
    try std.testing.expect(!needsSavedSeedFallback(&.{true}, 0));
    try std.testing.expect(needsSavedSeedFallback(&.{false}, 0));
    try std.testing.expect(needsSavedSeedFallback(&.{}, 0));
}
