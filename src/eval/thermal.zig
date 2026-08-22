//! Screening-grade steady-state thermal analysis, and the two forms that feed
//! it: the library part's `(thermal …)` envelope and an instance's `(power …)`
//! dissipation.
//!
//! The model is deliberately lumped — one junction temperature per part,
//! `Tj = Ta + P·θJA`, with no coupling between parts and no dependence on the
//! layout. That is what a designer does on paper before committing to a
//! package: it answers "will this part cook in still air, or does the board
//! need airflow / a heatsink", and it answers it from the evaluated
//! `DesignBlock` alone. A board-level verdict and the ambient range the board
//! is good for come out of the same pass. Read-only over the block, like
//! `power_budget` (whose rail machinery this reuses rather than restates).

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const env_mod = @import("env.zig");
const forms = @import("forms.zig");
const na = @import("net_analysis.zig");
const power_budget = @import("power_budget.zig");

const Node = ast.Node;
const DesignBlock = env_mod.DesignBlock;
const ThermalDecl = env_mod.ThermalDecl;
const PowerDecl = env_mod.PowerDecl;

// ── Screening constants ───────────────────────────────────────────────
// Every number here is a screening convention, not physics: the point is a
// consistent, documented yardstick, not a simulation.

/// Ambient the analysis runs at when no caller names one (°C) — bench air.
pub const default_ambient_c: f64 = 25.0;
/// Design margin held below the junction limit (°C). A part is "passively OK"
/// only when it lands this far under `tj_max`, so a screening estimate that is
/// somewhat optimistic still leaves the part inside its rating.
///
/// Public because the LAYOUT-aware ladder (`thermal_scenarios.boardVerdict`)
/// answers the same question about the same parts and must demand the same
/// margin. Two verdicts that disagree because they held different margins would
/// be unreadable; two that disagree because one has a board underneath it and
/// the other does not is the whole point.
pub const derate_c: f64 = 20.0;
/// Junction limit assumed for a part that has power and a θJA but declares no
/// `(tj-max …)` (°C). The near-universal commercial-silicon rating; rows using
/// it are flagged `tj_max_default` so a reader never mistakes it for datasheet
/// data.
const default_tj_max_c: f64 = 125.0;
/// θJA multiplier standing in for ~1 m/s of forced air.
const airflow_theta_scale: f64 = 0.7;
/// θJA multiplier standing in for a modest heatsink (or a deliberate copper
/// pour sized for the part).
const heatsink_theta_scale: f64 = 0.5;
/// Still-air scenario — θJA exactly as declared/estimated.
const passive_theta_scale: f64 = 1.0;
/// Below this the part is not dissipating anything worth a row (W).
const power_epsilon_w: f64 = 1e-12;

// ── The `(thermal …)` grammar ─────────────────────────────────────────

/// One sub-form of a library part's `(thermal …)` declaration. The parser
/// dispatches on this enum and `docgen` renders the reference from the doc
/// table below, so the documented grammar cannot drift from the parser.
pub const ThermalField = enum {
    theta_ja,
    theta_jb,
    theta_jc,
    theta_jc_top,
    theta_jc_bottom,
    psi_jt,
    psi_jb,
    tj_max,
    operating,

    /// Resolve a `(thermal …)` sub-form head atom to its field, or null when
    /// the atom names no field this grammar knows.
    pub fn fromAtom(name: []const u8) ?ThermalField {
        return atom_to_field.get(name);
    }
};

const atom_to_field = std.StaticStringMap(ThermalField).initComptime(.{
    .{ "theta-ja", .theta_ja },
    .{ "theta-jb", .theta_jb },
    .{ "theta-jc", .theta_jc },
    .{ "theta-jc-top", .theta_jc_top },
    .{ "theta-jc-bottom", .theta_jc_bottom },
    .{ "psi-jt", .psi_jt },
    .{ "psi-jb", .psi_jb },
    .{ "tj-max", .tj_max },
    .{ "operating", .operating },
});

/// Reference rows for the `(thermal …)` sub-forms, exhaustive by construction:
/// a new `ThermalField` variant without a row is a compile error.
pub const thermal_field_docs = blk: {
    const N = @typeInfo(ThermalField).@"enum".field_names.len;
    var t: [N]?forms.FormDoc = @splat(null);
    t[@backingInt(ThermalField.theta_ja)] = .{
        .syntax = "(theta-ja C-per-W)",
        .summary = "Junction-to-ambient resistance. Drives `Tj = Ta + P·θJA`; " ++
            "a part that declares none is screened against a package estimate.",
    };
    t[@backingInt(ThermalField.theta_jb)] = .{
        .syntax = "(theta-jb C-per-W)",
        .summary = "Junction-to-board resistance. Recorded for the layout-coupled phase; " ++
            "the lumped analysis does not read it.",
    };
    t[@backingInt(ThermalField.theta_jc)] = .{
        .syntax = "(theta-jc C-per-W)",
        .summary = "Direction-unspecified junction-to-case resistance. Recorded for " ++
            "completeness, but not guessed into a top or bottom heatsink path.",
    };
    t[@backingInt(ThermalField.theta_jc_top)] = .{
        .syntax = "(theta-jc-top C-per-W)",
        .summary = "Junction-to-case resistance through the package top. Drives a " ++
            "package-top heatsink path; do not substitute psi-jt.",
    };
    t[@backingInt(ThermalField.theta_jc_bottom)] = .{
        .syntax = "(theta-jc-bottom C-per-W)",
        .summary = "Junction-to-case resistance through the exposed pad or package bottom. " ++
            "Drives the package-to-board path for backside cold-plate screening.",
    };
    t[@backingInt(ThermalField.psi_jt)] = .{
        .syntax = "(psi-jt C-per-W)",
        .summary = "Junction-to-top characterisation parameter, for correlating a measured " ++
            "case temperature back to the junction. Recorded, not yet consumed.",
    };
    t[@backingInt(ThermalField.psi_jb)] = .{
        .syntax = "(psi-jb C-per-W)",
        .summary = "Junction-to-board characterisation parameter for measurement correlation. " ++
            "Recorded, not treated as a thermal resistance.",
    };
    t[@backingInt(ThermalField.tj_max)] = .{
        .syntax = "(tj-max C)",
        .summary = "Absolute-maximum junction temperature. Undeclared, a part with power " ++
            "and a θJA is screened against 125 °C and the row says so.",
    };
    t[@backingInt(ThermalField.operating)] = .{
        .syntax = "(operating MIN MAX)",
        .summary = "Rated ambient range (°C). Bounds the board's operating window " ++
            "independently of self-heating.",
    };
    break :blk forms.requireAllDocumented(ThermalField, forms.FormDoc, t);
};

/// Parse a library `(thermal (theta-ja 71) (tj-max 125) (operating -40 85) …)`
/// form into a `ThermalDecl`. Every sub-form is optional and unknown sub-forms
/// are ignored for forwards compatibility, but a RECOGNISED sub-form carrying a
/// non-numeric (or, for `operating`, an incomplete) value returns null — an
/// author typo must surface as a warning rather than silently erase the rating
/// the whole analysis rests on.
///
/// `form_children[0]` is the `thermal` head atom.
pub fn parseThermal(form_children: []const Node) ?ThermalDecl {
    if (form_children.len < 2) return null;
    var decl = ThermalDecl{};
    for (form_children[1..]) |sub| {
        const list = sub.asList() orelse continue;
        if (list.len < 2) continue;
        const head = list[0].asAtom() orelse continue;
        const field = ThermalField.fromAtom(head) orelse continue;
        if (!applyThermalField(&decl, field, list)) return null;
    }
    return decl;
}

