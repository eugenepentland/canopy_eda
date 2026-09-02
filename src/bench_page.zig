//! Page-load latency benchmark — the harness that makes "a primary design page
//! got slower" a checkable claim before it reaches main.
//!
//! The costs a reader actually feels on `/pcb-layout/:name` have regressed
//! repeatedly and invisibly: nothing measured them, so a change that added a
//! hundred milliseconds to every cold page load looked exactly like a change
//! that didn't. This times the same seams the server runs, per board, and
//! `--baseline` turns a committed recording into a non-zero-exit regression
//! gate (the `bench-route --baseline` pattern, applied to wall time).
//!
//! What is measured, per board — each phase is a production render seam, not a
//! synthetic workload:
//!
//!   eval        Evaluator.init + evalFile — the design evaluation alone.
//!   sidecar     read + std.json parse of `<design>.layouts.json` — the cost
//!               that scales with saved-copper size (7 MB on barracuda).
//!   solve       pcb_layout_page.solveForRequest — eval + sidecar + placement
//!               (verbatim ★ restore for a blessed board) + copper restore.
//!   drc_report  drc_rules.checkFilteredZones on the restored copper — the
//!               reporting DRC every surface pays (geometry + pour topology +
//!               net_open + severity overrides): /api/pcb-drc, the page blob,
//!               describe, the fab gate.
//!   drc_geom    drc.check on the same copper — the geometry-only hot path,
//!               the native twin of the client's interactive WASM engine.
//!   page        pcb_derived.warmPage(…, .page) on a fresh cache — the
//!               complete cold plain-page render: eval, sidecar, placement,
//!               DRC, HTML serialization, cache admission, and the gzip memo.
//!               This is the first-visitor cost after a deploy or an edit.
//!               `.page` scope deliberately stops where the reader's first
//!               paint does: the analyses behind `?derived=1` are a second
//!               response with its own cache entry, and folding them in here
//!               would stop this number tracking what a visitor waits for.
//!   assembly    assembly_debug.benchColdPage — evaluate, build the BOM/search
//!               index and render the parent `/assembly-debug/:name` HTML. Its
//!               PCB iframe is covered independently by `page`.
//!   thermal     thermal_page.benchColdPage — evaluate, solve the default
//!               layout-aware cooling scenarios and render `/thermal/:name`.
//!   schematic   schematic_page.benchColdPage — evaluate, run ERC and attached
//!               checks, build review data and render `/schematics/:name`.
//!
//! Phases NEST: eval ⊂ solve ⊂ page. The DRC phases are timed standalone on
//! the solve's output, so `page` includes another run of them. Medians over
//! `--reps` runs (default 3); the page phase gets a fresh cache per rep so
//! every rep is a true cold render.
//!
//! `drc_report` is the ONE phase whose reps are deliberately not independent.
//! The reporting seam memoises a board's poured copper for as long as the board
//! is unchanged (`placement/fill_cache.zig`), so the first rep pours the fill
//! and the rest borrow it — and the median of three is therefore the RECONCILE
//! cost, what the editor's DRC loop and every derived fetch pay over a board
//! that has not moved. That is the number this phase exists to track: a cold
//! first pour happens once per edit, the reconcile happens continuously. The
//! cold pour is still visible in `page`, whose per-rep cache reset makes each
//! render a first visit.
//!
//! Read-only in the bench_route sense: it renders through the same warm-up
//! seam the server boot uses, which only touches boards that already have a
//! saved-layout sidecar — the corpus below applies the same guard, so no
//! layout file is created for a board nobody laid out.
//!
//! Wall-clock discipline: numbers are only comparable when the machine isn't
//! also compiling something. Run gated: `scripts/gate.sh zig-out/bin/netlisp
//! bench-page …` (see docs/benchmarks/pcb-page/README.md). The lock can only
//! serialize jobs that take it, so the bench also watches /proc/loadavg's
//! 1-minute average around every board and labels the run — in the table and
//! the JSON — as CONTENDED when the load cannot be explained by this process
//! plus the decay of whatever ran before it; `scripts/perf_gate.sh --record`
//! refuses to install a baseline carrying that label.
//!
//! Usage:
//!   netlisp bench-page [--project-dir <dir>] [--reps <n>] [--json]
//!       [--baseline <file>] [<design> ...]
//!
//! With no design names it benchmarks every design that has a saved-layout
//! sidecar. Record a baseline with `--json > baseline.json`; the gate then
//! fails (non-zero exit) when a phase regresses past its allowance, when the
//! corpus-wide drift bound is exceeded, when a hand-set absolute budget in the
//! baseline file is blown, or when a board's DRC counts moved (a wall-time
//! claim is only valid over identical work).

