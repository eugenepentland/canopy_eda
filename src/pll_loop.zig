//! Small-signal validation for charge-pump PLLs with an inverting active loop
//! filter.  A `(pll-loop …)` design form names the *actual* R/C instances, so
//! this analysis follows BOM value/tolerance edits instead of duplicating them
//! in a spreadsheet.  The frequency-domain model includes the charge-pump
//! shunt, the two feedback branches, the output isolation pole, VCO tune-pin
//! capacitance, and a one-pole finite-gain op amp.
//!
//! An optional operating curve runs a deterministic E24 inverse search and
//! quantizes an ADF4159 charge-pump schedule before rechecking exact tolerance
//! corners. This is a linear, continuous-time screen. It does not claim
//! sampled-PFD, nonlinear lock acquisition, phase-noise, charge-pump
//! compliance, or op-amp capacitive-load sign-off.

const std = @import("std");
const ast = @import("sexpr/ast.zig");
const env = @import("eval/env.zig");
const passive = @import("req_checks.zig");
const decouple_key = @import("decouple_key.zig");
const content_key = @import("placement/content_key.zig");
const infra_fs = @import("infra/fs.zig");

const Node = ast.Node;
const DesignBlock = env.DesignBlock;
const Instance = env.Instance;

/// Whether failed engineering limits warn or block a design build.
pub const Mode = enum { advisory, gate };
/// ADF4159 phase-detector polarity programmed by firmware.
pub const Polarity = enum { positive, negative };

/// Instance labels assigned to each element of the supported active filter.
pub const Components = struct {
    c_cp: []const u8 = "",
    r_in: []const u8 = "",
    r_feedback: []const u8 = "",
    c_feedback: []const u8 = "",
    c_feedback_hf: []const u8 = "",
    r_isolation: []const u8 = "",
    c_tune: []const u8 = "",
};

const Range = struct { min: f64 = 0, max: f64 = 0 };
const ValueTolerance = struct { value: f64 = 0, tolerance_pct: f64 = 0 };
const Feedback = struct { prescaler: f64 = 0, pll_n: f64 = 0 };
const Synthesis = struct {
    enabled: bool = false,
    resistor_range: Range = .{ .min = 10, .max = 20_000 },
    capacitor_range: Range = .{ .min = 0.5e-12, .max = 2e-9 },
};
const OperatingCurve = struct { point_nodes: []const Node = &.{} };
const OperatingPoint = struct { pll_n: f64, kvco_hz_per_v: f64 };

/// A `(pinned "KEY" (c-cp F) …)` clause inside `(synthesize …)`: the winning
/// corner of a search a previous build already ran, stamped with that search's
/// own content key. A matching key answers without the 6,000-candidate search;
/// a stale key is ignored (with a warning) and the search runs as if the pin
/// were absent — so a pin can only ever skip recomputing an answer, never
/// change one. Values hold component nominals in component order (`c-tune`
/// WITHOUT the extra tune cap, exactly as authored), snapped onto the E24 grid
/// at parse so the printed text round-trips to the search's bit-exact f64s.
const PinnedSynthesis = struct {
    key_lo: u64 = 0,
    key_hi: u64 = 0,
    values: [7]f64 = @splat(0),
};
const pinned_component_names = [_][]const u8{ "c-cp", "r-in", "r-feedback", "c-feedback", "c-feedback-hf", "r-isolation", "c-tune" };

const DesignMode = struct { operating_curve: OperatingCurve = .{}, synthesis: Synthesis = .{}, pinned: ?PinnedSynthesis = null };
const OpAmp = struct {
    gbw_hz: f64 = 0,
    dc_gain: f64 = 500_000,
    supply_v: Range = .{},
    max_supply_v: f64 = 0,
    output_headroom_v: Range = .{},
    slew_rate_v_per_s: f64 = 0,
};
const CircuitConfig = struct {
    extra_tune_cap: ValueTolerance = .{},
    pfd_hz: f64 = 0,
    charge_pump: ValueTolerance = .{},
    feedback: Feedback = .{},
    kvco_hz_per_v: Range = .{},
    op_amp: OpAmp = .{},
    polarity: Polarity = .positive,
};
const PhaseRequirement = struct { target_deg: Range = .{ .min = 45, .max = 55 }, hard_min_deg: f64 = 40 };
const RampRequirement = struct { span_hz: f64 = 0, time_s: f64 = 0, max_phase_error_rad: f64 = 0 };
const Requirements = struct { phase: PhaseRequirement = .{}, vtune_v: Range = .{}, ramp: RampRequirement = .{} };

/// Parsed declaration. Frequencies are Hz, currents A, capacitances F,
/// voltages V, and slew rate V/s.
pub const Spec = struct {
    name: []const u8,
    mode: Mode = .gate,
    topology_active_inverting: bool = false,
    components: Components = .{},
    circuit: CircuitConfig = .{},
    requirements: Requirements = .{},
    design: DesignMode = .{},
};

const ParseError = error{InvalidForm};

/// Parse the documented top-level form. Values are literal SI-scaled numbers;
/// component names are local instance labels or assigned ref-deses.
pub fn parse(form: []const Node) ParseError!Spec {
    if (form.len < 3) return error.InvalidForm;
    var out = Spec{ .name = form[1].asString() orelse return error.InvalidForm };
    for (form[2..]) |node| try parseChild(node, &out);
    if (!validSpec(out)) return error.InvalidForm;
    return out;
}

fn parseChild(node: Node, out: *Spec) ParseError!void {
    const c = node.asList() orelse return error.InvalidForm;
    if (c.len == 0) return error.InvalidForm;
    const head = c[0].asAtom() orelse return error.InvalidForm;
    if (eq(head, "mode")) {
        const word = try atomAt(c, 1);
        out.mode = if (eq(word, "advisory")) .advisory else if (eq(word, "gate")) .gate else return error.InvalidForm;
    } else if (eq(head, "topology")) {
        if (!eq(try atomAt(c, 1), "active-inverting")) return error.InvalidForm;
        out.topology_active_inverting = true;
    } else if (eq(head, "components")) {
        try parseComponents(c, &out.components);
    } else if (eq(head, "extra-tune-cap")) {
        out.circuit.extra_tune_cap.value = try positiveAt(c, 1);
        if (c.len > 2) out.circuit.extra_tune_cap.tolerance_pct = try nonNegativeAt(c, 2);
    } else if (eq(head, "pfd")) {
        out.circuit.pfd_hz = try positiveAt(c, 1);
    } else if (eq(head, "charge-pump")) {
        out.circuit.charge_pump.value = try positiveAt(c, 1);
        if (c.len > 2) out.circuit.charge_pump.tolerance_pct = try nonNegativeAt(c, 2);
    } else if (eq(head, "feedback-divider")) {
        out.circuit.feedback.prescaler = try positiveAt(c, 1);
        out.circuit.feedback.pll_n = try positiveAt(c, 2);
    } else if (eq(head, "kvco")) {
        out.circuit.kvco_hz_per_v.min = try positiveAt(c, 1);
        out.circuit.kvco_hz_per_v.max = try positiveAt(c, 2);
    } else if (eq(head, "op-amp")) {
        try parseOpAmp(c, &out.circuit.op_amp);
    } else if (eq(head, "operating-curve")) {
        try parseOperatingCurve(c, &out.design.operating_curve);
    } else if (eq(head, "synthesize")) {
        try parseSynthesis(c, &out.design);
    } else if (eq(head, "phase-margin")) {
        try parsePhaseMargin(c, &out.requirements.phase);
    } else if (eq(head, "polarity")) {
        const word = try atomAt(c, 1);
        out.circuit.polarity = if (eq(word, "negative")) .negative else if (eq(word, "positive")) .positive else return error.InvalidForm;
    } else if (!try parseLimits(c, head, out)) return error.InvalidForm;
}

fn parseOperatingCurve(c: []const Node, out: *OperatingCurve) ParseError!void {
    if (c.len < 3 or c.len > 17) return error.InvalidForm;
    var previous_n: f64 = 0;
    for (c[1..]) |node| {
        const point = try parseOperatingPoint(node);
        if (point.pll_n <= previous_n) return error.InvalidForm;
        previous_n = point.pll_n;
    }
    out.point_nodes = c[1..];
}

fn parseOperatingPoint(node: Node) ParseError!OperatingPoint {
    const p = node.asList() orelse return error.InvalidForm;
    if (p.len != 3 or !eq(try atomAt(p, 0), "point")) return error.InvalidForm;
    return .{ .pll_n = try positiveAt(p, 1), .kvco_hz_per_v = try positiveAt(p, 2) };
}

fn parseSynthesis(c: []const Node, out: *DesignMode) ParseError!void {
    out.synthesis.enabled = true;
    for (c[1..]) |node| {
        const p = node.asList() orelse return error.InvalidForm;
        const head = try atomAt(p, 0);
        if (eq(head, "series")) {
            if (!eq(try atomAt(p, 1), "e24")) return error.InvalidForm;
        } else if (eq(head, "resistance-range")) {
            out.synthesis.resistor_range = .{ .min = try positiveAt(p, 1), .max = try positiveAt(p, 2) };
        } else if (eq(head, "capacitance-range")) {
            out.synthesis.capacitor_range = .{ .min = try positiveAt(p, 1), .max = try positiveAt(p, 2) };
        } else if (eq(head, "pinned")) {
            out.pinned = try parsePinned(p);
        } else return error.InvalidForm;
    }
    if (out.synthesis.resistor_range.max < out.synthesis.resistor_range.min) return error.InvalidForm;
    if (out.synthesis.capacitor_range.max < out.synthesis.capacitor_range.min) return error.InvalidForm;
}

/// `(pinned "KEY32HEX" (c-cp F) (r-in R) (r-feedback R) (c-feedback F)
/// (c-feedback-hf F) (r-isolation R) (c-tune F))` — the key string every
/// unpinned build prints, plus all seven components, each exactly once in any
/// order. Values snap onto the E24 grid (see `snapE24`).
fn parsePinned(p: []const Node) ParseError!PinnedSynthesis {
    if (p.len != 2 + pinned_component_names.len) return error.InvalidForm;
    const key_text = p[1].asString() orelse return error.InvalidForm;
    if (key_text.len != 32) return error.InvalidForm;
    var pin = PinnedSynthesis{};
    pin.key_hi = std.fmt.parseInt(u64, key_text[0..16], 16) catch return error.InvalidForm;
    pin.key_lo = std.fmt.parseInt(u64, key_text[16..32], 16) catch return error.InvalidForm;
    var seen: [pinned_component_names.len]bool = @splat(false);
    for (p[2..]) |node| {
        const entry = node.asList() orelse return error.InvalidForm;
        const head = try atomAt(entry, 0);
        const index = for (pinned_component_names, 0..) |name, i| {
            if (eq(head, name)) break i;
        } else return error.InvalidForm;
        if (seen[index]) return error.InvalidForm;
        seen[index] = true;
        pin.values[index] = snapE24(try positiveAt(entry, 1));
    }
    for (seen) |s| if (!s) return error.InvalidForm;
    return pin;
}

