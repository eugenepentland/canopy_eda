//! GET /api/placement-spec/:name — reverse-engineer an editable `(placement …)`
//! spec from any solved layout, closing the DSL loop: the optimizer (or a saved
//! hand layout) finds a good arrangement, this endpoint turns it back into the
//! declarative form, and an agent tweaks one side and re-solves deterministically.
//! Same placement-selection logic and query parameters as /api/pcb-png
//! (`layout=` picks a saved layout, `regen=1` a fresh solve, `sub=` a module
//! scope), so the exported spec describes exactly the board the image shows.
//! `?format=sexp` returns the bare spec text instead of the JSON wrapper.

const std = @import("std");
const httpz = @import("httpz");
const optimizer = @import("../placement/optimizer.zig");
const pcb_router = @import("../placement/router.zig");
const drc = @import("../placement/drc.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const design_block = @import("../eval/design_block.zig");
const modules_mod = @import("modules.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const pcb_describe = @import("pcb_describe.zig");
const render_pcb_png = @import("../render_pcb_png.zig");
const serve_root = @import("../serve.zig");
const edit = @import("edit.zig");
const paths = @import("../paths.zig");
const infra_fs = @import("../infra/fs.zig");
const Handler = serve_root.Handler;

/// 400 body shared by the POST endpoints that expect a bare spec form.
const ERR_NEED_FORM = "{\"error\":\"send the (placement ...) or (floorplan ...) form as the request body\"}";
/// 500 body shared by the save paths when the target file can't be written.
const ERR_WRITE_FAILED = "{\"error\":\"write failed\"}";
/// JSON object opener for the responses that lead with the design name.
const NAME_OPEN = "{\"name\":";

/// GET /api/placement-spec/:name — accepts the same query parameters as
/// /api/pcb-png (layout=, regen=, sub=, placement=off) plus `format=sexp`.
pub fn placementSpecApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) pcb_layout_page.HandlerError!void {
    const arena = req.arena;
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const opts = pcb_layout_page.pngRequestFromQuery(arena, req);
    const result = exportSpec(arena, ctx.project_dir, name, opts) catch |e| {
        res.status = if (e == error.BlockNotFound or e == error.SubNotFound) 404 else 500;
        res.body = "{\"error\":\"spec export failed\"}";
        return;
    };
    if (result.sexp.len == 0) {
        res.status = 422;
        res.content_type = .JSON;
        res.body = "{\"error\":\"no hub anchor - a (placement ...) spec needs an IC\"}";
        return;
    }
    const want_sexp = blk: {
        const q = req.query() catch break :blk false;
        const v = q.get("format") orelse break :blk false;
        break :blk std.mem.eql(u8, v, "sexp");
    };
    if (want_sexp) {
        res.content_type = .TEXT;
        res.body = result.sexp;
        return;
    }
    res.content_type = .JSON;
    res.body = result.json;
}

/// POST /api/propose-placement/:name — dry-run a `(placement …)` /
/// `(floorplan …)` form sent as the request body: solve it against a
/// request-local copy of the design, compare against the current layout, and
/// return both scoreboards. Nothing is written — the agent A/B-tests a spec
/// BEFORE committing it to the .sexp file. `?route=1` also routes both.
pub fn proposePlacementApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) pcb_layout_page.HandlerError!void {
    const arena = req.arena;
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = ERR_NEED_FORM;
        return;
    };
    const route = blk: {
        const q = req.query() catch break :blk false;
        const v = q.get("route") orelse break :blk false;
        break :blk v.len > 0 and v[0] == '1';
    };
    const result = proposePlacement(arena, ctx.project_dir, name, body, route) catch |e| {
        res.status = if (e == error.BlockNotFound or e == error.SubNotFound) 404 else 500;
        res.body = "{\"error\":\"propose failed\"}";
        return;
    };
    res.content_type = .JSON;
    if (result == null) {
        res.status = 422;
        res.body = "{\"error\":\"no (placement ...) or (floorplan ...) form found in the body\"}";
        return;
    }
    res.body = result.?;
}

/// POST /api/spec-solve/:name — the PCB page's live-preview hook: solve the
/// posted `(placement …)` / `(floorplan …)` form against a request-local copy
/// of the design (nothing written) and return the solved POSES plus the spec
/// diagnostics, so the browser can re-render the board as the user types.
/// `propose-placement` is the scoreboard twin (numbers only); this one carries
/// geometry.
pub fn specSolveApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) pcb_layout_page.HandlerError!void {
    const arena = req.arena;
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.content_type = .JSON;
        res.body = ERR_NEED_FORM;
        return;
    };
    res.content_type = .JSON;
    const result = specSolve(arena, ctx.project_dir, name, body) catch |e| {
        res.status = if (e == error.BlockNotFound or e == error.SubNotFound) 404 else 500;
        res.body = "{\"error\":\"solve failed\"}";
        return;
    };
    if (result == null) {
        res.status = 422;
        res.body = "{\"error\":\"couldn't parse - expected a (placement ...) or (floorplan ...) form\"}";
        return;
    }
    res.body = result.?;
}

/// Request-local spec solve returning poses + diagnostics JSON. Null when the
/// body holds no parseable placement/floorplan form.
pub fn specSolve(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    spec_text: []const u8,
) pcb_layout_page.PngError!?[]u8 {
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const base = try pcb_layout_page.solveForRequest(alloc, project_dir, name, .{}, &eval, &module_res);
    const parsed = (design_block.parsePlacementText(&eval, spec_text) catch null) orelse return null;
    if (parsed.floorplan) {
        base.block.floorplan = parsed.spec;
    } else {
        base.block.placement = parsed.spec;
    }
    const proposed = optimizer.solve(alloc, base.block, project_dir, null, base.params, .place) catch
        return error.BuildFailed;
    const diag = optimizer.placementDiag();

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    writeSolveJson(w, name, parsed.floorplan, base.placement, proposed, diag) catch return error.BuildFailed;
    return aw.written();
}

