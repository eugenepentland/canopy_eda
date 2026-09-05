//! `GET /thermal/:name` — the thermal review page: one screen carrying the
//! board-coupled verdict, the cooling-scenario ladder, the heat-zone image and
//! the per-part junction table for a design or a bare `lib/modules` module.
//!
//! Every sentence, pill and cell on it is built by `review_thermal.zig` — the
//! same builders the schematic page's review panel, the markdown report and the
//! review PDF render from — so the page can never state a verdict the document
//! does not. The numbers come from `eval/thermal.zig`, the layout-aware ladder
//! from `thermal_api.scenariosFor` (the same call `GET /api/thermal/:name`
//! makes), and the picture is the `?thermal=1` heat-zone PNG of that same
//! placement, so the image and the tables always describe one board.
//!
//! Changing the AMBIENT re-renders on the server (`?fragment=1` answers the two
//! live regions alone), because the facts JSON carries numbers and not prose:
//! re-deriving the verdict sentence in the browser is exactly the disagreement
//! this module exists to prevent. Changing the COOLING SCENARIO needs no round
//! trip — all four scenario tables are rendered into the page and the client
//! reveals one of them.
//!
//! `?layout=` screens one NAMED saved layout instead of the design's default
//! board, and the COMPARE panel puts every saved layout of the design in one
//! table beside it — how much cooler the same parts run when they are placed
//! differently and stitched with different vias. Each comparison row is a whole
//! second solve of a whole second board, so rows are filled one at a time, on
//! request (`?row=<layout>`), and the sweep can be stopped: a design with fifty
//! saved layouts is fifty solves, and pretending otherwise would either freeze
//! the page or quietly compare a handful and call it the answer.
//!
//! Read-only: nothing here writes to the project dir.

const std = @import("std");
const httpz = @import("httpz");
const log = @import("../infra/log.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const escape = @import("../escape.zig");
const mcp_tools = @import("mcp_tools.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const review_thermal = @import("../review_thermal.zig");
const serve_root = @import("../serve.zig");
const handler_probe = @import("handler_probe.zig");
const navbar = @import("navbar.zig");
const thermal = @import("../eval/thermal.zig");
const thermal_api = @import("thermal_api.zig");
const thermal_scenarios = @import("../thermal_scenarios.zig");
const urlcodec = @import("urlcodec.zig");
const Server = serve_root.Server;

/// Error set for the handler. Only allocation escapes to httpz; every other
/// failure is answered as a status plus a plain-text body.
pub const HandlerError = std.mem.Allocator.Error;

/// What one render can fail with: the writer's own failure plus whatever the
/// shared `review_thermal` cell builders allocate.
const RenderError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// Coldest ambient the page's control accepts (°C) — below the coldest
/// industrial part rating anyone declares, so the clamp never refuses a real
/// board while still keeping a typo out of the solver.
const ambient_min_c: f64 = -55;
/// Hottest ambient the page's control accepts (°C).
const ambient_max_c: f64 = 125;

const http_not_found: u16 = 404;
const http_internal_error: u16 = 500;

const err_not_found = "No design or module by that name\n";
const err_render = "Thermal review page failed to render\n";

/// What one render of the page knows. Built once per request and handed to
/// every writer below, so the headline, the ladder, the image URL and the
/// per-part rows are all reading one screening at one ambient.
const View = struct {
    name: []const u8,
    is_module: bool,
    ambient_c: f64,
    scenario: thermal_scenarios.Scenario,
    bt: thermal.BoardThermal,
    scenarios: thermal_scenarios.Answer,
    lines: review_thermal.Lines,
    /// Every saved layout of this design, in sidecar order — the rows of the
    /// compare panel and the options of the layout picker. Empty for a design
    /// that has never been saved, which is also the page with no picker.
    layouts: []const pcb_layout_page.SavedLayout = &.{},
    /// The saved layout being screened, or null for the design's DEFAULT board
    /// (the starred layout, else the auto cache, else a grid). Naming the
    /// starred layout resolves back to null — one board, one spelling, one
    /// cache entry, however a link spells it.
    layout: ?[]const u8 = null,
    /// Set when `?layout=` named something this design does not have: the page
    /// falls back to the default board and says which name it could not find,
    /// rather than reporting one board's temperatures under another's name.
    layout_missing: []const u8 = "",
    /// The compare panel is open (`?compare=1`). Carried through the fragment
    /// so an ambient change — which invalidates every row in it — comes back
    /// open and refills, instead of collapsing under the reader.
    compare: bool = false,
};

/// GET /thermal/:name — the thermal review page for a design or a bare
/// `lib/modules` module. `:name` is percent-decoded before any lookup; an
/// unknown name is a 404 with a plain-text body.
///
/// `?ambient=NN` screens at that ambient (clamped to the control's own range),
/// `?scenario=<tag>` opens on that rung of the cooling ladder, `?layout=NAME`
/// screens that saved layout instead of the design's default board,
/// `?compare=1` opens the layout-comparison panel, and `?fragment=1` answers
/// the two ambient-dependent regions alone — the response the client swaps in
/// rather than reloading the whole page. `?row=NAME` answers with the cells of
/// ONE comparison row: a whole solve of that board, differenced against the one
/// on screen.
pub fn thermalPage(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const alloc = req.arena;
    const name_raw = req.param("name") orelse return plainError(res, http_not_found, err_not_found);
    const name = try urlcodec.decodeAlloc(alloc, name_raw);

    // Read the live version BEFORE computing, so a design edit that lands
    // mid-request is treated as a miss next time instead of being baked in.
    const live_version = serve_root.getLiveVersion(name);
    var miss_version: ?u32 = null;
    if (ctx.state.caches.reads.thermal_page.serve(.{
        .scratch = alloc,
        .req = req,
        .res = res,
        .name = name,
        .live_version = live_version,
    }, &miss_version)) {
        res.content_type = .HTML;
        res.header("Cache-Control", "no-store");
        return;
    }

    var eval = Evaluator.init(alloc, ctx.project_dir);
    defer eval.deinit();
    const nb = mcp_tools.evalNamedBlock(alloc, ctx.project_dir, name, &eval) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return plainError(res, http_not_found, err_not_found),
    };

    const ambient = clampAmbient(queryFloat(req, "ambient") orelse thermal.default_ambient_c);
    const scenario = pcb_layout_page.parseScenario(queryOpt(req, "scenario")) orelse .natural;
    // The lumped screen is layout-free, so ONE analysis serves the shown board,
    // every comparison row and the baseline they are all differenced against.
    const bt = try thermal.analyze(alloc, nb.block, ambient);
    const layouts = pcb_layout_page.readLayouts(alloc, ctx.project_dir, name);
    const want = queryOpt(req, "layout");
    const shown = shownLayout(layouts, want);

    // One comparison row: bare cells for a board that is NOT the one on screen.
    // Answered before the page is built because it shares none of it.
    if (queryOpt(req, "row")) |row_layout| {
        const cells = renderCompareRow(alloc, ctx.project_dir, name, bt, .{
            .layout = rowLayout(layouts, row_layout),
            .base = shown,
            .scenario = scenario,
            .ambient_c = ambient,
        }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return plainError(res, http_internal_error, err_render),
        };
        res.content_type = .HTML;
        res.header("Cache-Control", "no-store");
        res.body = cells;
        return;
    }

    const scenarios = try thermal_api.scenariosFor(alloc, ctx.project_dir, name, bt, ambient, shown);
    const view = View{
        .name = name,
        .is_module = nb.is_module,
        .ambient_c = ambient,
        .scenario = scenario,
        .bt = bt,
        .scenarios = scenarios,
        .lines = try review_thermal.summaryLines(alloc, bt, scenarios),
        .layouts = layouts,
        .layout = shown,
        .layout_missing = if (want != null and shown == null and !isDefaultLayout(layouts, want.?)) want.? else "",
        .compare = queryOpt(req, "compare") != null,
    };

    const body = render(alloc, view, nb.block.name, queryOpt(req, "fragment") != null) catch |e| {
        switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                log.warn("thermal page {s} failed: {s}", .{ name, @errorName(e) });
                return plainError(res, http_internal_error, err_render);
            },
        }
    };
    res.content_type = .HTML;
    res.header("Cache-Control", "no-store");
    res.body = body;
    // Captured here rather than in a `defer`: `eval` is still alive (its own
    // `defer deinit` runs after this statement), and the retention has to see
    // the read-set, not the other way round.
    ctx.state.caches.reads.thermal_page.store(.{
        .scratch = alloc,
        .req = req,
        .res = res,
        .name = name,
        .body = body,
        .files = thermal_api.captureDeps(alloc, &eval, ctx.project_dir, name),
        .live_version = miss_version,
        .current_version = serve_root.getLiveVersion(name),
    });
}