fn parseLimits(c: []const Node, head: []const u8, out: *Spec) ParseError!bool {
    if (eq(head, "supply")) {
        out.circuit.op_amp.supply_v.min = try positiveAt(c, 1);
        out.circuit.op_amp.supply_v.max = try positiveAt(c, 2);
    } else if (eq(head, "op-amp-max-supply")) {
        out.circuit.op_amp.max_supply_v = try positiveAt(c, 1);
    } else if (eq(head, "vtune")) {
        out.requirements.vtune_v.min = try nonNegativeAt(c, 1);
        out.requirements.vtune_v.max = try nonNegativeAt(c, 2);
    } else if (eq(head, "output-headroom")) {
        out.circuit.op_amp.output_headroom_v.min = try nonNegativeAt(c, 1);
        out.circuit.op_amp.output_headroom_v.max = try nonNegativeAt(c, 2);
    } else if (eq(head, "ramp")) {
        out.requirements.ramp.span_hz = try positiveAt(c, 1);
        out.requirements.ramp.time_s = try positiveAt(c, 2);
    } else if (eq(head, "max-ramp-phase-error")) {
        out.requirements.ramp.max_phase_error_rad = try positiveAt(c, 1);
    } else if (eq(head, "slew-rate")) {
        out.circuit.op_amp.slew_rate_v_per_s = try positiveAt(c, 1);
    } else return false;
    return true;
}

fn parseComponents(c: []const Node, out: *Components) ParseError!void {
    for (c[1..]) |node| {
        const p = node.asList() orelse return error.InvalidForm;
        if (p.len != 2) return error.InvalidForm;
        const head = p[0].asAtom() orelse return error.InvalidForm;
        const name = p[1].asString() orelse return error.InvalidForm;
        if (eq(head, "c-cp")) out.c_cp = name else if (eq(head, "r-in")) out.r_in = name else if (eq(head, "r-feedback"))
            out.r_feedback = name
        else if (eq(head, "c-feedback")) out.c_feedback = name else if (eq(head, "c-feedback-hf"))
            out.c_feedback_hf = name
        else if (eq(head, "r-isolation")) out.r_isolation = name else if (eq(head, "c-tune"))
            out.c_tune = name
        else
            return error.InvalidForm;
    }
}

fn parseOpAmp(c: []const Node, out: *OpAmp) ParseError!void {
    for (c[1..]) |node| {
        const p = node.asList() orelse return error.InvalidForm;
        const head = if (p.len > 0) p[0].asAtom() else null;
        if (head == null) return error.InvalidForm;
        if (eq(head.?, "gbw")) out.gbw_hz = try positiveAt(p, 1) else if (eq(head.?, "dc-gain"))
            out.dc_gain = try positiveAt(p, 1)
        else
            return error.InvalidForm;
    }
}

fn parsePhaseMargin(c: []const Node, out: *PhaseRequirement) ParseError!void {
    for (c[1..]) |node| {
        const p = node.asList() orelse return error.InvalidForm;
        const head = if (p.len > 0) p[0].asAtom() else null;
        if (head == null) return error.InvalidForm;
        if (eq(head.?, "target")) {
            out.target_deg.min = try positiveAt(p, 1);
            out.target_deg.max = try positiveAt(p, 2);
        } else if (eq(head.?, "hard-min")) out.hard_min_deg = try positiveAt(p, 1) else return error.InvalidForm;
    }
}

fn atomAt(c: []const Node, index: usize) ParseError![]const u8 {
    if (index >= c.len) return error.InvalidForm;
    return c[index].asAtom() orelse error.InvalidForm;
}

fn positiveAt(c: []const Node, index: usize) ParseError!f64 {
    const value = try nonNegativeAt(c, index);
    if (value <= 0) return error.InvalidForm;
    return value;
}

fn nonNegativeAt(c: []const Node, index: usize) ParseError!f64 {
    if (index >= c.len) return error.InvalidForm;
    const value = c[index].asNumber() orelse return error.InvalidForm;
    if (!std.math.isFinite(value) or value < 0) return error.InvalidForm;
    return value;
}

fn validSpec(out: Spec) bool {
    if (!out.topology_active_inverting) return false;
    if (!complete(out.components)) return false;
    if (out.circuit.pfd_hz <= 0) return false;
    if (out.circuit.charge_pump.value <= 0) return false;
    if (out.circuit.feedback.prescaler <= 0) return false;
    if (out.circuit.feedback.pll_n <= 0) return false;
    if (out.circuit.kvco_hz_per_v.min <= 0) return false;
    if (out.circuit.kvco_hz_per_v.max < out.circuit.kvco_hz_per_v.min) return false;
    if (out.design.synthesis.enabled and out.design.operating_curve.point_nodes.len < 2) return false;
    return out.circuit.op_amp.gbw_hz > 0;
}

fn complete(c: Components) bool {
    return c.c_cp.len > 0 and c.r_in.len > 0 and c.r_feedback.len > 0 and
        c.c_feedback.len > 0 and c.c_feedback_hf.len > 0 and
        c.r_isolation.len > 0 and c.c_tune.len > 0;
}

const Value = struct {
    nominal: f64,
    tolerance_pct: f64,
    tolerance_abs: f64 = 0,
    ref: []const u8,

    fn tolerancePctAt(self: Value, nominal: f64) f64 {
        if (self.tolerance_abs > 0 and nominal > 0) return self.tolerance_abs / nominal * 100.0;
        return self.tolerance_pct;
    }
};
const Circuit = struct {
    c_cp: Value,
    r_in: Value,
    r_feedback: Value,
    c_feedback: Value,
    c_feedback_hf: Value,
    r_isolation: Value,
    c_tune: Value,
    extra_tune_cap: Value,
};

const Corner = struct {
    c_cp: f64,
    r_in: f64,
    r_feedback: f64,
    c_feedback: f64,
    c_feedback_hf: f64,
    r_isolation: f64,
    c_tune: f64,
};

const Metrics = struct { crossover_hz: f64, phase_margin_deg: f64 };
const Sweep = struct {
    min_bandwidth_hz: f64 = std.math.inf(f64),
    max_bandwidth_hz: f64 = 0,
    min_phase_margin_deg: f64 = std.math.inf(f64),
    max_phase_margin_deg: f64 = -std.math.inf(f64),
    solved: usize = 0,

    fn add(self: *Sweep, m: Metrics) void {
        self.min_bandwidth_hz = @min(self.min_bandwidth_hz, m.crossover_hz);
        self.max_bandwidth_hz = @max(self.max_bandwidth_hz, m.crossover_hz);
        self.min_phase_margin_deg = @min(self.min_phase_margin_deg, m.phase_margin_deg);
        self.max_phase_margin_deg = @max(self.max_phase_margin_deg, m.phase_margin_deg);
        self.solved += 1;
    }
};

/// Evaluate one declaration and append normal design assertions. In advisory
/// mode a failed engineering limit is a warning, suitable while graph-derived
/// Kvco or firmware charge-pump settings are still provisional.
pub fn evaluate(allocator: std.mem.Allocator, assertions: *std.ArrayList(env.AssertionResult), block: *const DesignBlock, spec: Spec) std.mem.Allocator.Error!void {
    var context = Context{ .allocator = allocator, .assertions = assertions };
    const circuit = resolveCircuit(block, spec) orelse {
        try append(&context, spec, false, "{s}: loop-filter component binding failed; every named R/C must exist and have a parseable value", .{spec.name});
        return;
    };
    try append(&context, spec, true, "{s}: BOM values loaded — {s} {d:.0} pF ±{d:.2}%, {s} {d:.0} Ω ±{d:.2}%, {s} {d:.0} Ω ±{d:.2}% / {s} {d:.1} pF ±{d:.2}%, {s} {d:.1} pF ±{d:.2}%, {s} {d:.0} Ω ±{d:.2}% / {s} {d:.0} pF ±{d:.2}%", .{ spec.name, circuit.c_cp.ref, circuit.c_cp.nominal * 1e12, circuit.c_cp.tolerancePctAt(circuit.c_cp.nominal), circuit.r_in.ref, circuit.r_in.nominal, circuit.r_in.tolerancePctAt(circuit.r_in.nominal), circuit.r_feedback.ref, circuit.r_feedback.nominal, circuit.r_feedback.tolerancePctAt(circuit.r_feedback.nominal), circuit.c_feedback.ref, circuit.c_feedback.nominal * 1e12, circuit.c_feedback.tolerancePctAt(circuit.c_feedback.nominal), circuit.c_feedback_hf.ref, circuit.c_feedback_hf.nominal * 1e12, circuit.c_feedback_hf.tolerancePctAt(circuit.c_feedback_hf.nominal), circuit.r_isolation.ref, circuit.r_isolation.nominal, circuit.r_isolation.tolerancePctAt(circuit.r_isolation.nominal), circuit.c_tune.ref, (circuit.c_tune.nominal + circuit.extra_tune_cap.nominal) * 1e12, @max(circuit.c_tune.tolerancePctAt(circuit.c_tune.nominal), circuit.extra_tune_cap.tolerancePctAt(circuit.extra_tune_cap.nominal)) });

    try append(&context, spec, loopCapsAreStable(block, spec.components), "{s}: every frequency-shaping capacitor is C0G/NP0", .{spec.name});

    const nominal = nominalCorner(circuit);
    var sweep = Sweep{};
    const kvco_mid = @sqrt(spec.circuit.kvco_hz_per_v.min * spec.circuit.kvco_hz_per_v.max);
    for ([_]f64{ spec.circuit.kvco_hz_per_v.min, kvco_mid, spec.circuit.kvco_hz_per_v.max }) |kvco| {
        if (analyze(spec, nominal, spec.circuit.charge_pump.value, kvco)) |m| sweep.add(m);
    }
    if (sweep.solved != 3) {
        try append(&context, spec, false, "{s}: no unique 0 dB crossover was found across the Kvco sweep", .{spec.name});
        return;
    }
    try append(&context, spec, sweep.min_phase_margin_deg >= spec.requirements.phase.hard_min_deg, "{s}: nominal Kvco sweep {d:.0}-{d:.0} MHz/V gives LBW {d:.3}-{d:.3} MHz and phase margin {d:.1}-{d:.1}° (hard minimum {d:.1}°)", .{ spec.name, spec.circuit.kvco_hz_per_v.min / 1e6, spec.circuit.kvco_hz_per_v.max / 1e6, sweep.min_bandwidth_hz / 1e6, sweep.max_bandwidth_hz / 1e6, sweep.min_phase_margin_deg, sweep.max_phase_margin_deg, spec.requirements.phase.hard_min_deg });
    try append(&context, spec, sweep.min_phase_margin_deg >= spec.requirements.phase.target_deg.min and sweep.max_phase_margin_deg <= spec.requirements.phase.target_deg.max, "{s}: nominal phase margin stays inside target {d:.1}-{d:.1}°", .{ spec.name, spec.requirements.phase.target_deg.min, spec.requirements.phase.target_deg.max });

    const worst = toleranceSweep(spec, circuit);
    try append(&context, spec, worst.solved > 0 and worst.min_phase_margin_deg >= spec.requirements.phase.hard_min_deg, "{s}: deterministic R/C/Icp tolerance corners give LBW {d:.3}-{d:.3} MHz and minimum phase margin {d:.1}°", .{ spec.name, worst.min_bandwidth_hz / 1e6, worst.max_bandwidth_hz / 1e6, worst.min_phase_margin_deg });

    const pfd_ratio = spec.circuit.pfd_hz / sweep.max_bandwidth_hz;
    try append(&context, spec, pfd_ratio >= 10, "{s}: PFD/LBW ratio is {d:.1} at the widest nominal corner (must be ≥10)", .{ spec.name, pfd_ratio });
    const gbw_ratio = spec.circuit.op_amp.gbw_hz / sweep.max_bandwidth_hz;
    try append(&context, spec, gbw_ratio >= 10, "{s}: op-amp GBW/LBW ratio is {d:.1} at the widest nominal corner (must be ≥10; ≥20 preferred)", .{ spec.name, gbw_ratio });
    if (gbw_ratio >= 10 and gbw_ratio < 20) try warning(&context, "{s}: op-amp GBW/LBW ratio {d:.1} passes the hard floor but is below the preferred 20", .{ spec.name, gbw_ratio });

    try append(&context, spec, spec.circuit.polarity == .negative, "{s}: inverting active filter requires negative ADF4159 phase-detector polarity", .{spec.name});
    var tracking_bandwidth_hz = sweep.min_bandwidth_hz;
    if (spec.design.operating_curve.point_nodes.len >= 2) {
        const profile = fixedProfileSweep(spec, nominal, false);
        const profile_tolerance = fixedProfileToleranceSweep(spec, circuit);
        tracking_bandwidth_hz = profile.min_bandwidth_hz;
        try append(&context, spec, profile.min_phase_margin_deg >= spec.requirements.phase.hard_min_deg and profile_tolerance.min_phase_margin_deg >= spec.requirements.phase.hard_min_deg, "{s}: populated fixed-I_CP operating curve gives nominal LBW {d:.3}-{d:.3} MHz / PM {d:.1}-{d:.1}° and tolerance-corner LBW {d:.3}-{d:.3} MHz / PM {d:.1}-{d:.1}°", .{ spec.name, profile.min_bandwidth_hz / 1e6, profile.max_bandwidth_hz / 1e6, profile.min_phase_margin_deg, profile.max_phase_margin_deg, profile_tolerance.min_bandwidth_hz / 1e6, profile_tolerance.max_bandwidth_hz / 1e6, profile_tolerance.min_phase_margin_deg, profile_tolerance.max_phase_margin_deg });
    }
    try outputChecks(&context, spec);
    try rampChecks(&context, spec, tracking_bandwidth_hz);
    try chargePumpSuggestion(&context, spec, nominal, sweep.min_phase_margin_deg);
    if (spec.design.synthesis.enabled) try synthesize(&context, spec, circuit);
}

