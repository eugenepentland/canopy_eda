//! `route_experiment` CLI tool — a request-local "try a routing DSL change"
//! surface for the constraint-DSL routing loop. It resolves the design's
//! blessed placement exactly like `describe_pcb_layout` / `route_pcb` do, then
//! routes it fresh through the shared plan-lowering seam (`route_plan`), and
//! answers with the deterministic route score (`route_score`) plus the per-net
//! stuck diagnostics (`stuck_json`) — the same numbers an agent iterates on.
//!
//! The DEFINING property vs. `route_pcb`: it PERSISTS NOTHING. No sidecar write,
//! no `.layouts.json` touch, no route-cache write — every path it calls is
//! read-only (placement selection reads saved layouts; routing + DRC + scoring
//! are pure over per-call arena memory). An optional `plan` arg supplies a
//! complete `(pcb-plan …)` fragment that REPLACES the design's authored plan for
//! this run only; it is parsed with the repo's own evaluator (no plan-grammar
//! duplication) and lowered through the same seam, so an unknown wave/class/net
//! name surfaces as a `plan_warnings` entry rather than an error, and a
//! malformed s-expression returns a structured parse-position error.
//!
//! It also NAMES THE FAILURES. `stuck[]` alone is router-derived and capped, so
//! it can be empty on a run whose `routed` is short of `total` — an agent then
//! had to spend a whole second `describe_pcb_layout` call just to learn WHICH
//! nets were open. `unrouted[]` (the gate's own oracle list) and `open_nets[]`
//! (per open net: island count plus the shortest pad-to-pad hops that close it,
//! the aiming data `add_tracks` takes) come back in the same payload.
//!
//! And it routes the SAME BOARD the other surfaces do: the shown layout's
//! hand-drawn pours ride along as router source copper, because a pour is
//! connecting copper — without them a poured rail is re-traced and then reported
//! open, which is not the board `route_pcb` would commit.
//!
//! An optional `topology` boolean is a further request-local knob: it forces
//! every resolved route wave through the global topology planner for this run
//! only, exactly as if each had authored `(topology)`. When the planner runs,
//! the result carries a small `topology` object counting what it did.
//!
//! An optional `repair_placement` boolean turns on the engine-computed
//! PLACEMENT half (`route_repair`): after the baseline route it probes what
//! geometry walls the still-open channels, computes up to three bounded
//! micro-moves of movable passives, re-routes once, and keeps the trial only on
//! a strict improvement. It persists nothing either — the accepted poses come
//! back shaped for `set_part_poses`, which is where writing is gated.