/// Render the default thermal review without a published server cache. The
/// page-latency gate uses this request-less seam so every repetition measures a
/// cold evaluation, layout-aware scenario solve, summary build and HTML render
/// matching `/thermal/:name`, without inheriting a prior repetition's solve.
pub fn benchColdPage(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?usize {
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const nb = mcp_tools.evalNamedBlock(allocator, project_dir, name, &eval) catch return null;
    const ambient = thermal.default_ambient_c;
    const bt = thermal.analyze(allocator, nb.block, ambient) catch return null;
    const layouts = pcb_layout_page.readLayouts(allocator, project_dir, name);
    const scenarios = thermal_api.scenariosFor(allocator, project_dir, name, bt, ambient, null) catch return null;
    const view = View{
        .name = name,
        .is_module = nb.is_module,
        .ambient_c = ambient,
        .scenario = .natural,
        .bt = bt,
        .scenarios = scenarios,
        .lines = review_thermal.summaryLines(allocator, bt, scenarios) catch return null,
        .layouts = layouts,
    };
    const body = render(allocator, view, nb.block.name, false) catch return null;
    return body.len;
}

fn plainError(res: *httpz.Response, status: u16, body: []const u8) void {
    res.status = status;
    res.body = body;
}

/// An ambient outside the control's range is CLAMPED rather than refused: the
/// number arrives from a spinner a reader can hold down, and answering a board
/// at the nearest ambient it was asked about beats answering nothing.
fn clampAmbient(c: f64) f64 {
    if (std.math.isNan(c)) return thermal.default_ambient_c;
    return std.math.clamp(c, ambient_min_c, ambient_max_c);
}

/// Which saved layout the page is screening, canonicalized: null for the
/// design's default board.
///
/// A `want` that names the STARRED layout resolves to null, because that IS the
/// default board — `solveForRequest` renders it verbatim with no `?layout=` at
/// all — so the two spellings share one solve and one cache entry instead of
/// paying twice for the same poses. A `want` nobody saved also resolves to null
/// (the caller reports it as missing); silently screening the default board
/// under a name that is not on it is the one answer this page must never give.
fn shownLayout(layouts: []const pcb_layout_page.SavedLayout, want: ?[]const u8) ?[]const u8 {
    const w = want orelse return null;
    for (layouts) |l| {
        if (!std.mem.eql(u8, l.name, w)) continue;
        return if (l.default) null else l.name;
    }
    return null;
}

/// The board one comparison row is FOR.
///
/// Unlike `shownLayout` this keeps an unknown name unknown. A row is a claim
/// about one specific saved layout, so answering a name nobody saved with the
/// default board's numbers would print a temperature under the wrong heading;
/// left alone, the solve reports that there is no such board. The starred name
/// still folds to null, since that layout and the default board are one board
/// and deserve one solve between them.
fn rowLayout(layouts: []const pcb_layout_page.SavedLayout, want: []const u8) ?[]const u8 {
    if (want.len == 0 or isDefaultLayout(layouts, want)) return null;
    return want;
}

/// True when `want` names the starred layout — the board `shownLayout` folds
/// into the default. Distinguishes "asked for the default by name" from "asked
/// for a layout that is not there", which read identically as a null.
fn isDefaultLayout(layouts: []const pcb_layout_page.SavedLayout, want: []const u8) bool {
    for (layouts) |l| {
        if (std.mem.eql(u8, l.name, want)) return l.default;
    }
    return false;
}

/// The starred layout — the one the default board renders — or null when the
/// design has none and its default board is generated.
fn starredLayout(layouts: []const pcb_layout_page.SavedLayout) ?pcb_layout_page.SavedLayout {
    for (layouts) |l| {
        if (l.default) return l;
    }
    return null;
}

/// The ladder row for one scenario, or null when the ladder has no such rung.
fn rowFor(ladder: thermal_scenarios.Ladder, want: thermal_scenarios.Scenario) ?thermal_scenarios.Row {
    for (ladder.rows) |row| {
        if (row.scenario == want) return row;
    }
    return null;
}

/// The board's peak junction temperature under one scenario — the number the
/// comparison ranks layouts by. Null when the board has no ladder, no such rung
/// or no part with a junction figure.
fn peakTj(answer: thermal_scenarios.Answer, want: thermal_scenarios.Scenario) ?f64 {
    const ladder = answer.ladder orelse return null;
    const row = rowFor(ladder, want) orelse return null;
    return (row.hottest() orelse return null).tj_c;
}

fn queryOpt(req: *httpz.Request, key: []const u8) ?[]const u8 {
    const q = req.query() catch return null;
    const v = q.get(key) orelse return null;
    return if (v.len == 0) null else v;
}

fn queryFloat(req: *httpz.Request, key: []const u8) ?f64 {
    return std.fmt.parseFloat(f64, queryOpt(req, key) orelse return null) catch null;
}

// ── Rendering ─────────────────────────────────────────────────────────

/// The whole document, or — when `fragment` — only the two regions an ambient
/// change invalidates. Both spellings are written by the same two block writers,
/// so a swapped-in fragment cannot render differently from a fresh page load.
fn render(
    alloc: std.mem.Allocator,
    v: View,
    title: []const u8,
    fragment: bool,
) RenderError![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    if (fragment) {
        try writeVerdictBlock(w, v);
        try writeTablesBlock(w, alloc, v);
        return aw.written();
    }
    try writeDocHead(w, v, title);
    // The assembly workspace's shape: a scrolling panel of numbers beside a
    // full-height board that fills whatever is left. The board is the LIVE PCB
    // view, not a picture of it, so panning and zooming the heat map is the same
    // gesture as panning and zooming the layout.
    try w.writeAll("<main class=\"tp-workspace\" id=\"tp-page\" data-name=\"");
    try escape.writeXml(w, v.name);
    try w.print("\" data-ambient=\"{d}\" data-scenario=\"{s}\" data-layout=\"", .{ v.ambient_c, @tagName(v.scenario) });
    try escape.writeXml(w, v.layout orelse "");
    try w.writeAll("\">");
    try w.writeAll("<aside class=\"tp-panel\">");
    try writeVerdictBlock(w, v);
    try writeControls(w, alloc, v);
    try writeTablesBlock(w, alloc, v);
    try w.writeAll("</aside>");
    try writeBoardPane(w, v);
    try w.writeAll("</main><script src=\"/static/thermal_page.js\"></script></body></html>");
    return aw.written();
}

/// `<head>` plus the topbar carrying the design-view tab bar with Thermal
/// active — the same tabs the schematic, PCB, 3D and Assembly pages show.
fn writeDocHead(w: *std.Io.Writer, v: View, title: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">");
    try w.writeAll("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\">");
    try w.writeAll("<title>");
    try escape.writeXml(w, v.name);
    try w.writeAll(" — Thermal</title>");
    try w.writeAll("<style>");
    try w.writeAll(navbar.css);
    try w.writeAll("</style><link rel=\"stylesheet\" href=\"/static/thermal_page.css\"></head><body>");
    try navbar.write(w, .none);
    try w.writeAll("<header class=\"topbar\"><strong>");
    try escape.writeXml(w, if (title.len > 0) title else v.name);
    try w.writeAll("</strong>");
    try writeNav(w, v);
    try w.writeAll("</header>");
}

/// The design-view tab bar, Thermal active and last. Modules get no Assembly
/// tab (that workspace is a physical-board surface), exactly as the schematic
/// and PCB headers scope it.
///
/// The board tabs carry the page's `?layout=` through: a reader who is looking
/// at one saved layout's heat and clicks "PCB Layout" means THAT board, not the
/// starred one.
fn writeNav(w: *std.Io.Writer, v: View) std.Io.Writer.Error!void {
    try w.writeAll("<nav aria-label=\"Design views\"><a href=\"");
    try w.writeAll(if (v.is_module) "/modules/" else "/schematics/");
    try writeUrlEncoded(w, v.name);
    try w.writeAll("\">Schematic</a><a href=\"/pcb-layout/");
    try writeUrlEncoded(w, v.name);
    try writeLayoutParam(w, v, true);
    try w.writeAll("\">PCB Layout</a><a href=\"/pcb-layout/");
    try writeUrlEncoded(w, v.name);
    try w.writeAll("?view=3d");
    try writeLayoutParam(w, v, false);
    try w.writeAll("\">3D</a>");
    if (!v.is_module) {
        try w.writeAll("<a href=\"/assembly-debug/");
        try writeUrlEncoded(w, v.name);
        try writeLayoutParam(w, v, true);
        try w.writeAll("\">Assembly</a>");
    }
    try w.writeAll("<a class=\"active\" aria-current=\"page\">Thermal</a>");
    if (!v.is_module) {
        try w.writeAll("<a href=\"/review/");
        try writeUrlEncoded(w, v.name);
        try writeLayoutParam(w, v, true);
        try w.writeAll("\">Review</a>");
    }
    try w.writeAll("</nav>");
}

/// `layout=<name>` when the page is screening a NAMED saved layout; nothing at
/// all for the default board. `first` says whether it opens the target's query
/// or joins one already there. Every link off this page goes through it, so a
/// reader never lands on a different board than the one they were reading the
/// temperatures of.
fn writeLayoutParam(w: *std.Io.Writer, v: View, first: bool) std.Io.Writer.Error!void {
    const l = v.layout orelse return;
    try w.writeAll(if (first) "?layout=" else "&amp;layout=");
    try writeUrlEncoded(w, l);
}

/// The headline region: the board-coupled verdict as a pill plus its sentence,
/// the package-level screen demoted below it, and the ambient window. Rebuilt
/// whole on an ambient change, which is why it is its own element.
fn writeVerdictBlock(w: *std.Io.Writer, v: View) std.Io.Writer.Error!void {
    const headline = review_thermal.headlineVerdict(v.bt, v.scenarios);
    try w.writeAll("<section class=\"tp-verdict\" id=\"tp-verdict\" aria-label=\"Thermal verdict\">");
    try w.print("<p class=\"tp-headline\"><span class=\"tp-pill tp-{s}\">{s}</span> ", .{
        pillClass(headline),
        verdictLabel(headline),
    });
    try escape.writeXml(w, v.lines.verdict);
    try w.writeAll("</p>");
    if (v.lines.package.len > 0) try writeHint(w, "", v.lines.package);
    if (v.lines.ambient.len > 0) try writeHint(w, "Board ambient range: ", v.lines.ambient);
    if (v.lines.hint.len > 0) try writeHint(w, "", v.lines.hint);
    try w.writeAll("</section>");
}

fn writeHint(w: *std.Io.Writer, lead: []const u8, text: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("<p class=\"tp-hint\">");
    try w.writeAll(lead);
    try escape.writeXml(w, text);
    try w.writeAll("</p>");
}

/// The controls row: the cooling-scenario segmented picker (only where there IS
/// a ladder to pick from), and the two read-only exports. The ambient spinner
/// lives beside the temperature scale when there is a board field; only the
/// no-field fallback keeps it here, because that page has no board toolbar.
/// Deliberately OUTSIDE the swapped regions — replacing the number the reader is
/// typing into would fight them for the caret.
fn writeControls(w: *std.Io.Writer, alloc: std.mem.Allocator, v: View) RenderError!void {
    try w.writeAll("<section class=\"tp-controls\" aria-label=\"Thermal controls\">");
    try writeLayoutPicker(w, v);
    if (v.scenarios.ladder) |ladder| {
        const fan_row = rowFor(ladder, .fan);
        // A physical, authored sink carries a concrete PCB face. The generic
        // fallback heatsink rung deliberately does not: it is a sizing aid,
        // not saved hardware that can be included/excluded from an assembly.
        const has_saved_sink = ladder.heatsink_face != null;
        if (fan_row != null or has_saved_sink) {
            try w.writeAll("<fieldset class=\"tp-cooling\"><legend>Include saved cooling</legend><div class=\"tp-cooling-switches\">");
            if (fan_row != null) {
                try w.print("<label class=\"tp-cooling-switch\"><input id=\"tp-use-fan\" type=\"checkbox\"{s}> Fan</label>", .{
                    if (v.scenario == .fan or v.scenario == .fan_heatsink) " checked" else "",
                });
            }
            if (has_saved_sink) {
                try w.print("<label class=\"tp-cooling-switch\"><input id=\"tp-use-heatsink\" type=\"checkbox\"{s}> Heatsink</label>", .{
                    if (v.scenario == .heatsink or v.scenario == .fan_heatsink) " checked" else "",
                });
            }
            try w.writeAll("</div><p>View and simulation only — the saved fan and heatsink stay in the layout.</p></fieldset>");
        }
        try w.writeAll("<div class=\"tp-seg\" id=\"tp-seg\" role=\"group\" aria-label=\"Cooling scenario\">");
        for (ladder.rows) |row| {
            const label = try thermal_scenarios.scenarioLabel(alloc, row.scenario, thermal_scenarios.sinkOf(ladder));
            const on = row.scenario == v.scenario;
            try w.print("<button type=\"button\" class=\"tp-seg-btn{s}\" data-scenario=\"{s}\" aria-pressed=\"{s}\">", .{
                if (on) " on" else "",
                @tagName(row.scenario),
                if (on) "true" else "false",
            });
            try escape.writeXml(w, label);
            try w.writeAll("</button>");
        }
        try w.writeAll("</div>");
    }
    if (v.scenarios.ladder == null) try writeAmbientControl(w, v);
    try w.writeAll("<span class=\"tp-tools\"><a class=\"tp-tool\" href=\"/api/schematic-pdf/");
    try writeUrlEncoded(w, v.name);
    try w.writeAll("\" download title=\"Download the design-review document\">⤓ PDF</a>");
    try w.writeAll("<a class=\"tp-tool\" id=\"tp-json\" href=\"/api/thermal/");
    try writeUrlEncoded(w, v.name);
    try w.print("?ambient={d}", .{v.ambient_c});
    try writeLayoutParam(w, v, false);
    try w.writeAll("\" title=\"The same screening as read-only facts JSON\">{ } JSON</a></span>");
    try w.writeAll("</section>");
}

