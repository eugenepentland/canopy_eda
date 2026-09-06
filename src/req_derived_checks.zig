//! Derived-value requirement checks for programmable regulators. Kept apart
//! from `req_checks.zig` so the core checker stays below its size ceiling.

const std = @import("std");
const env = @import("eval/env.zig");
const ids = @import("eval/ids.zig");
const req_checks = @import("req_checks.zig");
const na = @import("eval/net_analysis.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;

/// Amperes per microampere — the declared SET current is in µA, Ohm's law is
/// in amperes.
const amps_per_microamp: f64 = 1e-6;

const DesignBlock = env.DesignBlock;
const Instance = env.Instance;
const FeedbackDividerCheck = @FieldType(env.Check, "feedback_divider");
const SetResistorOutputCheck = @FieldType(env.Check, "set_resistor_output");

/// The resistor-value parser, borrowed from the core requirement checker rather
/// than re-implemented here. This file used to carry a private copy that had
/// silently fallen behind the canonical one: it lacked the milliohm `m`, giga
/// `G` and spelled-out `ohm`/`ohms` suffixes, so a `10m` current-sense shunt was
/// null-skipped by the derived checks while `req_checks` read it as 0.01 Ω. One
/// value grammar must have exactly one parser.
const parseOhms = req_checks.parseOhms;

/// Allocator-owned pass/fail result translated into `req_checks.Result` by the
/// core requirement checker.
pub const Result = struct {
    passed: bool,
    message: []const u8,
};

/// Evaluate one derived regulator requirement check.
pub fn evaluate(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    check: env.Check,
) Result {
    return switch (check) {
        .feedback_divider => |payload| feedbackDivider(
            allocator,
            eval,
            block,
            inst,
            payload,
        ),
        .set_resistor_output => |payload| setResistorOutput(
            allocator,
            eval,
            block,
            inst,
            payload,
        ),
        else => resultFmt(
            allocator,
            false,
            "unsupported derived requirement check",
            .{},
        ),
    };
}

/// Evaluate a programmable feedback divider against its declared/name-encoded
/// output rail voltage.
///
/// An FB node carrying more than one resistor on the same leg (a parallel trim
/// pair, an FB filter R, a miswired pull-up) is REPORTED, not resolved: the
/// collector used to overwrite `top`/`bottom` on every match, so which resistor
/// won depended on instance order, and a wrongly-picked leg computes a VOUT that
/// can make a mis-set rail false-PASS. There is no safe way to guess which one
/// the author meant.
fn feedbackDivider(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    check: FeedbackDividerCheck,
) Result {
    const fb_net = netForPinFn(eval, block, inst, check.pin) orelse
        return resultFmt(
            allocator,
            false,
            "pin '{s}' could not be resolved to a net",
            .{check.pin},
        );
    const legs = collectFeedbackLegs(block, fb_net, check.return_net);
    if (legs.top.count > 1) return ambiguousLeg(allocator, "upper", fb_net, legs.top);
    if (legs.bottom.count > 1) return ambiguousLeg(allocator, "lower", fb_net, legs.bottom);
    const rt = legs.top.first orelse return resultFmt(allocator, false, "no upper feedback resistor found on {s}", .{fb_net});
    const rb = legs.bottom.first orelse return resultFmt(
        allocator,
        false,
        "no feedback resistor from {s} to {s}",
        .{ fb_net, check.return_net },
    );
    if (rb.ohms <= 0 or check.reference_v <= 0) {
        return resultFmt(allocator, false, "feedback reference and lower resistance must be positive", .{});
    }
    const calculated = check.reference_v * (1.0 + rt.ohms / rb.ohms);
    const expected = expectedVoltage(block, rt.other_net) orelse
        return resultFmt(
            allocator,
            false,
            "output net {s} has no declared or name-encoded voltage",
            .{netBase(rt.other_net)},
        );
    return compareOutput(allocator, .{
        .label = "feedback divider",
        .calculated = calculated,
        .expected = expected.volts,
        .tolerance_pct = check.tolerance_pct,
        .output_net = rt.other_net,
        .resistor_a = rt.ref_des,
        .resistor_b = rb.ref_des,
    });
}

/// Evaluate a current-programmed SET resistor against the output rail voltage.
fn setResistorOutput(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    check: SetResistorOutputCheck,
) Result {
    const set_net = netForPinFn(eval, block, inst, check.pin) orelse
        return resultFmt(
            allocator,
            false,
            "pin '{s}' could not be resolved to a net",
            .{check.pin},
        );
    const output_net = netForPinFn(eval, block, inst, check.output_pin) orelse
        return resultFmt(
            allocator,
            false,
            "output pin '{s}' could not be resolved to a net",
            .{check.output_pin},
        );
    // Same discipline as `feedbackDivider`: two resistors between SET and the
    // return net are in PARALLEL, so taking the first one (as this loop used to,
    // via `break`) computes a SET current — and therefore an output voltage —
    // that is simply wrong, and a mis-programmed rail can false-PASS on it.
    const candidates = collectSetResistors(block, set_net, check.return_net);
    if (candidates.count > 1) return ambiguousLeg(allocator, "SET", set_net, candidates);
    const resistor = candidates.first orelse return resultFmt(
        allocator,
        false,
        "no SET resistor found between {s} and {s}",
        .{ set_net, check.return_net },
    );
    if (resistor.ohms <= 0 or check.current_ua <= 0) {
        return resultFmt(allocator, false, "SET current and resistance must be positive", .{});
    }
    const calculated = resistor.ohms * check.current_ua * amps_per_microamp;
    const expected = expectedVoltage(block, output_net) orelse
        return resultFmt(
            allocator,
            false,
            "output net {s} has no declared or name-encoded voltage",
            .{netBase(output_net)},
        );
    return compareOutput(allocator, .{
        .label = "SET resistor",
        .calculated = calculated,
        .expected = expected.volts,
        .tolerance_pct = check.tolerance_pct,
        .output_net = output_net,
        .resistor_a = resistor.ref_des,
    });
}

const Resistor = struct {
    ref_des: []const u8,
    ohms: f64,
    other_net: []const u8,
};

/// The resistors found on one leg of a programming network. Keeps the first
/// match plus a COUNT (and the second ref-des, for the diagnostic) so an
/// ambiguous node is reported instead of being resolved by instance order.
const LegCandidates = struct {
    first: ?Resistor = null,
    /// Ref-des of the second match, empty when there is at most one.
    second_ref: []const u8 = "",
    count: usize = 0,

    fn add(self: *LegCandidates, resistor: Resistor) void {
        self.count += 1;
        if (self.first == null) {
            self.first = resistor;
        } else if (self.second_ref.len == 0) {
            self.second_ref = resistor.ref_des;
        }
    }
};

/// Both legs of a feedback divider hanging off the FB node.
const FeedbackLegs = struct {
    top: LegCandidates = .{},
    bottom: LegCandidates = .{},
};

/// Split every resistor touching `fb_net` into the leg that returns to
/// `return_net` (the lower leg) and everything else (the upper leg).
fn collectFeedbackLegs(block: *const DesignBlock, fb_net: []const u8, return_net: []const u8) FeedbackLegs {
    var legs = FeedbackLegs{};
    for (block.instances) |candidate| {
        const resistor = feedbackResistor(block, candidate, fb_net) orelse continue;
        if (netsAlias(resistor.other_net, return_net)) legs.bottom.add(resistor) else legs.top.add(resistor);
    }
    return legs;
}

/// Every resistor bridging `set_net` to `return_net`.
fn collectSetResistors(block: *const DesignBlock, set_net: []const u8, return_net: []const u8) LegCandidates {
    var found = LegCandidates{};
    for (block.instances) |candidate| {
        const resistor = feedbackResistor(block, candidate, set_net) orelse continue;
        if (!netsAlias(resistor.other_net, return_net)) continue;
        found.add(resistor);
    }
    return found;
}

/// `candidate` as a programming resistor on `net`, or null when it is not an
/// `R` part, does not touch `net`, has no second net, or carries a value the
/// canonical `req_checks.parseOhms` cannot read.
fn feedbackResistor(block: *const DesignBlock, candidate: Instance, net: []const u8) ?Resistor {
    if (candidate.ref_des.len == 0 or candidate.ref_des[0] != 'R') return null;
    if (!instancePinOnNet(block, candidate, net)) return null;
    const other = otherNet(block, candidate, net) orelse return null;
    const ohms = parseOhms(candidate.value) orelse return null;
    return .{ .ref_des = candidate.ref_des, .ohms = ohms, .other_net = other };
}

/// Report a programming node with more than one resistor on the same leg.
/// Silently picking one by instance order changes the computed output voltage,
/// so a mis-set rail could false-PASS; naming the conflict is the only safe
/// answer the checker can give.
fn ambiguousLeg(
    allocator: std.mem.Allocator,
    leg: []const u8,
    net: []const u8,
    candidates: LegCandidates,
) Result {
    const first_ref = if (candidates.first) |resistor| resistor.ref_des else "?";
    return resultFmt(
        allocator,
        false,
        "ambiguous {s} leg on {s}: {d} resistors sit on it, including {s} and {s} — " ++
            "the programming network cannot be resolved, so move the extra part off the node " ++
            "or give it its own net",
        .{ leg, net, candidates.count, first_ref, candidates.second_ref },
    );
}

const ExpectedVoltage = struct { volts: f64 };

const OutputComparison = struct {
    label: []const u8,
    calculated: f64,
    expected: f64,
    tolerance_pct: f64,
    output_net: []const u8,
    resistor_a: []const u8,
    resistor_b: []const u8 = "",
};

fn compareOutput(allocator: std.mem.Allocator, comparison: OutputComparison) Result {
    const allowed = @abs(comparison.expected) *
        @max(comparison.tolerance_pct, 0) / 100.0;
    const matches = @abs(comparison.calculated - comparison.expected) <=
        @max(allowed, 1e-9);
    if (comparison.resistor_b.len > 0) return resultFmt(
        allocator,
        matches,
        "{s} {s}/{s} calculates {d:.3} V; {s} expects {d:.3} V (±{d:.2}%)",
        .{
            comparison.label,
            comparison.resistor_a,
            comparison.resistor_b,
            comparison.calculated,
            netBase(comparison.output_net),
            comparison.expected,
            comparison.tolerance_pct,
        },
    );
    return resultFmt(
        allocator,
        matches,
        "{s} {s} calculates {d:.3} V; {s} expects {d:.3} V (±{d:.2}%)",
        .{
            comparison.label,
            comparison.resistor_a,
            comparison.calculated,
            netBase(comparison.output_net),
            comparison.expected,
            comparison.tolerance_pct,
        },
    );
}

fn expectedVoltage(block: *const DesignBlock, net: []const u8) ?ExpectedVoltage {
    for (block.ports) |port| {
        if (!netsAlias(port.net, net) and !netsAlias(port.name, net)) continue;
        if (port.nominal) |volts| return .{ .volts = volts };
        if (port.rated_min != null and port.rated_max != null) {
            return .{ .volts = (port.rated_min.? + port.rated_max.?) / 2.0 };
        }
    }
    for (block.sections) |section| if (sectionVoltage(section, netBase(net))) |volts| {
        return .{ .volts = volts };
    };
    if (voltageFromRailName(netBase(net))) |volts| return .{ .volts = volts };
    return null;
}

fn sectionVoltage(section: env.Section, net: []const u8) ?f64 {
    for (section.ports) |port| {
        if (std.mem.eql(u8, port.name, net)) if (port.voltage) |volts| return volts;
    }
    for (section.sub_sections) |sub| if (sectionVoltage(sub, net)) |volts| return volts;
    return null;
}

/// Parse common rail names into volts: `+6V7` → 6.7, `3V3` → 3.3, `V1P8` → 1.8,
/// `VDD_3V3` → 3.3, `+5V` → 5, `3.3V` → 3.3, `+5_0V` → 5.0, `V_NEG_3P3` → −3.3.
///
/// Four spellings stand in for the decimal point, because all four occur in this
/// tree: a literal `.`, the authored board conventions `V` and `P`, and `_` —
/// which is what `import_kicad.sanitizeNetName` produces when it rewrites
/// KiCad's `+5.0V` (dots are stripped there because the evaluator reserves them
/// for `<rail>.<ic>.<pad>` bypass stubs, so importing them verbatim would merge
/// `+5.0V` and `+5.7V` into one rail). The `_` form previously fell through the
/// separator test and the scan RESUMED at the fraction digits, so `+5_0V`
/// decoded as **0.0 V** — and a divider / SET-resistor check on such a rail then
/// compared its computed output against 0 V and failed with confident wrong
/// numbers. An `_` only counts as a decimal point when digits and a closing volt
/// unit follow it, so the ordinary separator underscore of `VDD_3V3` is
/// untouched.
///
/// A negative marker — a leading `-`, or a delimited `NEG` token — flips the
/// sign, so a −3.3 V rail spelled `V_NEG_3P3` is no longer reported as +3.3 V.
///
/// Returns null when the name encodes no voltage at all ("SIGNAL", "GND").
fn voltageFromRailName(name: []const u8) ?f64 {
    const magnitude = railNameMagnitude(name) orelse return null;
    return if (isNegativeRailName(name)) -magnitude else magnitude;
}

/// Unsigned voltage encoded in `name`: scans left to right for the first digit
/// run that a rail spelling can be completed from, and gives up at the end of
/// the name.
fn railNameMagnitude(name: []const u8) ?f64 {
    var index: usize = 0;
    while (index < name.len) : (index += 1) {
        if (!std.ascii.isDigit(name[index])) continue;
        const whole_start = index;
        while (index < name.len and std.ascii.isDigit(name[index])) : (index += 1) {}
        if (index >= name.len) return null;
        if (name[index] == '.') {
            index += 1;
            while (index < name.len and std.ascii.isDigit(name[index])) : (index += 1) {}
            if (index < name.len and isVoltUnit(name[index])) {
                return std.fmt.parseFloat(f64, name[whole_start..index]) catch null;
            }
            continue;
        }
        if (!isDecimalSeparator(name, index)) continue;
        const separator = index;
        index += 1;
        const fraction_start = index;
        while (index < name.len and std.ascii.isDigit(name[index])) : (index += 1) {}
        const whole = std.fmt.parseFloat(f64, name[whole_start..separator]) catch return null;
        if (fraction_start == index) return whole;
        const fraction = fractionValue(name[fraction_start..index]) orelse return null;
        return whole + fraction;
    }
    return null;
}

/// True when `name[index]`, sitting immediately after a digit run, stands in for
/// the decimal point: `V`/`v` (`3V3`), `P`/`p` (`V1P8`), or the imported `_`
/// form (`+5_0V`). The underscore is accepted only when it is followed by
/// fraction digits AND a closing volt unit, so a plain separator underscore
/// (`VDD_3V3`, `EN_3_3`) is never mistaken for one.
fn isDecimalSeparator(name: []const u8, index: usize) bool {
    const c = name[index];
    if (isVoltUnit(c) or c == 'P' or c == 'p') return true;
    if (c != '_') return false;
    var scan = index + 1;
    const fraction_start = scan;
    while (scan < name.len and std.ascii.isDigit(name[scan])) : (scan += 1) {}
    if (scan == fraction_start) return false;
    return scan < name.len and isVoltUnit(name[scan]);
}

/// True for the volt unit letter in either case.
fn isVoltUnit(c: u8) bool {
    return c == 'V' or c == 'v';
}

/// Value of a run of fraction digits: "8" → 0.8, "25" → 0.25. Null when the run
/// does not parse, which the caller's digit scan makes unreachable — it is
/// propagated rather than defaulted so a fabricated 0 can never reach a voltage
/// comparison.
fn fractionValue(digits: []const u8) ?f64 {
    const value = std.fmt.parseFloat(f64, digits) catch return null;
    var scale: f64 = 1;
    for (digits) |_| scale *= 10;
    return value / scale;
}

/// True when `name` spells a NEGATIVE rail: a leading `-` (`-5V`, `-3.3V`) or a
/// delimited `NEG` token (`V_NEG_3P3`, `VNEG_12V`, `NEG3V3`). The magnitude
/// scanner is sign-blind by construction — it looks only for digits — so this is
/// what stops a −3.3 V rail being reported, and compared against, as +3.3 V.
fn isNegativeRailName(name: []const u8) bool {
    if (name.len > 0 and name[0] == '-') return true;
    var index: usize = 0;
    while (index + 3 <= name.len) : (index += 1) {
        if (!std.ascii.eqlIgnoreCase(name[index .. index + 3], "NEG")) continue;
        if (!negTokenStarts(name, index)) continue;
        if (negTokenEnds(name, index + 3)) return true;
    }
    return false;
}

/// True when the `NEG` at `at` begins a token: at the string start, after a
/// `_`/`-` separator, or straight after the leading `V` of the `VNEG…` form.
/// Anchoring it this way keeps an incidental "neg" inside a longer word from
/// negating a rail.
fn negTokenStarts(name: []const u8, at: usize) bool {
    if (at == 0) return true;
    const previous = name[at - 1];
    if (previous == '_' or previous == '-') return true;
    return at == 1 and isVoltUnit(previous);
}

/// True when the `NEG` token ending at `at` is closed by a separator, by the
/// voltage digits themselves (`NEG3V3`), or by the end of the name.
fn negTokenEnds(name: []const u8, at: usize) bool {
    if (at >= name.len) return true;
    const next = name[at];
    if (next == '_' or next == '-') return true;
    return std.ascii.isDigit(next);
}

fn netForPinFn(eval: *Evaluator, block: *const DesignBlock, inst: Instance, pin_fn: []const u8) ?[]const u8 {
    const pinout_key = if (inst.pinout.len > 0) inst.pinout else inst.symbol;
    if (pinout_key.len == 0) return null;
    const symbol_pins = ids.getSymbolPins(eval, pinout_key) orelse return null;
    var iterator = symbol_pins.iterator();
    while (iterator.next()) |entry| {
        if (!std.ascii.eqlIgnoreCase(entry.value_ptr.*, pin_fn)) continue;
        if (netForPhysicalPin(block, inst.ref_des, entry.key_ptr.*)) |net| return net;
    }
    return netForPhysicalPin(block, inst.ref_des, pin_fn);
}

fn netForPhysicalPin(block: *const DesignBlock, ref_des: []const u8, pin_id: []const u8) ?[]const u8 {
    for (block.nets) |net| for (net.pins) |pin| {
        if (std.mem.eql(u8, pin.ref_des, ref_des) and std.mem.eql(u8, pin.pin, pin_id)) return net.name;
    };
    return null;
}

fn instancePinOnNet(block: *const DesignBlock, inst: Instance, net_name: []const u8) bool {
    for (block.nets) |net| {
        if (!netsAlias(net.name, net_name)) continue;
        for (net.pins) |pin| if (std.mem.eql(u8, pin.ref_des, inst.ref_des)) return true;
    }
    return false;
}

fn otherNet(block: *const DesignBlock, inst: Instance, known_net: []const u8) ?[]const u8 {
    for (block.nets) |net| {
        if (netsAlias(net.name, known_net)) continue;
        for (net.pins) |pin| if (std.mem.eql(u8, pin.ref_des, inst.ref_des)) return net.name;
    }
    return null;
}

fn netsAlias(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b) or std.mem.eql(u8, netBase(a), netBase(b));
}

