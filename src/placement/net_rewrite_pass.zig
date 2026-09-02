//! The per-net driver every copper-rewriting cleanup pass runs under.
//!
//! A pass that edits routed copper net by net has a fixed preamble before it may
//! touch anything, and getting it wrong is silent:
//!
//!   • **Scope.** In a scoped re-route an unselected net's copper is the
//!     caller's retained board, echoed back "unchanged". Rewriting it returns a
//!     different board than the caller submitted, and did — a scoped barracuda
//!     re-route once straightened and amputated out-of-scope copper and reopened
//!     six connected nets.
//!   • **Diff pairs.** A pair's two legs move in lock-step; a pass that rewrites
//!     one leg alone breaks the coupling the router built.
//!   • **Per-net parameters.** `setNetParams` is what points the clearance probe
//!     and the track width at THIS net's rule, and the copper index must be
//!     restamped after it: an earlier net's removal packed the track/via lists
//!     down, so every entry in the generation-stamped index now names different
//!     copper, and the index's own insertion reach derives from the parameters
//!     just set.
//!
//! `route_cleanup.dropRedundantViaPairs` and `dive_elide.passBoard` each carried
//! their own copy of that preamble, and the copies had already parted over the
//! scope test — one refused foreign (net < 0) copper before consulting the
//! selection, the other after, so a whole-board run disagreed with itself about
//! unnetted copper. The strict order is the one kept here.
//!
//! What each pass does with a net is its own: `stepOne` returns "I changed
//! something, ask me again" and the driver reruns it up to `max_steps`.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");

/// The mutable board a cleanup pass rewrites: placement, copper lists, context.
const Board = router.CleanupBoard;

/// May a cleanup pass rewrite `net`'s copper? With no selection every net is
/// fair game (the whole-board route). In a SCOPED route every unselected net's
/// copper is the caller's retained board (`stampExistingCopper` echoes it into
/// the result "unchanged") — so rewriting it here would return a different
/// board than the caller submitted, and did: a scoped barracuda re-route
/// straightened/amputated out-of-scope copper and reopened six connected nets.
/// Foreign copper (net < 0) is likewise retained caller copper in a scoped run,
/// and is refused BEFORE the selection is consulted so an unnetted track is
/// never rewritten by a whole-board pass either.
pub fn mayRewrite(selected_nets: []const bool, net: i32) bool {
    if (net < 0) return false;
    if (selected_nets.len == 0) return true;
    const i: usize = @intCast(net);
    return i < selected_nets.len and selected_nets[i];
}

/// Is this net one leg of a declared differential pair? Its two legs move in
/// lock-step, so a pass that rewrites one alone breaks their coupling.
pub fn netIsDiffPairLeg(placement: optimizer.Placement, net_i: usize) bool {
    for (placement.diff_pairs) |dp| {
        if (dp.p == net_i or dp.n == net_i) return true;
    }
    return false;
}

/// Does this net declare RF discipline (`(net-class … (max-freq …))`)?
///
/// Such a net's corners are ARCS by declaration: `bend_smooth` reshaped them
/// the moment it routed and recorded the arc metadata the result carries, and a
/// via fence may already flank the copper. Redrawing a span of it as three
/// octilinear segments would contradict the geometry the design asked for and
/// orphan that metadata, so an RF net keeps its dives — the one net class where
/// a layer change is a considered choice rather than a lattice artefact.
pub fn netIsRfDisciplined(placement: optimizer.Placement, net_i: usize) bool {
    if (net_i >= placement.rules.net.len) return false;
    return placement.rules.net[net_i].rf.max_freq_hz > 0;
}

/// What a pass asks of the driver beyond the guards every pass shares.
pub const Options = struct {
    /// Attempts per net. Each success deletes copper and the scan is rerun, so
    /// this only caps a pathological loop; set it well above any real net's
    /// via count.
    max_steps: usize,
    /// Skip a net whose route policy AUTHORS its layers — a preferred/allowed
    /// mask, or waypoints requesting an exact transition. Its hops are meant.
    /// The coarse whole-net guard: a pass with a finer per-candidate policy
    /// test of its own leaves this off and applies that instead.
    skip_layer_authored: bool = false,
    /// Skip a net under RF discipline (see `netIsRfDisciplined`).
    skip_rf_disciplined: bool = false,
};

/// Run `stepOne` over every net whose copper this pass may rewrite, with that
/// net's routing parameters and a freshly stamped copper index in force.
pub fn run(
    board: Board,
    opts: Options,
    ctx: anytype,
    comptime stepOne: fn (@TypeOf(ctx), i32) std.mem.Allocator.Error!bool,
) std.mem.Allocator.Error!void {
    const placement = board.placement;
    for (0..placement.nets.len) |net_i| {
        const net: i32 = @intCast(net_i);
        if (!mayRewrite(board.ctx.selected_nets, net)) continue; // retained copper echoes verbatim
        if (netIsDiffPairLeg(placement, net_i)) continue; // pairs move in lock-step
        if (opts.skip_rf_disciplined and netIsRfDisciplined(placement, net_i)) continue;
        if (opts.skip_layer_authored and router.netLayerAuthored(board.ctx, net_i)) continue;
        router.setNetParams(board.ctx, placement, net_i); // probe + width read this net's rule
        // Restamp for THIS net: an earlier net's rewrite packed the lists down
        // (aliasing every entry) and the index's insertion reach derives from
        // the parameters just set.
        router.rebuildCopperIndex(board.ctx, board.tracks.items, board.vias.items);
        var guard: usize = 0;
        while (guard < opts.max_steps) : (guard += 1) {
            if (!try stepOne(ctx, net)) break;
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: placement/router - a cleanup pass never rewrites copper outside the route's own scope, and never one leg of a differential pair alone
test "the shared cleanup guards refuse out-of-scope, unnetted and paired copper" {
    // No selection is a whole-board route: every real net is fair game …
    try testing.expect(mayRewrite(&.{}, 0));
    try testing.expect(mayRewrite(&.{}, 7));
    // … but unnetted copper is retained caller copper even then. This is the
    // half the two hand-written copies had drifted over.
    try testing.expect(!mayRewrite(&.{}, -1));

    // A scoped route rewrites only what it selected, and nothing past the end
    // of the selection.
    const selected = [_]bool{ true, false };
    try testing.expect(mayRewrite(&selected, 0));
    try testing.expect(!mayRewrite(&selected, 1));
    try testing.expect(!mayRewrite(&selected, 2));

    // A declared pair's legs are off limits to a pass that would move one alone.
    const pairs = [_]@import("diff_pairs.zig").DiffPair{.{ .p = 1, .n = 2, .gap = 0.2 }};
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 0,
        .maxy = 0,
        .generated = true,
        .diff_pairs = &pairs,
        .rules = .{ .net = &[_]optimizer.NetRule{ .{}, .{}, .{}, .{ .rf = .{ .max_freq_hz = 12e9 } } } },
    };
    try testing.expect(!netIsDiffPairLeg(placement, 0));
    try testing.expect(netIsDiffPairLeg(placement, 1));
    try testing.expect(netIsDiffPairLeg(placement, 2));

    // And an RF-disciplined net keeps its authored arcs and its dives.
    try testing.expect(!netIsRfDisciplined(placement, 0));
    try testing.expect(netIsRfDisciplined(placement, 3));
    try testing.expect(!netIsRfDisciplined(placement, 99)); // past the rule table
}
