//! Convert generated physical copper to persisted, net-named layout records.
const std = @import("std");
const router = @import("placement/router.zig");
const outline_mod = @import("placement/outline.zig");
const export_kicad = @import("export_kicad.zig");
const sidecar_types = @import("layout_sidecar_types.zig");
const SavedRoutes = sidecar_types.SavedRoutes;
const SavedTrack = sidecar_types.SavedTrack;
const SavedVia = sidecar_types.SavedVia;
const SavedRfPath = sidecar_types.SavedRfPath;
const route_source_autorouter = sidecar_types.route_source_autorouter;

/// Net NAME at flattened-net index `idx` (−1 / out-of-range ⇒ "" — foreign
/// copper the sidecar still stores). Inverse of `restoreRoutes`' name→index.
pub fn netNameAt(nets: []const export_kicad.FlatNet, idx: i32) []const u8 {
    if (idx < 0) return "";
    const u: usize = @intCast(idx);
    return if (u < nets.len) nets[u].name else "";
}

pub fn arcOwnsTrack(arcs: []const router.Arc, track: router.Track) bool {
    for (arcs) |arc| {
        if (arc.layer != track.layer or arc.net != track.net or @abs(arc.width - track.width) > 0.0001) continue;
        if (outline_mod.arcOwnsSegment(.{ .p1 = arc.p1, .pm = arc.pm, .p2 = arc.p2 }, .{ track.x1, track.y1 }, .{ track.x2, track.y2 }, 0.0001)) return true;
    }
    return false;
}

fn savedTrackMetadataMatch(candidate: SavedTrack, saved: SavedTrack) bool {
    if (candidate.l != saved.l or @abs(candidate.w - saved.w) > 1e-9) return false;
    return std.mem.eql(u8, candidate.net, saved.net);
}

fn savedViaMetadataMatch(candidate: SavedVia, saved: SavedVia) bool {
    if (@abs(candidate.x - saved.x) > 1e-9 or @abs(candidate.y - saved.y) > 1e-9) return false;
    if (@abs(candidate.d - saved.d) > 1e-9 or @abs(candidate.drill - saved.drill) > 1e-9) return false;
    return std.mem.eql(u8, candidate.net, saved.net);
}

/// A router `RouteResult` → the sidecar's `SavedRoutes` shape (net INDEX →
/// net NAME, so the copper survives the next flatten's index shuffle). The
/// persistence counterpart of `restoreRoutes`.
pub fn fromResult(
    alloc: std.mem.Allocator,
    r: router.RouteResult,
    nets: []const export_kicad.FlatNet,
    prior: ?SavedRoutes,
) std.mem.Allocator.Error!SavedRoutes {
    var tracks: std.ArrayList(SavedTrack) = .empty;
    for (r.tracks) |t| {
        if (arcOwnsTrack(r.arcs, t)) continue;
        var saved = SavedTrack{
            .x1 = t.x1,
            .y1 = t.y1,
            .x2 = t.x2,
            .y2 = t.y2,
            .l = t.layer,
            .w = t.width,
            .net = netNameAt(nets, t.net),
        };
        var matched_prior = false;
        if (prior) |old| for (old.tracks) |candidate| {
            if (candidate.xm != null or candidate.ym != null) continue;
            if (!savedTrackMetadataMatch(candidate, saved)) continue;
            const forward = @abs(candidate.x1 - saved.x1) <= 1e-9 and @abs(candidate.y1 - saved.y1) <= 1e-9 and
                @abs(candidate.x2 - saved.x2) <= 1e-9 and @abs(candidate.y2 - saved.y2) <= 1e-9;
            const reverse = @abs(candidate.x1 - saved.x2) <= 1e-9 and @abs(candidate.y1 - saved.y2) <= 1e-9 and
                @abs(candidate.x2 - saved.x1) <= 1e-9 and @abs(candidate.y2 - saved.y1) <= 1e-9;
            if (forward or reverse) {
                saved.g = candidate.g;
                saved.source = candidate.source;
                saved.id = candidate.id;
                matched_prior = true;
                break;
            }
        };
        if (!matched_prior) saved.source = route_source_autorouter;
        try tracks.append(alloc, saved);
    }
    for (r.arcs) |arc| {
        var saved = SavedTrack{
            .x1 = arc.p1[0],
            .y1 = arc.p1[1],
            .xm = arc.pm[0],
            .ym = arc.pm[1],
            .x2 = arc.p2[0],
            .y2 = arc.p2[1],
            .l = arc.layer,
            .w = arc.width,
            .net = netNameAt(nets, arc.net),
        };
        var matched_prior = false;
        if (prior) |old| for (old.tracks) |candidate| {
            if (candidate.xm == null or candidate.ym == null or !savedTrackMetadataMatch(candidate, saved)) continue;
            const midpoint_matches = @abs(candidate.xm.? - saved.xm.?) <= 1e-9 and @abs(candidate.ym.? - saved.ym.?) <= 1e-9;
            const endpoint_matches = (@abs(candidate.x1 - saved.x1) <= 1e-9 and @abs(candidate.y1 - saved.y1) <= 1e-9 and
                @abs(candidate.x2 - saved.x2) <= 1e-9 and @abs(candidate.y2 - saved.y2) <= 1e-9) or
                (@abs(candidate.x1 - saved.x2) <= 1e-9 and @abs(candidate.y1 - saved.y2) <= 1e-9 and
                    @abs(candidate.x2 - saved.x1) <= 1e-9 and @abs(candidate.y2 - saved.y1) <= 1e-9);
            if (midpoint_matches and endpoint_matches) {
                saved.g = candidate.g;
                saved.source = candidate.source;
                saved.id = candidate.id;
                matched_prior = true;
                break;
            }
        };
        if (!matched_prior) saved.source = route_source_autorouter;
        try tracks.append(alloc, saved);
    }
    const vias = try alloc.alloc(SavedVia, r.vias.len);
    for (r.vias, 0..) |v, i| {
        vias[i] = .{
            .x = v.x,
            .y = v.y,
            .d = v.dia,
            .drill = v.drill,
            .net = netNameAt(nets, v.net),
        };
        var matched_prior = false;
        if (prior) |old| for (old.vias) |candidate| {
            if (!savedViaMetadataMatch(candidate, vias[i])) continue;
            vias[i].g = candidate.g;
            vias[i].f = candidate.f;
            vias[i].source = candidate.source;
            vias[i].s = candidate.s;
            vias[i].id = candidate.id;
            matched_prior = true;
            break;
        };
        if (!matched_prior) vias[i].source = route_source_autorouter;
    }
    var rf_paths: std.ArrayList(SavedRfPath) = .empty;
    for (r.rf_port_outcomes) |outcome| {
        if (!outcome.success or outcome.physical.gate_removed) continue;
        if (outcome.physical.samples.len < 2) continue;
        try rf_paths.append(alloc, .{
            .net = netNameAt(nets, outcome.net),
            .layer = outcome.physical.layer,
            .samples = outcome.physical.samples,
        });
    }
    return .{ .tracks = try tracks.toOwnedSlice(alloc), .vias = vias, .rf_paths = try rf_paths.toOwnedSlice(alloc) };
}
