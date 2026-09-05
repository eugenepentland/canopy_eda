//! Component-class review profiles: the review obligations a placed active
//! part carries because of the KIND of part it is — a regulator, a PLL, an
//! MCU, a mixer. The class comes from an authored `(class <key>)` on the
//! library component, else a best-effort inference from the part's pin
//! function names. Every obligation the tool can see mechanically becomes one
//! `profile_incomplete` preflight finding that names the form closing it; the
//! prose profiles (what a reviewer must still judge) live beside the designs
//! in `docs/review-profiles/`.

const std = @import("std");
const env = @import("eval/env.zig");
const pin_roles = @import("placement/pin_roles.zig");

/// The profile keys, spelled as the designs-side profile files are.
pub const Class = enum {
    ldo,
    switching_regulator,
    protection,
    load_switch,
    mcu,
    level_shifter,
    pll_loop,
    integrated_synthesizer,
    clock_jitter_cleaner,
    crystal_oscillator,
    rf_amplifier,
    mixer,
    rf_attenuator_switch,
    rf_passive,
    rf_detector,
    op_amp,
    sensor,
    connectors,
    power_path_passives,
    generic,

    /// The kebab-case key an author writes in `(class …)`.
    pub fn key(self: Class) []const u8 {
        return switch (self) {
            .ldo => "ldo",
            .switching_regulator => "switching-regulator",
            .protection => "protection",
            .load_switch => "load-switch",
            .mcu => "mcu",
            .level_shifter => "level-shifter",
            .pll_loop => "pll-loop",
            .integrated_synthesizer => "integrated-synthesizer",
            .clock_jitter_cleaner => "clock-jitter-cleaner",
            .crystal_oscillator => "crystal-oscillator",
            .rf_amplifier => "rf-amplifier",
            .mixer => "mixer",
            .rf_attenuator_switch => "rf-attenuator-switch",
            .rf_passive => "rf-passive",
            .rf_detector => "rf-detector",
            .op_amp => "op-amp",
            .sensor => "sensor",
            .connectors => "connectors",
            .power_path_passives => "power-path-passives",
            .generic => "generic",
        };
    }
};

/// Parse an authored class key. Both the kebab-case profile name and the
/// enum tag spelling are accepted; anything else is rejected rather than
/// silently read as `generic`.
pub fn parseClass(word: []const u8) ?Class {
    const trimmed = std.mem.trim(u8, word, " \t\r\n\"");
    for (std.enums.values(Class)) |class| {
        if (std.ascii.eqlIgnoreCase(trimmed, class.key()) or std.ascii.eqlIgnoreCase(trimmed, @tagName(class))) return class;
    }
    return null;
}

/// The authored `(class …)` on the instance's library component, if any.
/// A component body field the evaluator does not recognise structurally is
/// carried as an inline property, which is exactly where `class` lands.
pub fn declaredClass(inst: env.Instance) ?Class {
    for (inst.properties) |property| {
        if (!std.mem.eql(u8, property.key, "class")) continue;
        return parseClass(property.value);
    }
    return null;
}

/// Extra datasheet-review categories a complete review of this class must
/// answer, beyond the six every active part owes.
pub fn extraCategories(class: Class) []const []const u8 {
    return switch (class) {
        .ldo => &.{ "dropout", "current-limit", "stability" },
        .switching_regulator => &.{ "hot-loop", "compensation", "inductor", "input-transient" },
        .protection => &.{ "fault-response", "reverse-polarity", "clamp-coordination" },
        .load_switch => &.{ "gate-drive", "turn-on-off" },
        .mcu => &.{ "gpio-drive", "boot-straps", "reset-por", "clock-input", "interfaces" },
        .level_shifter => &.{ "direction-control", "oe-sequencing", "drive-strength" },
        .pll_loop => &.{ "loop-filter", "reference-input", "feedback-input", "tuning-range", "lock-detect" },
        .integrated_synthesizer => &.{ "reference-input", "loop-filter", "output-network", "register-image" },
        .clock_jitter_cleaner => &.{ "xo-selection", "input-levels", "output-formats", "boot-straps", "register-image" },
        .crystal_oscillator => &.{ "load-capacitance", "drive-level", "startup" },
        .rf_amplifier => &.{ "level-budget", "bias-network", "stability" },
        .mixer => &.{ "drive-levels", "combined-power", "spur-table", "port-terminations" },
        .rf_attenuator_switch => &.{ "control-interface", "power-handling", "switching" },
        .rf_passive => &.{ "passband", "power-rating", "port-match" },
        .rf_detector => &.{ "input-range", "output-scaling" },
        .op_amp => &.{ "supply-swing", "input-range", "stability" },
        .sensor => &.{ "bus-levels", "address" },
        .connectors => &.{ "contact-rating", "mating" },
        .power_path_passives, .generic => &.{},
    };
}

