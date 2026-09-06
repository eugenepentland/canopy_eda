//! Brief-driven unit checks: what a board owes because the SYSTEM it belongs
//! to states an envelope for the product.
//!
//! `src/system_brief.zig` answers "which brief governs this board". This
//! module is the other half — it turns that brief into the parameters the
//! unit-level engines run at, and into the per-part and per-net assertions
//! that only exist once a brief has been written:
//!
//! | brief field                        | what it parametrizes                       |
//! | ---------------------------------- | ------------------------------------------ |
//! | `(environment (ambient MIN MAX))`  | the thermal screen's ambient (MAX)         |
//! | `(environment (cooling …))`        | the release cooling scenario it is read at |
//! | `(environment (ambient MIN MAX))`  | every part's `(thermal (operating …))`     |
//! | `(temperature-grade …)`            | every part's `temperature-grade` property  |
//! | `(input-power (voltage LO HI) …)`  | the input net's proven voltage envelope    |
//! | `(derating "…")`                   | the fab gate's rating-screen factors       |
//! | `(compliance (esd "…"))`           | a protection part on every interface net   |
//!
//! Nothing here is a default. A board whose system declares no brief is
//! screened exactly as it was before this module existed — 25 °C, no operating
//! window, no grade, no derating factors, no ESD demand — and every row reads
//! `not-declared` rather than passing. That asymmetry is the point: a review
//! surface must be able to tell "the board met the target" from "nobody ever
//! stated one".
//!
//! The observations produced here are converted into preflight findings by
//! `preflight.zig` (kind `.brief`). This module deliberately does NOT import
//! preflight: the dependency runs one way so the check engine stays testable
//! without a design walk.

const std = @import("std");
const component_classification = @import("component_classification.zig");
const env_mod = @import("eval/env.zig");
const net_analysis = @import("eval/net_analysis.zig");
const net_envelopes = @import("eval/net_envelopes.zig");
const review_profiles = @import("review_profiles.zig");
const system_brief = @import("system_brief.zig");
const system_review = @import("system_review.zig");
const thermal = @import("eval/thermal.zig");
const thermal_field = @import("placement/thermal_field.zig");

const Brief = system_review.Brief;
const DesignBlock = env_mod.DesignBlock;
const Instance = env_mod.Instance;

/// Volt-scale slack, matching `req_physical_checks.volt_epsilon`: envelopes
/// and brief windows are both authored to three decimals at most, so a
/// coverage comparison must not fail on float representation alone.
const volt_epsilon: f64 = 1e-9;

/// Degree-scale slack, for the same reason on the ambient window.
const degree_epsilon: f64 = 1e-9;

// ── The ambient the screen runs at ────────────────────────────────────

/// Everything the thermal screen needs from the brief, resolved once.
///
/// `ambient_c` is what `eval/thermal.analyze` is called with. Without a brief
/// it is `thermal.default_ambient_c` and `source.system` is empty, which is
/// what every surface renders as `not-declared`.
pub const Plan = struct {
    /// The ambient the screen runs at (°C) — the brief's ambient MAX, else
    /// the 25 °C bench default.
    ambient_c: f64 = thermal.default_ambient_c,
    /// The brief's ambient window, null when no brief governs the board.
    window: ?Window = null,
    /// The provenance every thermal surface renders.
    source: thermal.AmbientSource = .{},
    /// The governing brief itself, for the checks below.
    brief: ?Brief = null,
};

/// The ambient window a product is specified over (°C).
pub const Window = struct {
    min_c: f64,
    max_c: f64,
};

/// Which screened cooling scenario a declared `(cooling …)` case is read at,
/// and whether that is an exact model or the nearest conservative stand-in.
pub const Mapping = struct {
    scenario: thermal_field.Scenario,
    /// True when the solver has no model for the declared case and the
    /// scenario below is the closest CONSERVATIVE one. Every surface that
    /// prints the scenario must also print this, or a reader would take an
    /// approximation for a solve.
    approximated: bool = false,
    /// Why the substitution was made, for the finding and the provenance
    /// line. Empty when `approximated` is false.
    note: []const u8 = "",
};

/// Sealed conduction has no solver model: the field solver's rungs are all
/// convective (a film coefficient per face) plus a bolted heatsink network,
/// and a sealed enclosure sheds its heat through the case instead. Stated
/// once, here, so the finding text, the provenance line and the reference all
/// quote the same sentence.
pub const sealed_conduction_note =
    "sealed-conduction has no solver model - screened in still air (natural), " ++
    "the most conservative convective rung, so the real conduction path can only help";