const std = @import("std");
const httpz = @import("httpz");
const clock = @import("infra/clock.zig");
const infra_fs = @import("infra/fs.zig");
const log = @import("infra/log.zig");
const paths = @import("paths.zig");
const bench_args = @import("bench_args.zig");
const json_writer = @import("json_writer.zig");
const optimizer = @import("placement/optimizer.zig");
const drc = @import("placement/drc.zig");
const drc_compose = @import("placement/drc_compose.zig");
const drc_rules = @import("serve/drc_rules.zig");
const assembly_debug = @import("serve/assembly_debug.zig");
const pcb_layout_page = @import("serve/pcb_layout_page.zig");
const pcb_derived = @import("serve/pcb_derived.zig");
const pcb_page_cache = @import("serve/pcb_page_cache.zig");
const schematic_page = @import("serve/schematic_page.zig");
const thermal_page = @import("serve/thermal_page.zig");
const bench_route = @import("bench_route.zig");
const serve_root = @import("serve.zig");
const router = @import("placement/router.zig");
const modules_mod = @import("serve/modules.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;

const ns_per_ms: f64 = 1_000_000.0;

/// A board may be this much slower than its baseline before the gate fails —
/// but only once it is also past `abs_floor_ms`, so a 4 ms board jittering to
/// 6 ms doesn't fail a 50% rule that exists to catch real regressions.
const ratio_limit = 1.30;
/// Absolute allowance under which the ratio rule never fires. Chosen at the
/// observed same-machine run-to-run noise of the smallest boards, with room.
const abs_floor_ms = 25.0;
/// Corpus-wide drift bound: the geomean of per-board `now/baseline` ratios for
/// one phase may not exceed this even when every individual board stays under
/// its own allowance — ten boards each 20% slower is a regression the
/// per-board rule alone would wave through.
const drift_limit = 1.10;

/// The wire key of the net-open count, derived from the one DRC vocabulary
/// (`drc.Kind`) so renaming the kind cannot orphan recorded baselines silently
/// — the rename shows up here as a compile error instead.
const net_open_key = @tagName(drc.Kind.net_open);

/// What this harness can fail with. A board that fails to load or solve is an
/// `ok = false` row, not an error — one broken board must not abort the corpus.
pub const BenchError = std.mem.Allocator.Error ||
    std.Io.Writer.Error ||
    infra_fs.File.WriteError ||
    error{PageBaselineRegression}; // the --baseline gate failed

/// The measured phases of one board, in milliseconds (medians across reps).
/// Field order is display order; names are the wire keys of the JSON output
/// and the baseline file, so renaming one silently orphans recorded baselines
/// — the round-trip test at the foot of the file pins them.
pub const Phases = struct {
    eval_ms: f64 = 0,
    sidecar_ms: f64 = 0,
    solve_ms: f64 = 0,
    drc_report_ms: f64 = 0,
    drc_geom_ms: f64 = 0,
    pages: struct {
        pcb: f64 = 0,
        assembly: f64 = 0,
        thermal: f64 = 0,
        schematic: f64 = 0,
    } = .{},

    pub const names = [_][]const u8{
        "eval_ms",
        "sidecar_ms",
        "solve_ms",
        "drc_report_ms",
        "drc_geom_ms",
        "page_ms",
        "assembly_page_ms",
        "thermal_page_ms",
        "schematic_page_ms",
    };

    fn get(self: Phases, comptime name: []const u8) f64 {
        if (comptime std.mem.eql(u8, name, "page_ms")) return self.pages.pcb;
        if (comptime std.mem.eql(u8, name, "assembly_page_ms")) return self.pages.assembly;
        if (comptime std.mem.eql(u8, name, "thermal_page_ms")) return self.pages.thermal;
        if (comptime std.mem.eql(u8, name, "schematic_page_ms")) return self.pages.schematic;
        return @field(self, name);
    }

    fn set(self: *Phases, comptime name: []const u8, value: f64) void {
        if (comptime std.mem.eql(u8, name, "page_ms")) {
            self.pages.pcb = value;
        } else if (comptime std.mem.eql(u8, name, "assembly_page_ms")) {
            self.pages.assembly = value;
        } else if (comptime std.mem.eql(u8, name, "thermal_page_ms")) {
            self.pages.thermal = value;
        } else if (comptime std.mem.eql(u8, name, "schematic_page_ms")) {
            self.pages.schematic = value;
        } else {
            @field(self, name) = value;
        }
    }
};

/// The DRC outcome observed with the timings. Doubles as the gate's
/// identical-work invariant: a wall-time comparison across commits is only
/// meaningful when both runs did the same checking.
pub const DrcCounts = struct {
    total: usize = 0,
    errors: usize = 0,
    net_open: usize = 0,

    fn eql(a: DrcCounts, b: DrcCounts) bool {
        return a.total == b.total and a.errors == b.errors and a.net_open == b.net_open;
    }
};

/// Non-timing facts observed about one board's render.
pub const Facts = struct {
    parts: usize = 0,
    sidecar_bytes: usize = 0,
    /// Rendered page cache footprint in bytes (HTML before gzip).
    html_bytes: usize = 0,
    /// The rendered page was admitted to the page cache — the property that
    /// keeps every load after the first warm. A render too large for the
    /// cache budget (or refused admission) makes EVERY reload a cold render,
    /// which is itself a page-load regression no timing column shows.
    cached: bool = false,
    /// DRC counts disagreed between reps — nondeterminism worth shouting
    /// about, though the row still reports the last rep's counts.
    unstable: bool = false,
    /// The shown placement came VERBATIM from a saved (blessed) layout. A
    /// board without one re-solves on every cold render — and the render path
    /// then persists that solve into the sidecar (exactly as the boot warm-up
    /// does) — so neither its wall times nor its DRC counts are stable across
    /// runs. Such a board is reported but kept OUT of the baseline gate, the
    /// same rule bench_route applies to its corpus score.
    placed: bool = false,
};

/// One board's measured outcome.
pub const BoardResult = struct {
    name: []const u8,
    ok: bool = false,
    phases: Phases = .{},
    drc: DrcCounts = .{},
    facts: Facts = .{},
    /// The 1-minute load sampled right after this board exceeded the
    /// contention model (see the machine-load tripwire below): something else
    /// ran beside the measurement, so this row's wall times are suspect.
    load_contended: bool = false,
};

/// Median of the samples, in place. Even counts average the middle pair —
/// with the default 3 reps this is the classic outlier-tolerant middle value.
fn median(samples: []f64) f64 {
    if (samples.len == 0) return 0;
    std.mem.sort(f64, samples, {}, std.sort.asc(f64));
    const mid = samples.len / 2;
    if (samples.len % 2 == 1) return samples[mid];
    return (samples[mid - 1] + samples[mid]) / 2;
}

const empty_route = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };

/// One rep's raw samples and observed facts.
const RepSample = struct {
    ok: bool = false,
    phases: Phases = .{},
    drc: DrcCounts = .{},
    facts: Facts = .{},
};

/// Run every phase once for one board. `alloc` should be a per-rep arena: a
/// cold barracuda render holds hundreds of megabytes, and the corpus must peak
/// at one rep's worth, not the whole run's.
fn benchRep(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) RepSample {
    var out = RepSample{};

    // Phase: eval — the design evaluation alone, on its own evaluator.
    {
        const source_path = paths.designSourcePath(alloc, project_dir, name) catch return out;
        var eval = Evaluator.init(alloc, project_dir);
        defer eval.deinit();
        const t0 = clock.nanoTimestamp();
        _ = eval.evalFile(source_path) catch return out;
        out.phases.eval_ms = nsToMs(clock.nanoTimestamp() - t0);
    }

    // Phase: sidecar — the raw `.layouts.json` read + JSON parse, the cost
    // component that scales with saved copper rather than design size. A
    // malformed sidecar still measured real parse work, so the time stands;
    // the warning keeps the anomaly visible beside the row it distorts.
    {
        const sidecar_path = paths.designSiblingPath(alloc, project_dir, name, ".layouts.json") catch return out;
        if (infra_fs.cwd().readFileAlloc(alloc, sidecar_path, pcb_layout_page.sidecar_max_bytes)) |data| {
            out.facts.sidecar_bytes = data.len;
            const t0 = clock.nanoTimestamp();
            if (std.json.parseFromSliceLeaky(std.json.Value, alloc, data, .{})) |_| {} else |err| {
                log.warn("bench-page: {s} sidecar JSON parse failed mid-measure: {s}", .{ name, @errorName(err) });
            }
            out.phases.sidecar_ms = nsToMs(clock.nanoTimestamp() - t0);
        } else |_| {}
    }

    // Phase: solve — the shared placement seam (eval + sidecar + verbatim ★
    // restore + copper restore), exactly what PNG/describe/CAM pay.
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const t_solve = clock.nanoTimestamp();
    const solved = pcb_layout_page.solveForRequest(alloc, project_dir, name, .{}, &eval, &module_res) catch return out;
    out.phases.solve_ms = nsToMs(clock.nanoTimestamp() - t_solve);
    out.facts.parts = solved.placement.parts.len;
    // `shownLayoutCopper` reports `from_saved` under exactly the condition the
    // solve took the placement VERBATIM from a saved snapshot — the honest
    // "is this a blessed board" answer (see bench_route's identical use).
    out.facts.placed = pcb_layout_page.shownLayoutCopper(alloc, project_dir, name, .{}, solved.placement).from_saved;
    const routed = solved.restored.routes orelse empty_route;
    // The DRC clearance rule, resolved the same way bench_route and the page
    // resolve it: from the design's own routing parameters, not the optimizer's.
    const clearance = solved.placement.rules.design.routeParams().clearance;

    // Phase: drc_report — the reporting seam every violation producer calls
    // (net_open's per-net pour raster included).
    {
        const t0 = clock.nanoTimestamp();
        const v = drc_rules.checkFilteredZones(alloc, project_dir, name, .{
            .placement = solved.placement,
            .routed = routed,
            .clearance = clearance,
            .zones = solved.shown_zones.user,
        });
        out.phases.drc_report_ms = nsToMs(clock.nanoTimestamp() - t0);
        out.drc = .{ .total = v.len, .errors = drc.errorCount(v), .net_open = drc.countKind(v, .net_open) };
    }

    // Phase: drc_geom — the geometry-only pass as the SERVER runs it: the same
    // rules the client's interactive WASM engine runs, through the server-side
    // seam that memoises the plane surfaces the power-width rule pours
    // (`drc_compose.checkGeometry`). Only the wall time is wanted; a failed
    // check still spent the time it spent.
    {
        const t0 = clock.nanoTimestamp();
        if (drc_compose.checkGeometry(alloc, solved.placement, routed, clearance)) |_| {} else |err| {
            log.warn("bench-page: {s} geometry DRC failed mid-measure: {s}", .{ name, @errorName(err) });
        }
        out.phases.drc_geom_ms = nsToMs(clock.nanoTimestamp() - t0);
    }

    // Phase: page — the complete cold plain-page render through the boot
    // warm-up's own seam, against a fresh per-rep cache so it can never hit.
    {
        var state: serve_root.ServerState = .{ .caches = .init(alloc) };
        defer state.caches.deinit();
        var srv = serve_root.Server{
            .allocator = alloc,
            .project_dir = project_dir,
            .auth_dir = "",
            .state = &state,
        };
        const t0 = clock.nanoTimestamp();
        const rendered = pcb_derived.warmPage(&srv, alloc, name, .page);
        out.phases.pages.pcb = nsToMs(clock.nanoTimestamp() - t0);
        if (!rendered) return out;
        out.facts.cached = pageRetained(&state.caches.pcb_pages, alloc, name);
        out.facts.html_bytes = state.caches.pcb_pages.bytes;
    }

    // The other three primary pages are measured cold through request-less
    // benchmark seams that share their production evaluation/index/render
    // functions. Each call owns fresh state, so an earlier rep cannot turn a
    // later one into a cache hit. Assembly's child PCB iframe is deliberately
    // excluded here because the complete PCB render is already `page_ms`.
    {
        const t0 = clock.nanoTimestamp();
        _ = assembly_debug.benchColdPage(alloc, project_dir, name) orelse return out;
        out.phases.pages.assembly = nsToMs(clock.nanoTimestamp() - t0);
    }
    {
        const t0 = clock.nanoTimestamp();
        _ = thermal_page.benchColdPage(alloc, project_dir, name) orelse return out;
        out.phases.pages.thermal = nsToMs(clock.nanoTimestamp() - t0);
    }
    {
        const t0 = clock.nanoTimestamp();
        _ = schematic_page.benchColdPage(alloc, project_dir, name) orelse return out;
        out.phases.pages.schematic = nsToMs(clock.nanoTimestamp() - t0);
    }

    out.ok = true;
    return out;
}