/// Write one parsed sub-form onto `decl`; false ⇒ the value was malformed.
fn applyThermalField(decl: *ThermalDecl, field: ThermalField, list: []const Node) bool {
    switch (field) {
        .operating => {
            if (list.len < 3) return false;
            decl.operating_min = list[1].asNumber() orelse return false;
            decl.operating_max = list[2].asNumber() orelse return false;
        },
        .theta_ja => decl.theta_ja = list[1].asNumber() orelse return false,
        .theta_jb => decl.theta_jb = list[1].asNumber() orelse return false,
        .theta_jc => decl.theta_jc.generic = list[1].asNumber() orelse return false,
        .theta_jc_top => decl.theta_jc.top = list[1].asNumber() orelse return false,
        .theta_jc_bottom => decl.theta_jc.bottom = list[1].asNumber() orelse return false,
        .psi_jt => decl.psi.jt = list[1].asNumber() orelse return false,
        .psi_jb => decl.psi.jb = list[1].asNumber() orelse return false,
        .tj_max => decl.tj_max = list[1].asNumber() orelse return false,
    }
    return true;
}

/// Reference row for the instance-scope `(power …)` form. Lives beside the
/// parser for the same reason the `(thermal …)` rows do: the documented shape
/// and the accepted shape are one table.
pub const power_form_doc: forms.FormDoc = .{
    .syntax = "(power WATTS | (typ WATTS) (max WATTS))",
    .summary = "Declare what this instance dissipates. Outranks every derived figure — " ++
        "a pin-current rollup and a regulator's back-computed conversion loss both yield to it.",
};

/// Parse an instance's `(power 1.2)` or `(power (typ 0.8) (max 1.5))` into a
/// `PowerDecl`. Null when the form carries neither a bare number nor at least
/// one well-formed `(typ …)` / `(max …)` pair, so the call site can warn
/// instead of recording a declaration the author did not make.
///
/// `form_children[0]` is the `power` head atom.
pub fn parsePower(form_children: []const Node) ?PowerDecl {
    if (form_children.len < 2) return null;
    if (form_children[1].asNumber()) |watts| return .{ .typ = watts };

    var decl = PowerDecl{};
    var any = false;
    for (form_children[1..]) |sub| {
        const list = sub.asList() orelse continue;
        if (list.len < 2) continue;
        const head = list[0].asAtom() orelse continue;
        const watts = list[1].asNumber() orelse return null;
        if (std.mem.eql(u8, head, "typ")) {
            decl.typ = watts;
            any = true;
        } else if (std.mem.eql(u8, head, "max")) {
            decl.max = watts;
            any = true;
        }
    }
    return if (any) decl else null;
}

// ── Package θJA estimates ─────────────────────────────────────────────

/// One package-name hint and the θJA to assume for it.
const PackageTheta = struct { hint: []const u8, theta_ja: f64 };

/// Junction-to-ambient estimates by package, keyed on a case-insensitive
/// substring of the footprint name and searched in order, so the most specific
/// hint wins (`soic-8-ep` before `soic-8`). Every figure is a rounded
/// JEDEC-2s2p screening estimate — the number a datasheet quotes for a
/// four-layer board with no airflow — and none of them is a substitute for the
/// part's own `(thermal (theta-ja …))`. A row screened against one of these is
/// flagged `theta_estimated`.
const package_theta_defaults = [_]PackageTheta{
    .{ .hint = "soic-8-ep", .theta_ja = 50 },
    .{ .hint = "msop-8-ep", .theta_ja = 55 },
    .{ .hint = "tssop-ep", .theta_ja = 40 },
    .{ .hint = "sot-23-5", .theta_ja = 190 },
    .{ .hint = "sot-223", .theta_ja = 60 },
    .{ .hint = "soic-14", .theta_ja = 90 },
    .{ .hint = "soic-16", .theta_ja = 90 },
    .{ .hint = "to-252", .theta_ja = 30 },
    .{ .hint = "to-263", .theta_ja = 25 },
    .{ .hint = "sot-23", .theta_ja = 200 },
    .{ .hint = "sot-89", .theta_ja = 80 },
    .{ .hint = "d2pak", .theta_ja = 25 },
    .{ .hint = "soic-8", .theta_ja = 110 },
    .{ .hint = "msop-8", .theta_ja = 170 },
    .{ .hint = "qfn-ep", .theta_ja = 45 },
    .{ .hint = "tssop", .theta_ja = 100 },
    .{ .hint = "sc-70", .theta_ja = 250 },
    .{ .hint = "dpak", .theta_ja = 30 },
    .{ .hint = "lqfp", .theta_ja = 55 },
    .{ .hint = "tqfp", .theta_ja = 55 },
    .{ .hint = "wson", .theta_ja = 55 },
    .{ .hint = "qfn", .theta_ja = 65 },
    .{ .hint = "dfn", .theta_ja = 60 },
    .{ .hint = "bga", .theta_ja = 40 },
};

