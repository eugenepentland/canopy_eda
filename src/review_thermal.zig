//! Presentation and serialization for the lumped thermal screening in
//! `eval/thermal.zig` — the one place a `BoardThermal` becomes the sentences,
//! the table cells and the JSON every surface shows.
//!
//! Six surfaces render this analysis: the review panels embedded in the
//! schematic page, the markdown report, the review PDF, the review JSON,
//! `GET /api/thermal/:name` and the `describe_thermal` CLI tool. They differ
//! only in markup, so the wording, the rounding and the JSON key names live
//! here instead of being restated — and drifting — five times over.
//!
//! Every shared string is WinAnsi-encodable on purpose: the PDF composer draws
//! these same sentences through a base-14 font, and a glyph it cannot encode
//! becomes a question mark on the page. That is why the coverage line says
//! `theta-JA` rather than `θJA`. Column HEADERS are each renderer's own
//! business and are free to use the Greek letter.

const std = @import("std");
const json_writer = @import("json_writer.zig");
const thermal = @import("eval/thermal.zig");
const thermal_scenarios = @import("thermal_scenarios.zig");

/// The cell a renderer prints for a figure the analysis could not compute.
pub const dash: []const u8 = "-";

// ── Summary prose ─────────────────────────────────────────────────────

/// The prose above and below the per-part table. Each field is a finished
/// line; an empty one is a line this board cannot support, and the renderer
/// simply skips it rather than printing a half-sentence.
pub const Lines = struct {
    /// The HEADLINE verdict as a sentence a reader can act on — the
    /// board-coupled one whenever a cooling ladder exists, the package-level
    /// screen's own otherwise. Pair it with `headlineVerdict` for the status
    /// pill so the badge and the sentence can never disagree.
    verdict: []const u8,
    /// The package-level screen's own sentence, explicitly labelled as the
    /// optimistic JEDEC-board estimate, for a renderer to print BELOW the
    /// headline. Empty when there is no ladder — the headline already is this
    /// sentence, and repeating it labelled would be nonsense.
    package: []const u8,
    /// The ambient window and who sets each end, e.g.
    /// `-40…71 °C, hot limit set by U5, cold limit by J2`. Scenario-aware when
    /// a ladder exists: the hot end is the GOVERNING scenario's ceiling and the
    /// clause names the cooling it assumes. Empty when neither end is known.
    ambient: []const u8,
    /// What the analysis actually knew, e.g.
    /// `power known for 9 parts, unknown for 3; theta-JA declared for 5, estimated for 4`.
    coverage: []const u8,
    /// Which forms to add when there is nothing to judge. Empty otherwise, so
    /// a board with real data is never lectured about the grammar.
    hint: []const u8,
};

/// Build every summary line for `bt`, reconciled against `scenarios`. The
/// strings are owned by `allocator`.
///
/// The reconciliation is the point. A datasheet θJA is measured on the JEDEC
/// 2s2p board (76 x 114 mm), so the lumped screen is systematically optimistic
/// on a smaller board — on barracuda it reads "passive OK" while the
/// board-coupled ladder puts the same board's hottest junction 56 °C past its
/// limit in still air. Two verdicts printed side by side, one of them wrong,
/// is worse than either alone: so when a ladder exists it GOVERNS the headline
/// and the ambient window, and the package screen is kept, demoted and labelled
/// with the assumption that makes it optimistic.
pub fn summaryLines(
    allocator: std.mem.Allocator,
    bt: thermal.BoardThermal,
    scenarios: thermal_scenarios.Answer,
) std.mem.Allocator.Error!Lines {
    const ladder = scenarios.ladder orelse return .{
        .verdict = try verdictSentence(allocator, bt),
        .package = "",
        .ambient = try ambientLine(allocator, bt),
        .coverage = try coverageLine(allocator, bt),
        .hint = if (bt.verdict == .insufficient_data) data_hint else "",
    };
    return .{
        .verdict = try boardSentence(allocator, ladder),
        .package = try packageLine(allocator, bt),
        .ambient = try boardAmbientLine(allocator, bt, ladder),
        .coverage = try coverageLine(allocator, bt),
        .hint = if (headlineVerdict(bt, scenarios) == .insufficient_data) data_hint else "",
    };
}

/// The verdict a surface hangs its status pill on: the board-coupled one when
/// a ladder exists, the package-level screen's own otherwise. One function so
/// the pill, the label and `Lines.verdict` cannot come from different models.
pub fn headlineVerdict(
    bt: thermal.BoardThermal,
    scenarios: thermal_scenarios.Answer,
) thermal.Verdict {
    const ladder = scenarios.ladder orelse return bt.verdict;
    return thermal_scenarios.boardVerdict(ladder);
}

/// What the JEDEC board the package screen assumes actually is. Named so the
/// three renderers state the same measurement, and spelled in ASCII because the
/// PDF draws this sentence through a base-14 font.
const jedec_note = "theta-JA on the JEDEC 2s2p board - optimistic for a board smaller than 76 x 114 mm";

/// The package-level screen, demoted under the board-coupled headline and
/// labelled with the assumption that makes it the more optimistic of the two.
fn packageLine(
    allocator: std.mem.Allocator,
    bt: thermal.BoardThermal,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "Package-level screen ({s}): {s}", .{
        jedec_note,
        try verdictSentence(allocator, bt),
    });
}

/// The board-coupled verdict as one sentence: the least cooling that works,
/// what still air actually does to the hottest junction, and how far the
/// governing scenario carries the board.
fn boardSentence(
    allocator: std.mem.Allocator,
    ladder: thermal_scenarios.Ladder,
) std.mem.Allocator.Error![]const u8 {
    const gov = thermal_scenarios.governingRow(ladder);
    const head = try thermal_scenarios.interventionPhrase(
        allocator,
        if (gov) |g| g.scenario else null,
        thermal_scenarios.sinkOf(ladder),
    );
    return std.fmt.allocPrint(allocator, "{s} at {d} °C{s}{s}", .{
        head,
        ladder.ambient_c,
        try stillAirEvidence(allocator, ladder),
        try usableClause(allocator, ladder, gov),
    });
}

