//! `GET /api/thermal/:name` — the lumped thermal screening as read-only facts
//! JSON, and the `describe_thermal` CLI tool that answers with the same bytes.
//!
//! The analysis itself lives in `eval/thermal.zig` and its serialization in
//! `review_thermal.zig`; this module is only the resolve-and-answer seam. Both
//! surfaces run through one `thermalJson` body — the pattern
//! `serve/route_analyze_api.zig` uses for `diagnose_net` — so an agent reading
//! the tool and a browser reading the endpoint can never be told different
//! junction temperatures for the same design and ambient.
//!
//! `:name` resolves as a design or as a bare `lib/modules` module (instantiated
//! standalone through its parameter defaults), the same resolution every other
//! read surface uses. Read-only: nothing here writes to the project dir, and
//! the analysis allocates only into the caller's arena.
//!
//! `?layout=` (and the tool's `layout` arg) screens one NAMED saved layout
//! instead of the design's default board. Two layouts of one design place the
//! same parts differently and stitch different vias under them, so they are two
//! different boards thermally — which is the whole point of comparing them.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const log = @import("../infra/log.zig");
const json_writer = @import("../json_writer.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const review_thermal = @import("../review_thermal.zig");
const thermal = @import("../eval/thermal.zig");
const thermal_cache = @import("thermal_cache.zig");
const mcp_tools = @import("mcp_tools.zig");
const modules_mod = @import("modules.zig");
const page_cache = @import("page_cache.zig");
const paths = @import("../paths.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const serve_root = @import("../serve.zig");
const thermal_scenarios = @import("../thermal_scenarios.zig");
const urlcodec = @import("urlcodec.zig");
const Server = serve_root.Server;

/// Error set for the handler. Only allocation escapes to httpz; every other
/// failure is answered as a status plus a plain-text body.
pub const HandlerError = std.mem.Allocator.Error;

const http_bad_request: u16 = 400;
const http_not_found: u16 = 404;
const http_internal_error: u16 = 500;

const err_not_found = "No design or module by that name\n";
const err_ambient = "ambient must be a number in degrees Celsius\n";
const err_analyze = "Thermal analysis failed\n";

/// Failures of one `thermalJson` call: `evalNamedBlock`'s resolution errors
/// plus whatever the analysis allocates.
pub const ThermalError = mcp_tools.ToolError || std.mem.Allocator.Error || std.Io.Writer.Error;

/// Resolve `name` as a design or a standalone module, screen it at `ambient_c`
/// (bench ambient when null) over `layout` (the design's default board when
/// null), and return the facts object as JSON bytes owned by `alloc`.
///
/// This is the WHOLE body both surfaces share — the HTTP endpoint below and the
/// `describe_thermal` CLI tool — so neither can describe a different board, or
/// a different ambient, than the other for the same request.
///
/// `deps`, when non-null, receives the file dependency set of this computation
/// (see `captureDeps`) so the caller can retain the body against it. The
/// capture happens while the evaluator is still alive and before any early
/// error return, so a cache never keys on a half-built read-set.
pub fn thermalJson(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    ambient_c: ?f64,
    layout: ?[]const u8,
    deps: ?*?page_cache.FileSet,
) ThermalError![]const u8 {
    // `eval` owns the arena the block borrows, so it outlives the analysis.
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    defer if (deps) |out| {
        out.* = captureDeps(alloc, &eval, project_dir, name);
    };
    const nb = try mcp_tools.evalNamedBlock(alloc, project_dir, name, &eval);

    const ambient = ambient_c orelse thermal.default_ambient_c;
    const result = try thermal.analyze(alloc, nb.block, ambient);
    const scenarios = try scenariosFor(alloc, project_dir, name, result, ambient, layout);
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try review_thermal.writeFactsJson(&aw.writer, result, scenarios);
    return aw.written();
}

/// The file dependency set of one thermal answer: everything the evaluator read
/// (design, checks, every transitively imported `lib/` file, plus the `.bom` /
/// `.refdes.json` / `.notes.md` siblings `page_cache` always stamps) and the two
/// placement sidecars the solve resolves its board from.
///
/// It is deliberately the pair `serve/thermal_cache.zig` stamps for the solved
/// FIELD: a thermal page, its facts JSON and its cached solve must go stale on
/// exactly the same edits, or a retained page would outlive the field it
/// reports. Null when nothing could be stamped, which a caller must treat as
/// "not cacheable" — a set that stamps no file can never go stale.
pub fn captureDeps(
    scratch: std.mem.Allocator,
    eval: *const Evaluator,
    project_dir: []const u8,
    name: []const u8,
) ?page_cache.FileSet {
    const layouts = paths.designSiblingPath(scratch, project_dir, name, ".layouts.json") catch return null;
    defer scratch.free(layouts);
    const legacy = paths.designSiblingPath(scratch, project_dir, name, ".autolayout.json") catch return null;
    defer scratch.free(legacy);
    return page_cache.captureWithExtras(scratch, eval, project_dir, name, &.{ layouts, legacy }) catch null;
}

/// Said when the lumped screen found nothing that dissipates: a field with no
/// source is a board at ambient everywhere, and solving four of them would
/// dress that up as an analysis.
const nothing_to_spread =
    "No part declares a dissipation, so there is no heat to spread over the board. " ++
    "Add `(power W)` or `(i-typ A)` pin currents to see the cooling scenarios.";
/// Said when the design resolves but no placement could be built for it.
const no_placement =
    "Cooling scenarios need a board layout, and this design has no placement to solve over.";
/// Said when a placement resolved but put nothing on the board.
const no_parts =
    "The resolved layout places no parts, so there is no board for the heat to spread over.";
/// Said when the caller named a saved layout this design does not have. Not
/// silently degraded to the default board: reporting one board's temperatures
/// under another layout's name is the exact confusion a comparison invites.
const no_layout =
    "This design has no saved layout by that name, so there is no board to spread the heat over.";

fn derivedCacheAllowed() bool {
    return !infra_fs.hasActiveReadTrace();
}

/// The layout-aware cooling-scenario ladder for `name` at `ambient_c`, or the
/// reason there is none.
///
/// A design that has never been placed is a NORMAL answer, not an error: the
/// caller still gets the whole lumped screen, plus a sentence saying what is
/// missing. So every failure below degrades to an `unavailable` reason and only
/// an allocation failure escapes.
///
/// With `layout` null the placement is selected by `solveForRequest`'s own
/// default ladder — the starred (★) saved layout, else the auto cache, else a
/// plain grid — which is exactly the board `/pcb-layout` and `/api/pcb-describe`
/// show, so the temperatures describe the board a reader is looking at. A named
/// `layout` renders that saved layout verbatim instead, with ITS copper, which
/// is how two layouts of one design are compared. Screening a design with
/// nothing to dissipate skips that solve entirely: it is the expensive half of
/// this endpoint and its answer would be a field of zeros.
///
/// The solve itself comes from `solveFor` below, which caches it; this function
/// is only the ambient arithmetic on top.
pub fn scenariosFor(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    bt: thermal.BoardThermal,
    ambient_c: f64,
    layout: ?[]const u8,
) std.mem.Allocator.Error!thermal_scenarios.Answer {
    const solved = try solveFor(alloc, project_dir, name, bt, layout);
    const results = solved.results orelse return .{ .unavailable = solved.unavailable };
    return .{ .ladder = try thermal_scenarios.ladderAt(alloc, results, ambient_c) };
}

/// One design's solved cooling scenarios as the solver produced them — rises
/// above ambient, with no ambient applied — or the reason there are none.
pub const Solved = struct {
    /// One result per scenario, in `thermal_scenarios.Scenario` order. Null when
    /// there was nothing to solve; `unavailable` then says why.
    results: ?[]const thermal_scenarios.ScenarioResult = null,
    unavailable: []const u8 = "",
};

/// `solveForRequest` hands back the evaluator it spun up for a sub-module
/// design, or nothing for a plain one; a caller drops it here so releasing it
/// is one call rather than a branch at every use.
fn dropModule(alloc: std.mem.Allocator, res: ?modules_mod.ResolvedBlock) void {
    const mr = res orelse return;
    mr.eval.deinit();
    alloc.destroy(mr.eval);
}

/// Solve (or recall) the ambient-free scenario fields for `name`.
///
/// This is the expensive half of every thermal surface — resolving the board's
/// placement out of a possibly multi-megabyte layout sidecar, then relaxing four
/// steady-state spreader fields over it — so it is cached whole, in
/// `serve/thermal_cache.zig`, against the evaluator read-set, the placement
/// sidecars and the design's live-edit version. A board that has not changed is
/// solved once however many pages, images, documents and ambients read it.
///
/// Caching the RISE fields rather than a ladder is what makes the ambient free:
/// `thermal_scenarios.ladderAt` is the only place an ambient is ever added, so
/// re-screening at a different ambient is arithmetic over a cached field.
///
/// `layout` names a saved layout to solve over, or is null for the design's
/// default board. A name this design does not have is answered with the
/// `no_layout` sentence rather than quietly falling back — checked only on a
/// cache MISS, since a hit was cached under a name that existed at the time and
/// any sidecar write invalidates the entry.
///
/// Only successful solves are retained. A design with no placement is a normal
/// answer, not an error, and cheap enough to re-derive.
pub fn solveFor(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    bt: thermal.BoardThermal,
    layout: ?[]const u8,
) std.mem.Allocator.Error!Solved {
    if (bt.counts.with_power == 0) return .{ .unavailable = nothing_to_spread };

    const cache = thermal_cache.active();
    // Read BEFORE the solve: a design edited while the fields relax must not be
    // cached under the version it started at.
    const version = serve_root.getLiveVersion(name);
    const key: thermal_cache.Key = .{
        .project_dir = project_dir,
        .name = name,
        .live_version = version,
        .layout = layout orelse "",
    };
    if (derivedCacheAllowed()) {
        if (cache) |store| {
            // Checked HERE and not just in `solveOver`, because a hit has to skip
            // the placement resolve too — that sidecar parse is half the cost.
            if (store.get(alloc, key)) |hit| return .{ .results = hit };
        }
    }
    // A misspelled layout would otherwise fall through to a FRESH optimizer
    // solve — the most expensive thing this process does — and answer for a
    // board nobody saved. Cost is one sidecar parse, on the miss path only.
    if (layout) |want| {
        if (!pcb_layout_page.hasSavedLayout(alloc, project_dir, name, want)) {
            return .{ .unavailable = no_layout };
        }
    }

    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer dropModule(alloc, module_res);
    const opts: pcb_layout_page.PngRequest = .{ .layout = layout };
    const solved = pcb_layout_page.solveForRequest(alloc, project_dir, name, opts, &eval, &module_res) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .unavailable = no_placement },
    };
    if (solved.placement.parts.len == 0) return .{ .unavailable = no_parts };

    return .{ .results = try solveOver(alloc, &eval, project_dir, name, bt, boardOf(solved, layout, bt)) };
}

