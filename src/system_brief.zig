//! The design brief and its goals — which brief governs a board, and what the
//! engines already know about each stated target.
//!
//! A `(brief …)` states the envelope a product is designed to (ambient window,
//! input power, grade, derating, compliance, exposed interfaces) and a
//! `(goal …)` states one target inside it together with the engine that proves
//! it. This module is the join: it reads the boards' already-computed reports
//! and turns each goal into one row — a figure, a verdict from the shared
//! seven-word vocabulary, and the evidence sentence behind it.
//!
//! Nothing here runs an engine. Every figure comes from a report a board
//! review already produced, so a goal row can never disagree with the section
//! that renders the same report. Where an engine publishes no figure for a
//! goal's unit the row is `unproven` and says which figures that engine does
//! publish, and where no board gave the engine an input at all the row is
//! `not_declared` rather than a silent pass.
//!
//! Which figure a goal reads is selected by its UNIT, because a unit is what a
//! target is already written in:
//!
//! | verify-by      | unit             | figure                                    |
//! | -------------- | ---------------- | ----------------------------------------- |
//! | thermal        | C                | limiting maximum ambient over the boards  |
//! | power-budget   | %                | tightest rail margin                      |
//! | power-budget   | A                | largest rail load current                 |
//! | frequency-plan | Hz kHz MHz GHz   | the declared output (IF) band              |
//! | frequency-plan | dBm              | delivered LO drive                        |
//! | pll-loop       | deg              | worst-corner phase margin                 |
//! | pll-loop       | Hz kHz MHz GHz   | the nominal loop-bandwidth range           |
//! | spur-table     | dBc              | worst claimed level of an in-band product |

const std = @import("std");

const board_review = @import("board_review_snapshot.zig");
const frequency_plan = @import("frequency_plan.zig");
const infra_fs = @import("infra/fs.zig");
const pll_loop = @import("pll_loop.zig");
const review_assets = @import("system_review_assets.zig");
const system_review = @import("system_review.zig");
const system_sexp = @import("system_sexp.zig");

const GoalSpec = system_review.GoalSpec;

/// Most system workspaces one brief lookup will read before giving up. A
/// project with more directories than this under `src/systems` is answered
/// from the first 256 by name rather than by walking an unbounded tree.
const max_scanned_systems: usize = 256;

/// What a goal row can say, spelled as the review stack's shared vocabulary.
///
/// `waived` and `not_applicable` are deliberately absent: a goal is the
/// product's own target, so it is either met, not met, unprovable from what
/// the design declares, never given to its engine, or a bench measurement
/// nobody has taken yet.
pub const Verdict = enum { pass, fail, unproven, not_declared, manual };

/// One goal joined to what its engine says today.
pub const Evaluation = struct {
    goal: GoalSpec,
    /// The figure the engine published, already in the goal's own unit. Null
    /// whenever the verdict is `unproven`, `not_declared` or `manual`.
    value: ?f64 = null,
    verdict: Verdict,
    /// One sentence naming where the figure came from, or what is missing.
    evidence: []const u8,
};

/// The reports one board member publishes to the goal layer. The engineering
/// rollup is the board review's own, so a goal and the generated section that
/// renders the same report read one set of numbers.
pub const BoardReports = struct {
    name: []const u8,
    engineering: board_review.Engineering,
};

/// True when any row is a stated target the design misses. Only `fail` blocks:
/// an `unproven` or `not_declared` row names an input the design never gave
/// its engine, and a `manual` row is waiting on a bench, so neither is
/// evidence that the product misses its target.
pub fn blocks(evaluations: []const Evaluation) bool {
    for (evaluations) |evaluation| {
        if (evaluation.verdict == .fail) return true;
    }
    return false;
}

/// Evaluate every goal against the boards' reports, in authored order.
/// Evidence strings are allocated from `allocator`.
pub fn evaluate(
    allocator: std.mem.Allocator,
    goals: []const GoalSpec,
    boards: []const BoardReports,
) std.mem.Allocator.Error![]const Evaluation {
    const out = try allocator.alloc(Evaluation, goals.len);
    for (goals, out) |goal, *row| row.* = try evaluateGoal(allocator, goal, boards);
    return out;
}

