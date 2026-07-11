//! Best-of-family rough generation for a **module** (subcircuit): produce a small
//! deterministic set of candidate layouts, score each with the hybrid metric
//! (physics objective × dense style match vs the module's starred ★ reference),
//! keep the winner, and rotate it to the ★'s orientation so it comes out
//! pre-aligned to the hand layout.
//!
//! Why this exists: the audit found the rough engine produces exactly ONE
//! deterministic result with no candidate selection — so the proven leverage
//! ("select on a better metric", never "search harder") had nothing to act on.
//! The corpus sweep then showed the rough seed is usually WORSE than the hand
//! layout on BOTH physics and style (20/22 modules), i.e. real headroom on both
//! axes. This restores the arbiter the audit called for, over a diverse family:
//!
//!   * `rough`  — the default hierarchical/pad-anchored rough seed.
//!   * `force`  — the force-relaxed solve (a different basin; sometimes tighter).
//!
//! Each candidate is scored by `style_score.hybridScore`; the min-`hybrid`
//! candidate wins. The style score already reports the whole-module rotation
//! `rot_k` that best matches the ★, so the winner's poses are rigidly rotated by
//! that amount about the anchor — a free, high-value hand-likeness win (the
//! corpus has many rough seeds mis-rotated 90–270° vs their ★).
//!
//! Additive: this is a NEW endpoint (`/api/rough-best/:name`); it does not touch
//! the default page-load solve path, so it can't regress a normal render.