/// The screened scenario a brief's declared cooling case maps to.
///
/// Five of the six cases are the solver's own rungs under another name. The
/// sixth, `sealed-conduction`, is approximated by still air: the lumped and
/// field screens both model convection off the board faces, and a sealed
/// enclosure's conduction path is an ADDITIONAL route to ambient the solver
/// does not carry. Reading it at the natural rung therefore understates the
/// cooling and never the heat, which is the only direction a screen may err.
pub fn scenarioFor(cooling: system_review.Cooling) Mapping {
    return switch (cooling) {
        .natural => .{ .scenario = .natural },
        .fan => .{ .scenario = .fan },
        .airflow_1ms => .{ .scenario = .airflow_1ms },
        .airflow_2ms => .{ .scenario = .airflow_2ms },
        .heatsink => .{ .scenario = .heatsink },
        .@"sealed-conduction" => .{
            .scenario = .natural,
            .approximated = true,
            .note = sealed_conduction_note,
        },
    };
}

/// The brief that governs `design_name`, resolved into a screening plan.
/// Everything returned is allocated from `allocator`, expected to be an arena
/// the caller frees whole.
pub fn planFor(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    design_name: []const u8,
) Plan {
    const governing = system_brief.governingBrief(allocator, project_dir, design_name) orelse return .{};
    return planOf(governing.system, governing.brief);
}

/// The plan a brief implies, with no filesystem in the way — the seam the
/// tests drive and the one `planFor` funnels through.
pub fn planOf(system: []const u8, brief: Brief) Plan {
    const environment = brief.environment orelse return .{ .brief = brief, .source = .{ .system = system } };
    const mapping = if (environment.cooling) |cooling| scenarioFor(cooling) else null;
    return .{
        .ambient_c = environment.ambient_max_c,
        .window = .{ .min_c = environment.ambient_min_c, .max_c = environment.ambient_max_c },
        .brief = brief,
        .source = .{
            .system = system,
            .ambient_min_c = environment.ambient_min_c,
            .ambient_max_c = environment.ambient_max_c,
            .cooling = if (environment.cooling) |cooling| @tagName(cooling) else "",
            .scenario = if (mapping) |m| @tagName(m.scenario) else "",
            .note = if (mapping) |m| m.note else "",
        },
    };
}

/// Screen `block` at the ambient its governing brief states, stamping the
/// provenance every thermal surface renders. `override_c` is a caller-supplied
/// ambient (the `?ambient=` query, `--ambient`) and wins over the brief, since
/// a reader dialling in a temperature is asking a what-if and knows it.
pub fn analyzeGoverned(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    design_name: []const u8,
    override_c: ?f64,
) std.mem.Allocator.Error!thermal.BoardThermal {
    const plan = planFor(allocator, project_dir, design_name);
    var result = try thermal.analyze(allocator, block, override_c orelse plan.ambient_c);
    result.ambient_source = plan.source;
    if (override_c != null) result.ambient_source.overridden = true;
    return result;
}

// ── Derating standards ────────────────────────────────────────────────

/// The three passive families the release rating screen compares against a
/// rating, and the fraction of that rating a named standard allows.
///
/// These are the standards' GENERAL rows for those families, not a transcription
/// of the whole table: a program at a different quality level, or one derating
/// against temperature as well as stress, states its own factors in its own
/// process document. What the tool guarantees is that a named standard is
/// applied consistently and that every finding says which factor it used.
pub const Derating = struct {
    /// The standard as the brief spelled it, for the finding text.
    standard: []const u8,
    /// Fraction of a ceramic capacitor's rated voltage the applied DC
    /// potential may reach.
    ceramic_voltage: f64,
    /// Fraction of a resistor's rated power its worst-case dissipation may
    /// reach.
    resistor_power: f64,
    /// Fraction of an inductor's or ferrite's rated current it may carry.
    inductor_current: f64,
};

/// One row of the standards table.
const Row = struct {
    /// A substring of the brief's `(derating "…")` text, matched
    /// case-insensitively. The designation is enough — `"NASA EEE-INST-002"`
    /// and `"EEE-INST-002 Level 2"` select the same row.
    key: []const u8,
    /// The canonical designation the findings quote.
    label: []const u8,
    ceramic_voltage: f64,
    resistor_power: f64,
    inductor_current: f64,
};