/// The figure one engine published for one goal, already converted into the
/// goal's unit. A scalar figure sets `low` and `high` to the same number; a
/// band figure keeps its edges so a `(min …) (max …)` pair tests both.
const Figure = struct {
    low: f64,
    high: f64,
    evidence: []const u8,
};

/// What an engine reader answers with: a figure, or the reason there is none.
const Reading = union(enum) {
    figure: Figure,
    /// The engine ran, but publishes no figure for this goal's unit.
    unproven: []const u8,
    /// No board handed this engine an input at all.
    not_declared: []const u8,
};

fn evaluateGoal(
    allocator: std.mem.Allocator,
    goal: GoalSpec,
    boards: []const BoardReports,
) std.mem.Allocator.Error!Evaluation {
    if (goal.verify_by == .measurement) return measurementRow(allocator, goal);
    const reading = try engineReading(allocator, goal, boards);
    return switch (reading) {
        .figure => |figure| .{
            .goal = goal,
            .value = reportedValue(goal, figure),
            .verdict = boundVerdict(goal, figure),
            .evidence = figure.evidence,
        },
        .unproven => |why| .{ .goal = goal, .verdict = .unproven, .evidence = why },
        .not_declared => |why| .{ .goal = goal, .verdict = .not_declared, .evidence = why },
    };
}

/// A measurement goal is `manual` until an acceptance record closes it, and
/// then it is judged exactly like an engine figure.
fn measurementRow(
    allocator: std.mem.Allocator,
    goal: GoalSpec,
) std.mem.Allocator.Error!Evaluation {
    const measured = goal.measured orelse return .{
        .goal = goal,
        .verdict = .manual,
        .evidence = if (goal.reference) |reference|
            try std.fmt.allocPrint(allocator, "closed by measurement at {s}", .{reference})
        else
            try allocator.dupe(u8, "closed by measurement; no acceptance step named"),
    };
    const figure: Figure = .{
        .low = measured.value,
        .high = measured.value,
        .evidence = try std.fmt.allocPrint(allocator, "measured {d} {s} — {s}", .{
            measured.value,
            goal.unit,
            measured.evidence,
        }),
    };
    return .{
        .goal = goal,
        .value = figure.low,
        .verdict = boundVerdict(goal, figure),
        .evidence = figure.evidence,
    };
}

fn engineReading(
    allocator: std.mem.Allocator,
    goal: GoalSpec,
    boards: []const BoardReports,
) std.mem.Allocator.Error!Reading {
    return switch (goal.verify_by) {
        .thermal => thermalReading(allocator, goal, boards),
        .@"power-budget" => powerReading(allocator, goal, boards),
        .@"frequency-plan" => frequencyReading(allocator, goal, boards),
        .@"pll-loop" => pllReading(allocator, goal, boards),
        .@"spur-table" => spurReading(allocator, goal, boards),
        // `measurement` never reaches here: `evaluateGoal` answers it first.
        .measurement => .{ .unproven = "a measurement goal is closed by an acceptance record, not by an engine" },
    };
}

/// A bound the figure misses is a fail; a figure inside every declared bound
/// is a pass; a goal with no bound at all states a figure to report, and
/// reporting it is passing.
fn boundVerdict(goal: GoalSpec, figure: Figure) Verdict {
    if (goal.min) |min| {
        if (figure.low < min) return .fail;
    }
    if (goal.max) |max| {
        if (figure.high > max) return .fail;
    }
    return .pass;
}

/// The single number a row states. A scalar figure has only one; a band states
/// the edge that decided the verdict, so a failing row shows the edge that
/// broke the bound rather than the comfortable one.
fn reportedValue(goal: GoalSpec, figure: Figure) f64 {
    if (goal.min) |min| {
        if (figure.low < min) return figure.low;
    }
    return figure.high;
}

// ── Engine readers ───────────────────────────────────────────────────