/// The spec-solve response: solved poses (the browser re-renders from these),
/// the proposed/current objectives, and the spec-coverage diagnostics.
fn writeSolveJson(
    w: *std.Io.Writer,
    name: []const u8,
    floorplan: bool,
    current: optimizer.Placement,
    proposed: optimizer.Placement,
    diag: optimizer.PlacementDiag,
) BuildError!void {
    try w.writeAll(NAME_OPEN);
    try pcb_layout_page.writeJsonStr(w, name);
    try w.print(",\"form\":\"{s}\"", .{if (floorplan) "floorplan" else "placement"});
    try w.writeAll(",\"parts\":[");
    for (proposed.parts, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"ref\":");
        try pcb_layout_page.writeJsonStr(w, p.ref_des);
        try w.print(",\"x\":{d:.3},\"y\":{d:.3},\"rot\":{d:.0}}}", .{ p.x, p.y, p.rot });
    }
    try w.writeAll("]");
    const pb = proposed.breakdown;
    try w.print(",\"objective\":{d:.1},\"hpwl\":{d:.1},\"loop_nh\":{d:.1}", .{ pb.objective, pb.hpwl, pb.loop_nh });
    try w.print(",\"current_objective\":{d:.1},\"delta_objective\":{d:.1}", .{
        current.breakdown.objective, pb.objective - current.breakdown.objective,
    });
    try w.print(",\"used_spec\":{}", .{diag.used_spec});
    try writeRefList(w, ",\"unplaced\":", diag.unplaced);
    try writeRefList(w, ",\"auto_filled\":", diag.auto_filled);
    try writeRefList(w, ",\"unresolved\":", diag.unresolved);
    try w.writeAll("}");
}

/// POST /api/spec-save/:name — write the posted spec into the design's .sexp:
/// replace its existing top-level `(placement …)` / `(floorplan …)` form, or
/// insert one before the design-block's closing paren. A history snapshot is
/// taken first (`edit.writeAndRebuild`), the design re-evaluates, and the live
/// version bumps so open viewers refresh. When `name` is a lib/modules module
/// instead of a design, the spec splices into the `(design-block …)` inside
/// its `(defmodule …)` body — every design instantiating the module picks the
/// layout up on its next solve.
pub fn specSaveApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) pcb_layout_page.HandlerError!void {
    const arena = req.arena;
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    res.content_type = .JSON;
    const body_raw = req.body() orelse {
        res.status = 400;
        res.body = ERR_NEED_FORM;
        return;
    };
    const body = std.mem.trim(u8, body_raw, " \t\r\n");

    // Validate the form parses before touching the file.
    var eval = Evaluator.init(arena, ctx.project_dir);
    defer eval.deinit();
    const parsed = (design_block.parsePlacementText(&eval, body) catch null) orelse {
        res.status = 422;
        res.body = "{\"error\":\"couldn't parse - expected a (placement ...) or (floorplan ...) form\"}";
        return;
    };

    const path = paths.designSourcePath(arena, ctx.project_dir, name) catch {
        res.status = 500;
        return;
    };
    const token: []const u8 = if (parsed.floorplan) "(floorplan" else "(placement";
    const source = infra_fs.cwd().readFileAlloc(arena, path, MAX_DESIGN_BYTES) catch {
        // Not a design — fall through to the module save path.
        try specSaveModule(ctx, res, arena, name, body, token);
        return;
    };
    const new_source = splicePlacementForm(arena, source, body, token) catch {
        res.status = 500;
        return;
    } orelse {
        res.status = 422;
        res.body = "{\"error\":\"no (design-block ...) found in the design file\"}";
        return;
    };
    const mr = edit.writeAndRebuild(arena, ctx.project_dir, name, new_source, "placement spec edit (PCB page)") catch |e| {
        res.status = 500;
        if (e == error.RebuildFailed) {
            // The file is written (snapshot exists for undo) but no longer
            // evaluates — surface that loudly instead of a silent 500.
            res.body = "{\"error\":\"design failed to rebuild after the edit - restore from history\"}";
        } else {
            res.body = ERR_WRITE_FAILED;
        }
        return;
    };
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.print("{{\"ok\":true,\"version\":{d}", .{mr.version}) catch return error.OutOfMemory;
    if (mr.snapshot) |id| {
        w.writeAll(",\"snapshot\":") catch return error.OutOfMemory;
        pcb_layout_page.writeJsonStr(w, id) catch return error.OutOfMemory;
    }
    w.writeAll("}") catch return error.OutOfMemory;
    res.body = aw.written();
}