const netBase = na.baseNetName;

fn resultFmt(allocator: std.mem.Allocator, passed: bool, comptime format: []const u8, args: anytype) Result {
    return .{
        .passed = passed,
        .message = std.fmt.allocPrint(allocator, format, args) catch "",
    };
}

// spec: req_derived_checks - rail-name fallback decodes common voltage conventions used by flat designs
test "voltageFromRailName handles common conventions" {
    try std.testing.expectApproxEqAbs(@as(f64, 6.7), voltageFromRailName("+6V7").?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), voltageFromRailName("+6V").?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.8), voltageFromRailName("V1P8").?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.3), voltageFromRailName("VDD_3V3").?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.3), voltageFromRailName("3.3V").?, 1e-9);
    try std.testing.expect(voltageFromRailName("SIGNAL") == null);
}

// spec: req_derived_checks - rail-name fallback decodes the imported underscore decimal and signed negative spellings
test "voltageFromRailName decodes imported and negative rail spellings" {
    const cases = [_]struct { name: []const u8, volts: f64 }{
        // `import_kicad.sanitizeNetName` rewrites KiCad's "+5.0V" as "+5_0V"
        // (dots are reserved for bypass-stub nets). The parser used to scan the
        // 5, hit the '_', resume, and read "0V" — returning 0.0 V.
        .{ .name = "+5_0V", .volts = 5.0 },
        .{ .name = "+5_7V", .volts = 5.7 },
        // Negative rails keep their sign instead of reporting as positive.
        .{ .name = "V_NEG_3P3", .volts = -3.3 },
        .{ .name = "-5V", .volts = -5.0 },
        .{ .name = "-3.3V", .volts = -3.3 },
        // Every spelling that already decoded must keep decoding.
        .{ .name = "+6V7", .volts = 6.7 },
        .{ .name = "+6V", .volts = 6.0 },
        .{ .name = "V1P8", .volts = 1.8 },
        .{ .name = "V3P3", .volts = 3.3 },
        .{ .name = "V5P0", .volts = 5.0 },
        .{ .name = "VDD_3V3", .volts = 3.3 },
        .{ .name = "V_3V3D", .volts = 3.3 },
        .{ .name = "V_12V", .volts = 12.0 },
        .{ .name = "V_RX_2P5", .volts = 2.5 },
        .{ .name = "3.3V", .volts = 3.3 },
        .{ .name = "3V3", .volts = 3.3 },
    };
    for (cases) |c| {
        try std.testing.expect(voltageFromRailName(c.name) != null);
        try std.testing.expectApproxEqAbs(c.volts, voltageFromRailName(c.name).?, 1e-9);
    }
    // A bare separator underscore is not a decimal point, and a name with no
    // voltage in it still decodes to nothing at all.
    try std.testing.expect(voltageFromRailName("SIGNAL") == null);
    try std.testing.expect(voltageFromRailName("GND") == null);
}