fn thermalReading(
    allocator: std.mem.Allocator,
    goal: GoalSpec,
    boards: []const BoardReports,
) std.mem.Allocator.Error!Reading {
    if (unitKind(goal.unit) != .temperature)
        return unitMismatch(allocator, goal, "the thermal screen publishes a limiting ambient in C");
    var screened: usize = 0;
    var limiting: ?f64 = null;
    var limiting_board: []const u8 = "";
    for (boards) |board| {
        const heat = board.engineering.thermal;
        screened += heat.coverage.with_power;
        const max_c = heat.window.max_c orelse continue;
        if (limiting != null and limiting.? <= max_c) continue;
        limiting = max_c;
        limiting_board = board.name;
    }
    if (screened == 0)
        return .{ .not_declared = "no board declares part dissipation, so the thermal screen has no input" };
    const usable = limiting orelse
        return .{ .unproven = "the thermal screen cleared no cooling scenario, so no board reports an ambient window" };
    return .{ .figure = .{
        .low = usable,
        .high = usable,
        .evidence = try std.fmt.allocPrint(allocator, "thermal screen: usable to {d:.1} C ambient, limited by `{s}`", .{
            usable,
            limiting_board,
        }),
    } };
}

fn powerReading(
    allocator: std.mem.Allocator,
    goal: GoalSpec,
    boards: []const BoardReports,
) std.mem.Allocator.Error!Reading {
    const kind = unitKind(goal.unit);
    if (kind != .percent and kind != .amps)
        return unitMismatch(allocator, goal, "the power budget publishes a rail margin in % and a rail load in A");
    var rails: usize = 0;
    var tightest: ?f64 = null;
    var heaviest: f64 = 0;
    var rail_net: []const u8 = "";
    var load_net: []const u8 = "";
    for (boards) |board| for (board.engineering.power) |rail| {
        rails += 1;
        if (rail.load_max_a > heaviest) {
            heaviest = rail.load_max_a;
            load_net = rail.net;
        }
        const margin = rail.margin_pct orelse continue;
        if (tightest != null and tightest.? <= margin) continue;
        tightest = margin;
        rail_net = rail.net;
    };
    if (rails == 0)
        return .{ .not_declared = "no board declares a power-rail budget, so the rail screen has no input" };
    if (kind == .amps) return .{ .figure = .{
        .low = heaviest,
        .high = heaviest,
        .evidence = try std.fmt.allocPrint(allocator, "power budget: heaviest rail `{s}` draws {d:.3} A", .{ load_net, heaviest }),
    } };
    const margin = tightest orelse
        return .{ .unproven = "no declared rail carries a source, so the budget computes no margin" };
    return .{ .figure = .{
        .low = margin,
        .high = margin,
        .evidence = try std.fmt.allocPrint(allocator, "power budget: tightest rail `{s}` at {d:.1} % margin", .{ rail_net, margin }),
    } };
}

fn frequencyReading(
    allocator: std.mem.Allocator,
    goal: GoalSpec,
    boards: []const BoardReports,
) std.mem.Allocator.Error!Reading {
    const report = pickFrequencyReport(goal.id, boards) orelse
        return .{ .not_declared = "no board declares a (frequency-plan …), so the plan screen has no input" };
    const kind = unitKind(goal.unit);
    if (kind == .decibel_milliwatt) {
        const lo = report.profile.mixer.lo;
        if (!lo.drive_declared)
            return .{ .unproven = "the frequency plan declares no LO drive, so it publishes no dBm figure" };
        return .{ .figure = .{
            .low = lo.drive_dbm,
            .high = lo.drive_dbm,
            .evidence = try std.fmt.allocPrint(allocator, "(frequency-plan \"{s}\"): LO drive {d:.1} dBm", .{ report.name, lo.drive_dbm }),
        } };
    }
    const scale = frequencyScale(goal.unit) orelse
        return unitMismatch(allocator, goal, "a frequency plan publishes its output band in Hz, kHz, MHz or GHz and its LO drive in dBm");
    const band = report.profile.plan.output_band;
    if (!band.declared())
        return .{ .unproven = "the frequency plan declares no output band, so it publishes no band figure" };
    return .{ .figure = .{
        .low = band.lo_hz / scale,
        .high = band.hi_hz / scale,
        .evidence = try std.fmt.allocPrint(allocator, "(frequency-plan \"{s}\"): output band {d:.4} to {d:.4} {s}", .{
            report.name,
            band.lo_hz / scale,
            band.hi_hz / scale,
            goal.unit,
        }),
    } };
}

