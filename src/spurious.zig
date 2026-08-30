//! Interval arithmetic for a fixed-LO difference mixer's frequency plan.
//!
//! Everything here is a pure function of closed frequency intervals: no
//! sampling, no allocation, no design state. A swept source covers a
//! CONTINUOUS RF interval, so every (m,n) mixer product covers a continuous
//! interval too, and asking whether a spur lands in the commanded output band
//! is an interval-overlap question rather than something a frequency sweep can
//! only ever approximate.
//!
//! The one subtlety this file exists to get right is the absolute value.
//! `m·RF − n·LO` is monotone increasing in RF (m ≥ 0), so its signed range is
//! just its two endpoints — but `|·|` folds a range that straddles DC back
//! onto itself, and the folded set then reaches all the way DOWN to 0 rather
//! than stopping at the smaller endpoint magnitude. `fold` returns the two
//! monotone branches in that case; a naive two-endpoint fold would report an
//! interval that excludes every frequency below `min(|lo|, |hi|)` — including
//! the output band, whenever the band sits underneath a straddling product.

const std = @import("std");

/// A closed frequency interval in hertz. `lo_hz == hi_hz` is a single tone;
/// both edges stay 0 for a clause that was never authored.
pub const Band = struct {
    lo_hz: f64 = 0,
    hi_hz: f64 = 0,

    /// A band nobody authored. Distinguishes "not declared" from "DC to DC".
    pub fn declared(self: Band) bool {
        return self.lo_hz != 0 or self.hi_hz != 0;
    }

    /// High edge minus low edge; zero for a single tone.
    pub fn width(self: Band) f64 {
        return self.hi_hz - self.lo_hz;
    }

    /// True when the two intervals share at least one frequency. Touching at
    /// a single point counts: a product sitting exactly on the band edge is in
    /// the band, not beside it.
    pub fn overlaps(self: Band, other: Band) bool {
        return self.lo_hz <= other.hi_hz and other.lo_hz <= self.hi_hz;
    }

    /// True when `other` lies wholly within `self`, edges included — the test
    /// band closure is: does the delivered passband cover the whole sweep?
    pub fn contains(self: Band, other: Band) bool {
        return self.lo_hz <= other.lo_hz and other.hi_hz <= self.hi_hz;
    }

    /// The part of `self` strictly below `other`'s low edge; empty (both edges
    /// equal) when `self` starts at or above it.
    pub fn below(self: Band, other: Band) Band {
        if (self.lo_hz >= other.lo_hz) return .{};
        return .{ .lo_hz = self.lo_hz, .hi_hz = @min(self.hi_hz, other.lo_hz) };
    }

    /// The part of `self` strictly above `other`'s high edge; empty when
    /// `self` ends at or below it.
    pub fn above(self: Band, other: Band) Band {
        if (self.hi_hz <= other.hi_hz) return .{};
        return .{ .lo_hz = @max(self.lo_hz, other.hi_hz), .hi_hz = self.hi_hz };
    }

    /// True for the empty results `below`/`above` return, and only for those:
    /// a real interval always has a positive width or a nonzero edge.
    pub fn isEmpty(self: Band) bool {
        return self.lo_hz == 0 and self.hi_hz == 0;
    }
};

/// The signed range of `m·RF − n·LO` over an RF interval. Monotone increasing
/// in RF because `m` is never negative, so the endpoints ARE the range.
pub fn signedProduct(m: f64, n: f64, rf: Band, lo_hz: f64) Band {
    return .{ .lo_hz = m * rf.lo_hz - n * lo_hz, .hi_hz = m * rf.hi_hz - n * lo_hz };
}

/// `|signed|` as up to two monotone branches. One branch when the signed range
/// keeps its sign; two — the descending branch `[0, −lo]` and the ascending
/// branch `[0, hi]` — when it crosses DC inside the RF sweep.
pub const Branches = struct {
    parts: [2]Band = @splat(.{}),
    /// 1 or 2. A `Branches` built by `fold` is never empty.
    len: usize = 0,

    /// The smallest interval containing every branch. Equal to the single
    /// branch when there is one; `[0, max]` across a DC crossing.
    pub fn hull(self: Branches) Band {
        if (self.len == 0) return .{};
        var out = self.parts[0];
        for (self.parts[1..self.len]) |part| {
            out.lo_hz = @min(out.lo_hz, part.lo_hz);
            out.hi_hz = @max(out.hi_hz, part.hi_hz);
        }
        return out;
    }

    /// True when ANY branch shares a frequency with `other`. `fold`'s two
    /// branches both start at 0, so this happens to agree with the hull today;
    /// it is written per-branch so a future non-adjacent split cannot silently
    /// start reporting the gap between branches as occupied.
    pub fn overlaps(self: Branches, other: Band) bool {
        for (self.parts[0..self.len]) |part| {
            if (part.overlaps(other)) return true;
        }
        return false;
    }

    /// Every branch lies strictly above `cutoff` — the condition for a
    /// declared low-pass to reject the whole product.
    pub fn aboveAll(self: Branches, cutoff: f64) bool {
        if (self.len == 0) return false;
        for (self.parts[0..self.len]) |part| {
            if (part.lo_hz <= cutoff) return false;
        }
        return true;
    }

    /// Every branch lies strictly below `cutoff` — the condition for a
    /// declared high-pass to reject the whole product.
    pub fn belowAll(self: Branches, cutoff: f64) bool {
        if (self.len == 0) return false;
        for (self.parts[0..self.len]) |part| {
            if (part.hi_hz >= cutoff) return false;
        }
        return true;
    }
};

