//! Windowed fine-grid local retry — planning for the router's last-resort rescue.
//!
//! The whole-board maze grid pitch is `track_width + clearance` (0.254 mm for
//! board-a's 0.127 nets) and pads sit off-grid, so an interior pad of a
//! fine-pitch package can be impossible to escape at that raster even when the
//! copper corridor beside it is empty — the hand reference threads such hops on
//! sub-grid geometry. After every escalate / rip-up phase, the router asks this
//! module WHERE and HOW FINE to re-maze each STILL-failed net: a small window
//! over the net's terminals at half (then quarter) the whole-board pitch, where
//! the off-grid escape becomes representable.
//!
//! This module is pure planning over plain data (terminal points + the board
//! rectangle) — the bend_smooth / straighten precedent of a narrow, Ctx-free
//! interface. The router owns the maze context and drives the search on the
//! window this module hands back, so all DRC / occupancy state stays private to
//! `router.zig`. A whole-net window re-routes the tree at once; a board-spanning
//! multi-drop net decomposes into nearest-unconnected-pair legs, each with its
//! own two-terminal window.

const std = @import("std");
const router = @import("router.zig");
const optimizer = @import("optimizer.zig");
const numeric = @import("../numeric.zig");

/// Deterministic margin (mm) grown around a net's terminal box before it
/// becomes the search window — room for the maze to detour a blocker.
const window_margin_mm: f64 = 3.5;
/// The whole-board margin `buildRouteCtx` leaves outside the parts bbox; the
/// window is clamped to this same extent so it never reaches off the grid.
const grid_margin_mm: f64 = 1.0;
/// Half-pitch first attempt, quarter-pitch fallback (the quarter tier resolves
/// an interior fine-pitch pad escape the half tier still can't land a node in).
const tier1_scale: f64 = 0.5;
const tier2_scale: f64 = 0.25;
/// Largest window (grid cells, one signal layer) a retry will build — keeps the
/// bounded node count deterministic and the whole phase a few seconds. A window
/// over budget yields no candidate at that pitch rather than a degraded search.
const max_window_cells: usize = 60_000;

/// Per-window maze expansion budget cap. A bounded window is fully explorable in
/// far fewer expansions than the whole board; this keeps an unroutable window's
/// search (which spends the whole budget) cheap so the rescue phase stays fast.
pub const max_window_expansions: usize = 250_000;

/// Hard expansion ceiling for an OVER-CAP declared window (`Window.over_cap`) —
/// the only tier allowed past `max_window_cells`, and so the only one whose
/// lattice is big enough for a runaway search.
///
/// `max_window_expansions` is NOT the right ceiling for it. That number was
/// sized so an automatic window always gets ONE FULL SWEEP of its own lattice
/// (60k cells x 2 signal layers = 120k, comfortably inside 250k), so it never
/// actually binds; a declared 283k-cell window truncates at 44 % of its lattice
/// instead. Measured on board-a's `SPI_SCK`: at 250k the maze exhausts the
/// budget having never reached the goal — the declaration reads as "no path
/// exists at 0.05 mm" when what happened was "the search was cut off". So a
/// declared window gets its full sweep too (`declaredWindowBudget`), and the
/// thing that bounds it is `max_declared_window_cells`, not this. This stays as
/// the backstop for a board with more than two signal layers, where a full
/// sweep of the largest admissible window would be over a million expansions.
pub const declared_window_expansions: usize = 700_000;

/// One full sweep of an over-cap declared window's own lattice (`layers` signal
/// layers x `cells` nodes each), under the hard ceiling above — the same "one
/// bounded sweep" rule `windowCtx` applies to every other window.
pub fn declaredWindowBudget(layers: usize, cells: usize) usize {
    return @min(layers * cells, declared_window_expansions);
}

/// Board-scale cell ceiling for the router's quantization-only full-board fine
/// pass. Board A's ~62x25 mm board is ~400k cells at quarter pitch; a
/// half-million cap admits it while bounding that pass to a small, fixed
/// multiple of the ordinary whole-board grid.
pub const max_fine_board_cells: usize = 500_000;

