//! Judge → rank → admit under two bounds: the shape both rip-up tiers select
//! their transaction with.
//!
//! `vacate_policy` and `joint_rescue` answer different questions and rank by
//! different keys on purpose (restore cheapness vs. corridor proximity — see
//! `joint_rescue.cheaperFirst`). What they must NOT differ on is the admission
//! policy underneath, and they each used to carry their own copy of it:
//!
//!   * every candidate is judged, and a refusal is RECORDED with its reason
//!     rather than dropped, so a caller can tell "the tier would not touch
//!     this" from "the tier ran out of room";
//!   * the eligible ones are sorted by the caller's order;
//!   * they are admitted greedily under BOTH a count cap and an element
//!     budget, and an over-budget candidate is SKIPPED rather than ending the
//!     scan — a long rail must not shut out the two-element stub ranked behind
//!     it, which may be the rest of the corridor. That skip is the subtle half:
//!     a copy that reverted to "stop at the first over-budget candidate" would
//!     still pass every test about caps and would quietly stop finding the
//!     transactions the tiers exist to find.
//!
//! The caller keeps its own `Nomination`, `Refused` and refusal enum; this
//! module only requires that a nomination carries `net_i` and `elements`, that
//! a refusal is `{ net_i, why }`, and that the `why` enum spells `capped` and
//! `over_budget`.

const std = @import("std");

/// The two bounds a transaction is admitted under.
pub const Caps = struct {
    /// Most candidates one transaction takes.
    max_items: usize,
    /// Total elements (tracks + vias) it may take off the board.
    max_total_elements: usize,
};

/// One candidate's judgement: nominated, or refused with a reason.
pub fn Verdict(comptime Nomination: type, comptime Why: type) type {
    return union(enum) { accept: Nomination, refuse: Why };
}

/// What the tier decided about every candidate it was shown.
pub fn Decision(comptime Nomination: type, comptime Refused: type) type {
    return struct {
        /// The candidates to take, in the caller's rank order.
        picked: []const Nomination,
        /// Every other candidate, with its reason.
        refused: []const Refused,
    };
}

/// Judge every candidate in `facts` with `nominate` (which is handed `ctx` —
/// the seed, victim, or limits it needs), rank the eligible ones with `order`,
/// and admit them greedily under `caps`. Both returned slices are owned by
/// `alloc`.
///
/// Every seam is a concrete type rather than `anytype`: a tier that hands this
/// the wrong nomination shape should fail at its own call, naming the type it
/// got, instead of somewhere inside this body.
pub fn select(
    alloc: std.mem.Allocator,
    comptime Nomination: type,
    comptime Refused: type,
    comptime Facts: type,
    comptime Ctx: type,
    comptime nominate: fn (Ctx, Facts) Verdict(Nomination, @FieldType(Refused, "why")),
    comptime order: fn (void, Nomination, Nomination) bool,
    facts: []const Facts,
    ctx: Ctx,
    caps: Caps,
) std.mem.Allocator.Error!Decision(Nomination, Refused) {
    var ok: std.ArrayList(Nomination) = .empty;
    defer ok.deinit(alloc);
    var no: std.ArrayList(Refused) = .empty;
    errdefer no.deinit(alloc);
    for (facts) |f| switch (nominate(ctx, f)) {
        .accept => |n| try ok.append(alloc, n),
        .refuse => |why| try no.append(alloc, .{ .net_i = f.net_i, .why = why }),
    };
    std.mem.sort(Nomination, ok.items, {}, order);

    var picked: std.ArrayList(Nomination) = .empty;
    errdefer picked.deinit(alloc);
    var spent: usize = 0;
    for (ok.items) |n| {
        if (picked.items.len >= caps.max_items) {
            try no.append(alloc, .{ .net_i = n.net_i, .why = .capped });
        } else if (spent + n.elements > caps.max_total_elements) {
            // Skip, do not stop: the candidates ranked behind this one may fit.
            try no.append(alloc, .{ .net_i = n.net_i, .why = .over_budget });
        } else {
            spent += n.elements;
            try picked.append(alloc, n);
        }
    }
    // Owned slices, so a caller on a real allocator can free exactly what it
    // was handed (an arena caller simply drops them).
    return .{
        .picked = try picked.toOwnedSlice(alloc),
        .refused = try no.toOwnedSlice(alloc),
    };
}