const Context = struct {
    allocator: std.mem.Allocator,
    assertions: *std.ArrayList(env.AssertionResult),
};

fn outputChecks(context: *Context, spec: Spec) std.mem.Allocator.Error!void {
    if (spec.circuit.op_amp.supply_v.min <= 0 or spec.circuit.op_amp.supply_v.max <= 0) return;
    const swing_min = spec.circuit.op_amp.output_headroom_v.min;
    const swing_max = spec.circuit.op_amp.supply_v.min - spec.circuit.op_amp.output_headroom_v.max;
    try append(context, spec, spec.requirements.vtune_v.min >= swing_min and spec.requirements.vtune_v.max <= swing_max, "{s}: worst-case op-amp output range is {d:.2}-{d:.2} V; required VTUNE is {d:.2}-{d:.2} V", .{ spec.name, swing_min, swing_max, spec.requirements.vtune_v.min, spec.requirements.vtune_v.max });
    if (spec.circuit.op_amp.max_supply_v > 0) try append(context, spec, spec.circuit.op_amp.supply_v.max <= spec.circuit.op_amp.max_supply_v, "{s}: loop rail maximum {d:.2} V is within op-amp {d:.2} V operating maximum ({d:.2} V margin)", .{ spec.name, spec.circuit.op_amp.supply_v.max, spec.circuit.op_amp.max_supply_v, spec.circuit.op_amp.max_supply_v - spec.circuit.op_amp.supply_v.max });
}

fn rampChecks(context: *Context, spec: Spec, min_bandwidth_hz: f64) std.mem.Allocator.Error!void {
    if (spec.requirements.ramp.span_hz <= 0 or spec.requirements.ramp.time_s <= 0) return;
    const slope = spec.requirements.ramp.span_hz / spec.requirements.ramp.time_s;
    // Standard type-II envelope estimate near 50° PM: fc ≈ 1.4 fn.
    const natural_hz = min_bandwidth_hz / 1.4;
    const phase_error = slope / (2.0 * std.math.pi * natural_hz * natural_hz);
    if (spec.requirements.ramp.max_phase_error_rad > 0) try append(context, spec, phase_error <= spec.requirements.ramp.max_phase_error_rad, "{s}: linear-ramp phase-error estimate is {d:.2} rad at the narrowest loop (limit {d:.2} rad; fc/1.4 envelope model)", .{ spec.name, phase_error, spec.requirements.ramp.max_phase_error_rad });
    if (spec.circuit.op_amp.slew_rate_v_per_s > 0) {
        const required = slope / spec.circuit.kvco_hz_per_v.min;
        try append(context, spec, required <= spec.circuit.op_amp.slew_rate_v_per_s, "{s}: VTUNE slew requires {d:.3} V/µs; op amp provides {d:.1} V/µs", .{ spec.name, required / 1e6, spec.circuit.op_amp.slew_rate_v_per_s / 1e6 });
    }
}

fn chargePumpSuggestion(context: *Context, spec: Spec, corner: Corner, current_min_pm: f64) std.mem.Allocator.Error!void {
    if (current_min_pm >= spec.requirements.phase.target_deg.min) return;
    var best_current: f64 = 0;
    var best_min_pm: f64 = -std.math.inf(f64);
    var best_min_bw: f64 = 0;
    var best_max_bw: f64 = 0;
    for (1..17) |step| {
        const icp = 5e-3 * @as(f64, @floatFromInt(step)) / 16.0;
        var candidate = Sweep{};
        const kvco_mid = @sqrt(spec.circuit.kvco_hz_per_v.min * spec.circuit.kvco_hz_per_v.max);
        for ([_]f64{ spec.circuit.kvco_hz_per_v.min, kvco_mid, spec.circuit.kvco_hz_per_v.max }) |kvco|
            if (analyze(spec, corner, icp, kvco)) |m| candidate.add(m);
        if (candidate.solved == 3 and candidate.min_phase_margin_deg > best_min_pm) {
            best_current = icp;
            best_min_pm = candidate.min_phase_margin_deg;
            best_min_bw = candidate.min_bandwidth_hz;
            best_max_bw = candidate.max_bandwidth_hz;
        }
    }
    try warning(context, "{s}: no claim is made that the current population is optimal; best ADF4159 5 mA/16 step is {d:.4} mA with nominal min PM {d:.1}° and LBW {d:.3}-{d:.3} MHz", .{ spec.name, best_current * 1e3, best_min_pm, best_min_bw / 1e6, best_max_bw / 1e6 });
}

const SynthResult = struct {
    corner: Corner,
    anchor_step: usize,
    nominal: Sweep,
    tolerance: Sweep,
};

const e24 = [_]f64{ 1.0, 1.1, 1.2, 1.3, 1.5, 1.6, 1.8, 2.0, 2.2, 2.4, 2.7, 3.0, 3.3, 3.6, 3.9, 4.3, 4.7, 5.1, 5.6, 6.2, 6.8, 7.5, 8.2, 9.1 };
const synthesis_primes = [_]usize{ 2, 3, 5, 7, 11, 13, 17 };

fn synthesize(context: *Context, spec: Spec, circuit: Circuit) std.mem.Allocator.Error!void {
    const key = synthKey(spec, circuit);
    if (spec.design.pinned) |pin| {
        if (pin.key_lo == key.lo and pin.key_hi == key.hi) {
            try appendSynthesisResult(context, spec, circuit, pinnedResult(spec, circuit, pin));
            return;
        }
        try warning(context, "{s}: pinned synthesis is stale — the declaration or resolved values no longer match its key, so the full search ran; replace the pin from the line below", .{spec.name});
    }
    const result = memoisedSynthesis(spec, circuit);
    try appendSynthesisResult(context, spec, circuit, result);
    try appendPinOffer(context, spec, circuit, key, result);
}

/// The `SynthResult` a current pin stands for: the pinned corner pushed
/// through the same helpers `findSynthesis` returns through, so a pinned
/// evaluation and the search it replaces are the same answer to the digit.
fn pinnedResult(spec: Spec, circuit: Circuit, pin: PinnedSynthesis) SynthResult {
    const first = parseOperatingPoint(spec.design.operating_curve.point_nodes[0]) catch OperatingPoint{ .pll_n = spec.circuit.feedback.pll_n, .kvco_hz_per_v = spec.circuit.kvco_hz_per_v.min };
    const anchor_step = synthesisAnchorStep(spec, first);
    const corner = Corner{ .c_cp = pin.values[0], .r_in = pin.values[1], .r_feedback = pin.values[2], .c_feedback = pin.values[3], .c_feedback_hf = pin.values[4], .r_isolation = pin.values[5], .c_tune = pin.values[6] + circuit.extra_tune_cap.nominal };
    return .{
        .corner = corner,
        .anchor_step = anchor_step,
        .nominal = profileSweep(spec, corner, anchor_step, false),
        .tolerance = synthesisToleranceSweep(spec, circuit, corner, anchor_step),
    };
}

/// The copy-paste line that makes the NEXT evaluation skip the search: the
/// search's winning component values plus the content key of everything the
/// search read. Printed values are snapped onto the E24 grid so they read as
/// the catalogue numbers they are; parsing snaps again, so the round trip
/// lands on the identical f64s either way.
fn appendPinOffer(context: *Context, spec: Spec, circuit: Circuit, key: content_key.Key, result: SynthResult) std.mem.Allocator.Error!void {
    const c = result.corner;
    try append(context, spec, true, "{s}: pin this search — (pinned \"{x:0>16}{x:0>16}\" (c-cp {d}pF) (r-in {d}R) (r-feedback {d}R) (c-feedback {d}pF) (c-feedback-hf {d}pF) (r-isolation {d}R) (c-tune {d}pF))", .{ spec.name, key.hi, key.lo, snapE24(c.c_cp * 1e12), snapE24(c.r_in), snapE24(c.r_feedback), snapE24(c.c_feedback * 1e12), snapE24(c.c_feedback_hf * 1e12), snapE24(c.r_isolation), snapE24((c.c_tune - circuit.extra_tune_cap.nominal) * 1e12) });
}