/// Straight pad-escape reserve (mm) forced on for every windowed rescue leg. A
/// still-failed net is typically hemmed at a fine-pitch pad; this turns on the
/// escape-shaped maze AND the escape-fan direct synthesis (both otherwise gated
/// to RF nets), which hold the pad exit straight along its outward axis long
/// enough to clear the neighbours the coarse grid could not thread past.
pub const escape_reserve_mm: f64 = 0.4;

/// The exact-clearance probe ceiling a rescue window's escape rescue runs
/// under: `window` when the window armed one, else the context's `own` budget
/// (null = the unbounded direct-lattice sweep a whole-board route allows an
/// author-declared RF escape net). A window FORCES the escape reserve on every
/// residual net (`router.routeWindowNet`), so the "these are the few declared
/// RF nets" premise behind that unbounded sweep does not hold inside one and
/// the window has to supply a ceiling of its own.
pub fn escapeRescueBudget(window: ?usize, own: ?usize) ?usize {
    return window orelse own;
}

/// A world-space window (mm) for a local fine-grid retry: the axis-aligned box
/// a still-failed net's terminals live in, plus the search margin.
pub const WindowRect = struct { x0: f64, y0: f64, x1: f64, y1: f64 };

/// A concrete search window the router can build a context over: the clamped
/// rectangle and the grid pitch to raster it at.
///
/// `over_cap` marks the one tier allowed past `max_window_cells` — a DECLARED
/// `(resolution …)` on a whole-net window. The router owes such a window two
/// things the automatic tiers do not need: the tighter
/// `declared_window_expansions` search ceiling, and the connectivity accept gate
/// in `fine_accept.zig` (a window this wide can lay copper that islands a pour
/// another rail was riding, which per-window DRC cannot see).
pub const Window = struct { rect: WindowRect, pitch: f64, over_cap: bool = false };

/// A net's whole-board grid pitch = its effective track width + clearance (the
/// `(net-class …)` overlay on `base`), computed without a routing context.
pub fn netPitch(base: router.RouteParams, placement: optimizer.Placement, net_i: usize) f64 {
    var tw = base.track_width;
    var cl = base.clearance;
    if (net_i < placement.rules.net.len) {
        const r = placement.rules.net[net_i];
        if (r.width > 0) tw = r.width;
        if (r.clearance > 0) cl = r.clearance;
    }
    return tw + cl;
}

/// Grid-cell count of `rect` at pitch `g` (mirrors `router.windowCtx`'s sizing)
/// so a window can be budgeted before it is allocated. Also the sizing the
/// router's board-spanning fine pass budgets itself by, hence `pub`.
pub fn windowCells(rect: WindowRect, g: f64) usize {
    const nx = numeric.toCount(@ceil(@max(rect.x1 - rect.x0, 0) / g) + 1);
    const ny = numeric.toCount(@ceil(@max(rect.y1 - rect.y0, 0) / g) + 1);
    return nx * ny;
}

/// The raster pitch a net DECLARED via `(net-class … (resolution MM))`, or
/// null when it declared none.
///
/// A declared pitch is an author's statement that this net needs geometry the
/// adaptive tiers cannot express — board-a's `SPI_SCK` has a legal detour
/// clearing its obstacles by 0.07-0.20 mm, which no ordering or priority can
/// help because the lattice cannot put a centerline there. It is honoured as
/// the FIRST tier so the net gets what it asked for before the defaults.
pub fn declaredPitch(placement: optimizer.Placement, net_i: usize) ?f64 {
    if (net_i >= placement.rules.net.len) return null;
    const mm = placement.rules.net[net_i].resolution_mm;
    return if (mm > 0) mm else null;
}

/// The candidate windows for re-routing a whole net's terminal tree, in try
/// order: the net's declared pitch when it has one, then half pitch, then
/// quarter pitch. A tier whose window would exceed the cell budget is null
/// (skipped), so a board-spanning net yields no whole-net window and the router
/// falls to per-leg.
pub fn wholeWindows(placement: optimizer.Placement, pts: []const router.NetPt, base: f64, declared: ?f64) [3]?Window {
    return tierWindows(clampRect(placement, terminalBox(pts)), base, declared, max_declared_window_cells);
}

