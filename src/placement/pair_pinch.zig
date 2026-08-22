//! Where a coupled differential pair's envelope search hit a wall, carried back
//! out of the router.
//!
//! The pair channel search (`diff_shape.envelopeChannel`) triangulates the
//! pair's free space at envelope width and, when no channel exists, walks its
//! own walls to find the narrowest cut between the two terminals and the copper
//! that owns each side of it (`cdt_layers.Pinch`). That is a fact the CALLER
//! needs, not the router: the transaction that lost the pair is the one holding
//! rip authority, and "these two nets are 0.31 mm apart where the pair needs
//! 0.52 mm" names copper a deepening round can nominate — where the old verdict,
//! "no envelope channel in the mesh either", named nothing at all.
//!
//! So this is a SINK, sized like the other two the route options already carry
//! (`ProgressSink`, `PhaseTimer`): a caller that wants the diagnosis hands one
//! in, and a run with none is byte-identical to a run before this existed. It is
//! a fixed-size buffer rather than a list because it is written from inside a
//! routing pass, where an allocation failure must never be able to lose copper —
//! a full log simply stops recording, and a dropped diagnosis costs a verdict
//! line rather than a board.
//!
//! Plain data, no allocator, no clock: the values are flattened net indices,
//! world millimetres and a signal layer, all already resolved by the geometry
//! that found them.

const std = @import("std");

/// One pair whose envelope had no channel, and the wall that closed it.
///
/// The two sides repeat each other when a single body spans the channel alone —
/// there is no gap between two things to report — and either is `-1` where that
/// side is a keepout or the board-edge band, which carries no net and no owner a
/// rip could ever negotiate.
pub const Report = struct {
    /// The declared pair's two flattened net indices, P then N.
    pair: [2]i32 = .{ -1, -1 },
    /// The two sides of the wall, by flattened net index.
    nets: [2]i32 = .{ -1, -1 },
    /// Where on the board the wall stands (world mm), and on which signal layer.
    at: [2]f64 = .{ 0, 0 },
    layer: u8 = 0,
    /// The clear millimetres between the two bodies, and what the pair's own
    /// envelope needed there.
    have_mm: f64 = 0,
    need_mm: f64 = 0,

    /// Is this side's owner a net a caller could nominate at all? A keepout, a
    /// board edge and an unresolved body all answer no.
    pub fn owner(self: Report, side: Side) ?usize {
        const net = self.nets[@backingInt(side)];
        return if (net < 0) null else @intCast(net);
    }
};

/// Which side of the wall a reader is asking about.
pub const Side = enum { a, b };

/// Most pinches one route records. A transaction re-homes a handful of victims
/// at most, and a log that grew without bound inside a routing pass would be a
/// new failure mode for no new information.
pub const max_reports: usize = 8;

/// The caller's collection point. Default-constructed and passed by pointer;
/// nothing here allocates, so it can be a stack value in the caller's frame.
pub const Log = struct {
    buf: [max_reports]Report = @splat(.{}),
    len: usize = 0,

    /// Record one pinch, silently ignoring anything past the cap.
    pub fn record(self: *Log, report: Report) void {
        if (self.len >= max_reports) return;
        self.buf[self.len] = report;
        self.len += 1;
    }

    /// Everything recorded, in the order it was found.
    pub fn reports(self: *const Log) []const Report {
        return self.buf[0..self.len];
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

// spec: placement/pair-pinch - a pinch log records what it is handed in order, stops at its cap rather than growing, and names only the sides whose owner is a net a caller could nominate
test "a pinch log is a bounded, ordered record of nameable owners" {
    var log = Log{};
    try testing.expectEqual(@as(usize, 0), log.reports().len);

    log.record(.{ .pair = .{ 3, 4 }, .nets = .{ 7, 9 }, .have_mm = 0.31, .need_mm = 0.52 });
    try testing.expectEqual(@as(usize, 1), log.reports().len);
    try testing.expectEqual(@as(?usize, 7), log.reports()[0].owner(.a));
    try testing.expectEqual(@as(?usize, 9), log.reports()[0].owner(.b));

    // A keepout or board-edge side carries no net, so it names no owner at all —
    // there is nothing there a rip could ever be asked to move.
    log.record(.{ .pair = .{ 3, 4 }, .nets = .{ 2, -1 } });
    try testing.expectEqual(@as(?usize, 2), log.reports()[1].owner(.a));
    try testing.expectEqual(@as(?usize, null), log.reports()[1].owner(.b));

    // Past the cap the log stops recording instead of growing inside a route.
    for (0..max_reports * 2) |_| log.record(.{ .pair = .{ 0, 1 } });
    try testing.expectEqual(max_reports, log.reports().len);
    // …and what it already held is untouched, in the order it arrived.
    try testing.expectEqual(@as(i32, 7), log.reports()[0].nets[0]);
    try testing.expectEqual(@as(i32, 2), log.reports()[1].nets[0]);
}