const std = @import("std");
const parser = @import("../sexpr/parser.zig");
const env_mod = @import("../eval/env.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const modules_mod = @import("modules.zig");
const pcb_describe = @import("pcb_describe.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const route_plan = @import("route_plan.zig");
const route_policy = @import("../placement/route_policy.zig");
const route_repair = @import("../route_repair.zig");
const route_score = @import("../placement/route_score.zig");
const stuck_json = @import("stuck_json.zig");
const drc = @import("../placement/drc.zig");
const drc_rules = @import("drc_rules.zig");
const plan_resolve = @import("../placement/plan_resolve.zig");
const fab_readiness = @import("../fab_readiness.zig");
const topo_lower = @import("../placement/topo_lower.zig");

/// One-form `(design-block …)` wrapper the plan fragment is spliced into so the
/// real evaluator (not a hand-rolled copy) builds the `PcbPlanSpec`.
const plan_probe_wrapper = "(design-block \"__route_experiment_probe__\"\n{s})";

/// `route_experiment` — route the blessed placement request-locally and return
/// `{name, layout, effort, plan_source, plan_warnings[], cancelled, routed, total, vias,
/// trace_mm, drc_errors, score, score_v, topology?, stuck[], unrouted[],
/// open_nets[]}`. `plan` (optional) is a complete `(pcb-plan …)` fragment that
/// overrides the authored plan for this run only; `layout` / `sub` pick the
/// board, `effort` the retry tier, and `topology` (optional) forces the global
/// topology planner onto every route wave of that plan. Writes nothing to disk.
pub fn mcpRouteExperiment(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) pcb_layout_page.HandlerError!bool {
    const name = argStr(args_val, "name") orelse return fail(out, alloc, "missing required arg: name");
    // A blank/whitespace plan is treated as "no override" (route the authored plan).
    const plan_text: ?[]const u8 = blk: {
        const p = argStr(args_val, "plan") orelse break :blk null;
        const trimmed = std.mem.trim(u8, p, " \t\r\n");
        break :blk if (trimmed.len == 0) null else trimmed;
    };
    const effort: ?route_policy.Effort = switch (parseEffort(argStr(args_val, "effort"))) {
        .absent => null,
        .ok => |e| e,
        .bad => return fail(out, alloc, "effort must be \"one_shot\" or \"standard\""),
    };
    const layout_arg = argStr(args_val, "layout");

    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    // Route mode selects the blessed (★ else auto) placement and skips restoring
    // saved copper — this tool routes fresh. Same selection as route_pcb, with
    // the read tools' `layout` / `sub` selectors so a caller can iterate on one
    // named board instead of only on whatever is starred.
    const solved = pcb_layout_page.solveForRequest(alloc, project_dir, name, .{
        .route = true,
        .layout = layout_arg,
        .sub = argStr(args_val, "sub"),
    }, &eval, &module_res) catch |e|
        return failFmt(out, alloc, "could not resolve layout: {s}", .{@errorName(e)});

    // Parse the optional plan override with a dedicated request-local evaluator
    // (its arena-backed memory outlives the route below via this scope).
    var plan_eval = Evaluator.init(alloc, project_dir);
    defer plan_eval.deinit();
    var plan_override: ?env_mod.PcbPlanSpec = null;
    if (plan_text) |pt| switch (parsePlanOverride(&plan_eval, alloc, pt)) {
        .ok => |spec| plan_override = spec,
        .not_plan => return fail(out, alloc, "plan must be a single (pcb-plan …) s-expression form"),
        .bad_syntax => |d| return failParse(out, alloc, d),
    };

    const params = solved.placement.rules.design.routeParams();
    const exp_opts = route_plan.ExperimentOpts{
        .project_dir = project_dir,
        .saved_module_routes = argBool(args_val, "saved_module_routes") orelse true,
        .plan = plan_override,
        .effort = effort,
        .zones = solved.shown_zones.sources,
        .topology = argBool(args_val, "topology") orelse false,
    };
    const exp = route_plan.routeExperiment(alloc, solved.block, solved.placement, params, exp_opts) catch |e|
        return failFmt(out, alloc, "routing failed: {s}", .{@errorName(e)});

    // Score inputs: DRC-check the routed copper through the same filtered seam
    // describe uses, sum the trace, and count the fab-blocking violations (the
    // score's error term — `drc.errorCount`, so warnings and `net_open` are both
    // out; completion is already the `routed`/`total` term right below).
    // Reads DRC policy config; writes nothing.
    //
    // The two v2 geometry terms come from the score module's OWN shared
    // measurements — `bendCount` over this run's copper, `qualityWarnCount` over
    // this run's findings — so a number from this tool is directly comparable to
    // the route-review replay's, which calls the same two helpers.
    const violations = drc_rules.checkFilteredZones(alloc, project_dir, name, .{
        .placement = solved.placement,
        .routed = exp.result,
        .clearance = params.clearance,
        .zones = solved.shown_zones.user,
    });
    var trace_mm: f64 = 0;
    for (exp.result.tracks) |t| trace_mm += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    const drc_errors = drc.errorCount(violations);
    const bends = try route_score.bendCount(alloc, exp.result.tracks);
    const quality_warns = route_score.qualityWarnCount(violations);
    const s = route_score.score(.{
        .routed = exp.result.routed,
        .total = exp.result.total,
        .vias = exp.result.vias.len,
        .trace_mm = trace_mm,
        .drc_errors = drc_errors,
        .bends = bends,
        .quality_warns = quality_warns,
    });
    // Per-open-net aiming data over the SAME copper the counters describe —
    // pours included, exactly as `/api/pcb-describe` builds its `open_nets`.
    const open_nets = fab_readiness.openNetsAmong(alloc, solved.placement, .{
        .tracks = exp.result.tracks,
        .vias = exp.result.vias,
        .arcs = exp.result.arcs,
        .rf_paths = exp.result.rf_port_outcomes,
        .zones = solved.shown_zones.user,
    }, exp.result.failed) catch &.{};

    // The engine-computed placement half, off unless asked for: probe what walls
    // the still-open channels, move at most three movable passives, re-route
    // once, and keep only a strict improvement. Persists nothing (see
    // `route_repair`), so `route_experiment` stays the read-only tool it is.
    const repair: ?route_repair.Outcome = if (argBool(args_val, "repair_placement") orelse false)
        route_repair.run(alloc, .{
            .project_dir = project_dir,
            .name = name,
            .block = solved.block,
            .placement = solved.placement,
            .params = params,
            .opts = exp_opts,
            .baseline = .{
                .result = exp.result,
                .drc_errors = drc_errors,
                .open_nets = open_nets,
            },
        }) catch |e|
            return failFmt(out, alloc, "placement repair failed: {s}", .{@errorName(e)})
    else
        null;

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.writeAll("{\"name\":");
    try pcb_layout_page.writeJsonStr(w, name);
    try w.writeAll(",\"layout\":");
    if (layout_arg) |ln| try pcb_layout_page.writeJsonStr(w, ln) else try w.writeAll("null");
    try w.writeAll(",\"effort\":");
    try pcb_layout_page.writeJsonStr(w, @tagName(exp.effort));
    try w.writeAll(",\"plan_source\":");
    try pcb_layout_page.writeJsonStr(w, if (plan_override != null) "override" else "design");
    try writePlanWarnings(w, exp.warnings);
    try w.print(",\"cancelled\":{},\"routed\":{d},\"total\":{d},\"vias\":{d},\"trace_mm\":{d:.3},\"drc_errors\":{d}", .{
        exp.result.cancelled,
        exp.result.routed,
        exp.result.total,
        exp.result.vias.len,
        trace_mm,
        drc_errors,
    });
    // The two v2 geometry inputs ride beside the score so a plan-iterating
    // agent can see WHICH term moved, not just that the scalar did.
    try w.print(",\"bends\":{d},\"quality_warns\":{d}", .{ bends, quality_warns });
    try w.print(",\"score\":{d:.2},\"score_v\":{d}", .{ s, route_score.formula_version });
    try writeTopology(w, exp.topology);
    try pcb_layout_page.writeRouteSeedStats(w, exp.seeds);
    try stuck_json.writeStuckJson(w, exp.stuck);
    try writeUnroutedJson(w, exp.result.failed);
    try writeOpenNetsJson(w, open_nets);
    if (repair) |r| try route_repair.writeRepairJson(w, solved.placement, r);
    try w.writeAll("}");
    try out.appendSlice(alloc, aw.written());
    return true;
}

/// The `,"unrouted":[…]` block — the ORACLE's still-open net names, as the
/// shared gate (`route_close.reconcile`) left them on `result.failed`. This is
/// the same list `/api/pcb-describe` reports as `routed.unrouted`, and it is
/// what `stuck[]` cannot be trusted for: the diagnostic capture is capped and
/// router-derived, so it can come back empty on a run whose `routed` is short of
/// `total`.
fn writeUnroutedJson(w: *std.Io.Writer, unrouted: []const []const u8) std.Io.Writer.Error!void {
    try w.writeAll(",\"unrouted\":[");
    for (unrouted, 0..) |net, i| {
        if (i > 0) try w.writeAll(",");
        try pcb_layout_page.writeJsonStr(w, net);
    }
    try w.writeAll("]");
}

/// The `,"open_nets":[…]` block — per still-open net, how many copper islands
/// it is in and the shortest pad-to-pad hops that would join them, each hop
/// naming both endpoints' ref/pad/coordinate. Deliberately COMPACT: the full pad
/// table `/api/pcb-describe?pads=1` carries is the obstacle set, which roughly
/// doubles the payload, while the hops alone are what an agent aims `add_tracks`
/// at. Omitted entirely when nothing is open, so a finished board stays lean.
fn writeOpenNetsJson(w: *std.Io.Writer, open_nets: []const fab_readiness.OpenNet) std.Io.Writer.Error!void {
    if (open_nets.len == 0) return;
    try w.writeAll(",\"open_nets\":[");
    for (open_nets, 0..) |n, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"net\":");
        try pcb_layout_page.writeJsonStr(w, n.net);
        try w.print(",\"islands\":{d},\"pads\":{d},\"gaps\":[", .{ n.islands, n.pads.len });
        for (n.gaps, 0..) |gp, gi| {
            if (gi > 0) try w.writeAll(",");
            try w.print("{{\"mm\":{d:.3},\"from\":", .{gp.mm});
            try pcb_describe.writeOpenPadJson(w, gp.from, .compact);
            try w.writeAll(",\"to\":");
            try pcb_describe.writeOpenPadJson(w, gp.to, .compact);
            try w.writeAll("}");
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]");
}

/// Outcome of reading the optional `effort` argument.
const EffortArg = union(enum) {
    /// No `effort` given — keep the plan's authored `(effort …)`.
    absent,
    ok: route_policy.Effort,
    /// Present but not a tier name.
    bad,
};

/// Map the `effort` argument onto the router's retry tier through the shared
/// `Effort.fromName` spelling, and distinguish "not given" from "not a tier" —
/// the agent-facing surface rejects a typo rather than silently routing at the
/// authored effort under a name the caller thought they had chosen.
fn parseEffort(text: ?[]const u8) EffortArg {
    const t = text orelse return .absent;
    return if (route_policy.Effort.fromName(t)) |e| .{ .ok = e } else .bad;
}

/// The `,"topology":{…}` block, written ONLY when the global topology planner
/// actually ran (some route wave carried `(topology)`, or the request forced
/// it). Absent means "no topology was planned" — never "planned nothing".
fn writeTopology(w: *std.Io.Writer, stats: ?topo_lower.Stats) std.Io.Writer.Error!void {
    const t = stats orelse return;
    try w.print(
        ",\"topology\":{{\"waves_planned\":{d},\"guides_emitted\":{d},\"nets_skipped_low_confidence\":{d}}}",
        .{ t.waves_planned, t.guides_emitted, t.nets_skipped_low_confidence },
    );
}

/// The `,"plan_warnings":[…]` block — one object per unresolved-selector warning
/// (unknown wave/class/net name) from the shared plan_resolve machinery.
fn writePlanWarnings(w: *std.Io.Writer, warnings: []const plan_resolve.Warning) std.Io.Writer.Error!void {
    try w.writeAll(",\"plan_warnings\":[");
    for (warnings, 0..) |warn, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"kind\":");
        try pcb_layout_page.writeJsonStr(w, warn.kind);
        try w.writeAll(",\"wave\":");
        try pcb_layout_page.writeJsonStr(w, warn.wave);
        try w.writeAll(",\"name\":");
        try pcb_layout_page.writeJsonStr(w, warn.name);
        try w.writeAll(",\"message\":");
        try pcb_layout_page.writeJsonStr(w, warn.message);
        try w.writeAll("}");
    }
    try w.writeAll("]");
}