/// The board one solve is over: the resolved placement, and the copper standing
/// on it. Bundled because the thermal projection now reads both — the pours
/// derate the spreading and the vias shorten each part's transfer path — and
/// because splitting them would put this function over the parameter budget.
pub const Board = struct {
    placement: thermal_scenarios.Placement,
    copper: thermal_scenarios.Copper = .{},
    heatsink: ?thermal_scenarios.Heatsink = null,
    /// Which saved layout this board IS — null for the design's default board.
    /// Carried with the geometry rather than passed alongside it so a caller
    /// cannot cache one layout's field under another's name.
    layout: ?[]const u8 = null,
};

/// The board a solved request describes. `layout` must be the `?layout=` the
/// request was solved with (null for the default board) — it is the half of the
/// cache key the geometry cannot supply.
pub fn boardOf(solved: pcb_layout_page.SolvedRequest, layout: ?[]const u8, bt: thermal.BoardThermal) Board {
    return .{
        .placement = solved.placement,
        .copper = pcb_layout_page.thermalCopper(solved),
        .heatsink = pcb_layout_page.thermalHeatsink(solved, bt),
        .layout = layout,
    };
}

/// The same cached solve, over a placement the caller has ALREADY resolved.
///
/// The heat-zone PNG path is the caller: it resolves the board anyway (it has to
/// draw it), so going through `solveFor` would resolve it twice. Sharing the
/// cache entry is the point — the page, its facts JSON and its image are one
/// solve, so an image can never show a field the numbers disagree with.
///
/// `eval` must be the evaluator that resolved `placement`: its read-set is what
/// the cache entry is validated against. Passing an unrelated evaluator would
/// cache the answer against the wrong design's files.
pub fn solveOver(
    alloc: std.mem.Allocator,
    eval: *const Evaluator,
    project_dir: []const u8,
    name: []const u8,
    bt: thermal.BoardThermal,
    board: Board,
) std.mem.Allocator.Error![]const thermal_scenarios.ScenarioResult {
    const version = serve_root.getLiveVersion(name);
    const key: thermal_cache.Key = .{
        .project_dir = project_dir,
        .name = name,
        .live_version = version,
        .layout = board.layout orelse "",
    };
    if (derivedCacheAllowed()) {
        if (thermal_cache.active()) |store| {
            if (store.get(alloc, key)) |hit| return hit;
        }
    }
    const results = try thermal_scenarios.solveFieldsWithHeatsink(alloc, bt, board.placement, board.copper, board.heatsink);
    if (derivedCacheAllowed()) {
        if (thermal_cache.active()) |store| {
            // Re-read: a design edited WHILE the fields relaxed would otherwise be
            // cached under the version it started at, and stay wrong until the next
            // edit bumped it again.
            if (serve_root.getLiveVersion(name) == version) store.put(alloc, eval, key, results);
        }
    }
    return results;
}

test "thermal derived caches are disabled while exact read tracing is active" {
    try std.testing.expect(derivedCacheAllowed());
    var trace = infra_fs.ReadTrace.init(std.testing.allocator);
    defer trace.deinit();
    trace.begin();
    defer trace.end();
    try std.testing.expect(!derivedCacheAllowed());
}

