//! Read-only `route-kicad-reference` experiment command.
//! Owns argument parsing, routing/scoring orchestration, and stable JSON output.

const std = @import("std");
const exit = @import("../exit.zig");
const infra_fs = @import("../infra/fs.zig");
const json_writer = @import("../json_writer.zig");
const render_pcb_png = @import("../render_pcb_png.zig");
const inspect = @import("inspect.zig");
const experiment = @import("experiment.zig");
const adapter = @import("router_adapter.zig");
const reference_guides = @import("reference_guides.zig");
const net_aliases = @import("net_aliases.zig");
const route_score = @import("route_score.zig");
const optimizer = @import("../placement/optimizer.zig");
const route_policy = @import("../placement/route_policy.zig");
const router = @import("../placement/router.zig");
const drc = @import("../placement/drc.zig");
const drc_compose = @import("../placement/drc_compose.zig");

const GuideMode = enum { none, vias, corridor, path };
/// Default for `--reference-tolerance-mm`: the largest deviation (mm) allowed
/// when a reference route is simplified into per-layer runs. A path-fitting
/// tolerance - unrelated to `match_group.default_tolerance_mm`, which is an
/// allowed routed-LENGTH spread across a matched group.
const default_reference_tolerance_mm: f64 = 0.2;
const drc_kind_count = @typeInfo(drc.Kind).@"enum".field_names.len;

const Args = struct {
    board_path: []const u8,
    nets: []const []const u8,
    guide_mode: GuideMode = .none,
    tolerance_mm: f64 = default_reference_tolerance_mm,
    output_png: ?[]const u8 = null,
};

const Candidate = struct {
    options: route_policy.Options,
    routed: router.RouteResult,
    violations: []const drc.Violation,
};

const Baseline = struct {
    routed: router.RouteResult,
    violations: []const drc.Violation,
};

const Run = struct {
    report: inspect.Report,
    aliases: net_aliases.Analysis,
    erasure: experiment.VirtualErasure,
    adapted: adapter.Adapted,
    guides: reference_guides.ReferenceGuides,
    candidate: Candidate,
    baseline: Baseline,
};

const DrcCounts = struct {
    errors: usize,
    warnings: usize,
    kinds: [drc_kind_count]usize,
};

const ReturnPaths = struct {
    all: usize,
    selected: usize,
};

const Quality = struct {
    drc_counts: DrcCounts,
    return_paths: ReturnPaths,
};

const Measurements = struct {
    candidate: Quality,
    baseline: Quality,
    total_trace_mm: f64,
    new_trace_mm: f64,
    score: route_score.Score,
};

/// Run the non-destructive reference-routing CLI and emit one JSON result.
pub fn run(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try parseArgs(arena, argv);
    const result = try runExperiment(arena, args);
    const measurements = measure(result);
    if (args.output_png) |path| writePreview(arena, path, result, measurements);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeResult(arena, &out.writer, args, result, measurements);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(infra_fs.currentIo(), &stdout_buffer);
    try stdout_writer.interface.writeAll(out.written());
    try stdout_writer.interface.writeByte('\n');
    try stdout_writer.interface.flush();
}

fn parseArgs(arena: std.mem.Allocator, argv: []const []const u8) std.mem.Allocator.Error!Args {
    var board_path: ?[]const u8 = null;
    var nets: std.ArrayList([]const u8) = .empty;
    var guide_mode: GuideMode = .none;
    var tolerance_mm = default_reference_tolerance_mm;
    var output_png: ?[]const u8 = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--net")) {
            if (i + 1 >= argv.len) exit.fatal("route-kicad-reference: --net requires a net name\n", .{});
            try nets.append(arena, argv[i + 1]);
            i += 1;
        } else if (guideMode(arg)) |mode| {
            guide_mode = mode;
        } else if (std.mem.eql(u8, arg, "--reference-tolerance-mm")) {
            if (i + 1 >= argv.len) exit.fatal(
                "route-kicad-reference: --reference-tolerance-mm requires a value\n",
                .{},
            );
            tolerance_mm = parseTolerance(argv[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, arg, "--output-png")) {
            if (i + 1 >= argv.len) exit.fatal(
                "route-kicad-reference: --output-png requires a path\n",
                .{},
            );
            output_png = argv[i + 1];
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            exit.fatal("route-kicad-reference: unknown option {s}\n", .{arg});
        } else if (board_path == null) {
            board_path = arg;
        } else {
            exit.fatal("route-kicad-reference: unexpected argument {s}\n", .{arg});
        }
    }
    return .{
        .board_path = board_path orelse exit.fatal(
            "Usage: netlisp route-kicad-reference <board.kicad_pcb> " ++
                "[--net <name>]... " ++
                "[--reference-guides|--reference-corridor|--reference-path] " ++
                "[--reference-tolerance-mm <mm>] [--output-png <preview.png>]\n",
            .{},
        ),
        .nets = nets.items,
        .guide_mode = guide_mode,
        .tolerance_mm = tolerance_mm,
        .output_png = output_png,
    };
}