/// The named standards the gate knows, with the general derating rows for
/// ceramic capacitors, fixed resistors and inductors/ferrites.
///
///   * NASA EEE-INST-002 (NASA/TP-2003-212242, *Instructions for EEE Parts
///     Selection, Screening, Qualification, and Derating*): ceramic capacitors
///     60 % of rated voltage, fixed resistors 60 % of rated power,
///     inductors/transformers 70 % of rated current.
///   * MIL-HDBK-1547 (*Electronic Parts, Materials, and Processes for Space
///     and Launch Vehicles*): ceramic capacitors 60 % of rated voltage,
///     resistors 50 % of rated power, inductors 60 % of rated current.
///   * ECSS-Q-ST-30-11 (*Derating - EEE components*): ceramic capacitors 50 %
///     of rated voltage, resistors 50 % of rated power, inductors 50 % of
///     rated current.
///
/// `house` is deliberately absent: it is the tool's own behaviour (the 1.5x
/// ceramic `(cap-rating …)` default and the gate's own "not above rated"
/// comparisons) and adds no screen, so `deratingFor` answers null for it.
const standards = [_]Row{
    .{
        .key = "EEE-INST-002",
        .label = "NASA EEE-INST-002",
        .ceramic_voltage = 0.6,
        .resistor_power = 0.6,
        .inductor_current = 0.7,
    },
    .{
        .key = "MIL-HDBK-1547",
        .label = "MIL-HDBK-1547",
        .ceramic_voltage = 0.6,
        .resistor_power = 0.5,
        .inductor_current = 0.6,
    },
    .{
        .key = "ECSS-Q-ST-30-11",
        .label = "ECSS-Q-ST-30-11",
        .ceramic_voltage = 0.5,
        .resistor_power = 0.5,
        .inductor_current = 0.5,
    },
};

/// True when `haystack` contains `needle`, ignoring ASCII case.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// The derating factors a brief's `(derating "…")` selects, or null when it
/// names none, names `house`, or names a standard this table does not carry.
/// Null means "screen exactly as before", never "screen at 1.0".
pub fn deratingFor(declared: ?[]const u8) ?Derating {
    const text = declared orelse return null;
    for (standards) |row| {
        if (!containsIgnoreCase(text, row.key)) continue;
        return .{
            .standard = row.label,
            .ceramic_voltage = row.ceramic_voltage,
            .resistor_power = row.resistor_power,
            .inductor_current = row.inductor_current,
        };
    }
    return null;
}

/// The derating factors that govern `design_name`, resolved through its brief.
pub fn deratingForBoard(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    design_name: []const u8,
) ?Derating {
    const brief = system_brief.briefForBoard(allocator, project_dir, design_name) orelse return null;
    return deratingFor(brief.derating);
}

// ── Temperature grades ────────────────────────────────────────────────

/// Grades in ascending order of severity, so "meets or exceeds" is `>=`.
fn gradeRank(grade: system_review.TemperatureGrade) u8 {
    return switch (grade) {
        .commercial => 0,
        .industrial => 1,
        .extended => 2,
        .automotive => 3,
    };
}

/// Parse a part's declared `temperature-grade`. Both the enum tag and a
/// quoted spelling are accepted; anything else is rejected rather than read as
/// the weakest grade.
pub fn parseGrade(word: []const u8) ?system_review.TemperatureGrade {
    const trimmed = std.mem.trim(u8, word, " \t\r\n\"");
    for (std.enums.values(system_review.TemperatureGrade)) |grade| {
        if (std.ascii.eqlIgnoreCase(trimmed, @tagName(grade))) return grade;
    }
    return null;
}

/// The `(temperature-grade …)` a placed part carries.
///
/// A component-body field the evaluator does not recognise structurally is
/// carried as an inline property, which is exactly where `temperature-grade`
/// lands — from the library component, from a call-site attribute, or from the
/// parts-table row a selection merged in. No grammar addition is needed.
pub fn declaredGrade(inst: Instance) ?system_review.TemperatureGrade {
    for (inst.properties) |property| {
        if (!std.ascii.eqlIgnoreCase(property.key, "temperature-grade")) continue;
        return parseGrade(property.value);
    }
    return null;
}

// ── Observations ──────────────────────────────────────────────────────

/// What a brief-driven check concluded. There is no `pass` observation: a
/// satisfied check produces no finding, exactly as an unmet class-profile
/// obligation is the only thing `review_profiles` emits.
pub const Result = enum {
    /// The board states the input and it does not meet the brief.
    fail,
    /// The board never gave the check its input. Never a pass.
    not_declared,
};

