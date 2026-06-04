//! Slim standalone benchmark for the PCB-layout placement optimizer
//! (`placement/optimizer.zig`). Evaluates one or more designs and times
//! `optimizer.solve` on each, reporting median / min wall-clock time plus a
//! grid-quantized pose checksum.
//!
//! The checksum is the *correctness gate* for a speed experiment: final poses
//! snap to `optimizer.GRID_MM`, so quantizing (x,y) to grid units and hashing
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
const optimizer = @import("placement/optimizer.zig");

const DEFAULT_REPS: usize = 5;
const NS_PER_MS: f64 = 1_000_000.0;

const BenchResult = struct {
    parts: usize,
    median_ns: u64,
    min_ns: u64,
    checksum: u64,
    objective: f64,
};

/// Snap a millimetre coordinate to its integer grid cell. Two layouts that are
/// equal at grid resolution map to the same cell regardless of sub-ULP float
/// drift, so the checksum is robust to floating-point reassociation.
fn quantize(v: f64) i64 {
    return @intFromFloat(@round(v / optimizer.GRID_MM));
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
        const qr: i64 = @intFromFloat(@round(p.rot));
        h.update(std.mem.asBytes(&qx));
        h.update(std.mem.asBytes(&qy));
        h.update(std.mem.asBytes(&qr));
    }
    return h.final();
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
    const block: *env.DesignBlock = switch (result) {
        .design_block => |b| b,
        else => return error.NotADesignBlock,
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // Warm-up: caches, page faults, and the (deterministic) checksum.
    const warm = try optimizer.solve(arena.allocator(), block, project_dir, null, .{}, .place);
    const checksum = poseChecksum(warm);
    const parts = warm.parts.len;
    const objective = warm.breakdown.objective;
    _ = arena.reset(.retain_capacity);

    var rep: usize = 0;
    while (rep < reps) : (rep += 1) {
        var timer = try std.time.Timer.start();
        const pl = try optimizer.solve(arena.allocator(), block, project_dir, null, .{}, .place);
        const ns = timer.read();
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
    };
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / NS_PER_MS;
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var project_dir: []const u8 = ".";
    var reps: usize = DEFAULT_REPS;
    var names = std.ArrayList([]const u8){};
    defer names.deinit(gpa);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--project-dir") and i + 1 < args.len) {
            project_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--reps") and i + 1 < args.len) {
            reps = std.fmt.parseInt(usize, args[i + 1], 10) catch DEFAULT_REPS;
            i += 1;
        } else if (!std.mem.startsWith(u8, a, "--")) {
            try names.append(gpa, a);
        }
    }
    if (reps == 0) reps = 1;

    if (names.items.len == 0) {
        std.debug.print("Usage: bench-layout --project-dir <dir> [--reps N] <design> [<design> ...]\n", .{});
        std.process.exit(2);
    }

    const times = try gpa.alloc(u64, reps);
    defer gpa.free(times);

    std.debug.print("# bench-layout reps={d} project_dir={s}\n", .{ reps, project_dir });
    for (names.items) |name| {
        if (benchOne(gpa, project_dir, name, reps, times)) |r| {
            std.debug.print(
                "BENCH {s} parts={d} median_ms={d:.3} min_ms={d:.3} checksum={x:0>16} objective={d:.4}\n",
                .{ name, r.parts, ms(r.median_ns), ms(r.min_ns), r.checksum, r.objective },
            );
        } else |err| {
            std.debug.print("BENCH_ERR {s} {s}\n", .{ name, @errorName(err) });
        }
    }
    std.debug.print("BENCH_DONE\n", .{});
}