fn writeAmbientControl(w: *std.Io.Writer, v: View) std.Io.Writer.Error!void {
    try w.print(
        "<label class=\"tp-amb\">Ambient <input id=\"tp-ambient\" type=\"number\" inputmode=\"numeric\" " ++
            "value=\"{d}\" min=\"{d}\" max=\"{d}\" step=\"1\" aria-label=\"Ambient temperature\"> °C</label>",
        .{ v.ambient_c, ambient_min_c, ambient_max_c },
    );
    try w.writeAll("<span class=\"tp-status\" id=\"tp-status\" role=\"status\" hidden></span>");
}

/// The board picker: which saved layout this page is screening.
///
/// Shown only where there is a choice — a design with no saved layout has one
/// board and no question to answer. The starred layout is not listed twice: it
/// IS the default board, and offering both spellings would invite a reader to
/// compare a board with itself.
fn writeLayoutPicker(w: *std.Io.Writer, v: View) std.Io.Writer.Error!void {
    if (v.layouts.len == 0) return;
    const starred = starredLayout(v.layouts);
    try w.writeAll("<label class=\"tp-layout\">Board <select id=\"tp-layout\">");
    try w.print("<option value=\"\"{s}>", .{if (v.layout == null) " selected" else ""});
    if (starred) |l| {
        try w.writeAll("★ ");
        try escape.writeXml(w, l.name);
    } else {
        try w.writeAll("Default board");
    }
    try w.writeAll("</option>");
    for (v.layouts) |l| {
        if (l.default) continue;
        const on = if (v.layout) |cur| std.mem.eql(u8, cur, l.name) else false;
        try w.print("<option{s} value=\"", .{if (on) " selected" else ""});
        try escape.writeXml(w, l.name);
        try w.writeAll("\">");
        try escape.writeXml(w, l.name);
        try w.writeAll("</option>");
    }
    try w.writeAll("</select></label>");
    if (v.layout_missing.len > 0) {
        try w.writeAll("<span class=\"tp-miss\">no saved layout named “");
        try escape.writeXml(w, v.layout_missing);
        try w.writeAll("” — showing the default board</span>");
    }
}

/// The board pane: the SAME read-only physical board the assembly page embeds,
/// with one extra script (`pcb_thermal.js`) painting the solved field over it.
///
/// It is an iframe rather than an image because a heat map is read by looking
/// closely: the reader gets the board viewer's own pan, zoom, layer and part
/// tools, and the picture is a live overlay on the board rather than a
/// server-rendered raster that has to be re-fetched to move. The overlay reads
/// the field from `/api/thermal-field/:name` — the same cached solve these
/// tables were built from — and reports back through `postMessage`, which is
/// what fills the legend beside it.
///
/// Omitted entirely when there is no ladder: there is no field to paint, and an
/// empty board under a heat legend would read as "solved, and cold".
fn writeBoardPane(w: *std.Io.Writer, v: View) std.Io.Writer.Error!void {
    try w.writeAll("<section class=\"tp-board-pane\">");
    if (v.scenarios.ladder == null) {
        try w.writeAll("<div class=\"tp-board-empty\"><p>");
        try escape.writeXml(w, review_thermal.scenarioNote(v.scenarios));
        try w.writeAll("</p></div></section>");
        return;
    }
    try writeBoardLegend(w, v);
    try w.writeAll("<div class=\"tp-board-stage\" id=\"tp-board-stage\">");
    try w.writeAll("<iframe id=\"tp-frame\" title=\"Heat field over the board\" src=\"/pcb-layout/");
    try writeUrlEncoded(w, v.name);
    try w.print(
        "?embed=1&amp;review=1&amp;drc=0&amp;thermal=1&amp;scenario={s}&amp;ambient={d}",
        .{ @tagName(v.scenario), v.ambient_c },
    );
    // The frame renders — and its overlay solves — the SAME board these tables
    // report, so a comparison never paints one layout under another's numbers.
    try writeLayoutParam(w, v, false);
    try w.writeAll("\"></iframe>");
    try w.writeAll("<div class=\"tp-loading\" id=\"tp-heat-loading\" hidden>Solving…</div>");
    try w.writeAll("</div></section>");
}

/// The board controls strip: 2D faces plus the physical 3D test setup, the
/// colour ramp and ambient, the hotspot readout, and the two switches that only
/// change what is DRAWN (range, label chips, wash opacity).
///
/// The scale starts at 25–125 °C. Its client keeps a valid manual range in the
/// URL and sends it to the overlay, which recolours its cached field in place.
fn writeBoardLegend(w: *std.Io.Writer, v: View) std.Io.Writer.Error!void {
    try w.writeAll("<div class=\"tp-board-controls\">");
    try w.writeAll("<div class=\"tp-face\" role=\"group\" aria-label=\"Board view\">");
    try w.writeAll("<span>View</span><button type=\"button\" id=\"tp-face-top\" data-board-side=\"top\" data-board-view=\"top\" class=\"on\" aria-pressed=\"true\">Top</button>");
    try w.writeAll("<button type=\"button\" id=\"tp-face-bottom\" data-board-side=\"bottom\" data-board-view=\"bottom\" aria-pressed=\"false\">Bottom</button>");
    try w.writeAll("<button type=\"button\" id=\"tp-view-3d\" data-board-view=\"3d\" aria-pressed=\"false\" title=\"Orbit the physical board, components, heatsink, and cooling fan\">3D setup</button></div>");
    try w.writeAll("<div class=\"tp-legend\" aria-label=\"Temperature scale\">");
    try w.writeAll("<label class=\"tp-scale-bound\"><input type=\"number\" id=\"tp-scale-min\" " ++
        "step=\"1\" value=\"25\" aria-label=\"Scale minimum temperature\" aria-invalid=\"false\"> °C</label>");
    try w.writeAll("<span class=\"tp-ramp\"></span>");
    try w.writeAll("<label class=\"tp-scale-bound\"><input type=\"number\" id=\"tp-scale-max\" " ++
        "step=\"1\" value=\"125\" aria-label=\"Scale maximum temperature\" aria-invalid=\"false\"> °C</label></div>");
    try writeAmbientControl(w, v);
    try w.writeAll("<span class=\"tp-hotspot\" id=\"tp-hotspot\"></span>");
    try w.writeAll("<label class=\"tp-switch\"><input type=\"checkbox\" id=\"tp-labels\"> All labels</label>");
    try w.writeAll("<label class=\"tp-switch\">Wash <input type=\"range\" id=\"tp-opacity\" " ++
        "min=\"20\" max=\"100\" step=\"5\" value=\"80\"></label>");
    try w.writeAll("</div>");
}

/// The ambient-dependent tables: the cooling ladder, one per-part table per
/// scenario (all but the selected hidden), and the coverage footer.
fn writeTablesBlock(w: *std.Io.Writer, alloc: std.mem.Allocator, v: View) RenderError!void {
    try w.writeAll("<div id=\"tp-tables\">");
    if (v.scenarios.ladder) |ladder| {
        try writeLadder(w, alloc, v, ladder);
        for (ladder.rows) |row| try writeScenarioParts(w, alloc, v, row);
    } else {
        try writeHint(w, "", review_thermal.scenarioNote(v.scenarios));
        try writeScreenedParts(w, alloc, v);
    }
    try writeCompare(w, alloc, v);
    try writeCoverage(w, v);
    try w.writeAll("</div>");
}

/// The four-rung ladder. The selected rung is marked, and every row is a
/// selector for its own scenario — the same action the segmented picker takes,
/// so a reader can drive the page from whichever they looked at first.
fn writeLadder(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    v: View,
    ladder: thermal_scenarios.Ladder,
) RenderError!void {
    try w.print(
        "<section class=\"tp-sect\"><h2>Cooling scenarios</h2><p class=\"tp-hint\">Each part's heat is " ++
            "spread over the placed board and read back at {d:.0} °C ambient.</p><div class=\"tp-scroll\">" ++
            "<table class=\"tp-table\"><thead><tr><th>Scenario</th><th>Hottest part</th><th>Tj (°C)</th>" ++
            "<th>Max ambient (°C)</th><th>Limited by</th></tr></thead><tbody id=\"tp-ladder\">",
        .{ladder.ambient_c},
    );
    for (ladder.rows) |row| {
        const c = try review_thermal.scenarioCells(alloc, ladder, row);
        try w.print("<tr class=\"tp-lrow{s}\" data-scenario=\"{s}\" tabindex=\"0\">", .{
            if (row.scenario == v.scenario) " sel" else "",
            @tagName(row.scenario),
        });
        for ([_][]const u8{ c.scenario, c.hottest, c.tj, c.max_ambient, c.limiting }) |cell| {
            try w.writeAll("<td>");
            try escape.writeXml(w, cell);
            try w.writeAll("</td>");
        }
        try w.writeAll("</tr>");
    }
    try w.writeAll("</tbody></table></div></section>");
}

/// One scenario's per-part table, hottest junction first. Hidden unless it is
/// selected: every available rung is in the document, so switching is a class
/// change rather than a solve.
fn writeScenarioParts(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    v: View,
    row: thermal_scenarios.Row,
) RenderError!void {
    try w.print("<section class=\"tp-sect tp-parts\" data-scenario=\"{s}\"{s}><h2>Parts</h2>", .{
        @tagName(row.scenario),
        if (row.scenario == v.scenario) "" else " hidden",
    });
    if (!row.converged) try writeHint(w, "", "This scenario hit the solver's iteration ceiling — read its numbers as indicative only.");
    if (row.cooling.heatsink.interface == .package_tops) {
        try w.print("<p class=\"tp-hint\">The plate contacts {d} powered package lid{s} through declared θJC(top).", .{
            row.cooling.heatsink.package_contacts,
            if (row.cooling.heatsink.package_contacts == 1) "" else "s",
        });
        if (row.cooling.heatsink.missing_theta_jc_top > 0) try w.print(
            " {d} covered powered package{s} lack directional θJC(top) and receive no direct heatsink credit.",
            .{ row.cooling.heatsink.missing_theta_jc_top, if (row.cooling.heatsink.missing_theta_jc_top == 1) "" else "s" },
        );
        if (row.cooling.heatsink.temperature_c) |temperature| try w.print(" Shared plate: {d:.1} °C.", .{temperature});
        try w.writeAll("</p>");
    } else if (row.cooling.heatsink.interface == .board_face) {
        try w.writeAll("<p class=\"tp-hint\">The thermal pad contacts the bare PCB face and conducts into one shared heatsink plate.</p>");
    }
    try w.writeAll("<div class=\"tp-scroll\"><table class=\"tp-table\"><thead><tr><th>Ref</th><th>Component</th>" ++
        "<th>P (W)</th><th>θJA (°C/W)</th><th>Path</th><th>Board (°C)</th><th>Tj (°C)</th><th>Margin (°C)</th>" ++
        "<th>Max ambient (°C)</th><th>Cross-probe</th></tr></thead><tbody>");
    const sorted = try alloc.dupe(thermal_scenarios.PartRow, row.parts);
    std.mem.sort(thermal_scenarios.PartRow, sorted, {}, hotterFirst);
    for (sorted) |part| try writeScenarioPartRow(w, alloc, v, part);
    try w.writeAll("</tbody></table></div></section>");
}