/// One brief-driven check outcome about one subject.
pub const Observation = struct {
    /// The `review_registry` row id this observation fills.
    id: []const u8,
    result: Result,
    /// Flattened ref-des for a part-scoped row, empty for a net-scoped one.
    ref_des: []const u8 = "",
    component: []const u8 = "",
    /// The sentence a reviewer reads. Owned by the allocator `observe` was
    /// given.
    message: []const u8,
};

/// Registry row ids the observations below carry. Named constants because
/// `review_registry` maps them and the tests assert on them.
pub const id_operating_range = "part-operating-range";
/// Registry row id for the temperature-grade check.
pub const id_temperature_grade = "part-temperature-grade";
/// Registry row id for the input-power envelope check.
pub const id_input_power = "brief-input-power-envelope";
/// Registry row id for the interface ESD-protection check.
pub const id_esd_protection = "interface-esd-protection";

/// Every brief-driven observation about `block`, in check order: the ambient
/// window over the placed parts, their temperature grades, the input-power
/// envelope, then ESD protection on the declared interfaces.
///
/// An empty slice comes back when no brief governs the board, which is the
/// whole no-behaviour-change guarantee: without a brief this module cannot
/// produce a finding.
pub fn observe(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    plan: Plan,
) std.mem.Allocator.Error![]const Observation {
    const brief = plan.brief orelse return &.{};
    var out: std.ArrayList(Observation) = .empty;
    try appendPartObservations(allocator, block, plan, &out);
    try appendInputPower(allocator, block, brief, &out);
    try appendEsd(allocator, block, project_dir, brief, &out);
    return out.toOwnedSlice(allocator);
}

/// The two per-part rows, walked over the whole hierarchy once so a part
/// inside a module is judged exactly as one on the board is.
///
/// The population is the ACTIVE parts — the same set that owes a datasheet
/// review and a class profile. A brief states the envelope a product works in,
/// and it is the semiconductors whose rated ambient range and grade decide
/// whether it does; demanding an `(operating …)` from every 0402 bypass cap
/// would bury that answer under a thousand rows.
///
/// Ref-deses are the block's own, unprefixed, exactly as every other preflight
/// finding spells them: they are globally unique once the block is
/// materialized, and borrowing them keeps a finding's subject valid after the
/// check's scratch memory is gone.
fn appendPartObservations(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    plan: Plan,
    out: *std.ArrayList(Observation),
) std.mem.Allocator.Error!void {
    for (block.instances) |inst| {
        if (inst.placeholder) continue;
        if (!component_classification.isActiveSemiconductor(inst)) continue;
        if (plan.window) |window| try appendOperatingRow(allocator, inst, plan, window, out);
        if (plan.brief.?.temperature_grade) |required| {
            try appendGradeRow(allocator, inst, plan, required, out);
        }
    }
    for (block.sub_blocks) |sub| {
        try appendPartObservations(allocator, sub.block, plan, out);
    }
}

/// One part's rated-ambient row against the brief window.
fn appendOperatingRow(
    allocator: std.mem.Allocator,
    inst: Instance,
    plan: Plan,
    window: Window,
    out: *std.ArrayList(Observation),
) std.mem.Allocator.Error!void {
    const system = plan.source.system;
    const decl = inst.thermal.decl;
    const low = if (decl) |d| d.operating_min else null;
    const high = if (decl) |d| d.operating_max else null;
    if (low == null and high == null) {
        try out.append(allocator, .{
            .id = id_operating_range,
            .result = .not_declared,
            .ref_des = inst.ref_des,
            .component = inst.component,
            .message = try std.fmt.allocPrint(
                allocator,
                "{s} declares no (thermal (operating MIN MAX)) - the \"{s}\" brief specifies {d:.0}...{d:.0} C, so this part's rated ambient range is unknown rather than met",
                .{ inst.ref_des, system, window.min_c, window.max_c },
            ),
        });
        return;
    }
    const cold_short = low != null and low.? > window.min_c + degree_epsilon;
    const hot_short = high != null and high.? < window.max_c - degree_epsilon;
    if (!cold_short and !hot_short) return;
    try out.append(allocator, .{
        .id = id_operating_range,
        .result = .fail,
        .ref_des = inst.ref_des,
        .component = inst.component,
        .message = try std.fmt.allocPrint(
            allocator,
            "{s} is rated {s}...{s} C but the \"{s}\" brief specifies {d:.0}...{d:.0} C",
            .{ inst.ref_des, degrees(allocator, low), degrees(allocator, high), system, window.min_c, window.max_c },
        ),
    });
}