/// Outcome of lowering a `plan` override fragment into a `PcbPlanSpec`.
const PlanOverride = union(enum) {
    /// A `(pcb-plan …)` form; its backing memory is owned by the evaluator/arena.
    ok: env_mod.PcbPlanSpec,
    /// Well-formed s-expression but not a single `(pcb-plan …)` form.
    not_plan,
    /// Malformed s-expression at this source location (position in the caller's text).
    bad_syntax: parser.ParseDiagnostic,
};

/// Parse a `plan` override fragment into a `PcbPlanSpec` through `plan_eval`
/// (whose allocator + lifetime own the returned spec's memory). Syntax is
/// validated FIRST against the caller's own text so a malformed fragment reports
/// an accurate position; a well-formed `(pcb-plan …)` is then built by the real
/// evaluator via a one-form wrapper design — no plan-grammar duplication here.
fn parsePlanOverride(plan_eval: *Evaluator, alloc: std.mem.Allocator, plan_text: []const u8) PlanOverride {
    var diag: parser.ParseDiagnostic = .{};
    const nodes = parser.parseDiag(alloc, plan_text, &diag) catch return .{ .bad_syntax = diag };
    if (nodes.len != 1) return .not_plan;
    const form = nodes[0].asList() orelse return .not_plan;
    if (form.len == 0) return .not_plan;
    const head = form[0].asAtom() orelse return .not_plan;
    if (!std.mem.eql(u8, head, "pcb-plan")) return .not_plan;
    const source = std.fmt.allocPrint(alloc, plan_probe_wrapper, .{plan_text}) catch return .not_plan;
    const val = plan_eval.evalSource(source) catch return .not_plan;
    return switch (val) {
        .design_block => |b| if (b.pcb_plan) |p| .{ .ok = p } else .not_plan,
        else => .not_plan,
    };
}