/// θJA estimate for a footprint name, or null when no package hint matches.
/// First match in `package_theta_defaults` wins and that table is ordered
/// most-specific-first, so the answer is deterministic for any footprint.
pub fn packageTheta(footprint: []const u8) ?f64 {
    for (package_theta_defaults) |entry| {
        if (containsIgnoreCase(footprint, entry.hint)) return entry.theta_ja;
    }
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ── Result types ──────────────────────────────────────────────────────

/// Where a part's dissipation figure came from. The ladder is ordered: an
/// authored watt figure beats a current-annotation rollup, which beats a
/// regulator's back-computed conversion loss.
pub const PowerSource = enum { explicit, pin_annotations, regulator_loss, none };

/// What a part dissipates, and on whose authority.
pub const PartPower = struct {
    /// Typical dissipation (W). Null ⇒ nothing to compute a rise from.
    watts: ?f64 = null,
    source: PowerSource = .none,
};

/// The junction-to-ambient resistance the part was screened with, and the
/// junction-to-board resistance the layout-aware field will screen it with.
pub const PartTheta = struct {
    /// °C/W. Null ⇒ neither the part nor its package name gave one.
    ja: ?f64 = null,
    /// Junction-to-board resistance (°C/W) from the library part's own
    /// `(thermal (theta-jb …))`. Null ⇒ never declared. This analysis does not
    /// use it — a lumped screen has no board to be above — but it is the figure
    /// `placement/thermal_field.zig` hangs a junction off the copper under the
    /// part with, so it is carried here rather than re-read from the instance
    /// by every surface that wants a field.
    jb: ?f64 = null,
    jc: struct {
        generic: ?f64 = null,
        /// Junction-to-case through the package top (°C/W).
        top: ?f64 = null,
        /// Junction-to-case through the exposed pad / package bottom (°C/W).
        bottom: ?f64 = null,
    } = .{},
    /// Measurement-correlation parameters, preserved separately because psi
    /// values are not heat-flow resistances.
    psi: struct { jt: ?f64 = null, jb: ?f64 = null } = .{},
    /// True when `ja` came from `package_theta_defaults` rather than from the
    /// part's own `(thermal (theta-ja …))`. Never says anything about `jb`,
    /// which is only ever the declared figure.
    estimated: bool = false,
};

/// The part's declared (or assumed) temperature limits.
pub const PartLimits = struct {
    /// Absolute-maximum junction temperature (°C).
    tj_max: ?f64 = null,
    /// True when `tj_max` is the assumed 125 °C rather than a declared figure.
    tj_max_default: bool = false,
    /// Rated ambient range (°C) from `(operating MIN MAX)`.
    operating_min_c: ?f64 = null,
    operating_max_c: ?f64 = null,
};

/// The computed screening numbers for one part at the analysis ambient.
pub const PartResult = struct {
    /// Self-heating above ambient, `P·θJA` (°C).
    rise_c: ?f64 = null,
    /// Junction temperature at the analysis ambient (°C).
    tj_at_ambient: ?f64 = null,
    /// Headroom to the junction limit, `tj_max − tj_at_ambient` (°C). Negative
    /// means the part is over its rating already.
    margin_c: ?f64 = null,
    /// Highest ambient this part alone tolerates, `tj_max − rise_c` (°C).
    max_ambient_c: ?f64 = null,
};

/// One part's thermal row. Split into four small records rather than a flat
/// wall of fields: a reader wants "what does it burn", "what package", "what
/// are its limits", "what came out", and each group travels together.
pub const PartThermal = struct {
    /// Ref-des, prefixed with its `sub-block/` path when the part sits inside
    /// a module — the same spelling the flattened netlist uses.
    ref_des: []const u8,
    component: []const u8,
    power: PartPower = .{},
    theta: PartTheta = .{},
    limits: PartLimits = .{},
    result: PartResult = .{},
};

/// The board-level answer. `passive_ok` needs no help; `needs_airflow` /
/// `needs_heatsink` name the least intervention that brings every powered part
/// under its derated limit; `over_limit` means even a heatsink does not;
/// `insufficient_data` means no part had both a dissipation and a θJA.
pub const Verdict = enum { passive_ok, needs_airflow, needs_heatsink, insufficient_data, over_limit };

/// One end of the board's ambient window, and the part that sets it.
pub const AmbientLimit = struct {
    c: ?f64 = null,
    ref_des: []const u8 = "",
};

/// How many of the listed rows carry what. Counts describe `BoardThermal.parts`
/// — the rows worth showing — not every instance in the design.
pub const PartCounts = struct {
    with_power: usize = 0,
    with_thermal: usize = 0,
    unknown_power: usize = 0,
};

/// The whole analysis: every interesting part, the verdict, and the ambient
/// window the board is good for.
pub const BoardThermal = struct {
    /// Ambient the per-part junction temperatures were computed at (°C).
    ambient_c: f64,
    /// Parts that dissipate something or declare thermal data, in design order.
    parts: []const PartThermal = &.{},
    verdict: Verdict = .insufficient_data,
    /// The part the verdict hangs on — the smallest headroom in still air.
    limiting_ref: []const u8 = "",
    /// Highest ambient the whole board tolerates, and who limits it.
    max_ambient: AmbientLimit = .{},
    /// Lowest ambient the whole board tolerates (a ratings question — cold
    /// never causes self-heating trouble), and who limits it.
    min_ambient: AmbientLimit = .{},
    counts: PartCounts = .{},
};

// ── Analysis ──────────────────────────────────────────────────────────

/// Analyze `block` at `ambient_c` and return one row per part that dissipates
/// something or declares `(thermal …)` data, plus the board-level verdict and
/// ambient window. Sub-blocks are walked too, each row's ref carrying its
/// `sub-block/` path. The returned rows are owned by the caller's allocator and
/// borrow their strings from the block.
pub fn analyze(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    ambient_c: f64,
) std.mem.Allocator.Error!BoardThermal {
    var rows: std.ArrayList(PartThermal) = .empty;
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    try collectBlock(allocator, block, "", &rows, &index);
    try addRegulatorLoss(allocator, block, "", &rows, &index);

    for (rows.items) |*row| finishRow(row, ambient_c);

    var listed: std.ArrayList(PartThermal) = .empty;
    for (rows.items) |row| {
        if (isListed(row)) try listed.append(allocator, row);
    }
    const parts = try listed.toOwnedSlice(allocator);
    return .{
        .ambient_c = ambient_c,
        .parts = parts,
        .verdict = verdictFor(parts),
        .limiting_ref = limitingRef(parts),
        .max_ambient = maxAmbient(parts),
        .min_ambient = minAmbient(parts),
        .counts = countRows(parts),
    };
}

/// A row is worth showing when it burns something or when the library says
/// anything about its thermals. Without this every bypass cap would be a row.
fn isListed(row: PartThermal) bool {
    if (row.power.watts) |w| {
        if (w > power_epsilon_w) return true;
    }
    return row.theta.ja != null or row.limits.tj_max != null or
        row.limits.operating_min_c != null or row.limits.operating_max_c != null;
}

/// Append one row per instance of `block` (recursing sub-blocks), with the
/// first two rungs of the power ladder already resolved: an explicit
/// `(power …)`, else the part's annotated pin currents against their rails.
fn collectBlock(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    prefix: []const u8,
    rows: *std.ArrayList(PartThermal),
    index: *std.StringHashMapUnmanaged(usize),
) std.mem.Allocator.Error!void {
    var annotated = try pinAnnotationPower(allocator, block);
    defer annotated.deinit(allocator);

    for (block.instances) |inst| {
        const ref = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, inst.ref_des });
        var row = PartThermal{ .ref_des = ref, .component = inst.component };
        row.power = instancePower(inst, annotated.get(inst.ref_des));
        row.theta = thetaFor(inst);
        row.limits = limitsFor(inst);
        try index.put(allocator, ref, rows.items.len);
        try rows.append(allocator, row);
    }

    for (block.sub_blocks) |sb| {
        const child_prefix = try std.fmt.allocPrint(allocator, "{s}{s}/", .{ prefix, sb.name });
        try collectBlock(allocator, sb.block, child_prefix, rows, index);
    }
}

/// The first two rungs of the ladder for one instance.
fn instancePower(inst: env_mod.Instance, annotated: ?f64) PartPower {
    if (inst.thermal.power) |decl| {
        if (decl.typ orelse decl.max) |watts| return .{ .watts = watts, .source = .explicit };
    }
    if (annotated) |watts| {
        if (watts > power_epsilon_w) return .{ .watts = watts, .source = .pin_annotations };
    }
    return .{};
}