const std = @import("std");
const httpz = @import("httpz");
const optimizer = @import("../placement/optimizer.zig");
const style_score = @import("style_score.zig");
const pcb_describe = @import("pcb_describe.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const render_pcb_png = @import("../render_pcb_png.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const modules_mod = @import("modules.zig");
const Server = @import("../serve.zig").Server;

/// One scored candidate in the family.
const Candidate = struct {
    name: []const u8,
    placement: optimizer.Placement,
    obj: f64,
    style_pct: f64,
    rot_k: usize,
    hybrid: f64,
    obj_rel: f64,
    /// Crossings among important ratlines (signal airwires + decoupling power
    /// legs; ground/rails excluded — see `optimizer.importantCrossings`).
    crossings: usize,
    /// Overlapping courtyard pairs (see `optimizer.overlapCount`); 0 when clean.
    overlaps: usize,
    /// The selection key: `hybrid` scaled up by the crossing rate and any
    /// overlap — a layout whose important ratlines cross, or whose parts sit on
    /// each other, must beat the clean ones by that much more to win.
    rank: f64,
};

/// Build the set of refs the starred reference doesn't cover (added after the
/// save) — they sit at the origin in the verbatim star render, so drop them from
/// the style comparison exactly as `layout_match` does.
fn coverageExclusions(
    alloc: std.mem.Allocator,
    star: optimizer.Placement,
    saved: pcb_layout_page.SavedLayout,
) std.mem.Allocator.Error!std.StringHashMapUnmanaged(void) {
    var ex = std.StringHashMapUnmanaged(void).empty;
    for (star.parts, 0..) |part, i| {
        const origin = if (i < star.instances.len and star.instances[i].origin_key.len > 0)
            star.instances[i].origin_key
        else
            part.ref_des;
        var hit = false;
        for (saved.parts) |pt| {
            if ((pt.origin.len > 0 and std.mem.eql(u8, pt.origin, origin)) or std.mem.eql(u8, pt.ref, part.ref_des)) {
                hit = true;
                break;
            }
        }
        if (!hit) try ex.put(alloc, part.ref_des, {});
    }
    return ex;
}

/// Score `cand` against `star` on the hybrid metric. `star_obj` is the ★'s own
/// surrogate objective (the reference denominator).
fn scoreCandidate(
    alloc: std.mem.Allocator,
    label: []const u8,
    cand: optimizer.Placement,
    star: optimizer.Placement,
    star_obj: f64,
    excluded: *const std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!Candidate {
    const st = try style_score.compareStyle(alloc, cand, star, excluded);
    const obj = cand.breakdown.objective;
    const hyb = style_score.hybridScore(obj, star_obj, st.style_pct, style_score.lambda_default);
    const crossings = try optimizer.importantCrossings(alloc, cand);
    const overlaps = optimizer.overlapCount(cand);
    const n: f64 = @floatFromInt(@max(cand.parts.len, 1));
    const rank = hyb.hybrid *
        (1.0 + @as(f64, @floatFromInt(crossings)) / n) *
        (1.0 + @as(f64, @floatFromInt(overlaps)));
    return .{
        .name = label,
        .placement = cand,
        .obj = obj,
        .style_pct = st.style_pct,
        .rot_k = st.rot_k,
        .hybrid = hyb.hybrid,
        .obj_rel = hyb.obj_rel,
        .crossings = crossings,
        .overlaps = overlaps,
        .rank = rank,
    };
}

/// Rigidly rotate a placement's poses by `k` CCW quarter-turns about the anchor
/// hub, returning fresh `RefPose`s. Position map R_{90k} and `rot += 90k` share
/// the same angular convention (see `style_score.rotSide`), so the result is a
/// rigid rotation — footprints turn with their positions. `k==0` is a plain copy.
fn rotatePoses(alloc: std.mem.Allocator, p: optimizer.Placement, k: usize) std.mem.Allocator.Error![]optimizer.RefPose {
    const out = try alloc.alloc(optimizer.RefPose, p.parts.len);
    const ai = pcb_describe.anchorIndex(p.parts, p.nets);
    const ax = if (ai) |i| p.parts[i].x else 0;
    const ay = if (ai) |i| p.parts[i].y else 0;
    const kk = k % 4;
    for (p.parts, 0..) |part, i| {
        const dx = part.x - ax;
        const dy = part.y - ay;
        const r: [2]f64 = switch (kk) {
            0 => .{ dx, dy },
            1 => .{ -dy, dx },
            2 => .{ -dx, -dy },
            else => .{ dy, -dx },
        };
        out[i] = .{
            .ref = part.ref_des,
            .x = ax + r[0],
            .y = ay + r[1],
            .rot = @mod(part.rot + 90.0 * @as(f64, @floatFromInt(kk)), 360.0),
            .side = part.side,
            .locked = part.locked,
        };
    }
    return out;
}

/// The best-of-family outcome: the winning variant, its rigidly-★-aligned
/// placement, the winning poses, and the full scored candidate list. `best_pl`
/// and the candidate placements reference the CALLER's evaluators — keep them
/// alive while using this.
const Best = struct {
    starred_name: []const u8,
    star_obj: f64,
    winner: []const u8,
    cands: []Candidate,
    poses: []optimizer.RefPose,
    best_pl: optimizer.Placement,
};

/// Solve the candidate family for `name`, score each against the ★, pick the
/// lowest-hybrid winner, and rebuild it rigidly rotated to the ★ orientation.
/// Returns null when the module has no ★. Evaluators are caller-owned (created
/// and torn down by the caller) so the returned placements stay valid until the
/// caller is done rendering/formatting them.
fn computeBest(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    variant: ?[]const u8,
    eval_s: *Evaluator,
    mr_s: *?modules_mod.ResolvedBlock,
    eval_c: *Evaluator,
    mr_c: *?modules_mod.ResolvedBlock,
) pcb_layout_page.PngError!?Best {
    const layouts = pcb_layout_page.readLayouts(alloc, project_dir, name);
    var saved: ?pcb_layout_page.SavedLayout = null;
    for (layouts) |L| {
        if (L.default) {
            saved = L;
            break;
        }
    }
    if (saved == null) return null;

    // Star placement (verbatim) — its own evaluator so block state can't bleed.
    const star = try pcb_layout_page.solveForRequest(alloc, project_dir, name, .{ .layout = saved.?.name }, eval_s, mr_s);
    const star_obj = star.placement.breakdown.objective;
    var excluded = try coverageExclusions(alloc, star.placement, saved.?);
    defer excluded.deinit(alloc);

    // Candidate family — one evaluator/block reused for all solves.
    // `.regen` forces a FRESH rough (else `solveForRequest` returns the auto-cache
    // sidecar, a stale earlier solve, so the "rough" candidate wouldn't be the
    // engine's current output).
    const rough = try pcb_layout_page.solveForRequest(alloc, project_dir, name, .{ .rough = true, .regen = true }, eval_c, mr_c);
    const block = rough.block;
    const force_pl = optimizer.solve(alloc, block, project_dir, null, .{ .rough = false }, .place) catch return error.BuildFailed;
    const pin_pl = optimizer.solvePinAdjacent(alloc, block, project_dir, .{}) catch return error.BuildFailed;

    var cands: std.ArrayList(Candidate) = .empty;
    cands.append(alloc, try scoreCandidate(alloc, "rough", rough.placement, star.placement, star_obj, &excluded)) catch return error.BuildFailed;
    cands.append(alloc, try scoreCandidate(alloc, "force", force_pl, star.placement, star_obj, &excluded)) catch return error.BuildFailed;
    if (pin_pl) |pp| cands.append(alloc, try scoreCandidate(alloc, "pin", pp, star.placement, star_obj, &excluded)) catch return error.BuildFailed;

    // Winner = lowest rank (hybrid × crossing × overlap penalties); rebuild it
    // rigidly rotated to the ★ orientation.
    var best: usize = 0;
    for (cands.items, 0..) |c, i| {
        if (c.rank < cands.items[best].rank) best = i;
    }
    // An explicit `variant` overrides the arbiter — the debugging lens for
    // viewing one candidate ("show me the pin layout even where force won").
    if (variant) |v| {
        for (cands.items, 0..) |c, i| {
            if (std.mem.eql(u8, c.name, v)) best = i;
        }
    }
    const winner = cands.items[best];
    const poses = try rotatePoses(alloc, winner.placement, winner.rot_k);
    const best_pl = optimizer.placeFromPoses(alloc, block, project_dir, poses, .{ .rough = true }) catch return error.BuildFailed;

    return .{
        .starred_name = saved.?.name,
        .star_obj = star_obj,
        .winner = winner.name,
        .cands = cands.items,
        .poses = poses,
        .best_pl = best_pl,
    };
}

/// Compute the best-of-family result for a starred module and emit the JSON:
/// `{name, starred, lambda, winner, candidates[], poses[]}`. Returns a
/// `starred:null` message when the module has no ★ (the reference the hybrid
/// needs). Bytes owned by `alloc` (pass an arena).
pub fn bestRoughJson(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) pcb_layout_page.PngError![]u8 {
    var eval_s = Evaluator.init(alloc, project_dir);
    defer eval_s.deinit();
    var mr_s: ?modules_mod.ResolvedBlock = null;
    defer if (mr_s) |m| {
        m.eval.deinit();
        alloc.destroy(m.eval);
    };
    var eval_c = Evaluator.init(alloc, project_dir);
    defer eval_c.deinit();
    var mr_c: ?modules_mod.ResolvedBlock = null;
    defer if (mr_c) |m| {
        m.eval.deinit();
        alloc.destroy(m.eval);
    };
    const best = try computeBest(alloc, project_dir, name, null, &eval_s, &mr_s, &eval_c, &mr_c);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    if (best == null) {
        w.writeAll("{\"name\":") catch return error.BuildFailed;
        pcb_layout_page.writeJsonStr(w, name) catch return error.BuildFailed;
        w.writeAll(",\"starred\":null,\"message\":\"best-of-family needs a starred ★ reference to score against — ") catch return error.BuildFailed;
        w.writeAll("hand-arrange, Save, Set default, and re-run.\"}") catch return error.BuildFailed;
        return aw.written();
    }
    const b = best.?;

    w.writeAll("{\"name\":") catch return error.BuildFailed;
    pcb_layout_page.writeJsonStr(w, name) catch return error.BuildFailed;
    w.writeAll(",\"starred\":") catch return error.BuildFailed;
    pcb_layout_page.writeJsonStr(w, b.starred_name) catch return error.BuildFailed;
    w.print(",\"lambda\":{d:.2},\"winner\":", .{style_score.lambda_default}) catch return error.BuildFailed;
    pcb_layout_page.writeJsonStr(w, b.winner) catch return error.BuildFailed;
    w.print(",\"star_obj\":{d:.2},\"candidates\":[", .{b.star_obj}) catch return error.BuildFailed;
    for (b.cands, 0..) |c, i| {
        if (i > 0) w.writeAll(",") catch return error.BuildFailed;
        w.writeAll("{\"variant\":") catch return error.BuildFailed;
        pcb_layout_page.writeJsonStr(w, c.name) catch return error.BuildFailed;
        w.print(
            ",\"obj\":{d:.2},\"obj_rel\":{d:.3},\"style_pct\":{d:.1},\"rot_k\":{d},\"hybrid\":{d:.3},\"crossings\":{d},\"overlaps\":{d},\"rank\":{d:.3}}}",
            .{ c.obj, c.obj_rel, c.style_pct, c.rot_k, c.hybrid, c.crossings, c.overlaps, c.rank },
        ) catch return error.BuildFailed;
    }
    w.writeAll("],\"poses\":[") catch return error.BuildFailed;
    for (b.poses, 0..) |ps, i| {
        if (i > 0) w.writeAll(",") catch return error.BuildFailed;
        w.writeAll("{\"ref\":") catch return error.BuildFailed;
        pcb_layout_page.writeJsonStr(w, ps.ref) catch return error.BuildFailed;
        w.print(",\"x\":{d:.3},\"y\":{d:.3},\"rot\":{d:.0}}}", .{ ps.x, ps.y, ps.rot }) catch return error.BuildFailed;
    }
    w.writeAll("]}") catch return error.BuildFailed;
    return aw.written();
}

/// GET /api/rough-best-png/:name — render the best-of-family winner as a PNG so
/// the generated layout is directly viewable (not just its pose JSON).
pub fn bestRoughPngApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) pcb_layout_page.HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const alloc = req.arena;
    var eval_s = Evaluator.init(alloc, ctx.project_dir);
    defer eval_s.deinit();
    var mr_s: ?modules_mod.ResolvedBlock = null;
    defer if (mr_s) |m| {
        m.eval.deinit();
        alloc.destroy(m.eval);
    };
    var eval_c = Evaluator.init(alloc, ctx.project_dir);
    defer eval_c.deinit();
    var mr_c: ?modules_mod.ResolvedBlock = null;
    defer if (mr_c) |m| {
        m.eval.deinit();
        alloc.destroy(m.eval);
    };
    const variant: ?[]const u8 = if (req.query()) |q| q.get("variant") else |_| null;
    const best = computeBest(alloc, ctx.project_dir, name, variant, &eval_s, &mr_s, &eval_c, &mr_c) catch |e| {
        res.status = if (e == error.BlockNotFound or e == error.SubNotFound) 404 else 500;
        res.body = "best-of-family render failed";
        return;
    } orelse {
        res.status = 404;
        res.body = "no starred ★ layout to generate against";
        return;
    };
    const png_bytes = render_pcb_png.render(alloc, best.best_pl, .{ .width = 1200, .title = name, .names = .origin }) catch {
        res.status = 500;
        res.body = "png render failed";
        return;
    };
    res.content_type = .PNG;
    res.header("Cache-Control", "no-store");
    res.body = png_bytes;
}