/// The candidate windows for one nearest-pair leg (two terminals), same tier
/// order as `wholeWindows`. A leg's declared tier is held to the AUTOMATIC cap:
/// the over-cap allowance exists for the one board-spanning detour a net's whole
/// terminal tree needs, and handing it to every leg of a multi-drop net would
/// multiply the cost of a single declaration by the leg count.
pub fn legWindows(placement: optimizer.Placement, a: router.NetPt, b: router.NetPt, base: f64, declared: ?f64) [3]?Window {
    return tierWindows(clampRect(placement, pairBox(a, b)), base, declared, max_window_cells);
}

/// Declared pitch (when any, budgeted at `declared_cap`), then half- and
/// quarter-pitch windows over `box`, each null when over the cell budget at that
/// pitch.
fn tierWindows(box: WindowRect, base: f64, declared: ?f64, declared_cap: usize) [3]?Window {
    return .{
        if (declared) |g| declaredWindow(box, g, declared_cap) else null,
        budgeted(box, base * tier1_scale, max_window_cells),
        budgeted(box, base * tier2_scale, max_window_cells),
    };
}

/// Cell budget for a whole-net window at a pitch the design DECLARED.
///
/// A declared pitch is not a guess — the author asked for it — so it is allowed
/// a wider window than an automatic retry. Measured 2026-08-05 on board-a's
/// `SPI_SCK`, the net the `(resolution …)` form was written for: its terminal
/// box grows to 51.0 x 13.8 mm, which is **283,094 cells** at the 0.05 mm it
/// declares. At the automatic 60k cap that window was silently dropped, so the
/// declaration did nothing at all — the form was inert on its own motivating
/// net. 320k admits it with room for a placement nudge to grow the box, and
/// still bounds one window to ~20 MB and one full sweep (`declaredWindowBudget`).
///
/// The number is NOT the whole fix. Raising it alone was measured NET-NEGATIVE
/// once: `TXDATA_ADF` closed, but `GND`, `loop_amp/LF_OUT` and
/// `boost22/BOOST22_SW` broke, taking the board 83/90 -> 81/90 while the
/// router's own claim ROSE to 87. A window this wide lays copper across the
/// whole board, and the per-window clean-DRC gate cannot see that it islanded a
/// pour another rail was riding. So an over-cap window is admitted only together
/// with `fine_accept.Gate` — the connectivity oracle asked before and after,
/// which keeps the attempt only when the board strictly improves.
pub const max_declared_window_cells: usize = 320_000;

/// A window at pitch `g`, or null when it would exceed `cap` cells. Flags the
/// result `over_cap` when it only fits because `cap` is the declared allowance.
fn declaredWindow(box: WindowRect, g: f64, cap: usize) ?Window {
    const cells = windowCells(box, g);
    if (cells > cap) return null;
    return .{ .rect = box, .pitch = g, .over_cap = cells > max_window_cells };
}

/// A window at pitch `g`, or null when it would exceed `cap` cells.
fn budgeted(box: WindowRect, g: f64, cap: usize) ?Window {
    if (windowCells(box, g) > cap) return null;
    return .{ .rect = box, .pitch = g };
}

/// The axis-aligned bounding box of a net's terminals.
fn terminalBox(pts: []const router.NetPt) WindowRect {
    var r = WindowRect{ .x0 = pts[0].x, .y0 = pts[0].y, .x1 = pts[0].x, .y1 = pts[0].y };
    for (pts) |p| {
        r.x0 = @min(r.x0, p.x);
        r.y0 = @min(r.y0, p.y);
        r.x1 = @max(r.x1, p.x);
        r.y1 = @max(r.y1, p.y);
    }
    return r;
}

/// The bounding box of two terminals.
fn pairBox(a: router.NetPt, b: router.NetPt) WindowRect {
    return .{ .x0 = @min(a.x, b.x), .y0 = @min(a.y, b.y), .x1 = @max(a.x, b.x), .y1 = @max(a.y, b.y) };
}