fn pllReading(
    allocator: std.mem.Allocator,
    goal: GoalSpec,
    boards: []const BoardReports,
) std.mem.Allocator.Error!Reading {
    const report = pickPllReport(goal.id, boards) orelse
        return .{ .not_declared = "no board declares a (pll-loop …), so the loop screen has no input" };
    const sweep = worstFittedSweep(report) orelse
        return .{ .unproven = "the loop filter solved no crossover, so it publishes no loop figure" };
    if (unitKind(goal.unit) == .degrees) return .{ .figure = .{
        .low = sweep.min_phase_margin_deg,
        .high = sweep.max_phase_margin_deg,
        .evidence = try std.fmt.allocPrint(allocator, "(pll-loop \"{s}\"): phase margin {d:.1} to {d:.1} deg over its corners", .{
            report.name,
            sweep.min_phase_margin_deg,
            sweep.max_phase_margin_deg,
        }),
    } };
    const scale = frequencyScale(goal.unit) orelse
        return unitMismatch(allocator, goal, "a loop filter publishes its phase margin in deg and its loop bandwidth in Hz, kHz, MHz or GHz");
    return .{ .figure = .{
        .low = sweep.min_bandwidth_hz / scale,
        .high = sweep.max_bandwidth_hz / scale,
        .evidence = try std.fmt.allocPrint(allocator, "(pll-loop \"{s}\"): loop bandwidth {d:.4} to {d:.4} {s}", .{
            report.name,
            sweep.min_bandwidth_hz / scale,
            sweep.max_bandwidth_hz / scale,
            goal.unit,
        }),
    } };
}

fn spurReading(
    allocator: std.mem.Allocator,
    goal: GoalSpec,
    boards: []const BoardReports,
) std.mem.Allocator.Error!Reading {
    if (unitKind(goal.unit) != .decibel_carrier)
        return unitMismatch(allocator, goal, "a spur table publishes an in-band level in dBc");
    const report = pickFrequencyReport(goal.id, boards) orelse
        return .{ .not_declared = "no board declares a (frequency-plan …), so no spur table was enumerated" };
    var worst: ?f64 = null;
    var order: frequency_plan.Order = .{ .m = 0, .n = 0 };
    for (report.plans) |plan| for (plan.spurs.rows) |product| {
        if (product.placement != .co_channel or !product.level.declared) continue;
        if (worst != null and worst.? >= product.level.dbc) continue;
        worst = product.level.dbc;
        order = product.order;
    };
    const level = worst orelse
        return .{ .unproven = "no (spur-table …) entry claims a level for an in-band product" };
    return .{ .figure = .{
        .low = level,
        .high = level,
        .evidence = try std.fmt.allocPrint(allocator, "(frequency-plan \"{s}\"): worst in-band product ({d},{d}) claimed at {d:.1} dBc", .{
            report.name,
            order.m,
            order.n,
            level,
        }),
    } };
}

fn unitMismatch(
    allocator: std.mem.Allocator,
    goal: GoalSpec,
    publishes: []const u8,
) std.mem.Allocator.Error!Reading {
    return .{ .unproven = try std.fmt.allocPrint(allocator, "{s}; this goal is stated in {s}", .{ publishes, goal.unit }) };
}

/// The report a goal reads: the one whose declaration name IS the goal id when
/// a design names them alike, and the first declared otherwise. The evidence
/// sentence always names the declaration it read, so the choice is visible.
fn pickFrequencyReport(id: []const u8, boards: []const BoardReports) ?board_review.FrequencyPlanReport {
    var first: ?board_review.FrequencyPlanReport = null;
    for (boards) |board| for (board.engineering.frequency) |report| {
        if (std.mem.eql(u8, report.name, id)) return report;
        if (first == null) first = report;
    };
    return first;
}

fn pickPllReport(id: []const u8, boards: []const BoardReports) ?board_review.PllReport {
    var first: ?board_review.PllReport = null;
    for (boards) |board| for (board.engineering.pll) |report| {
        if (std.mem.eql(u8, report.name, id)) return report;
        if (first == null) first = report;
    };
    return first;
}