fn writeScenarioPartRow(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    v: View,
    part: thermal_scenarios.PartRow,
) RenderError!void {
    const screened = screenedRow(v.bt, part.ref);
    const c = try review_thermal.cells(alloc, screened orelse .{ .ref_des = part.ref, .component = "" });
    const margin = marginOf(screened, part.tj_c);
    try w.print("<tr class=\"tp-prow{s}\" data-ref=\"", .{if (overLimit(margin)) " tp-over" else ""});
    try escape.writeXml(w, part.ref);
    try w.writeAll("\"><td><code>");
    try escape.writeXml(w, part.ref);
    try w.writeAll("</code></td><td>");
    try escape.writeXml(w, c.component);
    try w.writeAll("</td>");
    for ([_][]const u8{ c.power, c.theta }) |cell| {
        try w.writeAll("<td>");
        try escape.writeXml(w, cell);
        try w.writeAll("</td>");
    }
    try w.writeAll("<td>");
    try escape.writeXml(w, junctionPathLabel(part.junction_path));
    try w.print("</td><td>{d:.1}</td><td>", .{part.board_c});
    try writeDeg(w, part.tj_c);
    if (part.jb_estimated and part.tj_c != null) try w.writeAll(" <span class=\"tp-est\">est.</span>");
    try w.writeAll("</td><td>");
    try writeDeg(w, margin);
    try w.writeAll("</td><td>");
    try writeDeg(w, part.max_ambient_c);
    try w.writeAll("</td>");
    try writeCrossProbe(w, v, part.ref);
    try w.writeAll("</tr>");
}

fn junctionPathLabel(path: thermal_scenarios.JunctionPath) []const u8 {
    return switch (path) {
        .board => "Board",
        .package_top => "θJC top → plate",
        .package_bottom => "θJC bottom → PCB",
        .package_top_missing => "Board (θJC top missing)",
    };
}

/// The lumped screen's own table, shown when there is no ladder to show one
/// per scenario. Same columns minus the board temperature, which only the
/// spread field can compute.
fn writeScreenedParts(w: *std.Io.Writer, alloc: std.mem.Allocator, v: View) RenderError!void {
    if (v.bt.parts.len == 0) return;
    try w.writeAll("<section class=\"tp-sect tp-parts\" data-scenario=\"natural\"><h2>Parts</h2>" ++
        "<div class=\"tp-scroll\"><table class=\"tp-table\"><thead><tr><th>Ref</th><th>Component</th>" ++
        "<th>P (W)</th><th>θJA (°C/W)</th><th>Tj (°C)</th><th>Margin (°C)</th>" ++
        "<th>Max ambient (°C)</th><th>Cross-probe</th></tr></thead><tbody>");
    const sorted = try alloc.dupe(thermal.PartThermal, v.bt.parts);
    std.mem.sort(thermal.PartThermal, sorted, {}, screenedHotterFirst);
    for (sorted) |row| {
        const c = try review_thermal.cells(alloc, row);
        try w.print("<tr class=\"tp-prow{s}\" data-ref=\"", .{if (overLimit(row.result.margin_c)) " tp-over" else ""});
        try escape.writeXml(w, row.ref_des);
        try w.writeAll("\"><td><code>");
        try escape.writeXml(w, c.ref_des);
        try w.writeAll("</code></td>");
        for ([_][]const u8{ c.component, c.power, c.theta, c.tj, c.margin, c.max_ambient }) |cell| {
            try w.writeAll("<td>");
            try escape.writeXml(w, cell);
            try w.writeAll("</td>");
        }
        try writeCrossProbe(w, v, row.ref_des);
        try w.writeAll("</tr>");
    }
    try w.writeAll("</tbody></table></div></section>");
}

// ── Layout comparison ─────────────────────────────────────────────────

/// The comparison panel: every saved layout of this design in one table, so the
/// question "is this placement worth anything thermally" has an answer in
/// degrees.
///
/// Two saved layouts of one design are two different boards for heat — the same
/// parts sit in different places, over different pours, with different via
/// stitching under their lands — and nothing else on this page says by how much.
/// The row for the board on screen is filled by the server (that solve is
/// already in hand); every other row is a whole second solve of a whole second
/// board, so it arrives EMPTY and is filled one at a time on request. Fifty
/// saved layouts are fifty solves: the reader starts the sweep, watches it, and
/// stops it.
///
/// Hidden when there is nothing to compare — one board is not a comparison.
fn writeCompare(w: *std.Io.Writer, alloc: std.mem.Allocator, v: View) RenderError!void {
    if (compareRowCount(v) < 2) return;
    try w.writeAll("<section class=\"tp-sect tp-compare\"><details id=\"tp-compare\"");
    if (v.compare) try w.writeAll(" open");
    try w.print("><summary>Compare layouts <span class=\"tp-count\">{d} boards</span></summary>", .{compareRowCount(v)});
    try w.print(
        "<p class=\"tp-hint\">Every row is a full solve of that saved board — its own poses, its own " ++
            "copper — at {d:.0} °C ambient on the selected scenario. Δ is against the board on screen; " ++
            "negative is cooler. Rows are solved one at a time because each one costs a board solve.</p>",
        .{v.ambient_c},
    );
    try w.writeAll("<div class=\"tp-cbar\"><button type=\"button\" class=\"tp-cgo\" id=\"tp-cgo\">Solve all</button>");
    try w.writeAll("<span class=\"tp-cprog\" id=\"tp-cprog\" role=\"status\"></span></div>");
    try w.writeAll("<div class=\"tp-scroll\"><table class=\"tp-table tp-ctable\"><thead><tr><th>Layout</th>" ++
        "<th>Parts</th><th>Copper</th><th>Hottest part</th><th>Tj (°C)</th><th>Δ (°C)</th>" ++
        "<th>Max ambient (°C)</th><th>Limited by</th></tr></thead><tbody id=\"tp-crows\">");
    // The default board first — it is the one every other surface of this
    // design reports on, so it is the row a reader reads the others against.
    if (starredLayout(v.layouts) == null) try writeCompareRow(w, alloc, v, null);
    for (v.layouts) |l| try writeCompareRow(w, alloc, v, l);
    try w.writeAll("</tbody></table></div></details></section>");
}

/// How many boards the panel would list: every saved layout, plus the generated
/// default board when no layout is starred (a starred layout IS the default
/// board, and listing it twice would invite comparing a board with itself).
fn compareRowCount(v: View) usize {
    return v.layouts.len + @intFromBool(starredLayout(v.layouts) == null);
}

/// One comparison row. `l` null is the design's generated default board.
///
/// The free metadata — part count, saved copper — is printed immediately: it
/// comes off the sidecar the page already read, and it is half of why two
/// layouts run differently. The temperatures are the expensive half.
fn writeCompareRow(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    v: View,
    l: ?pcb_layout_page.SavedLayout,
) RenderError!void {
    const shown = isShownBoard(v, l);
    try w.writeAll("<tr class=\"tp-crow");
    if (shown) try w.writeAll(" sel");
    try w.writeAll("\" data-layout=\"");
    if (l) |sl| try escape.writeXml(w, sl.name);
    try w.writeAll("\"><td class=\"tp-cname\">");
    if (l) |sl| {
        if (sl.default) try w.writeAll("★ ");
        try escape.writeXml(w, sl.name);
        if (sl.rough) try w.writeAll(" <span class=\"tp-badge\">rough</span>");
    } else {
        try w.writeAll("Default board <span class=\"tp-badge\">generated</span>");
    }
    if (shown) {
        try w.writeAll(" <span class=\"tp-badge tp-badge-on\">shown</span>");
    } else {
        try writeShowLink(w, v, if (l) |sl| sl.name else null);
    }
    try w.writeAll("</td><td>");
    if (l) |sl| try w.print("{d}", .{sl.parts.len}) else try w.writeAll(review_thermal.dash);
    try w.writeAll("</td>");
    try writeCopperCell(w, l);
    if (!shown) {
        // Deliberately not solved on page load: see `writeCompare`.
        try w.writeAll("<td class=\"tp-cfill\" colspan=\"5\">click to solve</td></tr>");
        return;
    }
    const filled = fillShownRow(w, alloc, v) catch |e| return e;
    if (!filled) try writeNoteCell(w, review_thermal.scenarioNote(v.scenarios));
    try w.writeAll("</tr>");
}

/// The shown board's own cells, taken from the ladder the page already built —
/// never a second solve, so the compare table and the ladder above it cannot
/// disagree about the board they are both describing. False when this board has
/// no ladder (the caller prints the reason instead).
fn fillShownRow(w: *std.Io.Writer, alloc: std.mem.Allocator, v: View) RenderError!bool {
    const ladder = v.scenarios.ladder orelse return false;
    const row = rowFor(ladder, v.scenario) orelse return false;
    // Null delta: this row IS the baseline, and "0.0" would read as a measured
    // difference rather than the definition of the column.
    try writeSolvedCells(w, alloc, ladder, row, null);
    return true;
}

/// Whether `l` (null = the generated default board) is the board on screen.
fn isShownBoard(v: View, l: ?pcb_layout_page.SavedLayout) bool {
    const sl = l orelse return v.layout == null and starredLayout(v.layouts) == null;
    if (v.layout) |cur| return std.mem.eql(u8, cur, sl.name);
    return sl.default;
}

/// The five solved cells of a comparison row: the ladder's own cells for this
/// board, plus its difference from the board on screen.
fn writeSolvedCells(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    ladder: thermal_scenarios.Ladder,
    row: thermal_scenarios.Row,
    delta: ?f64,
) RenderError!void {
    const c = try review_thermal.scenarioCells(alloc, ladder, row);
    try writeTextCell(w, c.hottest);
    try writeTextCell(w, c.tj);
    try w.print("<td class=\"{s}\">", .{deltaClass(delta)});
    try writeDelta(w, delta);
    try w.writeAll("</td>");
    try writeTextCell(w, c.max_ambient);
    try writeTextCell(w, c.limiting);
}

fn writeTextCell(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("<td>");
    try escape.writeXml(w, text);
    try w.writeAll("</td>");
}

/// The row's whole cell span, carrying the sentence saying why this board has
/// no temperatures — a layout that was deleted since the page loaded, or one
/// that places nothing.
fn writeNoteCell(w: *std.Io.Writer, note: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("<td class=\"tp-cnote\" colspan=\"5\">");
    try escape.writeXml(w, note);
    try w.writeAll("</td>");
}