/// What still air does to the hottest junction — the measurement the headline
/// rests on, stated so a reader is not asked to take the verdict on faith. A
/// board whose still-air rung computed no junction at all just ends the clause.
fn stillAirEvidence(
    allocator: std.mem.Allocator,
    ladder: thermal_scenarios.Ladder,
) std.mem.Allocator.Error![]const u8 {
    const still = thermal_scenarios.rowFor(ladder, .natural) orelse return ".";
    const hot = still.hottest() orelse return ".";
    const tj = hot.tj_c orelse return ".";
    return std.fmt.allocPrint(allocator, " — still air reaches Tj {d:.0} °C on {s}.", .{ tj, hot.ref });
}

/// How far the governing scenario carries the board, and what limits it there.
/// A board no rung of the ladder saves says exactly that instead of naming a
/// ceiling it does not have.
fn usableClause(
    allocator: std.mem.Allocator,
    ladder: thermal_scenarios.Ladder,
    gov: ?thermal_scenarios.Row,
) std.mem.Allocator.Error![]const u8 {
    const row = gov orelse
        return " No cooling scenario brings every junction under its derated limit.";
    const cooling = try thermal_scenarios.coolingClause(allocator, row.scenario, thermal_scenarios.sinkOf(ladder));
    const ceiling = row.max_ambient.c orelse
        return std.fmt.allocPrint(allocator, " Usable {s}.", .{cooling});
    if (row.max_ambient.ref.len == 0) {
        return std.fmt.allocPrint(allocator, " Usable to {d:.0} °C ambient {s}.", .{ ceiling, cooling });
    }
    return std.fmt.allocPrint(allocator, " Usable to {d:.0} °C ambient {s} (limited by {s}).", .{
        ceiling,
        cooling,
        row.max_ambient.ref,
    });
}

/// The ambient window a board with a ladder is good for: the ratings floor
/// unchanged (cold never causes self-heating trouble), and a hot end taken from
/// the GOVERNING scenario rather than from the package screen — with the
/// still-air ceiling spelled out whenever passive operation is what the reader
/// would otherwise have assumed.
fn boardAmbientLine(
    allocator: std.mem.Allocator,
    bt: thermal.BoardThermal,
    ladder: thermal_scenarios.Ladder,
) std.mem.Allocator.Error![]const u8 {
    const gov = thermal_scenarios.governingRow(ladder) orelse return std.fmt.allocPrint(
        allocator,
        "no ambient clears every junction, even with a heatsink{s}",
        .{try stillAirCaveat(allocator, ladder, null)},
    );
    const span = try boardSpan(allocator, bt.min_ambient.c, gov.max_ambient.c);
    if (span.len == 0) return "";
    const cooling = try thermal_scenarios.coolingClause(allocator, gov.scenario, thermal_scenarios.sinkOf(ladder));
    const hot = if (gov.max_ambient.ref.len > 0)
        try std.fmt.allocPrint(allocator, ", hot limit set by {s}", .{gov.max_ambient.ref})
    else
        "";
    const cold = if (bt.min_ambient.ref_des.len > 0)
        try std.fmt.allocPrint(allocator, ", cold limit by {s}", .{bt.min_ambient.ref_des})
    else
        "";
    return std.fmt.allocPrint(allocator, "{s} {s}{s}{s}{s}", .{
        span,
        cooling,
        hot,
        cold,
        try stillAirCaveat(allocator, ladder, gov.scenario),
    });
}

/// The "and passive operation is not an option" clause, appended whenever the
/// governing scenario is anything but still air. Empty when still air governs
/// (there is nothing to warn about) or when the still-air rung computed no
/// ceiling to quote.
fn stillAirCaveat(
    allocator: std.mem.Allocator,
    ladder: thermal_scenarios.Ladder,
    governing: ?thermal_scenarios.Scenario,
) std.mem.Allocator.Error![]const u8 {
    if (governing == .natural) return "";
    const still = thermal_scenarios.rowFor(ladder, .natural) orelse return "";
    const ceiling = still.max_ambient.c orelse return "";
    return std.fmt.allocPrint(
        allocator,
        "; the {d:.0} °C still-air ceiling means passive operation is not viable",
        .{ceiling},
    );
}

/// What to add when nothing could be judged. Named rather than derived: the
/// three forms are the whole input surface of the analysis.
const data_hint: []const u8 =
    "Add `(power W)` to the parts that dissipate, `(i-typ A)` to their supply pins, " ++
    "or `(thermal (theta-ja C-per-W) (tj-max C))` to the library part.";

/// The verdict as one sentence. Every intervention names the part it hangs on
/// so a reader knows where to put the fan or the heatsink; a board with no
/// limiting part (nothing powered) drops that clause instead of naming "".
fn verdictSentence(
    allocator: std.mem.Allocator,
    bt: thermal.BoardThermal,
) std.mem.Allocator.Error![]const u8 {
    const ref = bt.limiting_ref;
    return switch (bt.verdict) {
        .passive_ok => std.fmt.allocPrint(allocator, "Passive cooling OK at {d} °C.", .{bt.ambient_c}),
        .needs_airflow => if (ref.len > 0)
            std.fmt.allocPrint(allocator, "Needs ~1 m/s airflow — limiting part {s}.", .{ref})
        else
            std.fmt.allocPrint(allocator, "Needs ~1 m/s airflow.", .{}),
        .needs_heatsink => if (ref.len > 0)
            std.fmt.allocPrint(allocator, "Needs a heatsink on {s}.", .{ref})
        else
            std.fmt.allocPrint(allocator, "Needs a heatsink.", .{}),
        .over_limit => if (ref.len > 0)
            std.fmt.allocPrint(allocator, "Over limit even with a heatsink — {s}.", .{ref})
        else
            std.fmt.allocPrint(allocator, "Over limit even with a heatsink.", .{}),
        .insufficient_data => std.fmt.allocPrint(
            allocator,
            "Insufficient data: no part declares both a dissipation and a junction-to-ambient resistance.",
            .{},
        ),
    };
}

/// The board's rated ambient window, each end attributed to the part that sets
/// it. Empty when neither end is known — there is no window to state.
fn ambientLine(
    allocator: std.mem.Allocator,
    bt: thermal.BoardThermal,
) std.mem.Allocator.Error![]const u8 {
    const hi = bt.max_ambient;
    const lo = bt.min_ambient;
    const span = try ambientSpan(allocator, lo.c, hi.c);
    if (span.len == 0) return "";
    const hot = if (hi.ref_des.len > 0)
        try std.fmt.allocPrint(allocator, ", hot limit set by {s}", .{hi.ref_des})
    else
        "";
    const cold = if (lo.ref_des.len > 0)
        try std.fmt.allocPrint(allocator, ", cold limit by {s}", .{lo.ref_des})
    else
        "";
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ span, hot, cold });
}