fn writePreview(
    arena: std.mem.Allocator,
    path: []const u8,
    result: Run,
    measurements: Measurements,
) void {
    const title = std.fmt.allocPrint(
        arena,
        "KiCad route candidate: {d}/{d} nets | DRC {d}E/{d}W",
        .{
            result.candidate.routed.routed,
            result.candidate.routed.total,
            measurements.candidate.drc_counts.errors,
            measurements.candidate.drc_counts.warnings,
        },
    ) catch exit.fatal("route-kicad-reference: preview title allocation failed\n", .{});
    const bytes = render_pcb_png.render(arena, result.adapted.placement, .{
        .width = 1800,
        .routed = result.candidate.routed,
        .violations = result.candidate.violations,
        .title = title,
        .grid = true,
    }) catch |err| exit.fatal(
        "route-kicad-reference: failed to render {s}: {s}\n",
        .{ path, @errorName(err) },
    );
    const file = infra_fs.cwd().createFile(path, .{ .truncate = true }) catch |err| exit.fatal(
        "route-kicad-reference: failed to create {s}: {s}\n",
        .{ path, @errorName(err) },
    );
    defer file.close();
    file.writeAll(bytes) catch |err| exit.fatal(
        "route-kicad-reference: failed to write {s}: {s}\n",
        .{ path, @errorName(err) },
    );
}

fn guideMode(arg: []const u8) ?GuideMode {
    if (std.mem.eql(u8, arg, "--reference-guides")) return .vias;
    if (std.mem.eql(u8, arg, "--reference-corridor")) return .corridor;
    if (std.mem.eql(u8, arg, "--reference-path")) return .path;
    return null;
}

fn parseTolerance(source: []const u8) f64 {
    const value = std.fmt.parseFloat(f64, source) catch
        exit.fatal("route-kicad-reference: invalid reference tolerance {s}\n", .{source});
    if (!std.math.isFinite(value) or value < 0) exit.fatal(
        "route-kicad-reference: reference tolerance must be finite and non-negative\n",
        .{},
    );
    return value;
}

fn runExperiment(arena: std.mem.Allocator, args: Args) std.mem.Allocator.Error!Run {
    var report = inspect.load(arena, args.board_path) catch |err| {
        exit.fatal("KiCad reference route load error: {s}\n", .{@errorName(err)});
    };
    const source_board = report.board;
    const aliases = try net_aliases.analyze(arena, source_board);
    report.board = try net_aliases.canonicalize(arena, source_board, aliases);
    const requested = try canonicalRequests(arena, source_board, aliases, args.nets);
    const erasure = try experiment.virtualErase(arena, report.board, requested);
    if (erasure.unknown_nets.len > 0) {
        exit.fatal("KiCad reference route: unknown net {s}\n", .{erasure.unknown_nets[0]});
    }
    const adapted = try adapter.adapt(arena, report.board, report.project);
    var options = try adapter.routeOptions(arena, adapted, erasure.seed, erasure.selected_nets);
    const guides = try buildGuides(arena, args, adapted, report, erasure.selected_nets);
    options.net = guides.policies;
    options.guides = .{ .tracks = guides.tracks, .vias = guides.vias };
    const routed = try router.routeWithOptions(arena, adapted.placement, adapted.params, options);
    const violations = checkBoard(arena, adapted, routed);

    // An impossible selector retains all reference features and routes no net,
    // giving candidate scoring a like-for-like adapter/DRC baseline.
    const baseline_options = try adapter.routeOptions(
        arena,
        adapted,
        report.board,
        &.{"__netlisp_reference_baseline__"},
    );
    const baseline_routed = try router.routeWithOptions(
        arena,
        adapted.placement,
        adapted.params,
        baseline_options,
    );
    const baseline_violations = checkBoard(arena, adapted, baseline_routed);
    return .{
        .report = report,
        .aliases = aliases,
        .erasure = erasure,
        .adapted = adapted,
        .guides = guides,
        .candidate = .{ .options = options, .routed = routed, .violations = violations },
        .baseline = .{ .routed = baseline_routed, .violations = baseline_violations },
    };
}