/// Did the render just timed actually land in the page cache? Asked by
/// re-reserving the entry it should have filled: `reserveWarm` declines only
/// for an entry that is still VALID, so a refused reservation is the proof of
/// retention, and a granted one means the page was dropped — the silent
/// regression that turns every reload cold while every timing column still
/// looks fine.
///
/// The probe has to name the same entry the warm did. `.page` is the identity
/// `warmPage(…, .page)` admits under, and the deferred payload's entries are
/// separate keys the page phase never fills — probing one of those would report
/// a miss on a perfectly cached page. The live version is re-read for the same
/// reason: `reserveWarm` treats an entry recorded at a different version as
/// dead, and nothing edits a design mid-benchmark, so this is the version the
/// render captured.
///
/// A granted probe is released before returning: the bench must not leave a
/// reservation behind for the next rep to trip over.
fn pageRetained(pages: *pcb_page_cache.Store, scratch: std.mem.Allocator, name: []const u8) bool {
    const kind: pcb_page_cache.WarmKind = .page;
    if (!pages.reserveWarm(scratch, name, kind, serve_root.getLiveVersion(name))) return true;
    pages.finishWarm(scratch, name, kind);
    return false;
}

fn nsToMs(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / ns_per_ms;
}

/// Benchmark one board: `reps` full passes, medians per phase. Facts and DRC
/// counts come from the last rep; reps disagreeing on counts set `unstable`.
pub fn benchOne(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    reps: usize,
) std.mem.Allocator.Error!BoardResult {
    var out = BoardResult{ .name = name };
    const n = @max(reps, 1);
    var samples: std.ArrayList(RepSample) = .empty;
    for (0..n) |_| {
        var rep_arena = std.heap.ArenaAllocator.init(allocator);
        defer rep_arena.deinit();
        const rep = benchRep(rep_arena.allocator(), project_dir, name);
        if (!rep.ok) return out; // a broken board reports FAILED, not garbage medians
        try samples.append(arena, rep);
    }
    const last = samples.items[samples.items.len - 1];
    out.ok = true;
    out.drc = last.drc;
    out.facts = last.facts;
    for (samples.items) |rep| {
        if (!rep.drc.eql(last.drc)) out.facts.unstable = true;
    }
    inline for (Phases.names) |fname| {
        const vals = try arena.alloc(f64, samples.items.len);
        for (samples.items, 0..) |rep, i| vals[i] = rep.phases.get(fname);
        out.phases.set(fname, median(vals));
    }
    return out;
}

/// The benchmark corpus: every design `bench_route.corpus` finds that ALSO has
/// a saved-layout sidecar — the same guard the boot warm-up applies, so no
/// board is solved-and-persisted that nobody laid out.
pub fn corpus(arena: std.mem.Allocator, project_dir: []const u8) std.mem.Allocator.Error![]const []const u8 {
    const all = try bench_route.corpus(arena, project_dir);
    var names: std.ArrayList([]const u8) = .empty;
    for (all) |name| {
        const sidecar = paths.designSiblingPath(arena, project_dir, name, ".layouts.json") catch continue;
        _ = infra_fs.cwd().statFile(sidecar) catch continue;
        try names.append(arena, name);
    }
    return names.toOwnedSlice(arena);
}

// ── Machine-load tripwire ───────────────────────────────────────────────────
//
// scripts/gate.sh serializes only the jobs that take its lock: a sibling
// session benchmarking outside it skewed one gated bench-page pass 17-72% on
// the big boards while the small ones held steady (FEEDBACK.md 2026-08-29).
// Nothing in the timing columns distinguishes that run from an honest
// regression, so the bench reads /proc/loadavg's 1-minute average around
// every board and labels the run — and each board measured beside the excess
// — as CONTENDED, in both the table and the JSON. A contended measurement is
// thereby labelled rather than silently recorded: perf_gate.sh --record
// refuses the labelled JSON, and a labelled FAIL reads as "re-run quiet
// first", not "chase a phantom regression". Where /proc/loadavg does not
// exist, no load facts are reported and no label is ever invented.

/// A sample is contended when it exceeds `expectedLoad` by more than this
/// many runnable tasks. The bench's own busy core is already in the model, so
/// the margin only absorbs sampler noise, kernel housekeeping, and a burst of
/// interactive use. Any sustained sibling workload lands beyond it: a
/// server-plus-headless-browser bench keeps 2-3 tasks runnable for minutes
/// and a parallel build far more, while a lone extra single-threaded process
/// stays under — a miss accepted to keep false alarms out of 20-minute
/// recordings.
const load_excess_limit = 2.0;

/// The kernel's 1-minute load average is an exponential moving average with a
/// 60 s time constant; this is that constant, for the model below.
const loadavg_tau_s = 60.0;

/// The 1-minute load this run should see `elapsed_s` seconds after sampling
/// `start_1m`, on a machine where nothing else is running: the starting load
/// decays with the kernel's time constant while the bench's own single busy
/// core ramps in with the same constant — `1 + (start − 1)·e^(−t/τ)`. A high
/// START is thereby forgiven when it fades on schedule (perf_gate.sh runs two
/// parallel `zig build`s seconds before the bench starts); load that persists
/// or arrives mid-run is exactly what exceeds the curve.
fn expectedLoad(start_1m: f64, elapsed_s: f64) f64 {
    return 1.0 + (start_1m - 1.0) * @exp(-elapsed_s / loadavg_tau_s);
}

/// The leading 1-minute figure of a /proc/loadavg line, or null for content
/// that isn't one — a refused parse must never fabricate a load of 0.
fn parseLoad1m(data: []const u8) ?f64 {
    var it = std.mem.tokenizeAny(u8, data, " \t\r\n");
    const tok = it.next() orelse return null;
    return std.fmt.parseFloat(f64, tok) catch null;
}