/// The same window for a board-model line, rounded to the degree.
///
/// `ambientSpan` prints its bounds in full because the package screen's are
/// authored ratings — `-40…85` is exactly what the library said. A scenario's
/// ceiling is a solved float, and `65.67716732299805 °C` is both unreadable and
/// a precision the model does not have; the board sentences already round to
/// the degree, and the window has to agree with them.
fn boardSpan(
    allocator: std.mem.Allocator,
    lo_c: ?f64,
    hi_c: ?f64,
) std.mem.Allocator.Error![]const u8 {
    if (lo_c) |lo| {
        if (hi_c) |hi| return std.fmt.allocPrint(allocator, "{d:.0}…{d:.0} °C", .{ lo, hi });
        return std.fmt.allocPrint(allocator, "{d:.0} °C and up", .{lo});
    }
    if (hi_c) |hi| return std.fmt.allocPrint(allocator, "up to {d:.0} °C", .{hi});
    return "";
}

/// The window itself. A window open at one end says so in words rather than
/// printing a bound nothing computed; open at both ends it is empty.
fn ambientSpan(
    allocator: std.mem.Allocator,
    lo_c: ?f64,
    hi_c: ?f64,
) std.mem.Allocator.Error![]const u8 {
    if (lo_c) |lo| {
        if (hi_c) |hi| return std.fmt.allocPrint(allocator, "{d}…{d} °C", .{ lo, hi });
        return std.fmt.allocPrint(allocator, "{d} °C and up", .{lo});
    }
    if (hi_c) |hi| return std.fmt.allocPrint(allocator, "up to {d} °C", .{hi});
    return "";
}

/// What the analysis knew, so a reader can weigh the verdict against its
/// coverage instead of reading a partial screen as a full one.
fn coverageLine(
    allocator: std.mem.Allocator,
    bt: thermal.BoardThermal,
) std.mem.Allocator.Error![]const u8 {
    var estimated: usize = 0;
    for (bt.parts) |row| {
        if (row.theta.estimated) estimated += 1;
    }
    return std.fmt.allocPrint(
        allocator,
        "power known for {d} parts, unknown for {d}; theta-JA declared for {d}, estimated for {d}",
        .{ bt.counts.with_power, bt.counts.unknown_power, bt.counts.with_thermal, estimated },
    );
}

// ── Table cells ───────────────────────────────────────────────────────

/// One part's row, already formatted. Sharing the cells (and not just the
/// numbers) is what keeps the HTML, markdown and PDF tables reading the same:
/// the rounding, the source marker and the "est." flag are decided once.
pub const Cells = struct {
    ref_des: []const u8,
    component: []const u8,
    /// Dissipation in watts with its provenance, e.g. `0.850 (reg-loss)`.
    power: []const u8,
    /// Junction-to-ambient resistance in °C/W, marked `est.` when it came from
    /// the package table rather than the part.
    theta: []const u8,
    /// Junction temperature at the analysis ambient (°C).
    tj: []const u8,
    /// Headroom to the junction limit (°C); negative means already over.
    margin: []const u8,
    /// Highest ambient this part alone tolerates (°C).
    max_ambient: []const u8,
};

/// Format one part's row. Strings are owned by `allocator`; an unknown figure
/// is `dash` rather than a zero a reader would mistake for a measurement.
pub fn cells(
    allocator: std.mem.Allocator,
    row: thermal.PartThermal,
) std.mem.Allocator.Error!Cells {
    return .{
        .ref_des = row.ref_des,
        .component = if (row.component.len > 0) row.component else dash,
        .power = try powerCell(allocator, row.power),
        .theta = try thetaCell(allocator, row.theta),
        .tj = try degCell(allocator, row.result.tj_at_ambient),
        .margin = try degCell(allocator, row.result.margin_c),
        .max_ambient = try degCell(allocator, row.result.max_ambient_c),
    };
}

/// How a part's dissipation figure was arrived at, in one word for a table
/// cell. `none` has no marker — there is no figure to attribute.
fn sourceMark(source: thermal.PowerSource) []const u8 {
    return switch (source) {
        .explicit => "declared",
        .pin_annotations => "pins",
        .regulator_loss => "reg-loss",
        .none => "",
    };
}

fn powerCell(allocator: std.mem.Allocator, power: thermal.PartPower) std.mem.Allocator.Error![]const u8 {
    const watts = power.watts orelse return dash;
    const mark = sourceMark(power.source);
    if (mark.len == 0) return std.fmt.allocPrint(allocator, "{d:.3}", .{watts});
    return std.fmt.allocPrint(allocator, "{d:.3} ({s})", .{ watts, mark });
}

fn thetaCell(allocator: std.mem.Allocator, theta: thermal.PartTheta) std.mem.Allocator.Error![]const u8 {
    const ja = theta.ja orelse return dash;
    if (theta.estimated) return std.fmt.allocPrint(allocator, "{d:.1} est.", .{ja});
    return std.fmt.allocPrint(allocator, "{d:.1}", .{ja});
}

fn degCell(allocator: std.mem.Allocator, v: ?f64) std.mem.Allocator.Error![]const u8 {
    const x = v orelse return dash;
    return std.fmt.allocPrint(allocator, "{d:.1}", .{x});
}

// ── Cooling-scenario table ────────────────────────────────────────────

/// One cooling scenario as a table row, already formatted. Same reasoning as
/// `Cells`: the HTML panel, the markdown report and the review JSON must read
/// alike, so the wording and the rounding are decided once.
pub const ScenarioCells = struct {
    /// The cooling this row assumes, e.g. `1 m/s airflow` or `Heatsink on U5`.
    scenario: []const u8,
    /// Ref-des of the part running hottest under it.
    hottest: []const u8,
    /// That part's junction temperature at the document's ambient (°C).
    tj: []const u8,
    /// Highest ambient the whole board tolerates under this scenario (°C).
    max_ambient: []const u8,
    /// The part that sets that ceiling.
    limiting: []const u8,
};