/// The full DRC on one candidate board: the geometric rules PLUS the `net_open`
/// connectivity layer, through the same `drc_compose` seam every serve-side
/// reporting surface uses. Bare `drc.check` — what this used to call — answers
/// only "does the copper break a spacing rule", so a routing whose copper left a
/// net in two islands was reported as clean and scored as clean. An uploaded
/// KiCad board has no `<design>.drc-rules.json`, so the built-in severities
/// stand (`checkDefaultRules`), and the candidate and the reference baseline are
/// measured the same way — the scorer compares them as deltas.
fn checkBoard(
    arena: std.mem.Allocator,
    adapted: adapter.Adapted,
    routed: router.RouteResult,
) []const drc.Violation {
    return drc_compose.checkDefaultRules(arena, .{
        .placement = adapted.placement,
        .routed = routed,
        .clearance = adapted.params.clearance,
    });
}

fn canonicalRequests(
    arena: std.mem.Allocator,
    source: @import("snapshot.zig").Snapshot,
    aliases: net_aliases.Analysis,
    requested: []const []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    if (requested.len == 0) return requested;
    var out: std.ArrayList([]const u8) = .empty;
    for (requested) |name| {
        const canonical = aliases.canonicalName(source, name);
        var duplicate = false;
        for (out.items) |known| if (std.ascii.eqlIgnoreCase(known, canonical)) {
            duplicate = true;
            break;
        };
        if (!duplicate) try out.append(arena, canonical);
    }
    return out.items;
}

fn buildGuides(
    arena: std.mem.Allocator,
    args: Args,
    adapted: adapter.Adapted,
    report: inspect.Report,
    selected: []const []const u8,
) std.mem.Allocator.Error!reference_guides.ReferenceGuides {
    if (args.guide_mode == .none) return .{
        .policies = &.{},
        .tracks = &.{},
        .vias = &.{},
        .guided_nets = 0,
        .waypoints = 0,
    };
    const detail: reference_guides.Detail = switch (args.guide_mode) {
        .corridor => .corridor,
        .path => .path,
        else => .vias,
    };
    return reference_guides.build(
        arena,
        adapted.placement,
        report.board,
        selected,
        detail,
        args.tolerance_mm,
    );
}

fn measure(result: Run) Measurements {
    const candidate_drc = countDrc(result.candidate.violations);
    const baseline_drc = countDrc(result.baseline.violations);
    const candidate_return = countReturnPaths(result, result.candidate.routed);
    const baseline_return = countReturnPaths(result, result.baseline.routed);
    const lengths = traceLengths(result.candidate.routed, result.candidate.options.existing_tracks.len);
    const score = route_score.compare(
        .{
            .routed = result.candidate.routed.total,
            .total = result.candidate.routed.total,
            .drc_errors = baseline_drc.errors,
            .drc_warnings = baseline_drc.warnings,
            .return_path_warnings = baseline_return.selected,
            .vias = result.erasure.removed.vias,
            .length_mm = result.erasure.removed.length_mm,
        },
        .{
            .routed = result.candidate.routed.routed,
            .total = result.candidate.routed.total,
            .drc_errors = candidate_drc.errors,
            .drc_warnings = candidate_drc.warnings,
            .return_path_warnings = candidate_return.selected,
            .vias = result.candidate.routed.vias.len - result.candidate.options.existing_vias.len,
            .length_mm = lengths[1],
        },
    );
    return .{
        .candidate = .{ .drc_counts = candidate_drc, .return_paths = candidate_return },
        .baseline = .{ .drc_counts = baseline_drc, .return_paths = baseline_return },
        .total_trace_mm = lengths[0],
        .new_trace_mm = lengths[1],
        .score = score,
    };
}