/// `args.key` as a string (absent / non-object / non-string ⇒ null).
fn argStr(args_val: ?std.json.Value, key: []const u8) ?[]const u8 {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// `args.key` as a boolean (absent / non-object / non-boolean ⇒ null).
fn argBool(args_val: ?std.json.Value, key: []const u8) ?bool {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return if (v == .bool) v.bool else null;
}

/// Write an `{"error":<msg>}` envelope into `out` and return false (the CLI
/// layer flags the result `isError`). One error spelling for this tool.
fn fail(out: *std.ArrayList(u8), alloc: std.mem.Allocator, msg: []const u8) pcb_layout_page.HandlerError!bool {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.writeAll("{\"error\":");
    try pcb_layout_page.writeJsonStr(w, msg);
    try w.writeAll("}");
    try out.appendSlice(alloc, aw.written());
    return false;
}

/// `fail` with a formatted message (built on `alloc`, then escaped).
fn failFmt(out: *std.ArrayList(u8), alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) pcb_layout_page.HandlerError!bool {
    const msg = std.fmt.allocPrint(alloc, fmt, args) catch "error";
    return fail(out, alloc, msg);
}

/// Structured malformed-plan error naming the parse position in the caller's
/// `plan` text: `{"error":…,"parse_error":{"line","col","offset","message"}}`.
fn failParse(out: *std.ArrayList(u8), alloc: std.mem.Allocator, diag: parser.ParseDiagnostic) pcb_layout_page.HandlerError!bool {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.writeAll("{\"error\":\"malformed plan s-expression\",\"parse_error\":{\"line\":");
    try w.print("{d},\"col\":{d},\"offset\":{d},\"message\":", .{ diag.span.line, diag.span.col, diag.span.offset });
    try pcb_layout_page.writeJsonStr(w, diag.message);
    try w.writeAll("}}");
    try out.appendSlice(alloc, aw.written());
    return false;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const mcp_tools = @import("mcp_tools.zig");
const optimizer = @import("../placement/optimizer.zig");
const geometry = @import("../placement/geometry.zig");
const export_kicad = @import("../export_kicad.zig");

// spec: Web Server - route_experiment is a registered read-only CLI tool
test "route_experiment is registered read-only" {
    try testing.expect(mcp_tools.isKnownTool("route_experiment"));
    try testing.expect(!mcp_tools.isMutationTool("route_experiment"));
}

/// Two 1-pad parts 8 mm apart carrying one net, on a plane-free 2-layer board
/// and with NO copper — so the connectivity oracle reports that net open, in two
/// islands, one hop from closed.
fn openNetPlacement(parts: []optimizer.Part, nets: []const export_kicad.FlatNet) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 10,
        .maxy = 2,
        .generated = false,
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };
}