// spec: req_derived_checks - resistor values are read through the canonical req_checks parser including the milliohm suffix
test "derived checks read resistor values through the canonical ohms parser" {
    // The private copy this file used to carry stopped at k/M/R/Ω, so a `10m`
    // shunt came back null here while `req_checks` read it as 0.01 Ω, and a
    // `2G` bias resistor was invisible to the derived checks entirely.
    try std.testing.expectApproxEqAbs(@as(f64, 0.01), parseOhms("10m").?, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2e9), parseOhms("2G").?, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f64, 220), parseOhms("220ohm").?, 1e-9);
    // `m` is milli and `M` is mega — the case distinction must survive.
    try std.testing.expectApproxEqAbs(@as(f64, 1e6), parseOhms("1M").?, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 10000), parseOhms("10k").?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 4.7), parseOhms("4R7").?, 1e-9);
    try std.testing.expect(parseOhms("bogus") == null);
}

// spec: req_derived_checks - feedback-divider and SET-current checks reject the mismatched values used by board-d
test "derived regulator checks catch board-d voltage mismatches" {
    const allocator = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/pinouts");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/pinouts/reg.sexp",
        .data = "(pinout reg (pin 1 \"FB\") (pin 2 \"OUT\") (pin 3 \"SET\"))",
    });
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    var evaluator = Evaluator.init(allocator, project_dir);
    defer evaluator.deinit();

    const instances = [_]Instance{
        .{ .ref_des = "PS1", .component = "reg", .value = "reg", .footprint = "x", .symbol = "reg", .pinout = "reg" },
        .{ .ref_des = "R_TOP", .component = "res", .value = "84.5K", .footprint = "x", .symbol = "res" },
        .{ .ref_des = "R_BOT", .component = "res", .value = "10K", .footprint = "x", .symbol = "res" },
        .{ .ref_des = "R_SET", .component = "res", .value = "50K", .footprint = "x", .symbol = "res" },
    };
    const nets = [_]env.Net{
        .{ .name = "FB", .pins = &.{
            .{ .ref_des = "PS1", .pin = "1" },
            .{ .ref_des = "R_TOP", .pin = "1" },
            .{ .ref_des = "R_BOT", .pin = "1" },
        } },
        .{ .name = "+6V7", .pins = &.{
            .{ .ref_des = "PS1", .pin = "2" },
            .{ .ref_des = "R_TOP", .pin = "2" },
        } },
        .{ .name = "SET", .pins = &.{
            .{ .ref_des = "PS1", .pin = "3" },
            .{ .ref_des = "R_SET", .pin = "1" },
        } },
        .{ .name = "GND", .pins = &.{
            .{ .ref_des = "R_BOT", .pin = "2" },
            .{ .ref_des = "R_SET", .pin = "2" },
        } },
    };
    const block = DesignBlock{
        .name = "derived",
        .instances = &instances,
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const divider = feedbackDivider(allocator, &evaluator, &block, instances[0], .{
        .pin = "FB",
        .return_net = "GND",
        .reference_v = 0.6,
        .tolerance_pct = 2,
    });
    try std.testing.expect(!divider.passed);
    try std.testing.expect(std.mem.indexOf(u8, divider.message, "5.670") != null);
    try std.testing.expect(std.mem.indexOf(u8, divider.message, "6.700") != null);

    const set = setResistorOutput(allocator, &evaluator, &block, instances[0], .{
        .pin = "SET",
        .return_net = "GND",
        .output_pin = "OUT",
        .current_ua = 100,
        .tolerance_pct = 2,
    });
    try std.testing.expect(!set.passed);
    try std.testing.expect(std.mem.indexOf(u8, set.message, "5.000") != null);
    try std.testing.expect(std.mem.indexOf(u8, set.message, "6.700") != null);
}