/// The fitted population's tolerance sweep — the corners the built BOM
/// actually flies. Null when no corner solved for a crossover, which is the
/// unproven case rather than a zero phase margin.
fn worstFittedSweep(report: board_review.PllReport) ?pll_loop.SweepSummary {
    for (report.populations) |population| {
        if (population.kind != .fitted) continue;
        if (population.results.tolerance.corners > 0) return population.results.tolerance;
        if (population.results.nominal.corners > 0) return population.results.nominal;
    }
    return null;
}

// ── Units ────────────────────────────────────────────────────────────

/// The unit families a goal's bounds can be written in. `other` covers every
/// unit no engine publishes today (`dBc/Hz`, `ppm`, …) — those goals belong to
/// `measurement` and read as `unproven` if bound to an engine.
const UnitKind = enum { temperature, percent, amps, degrees, decibel_milliwatt, decibel_carrier, frequency, other };

fn unitKind(unit: []const u8) UnitKind {
    const table = [_]struct { text: []const u8, kind: UnitKind }{
        .{ .text = "C", .kind = .temperature },
        .{ .text = "degC", .kind = .temperature },
        .{ .text = "%", .kind = .percent },
        .{ .text = "A", .kind = .amps },
        .{ .text = "deg", .kind = .degrees },
        .{ .text = "dBm", .kind = .decibel_milliwatt },
        .{ .text = "dBc", .kind = .decibel_carrier },
    };
    for (table) |row| {
        if (std.ascii.eqlIgnoreCase(row.text, unit)) return row.kind;
    }
    return if (frequencyScale(unit) != null) .frequency else .other;
}

/// Hz per one of `unit`, or null when the unit is not a frequency.
fn frequencyScale(unit: []const u8) ?f64 {
    const table = [_]struct { text: []const u8, scale: f64 }{
        .{ .text = "Hz", .scale = 1 },
        .{ .text = "kHz", .scale = 1e3 },
        .{ .text = "MHz", .scale = 1e6 },
        .{ .text = "GHz", .scale = 1e9 },
    };
    for (table) |row| {
        if (std.ascii.eqlIgnoreCase(row.text, unit)) return row.scale;
    }
    return null;
}

// ── Which brief governs a board ──────────────────────────────────────

/// The design brief governing `design_name`, or null when no system workspace
/// in this project declares that board, the system that does carries no brief,
/// or the project has no `src/systems` at all.
///
/// A board may belong to SEVERAL systems. This answers with the first by
/// system directory name, sorted, so a board shared between two products
/// resolves the same way on every run rather than by whichever manifest the
/// filesystem handed back first; a unit check quoting a brief therefore quotes
/// a stable one. Everything returned is allocated from `allocator`, which is
/// expected to be an arena the caller frees whole.
pub fn briefForBoard(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    design_name: []const u8,
) ?system_review.Brief {
    const names = systemNames(allocator, project_dir) catch return null;
    for (names) |name| {
        const spec = contractSpec(allocator, project_dir, name) orelse continue;
        if (!declaresBoard(spec, design_name)) continue;
        return spec.brief;
    }
    return null;
}

/// Every `src/systems/<name>` directory, sorted. Empty when the project has
/// none, which is not an error: a project that never adopted system review has
/// no brief to find.
fn systemNames(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
) ![]const []const u8 {
    const root = review_assets.resolveContainedPathAlloc(allocator, project_dir, "src/systems") catch return &.{};
    var directory = infra_fs.cwd().openDir(root, .{ .iterate = true }) catch return &.{};
    defer directory.close();
    var names: std.ArrayList([]const u8) = .empty;
    var iterator = directory.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (names.items.len >= max_scanned_systems) break;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessName);
    return names.items;
}

fn lessName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// One workspace's contract, read through the same discovery every other
/// reader uses. A workspace whose manifest does not parse is skipped rather
/// than reported: this is a lookup beside a check, not the check itself.
fn contractSpec(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) ?system_review.SystemSpec {
    const manifest = system_sexp.locate(allocator, project_dir, name) catch return null;
    var diagnostic: system_review.Diagnostic = .{};
    return switch (manifest.kind) {
        .sexp => system_sexp.parseWith(
            allocator,
            manifest.source,
            .{ .omit_underivable_interfaces = true },
            &diagnostic,
        ) catch null,
        .json => std.json.parseFromSliceLeaky(system_review.SystemSpec, allocator, manifest.source, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = false,
        }) catch null,
    };
}