fn readLoad1m() ?f64 {
    // Streamed from an open handle, not readFileAlloc: /proc files stat as
    // size 0, so a stat-sized buffer reads them as empty.
    const file = infra_fs.cwd().openFile("/proc/loadavg", .{}) catch return null;
    defer file.close();
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = file.readStreaming(buf[len..]) catch return null;
        if (n == 0) break;
        len += n;
    }
    return parseLoad1m(buf[0..len]);
}

/// The run-level load facts the table and JSON report.
const LoadReport = struct {
    start_1m: f64,
    end_1m: f64,
    /// Largest sampled excess over the model, clamped at 0 — how far past
    /// "this bench plus decay" the machine ever got.
    max_excess_1m: f64,
    contended: bool,
};

/// Samples the 1-minute load around every board and accumulates the verdict.
const LoadWatch = struct {
    start_1m: ?f64 = null,
    started_ns: i128 = 0,
    last_1m: f64 = 0,
    max_excess: f64 = 0,
    contended: bool = false,

    fn begin() LoadWatch {
        const first = readLoad1m() orelse return .{};
        return .{ .start_1m = first, .last_1m = first, .started_ns = clock.monotonicNanos() };
    }

    /// Read the load after one board; true when this sample exceeds the model
    /// past `load_excess_limit`, meaning that board's numbers are suspect.
    fn sample(self: *LoadWatch) bool {
        const start = self.start_1m orelse return false;
        const now = readLoad1m() orelse return false;
        self.last_1m = now;
        const elapsed_s = @as(f64, @floatFromInt(clock.monotonicNanos() - self.started_ns)) /
            @as(f64, @floatFromInt(clock.ns_per_s));
        const excess = now - expectedLoad(start, elapsed_s);
        if (excess > self.max_excess) self.max_excess = excess;
        if (excess <= load_excess_limit) return false;
        self.contended = true;
        return true;
    }

    fn report(self: LoadWatch) ?LoadReport {
        const start = self.start_1m orelse return null;
        return .{
            .start_1m = start,
            .end_1m = self.last_1m,
            .max_excess_1m = self.max_excess,
            .contended = self.contended,
        };
    }
};

/// Render the corpus table a reviewer reads. Columns are the phase medians in
/// milliseconds; the trailing flags call out the states a number can't show.
pub fn writeTable(w: *std.Io.Writer, results: []const BoardResult, reps: usize, load: ?LoadReport) std.Io.Writer.Error!void {
    try w.print("phase medians over {d} rep(s), ms — eval ⊂ solve ⊂ pcbPage; other pages are independent cold renders\n", .{reps});
    try w.print("{s:<24} {s:>5} {s:>9} {s:>8} {s:>8} {s:>8} {s:>8} {s:>8} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>13}\n", .{
        "board", "parts", "sidecar", "eval", "sidecar", "solve", "drcRep", "drcGeom", "pcbPage", "assembly", "thermal", "schematic", "pcb_kb", "drc e/t/open",
    });
    for (results) |r| {
        if (!r.ok) {
            try w.print("{s:<24} {s:>5}\n", .{ r.name, "FAILED" });
            continue;
        }
        var drc_buf: [48]u8 = undefined;
        const drc_col = std.fmt.bufPrint(&drc_buf, "{d}/{d}/{d}", .{ r.drc.errors, r.drc.total, r.drc.net_open }) catch "?";
        try w.print("{s:<24} {d:>5} {d:>8.1}k {d:>8.1} {d:>8.1} {d:>8.1} {d:>8.1} {d:>8.1} {d:>9.1} {d:>9.1} {d:>9.1} {d:>9.1} {d:>9.1} {s:>13}{s}{s}{s}{s}\n", .{
            r.name,
            r.facts.parts,
            @as(f64, @floatFromInt(r.facts.sidecar_bytes)) / 1024.0,
            r.phases.eval_ms,
            r.phases.sidecar_ms,
            r.phases.solve_ms,
            r.phases.drc_report_ms,
            r.phases.drc_geom_ms,
            r.phases.pages.pcb,
            r.phases.pages.assembly,
            r.phases.pages.thermal,
            r.phases.pages.schematic,
            @as(f64, @floatFromInt(r.facts.html_bytes)) / 1024.0,
            drc_col,
            if (r.facts.cached) "" else "   (NOT retained by page cache)",
            if (r.facts.unstable) "   (UNSTABLE drc counts across reps)" else "",
            if (r.facts.placed) "" else "   (no blessed layout — PCB/thermal not gated)",
            if (r.load_contended) "   (CONTENDED — 1-min load above the quiet-machine model while measured)" else "",
        });
    }
    if (load) |l| {
        try w.print("machine load (1-min avg): start {d:.2} → end {d:.2}, max excess over quiet-machine model {d:.2} (limit {d:.1}) — {s}\n", .{
            l.start_1m,
            l.end_1m,
            l.max_excess_1m,
            load_excess_limit,
            if (l.contended) "CONTENDED: another workload ran beside this bench; treat these numbers as noise" else "clean",
        });
    }
}

/// Render the same results as JSON — the recording `--baseline` reads back.
/// The top-level `budgets` object is absent here on purpose: budgets are
/// hand-set absolute caps a human adds to the committed file. The top-level
/// `load` object (and a flagged board's `load_contended`) is what lets
/// perf_gate.sh --record refuse a contended run instead of enshrining it;
/// the baseline loader ignores both.
pub fn writeResultsJson(w: *std.Io.Writer, results: []const BoardResult, load: ?LoadReport) json_writer.WriteError!void {
    try w.writeAll("{\"boards\":[");
    for (results, 0..) |r, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try json_writer.writeString(w, r.name);
        try w.print(",\"ok\":{s},\"placed\":{s},\"parts\":{d},\"sidecar_bytes\":{d}", .{
            if (r.ok) "true" else "false", if (r.facts.placed) "true" else "false", r.facts.parts, r.facts.sidecar_bytes,
        });
        inline for (Phases.names) |fname| {
            try w.print(",\"{s}\":{d:.3}", .{ fname, r.phases.get(fname) });
        }
        try w.print(",\"drc_total\":{d},\"drc_errors\":{d},\"{s}\":{d},\"cached\":{s},\"html_bytes\":{d},\"unstable\":{s}", .{
            r.drc.total,
            r.drc.errors,
            net_open_key,
            r.drc.net_open,
            if (r.facts.cached) "true" else "false",
            r.facts.html_bytes,
            if (r.facts.unstable) "true" else "false",
        });
        // Written only when it fired, so clean recordings stay byte-stable
        // across this label's introduction.
        if (r.load_contended) try w.writeAll(",\"load_contended\":true");
        try w.writeAll("}");
    }
    try w.writeAll("]");
    if (load) |l| {
        try w.print(",\"load\":{{\"start_1m\":{d:.2},\"end_1m\":{d:.2},\"max_excess_1m\":{d:.2},\"excess_limit_1m\":{d:.2},\"contended\":{s}}}", .{
            l.start_1m,
            l.end_1m,
            l.max_excess_1m,
            load_excess_limit,
            if (l.contended) "true" else "false",
        });
    }
    try w.writeAll("}\n");
}

// ── Baseline gate ───────────────────────────────────────────────────────────

/// One board's expect row inside a committed baseline file.
const BaselineBoard = struct {
    name: []const u8,
    ok: bool = false,
    placed: bool = false,
    phases: Phases = .{},
    drc: DrcCounts = .{},
    cached: bool = false,
};

/// Hand-set absolute caps, per phase, applied to EVERY board. Null = no cap.
/// These live only in the committed baseline file (a human edits them in);
/// the recorder never writes them, so re-recording cannot silently raise one.
const Budgets = struct {
    caps: [Phases.names.len]?f64 = @splat(null),

    fn get(self: Budgets, comptime name: []const u8) ?f64 {
        inline for (Phases.names, 0..) |fname, i| {
            if (comptime std.mem.eql(u8, fname, name)) return self.caps[i];
        }
        return null;
    }
};