/// Split a violation list into the scorer's terms. `errors` is `drc.errorCount`
/// — the fab-blocking subset — so it excludes `net_open` as well as warnings:
/// route_score's own contract is that COMPLETENESS dominates DRC errors, and
/// `missing_nets` already charges every net whose copper does not close. Letting
/// each open net's islands land in the error term too would let a tiebreak
/// outvote the primary key. `kinds` still tallies every kind (open nets
/// included), so the JSON report loses nothing — only the score term is
/// narrowed, and `errors + warnings` is deliberately ≤ `violations.len`.
fn countDrc(violations: []const drc.Violation) DrcCounts {
    var out = DrcCounts{ .errors = drc.errorCount(violations), .warnings = 0, .kinds = @splat(0) };
    for (violations) |violation| {
        if (violation.severity == .warn) out.warnings += 1;
        out.kinds[@backingInt(violation.kind)] += 1;
    }
    return out;
}

fn countReturnPaths(result: Run, routed: router.RouteResult) ReturnPaths {
    return .{
        .all = router.returnPathViolations(
            result.adapted.placement,
            routed,
            router.return_path_radius_mm,
        ),
        .selected = router.returnPathViolationsForNets(
            result.adapted.placement,
            routed,
            router.return_path_radius_mm,
            result.erasure.selected_nets,
        ),
    };
}

fn traceLengths(routed: router.RouteResult, existing_count: usize) [2]f64 {
    var total: f64 = 0;
    var fresh: f64 = 0;
    for (routed.tracks, 0..) |track, i| {
        const length = std.math.hypot(track.x2 - track.x1, track.y2 - track.y1);
        total += length;
        if (i >= existing_count) fresh += length;
    }
    return .{ total, fresh };
}

fn writeResult(
    arena: std.mem.Allocator,
    writer: anytype,
    args: Args,
    result: Run,
    metrics: Measurements,
) !void {
    try writeHeader(writer, args, result);
    try writer.writeAll(",\"reference_policies\":");
    try writePolicyMetrics(
        writer,
        result.adapted.placement,
        result.guides.policies,
        result.erasure.selected_nets,
    );
    try writeRouting(arena, writer, result, metrics);
    try writeScore(writer, metrics.score);
}

fn writeHeader(writer: anytype, args: Args, result: Run) !void {
    try writer.writeAll("{\"ok\":true,\"board_path\":");
    try json_writer.writeString(writer, result.report.board_path);
    try writer.writeAll(",\"selected_nets\":");
    try writeNames(writer, result.erasure.selected_nets);
    try writer.writeAll(",\"requested_nets\":");
    try writeNames(writer, args.nets);
    try writer.writeAll(",\"output_png\":");
    if (args.output_png) |path| try json_writer.writeString(writer, path) else try writer.writeAll("null");
    try writeNormalization(writer, result.aliases);
    try writer.writeAll(",\"erased\":");
    try writeCopperMetrics(writer, result.erasure.removed);
    try writer.writeAll(",\"retained\":");
    try writeCopperMetrics(writer, result.erasure.retained);
    try writer.print(
        ",\"reference_guides\":{{\"mode\":\"{s}\",\"tolerance_mm\":{d}," ++
            "\"nets\":{d},\"waypoints\":{d},\"tracks\":{d},\"vias\":{d}}}",
        .{
            @tagName(args.guide_mode),
            args.tolerance_mm,
            result.guides.guided_nets,
            result.guides.waypoints,
            result.guides.tracks.len,
            result.guides.vias.len,
        },
    );
}

fn writeNormalization(writer: anytype, aliases: net_aliases.Analysis) !void {
    try writer.print(
        ",\"net_normalization\":{{\"safe_groups\":{d},\"ambiguous_groups\":{d},\"folded\":[",
        .{ aliases.safe_groups, aliases.ambiguous_groups },
    );
    var emitted: usize = 0;
    for (aliases.groups) |group| {
        if (!group.safe) continue;
        if (emitted > 0) try writer.writeByte(',');
        try writer.writeAll("{\"canonical\":");
        try json_writer.writeString(writer, group.canonical);
        try writer.writeAll(",\"aliases\":[");
        var alias_count: usize = 0;
        for (group.members) |member| {
            if (std.mem.eql(u8, member.name, group.canonical)) continue;
            if (alias_count > 0) try writer.writeByte(',');
            try json_writer.writeString(writer, member.name);
            alias_count += 1;
        }
        try writer.writeAll("]}");
        emitted += 1;
    }
    try writer.writeAll("]}");
}