// ── Synthesis memo ────────────────────────────────────────────────────────
//
// `(synthesize …)` runs a 6,000-candidate deterministic inverse search plus six
// refinement rounds, and it runs inside DESIGN EVALUATION — so every page
// render, every `netlisp build`, every ERC run and every module resolution of a
// design carrying one paid for it again. Measured on barracuda (ReleaseSafe,
// 2026-08-28): 3.7 s of a 3.8 s `Evaluator.evalFile`, and a single cold PCB
// page evaluates the module TWICE (the design, then the Stamp palette's module
// resolution), a deferred-payload cycle four times.
//
// The search reads nothing but the declaration and the resolved R/C values, so
// its answer is kept for the life of the process and the repeats are free. A
// miss recomputes: cache loss changes latency, never an assertion.

/// Bumped whenever a change to the search makes an OLD key describe a result
/// this build would no longer produce.
const synth_key_version: u8 = 1;

/// Distinct synthesis declarations held at once. A design carries one or two;
/// the corpus a single server evaluates carries a handful.
const synth_memo_max: usize = 8;

const SynthEntry = struct { key: content_key.Key, result: SynthResult };

/// The memo itself. Small, fixed and oldest-first: this is a working set over
/// the declarations a process actually evaluates, not a cache to grow.
const SynthMemo = struct {
    mutex: infra_fs.Mutex = .{},
    entries: [synth_memo_max]?SynthEntry = @splat(null),
    next: usize = 0,

    fn get(self: *SynthMemo, key: content_key.Key) ?SynthResult {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries) |slot| {
            const entry = slot orelse continue;
            if (entry.key.eql(key)) return entry.result;
        }
        return null;
    }

    fn put(self: *SynthMemo, key: content_key.Key, result: SynthResult) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries) |slot| {
            const entry = slot orelse continue;
            if (entry.key.eql(key)) return;
        }
        self.entries[self.next] = .{ .key = key, .result = result };
        self.next = (self.next + 1) % synth_memo_max;
    }
};

var synth_memo: SynthMemo = .{};

/// `findSynthesis` through the process memo. Identical answer either way.
fn memoisedSynthesis(spec: Spec, circuit: Circuit) SynthResult {
    const key = synthKey(spec, circuit);
    if (synth_memo.get(key)) |hit| return hit;
    const result = findSynthesis(spec, circuit);
    synth_memo.put(key, result);
    return result;
}

/// The content key of one synthesis search: everything `findSynthesis` reads.
///
/// The walk over `Spec` is reflective on purpose — a field added to the
/// declaration is covered the day it is declared, and a type the fingerprint
/// cannot reduce fails the BUILD rather than going quietly unkeyed. `design` is
/// the one field taken apart by hand, because its operating curve holds raw
/// AST nodes; the SEARCH reads them only through `profileSample`, so the parsed
/// points are what is folded in, and the compile-time length check below fails
/// the build if `DesignMode` ever grows a third field nobody keyed.
fn synthKey(spec: Spec, circuit: Circuit) content_key.Key {
    // Three DesignMode fields, of which `pinned` is DELIBERATELY not keyed: a
    // pin is a memo OF this key's answer, so folding it in would be circular —
    // authoring the pin the offer line prints would change the key and
    // instantly un-pin it. The search never reads the pin, so the key is
    // complete without it.
    comptime std.debug.assert(@typeInfo(DesignMode).@"struct".field_names.len == 3);
    var fp: content_key.Fingerprint = .{};
    fp.tag(synth_key_version);
    const info = @typeInfo(Spec).@"struct";
    inline for (info.field_names, info.field_types) |name, Field| {
        if (comptime !std.mem.eql(u8, name, "design")) fp.put(Field, @field(spec, name));
    }
    fp.put(Synthesis, spec.design.synthesis);
    fp.put(usize, profileSampleCount(spec));
    for (0..profileSampleCount(spec)) |index| {
        const point = profileSample(spec, index) orelse continue;
        fp.put(usize, index);
        fp.put(f64, point.pll_n);
        fp.put(f64, point.kvco_hz_per_v);
    }
    fp.put(usize, @typeInfo(Circuit).@"struct".field_names.len);
    inline for (@typeInfo(Circuit).@"struct".field_names) |name| putValue(&fp, @field(circuit, name));
    return fp.final();
}

/// Fold one resolved passive in by the numbers the search reads, and NOT by its
/// `ref`. The reference designator is what the assertion TEXT prints, and it
/// differs between a module evaluated standalone and the same module evaluated
/// inside a design that renumbers it — while the search's answer does not.
/// Keying on it would miss on exactly the pair this memo exists to join.
/// The field count is asserted so a new `Value` field is a decision somebody
/// makes here rather than one that goes quietly unkeyed.
fn putValue(fp: *content_key.Fingerprint, value: Value) void {
    comptime std.debug.assert(@typeInfo(Value).@"struct".field_names.len == 4);
    fp.put(f64, value.nominal);
    fp.put(f64, value.tolerance_pct);
    fp.put(f64, value.tolerance_abs);
}

fn findSynthesis(spec: Spec, circuit: Circuit) SynthResult {
    const first = parseOperatingPoint(spec.design.operating_curve.point_nodes[0]) catch OperatingPoint{ .pll_n = spec.circuit.feedback.pll_n, .kvco_hz_per_v = spec.circuit.kvco_hz_per_v.min };
    const anchor_step = synthesisAnchorStep(spec, first);
    var best_score = std.math.inf(f64);
    var best_corner = nominalCorner(circuit);
    for (1..6_001) |index| {
        const candidate = synthesisCandidate(spec, circuit, index);
        const score = synthesisScore(spec, circuit, candidate, anchor_step);
        if (score < best_score) {
            best_score = score;
            best_corner = candidate;
        }
    }
    for (0..6) |_| {
        var improved = false;
        for (0..7) |component_index| {
            for ([_]f64{ 1.0 / 1.3, 1.0 / 1.2, 1.0 / 1.1, 1.1, 1.2, 1.3 }) |ratio| {
                const candidate = synthesisNeighbor(spec, circuit, best_corner, component_index, ratio);
                const score = synthesisScore(spec, circuit, candidate, anchor_step);
                if (score < best_score) {
                    best_score = score;
                    best_corner = candidate;
                    improved = true;
                }
            }
        }
        if (!improved) break;
    }

    return .{
        .corner = best_corner,
        .anchor_step = anchor_step,
        .nominal = profileSweep(spec, best_corner, anchor_step, false),
        .tolerance = synthesisToleranceSweep(spec, circuit, best_corner, anchor_step),
    };
}

fn synthesisAnchorStep(spec: Spec, first: OperatingPoint) usize {
    var maximum_ratio: f64 = 1;
    for (spec.design.operating_curve.point_nodes) |node| {
        const point = parseOperatingPoint(node) catch continue;
        const ratio = (point.pll_n / point.kvco_hz_per_v) / (first.pll_n / first.kvco_hz_per_v);
        maximum_ratio = @max(maximum_ratio, ratio);
    }
    const maximum_step: usize = @intFromFloat(@floor(16.0 / maximum_ratio));
    return @max(1, @min(16, (maximum_step * 4 + 2) / 5));
}

fn synthesisCandidate(spec: Spec, circuit: Circuit, index: usize) Corner {
    const base = [_]f64{ circuit.c_cp.nominal, circuit.r_in.nominal, circuit.r_feedback.nominal, circuit.c_feedback.nominal, circuit.c_feedback_hf.nominal, circuit.r_isolation.nominal, circuit.c_tune.nominal };
    var value: [base.len]f64 = undefined;
    for (base, 0..) |nominal, i| {
        const is_resistor = i == 1 or i == 2 or i == 5;
        const limits = if (is_resistor) spec.design.synthesis.resistor_range else spec.design.synthesis.capacitor_range;
        const low_factor: f64 = if (i == 2) 0.25 else 0.125;
        const high_factor: f64 = if (i == 2) 4 else 8;
        const low = @max(limits.min, nominal * low_factor);
        const high = @min(limits.max, nominal * high_factor);
        const fraction = halton(index, synthesis_primes[i]);
        value[i] = nearestE24InRange(std.math.pow(f64, 10, @log10(low) + (@log10(high) - @log10(low)) * fraction), .{ .min = low, .max = high });
    }
    return .{ .c_cp = value[0], .r_in = value[1], .r_feedback = value[2], .c_feedback = value[3], .c_feedback_hf = value[4], .r_isolation = value[5], .c_tune = value[6] + circuit.extra_tune_cap.nominal };
}

fn synthesisNeighbor(spec: Spec, circuit: Circuit, corner: Corner, component_index: usize, ratio: f64) Corner {
    var values = [_]f64{ corner.c_cp, corner.r_in, corner.r_feedback, corner.c_feedback, corner.c_feedback_hf, corner.r_isolation, corner.c_tune - circuit.extra_tune_cap.nominal };
    const original = [_]f64{ circuit.c_cp.nominal, circuit.r_in.nominal, circuit.r_feedback.nominal, circuit.c_feedback.nominal, circuit.c_feedback_hf.nominal, circuit.r_isolation.nominal, circuit.c_tune.nominal };
    const is_resistor = component_index == 1 or component_index == 2 or component_index == 5;
    const limits = if (is_resistor) spec.design.synthesis.resistor_range else spec.design.synthesis.capacitor_range;
    const low_factor: f64 = if (component_index == 2) 0.25 else 0.125;
    const high_factor: f64 = if (component_index == 2) 4 else 8;
    const low = @max(limits.min, original[component_index] * low_factor);
    const high = @min(limits.max, original[component_index] * high_factor);
    values[component_index] = nearestE24InRange(values[component_index] * ratio, .{ .min = low, .max = high });
    return .{ .c_cp = values[0], .r_in = values[1], .r_feedback = values[2], .c_feedback = values[3], .c_feedback_hf = values[4], .r_isolation = values[5], .c_tune = values[6] + circuit.extra_tune_cap.nominal };
}

fn halton(input_index: usize, base: usize) f64 {
    var index = input_index;
    var factor: f64 = 1;
    var result: f64 = 0;
    while (index > 0) : (index /= base) {
        factor /= @floatFromInt(base);
        result += factor * @as(f64, @floatFromInt(index % base));
    }
    return result;
}

/// The nearest E24 grid point, computed with the same `mantissa * scale`
/// arithmetic the search's candidates use — so a value that came off that grid
/// and went through decimal text re-parses to the bit-identical f64. A value
/// more than ~0.1% off every grid point (a hand-authored non-E24 pin) is kept
/// verbatim rather than silently moved onto the grid.
fn snapE24(value: f64) f64 {
    var best = value;
    var best_error = std.math.inf(f64);
    const decade = @floor(@log10(value));
    for ([_]f64{ decade - 1, decade, decade + 1 }) |exponent| {
        const scale = std.math.pow(f64, 10, exponent);
        for (e24) |mantissa| {
            const candidate = mantissa * scale;
            const err = @abs(@log(candidate / value));
            if (err < best_error) {
                best = candidate;
                best_error = err;
            }
        }
    }
    return if (best_error <= 1e-3) best else value;
}