/// GET /api/thermal/:name[?ambient=NN][&layout=NAME] — the thermal facts for a
/// design or a bare `lib/modules` module, over its default board or the named
/// saved layout. `:name` is percent-decoded before any lookup (httpz hands path
/// params over verbatim). Unknown name → 404, unparseable ambient → 400, both
/// with a plain-text body that never reads as JSON; a layout the design does
/// not have is a 200 whose scenarios say so, the same shape as a design that
/// has no placement at all.
pub fn thermalApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name_raw = req.param("name") orelse return plainError(res, http_not_found, err_not_found);
    const name = try urlcodec.decodeAlloc(ctx.allocator, name_raw);

    const ambient = ambientFromQuery(req) catch return plainError(res, http_bad_request, err_ambient);

    // Read the live version BEFORE computing, so a design edit that lands
    // mid-request is treated as a miss next time instead of being baked in.
    const live_version = serve_root.getLiveVersion(name);
    var miss_version: ?u32 = null;
    if (ctx.state.caches.reads.thermal_facts.serve(.{
        .scratch = ctx.allocator,
        .req = req,
        .res = res,
        .name = name,
        .live_version = live_version,
    }, &miss_version)) {
        res.content_type = .JSON;
        return;
    }

    var deps: ?page_cache.FileSet = null;
    const body = thermalJson(ctx.allocator, ctx.project_dir, name, ambient, layoutFromQuery(req), &deps) catch |e| {
        if (deps) |d| d.deinit();
        switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound, error.NotADesign, error.InvalidName => {
                return plainError(res, http_not_found, err_not_found);
            },
            else => {
                log.warn("thermal {s} failed: {s}", .{ name, @errorName(e) });
                return plainError(res, http_internal_error, err_analyze);
            },
        }
    };
    res.content_type = .JSON;
    res.body = body;
    ctx.state.caches.reads.thermal_facts.store(.{
        .scratch = ctx.allocator,
        .req = req,
        .res = res,
        .name = name,
        .body = body,
        .files = deps,
        .live_version = miss_version,
        .current_version = serve_root.getLiveVersion(name),
    });
}

/// GET /api/thermal-field/:name[?scenario=<tag>][&ambient=NN][&layout=NAME] — one solved
/// cooling scenario as a GRID, in board millimetres, for the thermal page's
/// board overlay to paint on the live PCB view.
///
/// `/api/thermal/:name` remains the authority on what the board does; this is
/// the same solve expressed as the field it came from, so a picture can never
/// show a scenario the numbers do not. Per-part rows carry only the ref-des and
/// its temperatures: the overlay runs inside the real PCB viewer and reads each
/// part's POSE from that page's own blob, so nothing here re-states geometry
/// the board is already drawing.
///
/// An unknown name is a 404; a design with no ladder answers 200 with
/// `available:false` and the sentence saying why, because "this board has no
/// layout yet" is an answer and not a failure.
pub fn thermalFieldApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const alloc = ctx.allocator;
    const name_raw = req.param("name") orelse return plainError(res, http_not_found, err_not_found);
    const name = try urlcodec.decodeAlloc(alloc, name_raw);
    const ambient_opt = ambientFromQuery(req) catch return plainError(res, http_bad_request, err_ambient);
    const ambient = ambient_opt orelse thermal.default_ambient_c;

    var eval = Evaluator.init(alloc, ctx.project_dir);
    defer eval.deinit();
    const nb = mcp_tools.evalNamedBlock(alloc, ctx.project_dir, name, &eval) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return plainError(res, http_not_found, err_not_found),
    };
    const bt = try thermal.analyze(alloc, nb.block, ambient);
    const solved = try solveFor(alloc, ctx.project_dir, name, bt, layoutFromQuery(req));

    const q = req.query() catch null;
    const want = pcb_layout_page.parseScenario(if (q) |qq| qq.get("scenario") else null) orelse .natural;

    var aw: std.Io.Writer.Allocating = .init(alloc);
    writeFieldJson(&aw.writer, name, ambient, want, solved) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.warn("thermal field {s} failed: {s}", .{ name, @errorName(e) });
            return plainError(res, http_internal_error, err_analyze);
        },
    };
    res.content_type = .JSON;
    res.body = aw.written();
}

/// The field object. `rise_c` and `active` are row-major over `cols × rows`;
/// each rise is ABOVE ambient and each active byte says whether that lattice
/// cell belongs to the exact PCB outline. A client adds `ambient_c` only for an
/// active cell, so neither stale ambient nor rounded-off substrate is painted.
fn writeFieldJson(
    w: *std.Io.Writer,
    name: []const u8,
    ambient_c: f64,
    want: thermal_scenarios.Scenario,
    solved: Solved,
) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    try w.writeAll("{\"name\":");
    try json_writer.writeString(w, name);
    try w.print(",\"ambient_c\":{d}", .{ambient_c});
    const results = solved.results orelse {
        try w.writeAll(",\"available\":false,\"unavailable\":");
        try json_writer.writeString(w, solved.unavailable);
        try w.writeAll("}");
        return;
    };
    const result = pick: {
        for (results) |r| if (r.scenario == want) break :pick r;
        break :pick results[0];
    };
    try w.print(",\"available\":true,\"scenario\":\"{s}\",\"converged\":{s}", .{
        @tagName(result.scenario),
        if (result.converged) "true" else "false",
    });
    const g = result.grid;
    try w.print(
        ",\"grid\":{{\"cols\":{d},\"rows\":{d},\"cell_mm\":{d:.4}," ++
            "\"origin_x_mm\":{d:.4},\"origin_y_mm\":{d:.4},\"rise_c\":[",
        .{ g.cols, g.rows, g.cell_mm, g.origin_x_mm, g.origin_y_mm },
    );
    // Two decimals: a hundredth of a degree is far below anything this screen
    // can claim, and it keeps a large board's field to a few tens of kilobytes.
    for (g.rise_c, 0..) |c, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{d:.2}", .{c});
    }
    try w.writeAll("],\"active\":[");
    for (g.active, 0..) |active, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeByte(if (active != 0) '1' else '0');
    }
    try w.print("]}},\"hotspot\":{{\"x_mm\":{d:.3},\"y_mm\":{d:.3},\"rise_c\":{d:.2},\"c\":{d:.1}}}", .{
        result.hotspot.x_mm,
        result.hotspot.y_mm,
        result.hotspot.rise_c,
        ambient_c + result.hotspot.rise_c,
    });
    try w.writeAll(",\"parts\":[");
    for (result.parts, 0..) |pf, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"ref\":");
        try json_writer.writeString(w, pf.ref_des);
        try w.print(",\"board_c\":{d:.1}", .{ambient_c + pf.board_rise_c});
        if (pf.tj_rise_c) |rise| try w.print(",\"tj_c\":{d:.1}", .{ambient_c + rise}) else try w.writeAll(",\"tj_c\":null");
        try w.print(",\"jb_estimated\":{s}", .{if (pf.jb_estimated) "true" else "false"});
        if (pf.max_ambient_c) |m| try w.print(",\"max_ambient_c\":{d:.1}", .{m}) else try w.writeAll(",\"max_ambient_c\":null");
        try w.writeAll("}");
    }
    try w.writeAll("],\"skipped\":[");
    for (result.skipped, 0..) |ref, i| {
        if (i > 0) try w.writeAll(",");
        try json_writer.writeString(w, ref);
    }
    try w.writeAll("]}");
}