/// A declared bound as text, or `?` when the part gave only the other end.
fn degrees(allocator: std.mem.Allocator, value: ?f64) []const u8 {
    const c = value orelse return "?";
    return std.fmt.allocPrint(allocator, "{d:.0}", .{c}) catch "?";
}

fn appendGradeRow(
    allocator: std.mem.Allocator,
    inst: Instance,
    plan: Plan,
    required: system_review.TemperatureGrade,
    out: *std.ArrayList(Observation),
) std.mem.Allocator.Error!void {
    const system = plan.source.system;
    const grade = declaredGrade(inst) orelse {
        try out.append(allocator, .{
            .id = id_temperature_grade,
            .result = .not_declared,
            .ref_des = inst.ref_des,
            .component = inst.component,
            .message = try std.fmt.allocPrint(
                allocator,
                "{s} declares no (temperature-grade ...) - the \"{s}\" brief requires {s} or better",
                .{ inst.ref_des, system, @tagName(required) },
            ),
        });
        return;
    };
    if (gradeRank(grade) >= gradeRank(required)) return;
    try out.append(allocator, .{
        .id = id_temperature_grade,
        .result = .fail,
        .ref_des = inst.ref_des,
        .component = inst.component,
        .message = try std.fmt.allocPrint(
            allocator,
            "{s} is a {s}-grade part but the \"{s}\" brief requires {s} or better",
            .{ inst.ref_des, @tagName(grade), system, @tagName(required) },
        ),
    });
}

// ── Input power ───────────────────────────────────────────────────────

/// Which board net the brief's input power lands on, and how that was decided.
const InputNet = struct {
    net: []const u8,
    /// The binding rule that found it, for the finding text.
    how: []const u8,
};

/// The board net the brief's `(input-power …)` feeds.
///
/// Two rules, in order, and both are stated in the finding so a reviewer can
/// see which one applied:
///
///   1. An explicit `(input-power … (feeds "NET"))` names the net outright.
///      This is the rule to use whenever the board's input net is not spelled
///      like the brief's interface.
///   2. Otherwise the brief's FIRST `(interface "NAME" …)` whose NAME matches
///      a design-block port name, case-insensitively; the port's net is the
///      input net.
///
/// Null when neither rule resolves, which is a `not-declared` row rather than
/// a pass: the tool will not guess which net carries the product's input.
fn inputNet(block: *const DesignBlock, brief: Brief) ?InputNet {
    const power = brief.input_power orelse return null;
    if (power.feeds.len > 0) return .{ .net = power.feeds, .how = "(input-power … (feeds \"…\"))" };
    for (brief.interfaces) |interface| {
        const port = portNamed(block, interface.name) orelse continue;
        return .{ .net = port, .how = "the brief interface matching a board port name" };
    }
    return null;
}

/// The net behind a design-block port of that name, case-insensitively.
fn portNamed(block: *const DesignBlock, name: []const u8) ?[]const u8 {
    for (block.ports) |port| {
        if (std.ascii.eqlIgnoreCase(port.name, name)) return port.net;
    }
    return null;
}

/// The brief's input window against the envelope the board proves for its
/// input net.
///
/// The check is coverage, not equality: the board's proven envelope must reach
/// at least as low as `LO` and at least as high as `HI`, because every rating
/// screen downstream — `component-rating-*`, `(check (voltage-range …))`,
/// `(check (cap-rating …))` — judges parts against that envelope. Closing a
/// failure therefore means widening the board's own `(port … (rated LO HI))`
/// or `(net-envelope …)` to the brief's window, at which point
/// `eval/net_envelopes` propagates it and every rating check judges against
/// the brief's numbers without knowing the brief exists.
///
/// `(transient T)` widens the ABS-MAX end only: a surge the product must
/// survive is not an operating point, so it raises the required ceiling
/// without moving the low end or the operating window.
fn appendInputPower(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    brief: Brief,
    out: *std.ArrayList(Observation),
) std.mem.Allocator.Error!void {
    const power = brief.input_power orelse return;
    const bound = inputNet(block, brief) orelse {
        try out.append(allocator, .{
            .id = id_input_power,
            .result = .not_declared,
            .message = try std.fmt.allocPrint(
                allocator,
                "the brief states {d:.3}–{d:.3} V from \"{s}\" but no board net is bound to it — add (input-power … (feeds \"NET\")) to the brief, or name the brief interface after a board port",
                .{ power.voltage_min_v, power.voltage_max_v, power.source },
            ),
        });
        return;
    };
    const envelope = net_envelopes.lookup(block, bound.net) orelse {
        try out.append(allocator, .{
            .id = id_input_power,
            .result = .not_declared,
            .message = try std.fmt.allocPrint(
                allocator,
                "{s} — bound by {s} — has no proven voltage envelope, so the brief's {d:.3}–{d:.3} V input window is not what the rating checks judge against",
                .{ bound.net, bound.how, power.voltage_min_v, power.voltage_max_v },
            ),
        });
        return;
    };
    const ceiling = @max(power.voltage_max_v, power.transient_v orelse power.voltage_max_v);
    const covers = envelope.min <= power.voltage_min_v + volt_epsilon and
        envelope.max + volt_epsilon >= ceiling;
    if (covers) return;
    try out.append(allocator, .{
        .id = id_input_power,
        .result = .fail,
        .message = try std.fmt.allocPrint(
            allocator,
            "{s} proves only {d:.3}–{d:.3} V but the brief states {d:.3}–{d:.3} V{s} — widen the port rating or (net-envelope \"{s}\" (rated {d:.3} {d:.3})) so the rating checks judge against the brief",
            .{
                bound.net,
                envelope.min,
                envelope.max,
                power.voltage_min_v,
                power.voltage_max_v,
                try transientClause(allocator, power.transient_v),
                bound.net,
                power.voltage_min_v,
                ceiling,
            },
        ),
    });
}