fn writeRouting(
    arena: std.mem.Allocator,
    writer: anytype,
    result: Run,
    metrics: Measurements,
) !void {
    const routed = result.candidate.routed;
    const options = result.candidate.options;
    try writer.print(",\"routing\":{{\"routed\":{d},\"total\":{d},\"failed\":", .{
        routed.routed,
        routed.total,
    });
    try writeNames(writer, routed.failed);
    try writer.writeAll(",\"reference_replayed\":");
    try writeNetIndices(writer, result.adapted.placement, routed.reference_replayed);
    try writer.writeAll(",\"search_limited\":");
    try writeNetIndices(writer, result.adapted.placement, routed.search_limited);
    try writer.writeAll(",\"per_net\":");
    try writeSelectedRouteMetrics(
        arena,
        writer,
        result.adapted.placement,
        routed,
        result.erasure.selected_nets,
    );
    try writer.writeAll(",\"new_via_sites\":");
    try writeNewViaSites(writer, result.adapted.placement, routed.vias[options.existing_vias.len..]);
    try writeRouteTotals(writer, result, metrics);
    try writeDrc(writer, result, metrics);
    try writeReturnPaths(writer, metrics);
}

fn writeRouteTotals(writer: anytype, result: Run, metrics: Measurements) !void {
    const routed = result.candidate.routed;
    const options = result.candidate.options;
    try writer.print(
        ",\"grid_overflow\":{s},\"ripup_rounds\":{d},\"grid_scale\":{d},\"tracks\":{d}," ++
            "\"new_tracks\":{d},\"vias\":{d},\"new_vias\":{d}," ++
            "\"trace_mm\":{d:.6},\"new_trace_mm\":{d:.6}," ++
            "\"drc_errors\":{d},\"drc_warnings\":{d}," ++
            "\"reference_drc_errors\":{d},\"reference_drc_warnings\":{d}," ++
            "\"drc_error_delta\":{d},\"drc_warning_delta\":{d}",
        .{
            if (routed.grid_overflow) "true" else "false",
            routed.ripup_rounds,
            routed.grid_scale,
            routed.tracks.len,
            routed.tracks.len - options.existing_tracks.len,
            routed.vias.len,
            routed.vias.len - options.existing_vias.len,
            metrics.total_trace_mm,
            metrics.new_trace_mm,
            metrics.candidate.drc_counts.errors,
            metrics.candidate.drc_counts.warnings,
            metrics.baseline.drc_counts.errors,
            metrics.baseline.drc_counts.warnings,
            signedDelta(metrics.candidate.drc_counts.errors, metrics.baseline.drc_counts.errors),
            signedDelta(metrics.candidate.drc_counts.warnings, metrics.baseline.drc_counts.warnings),
        },
    );
}

fn writeDrc(writer: anytype, result: Run, metrics: Measurements) !void {
    try writer.writeAll(",\"drc_by_kind\":{");
    inline for (@typeInfo(drc.Kind).@"enum".field_names, 0..) |field_name, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("\"{s}\":{d}", .{ field_name, metrics.candidate.drc_counts.kinds[i] });
    }
    try writer.writeAll("},\"drc_delta_by_kind\":{");
    inline for (@typeInfo(drc.Kind).@"enum".field_names, 0..) |field_name, i| {
        if (i > 0) try writer.writeByte(',');
        const delta = signedDelta(
            metrics.candidate.drc_counts.kinds[i],
            metrics.baseline.drc_counts.kinds[i],
        );
        try writer.print("\"{s}\":{d}", .{ field_name, delta });
    }
    try writer.writeAll("},\"diff_pair_violations\":");
    try writeDiffPairViolations(writer, result.candidate.violations);
    try writer.writeAll(",\"drc_violations\":");
    try writeViolations(writer, result.candidate.violations);
    try writer.writeAll(",\"reference_drc_violations\":");
    try writeViolations(writer, result.baseline.violations);
}