fn plainError(res: *httpz.Response, status: u16, body: []const u8) void {
    res.status = status;
    res.body = body;
}

/// The `?ambient=` override in °C. Absent ⇒ null (the analysis uses bench
/// ambient); present but not a number ⇒ an error the handler answers 400 with,
/// because silently ignoring it would report temperatures for an ambient the
/// caller did not ask for.
fn ambientFromQuery(req: *httpz.Request) error{BadAmbient}!?f64 {
    const q = req.query() catch return error.BadAmbient;
    const raw = q.get("ambient") orelse return null;
    return std.fmt.parseFloat(f64, raw) catch error.BadAmbient;
}

/// The `?layout=` selection: which saved layout to screen. Absent or empty ⇒
/// null, the design's default board — one spelling for the default, so it keeps
/// a single cache entry however a link spells it.
fn layoutFromQuery(req: *httpz.Request) ?[]const u8 {
    const q = req.query() catch return null;
    const raw = q.get("layout") orelse return null;
    return if (raw.len == 0) null else raw;
}

/// `describe_thermal` — the CLI twin of `GET /api/thermal/:name`. Args `name`
/// (design or module), an optional numeric `ambient`, and an optional `layout`
/// naming a saved layout to screen instead of the default board. Read-only: it
/// writes nothing and touches no sidecar.
pub fn mcpDescribeThermal(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
    const name = argStr(args_val, "name") orelse
        return toolError(out, alloc, "missing required arg: name");
    const ambient = argNumber(args_val, "ambient") catch
        return toolError(out, alloc, "ambient must be a number in degrees Celsius");

    // No `deps`: the CLI answers one process-lifetime request and has no store
    // to retain the body in, so capturing a read-set would be pure cost.
    const body = thermalJson(alloc, project_dir, name, ambient, argStr(args_val, "layout"), null) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound, error.NotADesign, error.InvalidName => return toolErrorFmt(
            out,
            alloc,
            "no design or module named \"{s}\"",
            .{name},
        ),
        else => return toolErrorFmt(out, alloc, "could not screen the design: {s}", .{@errorName(e)}),
    };
    try out.appendSlice(alloc, body);
    return true;
}

/// `args.key` as a non-empty string (absent / non-object / non-string ⇒ null).
fn argStr(args_val: ?std.json.Value, key: []const u8) ?[]const u8 {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}

/// `args.key` as a float. Absent ⇒ null; a JSON integer counts (a client that
/// sends `40` means 40 °C); anything else is the caller's mistake, not a
/// silently-ignored argument.
fn argNumber(args_val: ?std.json.Value, key: []const u8) error{BadAmbient}!?f64 {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch error.BadAmbient,
        .null => null,
        else => error.BadAmbient,
    };
}

/// Write an `{"error":<msg>}` envelope and return false — the CLI layer flags
/// the result `isError`. One error spelling for this tool.
fn toolError(out: *std.ArrayList(u8), alloc: std.mem.Allocator, msg: []const u8) std.mem.Allocator.Error!bool {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    aw.writer.writeAll("{\"error\":") catch return error.OutOfMemory;
    json_writer.writeString(&aw.writer, msg) catch return error.OutOfMemory;
    aw.writer.writeAll("}") catch return error.OutOfMemory;
    try out.appendSlice(alloc, aw.written());
    return false;
}

fn toolErrorFmt(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) std.mem.Allocator.Error!bool {
    const msg = try std.fmt.allocPrint(alloc, fmt, args);
    return toolError(out, alloc, msg);
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

/// A project with one design that dissipates something and one module that
/// does the same standalone — enough to exercise both resolution paths without
/// depending on the repo's own `projects/designs` (which is empty in a
/// worktree).
fn writeThermalFixture(dir: std.Io.Dir) !void {
    try dir.createDirPath(std.testing.io, "lib/components");
    try dir.createDirPath(std.testing.io, "lib/modules");
    try dir.createDirPath(std.testing.io, "src");
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/hot-ic.sexp", .data =
        \\(component "hot-ic"
        \\  (description "test regulator with a declared thermal envelope")
        \\  (footprint "SOT-223")
        \\  (thermal (theta-ja 60) (tj-max 150) (operating -40 85)))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/cool-ic.sexp", .data =
        \\(component "cool-ic"
        \\  (description "test part the module names only through its parameter default")
        \\  (footprint "SOT-223")
        \\  (thermal (theta-ja 40) (tj-max 125)))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "src/heater.sexp", .data =
        \\(import hot-ic)
        \\
        \\(design-block "Heater Board"
        \\  (instance "U1" hot-ic
        \\    (pin 1 "VIN")
        \\    (pin 2 "GND")
        \\    (power 1.0)))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "src/quiet.sexp", .data =
        \\(import cool-ic)
        \\
        \\(design-block "Quiet Board"
        \\  (instance "U1" cool-ic
        \\    (pin 1 "VIN")
        \\    (pin 2 "GND")))
    });
    // Two powered parts and two saved layouts of them: crowded, and spread out
    // over a board twice the size. This is the pair the layout comparison is
    // FOR — same schematic, same dissipation, different temperatures.
    try dir.writeFile(std.testing.io, .{ .sub_path = "src/pair.sexp", .data =
        \\(import hot-ic)
        \\
        \\(design-block "Pair Board"
        \\  (instance "U1" hot-ic
        \\    (pin 1 "VIN")
        \\    (pin 2 "GND")
        \\    (power 1.0))
        \\  (instance "U2" hot-ic
        \\    (pin 1 "VIN")
        \\    (pin 2 "GND")
        \\    (power 1.0)))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "src/pair.layouts.json", .data =
        \\{"rev":1,"layouts":[
        \\{"name":"tight","kind":"manual","ts":2,"parts":[
        \\{"ref":"U1","x":10,"y":10,"rot":0},{"ref":"U2","x":13,"y":10,"rot":0}]},
        \\{"name":"spread","kind":"manual","ts":1,"parts":[
        \\{"ref":"U1","x":10,"y":10,"rot":0},{"ref":"U2","x":70,"y":10,"rot":0}]}]}
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/modules/hot-mod.sexp", .data =
        \\(import hot-ic)
        \\(import cool-ic)
        \\
        \\(defmodule hot-mod ((part cool-ic))
        \\  (design-block "Hot Module"
        \\    (instance "U1" part
        \\      (pin 1 "VIN")
        \\      (pin 2 "GND")
        \\      (power 0.5))))
    });
}

const Served = struct { status: u16, body: []const u8, content_type: ?httpz.ContentType };

/// Drive the real handler for `name` and return the status plus a copy of the
/// body on `alloc`.
fn serve(alloc: std.mem.Allocator, project: []const u8, name: []const u8, ambient: ?[]const u8) !Served {
    var state = serve_root.ServerState{};
    var srv = Server{ .allocator = alloc, .project_dir = project, .auth_dir = project, .state = &state };
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("name", name);
    if (ambient) |a| ht.query("ambient", a);
    try thermalApi(&srv, ht.req, ht.res);
    return .{
        .status = ht.res.status,
        .body = try alloc.dupe(u8, ht.res.body),
        .content_type = ht.res.content_type,
    };
}