/// Classes whose parts dissipate enough that the thermal screen must not have
/// to guess their package: a missing `(thermal …)` is an unmet item.
pub fn requiresThermal(class: Class) bool {
    return switch (class) {
        .ldo, .switching_regulator, .mcu, .pll_loop, .integrated_synthesizer, .clock_jitter_cleaner, .rf_amplifier, .mixer, .op_amp => true,
        else => false,
    };
}

/// The design-level analysis form a class demands in gate mode.
pub const FormNeed = enum { none, pll_loop, frequency_plan };

/// Which analysis form (if any) the class demands of the design.
pub fn formNeed(class: Class) FormNeed {
    return switch (class) {
        .pll_loop => .pll_loop,
        .mixer => .frequency_plan,
        else => .none,
    };
}

/// Which analysis forms the evaluated design declared, and whether in gate
/// mode. Filled once per preflight run from the evaluator's reports.
pub const Forms = struct {
    pll_any: bool = false,
    pll_gate: bool = false,
    plan_any: bool = false,
    plan_gate: bool = false,
};

/// One unmet obligation. `message` is owned by the allocator `evaluate` was
/// given; `code` is a static identifier for the register column.
pub const Item = struct {
    code: []const u8,
    message: []const u8,
};

/// The class resolved for a placed part and where it came from.
pub const Resolved = struct {
    class: Class,
    declared: bool,
};

/// Resolve a part's class: the authored key wins, else pin-name inference over
/// the library pinout under `project_dir`.
pub fn resolve(arena: std.mem.Allocator, project_dir: []const u8, inst: env.Instance) Resolved {
    if (declaredClass(inst)) |class| return .{ .class = class, .declared = true };
    const pads = pin_roles.padFunctions(arena, project_dir, inst.component);
    return .{ .class = inferClass(pads), .declared = false };
}

// ── Inference ─────────────────────────────────────────────────────────────

/// Upper-case a pin function name with its separators removed, so "RF_IN",
/// "rf-in" and "RFIN" compare equal. Truncates silently past `buf`.
fn canonical(name: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    for (name) |c| {
        if (n == buf.len) break;
        switch (c) {
            '_', '-', '/', '.', ' ', '\t', '#', '~', '(', ')', '+', '{', '}' => continue,
            else => {
                buf[n] = std.ascii.toUpper(c);
                n += 1;
            },
        }
    }
    return buf[0..n];
}

/// True when some pad's canonical function name is exactly `needle`, or is
/// `needle` followed only by digits ("VDD" matches "VDD_2"; "RF" does not
/// match "RFOUT").
fn hasFn(pads: []const pin_roles.PadFunction, needle: []const u8) bool {
    for (pads) |pad| {
        var buf: [48]u8 = undefined;
        const c = canonical(pad.fn_name, &buf);
        if (c.len < needle.len or !std.mem.eql(u8, c[0..needle.len], needle)) continue;
        var digits_only = true;
        for (c[needle.len..]) |ch| if (!std.ascii.isDigit(ch)) {
            digits_only = false;
        };
        if (digits_only) return true;
    }
    return false;
}

/// True when some pad's canonical function name starts with `prefix`
/// ("PRIREF" matches "PRIREF_P").
fn hasPrefix(pads: []const pin_roles.PadFunction, prefix: []const u8) bool {
    for (pads) |pad| {
        var buf: [48]u8 = undefined;
        const c = canonical(pad.fn_name, &buf);
        if (std.mem.startsWith(u8, c, prefix)) return true;
    }
    return false;
}