/// The part's thermal resistances. θJA is the screening figure this analysis
/// uses (declared, else estimated from the package name); θJB is carried
/// through untouched for the layout-aware field, and a part may well declare
/// one and not the other.
fn thetaFor(inst: env_mod.Instance) PartTheta {
    const declared = inst.thermal.decl orelse {
        if (packageTheta(inst.footprint)) |ja| return .{ .ja = ja, .estimated = true };
        return .{};
    };
    const extra: PartTheta = .{
        .jb = declared.theta_jb,
        .jc = .{ .generic = declared.theta_jc.generic, .top = declared.theta_jc.top, .bottom = declared.theta_jc.bottom },
        .psi = .{ .jt = declared.psi.jt, .jb = declared.psi.jb },
    };
    if (inst.thermal.decl) |decl| {
        if (decl.theta_ja) |ja| return .{
            .ja = ja,
            .jb = extra.jb,
            .jc = extra.jc,
            .psi = extra.psi,
        };
    }
    if (packageTheta(inst.footprint)) |ja| return .{
        .ja = ja,
        .jb = extra.jb,
        .jc = extra.jc,
        .psi = extra.psi,
        .estimated = true,
    };
    return extra;
}

fn limitsFor(inst: env_mod.Instance) PartLimits {
    const decl = inst.thermal.decl orelse return .{};
    return .{
        .tj_max = decl.tj_max,
        .operating_min_c = decl.operating_min,
        .operating_max_c = decl.operating_max,
    };
}

/// Consumer-side dissipation per ref-des: every annotated `(i-typ …)` pin,
/// multiplied by the voltage its rail resolves to. A rail with no resolvable
/// voltage contributes nothing (and neither does a ground return, which never
/// resolves to one), so the figure is an approximation that only ever
/// understates — which is what makes it a screening input and not a budget.
fn pinAnnotationPower(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
) std.mem.Allocator.Error!std.StringHashMapUnmanaged(f64) {
    var out: std.StringHashMapUnmanaged(f64) = .empty;
    for (block.nets) |net| {
        const volts = power_budget.resolveRailVoltage(allocator, block, na.baseNetName(net.name)) orelse continue;
        if (volts <= 0) continue;
        for (net.pins) |pin| {
            const amps = pin.i_typ orelse continue;
            if (pin.ref_des.len == 0) continue;
            const prev = out.get(pin.ref_des) orelse 0;
            try out.put(allocator, pin.ref_des, prev + amps * volts);
        }
    }
    return out;
}

/// Third rung of the ladder: a regulator's conversion loss, `Vin·Iin −
/// Vout·Iout`, taken from the very rails `power_budget` already back-computed
/// (its input-side consumer row IS `Iin`). Attributed to the module's single
/// hub IC when it has one, else to a row named after the sub-block, and only
/// when that row has no power from a higher rung.
fn addRegulatorLoss(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    prefix: []const u8,
    rows: *std.ArrayList(PartThermal),
    index: *std.StringHashMapUnmanaged(usize),
) std.mem.Allocator.Error!void {
    const rails = try power_budget.analyze(allocator, block);
    for (block.sub_blocks) |sb| {
        const loss = regulatorLoss(allocator, block, rails, sb) orelse continue;
        const hub = hubRef(sb);
        const ref = if (hub.len > 0)
            try std.fmt.allocPrint(allocator, "{s}{s}/{s}", .{ prefix, sb.name, hub })
        else
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, sb.name });
        try chargeLoss(allocator, ref, loss, rows, index);
    }
    for (block.sub_blocks) |sb| {
        const child_prefix = try std.fmt.allocPrint(allocator, "{s}{s}/", .{ prefix, sb.name });
        try addRegulatorLoss(allocator, sb.block, child_prefix, rows, index);
    }
}

/// Record `watts` on `ref`'s row (creating one for a module that has no single
/// hub to hang it on). A row that already has power from a higher rung keeps it.
fn chargeLoss(
    allocator: std.mem.Allocator,
    ref: []const u8,
    watts: f64,
    rows: *std.ArrayList(PartThermal),
    index: *std.StringHashMapUnmanaged(usize),
) std.mem.Allocator.Error!void {
    if (index.get(ref)) |i| {
        if (rows.items[i].power.watts != null) return;
        rows.items[i].power = .{ .watts = watts, .source = .regulator_loss };
        return;
    }
    try index.put(allocator, ref, rows.items.len);
    try rows.append(allocator, .{
        .ref_des = ref,
        .component = "",
        .power = .{ .watts = watts, .source = .regulator_loss },
    });
}

/// The module's single U-prefixed instance — the part that actually burns the
/// conversion loss. "" when the module has none or several, in which case the
/// loss is reported against the sub-block itself rather than guessed onto a
/// part.
fn hubRef(sb: env_mod.SubBlock) []const u8 {
    var hub: []const u8 = "";
    for (sb.block.instances) |inst| {
        if (inst.ref_des.len == 0 or inst.ref_des[0] != 'U') continue;
        if (hub.len > 0) return "";
        hub = inst.ref_des;
    }
    return hub;
}

/// Conversion loss of one efficiency-declaring sub-block (W), or null when any
/// term is missing. Both currents come from `power_budget`'s own rails, so the
/// two analyses can never disagree about what the regulator carries.
fn regulatorLoss(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    rails: []const power_budget.Rail,
    sb: env_mod.SubBlock,
) ?f64 {
    for (sb.block.ports) |port| {
        if (!std.mem.eql(u8, port.direction, "out")) continue;
        if (port.efficiency == null and !port.efficiency_linear) continue;
        const vout = port.nominal orelse continue;
        const iout = outputCurrent(allocator, block, rails, sb.name, port.name) orelse continue;
        const loss = converterLoss(allocator, .{ .block = block, .rails = rails, .sb = sb }, port, vout * iout) orelse continue;
        if (loss > power_epsilon_w) return loss;
    }
    return null;
}

/// What one `regulatorLoss` question is asked against — bundled so the helper
/// below takes the board, not six arguments.
const RegulatorCtx = struct {
    block: *const DesignBlock,
    rails: []const power_budget.Rail,
    sb: env_mod.SubBlock,
};

/// The heat a converter delivering `pout` watts throws off, or null when
/// nothing declared enough to say.
///
/// The exact form is `Vin·Iin − Pout`, which needs the input rail's voltage and
/// the draw `power_budget` back-computed on it. When that rail's voltage is
/// undeclared — a board whose input supply arrives on a connector rather than
/// from a regulator that names it — a SCALAR efficiency still states the answer
/// on its own: `P_diss = Pout·(1/η − 1)`, with the input voltage cancelling
/// out. A LINEAR regulator gets no such fallback, because its dissipation IS
/// `(Vin − Vout)·I`: with no input voltage there is nothing to compute, and
/// guessing one would misreport the hottest class of part on the board.
fn converterLoss(
    allocator: std.mem.Allocator,
    ctx: RegulatorCtx,
    port: env_mod.Port,
    pout: f64,
) ?f64 {
    if (inputDraw(allocator, ctx.block, ctx.rails, ctx.sb.name)) |input| {
        return input.volts * input.amps - pout;
    }
    if (port.efficiency_linear) return null;
    const eta = port.efficiency orelse return null;
    if (eta <= 0 or eta >= 1) return null;
    return pout * (1.0 / eta - 1.0);
}

