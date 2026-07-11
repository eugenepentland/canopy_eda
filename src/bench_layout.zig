//! Slim standalone benchmark for the PCB-layout placement optimizer
//! (`placement/optimizer.zig`). Evaluates one or more designs and times
//! `optimizer.solve` on each, reporting median / min wall-clock time plus a
//! grid-quantized pose checksum.
//!
//! The checksum is the *correctness gate* for a speed experiment: final poses
//! snap to `optimizer.grid_mm`, so quantizing (x,y) to grid units and hashing
//! together with the rotation yields a value that is identical whenever the
//! layout is identical — even if SIMD/fast-math reassociation perturbs the
//! low bits of the continuous objective. A variant that prints the same
//! checksum as the baseline provably produced the same board.
//!
//! Built as its own executable (`zig build bench-layout -Doptimize=ReleaseFast`)
//! whose module pulls in only the optimizer + evaluator — not the HTTP server
//! or the render/diagram stack — so editing the optimizer rebuilds in a
//! fraction of the full `eda` build, and the step skips Guardian so a throwaway
//! perf variant compiles without baseline churn. Read-only: it never inserts
//! IDs or writes layout sidecars, so it is safe to point at a shared project
//! dir from many concurrent processes.
//!
//! Usage:
//!   bench-layout --project-dir <dir> [--reps N] <design> [<design> ...]