fn hasAny(pads: []const pin_roles.PadFunction, needles: []const []const u8) bool {
    for (needles) |needle| if (hasFn(pads, needle)) return true;
    return false;
}

/// IN/OUT with a set/feedback/adjust pin, or a small fixed-output regulator
/// whose only extra pins are a bypass, noise-reduction or no-connect pad.
fn looksLikeLdo(pads: []const pin_roles.PadFunction) bool {
    if (!hasAny(pads, &.{ "VIN", "IN" }) or !hasAny(pads, &.{ "VOUT", "OUT" })) return false;
    if (hasAny(pads, &.{ "SET", "FB", "ADJ", "SENSE", "SENSEADJ", "NR", "BYP" })) return true;
    return pads.len <= 6 and hasAny(pads, &.{ "NC", "NOISE", "BYPASS" });
}

/// A reference input (PRIREF/SECREF/XO) feeding a numbered output bank on a
/// large package.
fn looksLikeClockCleaner(pads: []const pin_roles.PadFunction) bool {
    const reference = hasPrefix(pads, "PRIREF") or hasPrefix(pads, "SECREF") or hasPrefix(pads, "XO");
    return reference and hasPrefix(pads, "OUT0") and pads.len >= 24;
}

fn looksLikeFet(pads: []const pin_roles.PadFunction) bool {
    return hasFn(pads, "G") and hasFn(pads, "D") and hasFn(pads, "S");
}

fn looksLikeLoadSwitch(pads: []const pin_roles.PadFunction) bool {
    if (pads.len > 8) return false;
    return hasAny(pads, &.{ "EN", "ON", "ENABLE" }) and hasAny(pads, &.{ "VIN", "IN" }) and hasAny(pads, &.{ "VOUT", "OUT" });
}

/// Best-effort class from the pin function names alone. Deliberately coarse:
/// an author who disagrees writes `(class …)` and this never runs.
pub fn inferClass(pads: []const pin_roles.PadFunction) Class {
    if (pads.len == 0) return .generic;
    const gpio = hasAny(pads, &.{ "GPIO", "PA", "PB", "PC", "IO" });
    const rf_in = hasAny(pads, &.{ "RFIN", "RFI", "IN", "INPUT" });
    const rf_out = hasAny(pads, &.{ "RFOUT", "RFO", "OUT", "OUTPUT" });
    const lo = hasAny(pads, &.{ "LO", "LOIN" });
    const rf_port = hasAny(pads, &.{ "RF", "RFC", "RF1", "RF2", "RFIN", "RFOUT" });
    if (lo and hasAny(pads, &.{ "IF", "RF", "IFOUT", "RFIN" })) return .mixer;
    if (hasFn(pads, "VCCA") and (hasFn(pads, "VCCB") or hasFn(pads, "OE"))) return .level_shifter;
    if (hasPrefix(pads, "OSCIN") and hasPrefix(pads, "RFOUT")) return .integrated_synthesizer;
    if (hasAny(pads, &.{ "CPOUT", "CP", "CPO" }) and hasAny(pads, &.{ "REFIN", "RSET", "RFIN", "RFINA" })) return .pll_loop;
    if (hasFn(pads, "VTUNE") and rf_out) return .pll_loop;
    if (hasAny(pads, &.{ "INHI", "INLO" }) and hasAny(pads, &.{ "VSET", "VOUT", "TADJ" })) return .rf_detector;
    if (looksLikeClockCleaner(pads)) return .clock_jitter_cleaner;
    if (pads.len >= 24 and gpio) return .mcu;
    if (hasAny(pads, &.{ "RFC", "RFCOM", "COM" }) or (hasFn(pads, "RF1") and hasFn(pads, "RF2")) or hasAny(pads, &.{ "SERIN", "SERNIN", "LE", "ATT", "D0" })) {
        if (rf_port) return .rf_attenuator_switch;
    }
    if (hasAny(pads, &.{ "SDA", "SCL" }) and pads.len <= 10) return .sensor;
    if (hasAny(pads, &.{ "INP", "INN", "+IN", "-IN", "IN+", "IN-" }) and rf_out and pads.len <= 8) return .op_amp;
    if (hasAny(pads, &.{ "SW", "LX", "SWITCH", "BOOT", "BST" }) and hasAny(pads, &.{ "FB", "VOUT", "OUT", "COMP" })) return .switching_regulator;
    if (looksLikeLdo(pads)) return .ldo;
    if (hasAny(pads, &.{ "DVDT", "FLT", "IMON", "FAULT", "FLTB" }) and hasAny(pads, &.{ "IN", "VIN" })) return .protection;
    if (looksLikeFet(pads) or looksLikeLoadSwitch(pads)) return .load_switch;
    if ((rf_in and rf_out) or rf_port) {
        if (hasAny(pads, &.{ "VDD", "VCC", "VD", "VG", "VBYP", "BIAS" })) return .rf_amplifier;
        return .rf_passive;
    }
    return .generic;
}

