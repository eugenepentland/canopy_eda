//! Derived-value requirement checks for programmable regulators. Kept apart
//! from `req_checks.zig` so the core checker stays below its size ceiling.

const std = @import("std");
const env = @import("eval/env.zig");
const ids = @import("eval/ids.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;

const DesignBlock = env.DesignBlock;
const Instance = env.Instance;
const FeedbackDividerCheck = @FieldType(env.Check, "feedback_divider");
const SetResistorOutputCheck = @FieldType(env.Check, "set_resistor_output");

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
    var top: ?Resistor = null;
    var bottom: ?Resistor = null;
    for (block.instances) |candidate| {
        if (candidate.ref_des.len == 0 or candidate.ref_des[0] != 'R') continue;
        if (!instancePinOnNet(block, candidate, fb_net)) continue;
        const other = otherNet(block, candidate, fb_net) orelse continue;
        const ohms = parseOhms(candidate.value) orelse continue;
        if (netsAlias(other, check.return_net)) {
            bottom = .{ .ref_des = candidate.ref_des, .ohms = ohms, .other_net = other };
        } else {
            top = .{ .ref_des = candidate.ref_des, .ohms = ohms, .other_net = other };
        }
    }
    const rt = top orelse return resultFmt(allocator, false, "no upper feedback resistor found on {s}", .{fb_net});
    const rb = bottom orelse return resultFmt(
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
    var rset: ?Resistor = null;
    for (block.instances) |candidate| {
        if (candidate.ref_des.len == 0 or candidate.ref_des[0] != 'R') continue;
        if (!instancePinOnNet(block, candidate, set_net)) continue;
        const other = otherNet(block, candidate, set_net) orelse continue;
        if (!netsAlias(other, check.return_net)) continue;
        const ohms = parseOhms(candidate.value) orelse continue;
        rset = .{ .ref_des = candidate.ref_des, .ohms = ohms, .other_net = other };
        break;
    }
    const resistor = rset orelse return resultFmt(
        allocator,
        false,
        "no SET resistor found between {s} and {s}",
        .{ set_net, check.return_net },
    );
    if (resistor.ohms <= 0 or check.current_ua <= 0) {
        return resultFmt(allocator, false, "SET current and resistance must be positive", .{});
    }
    const calculated = resistor.ohms * check.current_ua * 1e-6;
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

/// Parse common rail names: `+6V7`, `3V3`, `V1P8`, `VDD_3V3`, and `+5V`.
fn voltageFromRailName(name: []const u8) ?f64 {
    var index: usize = 0;
    while (index < name.len) : (index += 1) {
        if (!std.ascii.isDigit(name[index])) continue;
        const whole_start = index;
        while (index < name.len and std.ascii.isDigit(name[index])) : (index += 1) {}
        if (index >= name.len) return null;
        if (name[index] == '.') {
            const decimal_start = whole_start;
            index += 1;
            while (index < name.len and std.ascii.isDigit(name[index])) : (index += 1) {}
            if (index < name.len and (name[index] == 'V' or name[index] == 'v')) {
                return std.fmt.parseFloat(f64, name[decimal_start..index]) catch null;
            }
            continue;
        }
        if (name[index] != 'V' and name[index] != 'v' and name[index] != 'P' and name[index] != 'p') continue;
        const separator = index;
        index += 1;
        const fraction_start = index;
        while (index < name.len and std.ascii.isDigit(name[index])) : (index += 1) {}
        const whole = std.fmt.parseFloat(f64, name[whole_start..separator]) catch return null;
        if (fraction_start == index) return whole;
        const fraction_digits = name[fraction_start..index];
        const fraction = std.fmt.parseFloat(f64, fraction_digits) catch return null;
        var scale: f64 = 1;
        for (fraction_digits) |_| scale *= 10;
        return whole + fraction / scale;
    }
    return null;
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

fn netBase(name: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return name;
    return name[0..dot];
}

fn parseOhms(value: []const u8) ?f64 {
    if (value.len == 0) return null;
    if (std.mem.indexOfScalar(u8, value, '.') == null) {
        if (std.mem.indexOfAny(u8, value, "Rr")) |separator| {
            const whole = value[0..separator];
            const fraction = value[separator + 1 ..];
            if (allDigits(whole) and allDigits(fraction) and (whole.len > 0 or fraction.len > 0)) {
                var buffer: [32]u8 = undefined;
                const decimal = std.fmt.bufPrint(&buffer, "{s}.{s}", .{
                    if (whole.len > 0) whole else "0",
                    if (fraction.len > 0) fraction else "0",
                }) catch return null;
                return std.fmt.parseFloat(f64, decimal) catch null;
            }
        }
    }
    var index: usize = 0;
    while (index < value.len and (std.ascii.isDigit(value[index]) or value[index] == '.')) : (index += 1) {}
    if (index == 0) return null;
    const number = std.fmt.parseFloat(f64, value[0..index]) catch return null;
    while (index < value.len and (value[index] == ' ' or value[index] == '\t')) : (index += 1) {}
    if (index == value.len) return number;
    const suffix = value[index..];
    if (std.mem.eql(u8, suffix, "k") or std.mem.eql(u8, suffix, "K") or
        std.mem.eql(u8, suffix, "kΩ") or std.mem.eql(u8, suffix, "KΩ")) return number * 1e3;
    if (std.mem.eql(u8, suffix, "M") or std.mem.eql(u8, suffix, "MΩ")) return number * 1e6;
    if (std.mem.eql(u8, suffix, "R") or std.mem.eql(u8, suffix, "Ω")) return number;
    return null;
}

fn allDigits(value: []const u8) bool {
    for (value) |character| if (!std.ascii.isDigit(character)) return false;
    return true;
}

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

// spec: req_derived_checks - feedback-divider and SET-current checks reject the mismatched values used by straps
test "derived regulator checks catch straps voltage mismatches" {
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