/// Format one scenario row of `ladder`. Strings are owned by `allocator`; a
/// figure the solve could not produce is `dash`, never a zero.
pub fn scenarioCells(
    allocator: std.mem.Allocator,
    ladder: thermal_scenarios.Ladder,
    row: thermal_scenarios.Row,
) std.mem.Allocator.Error!ScenarioCells {
    const hot = row.hottest();
    return .{
        .scenario = if (row.scenario == .fan and row.cooling.fan.model.len > 0)
            try std.fmt.allocPrint(allocator, "Fan {s} ({d:.1} m/s at PCB)", .{ row.cooling.fan.model, row.cooling.fan.velocity_m_s })
        else
            try thermal_scenarios.scenarioLabel(allocator, row.scenario, thermal_scenarios.sinkOf(ladder)),
        .hottest = if (hot) |h| h.ref else dash,
        .tj = try degCell(allocator, if (hot) |h| h.tj_c else null),
        .max_ambient = try degCell(allocator, row.max_ambient.c),
        .limiting = if (row.max_ambient.ref.len > 0) row.max_ambient.ref else dash,
    };
}

/// The line a surface prints INSTEAD of the scenario table when there is none:
/// the reason it has none, phrased as a whole sentence. Empty when `answer`
/// carries a ladder, so a renderer can print it unconditionally.
pub fn scenarioNote(answer: thermal_scenarios.Answer) []const u8 {
    if (answer.ladder != null) return "";
    if (answer.unavailable.len > 0) return answer.unavailable;
    return no_layout_note;
}

/// What to say when nothing at all explained the missing ladder. Named rather
/// than inlined so the three renderers cannot each invent their own wording.
const no_layout_note: []const u8 =
    "Cooling scenarios need a board layout — place the design on the PCB editor to see " ++
    "how airflow and a heatsink change these temperatures.";

// ── JSON ──────────────────────────────────────────────────────────────

/// Serialize `bt` as one JSON object — the WHOLE body `GET /api/thermal/:name`
/// returns, the `describe_thermal` CLI tool returns, and the review JSON nests
/// under its `thermal` key. One writer for all three, so a caller reading the
/// endpoint and an agent reading the tool can never be told different numbers
/// about the same board.
///
/// Unknown figures are `null` (never 0), `estimated` / `tj_max_default` are
/// booleans, and both enums travel as their tag names.
///
/// `scenarios` is the layout-aware ladder when the caller could resolve a
/// placement, else `null` beside a `scenarios_unavailable` sentence saying why.
/// The two keys are ALWAYS both present: a consumer should never have to tell
/// "this board has no layout" apart from "this surface forgot to ask".
///
/// TWO verdict keys, deliberately. `verdict` is the PACKAGE-level screen and is
/// frozen as it has always been (API stability); `board_verdict` is the
/// board-coupled answer over the actual placement, null when there is no ladder.
/// Where they differ, `board_verdict` is the board being built — it is what the
/// review headline states — and `verdict` is the datasheet's JEDEC-board
/// estimate, which is optimistic for anything smaller than 76 x 114 mm.
pub fn writeFactsJson(
    w: anytype,
    bt: thermal.BoardThermal,
    scenarios: thermal_scenarios.Answer,
) json_writer.WriteError!void {
    try w.print("{{\"ambient_c\":{d},\"verdict\":\"{s}\",\"board_verdict\":", .{ bt.ambient_c, @tagName(bt.verdict) });
    if (scenarios.ladder) |ladder| {
        try w.print("\"{s}\"", .{@tagName(thermal_scenarios.boardVerdict(ladder))});
    } else try w.writeAll("null");
    try w.writeAll(",\"limiting_ref\":");
    try writeStringOrNull(w, bt.limiting_ref);
    try w.writeAll(",\"max_ambient\":");
    try writeAmbientLimit(w, bt.max_ambient);
    try w.writeAll(",\"min_ambient\":");
    try writeAmbientLimit(w, bt.min_ambient);
    try w.print(
        ",\"counts\":{{\"with_power\":{d},\"with_thermal\":{d},\"unknown_power\":{d}}}",
        .{ bt.counts.with_power, bt.counts.with_thermal, bt.counts.unknown_power },
    );
    try w.writeAll(",\"scenarios\":");
    if (scenarios.ladder) |ladder| try writeLadder(w, ladder) else try w.writeAll("null");
    try w.writeAll(",\"scenarios_unavailable\":");
    try writeStringOrNull(w, scenarioNote(scenarios));
    try w.writeAll(",\"parts\":[");
    for (bt.parts, 0..) |row, i| {
        if (i > 0) try w.writeAll(",");
        try writePart(w, row);
    }
    try w.writeAll("]}");
}

/// The scenario ladder as a JSON array, in `Scenario` enum order. Every
/// temperature is ABSOLUTE °C at the ladder's own ambient — the same numbers
/// the heat-zone image prints — while `max_ambient_c` is itself an ambient and
/// so does not move with it.
fn writeLadder(w: anytype, ladder: thermal_scenarios.Ladder) json_writer.WriteError!void {
    try w.writeAll("[");
    for (ladder.rows, 0..) |row, i| {
        if (i > 0) try w.writeAll(",");
        try writeScenarioRow(w, row);
    }
    try w.writeAll("]");
}

fn writeScenarioRow(w: anytype, row: thermal_scenarios.Row) json_writer.WriteError!void {
    try w.print("{{\"scenario\":\"{s}\",\"converged\":{s},\"board_max_c\":{d}", .{
        @tagName(row.scenario),
        boolText(row.converged),
        row.board_max_c,
    });
    try w.print(",\"hotspot\":{{\"x_mm\":{d},\"y_mm\":{d},\"c\":{d}}},\"max_ambient\":{{\"c\":", .{
        row.hotspot.x_mm,
        row.hotspot.y_mm,
        row.hotspot.c,
    });
    try writeFloatOrNull(w, row.max_ambient.c);
    try w.writeAll(",\"ref\":");
    try writeStringOrNull(w, row.max_ambient.ref);
    try w.writeAll("},\"heatsink\":");
    if (row.cooling.heatsink.ref.len == 0 and row.cooling.heatsink.face == null) {
        try w.writeAll("null");
    } else {
        try w.writeAll("{\"ref\":");
        try json_writer.writeString(w, row.cooling.heatsink.ref);
        try w.print(",\"side\":\"{s}\",\"face\":", .{@tagName(row.cooling.heatsink.side)});
        if (row.cooling.heatsink.face) |face|
            try w.print("\"{s}\"", .{@tagName(face)})
        else
            try w.writeAll("null");
        try w.writeAll("}");
    }
    try w.writeAll(",\"fan\":");
    if (row.cooling.fan.model.len == 0) {
        try w.writeAll("null");
    } else {
        try w.writeAll("{\"model\":");
        try json_writer.writeString(w, row.cooling.fan.model);
        try w.writeAll(",\"face\":");
        if (row.cooling.fan.face) |face| try w.print("\"{s}\"", .{@tagName(face)}) else try w.writeAll("null");
        try w.print(",\"velocity_m_s\":{d},\"operating_flow_m3_s\":{d},\"estimated_pressure_pa\":{d}}}", .{
            row.cooling.fan.velocity_m_s,
            row.cooling.fan.operating_flow_m3_s,
            row.cooling.fan.estimated_pressure_pa,
        });
    }
    try w.writeAll(",\"parts\":[");
    for (row.parts, 0..) |part, i| {
        if (i > 0) try w.writeAll(",");
        try writeScenarioPart(w, part);
    }
    try w.writeAll("],\"skipped\":[");
    for (row.skipped, 0..) |ref, i| {
        if (i > 0) try w.writeAll(",");
        try json_writer.writeString(w, ref);
    }
    try w.writeAll("]}");
}