fn writeViolations(writer: anytype, violations: []const drc.Violation) !void {
    try writer.writeByte('[');
    for (violations, 0..) |violation, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print(
            "{{\"kind\":\"{s}\",\"severity\":\"{s}\",\"x\":{d:.6},\"y\":{d:.6}," ++
                "\"gap_mm\":{d:.6},\"clearance_mm\":{d:.6}}}",
            .{
                @tagName(violation.kind),
                @tagName(violation.severity),
                violation.x,
                violation.y,
                violation.gap,
                violation.clearance,
            },
        );
    }
    try writer.writeByte(']');
}

fn writeReturnPaths(writer: anytype, metrics: Measurements) !void {
    try writer.print(
        ",\"return_path_warnings\":{d},\"reference_return_path_warnings\":{d}," ++
            "\"selected_return_path_warnings\":{d}," ++
            "\"reference_selected_return_path_warnings\":{d}}}",
        .{
            metrics.candidate.return_paths.all,
            metrics.baseline.return_paths.all,
            metrics.candidate.return_paths.selected,
            metrics.baseline.return_paths.selected,
        },
    );
}

fn writeScore(writer: anytype, score: route_score.Score) !void {
    try writer.print(
        ",\"score\":{{\"objective\":{d},\"reference_objective\":{d}," ++
            "\"missing_nets\":{d},\"new_errors\":{d},\"new_warnings\":{d}," ++
            "\"new_return_path_warnings\":{d}}}}}",
        .{
            score.objective,
            score.reference_objective,
            score.missing_nets,
            score.new_errors,
            score.new_warnings,
            score.new_return_path_warnings,
        },
    );
}

fn signedDelta(value: usize, baseline: usize) i64 {
    return @as(i64, @intCast(value)) - @as(i64, @intCast(baseline));
}

fn writeNames(writer: anytype, names: []const []const u8) !void {
    try writer.writeByte('[');
    for (names, 0..) |name, i| {
        if (i > 0) try writer.writeByte(',');
        try json_writer.writeString(writer, name);
    }
    try writer.writeByte(']');
}

fn writeNetIndices(
    writer: anytype,
    placement: optimizer.Placement,
    indices: []const usize,
) !void {
    try writer.writeByte('[');
    var written: usize = 0;
    for (indices) |net_i| {
        if (net_i >= placement.nets.len) continue;
        if (written > 0) try writer.writeByte(',');
        try json_writer.writeString(writer, placement.nets[net_i].name);
        written += 1;
    }
    try writer.writeByte(']');
}

fn writeCopperMetrics(writer: anytype, metrics: experiment.CopperMetrics) !void {
    try writer.print(
        "{{\"nets\":{d},\"segments\":{d},\"arcs\":{d},\"vias\":{d},\"length_mm\":{d:.6}}}",
        .{ metrics.nets, metrics.segments, metrics.arcs, metrics.vias, metrics.length_mm },
    );
}

fn writeSelectedRouteMetrics(
    arena: std.mem.Allocator,
    writer: anytype,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    selected: []const []const u8,
) !void {
    const metrics = try router.perNetRouted(arena, placement, routed);
    try writer.writeByte('[');
    for (selected, 0..) |name, i| {
        if (i > 0) try writer.writeByte(',');
        const net_metrics = findNetMetrics(metrics, name);
        try writer.writeAll("{\"name\":");
        try json_writer.writeString(writer, name);
        try writer.print(",\"trace_mm\":{d:.6},\"vias\":{d}}}", net_metrics);
    }
    try writer.writeByte(']');
}

fn findNetMetrics(metrics: []const router.NetRouted, name: []const u8) struct { f64, usize } {
    for (metrics) |metric| {
        if (std.ascii.eqlIgnoreCase(metric.name, name)) return .{ metric.mm, metric.vias };
    }
    return .{ 0, 0 };
}