fn transientClause(allocator: std.mem.Allocator, transient_v: ?f64) std.mem.Allocator.Error![]const u8 {
    const volts = transient_v orelse return "";
    return std.fmt.allocPrint(allocator, " with a {d:.3} V transient to survive", .{volts});
}

// ── ESD protection ────────────────────────────────────────────────────

/// A declared ESD class demands a protection part on every externally exposed
/// interface the brief names.
///
/// An interface's net is resolved exactly as the input net is: the brief's
/// `(interface "NAME" …)` matched case-insensitively against a design-block
/// port name, then against a net name. What counts as protection is a part
/// with the `protection` review-profile class (authored `(class protection)`
/// or inferred from its pin functions), or a component whose family name marks
/// it as a TVS/ESD device.
fn appendEsd(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    brief: Brief,
    out: *std.ArrayList(Observation),
) std.mem.Allocator.Error!void {
    const esd = brief.compliance.esd orelse return;
    for (brief.interfaces) |interface| {
        const net = portNamed(block, interface.name) orelse netNamed(block, interface.name) orelse {
            try out.append(allocator, .{
                .id = id_esd_protection,
                .result = .not_declared,
                .message = try std.fmt.allocPrint(
                    allocator,
                    "the brief names interface \"{s}\" and an ESD class ({s}), but no board port or net of that name exists to check for protection",
                    .{ interface.name, esd },
                ),
            });
            continue;
        };
        if (protectedBy(allocator, block, project_dir, net) != null) continue;
        try out.append(allocator, .{
            .id = id_esd_protection,
            .result = .fail,
            .message = try std.fmt.allocPrint(
                allocator,
                "interface \"{s}\" (net {s}) carries no protection-class part, but the brief declares ESD compliance to {s}",
                .{ interface.name, net, esd },
            ),
        });
    }
}

/// The net of that name, compared on its base name so a split `.ref.pin`
/// suffix does not hide it.
fn netNamed(block: *const DesignBlock, name: []const u8) ?[]const u8 {
    for (block.nets) |net| {
        if (std.ascii.eqlIgnoreCase(net_analysis.baseNetName(net.name), name)) return net.name;
    }
    return null;
}

/// The ref-des of the first protection part sitting on `net`, or null.
fn protectedBy(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    net_name: []const u8,
) ?[]const u8 {
    for (block.nets) |net| {
        if (!std.mem.eql(u8, net.name, net_name)) continue;
        for (net.pins) |pin| {
            const inst = instanceNamed(block, pin.ref_des) orelse continue;
            if (isProtection(allocator, project_dir, inst)) return inst.ref_des;
        }
    }
    return null;
}

fn instanceNamed(block: *const DesignBlock, ref_des: []const u8) ?Instance {
    for (block.instances) |inst| {
        if (std.mem.eql(u8, inst.ref_des, ref_des)) return inst;
    }
    return null;
}

/// Component-name markers for a transient-suppression device, used when the
/// part carries no pin functions the class inference can read (a two-terminal
/// TVS diode has none worth naming).
const protection_families = [_][]const u8{ "tvs", "esd", "varistor", "transil" };