// ── Evaluation ────────────────────────────────────────────────────────────

fn refersTo(reference: []const u8, pad: pin_roles.PadFunction) bool {
    return std.mem.eql(u8, reference, pad.pad) or std.ascii.eqlIgnoreCase(reference, pad.fn_name);
}

fn hasVoltageCheck(inst: env.Instance, pad: pin_roles.PadFunction) bool {
    for (inst.requirements) |requirement| {
        const check = requirement.check orelse continue;
        if (check == .voltage_range and refersTo(check.voltage_range.pin, pad)) return true;
    }
    return false;
}

fn hasDecouplingCheck(inst: env.Instance, pad: pin_roles.PadFunction) bool {
    for (inst.requirements) |requirement| {
        const check = requirement.check orelse continue;
        switch (check) {
            .decoupling => |d| if (refersTo(d.pin_a, pad) or refersTo(d.pin_b, pad)) return true,
            .decoupling_per_pin => |d| for (d.pins) |pin| if (refersTo(pin, pad)) return true,
            else => {},
        }
    }
    return false;
}

fn supplyCurrentAnnotated(block: *const env.DesignBlock, inst: env.Instance, pads: []const pin_roles.PadFunction) bool {
    for (block.nets) |net| for (net.pins) |pin| {
        if (!std.mem.eql(u8, pin.ref_des, inst.ref_des)) continue;
        if (pin.i_typ == null and pin.i_max == null) continue;
        for (pads) |pad| if (pad.class == .power and std.mem.eql(u8, pad.pad, pin.pin)) return true;
    };
    return false;
}

fn electricalFor(inst: env.Instance, fn_name: []const u8) ?env.ElectricalDecl {
    for (inst.electrical) |decl| if (std.ascii.eqlIgnoreCase(decl.pin, fn_name)) return decl;
    return null;
}

fn thresholdsComplete(decl: env.ElectricalDecl) bool {
    const t = decl.electrical_type orelse return false;
    return switch (t) {
        .input => decl.v_ih_min != null and decl.v_il_max != null,
        .output => decl.v_oh_typ != null and decl.v_ol_typ != null,
        .io => decl.v_ih_min != null and decl.v_il_max != null and decl.v_oh_typ != null and decl.v_ol_typ != null,
        else => true,
    };
}

fn reviewCovers(review: env.DatasheetReview, category: []const u8) bool {
    for (review.categories) |c| if (std.mem.eql(u8, c, category)) return true;
    for (review.not_applicable) |na| if (std.mem.eql(u8, na.category, category)) return true;
    return false;
}

const NameList = struct {
    names: std.ArrayList([]const u8) = .empty,

    fn add(self: *NameList, arena: std.mem.Allocator, name: []const u8) void {
        for (self.names.items) |seen| if (std.mem.eql(u8, seen, name)) return;
        self.names.append(arena, name) catch return;
    }

    fn joined(self: NameList, arena: std.mem.Allocator) []const u8 {
        return std.mem.join(arena, ", ", self.names.items) catch "";
    }
};

