//! Mutable state and physical-net projection for a batch of gap repairs.
//! Geometry and array order remain intact while one hop sees every proven
//! bypass-family feature as its requested net. Only accepted hops are absorbed.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const route_policy = @import("route_policy.zig");
const gap_policy = @import("gap_policy.zig");
const net_identity = @import("net_identity.zig");
const pad_exit = @import("pad_exit.zig");
const pad_grid = @import("pad_grid.zig");
const Track = router.Track;
const Via = router.Via;
const PadObs = pad_grid.PadObs;
const PadHole = pad_exit.Hole;
const GapBoard = gap_policy.GapBoard;
const GapOptions = gap_policy.GapOptions;
const GapPath = gap_policy.GapPath;
const GapReason = gap_policy.GapReason;

/// The context stays owned by the routing engine; this state only carries
/// the batch's board, accepted copper, rip history and temporary identity view.
pub fn State(comptime Ctx: type) type {
    return struct {
        const Self = @This();

        ctx: *Ctx,
        placement: optimizer.Placement,
        board: GapBoard,
        opts: GapOptions,
        dead: []bool,
        holes: []const PadHole,
        added_tracks: std.ArrayList(Track) = .empty,
        added_vias: std.ArrayList(Via) = .empty,
        /// How the hop currently in flight ended (see `GapReason`). Carried on the
        /// state rather than threaded through every return type: only the batch
        /// loop reads it, and only right after the hop it belongs to.
        /// The net whose hop is in flight. A rip filter that must weigh victim
        /// against beneficiary — "may THIS net take THAT one's copper" — cannot
        /// answer from the victim alone, and the batch loop is too coarse: one
        /// round carries hops for many nets.
        routing_net: i32 = -1,
        reason: GapReason = .routed,
        /// Scratch via-ban mask for the hop in flight (see `markTerminalViaBan`).
        /// One buffer for the whole batch, rewritten per hop.
        term_ban: []bool,
        /// Rip candidates already routed against during the hop in flight, as their
        /// (sorted) killed-track index sets. Cleared per hop by `closeOneGap`.
        rip_tried: std.ArrayList([]const usize) = .empty,

        /// Has this exact rip already been routed against during this hop? Both
        /// rip-up tiers converge on the same victims — the reach ladder saturates
        /// once it has caught all of a victim's segments, and the path-blocker probe
        /// re-nominates nets the terminal tier already cleared outright. Nothing
        /// else about the board moves between attempts within a hop, so a repeat is
        /// a re-stamp plus a full maze sweep for an answer already known.
        pub fn ripAlreadyTried(self: *Self, kill: []const usize) std.mem.Allocator.Error!bool {
            for (self.rip_tried.items) |past| {
                if (std.mem.eql(usize, past, kill)) return true;
            }
            try self.rip_tried.append(self.ctx.arena, kill);
            return false;
        }

        /// Fold a landed hop into the batch's running board view.
        pub fn absorb(self: *Self, path: GapPath) std.mem.Allocator.Error!void {
            try self.added_tracks.appendSlice(self.ctx.arena, path.tracks);
            try self.added_vias.appendSlice(self.ctx.arena, path.vias);
            for (path.ripped) |i| {
                if (i < self.dead.len) self.dead[i] = true;
            }
        }
        const Physical = struct {
            state: Self,
            original: ?struct { obs: []const PadObs, zones: []const route_policy.ExistingZone } = null,

            pub fn restore(self: Physical) void {
                const original = self.original orelse return;
                self.state.ctx.obs = original.obs;
                self.state.ctx.zones = original.zones;
                self.state.ctx.static_block.reset();
            }
        };

        pub fn physical(state: Self, net_i: usize) std.mem.Allocator.Error!Physical {
            var result = Physical{ .state = state };
            const net = std.math.cast(i32, net_i) orelse return result;
            if (state.placement.loops.len == 0) return result;
            const ctx = state.ctx;
            const arena = ctx.arena;
            const identity = try net_identity.Identity.init(arena, state.placement);
            if ((try identity.familyOf(arena, net_i)).len == 1) return result;
            const obs = try physicalGapItems(PadObs, arena, identity, net, ctx.obs);
            const zones = try physicalGapItems(route_policy.ExistingZone, arena, identity, net, state.board.zones);
            result.state.board.tracks = try physicalGapItems(Track, arena, identity, net, state.board.tracks);
            result.state.board.vias = try physicalGapItems(Via, arena, identity, net, state.board.vias);
            result.state.board.zones = zones;
            result.state.added_tracks = .fromOwnedSlice(try physicalGapItems(Track, arena, identity, net, state.added_tracks.items));
            result.state.added_vias = .fromOwnedSlice(try physicalGapItems(Via, arena, identity, net, state.added_vias.items));
            // Publish the temporary view only after every allocation succeeds. Keep
            // the same context so memo generations continue across successive hops;
            // copying a context would replay an old generation over shared cache data.
            result.original = .{ .obs = ctx.obs, .zones = ctx.zones };
            ctx.obs = obs;
            ctx.zones = zones;
            return result;
        }
    };
}

fn physicalGapItems(
    comptime T: type,
    arena: std.mem.Allocator,
    identity: net_identity.Identity,
    net: i32,
    items: []const T,
) std.mem.Allocator.Error![]T {
    const mapped = try arena.dupe(T, items);
    for (mapped) |*item| if (identity.same(item.net, net)) {
        item.net = net;
    };
    return mapped;
}