// spec: Web Server - a route_experiment result names the oracle's still-open nets and the pad-to-pad hops that would close them
test "the experiment payload names the open nets and their closing hops" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R1", .kind = .passive, .hw = 1, .hh = 1, .pads = &pad, .fallback = false, .x = 8, .y = 0 },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "R1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = openNetPlacement(&parts, &nets);

    // No tracks, no vias, no pours: the oracle sees two islands on one net.
    const open = try fab_readiness.openNets(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), open.len);

    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    // `unrouted[]` is the gate's own list — the names `stuck[]` may omit.
    try writeUnroutedJson(w, &.{"SIG"});
    try writeOpenNetsJson(w, open);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "\"unrouted\":[\"SIG\"]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"net\":\"SIG\",\"islands\":2,\"pads\":2") != null);
    // One hop closes it, and it names both endpoints in the board frame
    // add_tracks takes (8 mm apart on the x axis).
    try testing.expect(std.mem.indexOf(u8, out, "\"mm\":8.000") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"ref\":\"U1\",\"pad\":\"1\",\"x\":0.000,\"y\":0.000,\"side\":\"top\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"ref\":\"R1\",\"pad\":\"1\",\"x\":8.000,\"y\":0.000,\"side\":\"top\"") != null);
    // The obstacle-set pad table stays OUT of this payload — that is describe's
    // `?pads=1`, and it roughly doubles the bytes.
    try testing.expect(std.mem.indexOf(u8, out, "\"hw\":") == null);
}