fn nearestE24InRange(value: f64, limits: Range) f64 {
    var best = std.math.clamp(value, limits.min, limits.max);
    var best_error = std.math.inf(f64);
    const decade = @floor(@log10(value));
    for ([_]f64{ decade - 1, decade, decade + 1 }) |exponent| {
        const scale = std.math.pow(f64, 10, exponent);
        for (e24) |mantissa| {
            const candidate = mantissa * scale;
            if (candidate < limits.min or candidate > limits.max) continue;
            const err = @abs(@log(candidate / value));
            if (err < best_error) {
                best = candidate;
                best_error = err;
            }
        }
    }
    if (std.math.isFinite(best_error)) return best;
    for (0..49) |index| {
        const exponent = @as(f64, @floatFromInt(index)) - 24;
        const scale = std.math.pow(f64, 10, exponent);
        for (e24) |mantissa| {
            const candidate = mantissa * scale;
            if (candidate < limits.min or candidate > limits.max) continue;
            const err = @abs(@log(candidate / value));
            if (err < best_error) {
                best = candidate;
                best_error = err;
            }
        }
    }
    return best;
}

fn synthesisScore(spec: Spec, circuit: Circuit, corner: Corner, anchor_step: usize) f64 {
    var score: f64 = 0;
    const count = profileSampleCount(spec);
    for (0..count) |index| {
        const point = profileSample(spec, index) orelse return std.math.inf(f64);
        var point_spec = spec;
        point_spec.circuit.feedback.pll_n = point.pll_n;
        const current = scheduledCurrent(spec, point, anchor_step);
        const metrics = analyzeSearch(point_spec, corner, current, point.kvco_hz_per_v) orelse return std.math.inf(f64);
        score += metricPenalty(spec, metrics);
    }
    const candidate_values = [_]f64{ corner.c_cp, corner.r_in, corner.r_feedback, corner.c_feedback, corner.c_feedback_hf, corner.r_isolation, corner.c_tune - circuit.extra_tune_cap.nominal };
    const original_values = [_]f64{ circuit.c_cp.nominal, circuit.r_in.nominal, circuit.r_feedback.nominal, circuit.c_feedback.nominal, circuit.c_feedback_hf.nominal, circuit.r_isolation.nominal, circuit.c_tune.nominal };
    for (candidate_values, original_values) |candidate, original| score += 0.05 * std.math.pow(f64, @log10(candidate / original), 2);
    if (corner.c_cp < 2e-12) score += 10 * std.math.pow(f64, 2e-12 / corner.c_cp - 1, 2);
    if (corner.c_feedback_hf < 1e-12) score += 10 * std.math.pow(f64, 1e-12 / corner.c_feedback_hf - 1, 2);
    return score;
}

fn metricPenalty(spec: Spec, metrics: Metrics) f64 {
    const phase = spec.requirements.phase;
    const phase_low = phase.target_deg.min + 2;
    const phase_high = phase.target_deg.max - 2;
    const phase_mid = (phase.target_deg.min + phase.target_deg.max) / 2;
    const bandwidth_low = synthesisBandwidthMin(spec) * 1.05;
    const bandwidth_high = synthesisBandwidthMax(spec) * 0.9;
    var score = std.math.pow(f64, (metrics.phase_margin_deg - phase_mid) / 3, 2);
    if (metrics.phase_margin_deg < phase_low) score += 100 * std.math.pow(f64, (phase_low - metrics.phase_margin_deg) / 2, 4);
    if (metrics.phase_margin_deg > phase_high) score += 30 * std.math.pow(f64, (metrics.phase_margin_deg - phase_high) / 2, 4);
    if (bandwidth_low > 0 and metrics.crossover_hz < bandwidth_low) score += 100 * std.math.pow(f64, (bandwidth_low - metrics.crossover_hz) / 200e3, 4);
    if (metrics.crossover_hz > bandwidth_high) score += 100 * std.math.pow(f64, (metrics.crossover_hz - bandwidth_high) / 500e3, 4);
    return score;
}

fn synthesisBandwidthMin(spec: Spec) f64 {
    const ramp = spec.requirements.ramp;
    if (ramp.span_hz <= 0 or ramp.time_s <= 0 or ramp.max_phase_error_rad <= 0) return 0;
    const slope = ramp.span_hz / ramp.time_s;
    return 1.4 * @sqrt(slope / (2.0 * std.math.pi * ramp.max_phase_error_rad));
}

fn synthesisBandwidthMax(spec: Spec) f64 {
    return @min(spec.circuit.pfd_hz / 10.0, spec.circuit.op_amp.gbw_hz / 10.0);
}

fn profileSampleCount(spec: Spec) usize {
    return (spec.design.operating_curve.point_nodes.len - 1) * 4 + 1;
}

fn profileSample(spec: Spec, sample_index: usize) ?OperatingPoint {
    const last_index = profileSampleCount(spec) - 1;
    if (sample_index > last_index) return null;
    if (sample_index == last_index) return parseOperatingPoint(spec.design.operating_curve.point_nodes[spec.design.operating_curve.point_nodes.len - 1]) catch null;
    const segment = sample_index / 4;
    const fraction = @as(f64, @floatFromInt(sample_index % 4)) / 4.0;
    const a = parseOperatingPoint(spec.design.operating_curve.point_nodes[segment]) catch return null;
    const b = parseOperatingPoint(spec.design.operating_curve.point_nodes[segment + 1]) catch return null;
    return .{ .pll_n = a.pll_n + (b.pll_n - a.pll_n) * fraction, .kvco_hz_per_v = a.kvco_hz_per_v + (b.kvco_hz_per_v - a.kvco_hz_per_v) * fraction };
}

fn scheduledCurrent(spec: Spec, point: OperatingPoint, anchor_step: usize) f64 {
    const first = parseOperatingPoint(spec.design.operating_curve.point_nodes[0]) catch return spec.circuit.charge_pump.value;
    const step_a = 5e-3 / 16.0;
    const target_gain = @as(f64, @floatFromInt(anchor_step)) * step_a * first.kvco_hz_per_v / first.pll_n;
    const ideal_step = target_gain * point.pll_n / point.kvco_hz_per_v / step_a;
    return @as(f64, @floatFromInt(@max(1, @min(16, @as(usize, @intFromFloat(@round(ideal_step))))))) * step_a;
}

fn profileSweep(spec: Spec, corner: Corner, anchor_step: usize, tolerance_edges: bool) Sweep {
    var sweep = Sweep{};
    for (0..profileSampleCount(spec)) |index| {
        const point = profileSample(spec, index) orelse continue;
        var point_spec = spec;
        point_spec.circuit.feedback.pll_n = point.pll_n;
        const current = scheduledCurrent(spec, point, anchor_step);
        const tolerance = spec.circuit.charge_pump.tolerance_pct / 100.0;
        const scales = if (tolerance_edges) [_]f64{ 1.0 - tolerance, 1.0 + tolerance } else [_]f64{ 1, 1 };
        for (scales) |scale| if (analyze(point_spec, corner, current * scale, point.kvco_hz_per_v)) |metrics| sweep.add(metrics);
    }
    return sweep;
}

fn fixedProfileSweep(spec: Spec, corner: Corner, tolerance_edges: bool) Sweep {
    var sweep = Sweep{};
    for (0..profileSampleCount(spec)) |index| {
        const point = profileSample(spec, index) orelse continue;
        var point_spec = spec;
        point_spec.circuit.feedback.pll_n = point.pll_n;
        const scales = if (tolerance_edges) [_]f64{ 1.0 - spec.circuit.charge_pump.tolerance_pct / 100.0, 1.0 + spec.circuit.charge_pump.tolerance_pct / 100.0 } else [_]f64{ 1, 1 };
        for (scales) |scale| if (analyze(point_spec, corner, spec.circuit.charge_pump.value * scale, point.kvco_hz_per_v)) |metrics| sweep.add(metrics);
    }
    return sweep;
}

fn fixedProfileToleranceSweep(spec: Spec, circuit: Circuit) Sweep {
    const original = [_]Value{ circuit.c_cp, circuit.r_in, circuit.r_feedback, circuit.c_feedback, circuit.c_feedback_hf, circuit.r_isolation, circuit.c_tune, circuit.extra_tune_cap };
    const nominal = [_]f64{ circuit.c_cp.nominal, circuit.r_in.nominal, circuit.r_feedback.nominal, circuit.c_feedback.nominal, circuit.c_feedback_hf.nominal, circuit.r_isolation.nominal, circuit.c_tune.nominal, circuit.extra_tune_cap.nominal };
    var sweep = Sweep{};
    for (0..(@as(usize, 1) << original.len)) |mask| {
        var value: [original.len]f64 = undefined;
        for (original, nominal, 0..) |part, center, i| {
            const sign: f64 = if ((mask & (@as(usize, 1) << @intCast(i))) == 0) -1 else 1;
            value[i] = center * (1.0 + sign * part.tolerancePctAt(center) / 100.0);
        }
        const corner = Corner{ .c_cp = value[0], .r_in = value[1], .r_feedback = value[2], .c_feedback = value[3], .c_feedback_hf = value[4], .r_isolation = value[5], .c_tune = value[6] + value[7] };
        const one = fixedProfileSweep(spec, corner, true);
        if (one.solved > 0) mergeSweep(&sweep, one);
    }
    return sweep;
}

fn synthesisToleranceSweep(spec: Spec, circuit: Circuit, candidate: Corner, anchor_step: usize) Sweep {
    const original = [_]Value{ circuit.c_cp, circuit.r_in, circuit.r_feedback, circuit.c_feedback, circuit.c_feedback_hf, circuit.r_isolation, circuit.c_tune, circuit.extra_tune_cap };
    const nominal = [_]f64{ candidate.c_cp, candidate.r_in, candidate.r_feedback, candidate.c_feedback, candidate.c_feedback_hf, candidate.r_isolation, candidate.c_tune - circuit.extra_tune_cap.nominal, circuit.extra_tune_cap.nominal };
    var sweep = Sweep{};
    for (0..(@as(usize, 1) << original.len)) |mask| {
        var value: [original.len]f64 = undefined;
        for (original, nominal, 0..) |part, center, i| {
            const sign: f64 = if ((mask & (@as(usize, 1) << @intCast(i))) == 0) -1 else 1;
            value[i] = center * (1.0 + sign * part.tolerancePctAt(center) / 100.0);
        }
        const corner = Corner{ .c_cp = value[0], .r_in = value[1], .r_feedback = value[2], .c_feedback = value[3], .c_feedback_hf = value[4], .r_isolation = value[5], .c_tune = value[6] + value[7] };
        const one = profileSweep(spec, corner, anchor_step, true);
        if (one.solved > 0) mergeSweep(&sweep, one);
    }
    return sweep;
}

fn mergeSweep(target: *Sweep, source: Sweep) void {
    target.min_bandwidth_hz = @min(target.min_bandwidth_hz, source.min_bandwidth_hz);
    target.max_bandwidth_hz = @max(target.max_bandwidth_hz, source.max_bandwidth_hz);
    target.min_phase_margin_deg = @min(target.min_phase_margin_deg, source.min_phase_margin_deg);
    target.max_phase_margin_deg = @max(target.max_phase_margin_deg, source.max_phase_margin_deg);
    target.solved += source.solved;
}