/// The saved copper standing on a layout — the other half of why two placements
/// of one design run at different temperatures, and free to print (it is a
/// count off the sidecar, not a solve).
fn writeCopperCell(w: *std.Io.Writer, l: ?pcb_layout_page.SavedLayout) std.Io.Writer.Error!void {
    try w.writeAll("<td>");
    if (l) |sl| {
        if (sl.routes) |r| {
            try w.print("{d} tracks · {d} vias", .{ r.tracks.len, r.vias.len });
        } else try w.writeAll("no saved copper");
    } else try w.writeAll(review_thermal.dash);
    try w.writeAll("</td>");
}

/// The link that makes another layout the shown board, carrying the rung, the
/// ambient and the open panel across — a server-rendered href, so the table is
/// navigable with no client at all.
fn writeShowLink(w: *std.Io.Writer, v: View, layout: ?[]const u8) std.Io.Writer.Error!void {
    try w.writeAll(" <a class=\"tp-cshow\" href=\"/thermal/");
    try writeUrlEncoded(w, v.name);
    try w.print("?scenario={s}&amp;ambient={d}&amp;compare=1", .{ @tagName(v.scenario), v.ambient_c });
    if (layout) |l| {
        try w.writeAll("&amp;layout=");
        try writeUrlEncoded(w, l);
    }
    try w.writeAll("\">show</a>");
}

/// Which way a layout moved the peak junction: cooler, hotter, or too close to
/// call. The threshold is a tenth of a degree — the resolution the cell itself
/// prints at, so no cell is ever coloured for a difference it does not show.
fn deltaClass(delta: ?f64) []const u8 {
    const d = delta orelse return "";
    if (d <= -0.05) return "tp-cool";
    if (d >= 0.05) return "tp-hot";
    return "";
}

/// A signed difference in °C. Zig's formatter has no sign flag, and an unsigned
/// "3.2" in a column of differences reads as a rise either way.
fn writeDelta(w: *std.Io.Writer, delta: ?f64) std.Io.Writer.Error!void {
    const d = delta orelse return w.writeAll(review_thermal.dash);
    if (d > 0) try w.writeByte('+');
    try w.print("{d:.1}", .{d});
}

/// What one comparison row is asking for: a board, the board it is measured
/// against, and the rung and ambient both are read at.
const RowRequest = struct {
    /// The saved layout this row is FOR. Not canonicalized past the starred
    /// name: a row is a claim about a specific layout, and answering an unknown
    /// one with the default board's numbers is a lie the reader cannot see.
    layout: ?[]const u8,
    /// The board on screen, which the difference is against (null = default).
    base: ?[]const u8,
    scenario: thermal_scenarios.Scenario,
    ambient_c: f64,
};

/// `?row=<layout>` — the five solved cells of one comparison row.
///
/// A whole board solve, answered as bare `<td>`s the client swaps into the row
/// it already has. The BASELINE it differences against is the board on screen,
/// whose solve the page just made, so that half is a cache read rather than a
/// second relaxation.
///
/// A board with no ladder — a layout deleted since the page loaded, one that
/// places nothing — answers with the sentence saying so, spanning the row.
fn renderCompareRow(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    bt: thermal.BoardThermal,
    r: RowRequest,
) RenderError![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    const mine = try thermal_api.scenariosFor(alloc, project_dir, name, bt, r.ambient_c, r.layout);
    const ladder = mine.ladder orelse {
        try writeNoteCell(w, review_thermal.scenarioNote(mine));
        return aw.written();
    };
    const row = rowFor(ladder, r.scenario) orelse {
        try writeNoteCell(w, review_thermal.scenarioNote(mine));
        return aw.written();
    };
    const base = try thermal_api.scenariosFor(alloc, project_dir, name, bt, r.ambient_c, r.base);
    try writeSolvedCells(w, alloc, ladder, row, deltaTj(row, peakTj(base, r.scenario)));
    return aw.written();
}

/// How much hotter this board's peak junction runs than the baseline's. Null
/// whenever either side has no junction figure — a difference computed against
/// a missing number is worse than a dash.
fn deltaTj(row: thermal_scenarios.Row, base_tj: ?f64) ?f64 {
    const base = base_tj orelse return null;
    const mine = (row.hottest() orelse return null).tj_c orelse return null;
    return mine - base;
}

/// The two cross-probe links every part row carries: the board and the drawing,
/// spelled the way the existing viewers spell them (`?focus=` on the PCB page,
/// `#comp-<ref>` on the schematic, which resolves exact-then-leaf).
fn writeCrossProbe(w: *std.Io.Writer, v: View, ref: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("<td class=\"tp-links\"><a href=\"/pcb-layout/");
    try writeUrlEncoded(w, v.name);
    try w.writeAll("?focus=");
    try writeUrlEncoded(w, ref);
    try writeLayoutParam(w, v, false);
    try w.writeAll("\">PCB →</a><a href=\"");
    try w.writeAll(if (v.is_module) "/modules/" else "/schematics/");
    try writeUrlEncoded(w, v.name);
    try w.writeAll("#comp-");
    try writeUrlEncoded(w, ref);
    try w.writeAll("\">Schematic →</a></td>");
}

/// What the screen actually saw, and what it deliberately does not model.
fn writeCoverage(w: *std.Io.Writer, v: View) std.Io.Writer.Error!void {
    try w.writeAll("<section class=\"tp-sect tp-coverage\" id=\"tp-coverage\"><h2>Coverage</h2>");
    try writeHint(w, "Coverage: ", v.lines.coverage);
    const skipped = skippedRefs(v.scenarios);
    if (skipped.len > 0) {
        try w.writeAll("<p class=\"tp-hint\">Not placed, so left out of the spread field: ");
        for (skipped, 0..) |ref, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll("<code>");
            try escape.writeXml(w, ref);
            try w.writeAll("</code>");
        }
        try w.writeAll(".</p>");
    }
    if (v.scenarios.ladder) |ladder| {
        for (ladder.rows) |row| {
            if (row.scenario != .fan or row.cooling.fan.model.len == 0) continue;
            try w.writeAll("<p class=\"tp-hint\"><strong>Fan model:</strong> ");
            try escape.writeXml(w, row.cooling.fan.model);
            try w.print(
                "; {d:.4} m³/s assumed installed flow, {d:.1} m/s area-average velocity at the PCB, " ++
                    "{d:.1} Pa remaining on the endpoint P–Q approximation, aimed at the {s} face.</p>",
                .{ row.cooling.fan.operating_flow_m3_s, row.cooling.fan.velocity_m_s, row.cooling.fan.estimated_pressure_pa, if ((row.cooling.fan.face orelse .top) == .top) "top" else "bottom" },
            );
            break;
        }
    }
    try writeHint(w, "", model_caveat);
    try w.writeAll("</section>");
}

/// The model's own boundaries, stated on the page that shows its numbers so
/// nobody mistakes a screening estimate for a qualification.
const model_caveat =
    "Screening-grade model: a free-standing board in still or moving air, one junction per part, " ++
    "no enclosure and no conduction into a chassis. It reads the declared stackup's thickness and " ++
    "copper weights, derates each cell by the pour actually covering it, blocks convection off the " ++
    "face a part body sits on, and shortens a part's path into the board by the thermal vias under " ++
    "its own land. Still one sheet in the plane of the board: the two faces are not solved as " ++
    "separate layers, air does not carry heat between neighbouring parts, the fan case uses an area-average normal jet " ++
    "rather than CFD (no hub shadow, swirl, enclosure recirculation or component wake), and nothing here is " ++
    "transient. Read it as a ranking of hot spots and a first cut at the cooling this board needs, " ++
    "not as a thermal qualification.";

/// Every powered part the ladder could not place. Identical across the rungs
/// (the join is scenario-independent), so the first rung answers for all four.
fn skippedRefs(answer: thermal_scenarios.Answer) []const []const u8 {
    const ladder = answer.ladder orelse return &.{};
    if (ladder.rows.len == 0) return &.{};
    return ladder.rows[0].skipped;
}

/// The lumped screen's row for `ref`, or null when the ladder names a part the
/// screen has no row for.
fn screenedRow(bt: thermal.BoardThermal, ref: []const u8) ?thermal.PartThermal {
    for (bt.parts) |row| {
        if (std.mem.eql(u8, row.ref_des, ref)) return row;
    }
    return null;
}

/// Headroom to the junction limit at the scenario's own junction temperature.
/// Null whenever either half is unknown — a margin computed against a guess is
/// worse than a dash.
fn marginOf(screened: ?thermal.PartThermal, tj_c: ?f64) ?f64 {
    const limit = (screened orelse return null).limits.tj_max orelse return null;
    return limit - (tj_c orelse return null);
}

fn overLimit(margin: ?f64) bool {
    return if (margin) |m| m < 0 else false;
}

fn hotterFirst(_: void, a: thermal_scenarios.PartRow, b: thermal_scenarios.PartRow) bool {
    return (a.tj_c orelse a.board_c) > (b.tj_c orelse b.board_c);
}

fn screenedHotterFirst(_: void, a: thermal.PartThermal, b: thermal.PartThermal) bool {
    const cold = -std.math.inf(f64);
    return (a.result.tj_at_ambient orelse cold) > (b.result.tj_at_ambient orelse cold);
}

fn writeDeg(w: *std.Io.Writer, v: ?f64) std.Io.Writer.Error!void {
    if (v) |x| try w.print("{d:.1}", .{x}) else try w.writeAll(review_thermal.dash);
}

/// Which status-pill palette a verdict borrows — the review panel's own split,
/// restated here because the page has its own (dark, standalone) stylesheet.
fn pillClass(v: thermal.Verdict) []const u8 {
    return switch (v) {
        .passive_ok => "pass",
        .needs_airflow, .needs_heatsink => "warn",
        .over_limit => "fail",
        .insufficient_data => "info",
    };
}

fn verdictLabel(v: thermal.Verdict) []const u8 {
    return switch (v) {
        .passive_ok => "PASSIVE OK",
        .needs_airflow => "AIRFLOW",
        .needs_heatsink => "HEATSINK",
        .over_limit => "OVER LIMIT",
        .insufficient_data => "NO DATA",
    };
}