/// Grow `rect` by the search margin and clamp it to the whole-board grid extent.
fn clampRect(placement: optimizer.Placement, rect: WindowRect) WindowRect {
    return .{
        .x0 = @max(rect.x0 - window_margin_mm, placement.minx - grid_margin_mm),
        .y0 = @max(rect.y0 - window_margin_mm, placement.miny - grid_margin_mm),
        .x1 = @min(rect.x1 + window_margin_mm, placement.maxx + grid_margin_mm),
        .y1 = @min(rect.y1 + window_margin_mm, placement.maxy + grid_margin_mm),
    };
}

/// Squared distance between two terminals (ordering only, so sqrt is skipped).
fn dist2(a: router.NetPt, b: router.NetPt) f64 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return dx * dx + dy * dy;
}

/// Greedy minimum-spanning-tree leg order over a net's terminals: repeatedly
/// join the closest pair in different components until one component remains.
/// Deterministic (fixed i<j scan, strict-`<` tie-break keeps the first pair), so
/// the same terminals always yield the same legs. Returns `n-1` index pairs.
pub fn mstLegs(arena: std.mem.Allocator, pts: []const router.NetPt) std.mem.Allocator.Error![]const [2]usize {
    const n = pts.len;
    const comp = try arena.alloc(usize, n);
    for (comp, 0..) |*c, i| c.* = i;
    var legs: std.ArrayList([2]usize) = .empty;
    var joined: usize = 1;
    while (joined < n) : (joined += 1) {
        var best = std.math.inf(f64);
        var bi: usize = 0;
        var bj: usize = 0;
        var found = false;
        for (0..n) |i| {
            for (i + 1..n) |j| {
                if (comp[i] == comp[j]) continue;
                const d = dist2(pts[i], pts[j]);
                if (d < best) {
                    best = d;
                    bi = i;
                    bj = j;
                    found = true;
                }
            }
        }
        if (!found) break;
        try legs.append(arena, .{ bi, bj });
        const from = comp[bj];
        const to = comp[bi];
        for (comp) |*c| {
            if (c.* == from) c.* = to;
        }
    }
    return legs.toOwnedSlice(arena);
}

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

// spec: placement/router - a fine window's grid-cell count scales with its rectangle and pitch
test "window cell count scales with rectangle and pitch" {
    const rect = WindowRect{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 5 };
    // (ceil(10/1)+1) * (ceil(5/1)+1) = 11 * 6.
    try testing.expectEqual(@as(usize, 11 * 6), windowCells(rect, 1.0));
    // Halving the pitch roughly quadruples the cells (21*11 vs 11*6).
    try testing.expectEqual(@as(usize, 21 * 11), windowCells(rect, 0.5));
    try testing.expect(windowCells(rect, 0.5) > 3 * windowCells(rect, 1.0));
}

// spec: placement/router - a fine-window tier over budget yields no candidate at that pitch
test "an over-budget window tier yields no candidate" {
    var placement = std.mem.zeroes(optimizer.Placement);
    placement.minx = 0;
    placement.miny = 0;
    placement.maxx = 400;
    placement.maxy = 400;
    // Two terminals spanning a big box: at a fine pitch the whole-net window
    // overflows the cell budget, so its tiers are null (the router then goes
    // per-leg). A tight pitch of 0.05 mm over ~400 mm is far past the budget.
    const pts = [_]router.NetPt{
        .{ .x = 0, .y = 0, .layer = 0 },
        .{ .x = 400, .y = 400, .layer = 0 },
    };
    const windows = wholeWindows(placement, &pts, 0.1, null);
    try testing.expect(windows[1] == null);
    try testing.expect(windows[2] == null);
    // A small box at the same pitch DOES fit, and reports the finer pitch.
    const near = [_]router.NetPt{
        .{ .x = 10, .y = 10, .layer = 0 },
        .{ .x = 12, .y = 11, .layer = 0 },
    };
    const ok = wholeWindows(placement, &near, 0.254, null);
    try testing.expect(ok[0] == null); // no declared pitch → the declared tier is empty
    try testing.expect(ok[1] != null);
    try testing.expectApproxEqAbs(@as(f64, 0.254 * tier1_scale), ok[1].?.pitch, 1e-9);
    try testing.expect(ok[1].?.pitch < 0.254);
}