/// One part's evaluation in progress: the sink, the scratch arena, the
/// part, its pads and its class key, shared by the obligation checks.
const Evaluation = struct {
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    inst: env.Instance,
    pads: []const pin_roles.PadFunction,
    key: []const u8,
    items: *std.ArrayList(Item),

    fn push(self: Evaluation, code: []const u8, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        errdefer self.allocator.free(message);
        try self.items.append(self.allocator, .{ .code = code, .message = message });
    }

    fn requirements(self: Evaluation) std.mem.Allocator.Error!void {
        if (self.inst.requirements.len > 0 or self.inst.requirements_ignored) return;
        try self.push("requirements", "profile {s}: no (requirement …) rules on {s} — author cited datasheet rules with (check …) forms, or (ignore-requirements) for an inert part", .{ self.key, self.inst.component });
    }

    fn supply(self: Evaluation, block: *const env.DesignBlock) std.mem.Allocator.Error!void {
        var supply_count: usize = 0;
        var no_voltage: NameList = .{};
        var no_decoupling: NameList = .{};
        for (self.pads) |pad| {
            if (pad.class != .power) continue;
            supply_count += 1;
            if (!hasVoltageCheck(self.inst, pad)) no_voltage.add(self.arena, pad.fn_name);
            if (!hasDecouplingCheck(self.inst, pad)) no_decoupling.add(self.arena, pad.fn_name);
        }
        if (supply_count == 0) return;
        if (no_voltage.names.items.len > 0) {
            try self.push("supply-voltage-check", "profile {s}: supply pins without a (check (voltage-range …)) requirement: {s} — close with (requirement \"…\" (ref …) (check (voltage-range (pin \"PIN\") (min …) (max …))))", .{ self.key, no_voltage.joined(self.arena) });
        }
        if (no_decoupling.names.items.len > 0) {
            try self.push("supply-decoupling-check", "profile {s}: supply pins without a (check (decoupling …)) or (decoupling-per-pin …) requirement: {s}", .{ self.key, no_decoupling.joined(self.arena) });
        }
        if (!supplyCurrentAnnotated(block, self.inst, self.pads)) {
            try self.push("supply-current", "profile {s}: no supply pin of {s} carries (i-typ …)/(i-max …), so the power budget and the copper current screen have no envelope for it — annotate the instance's supply pin forms", .{ self.key, self.inst.ref_des });
        }
    }

    fn levels(self: Evaluation) std.mem.Allocator.Error!void {
        var no_levels: NameList = .{};
        var partial_levels: NameList = .{};
        for (self.pads) |pad| {
            if (pad.class != .strap) continue;
            const decl = electricalFor(self.inst, pad.fn_name) orelse {
                no_levels.add(self.arena, pad.fn_name);
                continue;
            };
            if (!thresholdsComplete(decl)) partial_levels.add(self.arena, pad.fn_name);
        }
        for (self.inst.electrical) |decl| {
            if (decl.electrical_type == null or thresholdsComplete(decl)) continue;
            partial_levels.add(self.arena, decl.pin);
        }
        if (no_levels.names.items.len > 0) {
            try self.push("control-levels", "profile {s}: control pins with no (electrical …) thresholds, so the driving GPIO cannot be proved to reach them: {s} — close with (electrical \"PIN\" (type input) (v-ih-min V) (v-il-max V) (max-voltage V))", .{ self.key, no_levels.joined(self.arena) });
        }
        if (partial_levels.names.items.len > 0) {
            try self.push("control-levels", "profile {s}: (electrical …) declarations missing their level thresholds (inputs need v-ih-min/v-il-max, outputs v-oh-typ/v-ol-typ): {s}", .{ self.key, partial_levels.joined(self.arena) });
        }
    }

    fn categories(self: Evaluation, class: Class) std.mem.Allocator.Error!void {
        const review = self.inst.docs.review orelse return;
        if (review.status != .complete) return;
        var missing: NameList = .{};
        for (extraCategories(class)) |category| if (!reviewCovers(review, category)) missing.add(self.arena, category);
        if (missing.names.items.len == 0) return;
        try self.push("class-categories", "profile {s}: the datasheet review does not answer the class categories {s} — add (category …) or (category-na … \"why\") entries", .{ self.key, missing.joined(self.arena) });
    }

    fn thermal(self: Evaluation, class: Class) std.mem.Allocator.Error!void {
        if (!requiresThermal(class) or self.inst.thermal.decl != null) return;
        try self.push("thermal-decl", "profile {s}: {s} declares no (thermal (theta-ja …) (tj-max …)), so the thermal screen guesses its package", .{ self.key, self.inst.component });
    }

    fn analysisForm(self: Evaluation, class: Class, forms: Forms) std.mem.Allocator.Error!void {
        switch (formNeed(class)) {
            .none => {},
            .pll_loop => if (!(forms.pll_any and forms.pll_gate)) {
                try self.push("analysis-form", "profile {s}: the design declares {s} — a PLL with an external loop must carry a (pll-loop … (mode gate)) form whose model inputs are cited", .{ self.key, if (forms.pll_any) "its (pll-loop …) in advisory mode" else "no (pll-loop …) form" });
            },
            .frequency_plan => if (!(forms.plan_any and forms.plan_gate)) {
                try self.push("analysis-form", "profile {s}: the design declares {s} — a mixer must carry a (frequency-plan … (mode gate)) form naming the LO drive window and the filters that bound the band", .{ self.key, if (forms.plan_any) "its (frequency-plan …) in advisory mode" else "no (frequency-plan …) form" });
            },
        }
    }
};