fn writeUrlEncoded(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| {
        const safe = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~';
        if (safe) try w.writeByte(c) else try w.print("%{X:0>2}", .{c});
    }
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

/// A project with a design that dissipates, a design that does not, and a
/// module — enough to exercise both resolution paths and both page shapes
/// without depending on the repo's own `projects/designs`.
fn writeFixture(dir: std.Io.Dir) !void {
    try dir.createDirPath(std.testing.io, "lib/components");
    try dir.createDirPath(std.testing.io, "lib/modules");
    try dir.createDirPath(std.testing.io, "src");
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/hot-ic.sexp", .data =
        \\(component "hot-ic"
        \\  (description "test regulator with a declared thermal envelope")
        \\  (footprint "SOT-223")
        \\  (thermal (theta-ja 60) (tj-max 150) (operating -40 85)))
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
    try dir.writeFile(std.testing.io, .{ .sub_path = "src/cooled-heater.sexp", .data =
        \\(import hot-ic)
        \\
        \\(design-block "Cooled Heater Board"
        \\  (board (size 40 20)
        \\    (heatsink (rect 0 0 40 20) (side bottom) (target "" "U1")
        \\      (material aluminum_6063) (base-mm 2) (fin-height-mm 10)
        \\      (fin-thickness-mm 1) (fin-gap-mm 1.5) (fin-axis length)
        \\      (pad-thickness-mm 0.5) (pad-k-w-mk 6))
        \\    (fan (model "9A0812G4D011") (rect -20 -30 80 80) (side top)
        \\      (distance-mm 10) (free-air-flow-m3-s 0.025)
        \\      (max-static-pressure-pa 80.4) (operating-flow-fraction 0.6)))
        \\  (instance "U1" hot-ic
        \\    (pin 1 "VIN")
        \\    (pin 2 "GND")
        \\    (power 1.0)))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "src/quiet.sexp", .data =
        \\(import hot-ic)
        \\
        \\(design-block "Quiet Board"
        \\  (instance "U1" hot-ic
        \\    (pin 1 "VIN")
        \\    (pin 2 "GND")))
    });
    // Two saved layouts of the heater, neither starred: the design's default
    // board stays the generated one, so the page has three boards to compare
    // and a picker with a real choice in it.
    try dir.writeFile(std.testing.io, .{ .sub_path = "src/heater.layouts.json", .data =
        \\{"rev":1,"layouts":[
        \\{"name":"tight","kind":"manual","ts":2,"parts":[{"ref":"U1","x":10,"y":10,"rot":0}]},
        \\{"name":"spread","kind":"manual","ts":1,"parts":[{"ref":"U1","x":40,"y":25,"rot":0}]}]}
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/modules/hot-mod.sexp", .data =
        \\(import hot-ic)
        \\
        \\(defmodule hot-mod ((part hot-ic))
        \\  (design-block "Hot Module"
        \\    (instance "U1" part
        \\      (pin 1 "VIN")
        \\      (pin 2 "GND")
        \\      (power 0.5))))
    });
}

/// Drive the real handler and return the status plus a copy of the body.
fn serve(alloc: std.mem.Allocator, project: []const u8, name: []const u8, q: []const [2][]const u8) !handler_probe.Served {
    return handler_probe.drive(alloc, project, name, q, thermalPage);
}

/// True when every needle is somewhere in the haystack — the assertion a
/// marker list wants, without a loop per list in the test body.
fn containsAll(hay: []const u8, needles: []const []const u8) bool {
    for (needles) |n| {
        if (std.mem.indexOf(u8, hay, n) == null) return false;
    }
    return true;
}

fn fixtureProject(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]const u8 {
    try writeFixture(tmp.dir);
    return tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
}

// spec: serve/thermal-page - GET /thermal/:name renders the verdict headline, the scenario picker, the cooling ladder, per-part rows, the coverage footer and the PDF and JSON links
test "the thermal page carries its verdict, controls, tables and exports" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp);

    const got = try serve(alloc, project, "heater", &.{});
    try testing.expectEqual(@as(u16, 200), got.status);
    const html = got.body;

    try testing.expect(std.mem.indexOf(u8, html, "<nav class=\"navbar\" aria-label=\"Primary\"><a href=\"/\" class=\"brand\">Netlisp</a>") != null);
    // The headline is review_thermal's own pill and sentence, never a second
    // opinion computed here.
    try testing.expect(std.mem.indexOf(u8, html, "id=\"tp-verdict\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "class=\"tp-pill tp-") != null);
    // The segmented picker offers every rung of the ladder, heatsink included.
    for ([_][]const u8{ "natural", "airflow_1ms", "airflow_2ms", "heatsink" }) |tag| {
        try testing.expect(std.mem.indexOf(u8, html, tag) != null);
    }
    try testing.expect(std.mem.indexOf(u8, html, "id=\"tp-seg\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "id=\"tp-ambient\"") != null);
    // The board frame opens on the same scenario and ambient the tables read.
    try testing.expect(std.mem.indexOf(u8, html, "scenario=natural&amp;ambient=25") != null);
    // The ladder, one per-part table per rung, and the coverage footer.
    try testing.expect(std.mem.indexOf(u8, html, "id=\"tp-ladder\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "data-ref=\"U1\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "id=\"tp-coverage\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "power known for") != null);
    try testing.expect(std.mem.indexOf(u8, html, "Screening-grade model") != null);
    // Both cross-probe links, spelled the way the two viewers read them.
    try testing.expect(std.mem.indexOf(u8, html, "/pcb-layout/heater?focus=U1") != null);
    try testing.expect(std.mem.indexOf(u8, html, "/schematics/heater#comp-U1") != null);
    // …and the two read-only exports.
    try testing.expect(std.mem.indexOf(u8, html, "/api/schematic-pdf/heater") != null);
    try testing.expect(std.mem.indexOf(u8, html, "/api/thermal/heater?ambient=25") != null);
}

/// A View carrying only what the tab bar reads, for the tests that check the
/// bar alone: the screening, the ladder and the prose belong to a solve the
/// navigation never touches.
fn navView(name: []const u8, is_module: bool) View {
    return .{
        .name = name,
        .is_module = is_module,
        .ambient_c = 25,
        .scenario = .natural,
        .bt = .{ .ambient_c = 25 },
        .scenarios = .{},
        .lines = .{ .verdict = "", .package = "", .ambient = "", .coverage = "", .hint = "" },
    };
}

// spec: serve/thermal-page - the Thermal tab is active on /thermal/:name and follows Assembly on the schematic, PCB and assembly headers
test "the thermal tab follows assembly and Review stays board scoped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var nav: std.Io.Writer.Allocating = .init(alloc);
    try writeNav(&nav.writer, navView("demo", false));
    const bar = nav.written();
    const assembly = std.mem.indexOf(u8, bar, ">Assembly</a>").?;
    const thermal_tab = std.mem.indexOf(u8, bar, "aria-current=\"page\">Thermal</a>").?;
    try testing.expect(assembly < thermal_tab);
    try testing.expect(std.mem.indexOf(u8, bar, "href=\"/review/demo\">Review</a>") != null);
    // A module has no Assembly surface, so its bar stops at 3D and Thermal.
    var mod: std.Io.Writer.Allocating = .init(alloc);
    try writeNav(&mod.writer, navView("power", true));
    try testing.expect(std.mem.indexOf(u8, mod.written(), "/assembly-debug/") == null);
    try testing.expect(std.mem.indexOf(u8, mod.written(), "/review/") == null);
    try testing.expect(std.mem.indexOf(u8, mod.written(), ">Thermal</a>") != null);
    var selected_view = navView("demo", false);
    selected_view.layout = "release-A";
    var selected: std.Io.Writer.Allocating = .init(alloc);
    try writeNav(&selected.writer, selected_view);
    try testing.expect(std.mem.indexOf(u8, selected.written(), "/review/demo?layout=release-A") != null);
    // The other three headers gained the same tab, each after their Assembly link.
    const heads = [_][]const u8{
        @embedFile("../render_html.zig"),
        @embedFile("pcb_layout_chrome.zig"),
        @embedFile("assembly_debug.zig"),
    };
    for (heads) |src| {
        const asm_at = std.mem.indexOf(u8, src, "Assembly</a>").?;
        const th_at = std.mem.indexOf(u8, src, "Thermal</a>").?;
        try testing.expect(asm_at < th_at);
        try testing.expect(std.mem.indexOf(u8, src, "/thermal/") != null);
    }
}

// spec: serve/thermal-page - GET /thermal/:name resolves a design or a bare lib/modules module and answers an unknown name with a 404 whose body is not HTML
test "the thermal page resolves a design, a module, and 404s anything else" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp);

    const design = try serve(alloc, project, "heater", &.{});
    try testing.expectEqual(@as(u16, 200), design.status);
    try testing.expect(std.mem.indexOf(u8, design.body, "Heater Board") != null);

    // A module resolves standalone through its parameter defaults, and its
    // schematic cross-probe points at the module viewer rather than /schematics.
    const module = try serve(alloc, project, "hot-mod", &.{});
    try testing.expectEqual(@as(u16, 200), module.status);
    try testing.expect(std.mem.indexOf(u8, module.body, "/modules/hot-mod#comp-") != null);

    const missing = try serve(alloc, project, "no-such-board", &.{});
    try testing.expectEqual(@as(u16, 404), missing.status);
    try testing.expect(!std.mem.startsWith(u8, missing.body, "<"));
    try testing.expect(std.mem.indexOf(u8, missing.body, "No design or module") != null);
}

// spec: serve/thermal-page - GET /thermal/:name?layout=<name> screens that saved layout and carries the choice into the board frame, the tab bar, the cross-probe links and the facts link
// spec: serve/thermal-page - a ?layout nobody saved falls back to the default board and says so rather than screening a board under the wrong name
test "the thermal page screens the saved layout it is asked for" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp);

    const got = try serve(alloc, project, "heater", &.{.{ "layout", "spread" }});
    try testing.expectEqual(@as(u16, 200), got.status);
    // The picker offers every saved board and holds the one on screen.
    try testing.expect(containsAll(got.body, &.{
        "id=\"tp-layout\"",
        "value=\"tight\"",
        "<option selected value=\"spread\">",
        "data-layout=\"spread\"",
    }));
    // Every link off this page names the same board. A tab, a frame or an
    // export that dropped the layout would quietly show a different one.
    try testing.expect(containsAll(got.body, &.{
        "/pcb-layout/heater?embed=1",
        "layout=spread",
        "/api/thermal/heater?ambient=25&amp;layout=spread",
    }));

    // A layout nobody saved: the page still answers, over the board it can
    // actually show, and says which board that is.
    const missing = try serve(alloc, project, "heater", &.{.{ "layout", "ghost" }});
    try testing.expectEqual(@as(u16, 200), missing.status);
    try testing.expect(std.mem.indexOf(u8, missing.body, "no saved layout named") != null);
    try testing.expect(std.mem.indexOf(u8, missing.body, "ghost") != null);
    try testing.expect(std.mem.indexOf(u8, missing.body, "data-layout=\"\"") != null);
}

// spec: serve/thermal-page - the page lists every saved layout of the design in one comparison table, filled only for the board on screen
// spec: serve/thermal-page - a design with only one board renders no comparison table
test "the compare table lists every board and solves only the one on screen" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp);

    const got = try serve(alloc, project, "heater", &.{.{ "compare", "1" }});
    try testing.expectEqual(@as(u16, 200), got.status);
    try testing.expect(containsAll(got.body, &.{
        "id=\"tp-crows\"",
        "3 boards",
        "Default board",
        "data-layout=\"tight\"",
        "data-layout=\"spread\"",
        "id=\"tp-cgo\"",
    }));
    // Exactly the two boards that are NOT on screen arrive unsolved: a page
    // load must not silently spend a board solve per saved layout.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, got.body, "tp-cfill"));

    // A module has no saved layouts at all, so there is nothing to compare and
    // no table pretending otherwise.
    const mod = try serve(alloc, project, "hot-mod", &.{});
    try testing.expectEqual(@as(u16, 200), mod.status);
    try testing.expect(std.mem.indexOf(u8, mod.body, "id=\"tp-compare\"") == null);
}

