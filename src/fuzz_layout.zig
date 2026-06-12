//! Sensitivity / fuzz harness for the PCB-layout *scoring* engine
//! (`placement/optimizer.zig`'s `scorePoses` — the exact path the server's
//! `POST /api/pcb-score` uses). Where `bench_layout.zig` times `solve`, this
//! tool answers a different question: **is the score a smooth function of where
//! a part sits?**
//!
//! It first solves the design once to get a sensible baseline layout, then —
//! holding every other part fixed — nudges one part at a time through a fine,
//! sub-grid sweep of x and y displacements and the four quarter-turn rotations,
//! re-scoring at each step. Each sample is emitted as a CSV row (the full
//! objective decomposition), and a discontinuity summary flags the largest
//! score jump between *adjacent* samples in every sweep, attributing it to the
//! score term (hpwl / routed-loop inductance / alignment / congestion) that
//! moved most. A smooth objective changes gently as a part slides 0.05 mm; a
//! big jump for a tiny move is the thing we're hunting — almost always the
//! maze-routed loop leg snapping to a different channel or tripping the
//! unroutable penalty.
//!
//! Built as its own slim executable (`zig build fuzz-layout
//! -Doptimize=ReleaseFast`) that, like `bench-layout`, pulls in only the
//! optimizer + evaluator and deliberately skips Guardian/templates, so it is
//! cheap to rebuild and safe to point at a shared, read-only project dir (it
//! never writes layout sidecars or inserts IDs).
//!
//! Usage:
//!   fuzz-layout --project-dir <dir> <design> [options]
//!     --part <ref>       sweep only this ref-des (default: every part)
//!     --step <mm>        x/y sweep increment (default 0.05)
//!     --range <mm>       x/y sweep half-width: ±range (default 2.0)
//!     --map <ref>        also write a 2-D (dx,dy) objective grid for one part
//!     --map-out <path>   2-D grid CSV path (default fuzz-map.csv)
//!     --map-step <mm>    2-D grid increment (default 0.1)
//!     --map-range <mm>   2-D grid half-width (default 2.0)
//!     --out <path>       1-D sweep CSV path (default: stdout)
//!
//! The human-readable baseline + discontinuity summary always goes to stderr,
//! so `fuzz-layout … > sweep.csv` captures clean CSV while the summary prints.