/// Typical load on the rail this sub-block's output port sources (A). The port
/// is resolved to its top-level rail name through the block's own net ties —
/// not through the rail's `source_label`, which exists only for a port that
/// also declared a current capacity.
fn outputCurrent(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    rails: []const power_budget.Rail,
    sb_name: []const u8,
    port_name: []const u8,
) ?f64 {
    const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ sb_name, port_name }) catch return null;
    defer allocator.free(path);
    const rail_name = power_budget.railNameForSubPath(block, path) orelse return null;
    for (rails) |rail| {
        if (!std.mem.eql(u8, rail.net, rail_name)) continue;
        if (!rail.any_typ_load) return null;
        return rail.load_typ_a;
    }
    return null;
}

/// What the regulator draws from its input rail: the current `power_budget`
/// back-computed for it, and that rail's voltage.
fn inputDraw(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    rails: []const power_budget.Rail,
    sb_name: []const u8,
) ?struct { volts: f64, amps: f64 } {
    for (rails) |rail| {
        for (rail.consumers) |consumer| {
            if (!std.mem.eql(u8, consumer.ref_des, sb_name)) continue;
            const amps = consumer.i_typ orelse continue;
            const volts = power_budget.resolveRailVoltage(allocator, block, rail.net) orelse continue;
            return .{ .volts = volts, .amps = amps };
        }
    }
    return null;
}

/// Fill in a row's computed numbers once its power, θJA and limits are known.
fn finishRow(row: *PartThermal, ambient_c: f64) void {
    const watts = row.power.watts orelse return;
    const theta = row.theta.ja orelse return;
    if (row.limits.tj_max == null) {
        row.limits.tj_max = default_tj_max_c;
        row.limits.tj_max_default = true;
    }
    const tj_max = row.limits.tj_max.?;
    const rise = watts * theta;
    row.result = .{
        .rise_c = rise,
        .tj_at_ambient = ambient_c + rise,
        .margin_c = tj_max - (ambient_c + rise),
        .max_ambient_c = tj_max - rise,
    };
}

/// True when the row has both a dissipation and a θJA — the only rows a
/// verdict can be computed from.
fn isPowered(row: PartThermal) bool {
    return row.result.rise_c != null;
}

/// Headroom to the derated limit at a θJA scaled by `scale` (°C). Positive ⇒
/// the part passes that scenario.
fn headroom(row: PartThermal, ambient_c: f64, scale: f64) f64 {
    const tj_max = row.limits.tj_max orelse default_tj_max_c;
    const rise = (row.result.rise_c orelse 0) * scale;
    return tj_max - derate_c - (ambient_c + rise);
}

/// The least intervention under which every powered part clears its derated
/// limit.
fn verdictFor(parts: []const PartThermal) Verdict {
    var any = false;
    for (parts) |row| {
        if (isPowered(row)) any = true;
    }
    if (!any) return .insufficient_data;

    const ladder = [_]struct { scale: f64, verdict: Verdict }{
        .{ .scale = passive_theta_scale, .verdict = .passive_ok },
        .{ .scale = airflow_theta_scale, .verdict = .needs_airflow },
        .{ .scale = heatsink_theta_scale, .verdict = .needs_heatsink },
    };
    for (ladder) |rung| {
        if (allPass(parts, rung.scale)) return rung.verdict;
    }
    return .over_limit;
}

fn allPass(parts: []const PartThermal, scale: f64) bool {
    for (parts) |row| {
        if (!isPowered(row)) continue;
        // `tj_at_ambient` already holds the ambient, so subtracting the
        // unscaled rise back out recovers it without carrying it separately.
        const ambient = (row.result.tj_at_ambient orelse 0) - (row.result.rise_c orelse 0);
        if (headroom(row, ambient, scale) < 0) return false;
    }
    return true;
}

/// The powered part with the least still-air headroom — the one the verdict
/// hangs on. "" when nothing is powered.
fn limitingRef(parts: []const PartThermal) []const u8 {
    var worst: ?f64 = null;
    var ref: []const u8 = "";
    for (parts) |row| {
        const margin = row.result.margin_c orelse continue;
        if (worst == null or margin < worst.?) {
            worst = margin;
            ref = row.ref_des;
        }
    }
    return ref;
}

/// Highest ambient the board tolerates: the tightest of every powered part's
/// `tj_max − rise` and every declared `(operating … MAX)`.
fn maxAmbient(parts: []const PartThermal) AmbientLimit {
    var limit = AmbientLimit{};
    for (parts) |row| {
        if (row.result.max_ambient_c) |c| takeLower(&limit, c, row.ref_des);
        if (row.limits.operating_max_c) |c| takeLower(&limit, c, row.ref_des);
    }
    return limit;
}

/// Lowest ambient the board tolerates: the highest declared `(operating MIN …)`.
/// Self-heating only helps in the cold, so this is purely a ratings question.
fn minAmbient(parts: []const PartThermal) AmbientLimit {
    var limit = AmbientLimit{};
    for (parts) |row| {
        const c = row.limits.operating_min_c orelse continue;
        if (limit.c == null or c > limit.c.?) limit = .{ .c = c, .ref_des = row.ref_des };
    }
    return limit;
}

fn takeLower(limit: *AmbientLimit, c: f64, ref_des: []const u8) void {
    if (limit.c == null or c < limit.c.?) limit.* = .{ .c = c, .ref_des = ref_des };
}

fn countRows(parts: []const PartThermal) PartCounts {
    var counts = PartCounts{};
    for (parts) |row| {
        if (row.power.watts != null) counts.with_power += 1 else counts.unknown_power += 1;
        if (!row.theta.estimated and row.theta.ja != null) counts.with_thermal += 1;
    }
    return counts;
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;
const parser_mod = @import("../sexpr/parser.zig");

/// Parse one S-expression form out of `src` for the grammar tests.
fn parseForm(arena: std.mem.Allocator, src: []const u8) ![]const Node {
    const nodes = try parser_mod.parse(arena, src);
    return nodes[0].asList() orelse error.TestUnexpectedResult;
}

// spec: eval/thermal - the library (thermal …) form records theta-ja, theta-jb, psi-jt, tj-max and the rated ambient range
test "thermal form parses every declared field" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const form = try parseForm(arena, "(thermal (theta-ja 71) (theta-jb 12) (theta-jc 9) (theta-jc-top 8) (theta-jc-bottom 1.5) (psi-jt 2) (psi-jb 6) (tj-max 150) (operating -40 85))");
    const decl = parseThermal(form).?;
    try testing.expectEqual(@as(f64, 71), decl.theta_ja.?);
    try testing.expectEqual(@as(f64, 12), decl.theta_jb.?);
    try testing.expectEqual(@as(f64, 9), decl.theta_jc.generic.?);
    try testing.expectEqual(@as(f64, 8), decl.theta_jc.top.?);
    try testing.expectEqual(@as(f64, 1.5), decl.theta_jc.bottom.?);
    try testing.expectEqual(@as(f64, 2), decl.psi.jt.?);
    try testing.expectEqual(@as(f64, 6), decl.psi.jb.?);
    try testing.expectEqual(@as(f64, 150), decl.tj_max.?);
    try testing.expectEqual(@as(f64, -40), decl.operating_min.?);
    try testing.expectEqual(@as(f64, 85), decl.operating_max.?);
}