// spec: serve/thermal-page - GET /thermal/:name?row=<layout> answers one comparison row's cells alone, differenced against the board on screen
test "a comparison row is answered as cells and nothing else" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp);

    const row = try serve(alloc, project, "heater", &.{.{ "row", "tight" }});
    try testing.expectEqual(@as(u16, 200), row.status);
    // Cells, not a page: the client swaps these into a row it already has.
    try testing.expect(std.mem.startsWith(u8, row.body, "<td"));
    try testing.expect(std.mem.indexOf(u8, row.body, "tp-page") == null);
    // The hottest part of that board, and a difference against the board on
    // screen — the column that makes the table worth reading.
    try testing.expect(std.mem.indexOf(u8, row.body, "U1") != null);
    try testing.expectEqual(@as(usize, 5), std.mem.count(u8, row.body, "<td"));

    // A row for a layout nobody saved reports that, rather than answering with
    // the default board's temperatures under that name.
    const ghost = try serve(alloc, project, "heater", &.{.{ "row", "ghost" }});
    try testing.expectEqual(@as(u16, 200), ghost.status);
    try testing.expect(std.mem.indexOf(u8, ghost.body, "no saved layout") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, ghost.body, "<td"));
}

// spec: serve/thermal-page - the client solves comparison rows one at a time and can be stopped, and the embedded board frame paints the same layout the page names
test "the compare sweep is incremental and the board frame follows the layout" {
    const js = @embedFile("assets/thermal_page.js");
    // One fetch per row, each naming the board it is for, plus the sweep the
    // reader starts and stops. Solving every saved layout on page load would
    // freeze the tab on a design with fifty of them.
    try testing.expect(containsAll(js, &.{ "?row=", "tp-cgo", "sweeping", "unsolvedRows" }));
    // The picker is a navigation, not a partial swap: the frame, the image and
    // every link have to change together.
    try testing.expect(containsAll(js, &.{ "tp-layout", "layoutParam" }));

    // …and the frame's own field fetch carries the layout, so the picture and
    // the numbers are of one board.
    const overlay = @embedFile("assets/pcb_thermal.js");
    try testing.expect(std.mem.indexOf(u8, overlay, "\"&layout=\"") != null);
}

// spec: serve/thermal-page - a design with no cooling ladder renders the reason in place of the picker, the board frame and the ladder, and still lists the parts the lumped screen saw
test "a design with no ladder renders the reason instead of a broken image" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp);

    const got = try serve(alloc, project, "quiet", &.{});
    try testing.expectEqual(@as(u16, 200), got.status);
    const html = got.body;
    // No board at all — never an empty one under a heat legend, which would
    // read as "solved, and cold".
    try testing.expect(std.mem.indexOf(u8, html, "<img") == null);
    try testing.expect(std.mem.indexOf(u8, html, "<iframe") == null);
    try testing.expect(std.mem.indexOf(u8, html, "id=\"tp-scale-max\"") == null);
    try testing.expect(std.mem.indexOf(u8, html, "id=\"tp-seg\"") == null);
    try testing.expect(std.mem.indexOf(u8, html, "id=\"tp-ladder\"") == null);
    // The sentence saying why, and the lumped screen's own rows underneath it.
    try testing.expect(std.mem.indexOf(u8, html, "dissipation") != null);
    try testing.expect(std.mem.indexOf(u8, html, "data-ref=\"U1\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "id=\"tp-coverage\"") != null);
}

// spec: serve/thermal-page - ?ambient=NN screens the whole page at that ambient clamped to the control's range, and ?fragment=1 answers the verdict and table regions alone
test "the ambient parameter is clamped and the fragment answers the live regions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp);

    const warm = try serve(alloc, project, "heater", &.{.{ "ambient", "70" }});
    try testing.expectEqual(@as(u16, 200), warm.status);
    try testing.expect(std.mem.indexOf(u8, warm.body, "ambient=70") != null);
    try testing.expect(std.mem.indexOf(u8, warm.body, "value=\"70\"") != null);

    // Out of range is clamped, not refused: the control is a spinner a reader
    // can hold down, and the nearest ambient they asked about is still an answer.
    const clamped = try serve(alloc, project, "heater", &.{.{ "ambient", "9000" }});
    try testing.expectEqual(@as(u16, 200), clamped.status);
    try testing.expect(std.mem.indexOf(u8, clamped.body, "value=\"125\"") != null);
    // …and so is a value that is not a number at all.
    const junk = try serve(alloc, project, "heater", &.{.{ "ambient", "warm" }});
    try testing.expectEqual(@as(u16, 200), junk.status);
    try testing.expect(std.mem.indexOf(u8, junk.body, "value=\"25\"") != null);

    // The fragment is the two live regions and nothing else — no document, no
    // controls the reader may be typing into, no script tag.
    const frag = try serve(alloc, project, "heater", &.{ .{ "fragment", "1" }, .{ "ambient", "70" } });
    try testing.expectEqual(@as(u16, 200), frag.status);
    try testing.expect(std.mem.startsWith(u8, frag.body, "<section class=\"tp-verdict\""));
    try testing.expect(std.mem.indexOf(u8, frag.body, "id=\"tp-tables\"") != null);
    try testing.expect(std.mem.indexOf(u8, frag.body, "<!doctype") == null);
    try testing.expect(std.mem.indexOf(u8, frag.body, "id=\"tp-ambient\"") == null);
    try testing.expect(std.mem.indexOf(u8, frag.body, "<script") == null);
}

// spec: serve/thermal-page - ?scenario=<tag> opens the page on that rung with its own part table shown and the board frame opened on it
test "the scenario parameter selects the rung the page opens on" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp);

    const blown = try serve(alloc, project, "heater", &.{.{ "scenario", "airflow_2ms" }});
    try testing.expectEqual(@as(u16, 200), blown.status);
    try testing.expect(std.mem.indexOf(u8, blown.body, "scenario=airflow_2ms&amp;ambient=25") != null);
    try testing.expect(std.mem.indexOf(u8, blown.body, "data-scenario=\"airflow_2ms\" aria-pressed=\"true\"") != null);
    // The selected rung's table is the visible one; the other three are hidden.
    try testing.expect(std.mem.indexOf(u8, blown.body, "data-scenario=\"airflow_2ms\"><h2>Parts</h2>") != null);
    try testing.expect(std.mem.indexOf(u8, blown.body, "data-scenario=\"natural\" hidden>") != null);

    // A scenario word nothing recognises opens on still air rather than refusing.
    const typo = try serve(alloc, project, "heater", &.{.{ "scenario", "breeze" }});
    try testing.expectEqual(@as(u16, 200), typo.status);
    try testing.expect(std.mem.indexOf(u8, typo.body, "data-scenario=\"natural\" aria-pressed=\"true\"") != null);
}

// spec: serve/thermal-page - saved fan and heatsink assemblies can be independently included in or excluded from the active simulation without mutating their layout definitions
test "saved cooling assemblies render independent simulation toggles" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp);

    const combined = try serve(alloc, project, "cooled-heater", &.{.{ "scenario", "fan_heatsink" }});
    try testing.expectEqual(@as(u16, 200), combined.status);
    try testing.expect(containsAll(combined.body, &.{
        "<fieldset class=\"tp-cooling\">",
        "id=\"tp-use-fan\" type=\"checkbox\" checked",
        "id=\"tp-use-heatsink\" type=\"checkbox\" checked",
        "View and simulation only — the saved fan and heatsink stay in the layout.",
    }));

    const natural = try serve(alloc, project, "cooled-heater", &.{});
    try testing.expect(std.mem.indexOf(u8, natural.body, "id=\"tp-use-fan\" type=\"checkbox\" checked") == null);
    try testing.expect(std.mem.indexOf(u8, natural.body, "id=\"tp-use-heatsink\" type=\"checkbox\" checked") == null);
}

// spec: serve/thermal-page - thermal fan and heatsink controls stay synchronized between the scenario panel and 3D setup, selecting the matching simulation scenario and model visibility
test "thermal 3D cooling visibility controls drive the simulation scenario" {
    const client = @embedFile("assets/thermal_page.js");
    const overlay = @embedFile("assets/pcb_thermal.js");
    const viewer = @embedFile("assets/pcb_3d_viewer.js");

    // The 3D viewer reports both cooling switches to the thermal overlay, the
    // overlay forwards one complete cooling state across the frame boundary,
    // and the page selects the already-rendered matching scenario.
    try testing.expect(containsAll(viewer, &.{
        "function notifyThermalCooling(",
        "function notifyThermalReady(",
        "function syncThermalCooling(",
        "thermal.toggleCooling(kind, visible)",
        "thermal.coolingState()",
        "setCoolingVisibility: function",
        "thermal:3d-ready",
    }));
    try testing.expect(containsAll(overlay, &.{
        "function coolingState()",
        "function toggleCooling(",
        "thermal:cooling-toggle",
        "three.setCoolingVisibility",
    }));
    try testing.expect(containsAll(client, &.{
        "d.t === \"thermal:cooling-toggle\"",
        "d.t === \"thermal:3d-ready\"",
        "function coolingVisibilityPush()",
        "three.setCoolingVisibility(useFan, useHeatsink)",
        "tpSelect(coolingScenario())",
    }));

    // A scenario message can precede lazy WebGL initialization. Its two
    // visibility values must be retained before the `built` guard, or the
    // authored fan and heatsink appear until another scenario change occurs.
    const setter = std.mem.indexOf(u8, viewer, "setCoolingVisibility: function") orelse return error.TestUnexpectedResult;
    const fan_store = std.mem.indexOfPos(u8, viewer, setter, "layerVisible.fan = !!fan") orelse return error.TestUnexpectedResult;
    const built_guard = std.mem.indexOfPos(u8, viewer, setter, "if (!built) return") orelse return error.TestUnexpectedResult;
    try testing.expect(fan_store < built_guard);
}

// spec: serve/thermal-page - the page puts its panel beside a live board frame rather than a static heat image, embedding the read-only PCB viewer with the thermal overlay on
test "the page embeds the read-only board viewer instead of a heat image" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp);

    const got = try serve(alloc, project, "heater", &.{});
    try testing.expectEqual(@as(u16, 200), got.status);
    const html = got.body;

    // The panel-beside-board shape the assembly page uses, not a page-wide
    // column with a raster dropped into it.
    try testing.expect(std.mem.indexOf(u8, html, "class=\"tp-workspace\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "class=\"tp-panel\"") != null);
    try testing.expect(std.mem.indexOf(u8, html, "class=\"tp-board-pane\"") != null);

    // The board is the real viewer, embedded read-only with the overlay on —
    // so the reader gets its pan, zoom, layers and part tools, and the heat is
    // painted over actual copper rather than baked into a server-side PNG.
    const frame = std.mem.indexOf(u8, html, "id=\"tp-frame\"") orelse return error.NoFrame;
    const src_end = std.mem.indexOfPos(u8, html, frame, "></iframe>") orelse return error.NoFrame;
    const tag = html[frame..src_end];
    try testing.expect(std.mem.indexOf(u8, tag, "/pcb-layout/heater?embed=1") != null);
    try testing.expect(std.mem.indexOf(u8, tag, "review=1") != null);
    try testing.expect(std.mem.indexOf(u8, tag, "thermal=1") != null);
    // On this navigation-first read-only surface, an ordinary mouse drag pans
    // from empty board, a footprint or a pad. A stationary press still runs
    // through the existing inspection path via pan.tapi.
    const board_client = @embedFile("assets/pcb_board.js");
    try testing.expect(containsAll(board_client, &.{
        "THERMAL_REVIEW=PHYSICAL_REVIEW",
        "if(THERMAL_REVIEW&&ev.button===0)",
        "startPan(ev);pan.tapi=",
        "hoverCursor=THERMAL_REVIEW?\"grab\"",
    }));
    // DRC off: the overlay owns the board's colour, and a DRC layer painted
    // under a heat wash is unreadable in both directions.
    try testing.expect(std.mem.indexOf(u8, tag, "drc=0") != null);
    // …and it opens on the scenario and ambient the page is already showing,
    // so the first paint costs no message at all.
    try testing.expect(std.mem.indexOf(u8, tag, "scenario=natural") != null);
    try testing.expect(std.mem.indexOf(u8, tag, "ambient=25") != null);

    // Nothing left of the old static heat raster.
    try testing.expect(std.mem.indexOf(u8, html, "<img") == null);
    try testing.expect(std.mem.indexOf(u8, html, "pcb-png") == null);
}