fn declaresBoard(spec: system_review.SystemSpec, design_name: []const u8) bool {
    for (spec.boards) |board| {
        if (std.mem.eql(u8, board.name, design_name)) return true;
    }
    return false;
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

fn goalFixture(id: []const u8, unit: []const u8, verify_by: system_review.VerifyBy) GoalSpec {
    return .{ .id = id, .unit = unit, .verify_by = verify_by };
}

fn thermalBoard(max_c: ?f64, with_power: usize) BoardReports {
    return .{
        .name = "rf",
        .engineering = .{ .thermal = .{
            .window = .{ .max_c = max_c },
            .coverage = .{ .with_power = with_power },
        } },
    };
}

// spec: system-review - an engine goal is evaluated from the boards' own reports and reads not-declared when no board gave that engine an input
test "an engine goal reads its figure from the board reports" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var goal = goalFixture("max-ambient", "C", .thermal);
    goal.min = 60;
    const boards = [_]BoardReports{thermalBoard(71.5, 12)};
    const rows = try evaluate(allocator, &.{goal}, &boards);
    try testing.expectEqual(Verdict.pass, rows[0].verdict);
    try testing.expectEqual(@as(f64, 71.5), rows[0].value.?);
    try testing.expect(std.mem.indexOf(u8, rows[0].evidence, "usable to 71.5 C ambient") != null);
    try testing.expect(!blocks(rows));

    const cold = [_]BoardReports{thermalBoard(41, 12)};
    const missed = try evaluate(allocator, &.{goal}, &cold);
    try testing.expectEqual(Verdict.fail, missed[0].verdict);
    try testing.expect(blocks(missed));

    // A screen with no window at all is unproven; a design that declares no
    // dissipation never gave the screen an input at all.
    const windowless = [_]BoardReports{thermalBoard(null, 12)};
    const unproven = try evaluate(allocator, &.{goal}, &windowless);
    try testing.expectEqual(Verdict.unproven, unproven[0].verdict);
    try testing.expect(unproven[0].value == null);
    try testing.expect(!blocks(unproven));

    const silent = [_]BoardReports{thermalBoard(null, 0)};
    const undeclared = try evaluate(allocator, &.{goal}, &silent);
    try testing.expectEqual(Verdict.not_declared, undeclared[0].verdict);

    // A unit the engine does not publish is named rather than guessed at.
    const wrong_unit = try evaluate(allocator, &.{goalFixture("max-ambient", "dBm", .thermal)}, &boards);
    try testing.expectEqual(Verdict.unproven, wrong_unit[0].verdict);
    try testing.expect(std.mem.indexOf(u8, wrong_unit[0].evidence, "stated in dBm") != null);
}

// spec: system-review - a measurement goal stays manual until its acceptance record closes it against the goal's own bounds
test "a measurement goal is manual until its acceptance record closes it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var goal = goalFixture("phase-noise-10k", "dBc/Hz", .measurement);
    goal.max = -95;
    goal.reference = "bring-up 4.3";
    const open = try evaluate(allocator, &.{goal}, &.{});
    try testing.expectEqual(Verdict.manual, open[0].verdict);
    try testing.expect(open[0].value == null);
    try testing.expect(std.mem.indexOf(u8, open[0].evidence, "bring-up 4.3") != null);
    try testing.expect(!blocks(open));

    goal.measured = .{ .value = -97.2, .evidence = "bring-up 4.3, 2026-09-04" };
    const closed = try evaluate(allocator, &.{goal}, &.{});
    try testing.expectEqual(Verdict.pass, closed[0].verdict);
    try testing.expectEqual(@as(f64, -97.2), closed[0].value.?);
    try testing.expect(std.mem.indexOf(u8, closed[0].evidence, "measured -97.2 dBc/Hz") != null);

    goal.measured = .{ .value = -88, .evidence = "bring-up 4.3, 2026-09-04" };
    const missed = try evaluate(allocator, &.{goal}, &.{});
    try testing.expectEqual(Verdict.fail, missed[0].verdict);
    try testing.expect(blocks(missed));
}

