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
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const modules_mod = @import("modules.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const pcb_describe = @import("pcb_describe.zig");
const render_pcb_png = @import("../render_pcb_png.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

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
    try w.writeAll("{\"name\":");
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