// spec: eval/thermal - a malformed or empty (thermal …) sub-form value is rejected whole rather than recorded as a partial rating
test "thermal form rejects a corrupted value and an empty body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(parseThermal(try parseForm(arena, "(thermal (theta-ja \"hot\"))")) == null);
    try testing.expect(parseThermal(try parseForm(arena, "(thermal (operating -40))")) == null);
    try testing.expect(parseThermal(try parseForm(arena, "(thermal)")) == null);
    // An unknown sub-form is forwards compatibility, not corruption.
    const decl = parseThermal(try parseForm(arena, "(thermal (theta-ja 40) (theta-xx 9))")).?;
    try testing.expectEqual(@as(f64, 40), decl.theta_ja.?);
}

// spec: eval/thermal - (power W) and (power (typ W) (max W)) both declare an instance's dissipation in watts
test "power form parses the scalar and the typ/max shapes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const scalar = parsePower(try parseForm(arena, "(power 1.2)")).?;
    try testing.expectEqual(@as(f64, 1.2), scalar.typ.?);
    try testing.expect(scalar.max == null);

    const pair = parsePower(try parseForm(arena, "(power (typ 0.8) (max 1.5))")).?;
    try testing.expectEqual(@as(f64, 0.8), pair.typ.?);
    try testing.expectEqual(@as(f64, 1.5), pair.max.?);

    try testing.expect(parsePower(try parseForm(arena, "(power)")) == null);
    try testing.expect(parsePower(try parseForm(arena, "(power (typ \"lots\"))")) == null);
}

/// A block over CALLER-OWNED instances for the analyzer tests — the slice stays
/// the caller's frame, so no helper hands back a block pointing at a dead one.
fn blockOver(insts: []const env_mod.Instance) DesignBlock {
    return .{
        .name = "t",
        .instances = insts,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
}

// spec: eval/thermal - a part's dissipation comes from its explicit (power …) ahead of any pin-current rollup
test "explicit power outranks the pin-annotation rollup" {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inst = env_mod.Instance{
        .ref_des = "U1",
        .component = "reg",
        .value = "",
        .footprint = "SOIC-8",
        .symbol = "",
        .thermal = .{ .power = .{ .typ = 0.5 } },
    };
    const insts = [_]env_mod.Instance{inst};
    var block = blockOver(&insts);
    block.nets = &.{.{ .name = "V3P3", .pins = &.{.{ .ref_des = "U1", .pin = "1", .i_typ = 0.1 }} }};
    block.ports = &.{.{ .name = "V3P3", .net = "V3P3", .direction = "in", .nominal = 3.3 }};

    const result = try analyze(arena, &block, default_ambient_c);
    try testing.expectEqual(@as(usize, 1), result.parts.len);
    try testing.expectEqual(PowerSource.explicit, result.parts[0].power.source);
    try testing.expectEqual(@as(f64, 0.5), result.parts[0].power.watts.?);
}

// spec: eval/thermal - a part with no declared power draws its dissipation from its annotated pin currents times the resolved rail voltage
test "pin-annotation rollup derives dissipation from rail voltage" {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const inst = env_mod.Instance{
        .ref_des = "U1",
        .component = "mcu",
        .value = "",
        .footprint = "LQFP-64",
        .symbol = "",
    };
    const insts = [_]env_mod.Instance{inst};
    var block = blockOver(&insts);
    block.nets = &.{.{ .name = "V3P3", .pins = &.{.{ .ref_des = "U1", .pin = "1", .i_typ = 0.2 }} }};
    block.ports = &.{.{ .name = "V3P3", .net = "V3P3", .direction = "in", .nominal = 3.3 }};

    const result = try analyze(arena, &block, default_ambient_c);
    try testing.expectEqual(PowerSource.pin_annotations, result.parts[0].power.source);
    try testing.expectApproxEqAbs(@as(f64, 0.66), result.parts[0].power.watts.?, 1e-9);
    // 0.66 W into the LQFP estimate (55 °C/W) is a 36.3 °C rise over 25 °C.
    try testing.expectApproxEqAbs(@as(f64, 61.3), result.parts[0].result.tj_at_ambient.?, 1e-9);
}

// spec: eval/thermal - a part with no declared theta-ja is screened against a package estimate and the row says the figure was estimated
test "package theta table fills in an undeclared theta-ja" {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Most specific hint wins, and matching ignores case.
    try testing.expectEqual(@as(f64, 50), packageTheta("SOIC-8-EP_3.9x4.9mm").?);
    try testing.expectEqual(@as(f64, 110), packageTheta("SOIC-8_3.9x4.9mm").?);
    try testing.expectEqual(@as(f64, 190), packageTheta("SOT-23-5").?);
    try testing.expectEqual(@as(f64, 200), packageTheta("SOT-23").?);
    try testing.expect(packageTheta("C_0402_1005Metric") == null);

    const declared = env_mod.Instance{
        .ref_des = "U1",
        .component = "reg",
        .value = "",
        .footprint = "SOT-23-5",
        .symbol = "",
        .thermal = .{ .decl = .{ .theta_ja = 100 }, .power = .{ .typ = 0.1 } },
    };
    const declared_insts = [_]env_mod.Instance{declared};
    var block = blockOver(&declared_insts);
    var result = try analyze(arena, &block, default_ambient_c);
    try testing.expectEqual(@as(f64, 100), result.parts[0].theta.ja.?);
    try testing.expect(!result.parts[0].theta.estimated);

    var undeclared = declared;
    undeclared.thermal = .{ .power = .{ .typ = 0.1 } };
    const undeclared_insts = [_]env_mod.Instance{undeclared};
    block = blockOver(&undeclared_insts);
    result = try analyze(arena, &block, default_ambient_c);
    try testing.expectEqual(@as(f64, 190), result.parts[0].theta.ja.?);
    try testing.expect(result.parts[0].theta.estimated);
    try testing.expect(result.parts[0].limits.tj_max_default);
}

// spec: eval/thermal - a screened row carries the part's declared theta-jb untouched beside its theta-ja, whether or not the theta-ja itself had to be estimated
test "the screened row carries a declared theta-jb through" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Both declared: each figure is the part's own, and nothing is estimated.
    const both = [_]env_mod.Instance{.{
        .ref_des = "U1",
        .component = "reg",
        .value = "",
        .footprint = "SOT-23-5",
        .symbol = "",
        .thermal = .{ .decl = .{ .theta_ja = 100, .theta_jb = 12 }, .power = .{ .typ = 0.1 } },
    }};
    var block = blockOver(&both);
    var result = try analyze(arena, &block, default_ambient_c);
    try testing.expectEqual(@as(f64, 100), result.parts[0].theta.ja.?);
    try testing.expectEqual(@as(f64, 12), result.parts[0].theta.jb.?);
    try testing.expect(!result.parts[0].theta.estimated);

    // θJB declared and θJA not: the package estimate fills the screening figure
    // in and the declared θJB still rides along untouched.
    var jb_only = both[0];
    jb_only.thermal = .{ .decl = .{ .theta_jb = 12 }, .power = .{ .typ = 0.1 } };
    const jb_insts = [_]env_mod.Instance{jb_only};
    block = blockOver(&jb_insts);
    result = try analyze(arena, &block, default_ambient_c);
    try testing.expectEqual(@as(f64, 190), result.parts[0].theta.ja.?);
    try testing.expect(result.parts[0].theta.estimated);
    try testing.expectEqual(@as(f64, 12), result.parts[0].theta.jb.?);

    // Nothing declared at all: no θJB is invented from the package estimate.
    var neither = both[0];
    neither.thermal = .{ .power = .{ .typ = 0.1 } };
    const neither_insts = [_]env_mod.Instance{neither};
    block = blockOver(&neither_insts);
    result = try analyze(arena, &block, default_ambient_c);
    try testing.expect(result.parts[0].theta.jb == null);
}