// spec: Web Server - a route_experiment on a fully connected board emits an empty unrouted list and no open_nets block
test "a closed board emits an empty unrouted list and no open_nets block" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try writeUnroutedJson(w, &.{});
    try writeOpenNetsJson(w, &.{});
    try testing.expectEqualStrings(",\"unrouted\":[]", aw.written());
}

// spec: Web Server - the route_experiment effort argument selects the router retry tier and rejects any other word
test "the effort argument maps onto the router retry tier" {
    try testing.expect(std.meta.activeTag(parseEffort(null)) == .absent);
    try testing.expectEqual(route_policy.Effort.one_shot, parseEffort("one_shot").ok);
    // The DSL spells it `(effort one-shot)`, which is what an agent reads.
    try testing.expectEqual(route_policy.Effort.one_shot, parseEffort("one-shot").ok);
    try testing.expectEqual(route_policy.Effort.standard, parseEffort("standard").ok);
    try testing.expect(std.meta.activeTag(parseEffort("fastest")) == .bad);
}

// spec: Web Server - a well-formed route_experiment plan override parses into a route plan spec
test "a well-formed plan override parses into a route plan spec" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var eval = Evaluator.init(arena, "");
    defer eval.deinit();
    const plan = "(pcb-plan (route (wave \"exp\" (rest) (allowed-layers \"F.Cu\" \"B.Cu\"))))";
    const result = parsePlanOverride(&eval, arena, plan);
    try testing.expect(std.meta.activeTag(result) == .ok);
    try testing.expectEqual(@as(usize, 1), result.ok.route.len);
    try testing.expectEqualStrings("exp", result.ok.route[0].name);
    try testing.expect(result.ok.route[0].rest);
}

// spec: Web Server - a malformed route_experiment plan override is rejected with a structured parse error
test "a malformed plan override yields a structured parse error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var eval = Evaluator.init(arena, "");
    defer eval.deinit();
    // Unbalanced parenthesis — the tokenizer never closes the open list.
    const result = parsePlanOverride(&eval, arena, "(pcb-plan (route");
    try testing.expect(std.meta.activeTag(result) == .bad_syntax);
    try testing.expect(result.bad_syntax.message.len > 0);
}

// spec: Web Server - a route_experiment plan override that is a non-plan form is rejected
test "a non-plan form override is rejected as not a plan" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var eval = Evaluator.init(arena, "");
    defer eval.deinit();
    const result = parsePlanOverride(&eval, arena, "(design-block \"x\")");
    try testing.expect(std.meta.activeTag(result) == .not_plan);
}