/// What the evaluator knows that the profile check needs beyond the instance.
pub const Context = struct {
    block: *const env.DesignBlock,
    project_dir: []const u8,
    forms: Forms = .{},
    /// Demand at least one `(requirement …)` on the part (release strictness).
    require_requirements: bool = false,
    /// Ref-deses that a DESIGN-owned `(requirement … (on "REF") (check …))`
    /// rule judges. A design rule satisfies the demand above exactly as a
    /// library one does: the obligation is that the part is covered by a
    /// cited, executable rule, not that the coverage was inherited.
    design_ruled_refs: []const []const u8 = &.{},
};

/// Evaluate every mechanically visible profile obligation of one placed
/// active part. Messages are owned by `allocator`; scratch lives in `arena`.
/// The returned slice is owned by `allocator` too.
pub fn evaluate(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    inst: env.Instance,
    ctx: Context,
) std.mem.Allocator.Error![]Item {
    var items: std.ArrayList(Item) = .empty;
    errdefer {
        for (items.items) |item| allocator.free(item.message);
        items.deinit(allocator);
    }
    const pads = pin_roles.padFunctions(arena, ctx.project_dir, inst.component);
    const class = declaredClass(inst) orelse inferClass(pads);
    const evaluation = Evaluation{
        .allocator = allocator,
        .arena = arena,
        .inst = inst,
        .pads = pads,
        .key = class.key(),
        .items = &items,
    };
    if (ctx.require_requirements and !env.containsString(ctx.design_ruled_refs, inst.ref_des))
        try evaluation.requirements();
    try evaluation.supply(ctx.block);
    try evaluation.levels();
    try evaluation.categories(class);
    try evaluation.thermal(class);
    try evaluation.analysisForm(class, ctx.forms);
    return try items.toOwnedSlice(allocator);
}

/// Free a slice returned by `evaluate`.
pub fn deinitItems(allocator: std.mem.Allocator, items: []Item) void {
    for (items) |item| allocator.free(item.message);
    allocator.free(items);
}

// ── Tests ─────────────────────────────────────────────────────────────────

fn padsOf(comptime names: []const []const u8, comptime classes: []const pin_roles.PinClass) [names.len]pin_roles.PadFunction {
    var out: [names.len]pin_roles.PadFunction = undefined;
    inline for (names, 0..) |name, i| {
        var id: [4]u8 = undefined;
        const pad = std.fmt.bufPrint(&id, "{d}", .{i + 1}) catch "?";
        out[i] = .{ .pad = pad, .fn_name = name, .class = classes[i] };
    }
    return out;
}