const std = @import("std");
const paths = @import("paths.zig");
const infra_fs = @import("infra/fs.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;
const env = @import("eval/env.zig");
const optimizer = @import("placement/optimizer.zig");

const RefPose = optimizer.RefPose;
const Breakdown = optimizer.Breakdown;

/// Default scoring weights (mirrors `Params{}`), kept here so the summary can
/// decompose an objective jump into its weighted terms exactly as the optimizer
/// sums them: `obj = hpwl + loop_w·loop_nh_weighted + w_align·alignment + w_congest·congestion`.
const PARAMS: optimizer.Params = .{};

const Sample = struct { d: f64, bd: Breakdown };

/// The largest objective change between two *adjacent* samples in one sweep —
/// the candidate "non-smooth spot". `term`/`dterm` name the weighted score term
/// that accounts for most of it.
const Jump = struct {
    ref: []const u8,
    axis: []const u8,
    at: f64, // displacement (mm) at the low side of the jumping step
    dobj: f64, // |Δ objective| across the step
    term: []const u8,
    dterm: f64, // signed Δ of the dominant weighted term
};

fn weightedTerms(bd: Breakdown) struct { hpwl: f64, loop: f64, algn: f64, cong: f64 } {
    return .{
        .hpwl = bd.hpwl,
        .loop = PARAMS.loop_w * bd.loop_nh_weighted,
        // `effAlignW`, not `.w_align` — the raw field defaults to the auto
        // sentinel (−1), which would sign-flip the alignment term here.
        .algn = optimizer.effAlignW(PARAMS) * bd.alignment,
        .cong = PARAMS.w_congest * bd.congestion,
    };
}

/// Pick the weighted term whose change between `a` and `b` is largest in
/// magnitude — the one to blame for the objective step.
fn dominantTerm(a: Breakdown, b: Breakdown) struct { name: []const u8, d: f64 } {
    const ta = weightedTerms(a);
    const tb = weightedTerms(b);
    const dh = tb.hpwl - ta.hpwl;
    const dl = tb.loop - ta.loop;
    const da = tb.algn - ta.algn;
    const dc = tb.cong - ta.cong;
    var name: []const u8 = "hpwl";
    var val = dh;
    if (@abs(dl) > @abs(val)) {
        name = "loop_nh";
        val = dl;
    }
    if (@abs(da) > @abs(val)) {
        name = "alignment";
        val = da;
    }
    if (@abs(dc) > @abs(val)) {
        name = "congestion";
        val = dc;
    }
    return .{ .name = name, .d = val };
}

/// Reset `score_arena` and score `poses` with the optimizer's own objective.
fn scoreOne(
    score_arena: *std.heap.ArenaAllocator,
    block: *const env.DesignBlock,
    project_dir: []const u8,
    poses: []const RefPose,
) !Breakdown {
    _ = score_arena.reset(.retain_capacity);
    return optimizer.scorePoses(score_arena.allocator(), block, project_dir, poses, PARAMS);
}

fn appendRow(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    design: []const u8,
    ref: []const u8,
    sweep: []const u8,
    value: f64,
    bd: Breakdown,
) !void {
    const line = try std.fmt.allocPrint(
        gpa,
        "{s},{s},{s},{d:.4},{d:.5},{d:.5},{d:.6},{d:.5},{d:.5},{d:.5},{d:.5}\n",
        .{
            design,       ref,          sweep,               value,
            bd.objective, bd.hpwl,      bd.loop_nh_weighted, bd.loop_raw,
            bd.alignment, bd.footprint, bd.congestion,
        },
    );
    try buf.appendSlice(gpa, line);
}

/// Everything a sweep needs that does not change between samples: the design,
/// the scoring scratch arena, the CSV buffer, and the baseline + scratch poses.
/// Bundled so the per-sweep entry points stay under the parameter cap.
const SweepCtx = struct {
    gpa: std.mem.Allocator,
    score_arena: *std.heap.ArenaAllocator,
    block: *const env.DesignBlock,
    project_dir: []const u8,
    design: []const u8,
    csv: *std.ArrayList(u8),
    base: []const RefPose,
    work: []RefPose,
};

/// Sweep one part along one axis (`set` writes the swept coordinate into the
/// work pose), scoring at every sub-grid step, writing a CSV row each time, and
/// returning the largest adjacent-step objective jump seen.
fn sweepAxis(
    ctx: *const SweepCtx,
    ip: usize,
    axis: []const u8,
    base_coord: f64,
    comptime set: fn (*RefPose, f64) void,
    step: f64,
    n: usize,
) !Jump {
    const ref = ctx.base[ip].ref;
    var prev: ?Sample = null;
    var worst = Jump{ .ref = ref, .axis = axis, .at = 0, .dobj = 0, .term = "none", .dterm = 0 };
    var k: i64 = -@as(i64, @intCast(n));
    while (k <= @as(i64, @intCast(n))) : (k += 1) {
        const delta = @as(f64, @floatFromInt(k)) * step;
        @memcpy(ctx.work, ctx.base);
        set(&ctx.work[ip], base_coord + delta);
        const bd = try scoreOne(ctx.score_arena, ctx.block, ctx.project_dir, ctx.work);
        try appendRow(ctx.csv, ctx.gpa, ctx.design, ref, axis, delta, bd);
        if (prev) |p| {
            const dobj = @abs(bd.objective - p.bd.objective);
            if (dobj > worst.dobj) {
                const dom = dominantTerm(p.bd, bd);
                worst = .{ .ref = ref, .axis = axis, .at = p.d, .dobj = dobj, .term = dom.name, .dterm = dom.d };
            }
        }
        prev = .{ .d = delta, .bd = bd };
    }
    return worst;
}

fn setX(p: *RefPose, v: f64) void {
    p.x = v;
}
fn setY(p: *RefPose, v: f64) void {
    p.y = v;
}

/// Write a 2-D (dx,dy) objective grid for one part to `map_path`, so the
/// neighbourhood can be rendered as a heatmap (a discontinuity shows up as a
/// hard colour edge that a 1-D scan can slice through but not reveal in full).
fn writeMap(ctx: *const SweepCtx, ip: usize, map_path: []const u8, step: f64, range: f64) !void {
    const gpa = ctx.gpa;
    var buf = std.ArrayList(u8){};
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "dx,dy,objective,loop_nh_w,hpwl,congestion\n");
    const n: i64 = @intFromFloat(@round(range / step));
    const bx = ctx.base[ip].x;
    const by = ctx.base[ip].y;
    var iy: i64 = -n;
    while (iy <= n) : (iy += 1) {
        const dy = @as(f64, @floatFromInt(iy)) * step;
        var ix: i64 = -n;
        while (ix <= n) : (ix += 1) {
            const dx = @as(f64, @floatFromInt(ix)) * step;
            @memcpy(ctx.work, ctx.base);
            ctx.work[ip].x = bx + dx;
            ctx.work[ip].y = by + dy;
            const bd = try scoreOne(ctx.score_arena, ctx.block, ctx.project_dir, ctx.work);
            const line = try std.fmt.allocPrint(
                gpa,
                "{d:.4},{d:.4},{d:.5},{d:.6},{d:.5},{d:.5}\n",
                .{ dx, dy, bd.objective, bd.loop_nh_weighted, bd.hpwl, bd.congestion },
            );
            try buf.appendSlice(gpa, line);
        }
    }
    const f = try infra_fs.cwd().createFile(map_path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(buf.items);
    const samples = (2 * n + 1) * (2 * n + 1);
    std.debug.print("# 2-D map for {s}: {d} samples -> {s}\n", .{ ctx.base[ip].ref, samples, map_path });
}

/// CLI entry point: parse `--project-dir`/`<design>` and the sweep knobs, solve
/// once for a baseline layout, then sweep every (or one) part through fine x/y/
/// rotation steps — writing the per-sample CSV and the ranked discontinuity
/// summary that flags where the objective is non-smooth.
pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var project_dir: []const u8 = ".";
    var design: ?[]const u8 = null;
    var only_part: ?[]const u8 = null;
    var step: f64 = 0.05;
    var range: f64 = 2.0;
    var out_path: ?[]const u8 = null;
    var map_ref: ?[]const u8 = null;
    var map_out: []const u8 = "fuzz-map.csv";
    var map_step: f64 = 0.1;
    var map_range: f64 = 2.0;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--project-dir") and i + 1 < args.len) {
            project_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--part") and i + 1 < args.len) {
            only_part = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--step") and i + 1 < args.len) {
            step = std.fmt.parseFloat(f64, args[i + 1]) catch step;
            i += 1;
        } else if (std.mem.eql(u8, a, "--range") and i + 1 < args.len) {
            range = std.fmt.parseFloat(f64, args[i + 1]) catch range;
            i += 1;
        } else if (std.mem.eql(u8, a, "--out") and i + 1 < args.len) {
            out_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--map") and i + 1 < args.len) {
            map_ref = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--map-out") and i + 1 < args.len) {
            map_out = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--map-step") and i + 1 < args.len) {
            map_step = std.fmt.parseFloat(f64, args[i + 1]) catch map_step;
            i += 1;
        } else if (std.mem.eql(u8, a, "--map-range") and i + 1 < args.len) {
            map_range = std.fmt.parseFloat(f64, args[i + 1]) catch map_range;
            i += 1;
        } else if (!std.mem.startsWith(u8, a, "--")) {
            design = a;
        }
    }

    const name = design orelse {
        std.debug.print("Usage: fuzz-layout --project-dir <dir> <design> [--part <ref>] [--step mm] [--range mm] [--map <ref>] [--out <path>]\n", .{});
        std.process.exit(2);
    };
    if (step <= 0) step = 0.05;

    // ---- Load + solve once for a baseline layout -------------------------
    const path = try paths.designSourcePath(gpa, project_dir, name);
    defer gpa.free(path);
    var eval = Evaluator.init(gpa, project_dir);
    defer eval.deinit();
    const result = try eval.evalFile(path);
    const block: *env.DesignBlock = switch (result) {
        .design_block => |b| b,
        else => {
            std.debug.print("error: {s} is not a design block\n", .{name});
            std.process.exit(1);
        },
    };

    // Long-lived arena: holds the baseline placement (and its ref-des strings,
    // which the poses reference) for the whole run. Scoring uses its own arena.
    var base_arena = std.heap.ArenaAllocator.init(gpa);
    defer base_arena.deinit();
    var score_arena = std.heap.ArenaAllocator.init(gpa);
    defer score_arena.deinit();

    const placed = try optimizer.solve(base_arena.allocator(), block, project_dir, null, PARAMS, .place);
    const np = placed.parts.len;
    if (np == 0) {
        std.debug.print("error: {s} has no parts\n", .{name});
        std.process.exit(1);
    }

    // Baseline poses (verbatim solved layout) + a reusable scratch copy.
    const base = try base_arena.allocator().alloc(RefPose, np);
    for (placed.parts, 0..) |p, j| base[j] = .{ .ref = p.ref_des, .x = p.x, .y = p.y, .rot = p.rot };
    const work = try base_arena.allocator().alloc(RefPose, np);

    const base_bd = try scoreOne(&score_arena, block, project_dir, base);
    std.debug.print(
        \\# fuzz-layout {s}  parts={d}  step={d:.3}mm range=±{d:.2}mm
        \\# baseline objective={d:.4}  hpwl={d:.4}  loop_nh_w={d:.5}  loop_len_mm={d:.4}  align={d:.4}  congest={d:.4}
        \\
    , .{ name, np, step, range, base_bd.objective, base_bd.hpwl, base_bd.loop_nh_weighted, base_bd.loop_raw, base_bd.alignment, base_bd.congestion });

    // ---- 1-D sweeps ------------------------------------------------------
    var csv = std.ArrayList(u8){};
    defer csv.deinit(gpa);
    try csv.appendSlice(gpa, "design,ref,sweep,value,objective,hpwl,loop_nh_w,loop_len_mm,alignment,footprint,congestion\n");

    const n: usize = @intFromFloat(@round(range / step));
    var jumps = std.ArrayList(Jump){};
    defer jumps.deinit(gpa);

    const ctx = SweepCtx{
        .gpa = gpa,
        .score_arena = &score_arena,
        .block = block,
        .project_dir = project_dir,
        .design = name,
        .csv = &csv,
        .base = base,
        .work = work,
    };

    for (base, 0..) |bp, ip| {
        if (only_part) |want| if (!std.mem.eql(u8, want, bp.ref)) continue;
        const jx = try sweepAxis(&ctx, ip, "x", bp.x, setX, step, n);
        const jy = try sweepAxis(&ctx, ip, "y", bp.y, setY, step, n);
        try jumps.append(gpa, jx);
        try jumps.append(gpa, jy);

        // Rotation sweep: the four quarter-turns the page snaps to, at baseline xy.
        const rots = [_]f64{ 0, 90, 180, 270 };
        for (rots) |r| {
            @memcpy(work, base);
            work[ip].rot = r;
            const bd = try scoreOne(&score_arena, block, project_dir, work);
            try appendRow(&csv, gpa, name, bp.ref, "rot", r, bd);
        }
    }

    // ---- Emit 1-D CSV ----------------------------------------------------
    if (out_path) |p| {
        const f = try infra_fs.cwd().createFile(p, .{ .truncate = true });
        defer f.close();
        try f.writeAll(csv.items);
        std.debug.print("# wrote {d} bytes of sweep CSV -> {s}\n", .{ csv.items.len, p });
    } else {
        try std.fs.File.stdout().writeAll(csv.items);
    }

    // ---- Optional 2-D map ------------------------------------------------
    if (map_ref) |want| {
        var found = false;
        for (base, 0..) |bp, ip| {
            if (std.mem.eql(u8, want, bp.ref)) {
                try writeMap(&ctx, ip, map_out, map_step, map_range);
                found = true;
                break;
            }
        }
        if (!found) std.debug.print("# --map: no part named {s}\n", .{want});
    }

    // ---- Discontinuity summary (stderr) ----------------------------------
    std.mem.sort(Jump, jumps.items, {}, struct {
        fn lt(_: void, a: Jump, b: Jump) bool {
            return a.dobj > b.dobj;
        }
    }.lt);

    // A "smooth" expectation: sliding step mm changes the loop term by roughly
    // loop_w · LOOP_PUL · step ≈ 6 · 0.19 · step per unit weight. Anything an
    // order of magnitude past that for a single step is the surprise the user
    // is chasing, so we surface the ranked list and let the magnitudes speak.
    std.debug.print("\n# ==== largest adjacent-step objective jumps (per part/axis) ====\n", .{});
    std.debug.print("# {s:<8} {s:<4} {s:>9}  {s:>10}   {s:<11} {s:>10}\n", .{ "ref", "axis", "at(mm)", "Δobjective", "blame-term", "Δterm" });
    const show = @min(jumps.items.len, 24);
    for (jumps.items[0..show]) |j| {
        std.debug.print("# {s:<8} {s:<4} {d:>9.3}  {d:>10.4}   {s:<11} {d:>10.4}\n", .{ j.ref, j.axis, j.at, j.dobj, j.term, j.dterm });
    }
    std.debug.print("# (step={d:.3}mm — a smooth single-step Δobjective is well under ~1.0)\n", .{step});
}