fn writePolicyMetrics(
    writer: anytype,
    placement: optimizer.Placement,
    policies: []const route_policy.NetPolicy,
    selected: []const []const u8,
) !void {
    try writer.writeByte('[');
    for (selected, 0..) |name, selected_i| {
        if (selected_i > 0) try writer.writeByte(',');
        const counts = policyCounts(placement, policies, name);
        try writer.writeAll("{\"name\":");
        try json_writer.writeString(writer, name);
        try writer.print(",\"waypoints\":{d},\"branches\":{d},\"branch_points\":{d}}}", counts);
    }
    try writer.writeByte(']');
}

fn policyCounts(
    placement: optimizer.Placement,
    policies: []const route_policy.NetPolicy,
    name: []const u8,
) struct { usize, usize, usize } {
    for (placement.nets, 0..) |net, net_i| {
        if (!std.ascii.eqlIgnoreCase(net.name, name) or net_i >= policies.len) continue;
        const policy = policies[net_i];
        var points: usize = 0;
        for (policy.branches) |branch| points += branch.waypoints.len;
        return .{ policy.waypoints.len, policy.branches.len, points };
    }
    return .{ 0, 0, 0 };
}

fn writeDiffPairViolations(writer: anytype, violations: []const drc.Violation) !void {
    try writer.writeByte('[');
    var emitted: usize = 0;
    for (violations) |violation| {
        if (violation.kind != .diff_uncoupled and violation.kind != .diff_skew) continue;
        if (emitted > 0) try writer.writeByte(',');
        try writer.print(
            "{{\"kind\":\"{s}\",\"x\":{d:.6},\"y\":{d:.6}," ++
                "\"measured_mm\":{d:.6},\"limit_mm\":{d:.6}}}",
            .{ @tagName(violation.kind), violation.x, violation.y, violation.gap, violation.clearance },
        );
        emitted += 1;
    }
    try writer.writeByte(']');
}

fn writeNewViaSites(
    writer: anytype,
    placement: optimizer.Placement,
    vias: []const router.Via,
) !void {
    try writer.writeByte('[');
    var emitted: usize = 0;
    for (vias) |via| {
        if (via.net < 0) continue;
        const net_i: usize = @intCast(via.net);
        if (net_i >= placement.nets.len) continue;
        if (emitted > 0) try writer.writeByte(',');
        try writer.writeAll("{\"net\":");
        try json_writer.writeString(writer, placement.nets[net_i].name);
        try writer.print(",\"x\":{d:.6},\"y\":{d:.6}}}", .{ via.x, via.y });
        emitted += 1;
    }
    try writer.writeByte(']');
}

test "parseArgs accepts corridor tolerance" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = try parseArgs(arena_state.allocator(), &.{
        "board.kicad_pcb",
        "--net",
        "SIG",
        "--reference-corridor",
        "--reference-tolerance-mm",
        "0.25",
        "--output-png",
        "candidate.png",
    });
    try std.testing.expectEqual(GuideMode.corridor, got.guide_mode);
    try std.testing.expectEqual(@as(f64, 0.25), got.tolerance_mm);
    try std.testing.expectEqualStrings("SIG", got.nets[0]);
    try std.testing.expectEqualStrings("candidate.png", got.output_png.?);
}

test "countDrc keeps open nets out of the scorer's error term but still tallies them" {
    // The reference scorer is lexicographic: COMPLETENESS first (`missing_nets`),
    // then newly-introduced DRC errors. An open net is already charged by the
    // completeness term, so letting it into the error term too would let a
    // tiebreak outvote the key it breaks ties under.
    const vios = [_]drc.Violation{
        .{ .x = 0, .y = 0, .gap = 0.01, .clearance = 0.127, .kind = .track_pad },
        .{ .x = 1, .y = 1, .gap = 0, .clearance = 0, .kind = .sharp_bend, .severity = .warn },
        .{ .x = 2, .y = 2, .gap = 0.3, .clearance = 0, .kind = .net_open },
    };
    const counts = countDrc(&vios);
    try std.testing.expectEqual(@as(usize, 1), counts.errors);
    try std.testing.expectEqual(@as(usize, 1), counts.warnings);
    // The JSON report loses nothing: every kind is still tallied, open nets
    // included, so a reader sees the connectivity finding the score ignores.
    try std.testing.expectEqual(@as(usize, 1), counts.kinds[@backingInt(drc.Kind.net_open)]);
    try std.testing.expectEqual(@as(usize, 1), counts.kinds[@backingInt(drc.Kind.track_pad)]);
}