/// POST /api/flip-side/:name — set the design's placement `(back-side …)` clause
/// to exactly the posted ref list. The PCB page's "hover a part, press F" flip
/// sends every part currently on the back copper layer; this writes that set to
/// source. The body is a bare list of ref-des separated by commas/whitespace
/// (empty clears the clause). Only the `(back-side …)` clause changes — any
/// hand-authored anchor/side lists in the `(placement …)` form are preserved —
/// then a history snapshot is taken, the design re-evaluates, and the live
/// version bumps so the colour (and the exported KiCad layer) persists.
pub fn flipSideApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) pcb_layout_page.HandlerError!void {
    const arena = req.arena;
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    res.content_type = .JSON;
    const body = std.mem.trim(u8, req.body() orelse "", " \t\r\n");

    var refs: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, body, ", \t\r\n");
    while (it.next()) |tok| {
        // A ref-des never contains a quote/paren; skip anything that would break
        // the emitted clause (the client only ever sends real part refs).
        if (std.mem.indexOfAny(u8, tok, "\"()") != null) continue;
        refs.append(arena, tok) catch return error.OutOfMemory;
    }

    const path = paths.designSourcePath(arena, ctx.project_dir, name) catch {
        res.status = 500;
        return;
    };
    const source = infra_fs.cwd().readFileAlloc(arena, path, MAX_DESIGN_BYTES) catch {
        res.status = 404;
        res.body = "{\"error\":\"not a design - back-side flips aren't supported on modules yet\"}";
        return;
    };
    const new_source = (setBackSideClause(arena, source, refs.items) catch {
        res.status = 500;
        return;
    }) orelse {
        res.status = 422;
        res.body = "{\"error\":\"no (design-block ...) found in the design file\"}";
        return;
    };
    const mr = edit.writeAndRebuild(arena, ctx.project_dir, name, new_source, "flip part side (PCB page)") catch |e| {
        res.status = 500;
        res.body = if (e == error.RebuildFailed)
            "{\"error\":\"design failed to rebuild after the flip - restore from history\"}"
        else
            ERR_WRITE_FAILED;
        return;
    };
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.print("{{\"ok\":true,\"version\":{d}}}", .{mr.version}) catch return error.OutOfMemory;
    res.body = aw.written();
}

/// Build a `(back-side "A" "B" …)` clause for `refs` (no escaping — ref-des are
/// plain tokens). Empty `refs` ⇒ empty string (the caller drops the clause).
fn buildBackSideClause(alloc: std.mem.Allocator, refs: []const []const u8) BuildError![]const u8 {
    if (refs.len == 0) return "";
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.writeAll("(back-side");
    for (refs) |r| {
        try w.writeAll(" \"");
        try w.writeAll(r);
        try w.writeAll("\"");
    }
    try w.writeAll(")");
    return aw.written();
}

fn isSpaceByte(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// Surgically rewrite `source` so the placement `(back-side …)` clause lists
/// exactly `refs`, leaving every other clause untouched:
///  - existing `(placement …)` with a `(back-side …)`: replace it (or drop it +
///    its leading whitespace when `refs` is empty);
///  - existing `(placement …)` without one: insert before the form's close;
///  - no placement form (+ non-empty `refs`): insert an anchor-less
///    `(placement (back-side …))` before the design-block close — it declares
///    copper sides only and falls through to auto-placement.
/// Null ⇒ no `(design-block …)` to host the form. String/comment-aware.
fn setBackSideClause(alloc: std.mem.Allocator, source: []const u8, refs: []const []const u8) BuildError!?[]u8 {
    const clause = try buildBackSideClause(alloc, refs);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (findForm(source, "(placement")) |ph| {
        if (findForm(source[ph.start..ph.end], "(back-side")) |rel| {
            const bs = ph.start + rel.start;
            const be = ph.start + rel.end;
            if (refs.len == 0) {
                var s = bs;
                while (s > ph.start and isSpaceByte(source[s - 1])) s -= 1;
                try out.appendSlice(alloc, source[0..s]);
                try out.appendSlice(alloc, source[be..]);
            } else {
                try out.appendSlice(alloc, source[0..bs]);
                try out.appendSlice(alloc, clause);
                try out.appendSlice(alloc, source[be..]);
            }
            return try out.toOwnedSlice(alloc);
        }
        if (refs.len == 0) return try alloc.dupe(u8, source); // nothing to clear
        const close = ph.end - 1; // before the placement form's ')'
        try out.appendSlice(alloc, source[0..close]);
        try out.appendSlice(alloc, "\n  ");
        try out.appendSlice(alloc, clause);
        try out.appendSlice(alloc, source[close..]);
        return try out.toOwnedSlice(alloc);
    }
    if (refs.len == 0) return try alloc.dupe(u8, source); // nothing to add
    const block = findForm(source, "(design-block") orelse return null;
    const close = block.end - 1; // before the design-block's ')'
    try out.appendSlice(alloc, source[0..close]);
    try out.appendSlice(alloc, "\n  (placement ");
    try out.appendSlice(alloc, clause);
    try out.appendSlice(alloc, ")\n");
    try out.appendSlice(alloc, source[close..]);
    return try out.toOwnedSlice(alloc);
}

/// Max design-file size the spec save will read (matches edit.zig's cap).
const MAX_DESIGN_BYTES: usize = 1 << 20;

/// Module tail of the spec save: splice the form into the `(design-block …)`
/// inside `lib/modules/<name>.sexp`'s defmodule body, verify the file still
/// evaluates (request-local) before writing, then bump the live version.
/// No history snapshot — the history store is design-keyed.
fn specSaveModule(
    ctx: *Handler,
    res: *httpz.Response,
    arena: std.mem.Allocator,
    name: []const u8,
    body: []const u8,
    token: []const u8,
) pcb_layout_page.HandlerError!void {
    if (std.mem.indexOfScalar(u8, name, '/') != null or std.mem.indexOf(u8, name, "..") != null) {
        res.status = 400;
        res.body = "{\"error\":\"bad name\"}";
        return;
    }
    const path = std.fmt.allocPrint(arena, "{s}/lib/modules/{s}.sexp", .{ ctx.project_dir, name }) catch {
        res.status = 500;
        return;
    };
    const source = infra_fs.cwd().readFileAlloc(arena, path, MAX_DESIGN_BYTES) catch {
        res.status = 404;
        res.body = "{\"error\":\"no design or module by that name\"}";
        return;
    };
    const new_source = splicePlacementForm(arena, source, body, token) catch {
        res.status = 500;
        return;
    } orelse {
        res.status = 422;
        res.body = "{\"error\":\"no (design-block ...) found in the module body\"}";
        return;
    };
    // The module file must still evaluate with the spec in place — defmodule
    // registration catches syntax damage before anything touches disk.
    var check = Evaluator.init(arena, ctx.project_dir);
    defer check.deinit();
    _ = check.evalSource(new_source) catch {
        res.status = 422;
        res.body = "{\"error\":\"module no longer evaluates with this spec - not written\"}";
        return;
    };
    {
        const file = infra_fs.cwd().createFile(path, .{}) catch {
            res.status = 500;
            res.body = ERR_WRITE_FAILED;
            return;
        };
        defer file.close();
        file.writeAll(new_source) catch {
            res.status = 500;
            res.body = ERR_WRITE_FAILED;
            return;
        };
    }
    const version = serve_root.bumpLiveVersion(name);
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.print("{{\"ok\":true,\"version\":{d},\"module\":true}}", .{version}) catch return error.OutOfMemory;
    res.body = aw.written();
}

/// Replace the design's first top-level `token` form (`(placement` /
/// `(floorplan`) with `spec`, or — when none exists — insert `spec` before the
/// `(design-block …)` form's closing paren. String- and comment-aware (a
/// `(note "VOUT (max 16V)")` must not confuse the balancer). Null when the
/// file has no design-block to host the form.
fn splicePlacementForm(
    alloc: std.mem.Allocator,
    source: []const u8,
    spec: []const u8,
    token: []const u8,
) std.mem.Allocator.Error!?[]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (findForm(source, token)) |hit| {
        try out.appendSlice(alloc, source[0..hit.start]);
        try out.appendSlice(alloc, spec);
        try out.appendSlice(alloc, source[hit.end..]);
        return try out.toOwnedSlice(alloc);
    }
    const block = findForm(source, "(design-block") orelse return null;
    // Insert before the design-block's closing ')' on its own line.
    const close = block.end - 1;
    try out.appendSlice(alloc, source[0..close]);
    try out.appendSlice(alloc, "\n  ");
    try out.appendSlice(alloc, spec);
    try out.appendSlice(alloc, "\n");
    try out.appendSlice(alloc, source[close..]);
    return try out.toOwnedSlice(alloc);
}