/// Same, for a request that needs more than an ambient — the layout selector
/// is a second query key, and the point of it is asking for a NAMED board.
fn serveQuery(alloc: std.mem.Allocator, project: []const u8, name: []const u8, q: []const [2][]const u8) !Served {
    var state = serve_root.ServerState{};
    var srv = Server{ .allocator = alloc, .project_dir = project, .auth_dir = project, .state = &state };
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("name", name);
    for (q) |pair| ht.query(pair[0], pair[1]);
    try thermalApi(&srv, ht.req, ht.res);
    return .{
        .status = ht.res.status,
        .body = try alloc.dupe(u8, ht.res.body),
        .content_type = ht.res.content_type,
    };
}

/// Drive the handler against a SHARED server state, so successive calls see the
/// same response cache. Also reports the cache's own verdict header, which is
/// the difference between "the second call was fast" and "the second call was
/// answered from the entry the first one retained".
fn serveShared(
    state: *serve_root.ServerState,
    alloc: std.mem.Allocator,
    project: []const u8,
    name: []const u8,
) !struct { body: []const u8, cache: []const u8 } {
    var srv = Server{ .allocator = alloc, .project_dir = project, .auth_dir = project, .state = state };
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("name", name);
    try thermalApi(&srv, ht.req, ht.res);
    return .{
        .body = try alloc.dupe(u8, ht.res.body),
        .cache = try alloc.dupe(u8, ht.res.headers.get("X-Netlisp-Thermal-Cache") orelse ""),
    };
}

// spec: Web Server - A cached thermal answer is byte-identical to the freshly computed one it was retained from, and an edit to the design retires it
test "the thermal endpoint answers a repeat request with the identical bytes it retained" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeThermalFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    var state = serve_root.ServerState{ .caches = .init(testing.allocator) };
    defer state.caches.deinit();

    const fresh = try serveShared(&state, alloc, project, "heater");
    try testing.expectEqualStrings("miss", fresh.cache);
    const cached = try serveShared(&state, alloc, project, "heater");
    try testing.expectEqualStrings("hit", cached.cache);
    // The whole contract: a cache loss changes latency and nothing else.
    try testing.expectEqualStrings(fresh.body, cached.body);

    // Editing the design retires the entry, and the recomputed answer reflects
    // the edit rather than the retained one — 2 W into 60 °C/W, not 1 W.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/heater.sexp", .data =
        \\(import hot-ic)
        \\
        \\(design-block "Heater Board"
        \\  (instance "U1" hot-ic
        \\    (pin 1 "VIN")
        \\    (pin 2 "GND")
        \\    (power 2.0)))
    });
    const edited = try serveShared(&state, alloc, project, "heater");
    try testing.expectEqualStrings("miss", edited.cache);
    const root = (try parse(alloc, edited.body)).object;
    const parts = root.get("parts").?.array.items;
    try testing.expectEqual(@as(f64, 145), try num(parts[0].object.get("result").?.object.get("tj_at_ambient").?));
}

fn parse(alloc: std.mem.Allocator, body: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, alloc, body, .{});
}

/// A parsed JSON number as an f64. The serializer prints `{d}`, so a whole
/// number arrives as a JSON integer and a fractional one as a float — the
/// assertion should not care which spelling the value happened to need.
fn num(v: std.json.Value) !f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => error.NotANumber,
    };
}

// spec: serve/thermal - GET /api/thermal/:name screens a design and answers the analysis as facts JSON
test "the thermal endpoint screens a design" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeThermalFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const got = try serve(alloc, project, "heater", null);
    try testing.expectEqual(@as(u16, 200), got.status);
    try testing.expectEqual(httpz.ContentType.JSON, got.content_type.?);

    const root = (try parse(alloc, got.body)).object;
    // Bench ambient by default, and 1 W into a declared 60 °C/W is a 60 °C rise.
    try testing.expectEqual(@as(f64, 25), try num(root.get("ambient_c").?));
    try testing.expectEqualStrings("passive_ok", root.get("verdict").?.string);
    const parts = root.get("parts").?.array.items;
    try testing.expectEqual(@as(usize, 1), parts.len);
    try testing.expectEqualStrings("U1", parts[0].object.get("ref_des").?.string);
    try testing.expectEqual(@as(f64, 85), try num(parts[0].object.get("result").?.object.get("tj_at_ambient").?));
}

// spec: serve/thermal - GET /api/thermal/:name resolves a bare lib/modules module standalone through its parameter defaults
test "the thermal endpoint screens a bare module" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeThermalFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const got = try serve(alloc, project, "hot-mod", null);
    try testing.expectEqual(@as(u16, 200), got.status);
    const root = (try parse(alloc, got.body)).object;
    const parts = root.get("parts").?.array.items;
    try testing.expectEqual(@as(usize, 1), parts.len);
    // Instantiated with NO arguments, so the part it screened is the one the
    // module's `(param default)` supplied — cool-ic, and its own 40 °C/W.
    try testing.expectEqualStrings("cool-ic", parts[0].object.get("component").?.string);
    try testing.expectEqual(@as(f64, 40), try num(parts[0].object.get("theta").?.object.get("ja").?));
    try testing.expectEqual(@as(f64, 0.5), try num(parts[0].object.get("power").?.object.get("watts").?));
}

// spec: serve/thermal - GET /api/thermal/:name?ambient=NN screens at the caller's ambient and rejects one that is not a number
test "the thermal endpoint honours the ambient override and refuses a bad one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeThermalFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const hot = try serve(alloc, project, "heater", "90");
    try testing.expectEqual(@as(u16, 200), hot.status);
    const root = (try parse(alloc, hot.body)).object;
    try testing.expectEqual(@as(f64, 90), try num(root.get("ambient_c").?));
    // The same 60 °C rise off a 90 °C start puts the junction at its 150 °C
    // limit — past the derated threshold in still air and under forced air,
    // so the screen now asks for a heatsink.
    const parts = root.get("parts").?.array.items;
    try testing.expectEqual(@as(f64, 150), try num(parts[0].object.get("result").?.object.get("tj_at_ambient").?));
    try testing.expectEqualStrings("needs_heatsink", root.get("verdict").?.string);

    // A non-numeric ambient is the caller's mistake, answered rather than
    // silently screened at 25 °C.
    const bad = try serve(alloc, project, "heater", "warm");
    try testing.expectEqual(@as(u16, 400), bad.status);
    try testing.expect(std.mem.indexOf(u8, bad.body, "ambient") != null);
}

// spec: serve/thermal - GET /api/thermal/:name answers an unknown design or module name with a 404 whose body is not JSON
test "the thermal endpoint 404s a name that is neither design nor module" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeThermalFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const got = try serve(alloc, project, "no-such-board", null);
    try testing.expectEqual(@as(u16, 404), got.status);
    try testing.expect(!std.mem.startsWith(u8, got.body, "{"));
    try testing.expect(std.mem.indexOf(u8, got.body, "No design or module") != null);
}