fn appendSynthesisResult(context: *Context, spec: Spec, circuit: Circuit, result: SynthResult) std.mem.Allocator.Error!void {
    const c = result.corner;
    try append(context, spec, true, "{s}: E24 synthesis replaces C_CP {d:.1}→{d:.1} pF, R_IN {d:.0}→{d:.0} Ω, R_FB {d:.0}→{d:.0} Ω, C_FB {d:.1}→{d:.1} pF, C_FB_HF {d:.1}→{d:.1} pF, R_ISO {d:.0}→{d:.0} Ω, and C_VTUNE {d:.1}→{d:.1} pF", .{ spec.name, circuit.c_cp.nominal * 1e12, c.c_cp * 1e12, circuit.r_in.nominal, c.r_in, circuit.r_feedback.nominal, c.r_feedback, circuit.c_feedback.nominal * 1e12, c.c_feedback * 1e12, circuit.c_feedback_hf.nominal * 1e12, c.c_feedback_hf * 1e12, circuit.r_isolation.nominal, c.r_isolation, circuit.c_tune.nominal * 1e12, (c.c_tune - circuit.extra_tune_cap.nominal) * 1e12 });
    const synthesis_passes = result.tolerance.min_phase_margin_deg >= spec.requirements.phase.target_deg.min and
        result.tolerance.max_phase_margin_deg <= spec.requirements.phase.target_deg.max and
        result.tolerance.max_bandwidth_hz <= synthesisBandwidthMax(spec);
    try append(context, spec, synthesis_passes, "{s}: synthesized profile gives nominal LBW {d:.3}-{d:.3} MHz / PM {d:.1}-{d:.1}° and tolerance-corner LBW {d:.3}-{d:.3} MHz / PM {d:.1}-{d:.1}°", .{ spec.name, result.nominal.min_bandwidth_hz / 1e6, result.nominal.max_bandwidth_hz / 1e6, result.nominal.min_phase_margin_deg, result.nominal.max_phase_margin_deg, result.tolerance.min_bandwidth_hz / 1e6, result.tolerance.max_bandwidth_hz / 1e6, result.tolerance.min_phase_margin_deg, result.tolerance.max_phase_margin_deg });
    const phase_error = rampPhaseError(spec, result.tolerance.min_bandwidth_hz);
    if (phase_error > 0) try append(context, spec, phase_error <= spec.requirements.ramp.max_phase_error_rad, "{s}: synthesized worst-corner FMCW ramp phase error is {d:.3} rad (limit {d:.3} rad)", .{ spec.name, phase_error, spec.requirements.ramp.max_phase_error_rad });
    try appendSchedule(context, spec, result.anchor_step);
}

fn appendSchedule(context: *Context, spec: Spec, anchor_step: usize) std.mem.Allocator.Error!void {
    const first = parseOperatingPoint(spec.design.operating_curve.point_nodes[0]) catch return;
    const middle = parseOperatingPoint(spec.design.operating_curve.point_nodes[spec.design.operating_curve.point_nodes.len / 2]) catch return;
    const last = parseOperatingPoint(spec.design.operating_curve.point_nodes[spec.design.operating_curve.point_nodes.len - 1]) catch return;
    try append(context, spec, true, "{s}: ADF4159 I_CP schedule — N={d:.2}/Kvco={d:.0} MHz/V: step {d} ({d:.4} mA); N={d:.2}/{d:.0}: step {d} ({d:.4} mA); N={d:.2}/{d:.0}: step {d} ({d:.4} mA)", .{ spec.name, first.pll_n, first.kvco_hz_per_v / 1e6, currentStep(spec, first, anchor_step), scheduledCurrent(spec, first, anchor_step) * 1e3, middle.pll_n, middle.kvco_hz_per_v / 1e6, currentStep(spec, middle, anchor_step), scheduledCurrent(spec, middle, anchor_step) * 1e3, last.pll_n, last.kvco_hz_per_v / 1e6, currentStep(spec, last, anchor_step), scheduledCurrent(spec, last, anchor_step) * 1e3 });
}

fn currentStep(spec: Spec, point: OperatingPoint, anchor_step: usize) usize {
    return @intFromFloat(@round(scheduledCurrent(spec, point, anchor_step) / (5e-3 / 16.0)));
}

fn rampPhaseError(spec: Spec, bandwidth_hz: f64) f64 {
    if (spec.requirements.ramp.span_hz <= 0 or spec.requirements.ramp.time_s <= 0) return 0;
    const natural_hz = bandwidth_hz / 1.4;
    return (spec.requirements.ramp.span_hz / spec.requirements.ramp.time_s) / (2.0 * std.math.pi * natural_hz * natural_hz);
}

fn resolveCircuit(block: *const DesignBlock, spec: Spec) ?Circuit {
    return .{
        .c_cp = capacitor(block, spec.components.c_cp) orelse return null,
        .r_in = resistor(block, spec.components.r_in) orelse return null,
        .r_feedback = resistor(block, spec.components.r_feedback) orelse return null,
        .c_feedback = capacitor(block, spec.components.c_feedback) orelse return null,
        .c_feedback_hf = capacitor(block, spec.components.c_feedback_hf) orelse return null,
        .r_isolation = resistor(block, spec.components.r_isolation) orelse return null,
        .c_tune = capacitor(block, spec.components.c_tune) orelse return null,
        .extra_tune_cap = .{ .nominal = spec.circuit.extra_tune_cap.value, .tolerance_pct = spec.circuit.extra_tune_cap.tolerance_pct, .ref = "extra" },
    };
}

fn resistor(block: *const DesignBlock, name: []const u8) ?Value {
    const inst = findInstance(block, name) orelse return null;
    const nominal = passive.parseOhms(inst.value) orelse return null;
    const tolerance = toleranceFor(inst, nominal, false);
    return .{ .nominal = nominal, .tolerance_pct = tolerance.percent, .tolerance_abs = tolerance.absolute, .ref = displayRef(inst) };
}

fn capacitor(block: *const DesignBlock, name: []const u8) ?Value {
    const inst = findInstance(block, name) orelse return null;
    const nominal = decouple_key.capFarads(inst.value);
    if (nominal <= 0) return null;
    const tolerance = toleranceFor(inst, nominal, true);
    return .{ .nominal = nominal, .tolerance_pct = tolerance.percent, .tolerance_abs = tolerance.absolute, .ref = displayRef(inst) };
}

fn findInstance(block: *const DesignBlock, name: []const u8) ?Instance {
    for (block.instances) |inst| if (eq(inst.label, name) or eq(inst.ref_des, name)) return inst;
    return null;
}

fn displayRef(inst: Instance) []const u8 {
    return if (inst.ref_des.len > 0) inst.ref_des else inst.label;
}

const ParsedTolerance = struct { percent: f64 = 0, absolute: f64 = 0 };

fn toleranceFor(inst: Instance, nominal: f64, is_cap: bool) ParsedTolerance {
    var raw: []const u8 = "";
    for (inst.properties) |property| if (eq(property.key, "tolerance")) {
        raw = property.value;
        break;
    };
    if (raw.len == 0) for (inst.attrs) |attr| if (std.mem.endsWith(u8, attr, "%") or
        (is_cap and (std.mem.endsWith(u8, attr, "F") or std.mem.endsWith(u8, attr, "f"))))
    {
        raw = attr;
        break;
    };
    if (raw.len == 0) return .{};
    if (std.mem.endsWith(u8, raw, "%")) return .{ .percent = std.fmt.parseFloat(f64, raw[0 .. raw.len - 1]) catch 0 };
    if (is_cap) {
        const absolute = decouple_key.capFarads(raw);
        if (absolute > 0 and nominal > 0) return .{ .percent = absolute / nominal * 100.0, .absolute = absolute };
    }
    return .{};
}

fn loopCapsAreStable(block: *const DesignBlock, c: Components) bool {
    for ([_][]const u8{ c.c_cp, c.c_feedback, c.c_feedback_hf, c.c_tune }) |name| {
        const inst = findInstance(block, name) orelse return false;
        var stable = false;
        for (inst.attrs) |attr| {
            if (eq(attr, "np0") or eq(attr, "c0g")) stable = true;
        }
        for (inst.properties) |property| if (eq(property.key, "dielectric") and
            (eq(property.value, "np0") or eq(property.value, "c0g")))
        {
            stable = true;
        };
        if (!stable) return false;
    }
    return true;
}

fn nominalCorner(c: Circuit) Corner {
    return .{ .c_cp = c.c_cp.nominal, .r_in = c.r_in.nominal, .r_feedback = c.r_feedback.nominal, .c_feedback = c.c_feedback.nominal, .c_feedback_hf = c.c_feedback_hf.nominal, .r_isolation = c.r_isolation.nominal, .c_tune = c.c_tune.nominal + c.extra_tune_cap.nominal };
}

fn toleranceSweep(spec: Spec, c: Circuit) Sweep {
    const values = [_]Value{ c.c_cp, c.r_in, c.r_feedback, c.c_feedback, c.c_feedback_hf, c.r_isolation, c.c_tune, c.extra_tune_cap };
    var sweep = Sweep{};
    for (0..(@as(usize, 1) << values.len)) |mask| {
        var corner_values: [values.len]f64 = undefined;
        for (values, 0..) |value, i| {
            const sign: f64 = if ((mask & (@as(usize, 1) << @intCast(i))) == 0) -1 else 1;
            corner_values[i] = value.nominal * (1.0 + sign * value.tolerancePctAt(value.nominal) / 100.0);
        }
        const corner = Corner{ .c_cp = corner_values[0], .r_in = corner_values[1], .r_feedback = corner_values[2], .c_feedback = corner_values[3], .c_feedback_hf = corner_values[4], .r_isolation = corner_values[5], .c_tune = corner_values[6] + corner_values[7] };
        for ([_]f64{ spec.circuit.kvco_hz_per_v.min, spec.circuit.kvco_hz_per_v.max }) |kvco| {
            for ([_]f64{ 1.0 - spec.circuit.charge_pump.tolerance_pct / 100.0, 1.0 + spec.circuit.charge_pump.tolerance_pct / 100.0 }) |icp_scale|
                if (analyze(spec, corner, spec.circuit.charge_pump.value * icp_scale, kvco)) |m| sweep.add(m);
        }
    }
    return sweep;
}

const Complex = struct {
    re: f64 = 0,
    im: f64 = 0,
    fn add(a: Complex, b: Complex) Complex {
        return .{ .re = a.re + b.re, .im = a.im + b.im };
    }
    fn sub(a: Complex, b: Complex) Complex {
        return .{ .re = a.re - b.re, .im = a.im - b.im };
    }
    fn mul(a: Complex, b: Complex) Complex {
        return .{ .re = a.re * b.re - a.im * b.im, .im = a.re * b.im + a.im * b.re };
    }
    fn scale(a: Complex, v: f64) Complex {
        return .{ .re = a.re * v, .im = a.im * v };
    }
    fn div(a: Complex, b: Complex) Complex {
        const d = b.re * b.re + b.im * b.im;
        return .{ .re = (a.re * b.re + a.im * b.im) / d, .im = (a.im * b.re - a.re * b.im) / d };
    }
    fn abs(a: Complex) f64 {
        return @sqrt(a.re * a.re + a.im * a.im);
    }
};