fn writeScenarioPart(w: anytype, part: thermal_scenarios.PartRow) json_writer.WriteError!void {
    try w.writeAll("{\"ref\":");
    try json_writer.writeString(w, part.ref);
    try w.writeAll(",\"tj_c\":");
    try writeFloatOrNull(w, part.tj_c);
    try w.print(",\"board_c\":{d},\"jb_estimated\":{s},\"junction_path\":\"{s}\",\"max_ambient_c\":", .{
        part.board_c,
        boolText(part.jb_estimated),
        @tagName(part.junction_path),
    });
    try writeFloatOrNull(w, part.max_ambient_c);
    try w.writeAll("}");
}

fn writePart(w: anytype, row: thermal.PartThermal) json_writer.WriteError!void {
    try w.writeAll("{\"ref_des\":");
    try json_writer.writeString(w, row.ref_des);
    try w.writeAll(",\"component\":");
    try json_writer.writeString(w, row.component);
    try w.print(",\"power\":{{\"watts\":", .{});
    try writeFloatOrNull(w, row.power.watts);
    try w.print(",\"source\":\"{s}\"}},\"theta\":{{\"ja\":", .{@tagName(row.power.source)});
    try writeFloatOrNull(w, row.theta.ja);
    try w.writeAll(",\"jb\":");
    try writeFloatOrNull(w, row.theta.jb);
    try w.writeAll(",\"jc_top\":");
    try writeFloatOrNull(w, row.theta.jc.top);
    try w.writeAll(",\"jc_bottom\":");
    try writeFloatOrNull(w, row.theta.jc.bottom);
    try w.writeAll(",\"jc_generic\":");
    try writeFloatOrNull(w, row.theta.jc.generic);
    try w.writeAll(",\"psi_jt\":");
    try writeFloatOrNull(w, row.theta.psi.jt);
    try w.writeAll(",\"psi_jb\":");
    try writeFloatOrNull(w, row.theta.psi.jb);
    try w.print(",\"estimated\":{s}}},\"limits\":{{\"tj_max\":", .{boolText(row.theta.estimated)});
    try writeFloatOrNull(w, row.limits.tj_max);
    try w.print(",\"tj_max_default\":{s},\"operating_min_c\":", .{boolText(row.limits.tj_max_default)});
    try writeFloatOrNull(w, row.limits.operating_min_c);
    try w.writeAll(",\"operating_max_c\":");
    try writeFloatOrNull(w, row.limits.operating_max_c);
    try w.writeAll("},\"result\":{\"rise_c\":");
    try writeFloatOrNull(w, row.result.rise_c);
    try w.writeAll(",\"tj_at_ambient\":");
    try writeFloatOrNull(w, row.result.tj_at_ambient);
    try w.writeAll(",\"margin_c\":");
    try writeFloatOrNull(w, row.result.margin_c);
    try w.writeAll(",\"max_ambient_c\":");
    try writeFloatOrNull(w, row.result.max_ambient_c);
    try w.writeAll("}}");
}

fn writeAmbientLimit(w: anytype, limit: thermal.AmbientLimit) json_writer.WriteError!void {
    try w.writeAll("{\"c\":");
    try writeFloatOrNull(w, limit.c);
    try w.writeAll(",\"ref\":");
    try writeStringOrNull(w, limit.ref_des);
    try w.writeAll("}");
}

fn writeFloatOrNull(w: anytype, v: ?f64) json_writer.WriteError!void {
    if (v) |x| try w.print("{d}", .{x}) else try w.writeAll("null");
}

/// An empty ref is `null`, not `""` — "no part sets this limit" is a different
/// statement from "a part whose ref-des is the empty string".
fn writeStringOrNull(w: anytype, s: []const u8) json_writer.WriteError!void {
    if (s.len == 0) try w.writeAll("null") else try json_writer.writeString(w, s);
}

fn boolText(b: bool) []const u8 {
    return if (b) "true" else "false";
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

/// A board whose one part is powered and screened, for the prose tests.
fn oneHotPart(verdict: thermal.Verdict) thermal.BoardThermal {
    return .{
        .ambient_c = 25,
        .parts = &.{},
        .verdict = verdict,
        .limiting_ref = "U5",
        .counts = .{ .with_power = 1, .with_thermal = 1 },
    };
}

// spec: review_thermal - the verdict renders as one plain sentence naming the part an intervention hangs on
test "each verdict renders as a sentence naming its limiting part" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectEqualStrings(
        "Passive cooling OK at 25 °C.",
        (try summaryLines(a, oneHotPart(.passive_ok), .{})).verdict,
    );
    try testing.expectEqualStrings(
        "Needs ~1 m/s airflow — limiting part U5.",
        (try summaryLines(a, oneHotPart(.needs_airflow), .{})).verdict,
    );
    try testing.expectEqualStrings(
        "Needs a heatsink on U5.",
        (try summaryLines(a, oneHotPart(.needs_heatsink), .{})).verdict,
    );
    try testing.expectEqualStrings(
        "Over limit even with a heatsink — U5.",
        (try summaryLines(a, oneHotPart(.over_limit), .{})).verdict,
    );

    // Nothing powered ⇒ no limiting part, and the sentence drops the clause
    // rather than naming the empty ref.
    var nameless = oneHotPart(.needs_airflow);
    nameless.limiting_ref = "";
    try testing.expectEqualStrings("Needs ~1 m/s airflow.", (try summaryLines(a, nameless, .{})).verdict);
}