// spec: req_derived_checks - a second resistor on one feedback leg is reported instead of silently replacing it
test "ambiguous feedback leg is reported rather than resolved by instance order" {
    const allocator = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/pinouts");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/pinouts/reg.sexp",
        .data = "(pinout reg (pin 1 \"FB\") (pin 2 \"OUT\"))",
    });
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    var evaluator = Evaluator.init(allocator, project_dir);
    defer evaluator.deinit();

    // Two resistors run from the FB node up to the output rail — a parallel
    // trim pair. The collector used to overwrite `top` on every match, so the
    // computed VOUT depended on which instance came last (84.5k → 5.67 V,
    // 1M → 60.6 V): a mis-set rail could false-PASS on the lucky ordering.
    const instances = [_]Instance{
        .{ .ref_des = "PS1", .component = "reg", .value = "reg", .footprint = "x", .symbol = "reg", .pinout = "reg" },
        .{ .ref_des = "R_TOP", .component = "res", .value = "84.5K", .footprint = "x", .symbol = "res" },
        .{ .ref_des = "R_TRIM", .component = "res", .value = "1M", .footprint = "x", .symbol = "res" },
        .{ .ref_des = "R_BOT", .component = "res", .value = "10K", .footprint = "x", .symbol = "res" },
    };
    const nets = [_]env.Net{
        .{ .name = "FB", .pins = &.{
            .{ .ref_des = "PS1", .pin = "1" },
            .{ .ref_des = "R_TOP", .pin = "1" },
            .{ .ref_des = "R_TRIM", .pin = "1" },
            .{ .ref_des = "R_BOT", .pin = "1" },
        } },
        .{ .name = "+6V7", .pins = &.{
            .{ .ref_des = "PS1", .pin = "2" },
            .{ .ref_des = "R_TOP", .pin = "2" },
            .{ .ref_des = "R_TRIM", .pin = "2" },
        } },
        .{ .name = "GND", .pins = &.{.{ .ref_des = "R_BOT", .pin = "2" }} },
    };
    const block = DesignBlock{
        .name = "ambiguous",
        .instances = &instances,
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const divider = feedbackDivider(allocator, &evaluator, &block, instances[0], .{
        .pin = "FB",
        .return_net = "GND",
        .reference_v = 0.6,
        .tolerance_pct = 2,
    });
    try std.testing.expect(!divider.passed);
    try std.testing.expect(std.mem.indexOf(u8, divider.message, "ambiguous upper leg") != null);
    try std.testing.expect(std.mem.indexOf(u8, divider.message, "R_TOP") != null);
    try std.testing.expect(std.mem.indexOf(u8, divider.message, "R_TRIM") != null);
}