const FormHit = struct { start: usize, end: usize };

/// Find the first `token` form outside strings/comments and return its byte
/// range (start of '(' to one past its balancing ')'). The char after the
/// token must be a delimiter, so `(placement` never matches `(placement-order`.
fn findForm(source: []const u8, token: []const u8) ?FormHit {
    var i: usize = 0;
    var in_str = false;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (in_str) {
            if (c == '"') in_str = false;
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            ';' => while (i + 1 < source.len and source[i + 1] != '\n') : (i += 1) {},
            '(' => if (std.mem.startsWith(u8, source[i..], token)) {
                const after = i + token.len;
                const ok = after >= source.len or switch (source[after]) {
                    ' ', '\t', '\r', '\n', '(', ')' => true,
                    else => false,
                };
                if (ok) {
                    if (balanceEnd(source, i)) |e| return .{ .start = i, .end = e };
                    return null;
                }
            },
            else => {},
        }
    }
    return null;
}

/// One past the ')' balancing the '(' at `start`, skipping strings/comments.
fn balanceEnd(source: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var in_str = false;
    var i = start;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (in_str) {
            if (c == '"') in_str = false;
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            ';' => while (i + 1 < source.len and source[i + 1] != '\n') : (i += 1) {},
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return null;
}

/// Dry-run solve of a proposed spec. Returns the comparison JSON, or null when
/// the body holds no parseable placement/floorplan form. The design block is
/// re-evaluated per request, so the in-memory spec swap leaks nowhere.
pub fn proposePlacement(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    spec_text: []const u8,
    route: bool,
) pcb_layout_page.PngError!?[]u8 {
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    // Baseline: the design exactly as a plain GET would solve it.
    const base = try pcb_layout_page.solveForRequest(alloc, project_dir, name, .{}, &eval, &module_res);
    const parsed = (design_block.parsePlacementText(&eval, spec_text) catch null) orelse return null;

    // Swap the spec on the request-local block and solve fresh.
    if (parsed.floorplan) {
        base.block.floorplan = parsed.spec;
    } else {
        base.block.placement = parsed.spec;
    }
    const proposed = optimizer.solve(alloc, base.block, project_dir, null, base.params, .place) catch
        return error.BuildFailed;
    const diag = optimizer.placementDiag();

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    writeProposeJson(w, alloc, name, parsed.floorplan, base.placement, proposed, diag, route) catch
        return error.BuildFailed;
    return aw.written();
}

/// The comparison document both propose surfaces (HTTP + MCP) return.
fn writeProposeJson(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    name: []const u8,
    floorplan: bool,
    current: optimizer.Placement,
    proposed: optimizer.Placement,
    diag: optimizer.PlacementDiag,
    route: bool,
) BuildError!void {
    try w.writeAll(NAME_OPEN);
    try pcb_layout_page.writeJsonStr(w, name);
    try w.print(",\"form\":\"{s}\"", .{if (floorplan) "floorplan" else "placement"});
    try w.writeAll(",\"proposed\":");
    try writeScoreObj(w, alloc, proposed, route);
    try w.print(",\"used_spec\":{}", .{diag.used_spec});
    try writeRefList(w, ",\"unplaced\":", diag.unplaced);
    try writeRefList(w, ",\"auto_filled\":", diag.auto_filled);
    try writeRefList(w, ",\"unresolved\":", diag.unresolved);
    try w.writeAll(",\"current\":");
    try writeScoreObj(w, alloc, current, route);
    try w.print(",\"delta_objective\":{d:.1}}}", .{proposed.breakdown.objective - current.breakdown.objective});
}

fn writeScoreObj(w: *std.Io.Writer, alloc: std.mem.Allocator, p: optimizer.Placement, route: bool) BuildError!void {
    const b = p.breakdown;
    try w.print("{{\"objective\":{d:.1},\"hpwl\":{d:.1},\"loop_nh\":{d:.1}", .{ b.objective, b.hpwl, b.loop_nh });
    if (route) {
        const rp = pcb_router.RouteParams{};
        if (pcb_router.route(alloc, p, rp) catch null) |r| {
            var trace: f64 = 0;
            for (r.tracks) |t| trace += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
            const v = drc.check(alloc, p, r, rp.clearance) catch &.{};
            try w.print(",\"routed\":{{\"trace_mm\":{d:.1},\"vias\":{d},\"drc\":{d}}}", .{ trace, r.vias.len, v.len });
        }
    }
    try w.writeAll("}");
}

fn writeRefList(w: *std.Io.Writer, key: []const u8, refs: []const []const u8) BuildError!void {
    try w.writeAll(key);
    try w.writeAll("[");
    for (refs, 0..) |r, i| {
        if (i > 0) try w.writeAll(",");
        try pcb_layout_page.writeJsonStr(w, r);
    }
    try w.writeAll("]");
}

/// The exported spec text plus its JSON wrapper; an empty `sexp` means the
/// board has no hub IC to anchor a spec on.
pub const ExportedSpec = struct { json: []const u8, sexp: []const u8 };

/// Errors of the spec builder: scratch allocation + text assembly.
pub const BuildError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// Solve (or load) the placement exactly as the PNG endpoint would and render
/// it as a `(placement …)` spec. Bytes are owned by `alloc` (callers pass an
/// arena) — the spec text copies every name, so it outlives the evaluator.
pub fn exportSpec(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    opts: pcb_layout_page.PngRequest,
) pcb_layout_page.PngError!ExportedSpec {
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = try pcb_layout_page.solveForRequest(alloc, project_dir, name, opts, &eval, &module_res);
    const sexp = buildSpecSexp(alloc, solved.placement, solved.spec_status) catch return error.BuildFailed;
    if (sexp == null) return .{ .json = "", .sexp = "" };

    const source: []const u8 = if (opts.layout) |ln|
        std.fmt.allocPrint(alloc, "saved:{s}", .{ln}) catch return error.BuildFailed
    else if (solved.spec_status != null)
        "spec"
    else if (opts.regen)
        "regen"
    else
        "auto";
    var aw: std.Io.Writer.Allocating = .init(alloc);
    writeSpecJson(&aw.writer, alloc, solved.placement, solved.spec_status, sexp.?, source, name, solved.title) catch
        return error.BuildFailed;
    return .{ .json = aw.written(), .sexp = sexp.? };
}

/// JSON wrapper around the spec text: where the layout came from, the anchor's
/// names, and any parts skipped because the source solve left them staged.
/// Skipped parts are named in the same vocabulary the spec text uses.
fn writeSpecJson(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    p: optimizer.Placement,
    spec: ?render_pcb_png.SpecStatus,
    sexp: []const u8,
    source: []const u8,
    name: []const u8,
    title: []const u8,
) BuildError!void {
    const use_origin = try computeUseOrigin(alloc, p);
    defer alloc.free(use_origin);
    try w.writeAll(NAME_OPEN);
    try pcb_layout_page.writeJsonStr(w, name);
    try w.writeAll(",\"title\":");
    try pcb_layout_page.writeJsonStr(w, title);
    try w.writeAll(",\"source\":");
    try pcb_layout_page.writeJsonStr(w, source);
    if (pcb_describe.anchorIndex(p.parts)) |ai| {
        try w.writeAll(",\"anchor\":{\"ref\":");
        try pcb_layout_page.writeJsonStr(w, p.parts[ai].ref_des);
        try w.writeAll(",\"origin\":");
        try pcb_layout_page.writeJsonStr(w, pcb_describe.originOf(p, ai));
        try w.writeAll("}");
    }
    try w.writeAll(",\"spec\":");
    try pcb_layout_page.writeJsonStr(w, sexp);
    try w.writeAll(",\"skipped\":[");
    if (spec) |sp| {
        for (sp.unplaced, 0..) |ref, i| {
            if (i > 0) try w.writeAll(",");
            try pcb_layout_page.writeJsonStr(w, specNameForRef(p, use_origin, ref));
        }
    }
    try w.writeAll("]}");
}

/// Which `(placement …)` side keyword a part belongs to — the optimizer's dock
/// `Edge`, whose tag names ARE the spec's side words (no `center`: a part
/// overlapping the anchor is forced onto its dominant axis).
const SideTag = optimizer.Edge;

/// One exported part: geometry relative to the anchor, used to reconstruct
/// side, depth lane, and along-edge order.
const Entry = struct { idx: usize, depth: f64, along: f64, lane: usize = 0 };

/// Depth jump (mm) that starts a new lane when clustering a side's parts.
/// Packed lanes have flush inner edges, so same-lane drift stays well under
/// this while the next lane sits at least a part-depth + gap further out.
const LANE_EPS_MM: f64 = 0.75;

/// Render `p` as an editable `(placement …)` s-expression: anchor = largest
/// hub, every placed part listed on its side of the anchor (inner lane first,
/// then along the edge — the order `packSpec` reproduces), `(rot …)` only
/// where the actual rotation differs from the solver's default for that side.
/// Null when the board has no hub to anchor on.
pub fn buildSpecSexp(
    alloc: std.mem.Allocator,
    p: optimizer.Placement,
    spec: ?render_pcb_png.SpecStatus,
) BuildError!?[]u8 {
    const anchor = pcb_describe.anchorIndex(p.parts) orelse return null;
    var skip = std.StringHashMap(void).init(alloc);
    defer skip.deinit();
    if (spec) |sp| for (sp.unplaced) |ref| try skip.put(ref, {});
    const use_origin = try computeUseOrigin(alloc, p);
    defer alloc.free(use_origin);

    var sides: [4]std.ArrayListUnmanaged(Entry) = .{ .empty, .empty, .empty, .empty };
    defer for (&sides) |*s| s.deinit(alloc);
    const a = p.parts[anchor];
    const ah = pcb_describe.aabbHalf(a);
    for (p.parts, 0..) |part, pi| {
        if (pi == anchor) continue;
        if (skip.contains(part.ref_des)) continue;
        const bh = pcb_describe.aabbHalf(part);
        const dx = part.x - a.x;
        const dy = part.y - a.y;
        const nx = dx / @max(ah[0] + bh[0], 0.001);
        const ny = dy / @max(ah[1] + bh[1], 0.001);
        const horizontal = @abs(nx) >= @abs(ny);
        const tag: SideTag = if (horizontal)
            (if (nx < 0) SideTag.left else SideTag.right)
        else
            (if (ny < 0) SideTag.top else SideTag.bottom);
        try sides[@intFromEnum(tag)].append(alloc, .{
            .idx = pi,
            .depth = if (horizontal) @abs(dx) - (ah[0] + bh[0]) else @abs(dy) - (ah[1] + bh[1]),
            .along = if (horizontal) dy else dx,
        });
    }

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.writeAll("(placement (anchor ");
    try writeName(w, p, use_origin, anchor);
    try w.writeAll(")");
    for (&sides, 0..) |*list, si| {
        if (list.items.len == 0) continue;
        assignLanes(list.items);
        std.mem.sort(Entry, list.items, {}, entryLess);
        const tag: SideTag = @enumFromInt(si);
        try w.print("\n  ({s}", .{@tagName(tag)});
        for (list.items) |e| {
            try w.writeAll(" ");
            try writeItem(w, p, use_origin, e.idx, tag);
        }
        try w.writeAll(")");
    }
    // Copper-side clause: list every back-layer (B.Cu) part so the round-trip
    // preserves which parts the author put on the back. Orthogonal to the side
    // blocks above (a back part still appears in its anchor-side list too).
    var any_back = false;
    for (p.parts, 0..) |part, pi| {
        if (pi == anchor) continue;
        if (skip.contains(part.ref_des)) continue;
        if (part.side != .bottom) continue;
        try w.writeAll(if (any_back) " " else "\n  (back-side ");
        any_back = true;
        try writeName(w, p, use_origin, pi);
    }
    if (any_back) try w.writeAll(")");
    try w.writeAll(")\n");
    return aw.written();
}

/// Cluster a side's parts into depth lanes: sort by inner-edge clearance and
/// start a new lane on each jump bigger than `LANE_EPS_MM`. Lane 0 (nearest
/// the IC) lists first, matching `packSpec`'s lane-wrap of the listed order.
fn assignLanes(items: []Entry) void {
    std.mem.sort(Entry, items, {}, depthLess);
    var lane: usize = 0;
    var cluster_start: f64 = if (items.len > 0) items[0].depth else 0;
    for (items) |*e| {
        if (e.depth - cluster_start > LANE_EPS_MM) {
            lane += 1;
            cluster_start = e.depth;
        }
        e.lane = lane;
    }
}

fn depthLess(_: void, x: Entry, y: Entry) bool {
    return x.depth < y.depth;
}

fn entryLess(_: void, x: Entry, y: Entry) bool {
    if (x.lane != y.lane) return x.lane < y.lane;
    return x.along < y.along;
}

/// Emit one side item: `"NAME"`, or `(rot N "NAME")` when the part's actual
/// rotation differs from what the solver would pick by default on that side
/// (power pad faced toward the IC for loop caps, 0 otherwise).
fn writeItem(
    w: *std.Io.Writer,
    p: optimizer.Placement,
    use_origin: []const bool,
    pi: usize,
    tag: SideTag,
) BuildError!void {
    const act = normRot(p.parts[pi].rot);
    if (rotsDiffer(act, defaultRot(p, pi, tag))) {
        try w.print("(rot {d:.0} ", .{act});
        try writeName(w, p, use_origin, pi);
        try w.writeAll(")");
        return;
    }
    try writeName(w, p, use_origin, pi);
}

/// The rotation `packSpecBlock` would apply with no `(rot …)` override: face
/// a loop cap's power pad toward the IC, leave everything else at 0.
fn defaultRot(p: optimizer.Placement, pi: usize, tag: SideTag) f64 {
    for (p.loops) |lp| {
        if (lp.cap == pi) return optimizer.faceRotation(lp.cap_pwr, tag);
    }
    return 0;
}

fn normRot(r: f64) f64 {
    return @mod(r, 360.0);
}

fn rotsDiffer(x: f64, y: f64) bool {
    const d = @abs(normRot(x) - normRot(y));
    return d > 0.5 and d < 359.5;
}

/// True per part when its module-local origin name is unique across the design
/// — specs prefer the stable origin vocabulary, but a module instantiated
/// twice repeats its origin keys, so ambiguous names fall back to the ref-des.
fn computeUseOrigin(alloc: std.mem.Allocator, p: optimizer.Placement) std.mem.Allocator.Error![]bool {
    var counts = std.StringHashMap(usize).init(alloc);
    defer counts.deinit();
    for (p.instances) |inst| {
        if (inst.origin_key.len == 0) continue;
        const g = try counts.getOrPut(inst.origin_key);
        if (g.found_existing) g.value_ptr.* += 1 else g.value_ptr.* = 1;
    }
    const out = try alloc.alloc(bool, p.parts.len);
    for (out, 0..) |*b, i| {
        b.* = i < p.instances.len and p.instances[i].origin_key.len > 0 and
            (counts.get(p.instances[i].origin_key) orelse 0) == 1;
    }
    return out;
}

fn writeName(w: *std.Io.Writer, p: optimizer.Placement, use_origin: []const bool, pi: usize) BuildError!void {
    const nm = if (pi < use_origin.len and use_origin[pi]) p.instances[pi].origin_key else p.parts[pi].ref_des;
    try w.print("\"{s}\"", .{nm});
}

/// The spec name for a diag ref-des (diag lists carry ref-des, the spec
/// speaks origin names where unique) — unknown refs pass through unchanged.
fn specNameForRef(p: optimizer.Placement, use_origin: []const bool, ref: []const u8) []const u8 {
    for (p.parts, 0..) |part, pi| {
        if (!std.mem.eql(u8, part.ref_des, ref)) continue;
        return if (pi < use_origin.len and use_origin[pi]) p.instances[pi].origin_key else ref;
    }
    return ref;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const export_kicad = @import("../export_kicad.zig");
const geometry = @import("../placement/geometry.zig");

// spec: Web Server - Placement-spec export rebuilds an editable (placement …) form from a solved layout
test "buildSpecSexp lists sides inner-lane-first with rot overrides" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var pads = [_]geometry.Pad{
        .{ .number = "1", .x = -1.8, .y = 0, .w = 0.6, .h = 0.6 },
        .{ .number = "2", .x = 1.8, .y = 0, .w = 0.6, .h = 0.6 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        // Outer-lane bulk cap listed AFTER the inner cap despite array order.
        .{ .ref_des = "C2", .kind = .passive, .hw = 1, .hh = 0.6, .pads = &pads, .fallback = false, .x = -7.5, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 0.6, .pads = &pads, .fallback = false, .x = -3.3, .y = 0 },
        // Rotated part with no loop: default 0, so the override is emitted.
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.6, .hh = 0.4, .pads = &pads, .fallback = false, .x = 3.1, .y = 0.2, .rot = 90 },
        // Top side, along-edge order: smaller x lists first.
        .{ .ref_des = "C3", .kind = .passive, .hw = 0.6, .hh = 0.4, .pads = &pads, .fallback = false, .x = 1, .y = -3 },
        .{ .ref_des = "C4", .kind = .passive, .hw = 0.6, .hh = 0.4, .pads = &pads, .fallback = false, .x = -1, .y = -3 },
    };
    const instances = [_]export_kicad.FlatInstance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "U1" },
        .{ .ref_des = "C2", .component = "cap", .value = "", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "C_BULK" },
        .{ .ref_des = "C1", .component = "cap", .value = "", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "C_IN" },
        .{ .ref_des = "R1", .component = "res", .value = "", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "R_FB" },
        .{ .ref_des = "C3", .component = "cap", .value = "", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "C_B2" },
        .{ .ref_des = "C4", .component = "cap", .value = "", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "C_B1" },
    };
    const p = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &instances,
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -9,
        .miny = -4,
        .maxx = 4,
        .maxy = 4,
        .generated = true,
    };
    const sexp = (try buildSpecSexp(alloc, p, null)).?;
    try std.testing.expect(std.mem.indexOf(u8, sexp, "(anchor \"U1\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, sexp, "(left \"C_IN\" \"C_BULK\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, sexp, "(right (rot 90 \"R_FB\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, sexp, "(top \"C_B1\" \"C_B2\")") != null);
}

// spec: Web Server - Placement-spec export falls back to ref-des when origin names repeat
test "buildSpecSexp falls back to ref-des on duplicate origin keys" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &.{}, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "a/C1", .kind = .passive, .hw = 1, .hh = 0.6, .pads = &.{}, .fallback = false, .x = -3.3, .y = 0 },
        .{ .ref_des = "b/C2", .kind = .passive, .hw = 1, .hh = 0.6, .pads = &.{}, .fallback = false, .x = 3.3, .y = 0 },
    };
    const instances = [_]export_kicad.FlatInstance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "U1" },
        .{ .ref_des = "a/C1", .component = "cap", .value = "", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "C_IN" },
        .{ .ref_des = "b/C2", .component = "cap", .value = "", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "C_IN" },
    };
    const p = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &instances,
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -5,
        .miny = -3,
        .maxx = 5,
        .maxy = 3,
        .generated = true,
    };
    const sexp = (try buildSpecSexp(alloc, p, null)).?;
    try std.testing.expect(std.mem.indexOf(u8, sexp, "(left \"a/C1\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, sexp, "(right \"b/C2\")") != null);
}