// spec: placement/router - a fine window grows a net's terminal box by the margin and clamps it to the board
test "the window grows a terminal box by the margin and clamps it to the board" {
    var placement = std.mem.zeroes(optimizer.Placement);
    placement.minx = 0;
    placement.miny = 0;
    placement.maxx = 100;
    placement.maxy = 100;
    // A window well inside the board is the terminal box grown by `window_margin_mm`.
    const inside = clampRect(placement, pairBox(
        .{ .x = 10, .y = 10, .layer = 0 },
        .{ .x = 20, .y = 12, .layer = 0 },
    ));
    try testing.expectApproxEqAbs(@as(f64, 10 - window_margin_mm), inside.x0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 20 + window_margin_mm), inside.x1, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 12 + window_margin_mm), inside.y1, 1e-9);
    // A window hugging the corner clamps to `min - grid_margin_mm`, not past it.
    var small = std.mem.zeroes(optimizer.Placement);
    small.maxx = 5;
    small.maxy = 5;
    const corner = clampRect(small, .{ .x0 = 0, .y0 = 0, .x1 = 5, .y1 = 5 });
    try testing.expectApproxEqAbs(@as(f64, -grid_margin_mm), corner.x0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 5 + grid_margin_mm), corner.x1, 1e-9);
}

// spec: placement/router - a fine-window multi-terminal net orders legs by nearest unconnected pair spanning every terminal
test "mst legs join nearest unconnected pairs across every terminal" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // Four collinear pads at x = 0, 1, 5, 6: the two tight pairs (0-1, 2-3) are
    // nearest, then the 1-2 bridge (gap 4) joins the halves — three legs, a
    // spanning tree, no cycle.
    const pts = [_]router.NetPt{
        .{ .x = 0, .y = 0, .layer = 0 },
        .{ .x = 1, .y = 0, .layer = 0 },
        .{ .x = 5, .y = 0, .layer = 0 },
        .{ .x = 6, .y = 0, .layer = 0 },
    };
    const legs = try mstLegs(arena, &pts);
    try testing.expectEqual(@as(usize, 3), legs.len);
    try testing.expectEqual([2]usize{ 0, 1 }, legs[0]);
    try testing.expectEqual([2]usize{ 2, 3 }, legs[1]);
    try testing.expectEqual([2]usize{ 1, 2 }, legs[2]);
    // A two-terminal net is a single leg.
    const two = try mstLegs(arena, pts[0..2]);
    try testing.expectEqual(@as(usize, 1), two.len);
}

// spec: placement/route-resolution - a net class may declare the raster pitch its rescue windows use, tried ahead of the adaptive tiers
test "a declared pitch leads the tier order" {
    var placement = std.mem.zeroes(optimizer.Placement);
    placement.minx = -1;
    placement.miny = -1;
    placement.maxx = 5;
    placement.maxy = 5;
    const rules = [_]optimizer.NetRule{.{ .resolution_mm = 0.05 }};
    placement.rules.net = &rules;
    try testing.expectEqual(@as(?f64, 0.05), declaredPitch(placement, 0));

    const a = router.NetPt{ .x = 0, .y = 0, .layer = 0 };
    const b = router.NetPt{ .x = 2, .y = 0, .layer = 0 };
    const ws = legWindows(placement, a, b, 0.254, declaredPitch(placement, 0));
    try testing.expectApproxEqAbs(@as(f64, 0.05), ws[0].?.pitch, 1e-12);
    // …and the adaptive tiers still follow it, unchanged.
    try testing.expectApproxEqAbs(@as(f64, 0.254 * tier1_scale), ws[1].?.pitch, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.254 * tier2_scale), ws[2].?.pitch, 1e-12);
}

