//! Small-signal validation for charge-pump PLLs with an inverting active loop
//! filter.  A `(pll-loop …)` design form names the *actual* R/C instances, so
//! this analysis follows BOM value/tolerance edits instead of duplicating them
//! in a spreadsheet.  The frequency-domain model includes the charge-pump
//! shunt, the two feedback branches, the output isolation pole, VCO tune-pin
//! capacitance, and a one-pole finite-gain op amp.
//!
//! This is a linear, continuous-time screen.  It deliberately does not claim
//! sampled-PFD, nonlinear lock acquisition, phase-noise, charge-pump
//! compliance, or op-amp capacitive-load sign-off.

const std = @import("std");
const ast = @import("sexpr/ast.zig");
const env = @import("eval/env.zig");
const passive = @import("req_checks.zig");
const decouple_key = @import("decouple_key.zig");

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
    } else if (eq(head, "phase-margin")) {
        try parsePhaseMargin(c, &out.requirements.phase);
    } else if (eq(head, "polarity")) {
        const word = try atomAt(c, 1);
        out.circuit.polarity = if (eq(word, "negative")) .negative else if (eq(word, "positive")) .positive else return error.InvalidForm;
    } else if (!try parseLimits(c, head, out)) return error.InvalidForm;
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
    return out.circuit.op_amp.gbw_hz > 0;
}

fn complete(c: Components) bool {
    return c.c_cp.len > 0 and c.r_in.len > 0 and c.r_feedback.len > 0 and
        c.c_feedback.len > 0 and c.c_feedback_hf.len > 0 and
        c.r_isolation.len > 0 and c.c_tune.len > 0;
}

const Value = struct { nominal: f64, tolerance_pct: f64, ref: []const u8 };
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
    try append(&context, spec, true, "{s}: BOM values loaded — {s} {d:.0} pF ±{d:.2}%, {s} {d:.0} Ω ±{d:.2}%, {s} {d:.0} Ω ±{d:.2}% / {s} {d:.1} pF ±{d:.2}%, {s} {d:.1} pF ±{d:.2}%, {s} {d:.0} Ω ±{d:.2}% / {s} {d:.0} pF ±{d:.2}%", .{ spec.name, circuit.c_cp.ref, circuit.c_cp.nominal * 1e12, circuit.c_cp.tolerance_pct, circuit.r_in.ref, circuit.r_in.nominal, circuit.r_in.tolerance_pct, circuit.r_feedback.ref, circuit.r_feedback.nominal, circuit.r_feedback.tolerance_pct, circuit.c_feedback.ref, circuit.c_feedback.nominal * 1e12, circuit.c_feedback.tolerance_pct, circuit.c_feedback_hf.ref, circuit.c_feedback_hf.nominal * 1e12, circuit.c_feedback_hf.tolerance_pct, circuit.r_isolation.ref, circuit.r_isolation.nominal, circuit.r_isolation.tolerance_pct, circuit.c_tune.ref, (circuit.c_tune.nominal + circuit.extra_tune_cap.nominal) * 1e12, @max(circuit.c_tune.tolerance_pct, circuit.extra_tune_cap.tolerance_pct) });

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
    try outputChecks(&context, spec);
    try rampChecks(&context, spec, sweep.min_bandwidth_hz);
    try chargePumpSuggestion(&context, spec, nominal, sweep.min_phase_margin_deg);
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
    return .{ .nominal = nominal, .tolerance_pct = tolerancePct(inst, nominal, false), .ref = displayRef(inst) };
}

fn capacitor(block: *const DesignBlock, name: []const u8) ?Value {
    const inst = findInstance(block, name) orelse return null;
    const nominal = decouple_key.capFarads(inst.value);
    if (nominal <= 0) return null;
    return .{ .nominal = nominal, .tolerance_pct = tolerancePct(inst, nominal, true), .ref = displayRef(inst) };
}

fn findInstance(block: *const DesignBlock, name: []const u8) ?Instance {
    for (block.instances) |inst| if (eq(inst.label, name) or eq(inst.ref_des, name)) return inst;
    return null;
}

fn displayRef(inst: Instance) []const u8 {
    return if (inst.ref_des.len > 0) inst.ref_des else inst.label;
}

fn tolerancePct(inst: Instance, nominal: f64, is_cap: bool) f64 {
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
    if (raw.len == 0) return 0;
    if (std.mem.endsWith(u8, raw, "%")) return std.fmt.parseFloat(f64, raw[0 .. raw.len - 1]) catch 0;
    if (is_cap) {
        const absolute = decouple_key.capFarads(raw);
        if (absolute > 0 and nominal > 0) return absolute / nominal * 100.0;
    }
    return 0;
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
            corner_values[i] = value.nominal * (1.0 + sign * value.tolerance_pct / 100.0);
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