// spec: serve/thermal-page - the thermal board view switches between the physical top and mirrored bottom faces without a new solve, shows temperature labels only for parts on the visible face, paints a same-face heatsink above the board and occludes an opposite-face heatsink behind it, and keeps the selected face in the page URL
test "the thermal board switches between physical top and bottom faces" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp);
    const html = (try serve(alloc, project, "heater", &.{})).body;
    try testing.expect(containsAll(html, &.{
        "id=\"tp-face-top\"",
        "id=\"tp-face-bottom\"",
        "data-board-side=\"top\"",
        "data-board-side=\"bottom\"",
    }));

    const client = @embedFile("assets/thermal_page.js");
    try testing.expect(containsAll(client, &.{
        "function boardSideSet(",
        "type: \"netlisp-pcb-orientation\"",
        "side: boardSide",
        "board_side",
        "tell({ side: boardSide })",
    }));
    const overlay = @embedFile("assets/pcb_thermal.js");
    try testing.expect(containsAll(overlay, &.{
        "!== view.side",
        "if (view.side === \"bottom\")",
        "ctx.scale(-1, 1)",
        "d.side === \"top\" || d.side === \"bottom\"",
    }));
    const board = @embedFile("assets/pcb_board.js");
    try testing.expect(containsAll(board, &.{
        "function heatsinkBehindBoard(s)",
        "if(heatsinkBehindBoard(s))return",
        "function paintRearHeatsink(ctx,k)",
        "paintRearHeatsink(c,k);paintPhysicalBoard(c,k)",
        "dragCacheDrop();drawBoardRect();paintSoon()",
    }));
}

// spec: serve/thermal-page - hovering the thermal board reports the interpolated temperature at the pointer from the same solved grid that paints the heat field
test "the thermal board reports its solved temperature under the pointer" {
    const overlay = @embedFile("assets/pcb_thermal.js");
    try testing.expect(containsAll(overlay, &.{
        "function gridTemperatureAt(x, y)",
        "g.rise_c[i]",
        "weighted / total",
        "boardSvg.getScreenCTM()",
        "temp.toFixed(1) + \" °C\"",
        "boardSvg.addEventListener(\"pointerleave\", probeHide)",
    }));
}

// spec: serve/thermal-page - thermal part labels start hidden, clicking an IC shows only that IC's reference and temperature, and the optional All labels control reveals every reported part on the visible face
test "thermal labels reveal only the clicked IC by default" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp);
    const html = (try serve(alloc, project, "heater", &.{})).body;
    try testing.expect(std.mem.indexOf(u8, html, "<input type=\"checkbox\" id=\"tp-labels\"> All labels") != null);

    const overlay = @embedFile("assets/pcb_thermal.js");
    try testing.expect(containsAll(overlay, &.{
        "labels: false",
        "selectedRef: \"\"",
        "if (view.labels || view.selectedRef) paintLabels(ctx)",
        "if (!view.labels && row.ref !== view.selectedRef) return",
        "typeof d.selectedRef === \"string\"",
        "painted: function ()",
        "paintedView.labels = view.labels",
        "paintedView.opacity = view.opacity",
        "paintedView.ambient = field.ambient_c",
        "paintedView.scenario = field.scenario",
    }));
    const client = @embedFile("assets/thermal_page.js");
    try testing.expect(containsAll(client, &.{
        "d.type === \"netlisp-pcb-ref-picked\"",
        "tell({ selectedRef: d.ref || \"\" })",
    }));
}

// spec: serve/thermal-page - the board's legend starts at 25 °C to 125 °C, lets the reader edit both endpoints without another solve, and preserves a valid manual range in the page URL
test "the board offers a persistent manual temperature scale" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try fixtureProject(alloc, &tmp);

    const html = (try serve(alloc, project, "heater", &.{})).body;
    // Both numeric endpoints are useful before the field loads and expose their
    // defaults directly to keyboard, touch-spinner and assistive-tech users.
    try testing.expect(containsAll(html, &.{
        "id=\"tp-scale-min\"",
        "id=\"tp-scale-max\"",
        "id=\"tp-ambient\"",
        "id=\"tp-view-3d\"",
        "3D setup",
        "value=\"25\"",
        "value=\"125\"",
        "Scale minimum temperature",
        "Scale maximum temperature",
        "id=\"tp-hotspot\"",
        "id=\"tp-heat-loading\"",
        "id=\"tp-labels\"",
        "id=\"tp-opacity\"",
    }));
    // Ambient now belongs to the board toolbar, immediately after the colour
    // scale rather than in the scenario/export panel on the left.
    const board_controls = std.mem.indexOf(u8, html, "class=\"tp-board-controls\"") orelse return error.NoBoardControls;
    const scale_max = std.mem.indexOfPos(u8, html, board_controls, "id=\"tp-scale-max\"") orelse return error.NoScale;
    const ambient_control = std.mem.indexOfPos(u8, html, board_controls, "id=\"tp-ambient\"") orelse return error.NoAmbient;
    const hotspot = std.mem.indexOfPos(u8, html, board_controls, "id=\"tp-hotspot\"") orelse return error.NoHotspot;
    try testing.expect(scale_max < ambient_control and ambient_control < hotspot);
    // The iframe maps absolute copper temperatures onto the chosen endpoints
    // and rebuilds its existing raster when they change.
    const overlay = @embedFile("assets/pcb_thermal.js");
    try testing.expect(containsAll(overlay, &.{
        "var SCALE_DEFAULT_MIN_C = 25",
        "var SCALE_DEFAULT_MAX_C = 125",
        "view.scaleMinC",
        "view.scaleMaxC",
        "temperatureNorm(f.ambient_c + g.rise_c[p])",
        "setScale: setScale",
        "if (recolor && field) raster = buildRaster(field)",
    }));

    // The parent validates min < max, sends both values without showing the
    // solve veil, and records a non-default range in the reproducible URL.
    const client = @embedFile("assets/thermal_page.js");
    try testing.expect(containsAll(client, &.{
        "function scaleSet(",
        "function scalePush(",
        "frame.contentWindow.PCBThermal",
        "thermal.setScale(scaleMinC, scaleMaxC)",
        "nextMaxC > nextMinC",
        "scaleMinC: scaleMinC, scaleMaxC: scaleMaxC",
        "searchParams.get(\"scale_min\")",
        "searchParams.get(\"scale_max\")",
        "searchParams.set(\"scale_min\"",
        "searchParams.set(\"scale_max\"",
        "function setupViewSet(",
        "type: \"netlisp-pcb-view\"",
        "searchParams.set(\"view\", \"3d\")",
    }));

    // Both halves of the postMessage contract, so a rename on either side of
    // the frame boundary fails here rather than silently blanking the legend.
    const report = [_][]const u8{ "thermal:state", "hotspot", "unavailable" };
    try testing.expect(containsAll(overlay, &report));
    try testing.expect(containsAll(client, &report));
    // The words are written from that report and never from a second fetch —
    // two fetches are how the picture and the legend come to disagree.
    try testing.expect(std.mem.indexOf(u8, client, "api/thermal-field") == null);

    const css = @embedFile("assets/thermal_page.css");
    // An author-level `display: flex` beats the user agent's `[hidden]` rule.
    // The page therefore needs an author-level hidden rule of its own or the
    // completed board remains greyed out behind a permanent "Solving…" veil.
    try testing.expect(std.mem.indexOf(u8, css, ".tp-loading[hidden] { display: none; }") != null);
}

// spec: serve/thermal-page - the page's client swaps only the ambient-dependent regions, keeps scenario switching local, and broadcasts a picked ref on the shared cross-probe channel
test "the thermal client fetches per ambient and switches scenario locally" {
    const js = @embedFile("assets/thermal_page.js");
    const markers = [_][]const u8{
        // The one network call, and it is the page's own fragment — the facts
        // JSON carries numbers, not the verdict prose this page states.
        "fragment=1",
        "document.getElementById(\"tp-tables\")",
        "document.getElementById(\"tp-verdict\")",
        // Scenario switching is a class/hidden change plus one message to the
        // board frame — no round trip, and no second fetch of the field.
        "function tpSelect(",
        "function coolingScenario()",
        "fanToggle.addEventListener",
        "heatsinkToggle.addEventListener",
        "fan_heatsink",
        "data-scenario",
        "tp-frame",
        "thermal:view",
        // The shared cross-probe bridge, send-only, with a `from` no receiver drops.
        "\"netlisp-xprobe\"",
        "from: \"thermal\"",
    };
    for (markers) |marker| try testing.expect(std.mem.indexOf(u8, js, marker) != null);
}

// spec: serve/thermal-page - the thermal page uses touch-sized navigation and single-column content at phone width, with wide tables scrolling inside their own box rather than the page
test "the thermal page exposes the shared phone layout" {
    const css = @embedFile("assets/thermal_page.css");
    // Wide tables scroll in their own box, so the page itself never does.
    try testing.expect(std.mem.indexOf(u8, css, ".tp-scroll { overflow-x:auto") != null);
    // Touch-sized controls and a full-width tab row at phone width.
    try testing.expect(std.mem.indexOf(u8, css, "@media (max-width: 620px)") != null);
    try testing.expect(std.mem.indexOf(u8, css, "min-height:44px") != null);
    try testing.expect(std.mem.indexOf(u8, css, ".topbar nav { width:100%") != null);
    try testing.expect(std.mem.indexOf(u8, css, ".tp-controls { flex-direction:column") != null);
    // …and the document itself opts into the notch-safe viewport the other
    // pages use, so the tab row is reachable on a phone.
    var head: std.Io.Writer.Allocating = .init(testing.allocator);
    defer head.deinit();
    try writeDocHead(&head.writer, .{
        .name = "demo",
        .is_module = false,
        .ambient_c = 25,
        .scenario = .natural,
        .bt = .{ .ambient_c = 25, .parts = &.{}, .verdict = .insufficient_data },
        .scenarios = .{},
        .lines = .{ .verdict = "", .package = "", .ambient = "", .coverage = "", .hint = "" },
    }, "Demo");
    try testing.expect(std.mem.indexOf(u8, head.written(), "viewport-fit=cover") != null);
}