// spec: system-review - a frequency-plan goal reads the declaration's own output band or LO drive, selected by the unit its bounds are written in
test "a frequency-plan goal reads the band or the drive its unit names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var profile: board_review.FrequencyProfile = .{};
    profile.plan.output_band = .{ .lo_hz = 50e6, .hi_hz = 1500e6 };
    profile.mixer.lo = .{ .frequency_hz = 10.95e9, .drive_dbm = 15, .drive_declared = true };
    const reports = [_]board_review.FrequencyPlanReport{.{
        .name = "downconvert",
        .mode = .gate,
        .outcome = .screened,
        .profile = profile,
        .plans = &.{},
    }};
    const boards = [_]BoardReports{.{ .name = "rf", .engineering = .{ .frequency = &reports } }};

    var band = goalFixture("if-band", "MHz", .@"frequency-plan");
    band.min = 50;
    band.max = 1500;
    const band_rows = try evaluate(allocator, &.{band}, &boards);
    try testing.expectEqual(Verdict.pass, band_rows[0].verdict);
    try testing.expect(std.mem.indexOf(u8, band_rows[0].evidence, "output band 50.0000 to 1500.0000 MHz") != null);

    var drive = goalFixture("lo-drive", "dBm", .@"frequency-plan");
    drive.min = 13;
    drive.max = 20;
    const drive_rows = try evaluate(allocator, &.{drive}, &boards);
    try testing.expectEqual(Verdict.pass, drive_rows[0].verdict);
    try testing.expectEqual(@as(f64, 15), drive_rows[0].value.?);

    // A band narrower than the goal's window fails on the edge that broke it.
    var narrow = goalFixture("if-band", "MHz", .@"frequency-plan");
    narrow.min = 100;
    const narrow_rows = try evaluate(allocator, &.{narrow}, &boards);
    try testing.expectEqual(Verdict.fail, narrow_rows[0].verdict);
    try testing.expectEqual(@as(f64, 50), narrow_rows[0].value.?);

    // With no declaration anywhere the row is not-declared, never a pass.
    const empty = try evaluate(allocator, &.{band}, &.{});
    try testing.expectEqual(Verdict.not_declared, empty[0].verdict);
}

// spec: system-review - the brief governing a board is the first system by name that declares it, and a board no system declares has none
test "the brief governing a board is the first system by name that declares it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "project/src/systems/alpha");
    try tmp.dir.createDirPath(testing.io, "project/src/systems/zulu");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "project/src/systems/alpha/system.sexp",
        .data =
        \\(system "alpha"
        \\  (title "Alpha") (part-number "A-1") (revision "A")
        \\  (brief (purpose "the alpha product") (environment (ambient -10 60)))
        \\  (board "shared" (role main) (source "src/shared.sexp") (part-number "P-1") (revision "A"))
        \\  (document "release-checklist" (title "Release checklist")
        \\    (path "src/systems/alpha/release-checklist.md") (classification checklist)))
        ,
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "project/src/systems/zulu/system.sexp",
        .data =
        \\(system "zulu"
        \\  (title "Zulu") (part-number "Z-1") (revision "A")
        \\  (brief (purpose "the zulu product") (environment (ambient 0 40)))
        \\  (board "shared" (role main) (source "src/shared.sexp") (part-number "P-1") (revision "A"))
        \\  (board "zulu-only" (role aux) (source "src/zulu.sexp") (part-number "P-2") (revision "A"))
        \\  (document "release-checklist" (title "Release checklist")
        \\    (path "src/systems/zulu/release-checklist.md") (classification checklist)))
        ,
    });
    const project = try tmp.dir.realPathFileAlloc(testing.io, "project", allocator);

    const shared = briefForBoard(allocator, project, "shared") orelse return error.MissingBrief;
    try testing.expectEqualStrings("the alpha product", shared.purpose);
    try testing.expectEqual(@as(f64, 60), shared.environment.?.ambient_max_c);

    const only = briefForBoard(allocator, project, "zulu-only") orelse return error.MissingBrief;
    try testing.expectEqualStrings("the zulu product", only.purpose);

    try testing.expect(briefForBoard(allocator, project, "unknown-board") == null);
    try testing.expect(briefForBoard(allocator, "/nonexistent-project", "shared") == null);
}