/// A single hot part, at `watts` into `theta` °C/W with the assumed 125 °C
/// junction limit.
fn hotPart(watts: f64, theta: f64) env_mod.Instance {
    return .{
        .ref_des = "U1",
        .component = "reg",
        .value = "",
        .footprint = "",
        .symbol = "",
        .thermal = .{ .decl = .{ .theta_ja = theta }, .power = .{ .typ = watts } },
    };
}

// spec: eval/thermal - the board verdict is the least intervention (still air, airflow, heatsink) under which every powered part clears its derated junction limit
test "verdict ladder walks passive, airflow, heatsink and over-limit" {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 1 W × 50 °C/W = 50 °C rise → 75 °C junction, inside 125 − 20.
    const cool = [_]env_mod.Instance{hotPart(1.0, 50)};
    var block = blockOver(&cool);
    try testing.expectEqual(Verdict.passive_ok, (try analyze(arena, &block, default_ambient_c)).verdict);

    // 1 W × 90 °C/W = 115 °C → over 105 still, under it with 0.7× airflow.
    const warm = [_]env_mod.Instance{hotPart(1.0, 90)};
    block = blockOver(&warm);
    const result = try analyze(arena, &block, default_ambient_c);
    try testing.expectEqual(Verdict.needs_airflow, result.verdict);
    try testing.expectEqualStrings("U1", result.limiting_ref);

    // 1 W × 120 °C/W needs the 0.5× heatsink scenario.
    const hot = [_]env_mod.Instance{hotPart(1.0, 120)};
    block = blockOver(&hot);
    try testing.expectEqual(Verdict.needs_heatsink, (try analyze(arena, &block, default_ambient_c)).verdict);

    // 1 W × 250 °C/W is past every scenario.
    const scorching = [_]env_mod.Instance{hotPart(1.0, 250)};
    block = blockOver(&scorching);
    try testing.expectEqual(Verdict.over_limit, (try analyze(arena, &block, default_ambient_c)).verdict);
}