// spec: review_thermal - the ambient window names the part setting each end, and an end nothing computed is said in words rather than printed as a bound
test "the ambient line spells an open-ended window instead of inventing a bound" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var both = oneHotPart(.passive_ok);
    both.max_ambient = .{ .c = 71, .ref_des = "U5" };
    both.min_ambient = .{ .c = -40, .ref_des = "J2" };
    try testing.expectEqualStrings(
        "-40…71 °C, hot limit set by U5, cold limit by J2",
        (try summaryLines(a, both, .{})).ambient,
    );

    var hot_only = oneHotPart(.passive_ok);
    hot_only.max_ambient = .{ .c = 71, .ref_des = "U5" };
    try testing.expectEqualStrings("up to 71 °C, hot limit set by U5", (try summaryLines(a, hot_only, .{})).ambient);

    var cold_only = oneHotPart(.passive_ok);
    cold_only.min_ambient = .{ .c = -40, .ref_des = "J2" };
    try testing.expectEqualStrings("-40 °C and up, cold limit by J2", (try summaryLines(a, cold_only, .{})).ambient);

    // Neither end known ⇒ no line at all, so the renderer prints nothing.
    try testing.expectEqualStrings("", (try summaryLines(a, oneHotPart(.passive_ok), .{})).ambient);
}

// spec: review_thermal - the coverage line counts the parts whose power is known, unknown, declared-theta and estimated-theta
test "the coverage line counts known, unknown, declared and estimated" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const parts = [_]thermal.PartThermal{
        .{ .ref_des = "U1", .component = "reg", .theta = .{ .ja = 60, .estimated = true } },
        .{ .ref_des = "U2", .component = "mcu", .theta = .{ .ja = 55 } },
    };
    var bt = oneHotPart(.passive_ok);
    bt.parts = &parts;
    bt.counts = .{ .with_power = 9, .with_thermal = 5, .unknown_power = 3 };

    try testing.expectEqualStrings(
        "power known for 9 parts, unknown for 3; theta-JA declared for 5, estimated for 1",
        (try summaryLines(a, bt, .{})).coverage,
    );
}

// spec: review_thermal - insufficient data carries a hint naming the power, pin-current and thermal forms, and a board with real data carries none
test "only an insufficient-data board is handed the grammar hint" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const hint = (try summaryLines(a, oneHotPart(.insufficient_data), .{})).hint;
    try testing.expect(std.mem.indexOf(u8, hint, "(power W)") != null);
    try testing.expect(std.mem.indexOf(u8, hint, "(i-typ A)") != null);
    try testing.expect(std.mem.indexOf(u8, hint, "(theta-ja") != null);

    try testing.expectEqualStrings("", (try summaryLines(a, oneHotPart(.passive_ok), .{})).hint);
}

// spec: review_thermal - a part's cells carry the power source marker, an est. marker on an estimated theta, and a dash for every figure the analysis could not compute
test "cells mark the power source, an estimated theta, and every unknown" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const known = try cells(a, .{
        .ref_des = "ldo/U1",
        .component = "ldo-chip",
        .power = .{ .watts = 0.85, .source = .regulator_loss },
        .theta = .{ .ja = 60, .estimated = true },
        .limits = .{ .tj_max = 125, .tj_max_default = true },
        .result = .{ .rise_c = 51, .tj_at_ambient = 76, .margin_c = 49, .max_ambient_c = 74 },
    });
    try testing.expectEqualStrings("ldo/U1", known.ref_des);
    try testing.expectEqualStrings("0.850 (reg-loss)", known.power);
    try testing.expectEqualStrings("60.0 est.", known.theta);
    try testing.expectEqualStrings("76.0", known.tj);
    try testing.expectEqualStrings("49.0", known.margin);
    try testing.expectEqualStrings("74.0", known.max_ambient);

    // A declared θJA carries no est. marker, and a declared wattage says so.
    const declared = try cells(a, .{
        .ref_des = "U2",
        .component = "",
        .power = .{ .watts = 1.5, .source = .explicit },
        .theta = .{ .ja = 40 },
    });
    try testing.expectEqualStrings("1.500 (declared)", declared.power);
    try testing.expectEqualStrings("40.0", declared.theta);
    // Nothing computed is a dash — never a zero a reader would read as data.
    try testing.expectEqualStrings(dash, declared.component);
    try testing.expectEqualStrings(dash, declared.tj);
    try testing.expectEqualStrings(dash, declared.margin);
    try testing.expectEqualStrings(dash, declared.max_ambient);

    const nothing = try cells(a, .{ .ref_des = "C1", .component = "cap" });
    try testing.expectEqualStrings(dash, nothing.power);
    try testing.expectEqualStrings(dash, nothing.theta);
}

/// A four-rung ladder over one placed part, hand-built at comptime so the
/// presentation tests never wait on a solve. `sink` names the heatsink rung's
/// target. Shared with the HTML, markdown and PDF renderers' own tests, which
/// need the same four rows to assert their tables against.
pub fn testLadder(sink: []const u8) thermal_scenarios.Ladder {
    return .{ .ambient_c = 25, .rows = &test_rows, .heatsink_ref = sink };
}

/// The hottest part under each rung, one row per scenario in ladder order. A
/// file-scope constant so the single-element slice each `Row` takes out of it
/// outlives the call that built the ladder.
const test_part_rows = [_]thermal_scenarios.PartRow{
    .{ .ref = "U5", .tj_c = 96, .board_c = 76, .max_ambient_c = 71 },
    .{ .ref = "U5", .tj_c = 78, .board_c = 58, .max_ambient_c = 88 },
    .{ .ref = "U5", .tj_c = 70, .board_c = 50, .max_ambient_c = 95 },
    .{ .ref = "U5", .tj_c = 64, .board_c = 44, .max_ambient_c = 85 },
};

/// The ladder's rows, likewise file-scope so `testLadder` hands out a slice
/// that outlives it. Still air clears the derate here, so this board governs
/// itself passively.
const test_rows = [_]thermal_scenarios.Row{
    fixtureRow(&test_part_rows, .natural, 0, "U5"),
    fixtureRow(&test_part_rows, .airflow_1ms, 1, "U5"),
    fixtureRow(&test_part_rows, .airflow_2ms, 2, "U5"),
    fixtureRow(&test_part_rows, .heatsink, 3, "OSC1"),
};