/// A committed `--json` output re-read, plus any hand-added budgets.
const Baseline = struct {
    boards: []const BaselineBoard = &.{},
    budgets: Budgets = .{},

    fn board(self: Baseline, name: []const u8) ?BaselineBoard {
        for (self.boards) |b| {
            if (b.ok and std.mem.eql(u8, b.name, name)) return b;
        }
        return null;
    }
};

fn jsonF64(v: ?std.json.Value) f64 {
    const val = v orelse return 0;
    return switch (val) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => 0,
    };
}

fn jsonUscalar(v: ?std.json.Value) usize {
    const val = v orelse return 0;
    return if (val == .integer and val.integer > 0) @intCast(val.integer) else 0;
}

fn jsonBool(v: ?std.json.Value) bool {
    const val = v orelse return false;
    return val == .bool and val.bool;
}

/// Parse a committed baseline back into rows + budgets. Any read/parse failure
/// surfaces as a gate failure, never a silent pass.
fn loadBaseline(arena: std.mem.Allocator, path: []const u8) !Baseline {
    const data = infra_fs.cwd().readFileAlloc(arena, path, 4 * 1024 * 1024) catch return error.BaselineUnreadable;
    return parseBaseline(arena, data);
}

fn parseBaseline(arena: std.mem.Allocator, data: []const u8) !Baseline {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{}) catch return error.BaselineInvalid;
    var out = Baseline{};
    if (root != .object) return error.BaselineInvalid;
    if (root.object.get("boards")) |arr| {
        if (arr != .array) return error.BaselineInvalid;
        var boards: std.ArrayList(BaselineBoard) = .empty;
        for (arr.array.items) |it| {
            if (it != .object) continue;
            const nm = it.object.get("name") orelse continue;
            if (nm != .string) continue;
            var b = BaselineBoard{
                .name = nm.string,
                .ok = jsonBool(it.object.get("ok")),
                .placed = jsonBool(it.object.get("placed")),
                .drc = .{
                    .total = jsonUscalar(it.object.get("drc_total")),
                    .errors = jsonUscalar(it.object.get("drc_errors")),
                    .net_open = jsonUscalar(it.object.get(net_open_key)),
                },
                .cached = jsonBool(it.object.get("cached")),
            };
            inline for (Phases.names) |fname| {
                b.phases.set(fname, jsonF64(it.object.get(fname)));
            }
            try boards.append(arena, b);
        }
        out.boards = try boards.toOwnedSlice(arena);
    }
    if (root.object.get("budgets")) |budgets| {
        if (budgets == .object) {
            inline for (Phases.names, 0..) |fname, i| {
                if (budgets.object.get(fname)) |v| out.budgets.caps[i] = jsonF64(v);
            }
        }
    }
    return out;
}

/// One gate finding, worded so the failure names the rule that fired.
const Breach = struct {
    board: []const u8,
    phase: []const u8,
    now_ms: f64,
    limit_ms: f64,
    rule: enum { allowance, budget },
};

/// The verdict of one baseline comparison.
const BaselineReport = struct {
    pass: bool,
    breaches: []const Breach = &.{},
    /// Per-phase geomean of now/baseline ratios over the shared board set.
    drift: [Phases.names.len]f64 = @splat(1),
    drift_failed: bool = false,
    /// Boards whose DRC counts moved — the runs did different work, so their
    /// wall times are not comparable. Fails the gate with a re-record hint.
    work_changed: []const []const u8 = &.{},
    /// A board the baseline retained that this run does not — every later
    /// load turned cold. As much a page-load regression as any timing.
    retention_lost: []const []const u8 = &.{},
    /// Boards without a blessed layout (this run or the baseline's): their PCB
    /// and thermal timings and DRC counts are not comparable. Assembly and
    /// schematic remain gated because neither depends on PCB placement.
    unplaced: []const []const u8 = &.{},
    /// Measured now but absent from the baseline — noted, never a silent pass.
    unlined: []const []const u8 = &.{},
    /// In the baseline but not measured now — noted (a renamed or removed
    /// design is a corpus change, not a code regression).
    missing: []const []const u8 = &.{},
};

/// A phase median regresses when it exceeds BOTH bounds: `base * ratio_limit`
/// (the relative rule) and `base + abs_floor_ms` (the noise floor that keeps
/// millisecond-scale boards from failing on jitter).
fn phaseAllowance(base: f64) f64 {
    return @max(base * ratio_limit, base + abs_floor_ms);
}

/// These renders depend only on the evaluated design and its review/BOM
/// siblings, so a board's unstable generated placement cannot make them noisy.
fn placementIndependent(comptime phase: []const u8) bool {
    return comptime (std.mem.eql(u8, phase, "assembly_page_ms") or
        std.mem.eql(u8, phase, "schematic_page_ms"));
}

/// Compare the run against a committed baseline: per-board phase allowances,
/// per-phase corpus drift, hand-set absolute budgets, DRC-count parity, and
/// cache-retention parity.
fn checkBaseline(
    arena: std.mem.Allocator,
    results: []const BoardResult,
    baseline: *const Baseline,
) std.mem.Allocator.Error!BaselineReport {
    var breaches: std.ArrayList(Breach) = .empty;
    var work_changed: std.ArrayList([]const u8) = .empty;
    var retention_lost: std.ArrayList([]const u8) = .empty;
    var unplaced: std.ArrayList([]const u8) = .empty;
    var unlined: std.ArrayList([]const u8) = .empty;
    var missing: std.ArrayList([]const u8) = .empty;
    var drift_sum: [Phases.names.len]f64 = @splat(0);
    var drift_n: [Phases.names.len]usize = @splat(0);

    for (results) |r| {
        if (!r.ok) continue;
        const base = baseline.board(r.name) orelse {
            try unlined.append(arena, r.name);
            continue;
        };
        const placed = r.facts.placed and base.placed;
        if (!placed) {
            try unplaced.append(arena, r.name);
        }
        const same_drc = r.drc.eql(base.drc);
        if (placed and !same_drc) {
            try work_changed.append(arena, r.name);
        }
        if (placed and base.cached and !r.facts.cached) try retention_lost.append(arena, r.name);
        inline for (Phases.names, 0..) |fname, i| {
            // PCB/DRC/thermal numbers require the same blessed placement and
            // identical DRC work. Assembly and schematic remain comparable
            // even when either of those physical-layout invariants moves.
            const comparable = placementIndependent(fname) or (placed and same_drc);
            if (comparable) {
                const now = r.phases.get(fname);
                const was = base.phases.get(fname);
                if (now > phaseAllowance(was)) try breaches.append(arena, .{
                    .board = r.name,
                    .phase = fname,
                    .now_ms = now,
                    .limit_ms = phaseAllowance(was),
                    .rule = .allowance,
                });
                if (baseline.budgets.get(fname)) |cap| {
                    if (now > cap) try breaches.append(arena, .{
                        .board = r.name,
                        .phase = fname,
                        .now_ms = now,
                        .limit_ms = cap,
                        .rule = .budget,
                    });
                }
                // Drift deadband: a delta inside the absolute noise floor is
                // not evidence in either direction and contributes ratio 1.0.
                if (@abs(now - was) > abs_floor_ms) {
                    drift_sum[i] += @log(@max(now, 0.001) / @max(was, 0.001));
                }
                drift_n[i] += 1;
            }
        }
    }
    for (baseline.boards) |b| {
        if (!b.ok) continue;
        var found = false;
        for (results) |r| {
            if (r.ok and std.mem.eql(u8, r.name, b.name)) found = true;
        }
        if (!found) try missing.append(arena, b.name);
    }

    var report = BaselineReport{ .pass = true };
    inline for (Phases.names, 0..) |_, i| {
        if (drift_n[i] > 0) {
            report.drift[i] = @exp(drift_sum[i] / @as(f64, @floatFromInt(drift_n[i])));
            if (report.drift[i] > drift_limit) report.drift_failed = true;
        }
    }
    report.breaches = try breaches.toOwnedSlice(arena);
    report.work_changed = try work_changed.toOwnedSlice(arena);
    report.retention_lost = try retention_lost.toOwnedSlice(arena);
    report.unplaced = try unplaced.toOwnedSlice(arena);
    report.unlined = try unlined.toOwnedSlice(arena);
    report.missing = try missing.toOwnedSlice(arena);
    report.pass = report.breaches.len == 0 and !report.drift_failed and
        report.work_changed.len == 0 and report.retention_lost.len == 0;
    return report;
}