// spec: placement/route-resolution - a whole-net window at a declared resolution may exceed the automatic cell cap, and is flagged over-cap so the router gates and budgets it
test "a board-spanning declared window is admitted over-cap on the whole net only" {
    var placement = std.mem.zeroes(optimizer.Placement);
    placement.minx = -1;
    placement.miny = -1;
    placement.maxx = 60;
    placement.maxy = 20;
    // A ~35 mm span at 0.05 mm needs far more cells than an AUTOMATIC retry is
    // allowed — the exact shape of board-a's SPI_SCK, which is why the form
    // was inert on the one net it was written for.
    const a = router.NetPt{ .x = 0, .y = 0, .layer = 0 };
    const b = router.NetPt{ .x = 35, .y = 5, .layer = 0 };
    const pts = [_]router.NetPt{ a, b };
    const box = clampRect(placement, terminalBox(&pts));
    try testing.expect(windowCells(box, 0.05) > max_window_cells);
    try testing.expect(windowCells(box, 0.05) <= max_declared_window_cells);
    // The WHOLE-net window is built anyway, and says so: `over_cap` is what
    // makes the router run it under the connectivity accept gate and the
    // tighter search ceiling instead of the ordinary window's.
    const whole = wholeWindows(placement, &pts, 0.254, 0.05);
    try testing.expectApproxEqAbs(@as(f64, 0.05), whole[0].?.pitch, 1e-12);
    try testing.expect(whole[0].?.over_cap);
    // A LEG keeps the automatic cap: the allowance is for one board-spanning
    // detour, not for every leg of a multi-drop net.
    const ws = legWindows(placement, a, b, 0.254, 0.05);
    try testing.expect(ws[0] == null);
    // A declaration that fits the automatic cap is honoured as before, first in
    // tier order, and is NOT flagged over-cap (so it costs no gate).
    const near = legWindows(placement, a, router.NetPt{ .x = 3, .y = 1, .layer = 0 }, 0.254, 0.05);
    try testing.expectApproxEqAbs(@as(f64, 0.05), near[0].?.pitch, 1e-12);
    try testing.expect(!near[0].?.over_cap);
    // A pathological declaration is still dropped rather than honoured at any
    // cost: 0.005 mm over the same span is ~100x past the declared cap.
    try testing.expect(wholeWindows(placement, &pts, 0.254, 0.005)[0] == null);
}

// spec: placement/route-resolution - a net that declares no resolution keeps the adaptive half- and quarter-pitch tiers exactly
test "no declared pitch leaves the adaptive tiers alone" {
    var placement = std.mem.zeroes(optimizer.Placement);
    placement.minx = -1;
    placement.miny = -1;
    placement.maxx = 5;
    placement.maxy = 5;
    try testing.expectEqual(@as(?f64, null), declaredPitch(placement, 0));
    const a = router.NetPt{ .x = 0, .y = 0, .layer = 0 };
    const b = router.NetPt{ .x = 2, .y = 0, .layer = 0 };
    const ws = legWindows(placement, a, b, 0.254, null);
    try testing.expect(ws[0] == null);
    try testing.expectApproxEqAbs(@as(f64, 0.254 * tier1_scale), ws[1].?.pitch, 1e-12);
}

// spec: placement/router - a fine rescue window bounds the escape direct-synthesis probe sweep it forces on, while a whole-board route keeps the unbounded sweep an author-declared escape net is allowed
test "a rescue window's probe ceiling outranks the context's own budget" {
    // Whole-board route: no window ceiling, so the context's own budget stands
    // — null there, i.e. the historical unbounded sweep.
    try testing.expectEqual(@as(?usize, null), escapeRescueBudget(null, null));
    try testing.expectEqual(@as(?usize, 7), escapeRescueBudget(null, 7));
    // Inside a window the ceiling wins, including over a budget already spent
    // by the attempt that ran before the rescue.
    try testing.expectEqual(@as(?usize, 200_000), escapeRescueBudget(200_000, null));
    try testing.expectEqual(@as(?usize, 200_000), escapeRescueBudget(200_000, 0));
}