/// A ladder whose board does NOT work in still air — the shape a real dense
/// board takes, and the case the reconciliation exists for: the package screen
/// reads passive-OK while this puts the hottest junction far past its limit.
/// 1 m/s airflow is the least rung that clears the derate.
pub fn testHotLadder() thermal_scenarios.Ladder {
    return .{ .ambient_c = 25, .rows = &hot_rows, .heatsink_ref = "U18" };
}

const hot_part_rows = [_]thermal_scenarios.PartRow{
    .{ .ref = "hmc451/U18", .tj_c = 181, .board_c = 164, .max_ambient_c = -27 },
    .{ .ref = "hmc451/U18", .tj_c = 110, .board_c = 92, .max_ambient_c = 65.67716732299805 },
    .{ .ref = "hmc451/U18", .tj_c = 88, .board_c = 70, .max_ambient_c = 78 },
    .{ .ref = "hmc451/U18", .tj_c = 100, .board_c = 83, .max_ambient_c = 66 },
};

const hot_rows = [_]thermal_scenarios.Row{
    fixtureRow(&hot_part_rows, .natural, 0, "hmc451/U18"),
    fixtureRow(&hot_part_rows, .airflow_1ms, 1, "ldo_3v3_lmx/U27"),
    fixtureRow(&hot_part_rows, .airflow_2ms, 2, "ldo_3v3_lmx/U27"),
    fixtureRow(&hot_part_rows, .heatsink, 3, "ldo_3v3_lmx/U27"),
};

/// One rung over `rows[i]`, its board figures taken from that row so a fixture
/// cannot state two different temperatures for one scenario. `limiting` is the
/// part that sets the rung's ambient ceiling, which on a real board is often
/// not the part running hottest.
fn fixtureRow(
    comptime rows: []const thermal_scenarios.PartRow,
    scenario: thermal_scenarios.Scenario,
    comptime i: usize,
    limiting: []const u8,
) thermal_scenarios.Row {
    const part = rows[i];
    return .{
        .scenario = scenario,
        .board_max_c = part.board_c,
        .hotspot = .{ .x_mm = 12, .y_mm = 8, .c = part.board_c },
        .max_ambient = .{ .c = part.max_ambient_c, .ref = limiting },
        .parts = rows[i .. i + 1],
    };
}

// spec: review_thermal - when a cooling ladder exists the headline verdict and sentence come from the board model, and the package-level screen is kept below it labelled with the JEDEC board that makes it optimistic
test "the board model governs the headline and demotes the package screen" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The contradiction this exists to resolve: the package screen says passive
    // OK on a board whose still-air junction is 56 °C past its limit.
    var bt = oneHotPart(.passive_ok);
    bt.max_ambient = .{ .c = 85, .ref_des = "U5" };
    bt.min_ambient = .{ .c = -40, .ref_des = "J2" };
    const answer = thermal_scenarios.Answer{ .ladder = testHotLadder() };

    // The pill and the sentence both come from the board model, and they agree.
    try testing.expectEqual(thermal.Verdict.needs_airflow, headlineVerdict(bt, answer));
    const lines = try summaryLines(a, bt, answer);
    try testing.expectEqualStrings(
        "Needs ~1 m/s airflow at 25 °C — still air reaches Tj 181 °C on hmc451/U18. " ++
            "Usable to 66 °C ambient with 1 m/s airflow (limited by ldo_3v3_lmx/U27).",
        lines.verdict,
    );
    // The package screen is kept, but labelled with the assumption that makes
    // it the optimistic of the two rather than left to read as a second answer.
    try testing.expectEqualStrings(
        "Package-level screen (theta-JA on the JEDEC 2s2p board - optimistic for a board " ++
            "smaller than 76 x 114 mm): Passive cooling OK at 25 °C.",
        lines.package,
    );

    // With NO ladder nothing changes: the package screen is the headline, and
    // there is no demoted line to print underneath it.
    try testing.expectEqual(thermal.Verdict.passive_ok, headlineVerdict(bt, .{}));
    const bare = try summaryLines(a, bt, .{});
    try testing.expectEqualStrings("Passive cooling OK at 25 °C.", bare.verdict);
    try testing.expectEqualStrings("", bare.package);
    try testing.expectEqualStrings("-40…85 °C, hot limit set by U5, cold limit by J2", bare.ambient);
}

// spec: review_thermal - with a cooling ladder the ambient window's hot end is the governing scenario's ceiling and names the cooling it assumes, adding the still-air ceiling whenever passive operation is not viable
test "the ambient window follows the governing scenario" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var bt = oneHotPart(.passive_ok);
    bt.max_ambient = .{ .c = 85, .ref_des = "U5" };
    bt.min_ambient = .{ .c = -40, .ref_des = "J2" };

    // Forced air governs: the hot end is ITS ceiling, not the package screen's
    // 85 °C, and the still-air ceiling is spelled out so nobody reads the
    // window as a passive rating. A solved ceiling is rounded to the degree —
    // it is a screening estimate, and `65.67716732299805 °C` is neither
    // readable nor a precision this model has.
    const forced = try summaryLines(a, bt, .{ .ladder = testHotLadder() });
    try testing.expectEqualStrings(
        "-40…66 °C with 1 m/s airflow, hot limit set by ldo_3v3_lmx/U27, cold limit by J2; " ++
            "the -27 °C still-air ceiling means passive operation is not viable",
        forced.ambient,
    );
    // A solved ceiling is rounded, never printed at f64 width.
    try testing.expect(std.mem.indexOf(u8, forced.ambient, "65.677") == null);

    // Still air governs: the same line names still air and drops the caveat,
    // because there is nothing left to warn about.
    const passive = try summaryLines(a, bt, .{ .ladder = testLadder("U5") });
    try testing.expectEqualStrings(
        "-40…71 °C in still air, hot limit set by U5, cold limit by J2",
        passive.ambient,
    );
}

// spec: review_thermal - a scenario's cells name the cooling, the hottest part and the ambient ceiling with the part that sets it, and dash every figure the solve could not produce
test "a scenario's cells name the cooling, the hottest part and the ceiling" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const ladder = testLadder("U5");
    const still = try scenarioCells(a, ladder, ladder.rows[0]);
    try testing.expectEqualStrings("Still air", still.scenario);
    try testing.expectEqualStrings("U5", still.hottest);
    try testing.expectEqualStrings("96.0", still.tj);
    try testing.expectEqualStrings("71.0", still.max_ambient);
    try testing.expectEqualStrings("U5", still.limiting);

    // The heatsink rung names the part its sink is bolted to, which is the one
    // thing a reader has to know to act on that row.
    const sunk = try scenarioCells(a, ladder, ladder.rows[3]);
    try testing.expectEqualStrings("Heatsink on U5 (board backside)", sunk.scenario);
    try testing.expectEqualStrings("OSC1", sunk.limiting);

    // A scenario the solve could say nothing about dashes rather than zeroing.
    const empty = try scenarioCells(a, ladder, .{ .scenario = .natural });
    try testing.expectEqualStrings(dash, empty.hottest);
    try testing.expectEqualStrings(dash, empty.tj);
    try testing.expectEqualStrings(dash, empty.max_ambient);
    try testing.expectEqualStrings(dash, empty.limiting);
}