// spec: review-profiles - an authored (class …) wins over pin-name inference and unknown keys are rejected
test "class resolution prefers the authored key" {
    try std.testing.expectEqual(Class.switching_regulator, parseClass("switching-regulator").?);
    try std.testing.expectEqual(Class.pll_loop, parseClass("pll_loop").?);
    try std.testing.expect(parseClass("widget") == null);
    const declared = env.Instance{
        .ref_des = "U1",
        .component = "part",
        .value = "part",
        .footprint = "x",
        .symbol = "x",
        .properties = &.{.{ .key = "class", .value = "mixer" }},
    };
    try std.testing.expectEqual(Class.mixer, declaredClass(declared).?);
    const pads = padsOf(&.{ "VIN", "VOUT", "SET", "GND", "EN" }, &.{ .power, .power, .other, .ground, .strap });
    try std.testing.expectEqual(Class.ldo, inferClass(&pads));
    const mixer = padsOf(&.{ "LO", "RF", "IF", "GND" }, &.{ .other, .other, .other, .ground });
    try std.testing.expectEqual(Class.mixer, inferClass(&mixer));
    try std.testing.expectEqual(Class.generic, inferClass(&.{}));
}

// spec: review-profiles - supply pins without voltage-range and decoupling checks, currents, or control-pin thresholds are named as unmet profile items
test "unmet supply and control obligations become items naming the closing form" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.createDirPath(std.testing.io, "lib/pinouts");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/part.sexp", .data = "(component part (pinout \"part\"))" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/pinouts/part.sexp", .data = "(pinout \"part\" (pin 1 \"VDD\") (pin 2 \"GND\") (pin 3 \"EN\") (pin 4 \"OUT\"))" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const block = env.DesignBlock{
        .name = "b",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const inst = env.Instance{
        .ref_des = "U1",
        .component = "part",
        .value = "part",
        .footprint = "x",
        .symbol = "x",
        .electrical = &.{.{ .pin = "OUT", .electrical_type = .output }},
    };
    const items = try evaluate(allocator, arena.allocator(), inst, .{ .block = &block, .project_dir = root, .require_requirements = true });
    defer deinitItems(allocator, items);
    const expected = [_][]const u8{ "requirements", "supply-voltage-check", "supply-decoupling-check", "supply-current", "control-levels" };
    for (expected) |code| try std.testing.expect(hasCode(items, code));
    // VDD is named in the supply items, EN in the missing-thresholds item and
    // OUT in the incomplete-declaration item.
    try std.testing.expect(mentions(items, "VDD"));
    try std.testing.expect(mentions(items, "EN"));
    try std.testing.expect(mentions(items, "OUT"));
}

fn hasCode(items: []const Item, code: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item.code, code)) return true;
    return false;
}

fn mentions(items: []const Item, needle: []const u8) bool {
    for (items) |item| if (std.mem.indexOf(u8, item.message, needle) != null) return true;
    return false;
}

// spec: review-profiles - a loop or mixer class demands its design-level analysis in gate mode
test "class-bound analysis forms are demanded in gate mode" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const block = env.DesignBlock{
        .name = "b",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const inst = env.Instance{
        .ref_des = "U2",
        .component = "nonexistent-mixer",
        .value = "part",
        .footprint = "x",
        .symbol = "x",
        .properties = &.{.{ .key = "class", .value = "mixer" }},
        .requirements = &.{.{ .text = "x" }},
        .thermal = .{ .decl = .{} },
    };
    const advisory = try evaluate(allocator, arena.allocator(), inst, .{ .block = &block, .project_dir = "/nonexistent", .forms = .{ .plan_any = true, .plan_gate = false } });
    defer deinitItems(allocator, advisory);
    try std.testing.expectEqual(@as(usize, 1), advisory.len);
    try std.testing.expectEqualStrings("analysis-form", advisory[0].code);
    try std.testing.expect(std.mem.indexOf(u8, advisory[0].message, "advisory") != null);
    const gated = try evaluate(allocator, arena.allocator(), inst, .{ .block = &block, .project_dir = "/nonexistent", .forms = .{ .plan_any = true, .plan_gate = true } });
    defer deinitItems(allocator, gated);
    try std.testing.expectEqual(@as(usize, 0), gated.len);
}