// spec: Web Server - spec save replaces an existing placement form in place
test "splicePlacementForm replaces the existing placement form" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const src =
        "(design-block \"Demo\"\n" ++
        "  (note \"VOUT (max 16V) - parens in a string\")\n" ++
        "  (placement (anchor \"U1\")\n    (left \"C1\"))\n" ++
        "  (instance \"U1\" buck))\n";
    const out = (try splicePlacementForm(alloc, src, "(placement (anchor \"U1\") (right \"C1\"))", "(placement")).?;
    try std.testing.expect(std.mem.indexOf(u8, out, "(right \"C1\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(left \"C1\")") == null);
    // The rest of the design is untouched.
    try std.testing.expect(std.mem.indexOf(u8, out, "(note \"VOUT (max 16V) - parens in a string\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(instance \"U1\" buck)") != null);
}

// spec: Web Server - spec save inserts a new placement form before the design-block close
test "splicePlacementForm inserts before the design-block closing paren" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const src =
        "(import buck)\n" ++
        "(design-block \"Demo\"\n" ++
        "  ; a comment with (placement inside it stays a comment\n" ++
        "  (placement-order (\"C1\"))\n" ++
        "  (instance \"U1\" buck))\n";
    const out = (try splicePlacementForm(alloc, src, "(placement (anchor \"U1\"))", "(placement")).?;
    // Inserted inside the design-block, not after it; placement-order untouched.
    try std.testing.expect(std.mem.indexOf(u8, out, "(placement (anchor \"U1\"))\n)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(placement-order (\"C1\"))") != null);
    // No design-block at all -> null.
    try std.testing.expect((try splicePlacementForm(alloc, "(import buck)\n", "(placement)", "(placement")) == null);
}