fn isProtection(allocator: std.mem.Allocator, project_dir: []const u8, inst: Instance) bool {
    if (review_profiles.resolve(allocator, project_dir, inst).class == .protection) return true;
    for (protection_families) |family| {
        if (containsIgnoreCase(inst.component, family)) return true;
    }
    return false;
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

fn briefWith(min_c: f64, max_c: f64, cooling: ?system_review.Cooling) Brief {
    return .{ .environment = .{ .ambient_min_c = min_c, .ambient_max_c = max_c, .cooling = cooling } };
}

// spec: system-review - a board with no governing brief keeps the bench ambient and produces no brief-driven observation
test "no brief leaves the screen at the bench default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const plan: Plan = .{};
    try testing.expectEqual(thermal.default_ambient_c, plan.ambient_c);
    try testing.expectEqual(@as(usize, 0), plan.source.system.len);
    var block: DesignBlock = .{ .name = "b", .instances = &.{}, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &.{} };
    const observations = try observe(alloc, &block, ".", plan);
    try testing.expectEqual(@as(usize, 0), observations.len);
}

// spec: system-review - the screening plan takes the brief's ambient maximum and maps its declared cooling case to a solver scenario
test "planOf reads the ambient maximum and the cooling case" {
    const plan = planOf("barracuda", briefWith(-10, 60, .airflow_1ms));
    try testing.expectEqual(@as(f64, 60), plan.ambient_c);
    try testing.expectEqual(@as(f64, -10), plan.window.?.min_c);
    try testing.expectEqualStrings("barracuda", plan.source.system);
    try testing.expectEqualStrings("airflow_1ms", plan.source.scenario);
    try testing.expectEqual(@as(usize, 0), plan.source.note.len);
}

// spec: system-review - a sealed-conduction brief is screened in still air and every surface is told the scenario is a conservative stand-in
test "sealed conduction maps to the conservative still-air rung" {
    const mapping = scenarioFor(.@"sealed-conduction");
    try testing.expectEqual(thermal_field.Scenario.natural, mapping.scenario);
    try testing.expect(mapping.approximated);
    try testing.expect(mapping.note.len > 0);
    const plan = planOf("barracuda", briefWith(-10, 60, .@"sealed-conduction"));
    try testing.expect(plan.source.note.len > 0);
    try testing.expectEqualStrings("natural", plan.source.scenario);
}

// spec: system-review - a named derating standard selects its published factors while the house default and an unknown standard change nothing
test "deratingFor selects a named standard and never invents one" {
    try testing.expect(deratingFor(null) == null);
    try testing.expect(deratingFor("house") == null);
    try testing.expect(deratingFor("our own process document") == null);
    const nasa = deratingFor("NASA EEE-INST-002 Level 2").?;
    try testing.expectEqualStrings("NASA EEE-INST-002", nasa.standard);
    try testing.expectApproxEqAbs(@as(f64, 0.6), nasa.ceramic_voltage, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.7), nasa.inductor_current, 1e-9);
    const ecss = deratingFor("ecss-q-st-30-11c").?;
    try testing.expectApproxEqAbs(@as(f64, 0.5), ecss.resistor_power, 1e-9);
}

// spec: system-review - temperature grades are ordered so a stricter grade satisfies a looser demand
test "temperature grades compare by severity" {
    try testing.expectEqual(system_review.TemperatureGrade.industrial, parseGrade("Industrial").?);
    try testing.expect(parseGrade("mil-spec") == null);
    try testing.expect(gradeRank(.automotive) > gradeRank(.extended));
    try testing.expect(gradeRank(.extended) > gradeRank(.industrial));
    try testing.expect(gradeRank(.industrial) > gradeRank(.commercial));
}

fn emptyBlock() DesignBlock {
    return .{
        .name = "b",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
}

fn activePart(ref: []const u8, thermal_decl: ?env_mod.ThermalDecl, properties: []const env_mod.Property) Instance {
    return .{
        .ref_des = ref,
        .component = "adf5901",
        .value = "",
        .footprint = "LFCSP-48",
        .symbol = "",
        .properties = properties,
        .thermal = .{ .decl = thermal_decl },
    };
}

fn firstWithId(observations: []const Observation, id: []const u8) ?Observation {
    for (observations) |observation| {
        if (std.mem.eql(u8, observation.id, id)) return observation;
    }
    return null;
}

// spec: system-review - an active part whose rated ambient range does not cover the brief window fails, and one declaring none is not-declared rather than passing
test "the ambient window is judged against every active part's rated range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parts = [_]Instance{
        activePart("U1", .{ .operating_min = -40, .operating_max = 85 }, &.{}),
        activePart("U2", .{ .operating_min = 0, .operating_max = 50 }, &.{}),
        activePart("U3", null, &.{}),
    };
    var block = emptyBlock();
    block.instances = &parts;

    const observations = try observe(alloc, &block, ".", planOf("barracuda", briefWith(-10, 60, null)));
    var fails: usize = 0;
    var missing: usize = 0;
    var covered: usize = 0;
    for (observations) |observation| {
        if (!std.mem.eql(u8, observation.id, id_operating_range)) continue;
        if (std.mem.eql(u8, observation.ref_des, "U1")) covered += 1;
        if (observation.result == .fail) fails += 1;
        if (observation.result == .not_declared) missing += 1;
    }
    // U1 covers -10...60 and says nothing; U2 is short at both ends; U3 never declared one.
    try testing.expectEqual(@as(usize, 0), covered);
    try testing.expectEqual(@as(usize, 1), fails);
    try testing.expectEqual(@as(usize, 1), missing);
}