// spec: serve/thermal - describe_thermal is a registered read-only CLI tool answering with the endpoint's own bytes
test "describe_thermal is registered read-only and shares the endpoint body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    try testing.expect(mcp_tools.isKnownTool("describe_thermal"));
    try testing.expect(!mcp_tools.isMutationTool("describe_thermal"));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeThermalFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    var out: std.ArrayList(u8) = .empty;
    const args = try parse(alloc, "{\"name\":\"heater\",\"ambient\":90}");
    try testing.expect(try mcpDescribeThermal(alloc, project, args, &out));

    // Byte-for-byte the endpoint's answer for the same design and ambient —
    // the two surfaces run through one body, so they cannot drift apart.
    const served = try serve(alloc, project, "heater", "90");
    try testing.expectEqualStrings(served.body, out.items);
}

/// The `scenarios` array of a served body, or an error when it is null.
fn scenarioRows(alloc: std.mem.Allocator, body: []const u8) ![]std.json.Value {
    const root = (try parse(alloc, body)).object;
    const scen = root.get("scenarios") orelse return error.NoScenarios;
    if (scen != .array) return error.NoScenarios;
    return scen.array.items;
}

// spec: serve/thermal - GET /api/thermal/:name carries the layout-aware cooling ladder as four rungs of absolute degrees at the requested ambient, each naming its hotspot, its ambient ceiling and any part it could not place
test "the thermal endpoint carries the cooling-scenario ladder" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeThermalFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const got = try serve(alloc, project, "heater", null);
    try testing.expectEqual(@as(u16, 200), got.status);
    const root = (try parse(alloc, got.body)).object;
    // A ladder is present, so nothing explains its absence.
    try testing.expect(root.get("scenarios_unavailable").? == .null);
    // …and the Tier-0 half of the answer is untouched beside it.
    try testing.expectEqual(@as(f64, 25), try num(root.get("ambient_c").?));
    try testing.expectEqual(@as(usize, 1), root.get("parts").?.array.items.len);

    const rows = try scenarioRows(alloc, got.body);
    try testing.expectEqual(@as(usize, 4), rows.len);
    try testing.expectEqualStrings("natural", rows[0].object.get("scenario").?.string);
    try testing.expectEqualStrings("airflow_1ms", rows[1].object.get("scenario").?.string);
    try testing.expectEqualStrings("airflow_2ms", rows[2].object.get("scenario").?.string);
    try testing.expectEqualStrings("heatsink", rows[3].object.get("scenario").?.string);
    try testing.expect(rows[0].object.get("heatsink").? == .null);
    const mounted = rows[3].object.get("heatsink").?.object;
    try testing.expectEqualStrings("U1", mounted.get("ref").?.string);
    try testing.expectEqualStrings("board_backside", mounted.get("side").?.string);

    const still = rows[0].object;
    try testing.expect(still.get("converged").?.bool);
    // Every temperature is ABSOLUTE: the board's hottest copper is at or above
    // the ambient it was read at, never a bare rise.
    const board_max = try num(still.get("board_max_c").?);
    try testing.expect(board_max >= 25);
    const hotspot = still.get("hotspot").?.object;
    try testing.expectEqual(board_max, try num(hotspot.get("c").?));
    _ = try num(hotspot.get("x_mm").?);
    _ = try num(hotspot.get("y_mm").?);
    // The one powered part is placed, so it is a row and not a skip.
    try testing.expectEqual(@as(usize, 0), still.get("skipped").?.array.items.len);
    const part = still.get("parts").?.array.items[0].object;
    try testing.expectEqualStrings("U1", part.get("ref").?.string);
    try testing.expect(try num(part.get("tj_c").?) > board_max);
    // θJB was never declared, so the junction went through the half-of-θJA
    // convention and the row says so.
    try testing.expect(part.get("jb_estimated").?.bool);
    // The ambient ceiling names the part that sets it, and is itself an ambient.
    const ceiling = still.get("max_ambient").?.object;
    try testing.expect(try num(ceiling.get("c").?) < 125);
    try testing.expectEqualStrings("U1", ceiling.get("ref").?.string);

    // More air is a cooler board — the whole point of offering the rungs.
    try testing.expect(try num(rows[1].object.get("board_max_c").?) < board_max);
    try testing.expect(try num(rows[2].object.get("board_max_c").?) < try num(rows[1].object.get("board_max_c").?));
}

// spec: serve/thermal - the cooling ladder is read at the caller's ambient, so every temperature on it shifts one for one with ?ambient while each ambient ceiling stays put
test "the cooling ladder follows the ambient override" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeThermalFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const cold = try scenarioRows(alloc, (try serve(alloc, project, "heater", null)).body);
    const warm = try scenarioRows(alloc, (try serve(alloc, project, "heater", "90")).body);

    const c = cold[0].object;
    const w = warm[0].object;
    try testing.expectApproxEqAbs(try num(c.get("board_max_c").?) + 65, try num(w.get("board_max_c").?), 1e-6);
    const cp = c.get("parts").?.array.items[0].object;
    const wp = w.get("parts").?.array.items[0].object;
    try testing.expectApproxEqAbs(try num(cp.get("tj_c").?) + 65, try num(wp.get("tj_c").?), 1e-6);
    try testing.expectApproxEqAbs(try num(cp.get("board_c").?) + 65, try num(wp.get("board_c").?), 1e-6);
    // A maximum ambient IS an ambient — it does not move with the reading.
    try testing.expectEqual(
        try num(c.get("max_ambient").?.object.get("c").?),
        try num(w.get("max_ambient").?.object.get("c").?),
    );
}

// spec: serve/thermal - a design with nothing to dissipate answers with a null ladder beside a sentence naming what is missing, and keeps every lumped field
test "a design that dissipates nothing says why it has no scenarios" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeThermalFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const got = try serve(alloc, project, "quiet", null);
    try testing.expectEqual(@as(u16, 200), got.status);
    const root = (try parse(alloc, got.body)).object;

    try testing.expect(root.get("scenarios").? == .null);
    const why = root.get("scenarios_unavailable").?.string;
    try testing.expect(std.mem.indexOf(u8, why, "dissipation") != null);
    // The lumped half is unchanged — the part is still screened and listed.
    try testing.expectEqualStrings("insufficient_data", root.get("verdict").?.string);
    try testing.expectEqual(@as(usize, 1), root.get("parts").?.array.items.len);
    try testing.expectEqual(@as(f64, 40), try num(root.get("parts").?.array.items[0].object.get("theta").?.object.get("ja").?));
}

// spec: Web Server - get_pcb_layout_image renders the heat-zone image when thermal is set, and a different picture for each cooling scenario
test "get_pcb_layout_image renders the heat field on request" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeThermalFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const still = try mcpImage(alloc, project, "{\"name\":\"heater\",\"thermal\":true,\"width\":420}");
    const blown = try mcpImage(alloc, project, "{\"name\":\"heater\",\"thermal\":true,\"scenario\":\"airflow_2ms\",\"width\":420}");
    const copper = try mcpImage(alloc, project, "{\"name\":\"heater\",\"width\":420}");

    // The scenario argument reaches the renderer: two rungs of the ladder are
    // two pictures, and neither is the copper view.
    try testing.expect(!std.mem.eql(u8, still, blown));
    try testing.expect(!std.mem.eql(u8, still, copper));
    // An unrecognised scenario falls back to still air rather than refusing.
    const typo = try mcpImage(alloc, project, "{\"name\":\"heater\",\"thermal\":true,\"scenario\":\"breeze\",\"width\":420}");
    try testing.expectEqualStrings(still, typo);
}