// spec: Web Server - flip-side sets the (back-side …) clause, preserving the rest of the form
test "setBackSideClause inserts, replaces, and clears the back-side clause" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const two = [_][]const u8{ "C1", "C2" };
    const one = [_][]const u8{"C9"};
    const none: []const []const u8 = &.{};

    // 1. No placement form: insert an anchor-less (placement (back-side …)) and
    //    KEEP the design-block's closing paren (the splice bug regression guard).
    const src1 = "(import buck)\n(design-block \"Demo\"\n  (instance \"U1\" buck))\n";
    const o1 = (try setBackSideClause(alloc, src1, &two)).?;
    try std.testing.expect(std.mem.indexOf(u8, o1, "(placement (back-side \"C1\" \"C2\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, o1, "(instance \"U1\" buck)") != null);
    try std.testing.expectEqual(std.mem.count(u8, o1, "("), std.mem.count(u8, o1, ")"));

    // 2. Existing placement form, no back-side clause: add one, keep the sides.
    const src2 = "(design-block \"Demo\"\n  (placement (anchor \"U1\") (left \"C1\"))\n  (instance \"U1\" buck))\n";
    const o2 = (try setBackSideClause(alloc, src2, &two)).?;
    try std.testing.expect(std.mem.indexOf(u8, o2, "(anchor \"U1\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, o2, "(back-side \"C1\" \"C2\")") != null);
    try std.testing.expectEqual(std.mem.count(u8, o2, "("), std.mem.count(u8, o2, ")"));

    // 3. Existing back-side clause: replace it wholesale.
    const o3 = (try setBackSideClause(alloc, o2, &one)).?;
    try std.testing.expect(std.mem.indexOf(u8, o3, "(back-side \"C9\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, o3, "\"C2\"") == null);

    // 4. Empty refs: drop the clause; the form still balances.
    const o4 = (try setBackSideClause(alloc, o3, none)).?;
    try std.testing.expect(std.mem.indexOf(u8, o4, "back-side") == null);
    try std.testing.expectEqual(std.mem.count(u8, o4, "("), std.mem.count(u8, o4, ")"));
}

// spec: Web Server - propose_placement parses a standalone placement/floorplan form
test "parsePlacementText parses standalone placement and floorplan forms" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    const pp = (try design_block.parsePlacementText(&eval, "(placement (anchor \"U1\") (left \"C1\"))")).?;
    try std.testing.expect(!pp.floorplan);
    try std.testing.expect(pp.spec.present);
    try std.testing.expectEqualStrings("U1", pp.spec.anchor);
    const fp = (try design_block.parsePlacementText(&eval, "(floorplan (anchor \"buck\") (right \"ldo\"))")).?;
    try std.testing.expect(fp.floorplan);
    try std.testing.expectEqualStrings("buck", fp.spec.anchor);
    try std.testing.expect((try design_block.parsePlacementText(&eval, "(note \"hi\")")) == null);
}

// spec: Web Server - spec save splices the placement form into a defmodule body
test "splicePlacementForm targets the design-block inside a defmodule" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const src =
        "(defmodule buck ((vin 12.0))\n" ++
        "  \"12V buck module\"\n" ++
        "  (design-block \"Buck\"\n" ++
        "    (instance \"U1\" chip)))\n";
    const out = (try splicePlacementForm(alloc, src, "(placement (anchor \"U1\"))", "(placement")).?;
    // Inserted before the design-block close — i.e. inside the defmodule,
    // after the last instance, with both closing parens still behind it.
    const at = std.mem.indexOf(u8, out, "(placement (anchor \"U1\"))") orelse return error.TestSpliceMissing;
    const inst = std.mem.indexOf(u8, out, "(instance \"U1\" chip)") orelse return error.TestSpliceMissing;
    try std.testing.expect(at > inst);
    // Both the design-block's and the defmodule's closing parens follow the
    // spliced spec — it landed inside the module body, not after it.
    try std.testing.expect(std.mem.indexOf(u8, out[at..], "\n))") != null);
}