/// Write the human-readable baseline verdict.
fn writeBaselineReport(w: *std.Io.Writer, report: BaselineReport, baseline_path: []const u8) std.Io.Writer.Error!void {
    try w.print("\n— page-latency gate vs {s} —\n", .{baseline_path});
    if (report.breaches.len == 0) {
        try w.print("  phase medians: every board within its allowance (≤ max(base×{d:.2}, base+{d:.0}ms)) and budget (OK)\n", .{ ratio_limit, abs_floor_ms });
    } else for (report.breaches) |b| {
        try w.print("  REGRESSED {s} {s}: {d:.1} ms > {s} {d:.1} ms\n", .{
            b.board, b.phase, b.now_ms, if (b.rule == .budget) "budget" else "allowance", b.limit_ms,
        });
    }
    try w.writeAll("  corpus drift (geomean now/base):");
    inline for (Phases.names, 0..) |fname, i| {
        try w.print(" {s}={d:.3}", .{ fname, report.drift[i] });
    }
    try w.print(" (limit {d:.2}: {s})\n", .{ drift_limit, if (report.drift_failed) "DRIFT" else "OK" });
    if (report.work_changed.len > 0) {
        try w.writeAll("  DRC COUNTS MOVED (unlike work — re-record the baseline if the designs changed):");
        for (report.work_changed) |n| try w.print(" {s}", .{n});
        try w.writeAll("\n");
    }
    if (report.retention_lost.len > 0) {
        try w.writeAll("  RETENTION LOST (page no longer admitted to the cache — every reload is cold):");
        for (report.retention_lost) |n| try w.print(" {s}", .{n});
        try w.writeAll("\n");
    }
    if (report.unplaced.len > 0) {
        try w.writeAll("  note: no blessed layout — PCB/thermal phases not gated; assembly/schematic still gated:");
        for (report.unplaced) |n| try w.print(" {s}", .{n});
        try w.writeAll("\n");
    }
    if (report.unlined.len > 0) {
        try w.writeAll("  note: measured now but not in baseline:");
        for (report.unlined) |n| try w.print(" {s}", .{n});
        try w.writeAll("\n");
    }
    if (report.missing.len > 0) {
        try w.writeAll("  note: in baseline but not measured now:");
        for (report.missing) |n| try w.print(" {s}", .{n});
        try w.writeAll("\n");
    }
    try w.print("  result: {s}\n", .{if (report.pass) "PASS" else "FAIL — page latency regression"});
}

// ── CLI ─────────────────────────────────────────────────────────────────────

/// The harness's parsed command line: the flags every bench harness shares,
/// plus this one's own.
const Args = struct {
    cli: bench_args.Common = .{},
    reps: usize = 3,
};

fn parseArgs(arena: std.mem.Allocator, args: []const []const u8) std.mem.Allocator.Error!Args {
    var out = Args{};
    try out.cli.parse(arena, args, &out, takeExtra);
    return out;
}

/// `--reps <n>` — bench-page's only flag of its own. An unparseable count
/// keeps the default rather than failing the run.
fn takeExtra(out: *Args, args: []const []const u8, i: *usize) bool {
    if (!std.mem.eql(u8, args[i.*], "--reps")) return false;
    i.* += 1;
    if (i.* < args.len) out.reps = std.fmt.parseInt(usize, args[i.*], 10) catch out.reps;
    return true;
}

/// CLI entry: `netlisp bench-page [--project-dir <dir>] [--reps <n>] [--json]
/// [--baseline <file>] [<design> ...]`.
pub fn cmdBenchPage(allocator: std.mem.Allocator, args: []const []const u8) BenchError!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parseArgs(arena, args);
    const names = if (parsed.cli.named.items.len > 0)
        parsed.cli.named.items
    else
        try corpus(arena, parsed.cli.project_dir);

    var watch = LoadWatch.begin();
    var results: std.ArrayList(BoardResult) = .empty;
    for (names) |n| {
        var row = try benchOne(allocator, arena, parsed.cli.project_dir, n, parsed.reps);
        row.load_contended = watch.sample();
        try results.append(arena, row);
    }
    const load = watch.report();

    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(infra_fs.currentIo(), &buf);
    if (parsed.cli.json) try writeResultsJson(&fw.interface, results.items, load) else try writeTable(&fw.interface, results.items, parsed.reps, load);

    // The durable regression gate: record with `--json > baseline.json`,
    // commit it, and every later gated run compares against it. A missing or
    // corrupt baseline is never a pass.
    if (parsed.cli.baseline) |path| {
        const baseline = loadBaseline(arena, path) catch return error.PageBaselineRegression;
        const report = checkBaseline(arena, results.items, &baseline) catch return error.PageBaselineRegression;
        try writeBaselineReport(&fw.interface, report, path);
        // Contention never flips the verdict — numbers under their limits
        // despite noise passed honestly, and a labelled FAIL tells the reader
        // to re-run quiet before believing the regression.
        if (load) |l| if (l.contended) {
            try fw.interface.print("  note: this run was CONTENDED (1-min load {d:.2} past the quiet-machine model) — a FAIL above may be machine noise; re-run gated on a quiet machine before believing it\n", .{l.max_excess_1m});
        };
        try fw.interface.flush();
        if (!report.pass) return error.PageBaselineRegression;
    }
    try fw.interface.flush();
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn sampleResult(name: []const u8) BoardResult {
    return .{
        .name = name,
        .ok = true,
        .phases = .{
            .eval_ms = 40,
            .sidecar_ms = 90,
            .solve_ms = 200,
            .drc_report_ms = 300,
            .drc_geom_ms = 40,
            .pages = .{ .pcb = 900, .assembly = 120, .thermal = 450, .schematic = 180 },
        },
        .drc = .{ .total = 12, .errors = 1, .net_open = 3 },
        .facts = .{ .parts = 100, .sidecar_bytes = 7 << 20, .html_bytes = 1 << 20, .cached = true, .placed = true },
    };
}

fn sampleBaselineJson(arena: std.mem.Allocator) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const results = [_]BoardResult{sampleResult("barracuda")};
    try writeResultsJson(&aw.writer, &results, null);
    return aw.written();
}

// spec: bench-page - the CLI parses project dir, reps, output and baseline flags with positionals as design names
test "bench-page CLI parses flags and positionals" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = try parseArgs(arena, &.{ "--project-dir", "p", "--reps", "5", "--json", "--baseline", "b.json", "barracuda" });
    try testing.expectEqualStrings("p", parsed.cli.project_dir);
    try testing.expectEqual(@as(usize, 5), parsed.reps);
    try testing.expect(parsed.cli.json);
    try testing.expectEqualStrings("b.json", parsed.cli.baseline.?);
    try testing.expectEqualStrings("barracuda", parsed.cli.named.items[0]);
    const defaults = try parseArgs(arena, &.{});
    try testing.expectEqual(@as(usize, 3), defaults.reps);
    try testing.expect(!defaults.cli.json and defaults.cli.baseline == null);
}