// spec: review_thermal - a missing ladder carries the reason a surface prints in its place, falling back to the shared needs-a-layout sentence when nothing explained it
test "a missing ladder carries the sentence printed in its place" {
    // A ladder present ⇒ nothing to say instead of it.
    try testing.expectEqualStrings("", scenarioNote(.{ .ladder = testLadder("U5") }));
    // A stated reason is used verbatim.
    try testing.expectEqualStrings("no power anywhere", scenarioNote(.{ .unavailable = "no power anywhere" }));
    // …and an unexplained absence still says something a reader can act on.
    try testing.expect(std.mem.indexOf(u8, scenarioNote(.{}), "layout") != null);
}

// spec: review_thermal - the shared JSON body carries the scenario ladder as absolute degrees per rung, or a null ladder beside the sentence saying why there is none
test "the JSON body carries the scenario ladder or the reason there is none" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var with: std.Io.Writer.Allocating = .init(a);
    try writeFactsJson(&with.writer, oneHotPart(.needs_airflow), .{ .ladder = testLadder("U5") });
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, with.written(), .{});
    const rows = parsed.object.get("scenarios").?.array.items;
    try testing.expectEqual(@as(usize, 4), rows.len);
    try testing.expectEqualStrings("natural", rows[0].object.get("scenario").?.string);
    try testing.expectEqualStrings("heatsink", rows[3].object.get("scenario").?.string);
    try testing.expectEqualStrings("U5", rows[0].object.get("parts").?.array.items[0].object.get("ref").?.string);
    // A ladder is present, so nothing explains its absence.
    try testing.expect(parsed.object.get("scenarios_unavailable").? == .null);

    var without: std.Io.Writer.Allocating = .init(a);
    try writeFactsJson(&without.writer, oneHotPart(.needs_airflow), .{ .unavailable = "nothing burns here" });
    const bare = try std.json.parseFromSliceLeaky(std.json.Value, a, without.written(), .{});
    try testing.expect(bare.object.get("scenarios").? == .null);
    try testing.expectEqualStrings("nothing burns here", bare.object.get("scenarios_unavailable").?.string);
    // Both keys are ALWAYS present, so "no layout" and "this surface never
    // asked" can never look the same to a consumer.
    try testing.expect(bare.object.get("parts") != null);
}

// spec: review_thermal - the shared JSON body carries the board-coupled verdict as its own additive key, null when there is no ladder, while the package-level verdict key keeps its meaning untouched
test "the JSON body carries both verdicts without either changing the other" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // A board the package screen passes and the board model does not: the two
    // keys disagree, which is the whole reason both are published.
    var with: std.Io.Writer.Allocating = .init(a);
    try writeFactsJson(&with.writer, oneHotPart(.passive_ok), .{ .ladder = testHotLadder() });
    const hot = try std.json.parseFromSliceLeaky(std.json.Value, a, with.written(), .{});
    try testing.expectEqualStrings("passive_ok", hot.object.get("verdict").?.string);
    try testing.expectEqualStrings("needs_airflow", hot.object.get("board_verdict").?.string);

    // No ladder ⇒ no board verdict at all, and `verdict` is untouched.
    var without: std.Io.Writer.Allocating = .init(a);
    try writeFactsJson(&without.writer, oneHotPart(.passive_ok), .{ .unavailable = "no layout" });
    const bare = try std.json.parseFromSliceLeaky(std.json.Value, a, without.written(), .{});
    try testing.expectEqualStrings("passive_ok", bare.object.get("verdict").?.string);
    try testing.expect(bare.object.get("board_verdict").? == .null);

    // A ladder the board model agrees with reports the same word twice, so a
    // consumer can compare the keys rather than guess which one it has.
    var agree: std.Io.Writer.Allocating = .init(a);
    try writeFactsJson(&agree.writer, oneHotPart(.passive_ok), .{ .ladder = testLadder("U5") });
    const same = try std.json.parseFromSliceLeaky(std.json.Value, a, agree.written(), .{});
    try testing.expectEqualStrings("passive_ok", same.object.get("board_verdict").?.string);
}

// spec: review_thermal - the shared JSON body spells unknowns as null, the estimated and defaulted flags as booleans, and both enums as their tag names
test "the JSON body nulls unknowns and keeps flags boolean" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const parts = [_]thermal.PartThermal{.{
        .ref_des = "U1",
        .component = "reg",
        .power = .{ .watts = 0.5, .source = .pin_annotations },
        .theta = .{ .ja = 60, .estimated = true },
        .limits = .{ .tj_max = 125, .tj_max_default = true },
        .result = .{ .rise_c = 30, .tj_at_ambient = 55, .margin_c = 70, .max_ambient_c = 95 },
    }};
    var bt = oneHotPart(.needs_airflow);
    bt.parts = &parts;
    bt.max_ambient = .{ .c = 95, .ref_des = "U1" };

    var aw: std.Io.Writer.Allocating = .init(a);
    try writeFactsJson(&aw.writer, bt, .{});
    const out = aw.written();

    // The enums travel as tag names, not as ordinals.
    try testing.expect(std.mem.indexOf(u8, out, "\"verdict\":\"needs_airflow\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"source\":\"pin_annotations\"") != null);
    // Flags are JSON booleans.
    try testing.expect(std.mem.indexOf(u8, out, "\"estimated\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"tj_max_default\":true") != null);
    // An undeclared operating range and an unset limit are null, not 0.
    try testing.expect(std.mem.indexOf(u8, out, "\"operating_min_c\":null") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"min_ambient\":{\"c\":null,\"ref\":null}") != null);
    // And the whole thing is parseable JSON, not just plausible text.
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, out, .{});
    try testing.expectEqual(@as(usize, 1), parsed.object.get("parts").?.array.items.len);
    try testing.expectEqualStrings("U5", parsed.object.get("limiting_ref").?.string);
}