/// Call `get_pcb_layout_image` with `args_json` and return the decoded PNG.
fn mcpImage(alloc: std.mem.Allocator, project: []const u8, args_json: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const result = mcp_tools.call(alloc, project, "get_pcb_layout_image", try parse(alloc, args_json), &out);
    // A failed call answers with its message in `out`, so assert against that
    // rather than an anonymous error a reader would have to re-run to explain.
    if (!result.ok) try testing.expectEqualStrings("", out.items);
    try testing.expectEqualStrings("image/png", result.image_mime.?);
    const dec = std.base64.standard.Decoder;
    const bytes = try alloc.alloc(u8, try dec.calcSizeForSlice(out.items));
    try dec.decode(bytes, out.items);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x89, 0x50, 0x4E, 0x47 }, bytes[0..4]);
    return bytes;
}

// spec: serve/thermal - describe_thermal names the argument a caller left out or mis-typed instead of screening a default
test "describe_thermal reports a missing name and a non-numeric ambient" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeThermalFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    var no_name: std.ArrayList(u8) = .empty;
    try testing.expect(!try mcpDescribeThermal(alloc, project, try parse(alloc, "{}"), &no_name));
    try testing.expect(std.mem.indexOf(u8, no_name.items, "missing required arg: name") != null);

    var bad_ambient: std.ArrayList(u8) = .empty;
    const args = try parse(alloc, "{\"name\":\"heater\",\"ambient\":\"warm\"}");
    try testing.expect(!try mcpDescribeThermal(alloc, project, args, &bad_ambient));
    try testing.expect(std.mem.indexOf(u8, bad_ambient.items, "ambient must be a number") != null);

    var unknown: std.ArrayList(u8) = .empty;
    const missing = try parse(alloc, "{\"name\":\"no-such-board\"}");
    try testing.expect(!try mcpDescribeThermal(alloc, project, missing, &unknown));
    try testing.expect(std.mem.indexOf(u8, unknown.items, "no design or module named") != null);
}

/// Drive the field handler for `name` and return the status plus a copy of the
/// body on `alloc`.
fn serveField(
    alloc: std.mem.Allocator,
    project: []const u8,
    name: []const u8,
    q: []const [2][]const u8,
) !Served {
    var state = serve_root.ServerState{};
    var srv = Server{ .allocator = alloc, .project_dir = project, .auth_dir = project, .state = &state };
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("name", name);
    for (q) |pair| ht.query(pair[0], pair[1]);
    try thermalFieldApi(&srv, ht.req, ht.res);
    return .{
        .status = ht.res.status,
        .body = try alloc.dupe(u8, ht.res.body),
        .content_type = ht.res.content_type,
    };
}

// spec: serve/thermal - GET /api/thermal-field/:name answers one scenario's rise grid, its hotspot and its per-part rows as the JSON the board overlay paints from
test "the thermal-field endpoint answers a grid, a hotspot and per-part rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeThermalFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const got = try serveField(alloc, project, "heater", &.{.{ "scenario", "airflow_1ms" }});
    try testing.expectEqual(@as(u16, 200), got.status);
    try testing.expectEqual(httpz.ContentType.JSON, got.content_type.?);

    const root = (try parse(alloc, got.body)).object;
    try testing.expect(root.get("available").?.bool);
    try testing.expectEqualStrings("airflow_1ms", root.get("scenario").?.string);
    try testing.expectEqual(@as(f64, 25), try num(root.get("ambient_c").?));

    // The grid is row-major and complete: a short array would paint a torn
    // board, and a client cannot tell a missing cell from a cold one.
    const grid = root.get("grid").?.object;
    const cols: usize = @intCast(grid.get("cols").?.integer);
    const rows: usize = @intCast(grid.get("rows").?.integer);
    try testing.expect(cols > 0 and rows > 0);
    try testing.expectEqual(cols * rows, grid.get("rise_c").?.array.items.len);
    try testing.expectEqual(cols * rows, grid.get("active").?.array.items.len);
    try testing.expect(try num(grid.get("cell_mm").?) > 0);

    // Every cell is a RISE, never an absolute temperature: the overlay's colour
    // scale is normalised on these, and an ambient baked in would wash it out.
    var peak: f64 = 0;
    for (grid.get("rise_c").?.array.items) |c| {
        const v = try num(c);
        try testing.expect(v >= 0);
        if (v > peak) peak = v;
    }
    // The hotspot is that peak, reported both as a rise and at this ambient.
    const hot = root.get("hotspot").?.object;
    // Both JSON paths print two decimals but start from f32 and f64
    // respectively, so a value exactly on a half-cent boundary may land on
    // opposite adjacent decimals. One cent plus float comparison slack is the
    // format's strict bound.
    try testing.expectApproxEqAbs(peak, try num(hot.get("rise_c").?), 0.011);
    // `c` is printed to a tenth, `rise_c` to a hundredth, so the sum is only
    // ever equal to within the coarser of the two roundings.
    try testing.expectApproxEqAbs(25 + peak, try num(hot.get("c").?), 0.1);

    // Per-part rows carry temperatures and no geometry — the overlay reads each
    // part's pose from the PCB page's own blob.
    const parts = root.get("parts").?.array.items;
    try testing.expectEqual(@as(usize, 1), parts.len);
    try testing.expectEqualStrings("U1", parts[0].object.get("ref").?.string);
    try testing.expect(try num(parts[0].object.get("board_c").?) >= 25);
    try testing.expect(parts[0].object.get("x_mm") == null);
}

// spec: serve/thermal - GET /api/thermal-field/:name says why it has no field instead of answering an empty grid, and rejects a non-numeric ?ambient
test "the thermal-field endpoint explains an absent field and refuses a bad ambient" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeThermalFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    // `quiet` dissipates nothing, so there is no field to paint — and saying so
    // is an answer, not a failure. A grid of zeroes would read as "solved, cold".
    const none = try serveField(alloc, project, "quiet", &.{});
    try testing.expectEqual(@as(u16, 200), none.status);
    try testing.expectEqual(httpz.ContentType.JSON, none.content_type.?);
    const root = (try parse(alloc, none.body)).object;
    try testing.expect(!root.get("available").?.bool);
    try testing.expect(root.get("unavailable").?.string.len > 0);
    try testing.expect(root.get("grid") == null);
    try testing.expect(root.get("hotspot") == null);

    const bad = try serveField(alloc, project, "heater", &.{.{ "ambient", "warm" }});
    try testing.expectEqual(@as(u16, 400), bad.status);
    // A refusal is plain text saying what was wrong, never a JSON field the
    // overlay would try to paint.
    try testing.expectEqualStrings(err_ambient, bad.body);

    const missing = try serveField(alloc, project, "no-such-board", &.{});
    try testing.expectEqual(@as(u16, 404), missing.status);
}