// spec: bench-page - phase medians are the outlier-tolerant middle of the rep samples
test "median takes the middle sample and averages an even pair" {
    var odd = [_]f64{ 900, 30, 32 };
    try testing.expectEqual(@as(f64, 32), median(&odd));
    var even = [_]f64{ 10, 30 };
    try testing.expectEqual(@as(f64, 20), median(&even));
    try testing.expectEqual(@as(f64, 0), median(&.{}));
}

// spec: bench-page - the JSON recording round-trips through the baseline loader with every phase and invariant intact
test "baseline JSON round-trips the recorded run" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const json = try sampleBaselineJson(arena);
    const base = try parseBaseline(arena, json);
    const b = base.board("barracuda").?;
    try testing.expectEqual(@as(f64, 900), b.phases.pages.pcb);
    try testing.expectEqual(@as(f64, 120), b.phases.pages.assembly);
    try testing.expectEqual(@as(f64, 450), b.phases.pages.thermal);
    try testing.expectEqual(@as(f64, 180), b.phases.pages.schematic);
    try testing.expectEqual(@as(f64, 300), b.phases.drc_report_ms);
    try testing.expectEqual(@as(usize, 12), b.drc.total);
    try testing.expectEqual(@as(usize, 3), b.drc.net_open);
    try testing.expect(b.cached);
    try testing.expect(b.placed);
    // The recorder never writes budgets; they arrive only by hand-editing.
    inline for (Phases.names, 0..) |_, i| try testing.expect(base.budgets.caps[i] == null);
}

// spec: bench-page - the --baseline gate passes a run identical to its committed baseline
test "baseline gate passes an unchanged run" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try parseBaseline(arena, try sampleBaselineJson(arena));
    const results = [_]BoardResult{sampleResult("barracuda")};
    const report = try checkBaseline(arena, &results, &base);
    try testing.expect(report.pass);
    try testing.expectEqual(@as(usize, 0), report.breaches.len);
}

// spec: bench-page - a phase past both the ratio and absolute allowance fails the gate and names the board, phase, and limit
test "baseline gate fails a real phase regression" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try parseBaseline(arena, try sampleBaselineJson(arena));
    var slower = sampleResult("barracuda");
    slower.phases.pages.pcb = 1400; // baseline 900: past 900×1.30=1170 and 900+25
    const report = try checkBaseline(arena, &.{slower}, &base);
    try testing.expect(!report.pass);
    try testing.expectEqual(@as(usize, 1), report.breaches.len);
    try testing.expectEqualStrings("barracuda", report.breaches[0].board);
    try testing.expectEqualStrings("page_ms", report.breaches[0].phase);
}

// spec: bench-page - millisecond-scale jitter under the absolute floor never fails the ratio rule
test "baseline gate tolerates small-board jitter under the absolute floor" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try parseBaseline(arena, try sampleBaselineJson(arena));
    var jitter = sampleResult("barracuda");
    jitter.phases.drc_geom_ms = 60; // baseline 40: 1.5× but only +20ms, under the 25ms floor
    const report = try checkBaseline(arena, &.{jitter}, &base);
    try testing.expect(report.pass);
}

// spec: bench-page - corpus-wide drift fails the gate even when every board stays inside its own allowance
test "baseline gate fails on corpus drift below the per-board allowance" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(arena);
    const recorded = [_]BoardResult{ sampleResult("a"), sampleResult("b"), sampleResult("c") };
    try writeResultsJson(&aw.writer, &recorded, null);
    const base = try parseBaseline(arena, aw.written());
    var now: [3]BoardResult = .{ sampleResult("a"), sampleResult("b"), sampleResult("c") };
    // Every page median 20% up: inside the 1.30 per-board ratio, over the
    // 1.10 corpus drift bound (the floor doesn't shelter 900ms boards).
    for (&now) |*r| r.phases.pages.pcb = 1080;
    const report = try checkBaseline(arena, &now, &base);
    try testing.expect(!report.pass);
    try testing.expect(report.drift_failed);
    try testing.expectEqual(@as(usize, 0), report.breaches.len);
}

// spec: bench-page - a hand-set absolute budget in the baseline file caps every board regardless of the recorded medians
test "baseline gate enforces hand-set absolute budgets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(arena);
    const recorded = [_]BoardResult{sampleResult("barracuda")};
    try writeResultsJson(&aw.writer, &recorded, null);
    // Splice a budgets object in, as a human editing the committed file would.
    const with_budget = try std.mem.concat(arena, u8, &.{
        aw.written()[0 .. aw.written().len - 2], // drop "}\n"
        ",\"budgets\":{\"page_ms\":800}}",
    });
    const base = try parseBaseline(arena, with_budget);
    const results = [_]BoardResult{sampleResult("barracuda")}; // page 900 > cap 800
    const report = try checkBaseline(arena, &results, &base);
    try testing.expect(!report.pass);
    try testing.expectEqual(@as(usize, 1), report.breaches.len);
    try testing.expect(report.breaches[0].rule == .budget);
}

// spec: bench-page - a board without a blessed layout skips layout-dependent PCB/thermal phases but still gates its stable assembly and schematic renders
test "baseline gate skips an unblessed board with a note" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(arena);
    var loose = sampleResult("free-solver");
    loose.facts.placed = false;
    const recorded = [_]BoardResult{ sampleResult("blessed"), loose };
    try writeResultsJson(&aw.writer, &recorded, null);
    const base = try parseBaseline(arena, aw.written());
    // The unblessed board comes back wildly different — different counts,
    // triple the wall — and the gate still passes, with it named in the note.
    var wild = loose;
    wild.drc.total = 999;
    wild.phases.pages.pcb = 2700;
    const results = [_]BoardResult{ sampleResult("blessed"), wild };
    const report = try checkBaseline(arena, &results, &base);
    try testing.expect(report.pass);
    try testing.expectEqual(@as(usize, 1), report.unplaced.len);
    try testing.expectEqualStrings("free-solver", report.unplaced[0]);
    try testing.expectEqual(@as(usize, 0), report.work_changed.len);
}

// The positive half of the spec above: stable page regressions still fail.
test "baseline gate still checks stable pages on an unblessed board" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var base_row = sampleResult("free-solver");
    base_row.facts.placed = false;
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeResultsJson(&aw.writer, &.{base_row}, null);
    const base = try parseBaseline(arena, aw.written());

    var slower = base_row;
    slower.phases.pages.assembly = 300;
    slower.phases.pages.schematic = 500;
    const report = try checkBaseline(arena, &.{slower}, &base);
    try testing.expect(!report.pass);
    try testing.expectEqual(@as(usize, 2), report.breaches.len);
}

// spec: bench-page - moved DRC counts mean unlike work, which fails the gate with a re-record hint instead of comparing wall times
test "baseline gate refuses to compare unlike work" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try parseBaseline(arena, try sampleBaselineJson(arena));
    var changed = sampleResult("barracuda");
    changed.drc.total = 13;
    changed.phases.pages.pcb = 1; // even a huge speedup is not comparable
    const report = try checkBaseline(arena, &.{changed}, &base);
    try testing.expect(!report.pass);
    try testing.expectEqual(@as(usize, 1), report.work_changed.len);
    try testing.expectEqual(@as(usize, 0), report.breaches.len);
}

// spec: bench-page - losing page-cache retention fails the gate even when every timing column improved
test "baseline gate fails a board that stopped being cacheable" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try parseBaseline(arena, try sampleBaselineJson(arena));
    var uncached = sampleResult("barracuda");
    uncached.facts.cached = false;
    const report = try checkBaseline(arena, &.{uncached}, &base);
    try testing.expect(!report.pass);
    try testing.expectEqual(@as(usize, 1), report.retention_lost.len);
}