// spec: system-review - the brief's input-power window is bound to a board net by (feeds "NET") or by an interface named after a board port, and an envelope narrower than the window fails
test "the input-power window binds to a board net and is judged against its envelope" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var block = emptyBlock();
    block.ports = &.{.{ .name = "VIN", .net = "V_12V", .direction = "in" }};
    block.rails = &.{.{ .name = "V_12V", .nominal = 12, .rated_voltage = .{ .min = 11.8, .max = 12.2 } }};

    const power: system_review.InputPower = .{
        .source = "12 V barrel",
        .voltage_min_v = 11.4,
        .voltage_max_v = 12.6,
        .feeds = "V_12V",
    };
    const narrow = try observe(alloc, &block, ".", planOf("barracuda", .{ .input_power = power }));
    const row = firstWithId(narrow, id_input_power) orelse return error.MissingRow;
    try testing.expectEqual(Result.fail, row.result);

    // Nothing bound at all is not-declared, never a pass.
    var unbound = power;
    unbound.feeds = "";
    const loose = try observe(alloc, &block, ".", planOf("barracuda", .{ .input_power = unbound }));
    const unbound_row = firstWithId(loose, id_input_power) orelse return error.MissingRow;
    try testing.expectEqual(Result.not_declared, unbound_row.result);

    // The interface-name fallback finds the same net through the board port.
    const interfaces = [_]system_review.BriefInterface{.{ .name = "vin" }};
    const bound = try observe(alloc, &block, ".", planOf("barracuda", .{ .input_power = unbound, .interfaces = &interfaces }));
    const bound_row = firstWithId(bound, id_input_power) orelse return error.MissingRow;
    try testing.expectEqual(Result.fail, bound_row.result);
}

// spec: system-review - a declared ESD class demands a protection-class part on every interface net the brief names
test "an ESD class demands protection on every named interface" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tvs: Instance = .{
        .ref_des = "D1",
        .component = "tvs-esd-array",
        .value = "",
        .footprint = "SOT-23",
        .symbol = "",
    };
    const parts = [_]Instance{tvs};
    const guarded = [_]env_mod.PinRef{.{ .ref_des = "D1", .pin = "1" }};
    var block = emptyBlock();
    block.instances = &parts;
    block.ports = &.{
        .{ .name = "OUT1", .net = "RF_OUT1", .direction = "out" },
        .{ .name = "OUT2", .net = "RF_OUT2", .direction = "out" },
    };
    block.nets = &.{
        .{ .name = "RF_OUT1", .pins = &guarded },
        .{ .name = "RF_OUT2", .pins = &.{} },
    };

    const interfaces = [_]system_review.BriefInterface{ .{ .name = "OUT1" }, .{ .name = "OUT2" } };
    const brief: Brief = .{
        .compliance = .{ .esd = "IEC 61000-4-2 8 kV" },
        .interfaces = &interfaces,
    };
    const observations = try observe(alloc, &block, ".", planOf("barracuda", brief));
    var rows: usize = 0;
    for (observations) |observation| {
        if (!std.mem.eql(u8, observation.id, id_esd_protection)) continue;
        rows += 1;
        try testing.expectEqual(Result.fail, observation.result);
    }
    // OUT1 is guarded by the TVS; only OUT2 is reported.
    try testing.expectEqual(@as(usize, 1), rows);

    // With no declared ESD class the same board owes nothing.
    var silent = brief;
    silent.compliance = .{};
    const quiet = try observe(alloc, &block, ".", planOf("barracuda", silent));
    try testing.expectEqual(@as(?Observation, null), firstWithId(quiet, id_esd_protection));
}
