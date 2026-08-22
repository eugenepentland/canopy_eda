//! Deterministic routing score — the single scalar the constraint-DSL routing
//! loop judges an accept/reject on. The loop is: an agent edits the routing
//! DSL, the board routes, the result is inspected, and the agent iterates. To
//! decide whether any DSL edit (or router change) helped, the loop needs ONE
//! number it can compare before/after, and it must be a pure function of the
//! routing result so the same routed board always scores identically.
//!
//! Every input already rides on the existing routing-result surfaces
//! (`/api/pcb-describe?route=1`, the route-review replay); nothing new is
//! measured here — only the formula lives in this module, so the describe and
//! replay surfaces stay byte-for-byte consistent by both calling `score`.
//!
//! v1 formula (higher is better):
//!   1000·completion − 2·vias − 0.1·trace_mm − 50·drc_errors
//! `completion` = routed / total (a board with no routable nets is complete,
//! not a divide-by-zero failure — see `completionFraction`). `drc_errors`
//! counts ERROR-severity DRC violations only; warnings never move the score.

const std = @import("std");

/// The formula version. Bump it whenever the weights or the shape of `score`
/// change, so a stored score is only ever compared against another of the same
/// version (the describe/replay JSON tags each score with `score_v`).
pub const formula_version: u32 = 1;

/// Reward for a fully routed board (completion == 1.0). The dominant term: a
/// complete board earns this before any penalty, so completion always outweighs
/// via/trace/DRC noise.
pub const completion_weight: f64 = 1000.0;
/// Penalty per via — each layer change costs reliability and board area.
pub const via_penalty: f64 = 2.0;
/// Penalty per millimetre of routed copper — shorter routing is weakly better.
pub const trace_mm_penalty: f64 = 0.1;
/// Penalty per ERROR-severity DRC violation — each one is fab-blocking, so it
/// weighs far more than a via yet still can't erase a completion gain alone.
pub const drc_error_penalty: f64 = 50.0;

/// The routing-result fields the score reads — every one already emitted by the
/// describe/replay surfaces. `drc_errors` is ERROR-severity DRC violations only
/// (the caller filters warnings out before constructing this).
pub const Inputs = struct {
    routed: usize,
    total: usize,
    vias: usize,
    trace_mm: f64,
    drc_errors: usize,
};

/// Completion fraction, `routed / total`, clamped to the documented empty-board
/// convention: a board with no routable nets (`total == 0`) is fully complete
/// (1.0), not a divide-by-zero failure — there was nothing to fail to route.
pub fn completionFraction(routed: usize, total: usize) f64 {
    if (total == 0) return 1.0;
    return @as(f64, @floatFromInt(routed)) / @as(f64, @floatFromInt(total));
}

/// The v1 routing score (higher is better) — a pure, deterministic function of
/// `in` with no clock or RNG, so the same routing result always scores the same.
pub fn score(in: Inputs) f64 {
    return completion_weight * completionFraction(in.routed, in.total) -
        via_penalty * @as(f64, @floatFromInt(in.vias)) -
        trace_mm_penalty * in.trace_mm -
        drc_error_penalty * @as(f64, @floatFromInt(in.drc_errors));
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: placement/route-score - a fully routed board with no vias, copper, or DRC errors scores the completion weight
test "a perfect route scores the completion weight" {
    const s = score(.{ .routed = 5, .total = 5, .vias = 0, .trace_mm = 0, .drc_errors = 0 });
    try testing.expectEqual(completion_weight, s);
}

// spec: placement/route-score - each via, mm of copper, and DRC error lowers the score by its named weight
test "a partial route subtracts each weighted penalty" {
    // 75% complete, 2 vias, 10 mm copper, 1 DRC error:
    //   1000·0.75 − 2·2 − 0.1·10 − 50·1 = 750 − 4 − 1 − 50 = 695.
    const s = score(.{ .routed = 3, .total = 4, .vias = 2, .trace_mm = 10, .drc_errors = 1 });
    try testing.expectApproxEqAbs(@as(f64, 695), s, 1e-9);
}

// spec: placement/route-score - a board with no routable nets counts as fully complete rather than a divide-by-zero
test "an empty board is fully complete, not a divide-by-zero" {
    try testing.expectEqual(@as(f64, 1.0), completionFraction(0, 0));
    const s = score(.{ .routed = 0, .total = 0, .vias = 0, .trace_mm = 0, .drc_errors = 0 });
    try testing.expectEqual(completion_weight, s);
}

// spec: placement/route-score - more vias, longer copper, or more DRC errors never raise the score
test "each penalty dimension is monotonically non-increasing" {
    const base = score(.{ .routed = 4, .total = 4, .vias = 1, .trace_mm = 5, .drc_errors = 0 });
    const more_vias = score(.{ .routed = 4, .total = 4, .vias = 2, .trace_mm = 5, .drc_errors = 0 });
    const more_trace = score(.{ .routed = 4, .total = 4, .vias = 1, .trace_mm = 6, .drc_errors = 0 });
    const more_drc = score(.{ .routed = 4, .total = 4, .vias = 1, .trace_mm = 5, .drc_errors = 1 });
    try testing.expect(more_vias < base);
    try testing.expect(more_trace < base);
    try testing.expect(more_drc < base);
}