fn analyze(spec: Spec, c: Corner, icp_a: f64, kvco_hz_per_v: f64) ?Metrics {
    const f_min: f64 = 100;
    const f_max = @max(spec.circuit.pfd_hz, spec.circuit.op_amp.gbw_hz * 2.0);
    const log_min = @log10(f_min);
    const log_span = @log10(f_max) - log_min;
    var previous_f = f_min;
    var previous_db = gainDb(spec, c, icp_a, kvco_hz_per_v, previous_f);
    for (1..321) |i| {
        const fraction = @as(f64, @floatFromInt(i)) / 320.0;
        const f = std.math.pow(f64, 10.0, log_min + log_span * fraction);
        const db = gainDb(spec, c, icp_a, kvco_hz_per_v, f);
        if (previous_db >= 0 and db <= 0) {
            var lo = previous_f;
            var hi = f;
            for (0..64) |_| {
                const mid = @sqrt(lo * hi);
                if (gainDb(spec, c, icp_a, kvco_hz_per_v, mid) >= 0) lo = mid else hi = mid;
            }
            const fc = @sqrt(lo * hi);
            const loop = openLoop(spec, c, icp_a, kvco_hz_per_v, fc);
            var phase = std.math.atan2(loop.im, loop.re) * 180.0 / std.math.pi;
            if (phase > 0) phase -= 360;
            return .{ .crossover_hz = fc, .phase_margin_deg = 180.0 + phase };
        }
        previous_f = f;
        previous_db = db;
    }
    return null;
}

fn analyzeSearch(spec: Spec, c: Corner, icp_a: f64, kvco_hz_per_v: f64) ?Metrics {
    const f_min: f64 = 100;
    const f_max = @max(spec.circuit.pfd_hz, spec.circuit.op_amp.gbw_hz * 2.0);
    const log_min = @log10(f_min);
    const log_span = @log10(f_max) - log_min;
    var previous_f = f_min;
    var previous_db = gainDb(spec, c, icp_a, kvco_hz_per_v, previous_f);
    for (1..82) |i| {
        const fraction = @as(f64, @floatFromInt(i)) / 81.0;
        const f = std.math.pow(f64, 10.0, log_min + log_span * fraction);
        const db = gainDb(spec, c, icp_a, kvco_hz_per_v, f);
        if (previous_db >= 0 and db <= 0) {
            var lo = previous_f;
            var hi = f;
            for (0..24) |_| {
                const mid = @sqrt(lo * hi);
                if (gainDb(spec, c, icp_a, kvco_hz_per_v, mid) >= 0) lo = mid else hi = mid;
            }
            const fc = @sqrt(lo * hi);
            const loop = openLoop(spec, c, icp_a, kvco_hz_per_v, fc);
            var phase = std.math.atan2(loop.im, loop.re) * 180.0 / std.math.pi;
            if (phase > 0) phase -= 360;
            return .{ .crossover_hz = fc, .phase_margin_deg = 180.0 + phase };
        }
        previous_f = f;
        previous_db = db;
    }
    return null;
}

fn gainDb(spec: Spec, c: Corner, icp: f64, kvco: f64, f: f64) f64 {
    return 20.0 * @log10(@max(1e-300, openLoop(spec, c, icp, kvco, f).abs()));
}

fn openLoop(spec: Spec, c: Corner, icp: f64, kvco: f64, f: f64) Complex {
    const s = Complex{ .im = 2.0 * std.math.pi * f };
    const z = transimpedance(spec, c, s);
    const polarity: f64 = if (spec.circuit.polarity == .negative) -1 else 1;
    // (Icp/2π)*(2π Kvco)*Z/(N_eff*s): the two 2π factors cancel.
    return z.scale(polarity * icp * kvco / (spec.circuit.feedback.prescaler * spec.circuit.feedback.pll_n)).div(s);
}

fn transimpedance(spec: Spec, c: Corner, s: Complex) Complex {
    const one = Complex{ .re = 1 };
    const yi = Complex{ .re = 1.0 / c.r_in };
    const yc = s.scale(c.c_cp);
    const series_feedback = (Complex{ .re = c.r_feedback }).add(one.div(s.scale(c.c_feedback)));
    const yf = one.div(series_feedback).add(s.scale(c.c_feedback_hf));
    const op_amp_pole_rad_s = 2.0 * std.math.pi * spec.circuit.op_amp.gbw_hz / spec.circuit.op_amp.dc_gain;
    const a = (Complex{ .re = spec.circuit.op_amp.dc_gain }).div(one.add(s.scale(1.0 / op_amp_pole_rad_s)));
    // KCL at the inverting input plus Vout=-A*Vinv.  This closed expression is
    // equivalent to solving the CP/inverting/output nodal matrix.
    const vinv_per_cp = yi.div(yi.add(one.add(a).mul(yf)));
    const out_per_cp = a.mul(vinv_per_cp).scale(-1);
    const current_per_cp = yc.add(one.sub(vinv_per_cp).mul(yi));
    const out_per_current = out_per_cp.div(current_per_cp);
    return out_per_current.div(one.add(s.scale(c.r_isolation * c.c_tune)));
}

fn append(context: *Context, spec: Spec, passed: bool, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
    const message = try std.fmt.allocPrint(context.allocator, fmt, args);
    errdefer context.allocator.free(message);
    try context.assertions.append(context.allocator, .{
        .passed = passed,
        .message = message,
        .is_warning = !passed and spec.mode == .advisory,
        .message_owned = true,
    });
}