/// GET /api/rough-best/:name — best-of-family rough generation scoreboard + poses.
pub fn bestRoughApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) pcb_layout_page.HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = bestRoughJson(req.arena, ctx.project_dir, name) catch |e| {
        res.status = if (e == error.BlockNotFound or e == error.SubNotFound) 404 else 500;
        res.body = "{\"error\":\"rough-best failed\"}";
        return;
    };
    res.content_type = .JSON;
    res.body = body;
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Web Server - rough-best rotatePoses rigidly rotates a placement about the anchor
test "rotatePoses rotates about the anchor and turns footprints with positions" {
    var astate = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    // Anchor hub at origin (a 2-pin part so pickAnchorHub can key on net degree
    // isn't needed — this unit test builds the geometry directly and asserts the
    // rotation math, so we bypass anchorIndex by placing the anchor at (0,0)).
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 0, .y = 0, .rot = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.25, .pads = &.{}, .fallback = false, .x = 2, .y = 0, .rot = 0 },
    };
    var pl: optimizer.Placement = .{
        .parts = &parts,
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
    };
    // No anchor hub resolvable from empty nets → anchor falls back to (0,0), which
    // is where U1 sits anyway. Rotate C1 at (2,0) by 90° CCW (R_{90}) → (0,2).
    const poses = try rotatePoses(arena, pl, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 0), poses[1].x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2), poses[1].y, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 90), poses[1].rot, 1e-9);
    _ = &pl;
}