/// Fold a signed product range onto the positive frequency axis.
pub fn fold(signed: Band) Branches {
    if (signed.lo_hz >= 0) return .{ .parts = .{ signed, .{} }, .len = 1 };
    if (signed.hi_hz <= 0) return .{ .parts = .{ .{ .lo_hz = -signed.hi_hz, .hi_hz = -signed.lo_hz }, .{} }, .len = 1 };
    return .{ .parts = .{
        .{ .lo_hz = 0, .hi_hz = -signed.lo_hz },
        .{ .lo_hz = 0, .hi_hz = signed.hi_hz },
    }, .len = 2 };
}

/// `|m·RF − n·LO|` over an RF interval, in one call.
pub fn productBranches(m: f64, n: f64, rf: Band, lo_hz: f64) Branches {
    return fold(signedProduct(m, n, rf, lo_hz));
}

/// Which sideband of a fixed LO a difference mixer takes the output band from.
/// `either` is not a sideband — it asks for both to be planned and reported.
pub const Sideband = enum { high, low, either };

/// The RF interval a difference mixer must sweep to deliver `band` against a
/// fixed `lo_hz`: `LO + IF` on the high side, `LO − IF` on the low side (which
/// reverses the sense, so the band's high edge sets the RF window's low edge).
pub fn requiredRf(lo_hz: f64, band: Band, side: Sideband) Band {
    if (side == .low) return .{ .lo_hz = lo_hz - band.hi_hz, .hi_hz = lo_hz - band.lo_hz };
    return .{ .lo_hz = lo_hz + band.lo_hz, .hi_hz = lo_hz + band.hi_hz };
}

/// The output sub-band an RF sub-interval maps to through the same mixer —
/// the inverse of `requiredRf`, used to say which part of the commanded band
/// an uncovered RF gap costs.
pub fn outputOf(lo_hz: f64, rf: Band, side: Sideband) Band {
    if (side == .low) return .{ .lo_hz = lo_hz - rf.hi_hz, .hi_hz = lo_hz - rf.lo_hz };
    return .{ .lo_hz = rf.lo_hz - lo_hz, .hi_hz = rf.hi_hz - lo_hz };
}

/// The image sideband: the OTHER RF window that folds onto the same IF.
pub fn imageOf(lo_hz: f64, band: Band, side: Sideband) Band {
    return requiredRf(lo_hz, band, if (side == .low) .high else .low);
}

/// `(m,m)` products sit at exact multiples of the commanded IF, so the number
/// of them landing inside `band` above the wanted one is `⌊band.hi/f⌋ − 1`,
/// clamped at zero. Worst case is the band's LOW edge, where the multiples are
/// packed tightest.
pub fn diagonalCount(band: Band, if_hz: f64) usize {
    if (if_hz <= 0 or band.hi_hz <= 0) return 0;
    const multiples = @floor(band.hi_hz / if_hz);
    if (multiples < 2) return 0;
    return @intFromFloat(multiples - 1);
}

/// The commanded IF above which no `(m,m)` product with m ≥ 2 can land inside
/// `band`: half the band's high edge, since `2·f > band.hi` is the condition.
pub fn diagonalCleanAbove(band: Band) f64 {
    return band.hi_hz / 2;
}

// spec: frequency-plan - the absolute value of a product range that crosses DC inside the RF sweep folds into two branches reaching down to zero, never the naive endpoint-magnitude interval
test "folding a straddling product reaches DC" {
    // 2·RF − 3·LO over RF 11.0-12.45 GHz against LO 8 GHz runs -2.0 … +0.9 GHz.
    const rf = Band{ .lo_hz = 11e9, .hi_hz = 12.45e9 };
    const branches = productBranches(2, 3, rf, 8e9);
    try std.testing.expectEqual(@as(usize, 2), branches.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0), branches.parts[0].lo_hz, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0e9), branches.parts[0].hi_hz, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 0), branches.parts[1].lo_hz, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9e9), branches.parts[1].hi_hz, 1);

    // The hull reaches DC — a naive |endpoint| fold would have reported
    // 0.9-2.0 GHz and missed every output band below 900 MHz.
    const hull = branches.hull();
    try std.testing.expectApproxEqAbs(@as(f64, 0), hull.lo_hz, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0e9), hull.hi_hz, 1);
    try std.testing.expect(branches.overlaps(.{ .lo_hz = 50e6, .hi_hz = 1500e6 }));

    // A range that keeps its sign stays one branch, either way round.
    const positive = productBranches(1, 1, rf, 8e9);
    try std.testing.expectEqual(@as(usize, 1), positive.len);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0e9), positive.parts[0].lo_hz, 1);
    const negative = productBranches(1, 2, rf, 8e9);
    try std.testing.expectEqual(@as(usize, 1), negative.len);
    try std.testing.expectApproxEqAbs(@as(f64, 3.55e9), negative.parts[0].lo_hz, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0e9), negative.parts[0].hi_hz, 1);
}