// spec: serve/thermal - GET /api/thermal/:name?layout=<name> screens that saved layout's own board, so two layouts of one design answer with different temperatures
// spec: serve/thermal - a ?layout nobody saved is answered with the sentence saying so instead of the default board's temperatures
test "the thermal endpoint screens a named saved layout" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeThermalFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const tight = try scenarioRows(alloc, (try serveQuery(alloc, project, "pair", &.{.{ "layout", "tight" }})).body);
    const spread = try scenarioRows(alloc, (try serveQuery(alloc, project, "pair", &.{.{ "layout", "spread" }})).body);

    // Two boards, one schematic. Both were solved over the poses they name, so
    // the parts that sit 3 mm apart heat each other and the pair 60 mm apart on
    // twice the copper does not — which is the whole reason to compare layouts.
    const hot = try num(tight[0].object.get("board_max_c").?);
    const cool = try num(spread[0].object.get("board_max_c").?);
    try testing.expect(hot > cool);
    // Both are still ABSOLUTE degrees at the requested ambient, not rises.
    try testing.expect(cool >= 25);

    // A name nobody saved is not the default board wearing that name. Screening
    // one board and labelling it another is a lie a reader cannot see, so the
    // answer is the sentence and no ladder at all.
    const missing = try serveQuery(alloc, project, "pair", &.{.{ "layout", "no-such-layout" }});
    try testing.expectEqual(@as(u16, 200), missing.status);
    const root = (try parse(alloc, missing.body)).object;
    try testing.expect(root.get("scenarios").? == .null);
    try testing.expect(std.mem.indexOf(u8, root.get("scenarios_unavailable").?.string, "no saved layout") != null);
    // The lumped screen is layout-free, so it is still answered in full.
    try testing.expectEqual(@as(usize, 2), root.get("parts").?.array.items.len);
}

// spec: serve/thermal - describe_thermal takes the same optional layout argument and shares the endpoint's bytes for it
test "describe_thermal screens the layout it is told to" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeThermalFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    var out: std.ArrayList(u8) = .empty;
    const args = try parse(alloc, "{\"name\":\"pair\",\"layout\":\"spread\"}");
    try testing.expect(try mcpDescribeThermal(alloc, project, args, &out));
    const http = try serveQuery(alloc, project, "pair", &.{.{ "layout", "spread" }});
    // Byte-identical, as for every other argument: an agent and a browser must
    // never be told different temperatures for one board.
    try testing.expectEqualStrings(http.body, out.items);

    // …and the tool's own schema offers the argument, or no agent could send it.
    try testing.expect(std.mem.indexOf(u8, mcp_tools.tools_list_result, "Which SAVED PCB layout") != null);
}

// spec: serve/thermal - GET /api/thermal-field/:name?layout=<name> paints the named layout's own field
test "the thermal-field endpoint paints the layout it is asked for" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeThermalFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const tight = (try parse(alloc, (try serveField(alloc, project, "pair", &.{.{ "layout", "tight" }})).body)).object;
    const spread = (try parse(alloc, (try serveField(alloc, project, "pair", &.{.{ "layout", "spread" }})).body)).object;
    try testing.expect(tight.get("available").?.bool);
    try testing.expect(spread.get("available").?.bool);
    // The picture the overlay paints is the picture of the board the page says
    // it is showing: crowded parts read hotter here too, from the same solve
    // the numbers came from.
    const hot = try num(tight.get("hotspot").?.object.get("rise_c").?);
    const cool = try num(spread.get("hotspot").?.object.get("rise_c").?);
    try testing.expect(hot > cool);

    const missing = (try parse(alloc, (try serveField(alloc, project, "pair", &.{.{ "layout", "nope" }})).body)).object;
    try testing.expect(!missing.get("available").?.bool);
    try testing.expect(std.mem.indexOf(u8, missing.get("unavailable").?.string, "no saved layout") != null);
}

// spec: serve/thermal - a solved cooling ladder is retained between requests and re-solved only once the design, its libraries, its layout sidecars or its live-edit version change
// spec: serve/thermal - a cached solve is reused across ambients, so changing ?ambient re-screens without relaxing a single field again
test "the cooling ladder is solved once and then read at any ambient" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeThermalFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    var store: thermal_cache.Store = .{ .allocator = testing.allocator };
    defer store.deinit();
    thermal_cache.publish(&store);
    defer thermal_cache.publish(null);

    var eval = Evaluator.init(alloc, project);
    defer eval.deinit();
    const nb = try mcp_tools.evalNamedBlock(alloc, project, "heater", &eval);

    // Cold: nothing retained, so this pays the placement resolve and four
    // relaxations, and leaves the answer behind.
    const bench = try thermal.analyze(alloc, nb.block, 25);
    const first = try solveFor(alloc, project, "heater", bench, null);
    try testing.expect(first.results != null);
    try testing.expectEqual(@as(usize, 1), store.entries.count());

    // Replace the retained field with a value no solver would produce. A second
    // call that comes back carrying it can only have READ the cache — which is
    // the claim, and the one thing a timing-free test can prove.
    var it = store.entries.valueIterator();
    it.next().?.results[0].hotspot.rise_c = 999;

    // A different ambient is a different QUESTION but the same solve: the field
    // is ambient-free, and the ambient is added afterwards.
    const hot = try thermal.analyze(alloc, nb.block, 70);
    const second = try solveFor(alloc, project, "heater", hot, null);
    try testing.expectEqual(@as(f64, 999), second.results.?[0].hotspot.rise_c);
    try testing.expectEqual(@as(usize, 1), store.entries.count());
}

// spec: serve/thermal - a caller that has already resolved a placement shares the same cached solve rather than resolving the board a second time
test "a caller holding its own placement shares the one cached solve" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeThermalFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    var store: thermal_cache.Store = .{ .allocator = testing.allocator };
    defer store.deinit();
    thermal_cache.publish(&store);
    defer thermal_cache.publish(null);

    // The heat-zone image's path: it has resolved the board already (it has to
    // draw it), so it hands the placement over rather than paying that resolve
    // a second time inside `solveFor`.
    var eval = Evaluator.init(alloc, project);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer dropModule(alloc, module_res);
    const solved = try pcb_layout_page.solveForRequest(alloc, project, "heater", .{}, &eval, &module_res);
    const nb = try mcp_tools.evalNamedBlock(alloc, project, "heater", &eval);
    const bench = try thermal.analyze(alloc, nb.block, 25);
    const over = try solveOver(alloc, &eval, project, "heater", bench, boardOf(solved, null, bench));
    try testing.expect(over.len > 0);
    try testing.expectEqual(@as(usize, 1), store.entries.count());

    // One entry, and it is the SAME one the page and its facts JSON read — so
    // a picture can never show a field the numbers disagree with.
    var it = store.entries.valueIterator();
    it.next().?.results[0].hotspot.rise_c = 999;
    const page = try solveFor(alloc, project, "heater", bench, null);
    try testing.expectEqual(@as(f64, 999), page.results.?[0].hotspot.rise_c);
    try testing.expectEqual(@as(usize, 1), store.entries.count());
}