fn warning(context: *Context, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
    const message = try std.fmt.allocPrint(context.allocator, fmt, args);
    errdefer context.allocator.free(message);
    try context.assertions.append(context.allocator, .{
        .passed = false,
        .message = message,
        .is_warning = true,
        .message_owned = true,
    });
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

// spec: pll-loop - AN-2548 active filter model retains the expected crossover and phase trend across Kvco
test "active inverting filter sweep responds to Kvco" {
    const spec = Spec{ .name = "test", .topology_active_inverting = true, .circuit = .{
        .pfd_hz = 100e6,
        .charge_pump = .{ .value = 2.5e-3 },
        .feedback = .{ .prescaler = 4, .pll_n = 29.25 },
        .kvco_hz_per_v = .{ .min = 200e6, .max = 800e6 },
        .op_amp = .{ .gbw_hz = 145e6, .dc_gain = 500_000 },
        .polarity = .negative,
    } };
    const c = Corner{ .c_cp = 12e-12, .r_in = 220, .r_feedback = 3000, .c_feedback = 82e-12, .c_feedback_hf = 2.7e-12, .r_isolation = 120, .c_tune = 200e-12 };
    const low = analyze(spec, c, spec.circuit.charge_pump.value, spec.circuit.kvco_hz_per_v.min).?;
    const high = analyze(spec, c, spec.circuit.charge_pump.value, spec.circuit.kvco_hz_per_v.max).?;
    try std.testing.expectApproxEqAbs(@as(f64, 1.99e6), low.crossover_hz, 20e3);
    try std.testing.expectApproxEqAbs(@as(f64, 46.9), low.phase_margin_deg, 0.3);
    try std.testing.expectApproxEqAbs(@as(f64, 5.92e6), high.crossover_hz, 30e3);
    try std.testing.expect(high.phase_margin_deg < 20);
}

// spec: pll-loop - phase detector polarity changes the feedback sign by 180 degrees
test "active inverting filter requires negative polarity" {
    var spec = Spec{ .name = "test", .topology_active_inverting = true, .circuit = .{
        .pfd_hz = 100e6,
        .charge_pump = .{ .value = 2.5e-3 },
        .feedback = .{ .prescaler = 4, .pll_n = 29.25 },
        .kvco_hz_per_v = .{ .min = 200e6, .max = 800e6 },
        .op_amp = .{ .gbw_hz = 145e6 },
        .polarity = .negative,
    } };
    const c = Corner{ .c_cp = 12e-12, .r_in = 220, .r_feedback = 3000, .c_feedback = 82e-12, .c_feedback_hf = 2.7e-12, .r_isolation = 120, .c_tune = 200e-12 };
    const stable = analyze(spec, c, spec.circuit.charge_pump.value, 200e6).?;
    spec.circuit.polarity = .positive;
    const wrong = analyze(spec, c, spec.circuit.charge_pump.value, 200e6).?;
    try std.testing.expect(stable.phase_margin_deg > 40);
    try std.testing.expect(wrong.phase_margin_deg < -100);
}

/// The declaration + resolved values the memo tests key on. Deliberately not
/// any real design's numbers: the memo is process-wide, so a fixture that
/// collided with an authored `(pll-loop …)` would seed that design's answer.
const memo_point_a = [_]Node{ Node.atom(ast.Span.zero, "point"), Node.float(ast.Span.zero, 26), Node.float(ast.Span.zero, 410e6) };
const memo_point_b = [_]Node{ Node.atom(ast.Span.zero, "point"), Node.float(ast.Span.zero, 31), Node.float(ast.Span.zero, 690e6) };
const memo_point_b_moved = [_]Node{ Node.atom(ast.Span.zero, "point"), Node.float(ast.Span.zero, 31), Node.float(ast.Span.zero, 700e6) };

fn memoFixture() struct { spec: Spec, circuit: Circuit, points: [2]Node } {
    return .{
        .points = .{ Node.list(ast.Span.zero, &memo_point_a), Node.list(ast.Span.zero, &memo_point_b) },
        .spec = .{
            .name = "pll-loop memo fixture",
            .topology_active_inverting = true,
            .circuit = .{
                .pfd_hz = 100e6,
                .charge_pump = .{ .value = 2.5e-3, .tolerance_pct = 2.5 },
                .feedback = .{ .prescaler = 4, .pll_n = 26 },
                .kvco_hz_per_v = .{ .min = 410e6, .max = 690e6 },
                .op_amp = .{ .gbw_hz = 145e6, .dc_gain = 500_000 },
                .polarity = .negative,
            },
            .requirements = .{
                .phase = .{ .target_deg = .{ .min = 45, .max = 55 }, .hard_min_deg = 40 },
                .ramp = .{ .span_hz = 1.5e9, .time_s = 35e-6, .max_phase_error_rad = 1 },
            },
            .design = .{ .synthesis = .{ .enabled = true } },
        },
        .circuit = .{
            .c_cp = .{ .nominal = 12e-12, .tolerance_pct = 2, .ref = "C_CP" },
            .r_in = .{ .nominal = 220, .tolerance_pct = 1, .ref = "R_IN" },
            .r_feedback = .{ .nominal = 3000, .tolerance_pct = 1, .ref = "R_FB" },
            .c_feedback = .{ .nominal = 82e-12, .tolerance_pct = 2, .ref = "C_FB" },
            .c_feedback_hf = .{ .nominal = 2.7e-12, .tolerance_pct = 3.7, .ref = "C_FB_HF" },
            .r_isolation = .{ .nominal = 120, .tolerance_pct = 1, .ref = "R_ISO" },
            .c_tune = .{ .nominal = 180e-12, .tolerance_pct = 5, .ref = "C_VTUNE" },
            .extra_tune_cap = .{ .nominal = 20e-12, .tolerance_pct = 2, .ref = "extra" },
        },
    };
}

// spec: pll-loop - the synthesis search is memoised on its complete input, so a design evaluated again runs it no second time and a changed value never reads the old answer
test "the synthesis memo answers only the identical declaration and circuit" {
    var fixture = memoFixture();
    fixture.spec.design.operating_curve = .{ .point_nodes = &fixture.points };
    const key = synthKey(fixture.spec, fixture.circuit);
    try std.testing.expect(key.eql(synthKey(fixture.spec, fixture.circuit)));

    // The memo is consulted, not merely written: a seeded answer comes back
    // without the 6,000-candidate search ever running.
    const seeded = SynthResult{
        .corner = .{ .c_cp = 1, .r_in = 2, .r_feedback = 3, .c_feedback = 4, .c_feedback_hf = 5, .r_isolation = 6, .c_tune = 7 },
        .anchor_step = 9,
        .nominal = .{},
        .tolerance = .{},
    };
    synth_memo.put(key, seeded);
    const hit = memoisedSynthesis(fixture.spec, fixture.circuit);
    try std.testing.expectEqual(@as(usize, 9), hit.anchor_step);
    try std.testing.expectEqual(@as(f64, 3), hit.corner.r_feedback);

    // Every input the search reads re-keys: a component value, an operating
    // point, a synthesis range, and a scalar of the declaration itself.
    var other_circuit = fixture.circuit;
    other_circuit.r_feedback.nominal = 3300;
    try std.testing.expect(!key.eql(synthKey(fixture.spec, other_circuit)));

    // …and the ref-des does NOT: the same module renumbers between a standalone
    // evaluation and its instantiation inside a design, and the search's answer
    // does not depend on what the assertion text will call the part.
    var renumbered = fixture.circuit;
    renumbered.r_feedback.ref = "R47";
    renumbered.c_tune.ref = "C93";
    try std.testing.expect(key.eql(synthKey(fixture.spec, renumbered)));

    var moved = fixture.points;
    moved[1] = Node.list(ast.Span.zero, &memo_point_b_moved);
    var moved_spec = fixture.spec;
    moved_spec.design.operating_curve = .{ .point_nodes = &moved };
    try std.testing.expect(!key.eql(synthKey(moved_spec, fixture.circuit)));

    var narrowed = fixture.spec;
    narrowed.design.synthesis.resistor_range = .{ .min = 100, .max = 10_000 };
    try std.testing.expect(!key.eql(synthKey(narrowed, fixture.circuit)));

    var faster = fixture.spec;
    faster.circuit.pfd_hz = 120e6;
    try std.testing.expect(!key.eql(synthKey(faster, fixture.circuit)));
}

// spec: pll-loop - pinned values snap onto the E24 grid at parse, so the printed decimal text round-trips to the search's bit-identical f64s, and a non-E24 value is kept verbatim rather than moved
test "snapE24 reproduces the candidate grid's exact doubles" {
    // The same `mantissa * scale` arithmetic `nearestE24InRange` uses.
    try std.testing.expectEqual(2.2 * std.math.pow(f64, 10, -11), snapE24(22e-12));
    try std.testing.expectEqual(7.5 * std.math.pow(f64, 10, 1), snapE24(75));
    try std.testing.expectEqual(4.3 * std.math.pow(f64, 10, 3), snapE24(4300));
    try std.testing.expectEqual(1.8 * std.math.pow(f64, 10, -12), snapE24(1.8e-12));
    // A value the offer line printed with float dust still lands on the grid…
    try std.testing.expectEqual(3.0 * std.math.pow(f64, 10, 1), snapE24(30.000000000000004));
    // …while a deliberate off-grid value (>0.1% from every E24 point) is kept.
    try std.testing.expectEqual(@as(f64, 3.14e3), snapE24(3.14e3));
}

/// The pin tests' own fixture: the memo fixture with its second operating
/// point moved, so its key collides with nothing another test seeds into the
/// process-wide memo.
fn pinFixture() struct { spec: Spec, circuit: Circuit, points: [2]Node } {
    var fixture = memoFixture();
    fixture.spec.name = "pll-loop pin fixture";
    fixture.points[1] = Node.list(ast.Span.zero, &memo_point_b_moved);
    return .{ .spec = fixture.spec, .circuit = fixture.circuit, .points = fixture.points };
}

fn freeAssertions(allocator: std.mem.Allocator, list: *std.ArrayList(env.AssertionResult)) void {
    for (list.items) |assertion| allocator.free(assertion.message);
    list.deinit(allocator);
}

fn messagesContain(list: *const std.ArrayList(env.AssertionResult), needle: []const u8) bool {
    for (list.items) |assertion| {
        if (std.mem.indexOf(u8, assertion.message, needle) != null) return true;
    }
    return false;
}

// spec: pll-loop - a pin whose key matches answers from its own values without consulting the search or its memo, and prints no re-pin offer
test "a matching pin bypasses the search and the memo" {
    var fixture = pinFixture();
    fixture.spec.design.operating_curve = .{ .point_nodes = &fixture.points };
    const key = synthKey(fixture.spec, fixture.circuit);

    // Poison the memo under this key: if the pinned path consulted the memo
    // (or ran the search and wrote it), these impossible values would show.
    synth_memo.put(key, .{
        .corner = .{ .c_cp = 1, .r_in = 1, .r_feedback = 1, .c_feedback = 1, .c_feedback_hf = 1, .r_isolation = 1, .c_tune = 1 },
        .anchor_step = 1,
        .nominal = .{},
        .tolerance = .{},
    });

    fixture.spec.design.pinned = .{
        .key_lo = key.lo,
        .key_hi = key.hi,
        .values = .{ snapE24(22e-12), snapE24(75), snapE24(4300), snapE24(30e-12), snapE24(1.8e-12), snapE24(36), snapE24(75e-12) },
    };
    var assertions: std.ArrayList(env.AssertionResult) = .{};
    defer freeAssertions(std.testing.allocator, &assertions);
    var context = Context{ .allocator = std.testing.allocator, .assertions = &assertions };
    try synthesize(&context, fixture.spec, fixture.circuit);

    // The E24 line prints the PIN's r_feedback (4300 Ω), not the poison's 1 Ω.
    try std.testing.expect(messagesContain(&assertions, "R_FB 3000→4300"));
    try std.testing.expect(!messagesContain(&assertions, "pin this search"));
    try std.testing.expect(!messagesContain(&assertions, "stale"));
}

// spec: pll-loop - a pin whose key no longer matches is ignored with a warning and the full search runs, so a pin can only skip recomputation and never change an answer
test "a stale pin warns, searches, and offers a fresh pin line" {
    var fixture = pinFixture();
    fixture.spec.design.operating_curve = .{ .point_nodes = &fixture.points };
    const key = synthKey(fixture.spec, fixture.circuit);

    // Seed the memo so "the search ran" is observable as this seeded answer
    // (and the test never pays the real 6,000-candidate walk).
    synth_memo.put(key, .{
        .corner = .{ .c_cp = 1, .r_in = 1, .r_feedback = 1, .c_feedback = 1, .c_feedback_hf = 1, .r_isolation = 1, .c_tune = 1 },
        .anchor_step = 1,
        .nominal = .{},
        .tolerance = .{},
    });

    fixture.spec.design.pinned = .{ .key_lo = key.lo +% 1, .key_hi = key.hi, .values = @splat(1) };
    var assertions: std.ArrayList(env.AssertionResult) = .{};
    defer freeAssertions(std.testing.allocator, &assertions);
    var context = Context{ .allocator = std.testing.allocator, .assertions = &assertions };
    try synthesize(&context, fixture.spec, fixture.circuit);

    try std.testing.expect(messagesContain(&assertions, "pinned synthesis is stale"));
    // The memoised (seeded) search answered — its 1 Ω corner, not the pin's.
    try std.testing.expect(messagesContain(&assertions, "R_FB 3000→1"));
    try std.testing.expect(messagesContain(&assertions, "pin this search"));
}

// spec: pll-loop - E24 synthesis jointly satisfies an authored divider/Kvco curve, tolerance corners, and ramp limit
test "synthesize active loop filter over operating curve" {
    try std.testing.expectEqual(@as(f64, 2.4), nearestE24InRange(2.37, .{ .min = 2.2, .max = 2.4 }));
    const p1 = [_]Node{ Node.atom(ast.Span.zero, "point"), Node.float(ast.Span.zero, 25), Node.float(ast.Span.zero, 420e6) };
    const p2 = [_]Node{ Node.atom(ast.Span.zero, "point"), Node.float(ast.Span.zero, 29.25), Node.float(ast.Span.zero, 730e6) };
    const p3 = [_]Node{ Node.atom(ast.Span.zero, "point"), Node.float(ast.Span.zero, 50), Node.float(ast.Span.zero, 340e6) };
    const points = [_]Node{ Node.list(ast.Span.zero, &p1), Node.list(ast.Span.zero, &p2), Node.list(ast.Span.zero, &p3) };
    const spec = Spec{
        .name = "Barracuda",
        .topology_active_inverting = true,
        .circuit = .{
            .pfd_hz = 100e6,
            .charge_pump = .{ .value = 2.5e-3, .tolerance_pct = 2.5 },
            .feedback = .{ .prescaler = 4, .pll_n = 25 },
            .kvco_hz_per_v = .{ .min = 340e6, .max = 730e6 },
            .op_amp = .{ .gbw_hz = 145e6, .dc_gain = 500_000 },
            .polarity = .negative,
        },
        .requirements = .{
            .phase = .{ .target_deg = .{ .min = 45, .max = 55 }, .hard_min_deg = 40 },
            .ramp = .{ .span_hz = 1.5e9, .time_s = 35e-6, .max_phase_error_rad = 1 },
        },
        .design = .{ .operating_curve = .{ .point_nodes = &points }, .synthesis = .{ .enabled = true } },
    };
    const circuit = Circuit{
        .c_cp = .{ .nominal = 12e-12, .tolerance_pct = 2, .ref = "C_CP" },
        .r_in = .{ .nominal = 220, .tolerance_pct = 1, .ref = "R_IN" },
        .r_feedback = .{ .nominal = 3000, .tolerance_pct = 1, .ref = "R_FB" },
        .c_feedback = .{ .nominal = 82e-12, .tolerance_pct = 2, .ref = "C_FB" },
        .c_feedback_hf = .{ .nominal = 2.7e-12, .tolerance_pct = 3.7, .tolerance_abs = 0.1e-12, .ref = "C_FB_HF" },
        .r_isolation = .{ .nominal = 120, .tolerance_pct = 1, .ref = "R_ISO" },
        .c_tune = .{ .nominal = 180e-12, .tolerance_pct = 5, .ref = "C_VTUNE" },
        .extra_tune_cap = .{ .nominal = 20e-12, .tolerance_pct = 2, .ref = "extra" },
    };
    const result = findSynthesis(spec, circuit);
    try std.testing.expect(result.tolerance.min_phase_margin_deg >= 45);
    try std.testing.expect(result.tolerance.max_phase_margin_deg <= 55);
    try std.testing.expect(result.tolerance.max_bandwidth_hz <= synthesisBandwidthMax(spec));
    try std.testing.expect(rampPhaseError(spec, result.tolerance.min_bandwidth_hz) <= 1);
}