// spec: eval/thermal - an empty design, and one whose parts carry no dissipation, both return insufficient_data with nothing to judge
test "an empty design and a powerless part both read as insufficient data" {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var empty = DesignBlock{
        .name = "t",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const nothing = try analyze(arena, &empty, default_ambient_c);
    try testing.expectEqual(@as(usize, 0), nothing.parts.len);
    try testing.expectEqual(Verdict.insufficient_data, nothing.verdict);
    try testing.expectEqualStrings("", nothing.limiting_ref);

    // A part that declares ratings but dissipates nothing is listed, counted
    // as unknown power, and judged by nothing.
    const rated_insts = [_]env_mod.Instance{.{
        .ref_des = "U1",
        .component = "sensor",
        .value = "",
        .footprint = "",
        .symbol = "",
        .thermal = .{ .decl = .{ .tj_max = 150 } },
    }};
    var rated = blockOver(&rated_insts);
    const result = try analyze(arena, &rated, default_ambient_c);
    try testing.expectEqual(@as(usize, 1), result.parts.len);
    try testing.expectEqual(@as(usize, 1), result.counts.unknown_power);
    try testing.expectEqual(Verdict.insufficient_data, result.verdict);
}

// spec: eval/thermal - the board's ambient window is the tightest junction-derived maximum and the highest declared minimum, each naming the part that sets it
test "max and min ambient name their limiting parts" {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const hot = env_mod.Instance{
        .ref_des = "U1",
        .component = "reg",
        .value = "",
        .footprint = "",
        .symbol = "",
        .thermal = .{ .decl = .{ .theta_ja = 50, .tj_max = 125, .operating_min = -40 }, .power = .{ .typ = 1.0 } },
    };
    const narrow = env_mod.Instance{
        .ref_des = "U2",
        .component = "osc",
        .value = "",
        .footprint = "",
        .symbol = "",
        .thermal = .{ .decl = .{ .operating_min = -20, .operating_max = 70 } },
    };
    const insts = [_]env_mod.Instance{ hot, narrow };
    var block = DesignBlock{
        .name = "t",
        .instances = &insts,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };

    const result = try analyze(arena, &block, default_ambient_c);
    // U1 tolerates 125 − 50 = 75 °C ambient; U2's rating caps the board at 70.
    try testing.expectEqual(@as(f64, 70), result.max_ambient.c.?);
    try testing.expectEqualStrings("U2", result.max_ambient.ref_des);
    // Cold is a ratings question: the highest declared minimum wins.
    try testing.expectEqual(@as(f64, -20), result.min_ambient.c.?);
    try testing.expectEqualStrings("U2", result.min_ambient.ref_des);
}

// spec: eval/thermal - a regulator's dissipation falls back to its back-computed conversion loss, attributed to the module's single hub IC
test "regulator conversion loss lands on the module hub" {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A 5 V → 3.3 V LDO carrying 0.5 A: Iin ≈ Iout, so the pass element burns
    // (5 − 3.3) × 0.5 = 0.85 W.
    var module = DesignBlock{
        .name = "ldo",
        .instances = &.{.{
            .ref_des = "U1",
            .component = "ldo-chip",
            .value = "",
            .footprint = "SOT-223",
            .symbol = "",
        }},
        .nets = &.{},
        .ports = &.{
            .{ .name = "VIN", .net = "VIN", .direction = "in", .nominal = 5.0 },
            .{ .name = "VOUT", .net = "VOUT", .direction = "out", .nominal = 3.3, .efficiency_linear = true },
        },
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var block = DesignBlock{
        .name = "t",
        .instances = &.{.{
            .ref_des = "U9",
            .component = "load",
            .value = "",
            .footprint = "",
            .symbol = "",
        }},
        .nets = &.{
            .{ .name = "V5P0", .pins = &.{} },
            .{ .name = "V3P3", .pins = &.{.{ .ref_des = "U9", .pin = "1", .i_typ = 0.5 }} },
        },
        .ports = &.{.{ .name = "V5P0", .net = "V5P0", .direction = "in", .nominal = 5.0 }},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{.{ .name = "ldo", .block = &module }},
        .net_ties = &.{
            .{ .a = "ldo/VIN", .b = "V5P0" },
            .{ .a = "ldo/VOUT", .b = "V3P3" },
        },
    };

    const result = try analyze(arena, &block, default_ambient_c);
    var hub: ?PartThermal = null;
    for (result.parts) |row| {
        if (std.mem.eql(u8, row.ref_des, "ldo/U1")) hub = row;
    }
    try testing.expectEqual(PowerSource.regulator_loss, hub.?.power.source);
    try testing.expectApproxEqAbs(@as(f64, 0.85), hub.?.power.watts.?, 1e-9);
    // SOT-223 is estimated at 60 °C/W, so the pass element runs 51 °C hot.
    try testing.expectApproxEqAbs(@as(f64, 51.0), hub.?.result.rise_c.?, 1e-9);
}

// spec: eval/thermal - a rail with no resolvable voltage and a part with no theta-ja are skipped with no panic and no half-computed row
test "unresolvable rails and thetaless parts are skipped rather than guessed" {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const insts = [_]env_mod.Instance{.{
        .ref_des = "U1",
        .component = "mystery",
        .value = "",
        .footprint = "MYSTERY-PACKAGE",
        .symbol = "",
        .thermal = .{ .power = .{ .typ = 2.0 } },
    }};
    var block = blockOver(&insts);
    // MYSTERY_RAIL resolves to no voltage (no port, no source declares one),
    // so it contributes no current-derived power at all.
    block.nets = &.{.{ .name = "MYSTERY_RAIL", .pins = &.{.{ .ref_des = "U1", .pin = "1", .i_typ = 0.5 }} }};

    const result = try analyze(arena, &block, default_ambient_c);
    try testing.expectEqual(@as(usize, 1), result.parts.len);
    // The explicit power stands; the unresolvable rail added nothing to it.
    try testing.expectEqual(@as(f64, 2.0), result.parts[0].power.watts.?);
    // No package hint matched, so there is no θJA — and therefore no rise, no
    // junction temperature and no verdict rather than an invented one.
    try testing.expect(result.parts[0].theta.ja == null);
    try testing.expect(result.parts[0].result.rise_c == null);
    try testing.expect(result.parts[0].limits.tj_max == null);
    try testing.expectEqual(Verdict.insufficient_data, result.verdict);
}

// spec: eval/thermal - a regulator whose entire load lives in a sibling sub-block is still charged its conversion loss, because the rail walk credits sealed modules
test "a regulator feeding a sealed sibling module still burns its conversion loss" {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The sealed-module board: nothing at the top level draws anything, and the
    // 0.25 A that decides the LDO's dissipation is declared inside a sibling.
    var load_mod = DesignBlock{
        .name = "radio",
        .instances = &.{},
        .nets = &.{.{ .name = "VDD", .pins = &.{.{ .ref_des = "U1", .pin = "1", .i_typ = 0.25 }} }},
        .ports = &.{.{ .name = "VDD", .net = "VDD", .direction = "in" }},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var module = DesignBlock{
        .name = "ldo",
        .instances = &.{.{
            .ref_des = "U1",
            .component = "ldo-chip",
            .value = "",
            .footprint = "SOT-223",
            .symbol = "",
        }},
        .nets = &.{},
        .ports = &.{
            .{ .name = "VIN", .net = "VIN", .direction = "in", .nominal = 6.0 },
            .{ .name = "VOUT", .net = "VOUT", .direction = "out", .nominal = 3.3, .efficiency_linear = true },
        },
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var block = DesignBlock{
        .name = "t",
        .instances = &.{},
        .nets = &.{
            .{ .name = "V6P0", .pins = &.{} },
            // The rail the LDO feeds carries a TEST POINT at the top level and
            // nothing else — the load is one namespace down.
            .{ .name = "V3P3", .pins = &.{.{ .ref_des = "TP1", .pin = "1" }} },
        },
        .ports = &.{.{ .name = "V6P0", .net = "V6P0", .direction = "in", .nominal = 6.0 }},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{
            .{ .name = "ldo", .block = &module },
            .{ .name = "radio", .block = &load_mod },
        },
        .net_ties = &.{
            .{ .a = "V6P0", .b = "ldo/VIN" },
            .{ .a = "V3P3", .b = "ldo/VOUT" },
            .{ .a = "V3P3", .b = "radio/VDD" },
        },
    };

    const result = try analyze(arena, &block, default_ambient_c);
    var hub: ?PartThermal = null;
    for (result.parts) |row| {
        if (std.mem.eql(u8, row.ref_des, "ldo/U1")) hub = row;
    }
    try testing.expectEqual(PowerSource.regulator_loss, hub.?.power.source);
    // (6.0 − 3.3) × 0.25 = 0.675 W, all of it decided by a current the top
    // level never mentions.
    try testing.expectApproxEqAbs(@as(f64, 0.675), hub.?.power.watts.?, 1e-9);
}

// spec: eval/thermal - a scalar-efficiency converter whose input rail declares no voltage still reports its loss from the output side alone
test "a switcher with an undeclared input rail voltage still burns its efficiency loss" {
    const alloc = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var load_mod = DesignBlock{
        .name = "radio",
        .instances = &.{},
        .nets = &.{.{ .name = "VDD", .pins = &.{.{ .ref_des = "U1", .pin = "1", .i_typ = 0.5 }} }},
        .ports = &.{.{ .name = "VDD", .net = "VDD", .direction = "in" }},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var module = DesignBlock{
        .name = "buck",
        .instances = &.{.{
            .ref_des = "U1",
            .component = "buck-chip",
            .value = "",
            .footprint = "SOT-223",
            .symbol = "",
        }},
        .nets = &.{},
        // The input rail arrives on a connector: nothing on the board declares
        // its voltage, so `Vin·Iin − Pout` cannot be evaluated.
        .ports = &.{
            .{ .name = "VIN", .net = "VIN", .direction = "in", .rated_min = 5.0, .rated_max = 24.0 },
            .{ .name = "VOUT", .net = "VOUT", .direction = "out", .nominal = 6.0, .efficiency = 0.9 },
        },
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var block = DesignBlock{
        .name = "t",
        .instances = &.{},
        .nets = &.{
            .{ .name = "V_IN_RAW", .pins = &.{} },
            .{ .name = "V6P0", .pins = &.{} },
        },
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{
            .{ .name = "buck", .block = &module },
            .{ .name = "radio", .block = &load_mod },
        },
        .net_ties = &.{
            .{ .a = "V_IN_RAW", .b = "buck/VIN" },
            .{ .a = "V6P0", .b = "buck/VOUT" },
            .{ .a = "V6P0", .b = "radio/VDD" },
        },
    };

    const result = try analyze(arena, &block, default_ambient_c);
    var hub: ?PartThermal = null;
    for (result.parts) |row| {
        if (std.mem.eql(u8, row.ref_des, "buck/U1")) hub = row;
    }
    // Pout = 6.0 × 0.5 = 3.0 W; at η 0.9 the converter throws off
    // 3.0 × (1/0.9 − 1) = 0.3333 W, with the input voltage cancelling out.
    try testing.expectEqual(PowerSource.regulator_loss, hub.?.power.source);
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), hub.?.power.watts.?, 1e-9);
}

// spec: eval/thermal - the package theta table is ordered most-specific-first so a footprint matching two hints always resolves to the same one
test "package theta hints are ordered longest-first within a family" {
    // Any hint that contains an earlier hint as a substring would be
    // unreachable — the earlier one would always match first.
    for (package_theta_defaults, 0..) |entry, i| {
        for (package_theta_defaults[0..i]) |earlier| {
            try testing.expect(!containsIgnoreCase(entry.hint, earlier.hint));
        }
    }
}