// spec: frequency-plan - the diagonal product count at an IF matches the closed form and names the IF above which the commanded band carries none
test "diagonal multiples follow the closed form" {
    const band = Band{ .lo_hz = 50e6, .hi_hz = 1500e6 };
    try std.testing.expectEqual(@as(usize, 29), diagonalCount(band, 50e6));
    try std.testing.expectEqual(@as(usize, 14), diagonalCount(band, 100e6));
    try std.testing.expectEqual(@as(usize, 1), diagonalCount(band, 600e6));
    try std.testing.expectEqual(@as(usize, 0), diagonalCount(band, 751e6));
    try std.testing.expectEqual(@as(usize, 0), diagonalCount(band, 1500e6));
    try std.testing.expectApproxEqAbs(@as(f64, 750e6), diagonalCleanAbove(band), 1e-6);

    // At the clean-above frequency the second harmonic sits exactly on the
    // band edge, so it still counts; a hair above, it does not.
    try std.testing.expectEqual(@as(usize, 1), diagonalCount(band, diagonalCleanAbove(band)));
}

// spec: frequency-plan - the required RF window, its image and the output sub-band an RF gap costs are exact inverses of one another on both sidebands
test "sideband arithmetic round-trips" {
    const band = Band{ .lo_hz = 50e6, .hi_hz = 1500e6 };
    const high = requiredRf(10.95e9, band, .high);
    try std.testing.expectApproxEqAbs(@as(f64, 11.0e9), high.lo_hz, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 12.45e9), high.hi_hz, 1);
    const back = outputOf(10.95e9, high, .high);
    try std.testing.expectApproxEqAbs(band.lo_hz, back.lo_hz, 1);
    try std.testing.expectApproxEqAbs(band.hi_hz, back.hi_hz, 1);

    const low = requiredRf(10.95e9, band, .low);
    try std.testing.expectApproxEqAbs(@as(f64, 9.45e9), low.lo_hz, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 10.9e9), low.hi_hz, 1);
    const low_back = outputOf(10.95e9, low, .low);
    try std.testing.expectApproxEqAbs(band.lo_hz, low_back.lo_hz, 1);
    try std.testing.expectApproxEqAbs(band.hi_hz, low_back.hi_hz, 1);

    // The image of one sideband is the other sideband's window.
    try std.testing.expectEqual(low.lo_hz, imageOf(10.95e9, band, .high).lo_hz);
    try std.testing.expectEqual(high.hi_hz, imageOf(10.95e9, band, .low).hi_hz);
}

// spec: frequency-plan - an RF window that leaves a declared passband reports the uncovered sub-interval on the side it leaves from, and reports nothing when it is contained
test "uncovered sub-intervals name the side they fall off" {
    const delivered = Band{ .lo_hz = 10.5e9, .hi_hz = 12.9e9 };
    const covered = Band{ .lo_hz = 11.0e9, .hi_hz = 12.45e9 };
    try std.testing.expect(delivered.contains(covered));
    try std.testing.expect(covered.below(delivered).isEmpty());
    try std.testing.expect(covered.above(delivered).isEmpty());

    // The 10.00 GHz LO case: 10.05-11.50 GHz loses its bottom 450 MHz.
    const short = Band{ .lo_hz = 10.05e9, .hi_hz = 11.5e9 };
    const gap = short.below(delivered);
    try std.testing.expectApproxEqAbs(@as(f64, 10.05e9), gap.lo_hz, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 10.5e9), gap.hi_hz, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 450e6), gap.width(), 1);
    try std.testing.expect(short.above(delivered).isEmpty());

    // …and that gap is the bottom 450 MHz of the commanded output band.
    const lost = outputOf(10.0e9, gap, .high);
    try std.testing.expectApproxEqAbs(@as(f64, 50e6), lost.lo_hz, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 500e6), lost.hi_hz, 1);
}

// spec: frequency-plan - a declared cutoff rejects a product only when every folded branch lies wholly beyond it
test "cutoff rejection consults every branch" {
    const straddling = productBranches(2, 3, .{ .lo_hz = 11e9, .hi_hz = 12.45e9 }, 8e9);
    // Both branches reach DC, so no low-pass anywhere above DC rejects it.
    try std.testing.expect(!straddling.aboveAll(6e9));
    try std.testing.expect(straddling.belowAll(2.1e9));
    try std.testing.expect(!straddling.belowAll(1.9e9));

    const single = productBranches(2, 3, .{ .lo_hz = 11e9, .hi_hz = 12.45e9 }, 10.95e9);
    try std.testing.expectEqual(@as(usize, 1), single.len);
    // 2·RF − 3·LO runs -10.85 … -7.95 GHz, folding to 7.95-10.85 GHz.
    try std.testing.expect(single.aboveAll(6e9));
    try std.testing.expect(!single.aboveAll(8e9));
}