const std = @import("std");
const paths = @import("paths.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;
const env = @import("eval/env.zig");
const eval_modules = @import("eval/modules.zig");
const optimizer = @import("placement/optimizer.zig");
const clock = @import("infra/clock.zig");
const infra_fs = @import("infra/fs.zig");
const numeric = @import("numeric.zig");

/// Sentinel printed after the last result so a harness driver knows the run
/// finished (vs. the process dying mid-list).
const bench_done = "BENCH_DONE\n";

const default_reps: usize = 5;
const ns_per_ms: f64 = 1_000_000.0;

/// Solve/score parameters for the quality modes (`--breakdown`, `--poses`,
/// `--seed`), overridable from the CLI (`--margin`, `--no-grid-court`) so a
/// denser courtyard regime can be swept. Default-shipping otherwise. The timing
/// path (`benchOne`) always uses defaults — it measures speed, not a regime.
var g_params: optimizer.Params = .{};

const BenchResult = struct {
    parts: usize,
    median_ns: u64,
    min_ns: u64,
    checksum: u64,
    objective: f64,
    routed: f64,
};

/// Snap a millimetre coordinate to its integer grid cell. Two layouts that are
/// equal at grid resolution map to the same cell regardless of sub-ULP float
/// drift, so the checksum is robust to floating-point reassociation.
fn quantize(v: f64) i64 {
    return numeric.checkedInt(i64, @round(v / optimizer.grid_mm)) orelse 0;
}

/// Order-sensitive hash over every part's (ref_des, grid x, grid y, rotation).
/// `prepare` builds parts in a deterministic flatten order that variants must
/// not change, so hashing in order also catches an accidental reordering.
fn poseChecksum(placement: optimizer.Placement) u64 {
    var h = std.hash.Wyhash.init(0x9e3779b97f4a7c15);
    for (placement.parts) |p| {
        h.update(p.ref_des);
        const qx = quantize(p.x);
        const qy = quantize(p.y);
        const qr: i64 = numeric.checkedInt(i64, @round(p.rot)) orelse 0;
        h.update(std.mem.asBytes(&qx));
        h.update(std.mem.asBytes(&qy));
        h.update(std.mem.asBytes(&qr));
    }
    return h.final();
}

/// Resolve `name` to a design block: a top-level `(design-block …)` is used
/// as-is; a bare `lib/modules/<name>.sexp` module (where `evalFile` returned
/// .nil after running the `(defmodule …)`) is instantiated standalone via
/// its parameter defaults. Lets every bench mode accept a module name the
/// same way the CLI build/check/export paths do.
fn resolveBlock(eval: *Evaluator, result: env.Value, name: []const u8) !*env.DesignBlock {
    return switch (result) {
        .design_block => |b| b,
        else => switch (try eval_modules.instantiateStandalone(eval, name)) {
            .design_block => |b| b,
            else => error.NotADesignBlock,
        },
    };
}

/// Evaluate `name` under `project_dir`, then time `optimizer.solve` (full
/// from-scratch placement: `cached = null`, `.place`) over `reps` reps after one
/// warm-up that also fixes the checksum and part count. Each rep runs in an
/// arena reset to retained capacity so allocator growth isn't charged to the
/// hot path. Returns the per-design result, or an error if the design can't be
/// evaluated to a design block.
fn benchOne(
    gpa: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    reps: usize,
    times: []u64,
) !BenchResult {
    const path = try paths.designSourcePath(gpa, project_dir, name);
    defer gpa.free(path);

    var eval = Evaluator.init(gpa, project_dir);
    defer eval.deinit();

    const result = try eval.evalFile(path);
    const block = try resolveBlock(&eval, result, name);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // Warm-up: caches, page faults, and the (deterministic) checksum.
    const warm = try optimizer.solve(arena.allocator(), block, project_dir, null, .{}, .place);
    const checksum = poseChecksum(warm);
    const parts = warm.parts.len;
    const objective = warm.breakdown.objective;
    // Routed objective of the finished placement — the metric `rerankSolve`
    // actually selects on (the surrogate `objective` above is what the page's
    // drag-score reports). Lets a placement experiment be judged on the same
    // metric the rerank path optimizes, not just the surrogate proxy.
    const poses = try arena.allocator().alloc(optimizer.RefPose, warm.parts.len);
    for (warm.parts, 0..) |p, i| poses[i] = .{ .ref = p.ref_des, .x = p.x, .y = p.y, .rot = p.rot };
    const routed = try optimizer.routedScorePoses(arena.allocator(), block, project_dir, poses, .{});
    _ = arena.reset(.retain_capacity);

    var rep: usize = 0;
    while (rep < reps) : (rep += 1) {
        const t0 = clock.nanoTimestamp();
        const pl = try optimizer.solve(arena.allocator(), block, project_dir, null, .{}, .place);
        const ns: u64 = @intCast(clock.nanoTimestamp() - t0);
        std.mem.doNotOptimizeAway(pl.parts.len);
        times[rep] = ns;
        _ = arena.reset(.retain_capacity);
    }
    std.mem.sort(u64, times[0..reps], {}, std.sort.asc(u64));
    return .{
        .parts = parts,
        .median_ns = times[reps / 2],
        .min_ns = times[0],
        .checksum = checksum,
        .objective = objective,
        .routed = routed,
    };
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / ns_per_ms;
}

/// A pose read from a `--poses <file>` JSON array: `[{"ref","x","y","rot"}, …]`.
/// Mirrors the `parts` array a saved `.layouts.json` entry stores, so a layout
/// (e.g. the hand-tuned "Best2") can be re-scored under the *current* engine —
/// the saved `objective` in the sidecar was computed by whatever engine version
/// wrote it, so it is not comparable to a fresh solve from this binary.
const PoseJson = struct { ref: []const u8, x: f64, y: f64, rot: f64 };

/// Read a JSON pose array from `path` into `optimizer.RefPose`s allocated in
/// `arena`. The JSON is `[{"ref":…,"x":…,"y":…,"rot":…}, …]`.
fn loadPoses(arena: std.mem.Allocator, path: []const u8) ![]optimizer.RefPose {
    const data = try infra_fs.cwd().readFileAlloc(arena, path, 1 << 20);
    const parsed = try std.json.parseFromSliceLeaky([]PoseJson, arena, data, .{ .ignore_unknown_fields = true });
    const out = try arena.alloc(optimizer.RefPose, parsed.len);
    for (parsed, 0..) |p, i| out[i] = .{ .ref = p.ref, .x = p.x, .y = p.y, .rot = p.rot };
    return out;
}

/// Print one `Breakdown` plus an optional routed value on a single `SCORE` line
/// (kept distinct from the `BENCH` timing line so a downstream parser can tell a
/// scored-layout result from a timed solve). `tag` labels which layout it is.
fn printScore(tag: []const u8, name: []const u8, bd: optimizer.Breakdown, routed: f64) void {
    std.debug.print(
        "SCORE {s} {s} objective={d:.4} routed={d:.4} hpwl={d:.4} loop_nh_w={d:.4} loop_raw_mm={d:.4} align={d:.4} congest={d:.4} footprint={d:.4}\n",
        .{ tag, name, bd.objective, routed, bd.hpwl, bd.loop_nh_weighted, bd.loop_raw, bd.alignment, bd.congestion, bd.footprint },
    );
}

/// The params the `FULL` line is *scored* under: the objective weights pinned
/// to the shipped defaults, only the geometry knobs (`--margin`,
/// `--no-grid-court`, `--court-overlap`) carried from the CLI. The FULL cost
/// formula contains `loop_w`/`w_align`/`input_loop_boost`, so scoring a weight
/// sweep under the swept weights would change the yardstick along with the
/// solver — every config must be judged on the same fixed physical metric.
fn fullEvalParams() optimizer.Params {
    var p = optimizer.Params{};
    p.bbox_margin = g_params.bbox_margin;
    p.grid_courtyards = g_params.grid_courtyards;
    p.courtyard_overlap = g_params.courtyard_overlap;
    return p;
}

/// Print the full-route verdict for a layout on its own `FULL` line — the
/// measured-copper metric (`fullRoutedScorePoses`) the rerank arbiter selects
/// on, so sweeps and engine A/Bs are judged on real traces, vias, and DRC
/// rather than the RSMT estimate. `FULL … unroutable` when the board can't grid.
fn printFull(tag: []const u8, name: []const u8, fr: ?optimizer.FullRouted) void {
    if (fr) |f| {
        std.debug.print(
            "FULL {s} {s} cost={d:.4} trace_mm={d:.2} vias={d} drc={d} unrouted={d} loop_nh_w={d:.4}\n",
            .{ tag, name, f.cost, f.trace_mm, f.vias, f.drc, f.unrouted, f.loop_nh_weighted },
        );
    } else {
        std.debug.print("FULL {s} {s} unroutable\n", .{ tag, name });
    }
}

/// Score a *fixed* set of `poses` for design `name` under the current engine —
/// both the smooth surrogate breakdown (`scorePoses`) and the routed objective
/// (`routedScorePoses`). Lets a hand layout from a `.layouts.json` be compared
/// apples-to-apples with a fresh `solve` from this same binary.
fn scoreOne(gpa: std.mem.Allocator, project_dir: []const u8, name: []const u8, tag: []const u8, poses: []const optimizer.RefPose) !void {
    const path = try paths.designSourcePath(gpa, project_dir, name);
    defer gpa.free(path);
    var eval = Evaluator.init(gpa, project_dir);
    defer eval.deinit();
    const result = try eval.evalFile(path);
    const block = try resolveBlock(&eval, result, name);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const bd = try optimizer.scorePoses(arena.allocator(), block, project_dir, poses, g_params);
    const routed = try optimizer.routedScorePoses(arena.allocator(), block, project_dir, poses, g_params);
    printScore(tag, name, bd, routed);
    const fr = try optimizer.fullRoutedScorePoses(arena.allocator(), block, project_dir, poses, fullEvalParams());
    printFull(tag, name, fr);
}

/// Diagnostic: seed `solve` with a saved layout and report whether it was
/// applied verbatim (`generated=false` ⇒ the optimizer accepts that geometry as
/// overlap-free) or rejected and re-solved (`generated=true` ⇒ those poses
/// overlap under the optimizer's courtyards, so it can never reproduce them).
/// Then run `.refine` (seed + local routed tuck) and report that breakdown too.
fn seedOne(gpa: std.mem.Allocator, project_dir: []const u8, name: []const u8, poses: []const optimizer.RefPose) !void {
    const path = try paths.designSourcePath(gpa, project_dir, name);
    defer gpa.free(path);
    var eval = Evaluator.init(gpa, project_dir);
    defer eval.deinit();
    const block = try resolveBlock(&eval, try eval.evalFile(path), name);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const placed = try optimizer.solve(arena.allocator(), block, project_dir, poses, g_params, .place);
    std.debug.print("SEED {s} applied_verbatim={} place_obj={d:.4}\n", .{ name, !placed.generated, placed.breakdown.objective });
    const refined = try optimizer.solve(arena.allocator(), block, project_dir, poses, g_params, .refine);
    const rposes = try arena.allocator().alloc(optimizer.RefPose, refined.parts.len);
    for (refined.parts, 0..) |p, i| rposes[i] = .{ .ref = p.ref_des, .x = p.x, .y = p.y, .rot = p.rot };
    const routed = try optimizer.routedScorePoses(arena.allocator(), block, project_dir, rposes, g_params);
    printScore("refine", name, refined.breakdown, routed);
}

/// Run the deterministic constraint validator (no solve) and print each
/// rejection, or `VALID` when every ref/net/pin resolves. The doc's load-bearing
/// safety check — surfaced here so a hand-authored constraint set can be linted.
fn validateOne(gpa: std.mem.Allocator, project_dir: []const u8, name: []const u8) !void {
    const path = try paths.designSourcePath(gpa, project_dir, name);
    defer gpa.free(path);
    var eval = Evaluator.init(gpa, project_dir);
    defer eval.deinit();
    const result = try eval.evalFile(path);
    const block = try resolveBlock(&eval, result, name);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const diags = try optimizer.validateConstraints(arena.allocator(), block, project_dir, .{});
    if (diags.len == 0) {
        std.debug.print("VALID {s}\n", .{name});
    } else {
        for (diags) |d| std.debug.print("REJECT {s}: {s}\n", .{ name, d });
    }
}

/// Fresh-solve a design and print its full breakdown on a `SCORE auto` line —
/// the same fields `scoreOne` prints, so a constrained vs unconstrained solve
/// can be diffed term-by-term against a hand layout.
fn breakdownOne(gpa: std.mem.Allocator, project_dir: []const u8, name: []const u8) !void {
    const path = try paths.designSourcePath(gpa, project_dir, name);
    defer gpa.free(path);
    var eval = Evaluator.init(gpa, project_dir);
    defer eval.deinit();
    const result = try eval.evalFile(path);
    const block = try resolveBlock(&eval, result, name);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const pl = try optimizer.solve(arena.allocator(), block, project_dir, null, g_params, .place);
    const poses = try arena.allocator().alloc(optimizer.RefPose, pl.parts.len);
    for (pl.parts, 0..) |p, i| poses[i] = .{ .ref = p.ref_des, .x = p.x, .y = p.y, .rot = p.rot };
    const routed = try optimizer.routedScorePoses(arena.allocator(), block, project_dir, poses, g_params);
    printScore("auto", name, pl.breakdown, routed);
    const fr = try optimizer.fullRoutedScorePoses(arena.allocator(), block, project_dir, poses, fullEvalParams());
    printFull("auto", name, fr);
}

/// CLI entry point: parse `--project-dir`, `--reps`, and the positional design
/// names, then time `optimizer.solve` on each and print a `BENCH …` line with
/// median/min wall time, the grid-quantized pose checksum, and the objective.
pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var project_dir: []const u8 = ".";
    var reps: usize = default_reps;
    var poses_file: ?[]const u8 = null;
    var tag: []const u8 = "saved";
    var want_breakdown = false;
    var want_validate = false;
    var want_seed = false;
    var names = std.ArrayList([]const u8){};
    defer names.deinit(gpa);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--project-dir") and i + 1 < args.len) {
            project_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--reps") and i + 1 < args.len) {
            // A silent fallback to DEFAULT_REPS on a typo would quietly change
            // the rep count and invalidate a timing protocol — flag it loudly.
            reps = std.fmt.parseInt(usize, args[i + 1], 10) catch blk: {
                std.debug.print("bench-layout: unparseable --reps {s}, using default {d}\n", .{ args[i + 1], default_reps });
                break :blk default_reps;
            };
            i += 1;
        } else if (std.mem.eql(u8, a, "--poses") and i + 1 < args.len) {
            // Score a fixed layout (JSON pose array) instead of timing a solve.
            poses_file = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--tag") and i + 1 < args.len) {
            tag = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--breakdown")) {
            // Fresh-solve each design and print its full term-by-term breakdown.
            want_breakdown = true;
        } else if (std.mem.eql(u8, a, "--validate")) {
            // Lint each design's constraint set against its netlist (no solve).
            want_validate = true;
        } else if (std.mem.eql(u8, a, "--seed")) {
            // Seed solve() with --poses and report verbatim-accept + refine.
            want_seed = true;
        } else if (std.mem.eql(u8, a, "--margin") and i + 1 < args.len) {
            // Override the courtyard clearance margin (mm) for the quality modes.
            g_params.bbox_margin = std.fmt.parseFloat(f64, args[i + 1]) catch g_params.bbox_margin;
            i += 1;
        } else if (std.mem.eql(u8, a, "--loop-w") and i + 1 < args.len) {
            // Objective-weight overrides for the sweep harness: solve + score
            // under these weights, judge on the FULL line's measured copper.
            g_params.loop_w = std.fmt.parseFloat(f64, args[i + 1]) catch g_params.loop_w;
            i += 1;
        } else if (std.mem.eql(u8, a, "--align-w") and i + 1 < args.len) {
            g_params.w_align = std.fmt.parseFloat(f64, args[i + 1]) catch g_params.w_align;
            i += 1;
        } else if (std.mem.eql(u8, a, "--congest-w") and i + 1 < args.len) {
            g_params.w_congest = std.fmt.parseFloat(f64, args[i + 1]) catch g_params.w_congest;
            i += 1;
        } else if (std.mem.eql(u8, a, "--boost") and i + 1 < args.len) {
            g_params.input_loop_boost = std.fmt.parseFloat(f64, args[i + 1]) catch g_params.input_loop_boost;
            i += 1;
        } else if (std.mem.eql(u8, a, "--no-grid-court")) {
            // Stop rounding courtyard half-extents up to the grid (denser pack).
            g_params.grid_courtyards = false;
        } else if (std.mem.eql(u8, a, "--court-overlap") and i + 1 < args.len) {
            // Sweep how much (mm) two courtyards may overlap in collision.
            g_params.courtyard_overlap = std.fmt.parseFloat(f64, args[i + 1]) catch g_params.courtyard_overlap;
            i += 1;
        } else if (!std.mem.startsWith(u8, a, "--")) {
            try names.append(gpa, a);
        }
    }
    if (reps == 0) reps = 1;

    if (names.items.len == 0) {
        std.debug.print("Usage: bench-layout --project-dir <dir> [--reps N] [--poses <json> --tag <t>] [--breakdown] <design> ...\n", .{});
        std.process.exit(2);
    }

    // Scoring modes short-circuit the timing path (they measure a layout's
    // quality, not how long a solve takes).
    if (poses_file) |pf| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const poses = loadPoses(arena.allocator(), pf) catch |err| {
            std.debug.print("POSES_ERR {s} {s}\n", .{ pf, @errorName(err) });
            std.process.exit(1);
        };
        for (names.items) |name| {
            if (want_seed) {
                seedOne(gpa, project_dir, name, poses) catch |err|
                    std.debug.print("SEED_ERR {s} {s}\n", .{ name, @errorName(err) });
            } else {
                scoreOne(gpa, project_dir, name, tag, poses) catch |err|
                    std.debug.print("SCORE_ERR {s} {s}\n", .{ name, @errorName(err) });
            }
        }
        std.debug.print(bench_done, .{});
        return;
    }
    if (want_validate) {
        for (names.items) |name| {
            validateOne(gpa, project_dir, name) catch |err|
                std.debug.print("VALIDATE_ERR {s} {s}\n", .{ name, @errorName(err) });
        }
        std.debug.print(bench_done, .{});
        return;
    }
    if (want_breakdown) {
        for (names.items) |name| {
            breakdownOne(gpa, project_dir, name) catch |err|
                std.debug.print("SCORE_ERR {s} {s}\n", .{ name, @errorName(err) });
        }
        std.debug.print(bench_done, .{});
        return;
    }

    const times = try gpa.alloc(u64, reps);
    defer gpa.free(times);

    std.debug.print("# bench-layout reps={d} project_dir={s}\n", .{ reps, project_dir });
    for (names.items) |name| {
        if (benchOne(gpa, project_dir, name, reps, times)) |r| {
            std.debug.print(
                "BENCH {s} parts={d} median_ms={d:.3} min_ms={d:.3} checksum={x:0>16} objective={d:.4} routed={d:.4}\n",
                .{ name, r.parts, ms(r.median_ns), ms(r.min_ns), r.checksum, r.objective, r.routed },
            );
        } else |err| {
            std.debug.print("BENCH_ERR {s} {s}\n", .{ name, @errorName(err) });
        }
    }
    std.debug.print(bench_done, .{});
}