// spec: bench-page - new and vanished boards are noted rather than silently passing or failing the gate
test "baseline gate notes unlined and missing boards" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(arena);
    const recorded = [_]BoardResult{ sampleResult("kept"), sampleResult("vanished") };
    try writeResultsJson(&aw.writer, &recorded, null);
    const base = try parseBaseline(arena, aw.written());
    const results = [_]BoardResult{ sampleResult("kept"), sampleResult("brand-new") };
    const report = try checkBaseline(arena, &results, &base);
    try testing.expect(report.pass); // notes, not failures
    try testing.expectEqual(@as(usize, 1), report.unlined.len);
    try testing.expectEqualStrings("brand-new", report.unlined[0]);
    try testing.expectEqual(@as(usize, 1), report.missing.len);
    try testing.expectEqualStrings("vanished", report.missing[0]);
}

// spec: bench-page - a missing or corrupt baseline is a gate failure, never a pass
test "baseline gate refuses a corrupt baseline" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.BaselineInvalid, parseBaseline(arena, "not json at all"));
    try testing.expectError(error.BaselineInvalid, parseBaseline(arena, "[1,2,3]"));
    try testing.expectError(error.BaselineUnreadable, loadBaseline(arena, "/definitely/not/a/file.json"));
}

// spec: bench-page - a failed board renders as FAILED in the table and carries ok=false in JSON
test "table and JSON report a failed board without medians" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const rows = [_]BoardResult{ sampleResult("good"), .{ .name = "broken" } };
    try writeTable(&w, &rows, 3, null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "FAILED") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "good") != null);
    var jbuf: [2048]u8 = undefined;
    var jw = std.Io.Writer.fixed(&jbuf);
    try writeResultsJson(&jw, &rows, null);
    try testing.expect(std.mem.indexOf(u8, jw.buffered(), "\"name\":\"broken\",\"ok\":false") != null);
}

// spec: bench-page - a page render the cache refused is flagged in the table so a silent every-load-cold regression is visible
test "table flags a render the page cache did not retain" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var uncached = sampleResult("big-board");
    uncached.facts.cached = false;
    try writeTable(&w, &.{uncached}, 3, null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "NOT retained") != null);
}

// spec: bench-page - the load tripwire parses the leading 1-minute loadavg figure and refuses malformed content
test "loadavg parse takes the 1-minute figure and refuses garbage" {
    try testing.expectEqual(@as(f64, 0.42), parseLoad1m("0.42 0.36 0.30 2/1250 12345\n").?);
    try testing.expect(parseLoad1m("") == null);
    try testing.expect(parseLoad1m("   \n") == null);
    try testing.expect(parseLoad1m("not-a-load 1 2") == null);
}

// spec: bench-page - the load model forgives a high start decaying after a gated build and the bench's own busy core
test "load model forgives post-build decay and its own core" {
    // Quiet machine: five minutes in, the only load is the bench's own core.
    try testing.expect(1.1 - expectedLoad(0.1, 300.0) < load_excess_limit);
    // perf_gate.sh runs two parallel `zig build`s seconds before the bench
    // starts (1-min load 8 at start); three minutes later the observed ~1.4
    // is the modelled decay plus this process, nowhere near the limit.
    try testing.expect(1.4 - expectedLoad(8.0, 180.0) < 1.0);
}

// spec: bench-page - load that persists or arrives mid-run exceeds the decay model and labels the run contended
test "load model flags persisting and arriving workloads" {
    // A sibling already running at start (1-min load 4) does not fade the way
    // a finished build would: five minutes in, the model expects ~1 and the
    // machine still shows ~4.8 — the FEEDBACK.md 2026-08-29 case.
    try testing.expect(4.8 - expectedLoad(4.0, 300.0) > load_excess_limit);
    // A parallel test shard arriving mid-run on a machine that started quiet.
    try testing.expect(9.0 - expectedLoad(0.2, 240.0) > load_excess_limit);
}

// spec: bench-page - a contended run is labelled in the table and JSON so it cannot be recorded as a clean baseline silently
test "contended runs are labelled in table and JSON" {
    var flagged = sampleResult("barracuda");
    flagged.load_contended = true;
    const noisy = LoadReport{ .start_1m = 0.2, .end_1m = 4.6, .max_excess_1m = 3.6, .contended = true };
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeTable(&w, &.{flagged}, 3, noisy);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "CONTENDED") != null);
    var jbuf: [4096]u8 = undefined;
    var jw = std.Io.Writer.fixed(&jbuf);
    try writeResultsJson(&jw, &.{flagged}, noisy);
    try testing.expect(std.mem.indexOf(u8, jw.buffered(), "\"load_contended\":true") != null);
    try testing.expect(std.mem.indexOf(u8, jw.buffered(), "\"load\":{") != null);
    try testing.expect(std.mem.indexOf(u8, jw.buffered(), "\"contended\":true") != null);

    // The labels ride beside the boards without disturbing the baseline
    // loader — a labelled recording still round-trips its rows.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try parseBaseline(arena, jw.buffered());
    try testing.expect(base.board("barracuda") != null);

    // A clean run carries no per-board label and says contended:false, the
    // fact perf_gate.sh --record checks before installing a recording.
    const clean = LoadReport{ .start_1m = 0.2, .end_1m = 1.1, .max_excess_1m = 0.1, .contended = false };
    var cbuf: [4096]u8 = undefined;
    var cw = std.Io.Writer.fixed(&cbuf);
    try writeResultsJson(&cw, &.{sampleResult("barracuda")}, clean);
    try testing.expect(std.mem.indexOf(u8, cw.buffered(), "load_contended") == null);
    try testing.expect(std.mem.indexOf(u8, cw.buffered(), "\"contended\":false") != null);
}

// spec: bench-page - the page-cache retention probe asks under the same entry and live version the page warm admitted, so a cached page is never reported as NOT retained
test "retention probe answers for the entry the page warm filled" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "src", .default_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/demo.sexp", .data = "(design demo)" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "src/demo.layouts.json", .data = "{}" });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    // The layout-sidecar freshness check `store` asks after stamping. The page
    // phase renders boards whose sidecar nobody is editing, so this test wants
    // the "nothing moved" answer. Local to the test: a stub is not API.
    const StubRev = struct {
        pub fn moved(_: @This()) bool {
            return false;
        }
    };

    var cache: pcb_page_cache.Store = .{ .allocator = testing.allocator };
    defer cache.deinit();

    // A board no render admitted: the probe reports the miss AND releases the
    // claim it took to find out, so asking twice cannot answer differently.
    try testing.expect(!pageRetained(&cache, testing.allocator, "demo"));
    try testing.expect(!pageRetained(&cache, testing.allocator, "demo"));

    // Admit the plain page exactly as the warm does, then probe: the refusal
    // is the retention. A probe naming another entry or another version would
    // be granted here and call this cached page cold.
    var eval = Evaluator.init(testing.allocator, root);
    defer eval.deinit();
    var page = httpz.testing.init(.{});
    defer page.deinit();
    var version: ?u32 = null;
    try testing.expect(!cache.serve(.{ .scratch = page.arena, .name = "demo", .live_version = 0 }, page.req, page.res, &version));
    page.res.status = 200;
    page.res.content_type = .HTML;
    page.res.body = "<html></html>";
    cache.store(.{
        .scratch = page.arena,
        .project_dir = root,
        .name = "demo",
        .req = page.req,
        .eval = &eval,
        .res = page.res,
        .live_version = version,
        .current_version = @as(u32, 0),
        .layout_rev = StubRev{},
    });
    try testing.expect(pageRetained(&cache, testing.allocator, "demo"));
}
