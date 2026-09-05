//! Frequency-plan and spurious-product screening for a fixed-LO downconverter.
//!
//! A `(frequency-plan …)` design form declares what the receiver/generator is
//! actually commanded to produce — an output band, a swept source and its
//! delivered passband, a fixed LO with its drive window, the mixer sense, the
//! cutoffs in the two signal paths — and this module answers the questions a
//! spreadsheet is usually asked instead: does the source cover the RF window
//! the plan needs, where does the image land, and which (m,n) mixer products
//! fall inside the commanded band where no filter can ever remove them.
//!
//! Everything is INTERVAL arithmetic over the required RF sweep (see
//! `spurious.zig`), never a frequency sample grid: a swept source covers a
//! continuous interval, so a product either overlaps the output band or it
//! does not, with no sampling gap to hide in.
//!
//! What this is NOT: it models filters at CUTOFF level only — a product is
//! "rejected" when its whole folded interval lies beyond a declared cutoff,
//! with no rolloff, no insertion loss and no group delay. It claims a spur
//! LEVEL only where `(spur-table …)` supplies measured or datasheet
//! suppression; every other row is a PLACEMENT with no level attached, because
//! inventing a conversion-loss number for an (m,n) product is exactly the kind
//! of confident fiction this tool exists to refuse. It is not a phase-noise,
//! reciprocal-mixing, compression, or intermodulation-from-two-tones analysis.

const std = @import("std");
const ast = @import("sexpr/ast.zig");
const env = @import("eval/env.zig");
const spurious = @import("spurious.zig");

const Node = ast.Node;

/// A closed frequency interval, re-exported so a consumer of a `Report` never
/// has to reach past this module for the type its own fields are made of.
pub const Band = spurious.Band;
/// Which sideband of the fixed LO the output band is taken from.
pub const Sideband = spurious.Sideband;

/// Whether a failed plan limit warns or blocks a design build.
pub const Mode = enum { advisory, gate };

/// The mixing sense. Only `difference` is analysed; `sum` parses to a clear
/// refusal rather than being silently treated as a difference mixer.
pub const Sense = enum { difference, sum };

/// The highest `(spurs (max-order M))` this engine will enumerate. The product
/// count grows as M², and past ninth order the placement of a product says
/// more about the arithmetic than about any real mixer.
pub const max_order_limit: u8 = 9;

/// Hard ceiling on enumerated rows: the full `1 ≤ m,n ≤ 9` square plus the two
/// leakage rows `(0,1)` and `(1,0)`.
pub const max_products: usize = @as(usize, max_order_limit) * max_order_limit + 2;

/// Most `(spur-table (product M N DBC))` entries one declaration may carry.
pub const max_table_entries: usize = 64;

const default_max_order: u8 = 3;

/// The swept source: its electrical tuning range and the passband actually
/// delivered to the mixer after the RF filtering in front of it.
pub const Source = struct {
    range: Band = .{},
    delivered: Band = .{},
};

/// Cutoff-level filter declarations. Zero means "not declared", never "DC".
pub const Filters = struct {
    if_low_pass_hz: f64 = 0,
    rf_low_pass_hz: f64 = 0,
    rf_high_pass_hz: f64 = 0,
};

/// The commanded plan: what comes out, what goes in, and what is filtered.
pub const PlanConfig = struct {
    output_band: Band = .{},
    source: Source = .{},
    filters: Filters = .{},
};

/// The mixer's acceptable LO drive, in dBm.
pub const DriveWindow = struct {
    min_dbm: f64 = 0,
    max_dbm: f64 = 0,
    declared: bool = false,
};

/// The fixed local oscillator delivered to the mixer's LO port.
pub const LocalOscillator = struct {
    frequency_hz: f64 = 0,
    /// Delivered LO power. Meaningful only when `drive_declared`.
    drive_dbm: f64 = 0,
    drive_declared: bool = false,
    window: DriveWindow = .{},
};

/// Mixing sense, sideband selection and the LO the products are taken against.
/// `declared` records that a `(mixer …)` clause was authored; a parsed `Spec`
/// and every `Report` built from one always has it set.
pub const MixerConfig = struct {
    sense: Sense = .difference,
    sideband: Sideband = .high,
    lo: LocalOscillator = .{},
    declared: bool = false,
};

/// Enumeration bound plus the in-band level limit, as authored.
pub const SpurConfig = struct {
    max_order: u8 = default_max_order,
    in_band_limit_dbc: f64 = 0,
    limit_declared: bool = false,
    /// `(product M N DBC)` children, validated at parse and re-read when the
    /// report's own table is built — the same borrow-the-AST discipline
    /// `pll_loop` uses for its operating curve.
    table_nodes: []const Node = &.{},
};

/// Parsed declaration. Frequencies are hertz; drive is dBm and suppression is
/// dBc, both signed and both left exactly as authored.
pub const Spec = struct {
    name: []const u8,
    mode: Mode = .gate,
    mode_declared: bool = false,
    plan: PlanConfig = .{},
    mixer: MixerConfig = .{},
    spurs: SpurConfig = .{},
};

/// `SumMixingUnsupported` and `SpurOrderTooHigh` are separated from the generic
/// shape error so the evaluator can say which limit was hit instead of printing
/// "malformed" at a declaration whose only problem is a number.
pub const ParseError = error{ InvalidForm, SumMixingUnsupported, SpurOrderTooHigh };

/// Parse the documented top-level form. Title, `(mode …)`, `(output-band …)`,
/// `(lo …)` and `(mixer …)` are required; every other clause is optional.
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
        out.mode_declared = true;
    } else if (eq(head, "output-band")) {
        out.plan.output_band = try bandAt(c, 1);
    } else if (eq(head, "source")) {
        try parseSource(c, &out.plan.source);
    } else if (eq(head, "lo")) {
        try parseLo(c, &out.mixer.lo);
    } else if (eq(head, "mixer")) {
        try parseMixer(c, &out.mixer);
    } else if (eq(head, "if-filter")) {
        try parseIfFilter(c, &out.plan.filters);
    } else if (eq(head, "rf-filter")) {
        try parseRfFilter(c, &out.plan.filters);
    } else if (eq(head, "spurs")) {
        try parseSpurs(c, &out.spurs);
    } else if (eq(head, "spur-table")) {
        try parseSpurTable(c, &out.spurs);
    } else return error.InvalidForm;
}

fn parseSource(c: []const Node, out: *Source) ParseError!void {
    for (c[1..]) |node| {
        const p = node.asList() orelse return error.InvalidForm;
        const head = try atomAt(p, 0);
        if (eq(head, "range")) {
            out.range = try bandAt(p, 1);
        } else if (eq(head, "delivered")) {
            out.delivered = try bandAt(p, 1);
        } else return error.InvalidForm;
    }
}

fn parseLo(c: []const Node, out: *LocalOscillator) ParseError!void {
    out.frequency_hz = try positiveAt(c, 1);
    for (c[2..]) |node| {
        const p = node.asList() orelse return error.InvalidForm;
        const head = try atomAt(p, 0);
        if (eq(head, "drive")) {
            out.drive_dbm = try finiteAt(p, 1);
            out.drive_declared = true;
        } else if (eq(head, "drive-window")) {
            out.window = .{ .min_dbm = try finiteAt(p, 1), .max_dbm = try finiteAt(p, 2), .declared = true };
            if (out.window.max_dbm < out.window.min_dbm) return error.InvalidForm;
        } else return error.InvalidForm;
    }
}

fn parseMixer(c: []const Node, out: *MixerConfig) ParseError!void {
    const sense = try atomAt(c, 1);
    if (eq(sense, "sum")) return error.SumMixingUnsupported;
    if (!eq(sense, "difference")) return error.InvalidForm;
    out.sense = .difference;
    out.declared = true;
    for (c[2..]) |node| {
        const p = node.asList() orelse return error.InvalidForm;
        if (!eq(try atomAt(p, 0), "sideband")) return error.InvalidForm;
        const word = try atomAt(p, 1);
        out.sideband = if (eq(word, "high")) .high else if (eq(word, "low")) .low else if (eq(word, "either")) .either else return error.InvalidForm;
    }
}

fn parseIfFilter(c: []const Node, out: *Filters) ParseError!void {
    if (c.len < 2) return error.InvalidForm;
    for (c[1..]) |node| {
        const p = node.asList() orelse return error.InvalidForm;
        if (!eq(try atomAt(p, 0), "low-pass")) return error.InvalidForm;
        out.if_low_pass_hz = try positiveAt(p, 1);
    }
}

fn parseRfFilter(c: []const Node, out: *Filters) ParseError!void {
    if (c.len < 2) return error.InvalidForm;
    for (c[1..]) |node| {
        const p = node.asList() orelse return error.InvalidForm;
        const head = try atomAt(p, 0);
        if (eq(head, "low-pass")) {
            out.rf_low_pass_hz = try positiveAt(p, 1);
        } else if (eq(head, "high-pass")) {
            out.rf_high_pass_hz = try positiveAt(p, 1);
        } else return error.InvalidForm;
    }
    if (out.rf_high_pass_hz > 0 and out.rf_low_pass_hz > 0 and out.rf_high_pass_hz >= out.rf_low_pass_hz) return error.InvalidForm;
}

fn parseSpurs(c: []const Node, out: *SpurConfig) ParseError!void {
    for (c[1..]) |node| {
        const p = node.asList() orelse return error.InvalidForm;
        const head = try atomAt(p, 0);
        if (eq(head, "max-order")) {
            const order = try positiveAt(p, 1);
            if (order != @floor(order) or order < 1) return error.InvalidForm;
            if (order > @as(f64, @floatFromInt(max_order_limit))) return error.SpurOrderTooHigh;
            out.max_order = @intFromFloat(order);
        } else if (eq(head, "in-band-limit")) {
            out.in_band_limit_dbc = try finiteAt(p, 1);
            out.limit_declared = true;
        } else return error.InvalidForm;
    }
}

fn parseSpurTable(c: []const Node, out: *SpurConfig) ParseError!void {
    if (c.len < 2 or c.len - 1 > max_table_entries) return error.InvalidForm;
    for (c[1..]) |node| _ = try parseTableEntry(node);
    out.table_nodes = c[1..];
}

/// `(product M N DBC)` — the suppression of the (m,n) product relative to the
/// wanted (1,1) product at the declared nominal drive.
fn parseTableEntry(node: Node) ParseError!TableEntry {
    const p = node.asList() orelse return error.InvalidForm;
    if (p.len != 4 or !eq(try atomAt(p, 0), "product")) return error.InvalidForm;
    const m = try orderAt(p, 1);
    const n = try orderAt(p, 2);
    if (m == 0 and n == 0) return error.InvalidForm;
    return .{ .m = m, .n = n, .dbc = try finiteAt(p, 3) };
}

fn orderAt(c: []const Node, index: usize) ParseError!u8 {
    const value = try finiteAt(c, index);
    if (value < 0 or value != @floor(value) or value > @as(f64, @floatFromInt(max_order_limit))) return error.InvalidForm;
    return @intFromFloat(value);
}

fn bandAt(c: []const Node, index: usize) ParseError!Band {
    const lo = try positiveAt(c, index);
    const hi = try positiveAt(c, index + 1);
    if (hi < lo) return error.InvalidForm;
    return .{ .lo_hz = lo, .hi_hz = hi };
}

fn atomAt(c: []const Node, index: usize) ParseError![]const u8 {
    if (index >= c.len) return error.InvalidForm;
    return c[index].asAtom() orelse error.InvalidForm;
}

fn finiteAt(c: []const Node, index: usize) ParseError!f64 {
    if (index >= c.len) return error.InvalidForm;
    const value = c[index].asNumber() orelse return error.InvalidForm;
    if (!std.math.isFinite(value)) return error.InvalidForm;
    return value;
}

fn positiveAt(c: []const Node, index: usize) ParseError!f64 {
    const value = try finiteAt(c, index);
    if (value <= 0) return error.InvalidForm;
    return value;
}

fn validSpec(out: Spec) bool {
    if (out.name.len == 0) return false;
    if (!out.mode_declared) return false;
    if (!out.plan.output_band.declared()) return false;
    if (!out.mixer.declared) return false;
    if (out.mixer.lo.frequency_hz <= 0) return false;
    if (out.plan.source.range.declared() and out.plan.source.delivered.declared() and
        !out.plan.source.range.contains(out.plan.source.delivered)) return false;
    return true;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

// ── Typed report ──────────────────────────────────────────────────────────

/// One `(spur-table (product M N DBC))` row, normalized.
pub const TableEntry = struct { m: u8, n: u8, dbc: f64 };

/// The `(m,n)` index of one enumerated mixer product: `|m·RF − n·LO|`.
pub const Order = struct { m: u8, n: u8 };

/// Where an enumerated product sits relative to the commanded output band.
/// `wanted` is the `(1,1)` product the plan is built on; `co_channel` products
/// overlap the output band and NO filter can remove them; `filter_rejected`
/// products lie wholly beyond a declared cutoff; `out_of_band` products miss
/// the band but nothing declared removes them either.
pub const Placement = enum { wanted, co_channel, filter_rejected, out_of_band };

/// Why a product is rejected, so a renderer can name the cutoff instead of
/// asserting "filtered".
pub const Rejection = enum { none, if_low_pass, rf_low_pass, rf_high_pass, outside_delivered };

/// A product's level claim. `unclaimed` is the honest default: without a
/// `(spur-table …)` entry this engine states WHERE a product lands and nothing
/// about how big it is.
pub const LevelVerdict = enum { unclaimed, within_limit, over_limit };

/// The declared suppression of one product, if any.
pub const Level = struct {
    dbc: f64 = 0,
    declared: bool = false,
    verdict: LevelVerdict = .unclaimed,
};

/// One enumerated `(m,n)` product over the whole required RF sweep.
pub const Product = struct {
    order: Order,
    /// Every monotone branch of `|m·RF − n·LO|`. Two branches when the signed
    /// product crosses DC inside the sweep, one otherwise.
    branches: spurious.Branches = .{},
    /// The smallest interval containing every branch — what a table renders.
    band: Band = .{},
    placement: Placement = .out_of_band,
    /// `.none` unless `placement == .filter_rejected`.
    rejection: Rejection = .none,
    level: Level = .{},
};

/// The RF window one sideband demands and how the declared source covers it.
pub const RfWindow = struct {
    required: Band = .{},
    /// The part of `required` below the delivered passband, empty when none.
    uncovered_low: Band = .{},
    /// The part of `required` above the delivered passband, empty when none.
    uncovered_high: Band = .{},
    /// The delivered passband contains the whole required window. False also
    /// when no `(delivered …)` was declared — see `covered_checked`.
    covered: bool = false,
    /// A `(delivered …)` clause existed, so `covered` is a verdict and not a
    /// default.
    covered_checked: bool = false,
    /// The declared `(range …)` contains the whole required window; false when
    /// no range was declared.
    in_range: bool = false,
};

/// Where the other sideband lands and what, if anything, removes it.
pub const Image = struct {
    band: Band = .{},
    rejection: Rejection = .none,
};

/// The `(m,m)` family, which always lands at exact multiples of the commanded
/// IF and so cannot be planned away by moving the LO.
pub const Diagonal = struct {
    /// The commanded IF the worst case is taken at — the output band's LOW
    /// edge, where the multiples pack tightest.
    worst_case_if_hz: f64 = 0,
    /// `⌊band.hi / worst_case_if_hz⌋ − 1`: diagonal products inside the band
    /// above the wanted one, unbounded by the enumeration order.
    worst_case_count: usize = 0,
    /// Diagonal rows this evaluation actually enumerated as co-channel, which
    /// the `(spurs (max-order …))` cap can hold below `worst_case_count`.
    enumerated_count: usize = 0,
    /// The commanded IF above which no `(m,m)`, m ≥ 2, lands in band.
    clean_above_hz: f64 = 0,
};

/// Every screen `evaluate` can append, named in the order it appends them.
/// `lo_drive` is charged to the first plan because LO drive is a property of
/// the declaration, not of a sideband.
pub const Screen = enum {
    lo_drive,
    rf_window,
    band_closure,
    source_range,
    image_band,
    spur_placement,
    spur_levels,
    spur_coverage,
    diagonal_family,
};

/// `pass` mirrors a passing assertion, `warn` an advisory-mode failure or a
/// standalone warning, `fail` a gating failure.
pub const Status = enum { pass, warn, fail };

/// One screen's outcome plus the exact assertion text it appended. `message`
/// is BORROWED from the assertion list, so it lives as long as the evaluator
/// that owns those messages, not longer.
pub const Verdict = struct {
    screen: Screen,
    status: Status,
    message: []const u8,
};

/// One sideband's complete plan. `(sideband either)` publishes two of these,
/// high side first; `high` or `low` publishes exactly one.
pub const SidebandPlan = struct {
    sideband: Sideband,
    rf: RfWindow = .{},
    image: Image = .{},
    diagonal: Diagonal = .{},
    /// Enumerated products in `(m, then n)` order: the two leakage rows
    /// `(0,1)` and `(1,0)` first, then the `1 ≤ m,n ≤ max-order` square.
    /// Empty when the sideband's RF window is unrealizable.
    products: []const Product = &.{},
    /// The screens charged to this plan, in assertion order. Concatenating the
    /// plans' lists reproduces the order `evaluate` appended its assertions in.
    verdicts: []const Verdict = &.{},
};

/// What the declaration states, normalized to SI. Absent clauses stay 0.
pub const Profile = struct {
    plan: PlanConfig = .{},
    mixer: MixerConfig = .{},
    spurs: SpurProfile = .{},
};

/// The enumeration bound and the resolved suppression table.
pub const SpurProfile = struct {
    max_order: u8 = default_max_order,
    in_band_limit_dbc: f64 = 0,
    limit_declared: bool = false,
    /// Authored `(product M N DBC)` rows in authored order. Owned by the
    /// allocator `evaluate` was handed.
    table: []const TableEntry = &.{},
};

/// How far the screens got. `unrealizable` ⇒ at least one sideband's required
/// RF window has a non-positive edge (a low-side plan under an LO below the
/// band), so that plan carries only its `rf_window` verdict; `screened` ⇒ every
/// plan was enumerated.
pub const Outcome = enum { unrealizable, screened };

/// One `(frequency-plan …)` declaration's complete typed result. Slices are
/// owned by the allocator `evaluate` was handed; `Verdict.message` and `name`
/// are borrowed — messages from the assertion list the evaluator owns, `name`
/// from the design source.
pub const Report = struct {
    name: []const u8 = "",
    mode: Mode = .gate,
    profile: Profile = .{},
    outcome: Outcome = .screened,
    /// One entry per analysed sideband, in evaluation order.
    plans: []const SidebandPlan = &.{},

    /// Release the slices `evaluate` allocated. Borrowed strings — verdict
    /// messages and the declaration name — belong to the assertion list and
    /// the design source and are left alone.
    pub fn deinit(self: Report, allocator: std.mem.Allocator) void {
        for (self.plans) |plan| {
            allocator.free(plan.products);
            allocator.free(plan.verdicts);
        }
        allocator.free(self.plans);
        allocator.free(self.profile.spurs.table);
    }
};

// ── Evaluation ────────────────────────────────────────────────────────────

/// Accumulator for one declaration: the assertion list every screen appends
/// to, plus the same screens' numbers on their way into a `Report`.
const Context = struct {
    allocator: std.mem.Allocator,
    assertions: *std.ArrayList(env.AssertionResult),
    /// Every verdict in assertion order; `plan_first_verdict` marks where the
    /// plan currently being screened started.
    verdicts: std.ArrayList(Verdict) = .empty,
    plan_first_verdict: usize = 0,
    plans: std.ArrayList(SidebandPlan) = .empty,
    outcome: Outcome = .screened,
};

/// Evaluate one declaration, append normal design assertions, and publish the
/// typed record of the same numbers. In advisory mode a failed plan limit is a
/// warning, suitable while an LO frequency or a drive measurement is still
/// provisional; gate mode makes it build-blocking.
pub fn evaluate(allocator: std.mem.Allocator, assertions: *std.ArrayList(env.AssertionResult), reports: *std.ArrayList(Report), spec: Spec) std.mem.Allocator.Error!void {
    var context = Context{ .allocator = allocator, .assertions = assertions };
    defer context.verdicts.deinit(allocator);
    defer context.plans.deinit(allocator);
    try screen(&context, spec);
    try reports.append(allocator, try finish(&context, spec));
}

fn screen(context: *Context, spec: Spec) std.mem.Allocator.Error!void {
    try loDrive(context, spec);
    if (spec.mixer.sideband == .either) {
        try screenSideband(context, spec, .high);
        try screenSideband(context, spec, .low);
        return;
    }
    try screenSideband(context, spec, spec.mixer.sideband);
}

fn loDrive(context: *Context, spec: Spec) std.mem.Allocator.Error!void {
    const lo = spec.mixer.lo;
    if (!lo.drive_declared or !lo.window.declared) return;
    const inside = lo.drive_dbm >= lo.window.min_dbm and lo.drive_dbm <= lo.window.max_dbm;
    try append(context, spec, .lo_drive, inside, "{s}: delivered LO drive {d:.2} dBm against the mixer's {d:.2}…{d:.2} dBm LO window", .{ spec.name, lo.drive_dbm, lo.window.min_dbm, lo.window.max_dbm });
}

fn screenSideband(context: *Context, spec: Spec, side: Sideband) std.mem.Allocator.Error!void {
    const required = spurious.requiredRf(spec.mixer.lo.frequency_hz, spec.plan.output_band, side);
    if (required.lo_hz <= 0) {
        context.outcome = .unrealizable;
        try append(context, spec, .rf_window, false, "{s}: the {s}-side RF window {d:.3}-{d:.3} MHz is not a realizable sweep against a {d:.3} MHz LO", .{ spec.name, sidebandName(side), mhz(required.lo_hz), mhz(required.hi_hz), mhz(spec.mixer.lo.frequency_hz) });
        try closePlan(context, side, .{}, .{}, .{}, &.{});
        return;
    }
    const window = coverage(spec, required);
    try bandClosure(context, spec, side, window);
    try sourceRange(context, spec, side, window);
    const image = imageScreen(spec, side);
    try imageAssertion(context, spec, side, image);

    var products: [max_products]Product = undefined;
    const count = enumerate(spec, required, &products);
    const diagonal = diagonalOf(spec, products[0..count]);
    try spurScreens(context, spec, side, products[0..count]);
    try diagonalAssertion(context, spec, side, diagonal);
    try closePlan(context, side, window, image, diagonal, products[0..count]);
}

fn closePlan(context: *Context, side: Sideband, window: RfWindow, image: Image, diagonal: Diagonal, products: []const Product) std.mem.Allocator.Error!void {
    const allocator = context.allocator;
    try context.plans.append(allocator, .{
        .sideband = side,
        .rf = window,
        .image = image,
        .diagonal = diagonal,
        .products = try allocator.dupe(Product, products),
        .verdicts = try allocator.dupe(Verdict, context.verdicts.items[context.plan_first_verdict..]),
    });
    context.plan_first_verdict = context.verdicts.items.len;
}

fn coverage(spec: Spec, required: Band) RfWindow {
    const delivered = spec.plan.source.delivered;
    const range = spec.plan.source.range;
    return .{
        .required = required,
        .uncovered_low = if (delivered.declared()) required.below(delivered) else .{},
        .uncovered_high = if (delivered.declared()) required.above(delivered) else .{},
        .covered = delivered.declared() and delivered.contains(required),
        .covered_checked = delivered.declared(),
        .in_range = range.declared() and range.contains(required),
    };
}

fn bandClosure(context: *Context, spec: Spec, side: Sideband, window: RfWindow) std.mem.Allocator.Error!void {
    if (!window.covered_checked) return;
    const delivered = spec.plan.source.delivered;
    const band = spec.plan.output_band;
    if (window.covered) {
        try append(context, spec, .band_closure, true, "{s}: the {s}-side RF window {d:.3}-{d:.3} MHz for output band {d:.3}-{d:.3} MHz lies inside the delivered passband {d:.3}-{d:.3} MHz", .{ spec.name, sidebandName(side), mhz(window.required.lo_hz), mhz(window.required.hi_hz), mhz(band.lo_hz), mhz(band.hi_hz), mhz(delivered.lo_hz), mhz(delivered.hi_hz) });
        return;
    }
    const low = window.uncovered_low;
    const high = window.uncovered_high;
    const lost_low = spurious.outputOf(spec.mixer.lo.frequency_hz, low, side);
    const lost_high = spurious.outputOf(spec.mixer.lo.frequency_hz, high, side);
    if (!low.isEmpty() and !high.isEmpty()) {
        try append(context, spec, .band_closure, false, "{s}: the {s}-side RF window {d:.3}-{d:.3} MHz for output band {d:.3}-{d:.3} MHz leaves the delivered passband {d:.3}-{d:.3} MHz — {d:.3}-{d:.3} MHz falls below it (costing output {d:.3}-{d:.3} MHz) and {d:.3}-{d:.3} MHz falls above it (costing output {d:.3}-{d:.3} MHz)", .{ spec.name, sidebandName(side), mhz(window.required.lo_hz), mhz(window.required.hi_hz), mhz(band.lo_hz), mhz(band.hi_hz), mhz(delivered.lo_hz), mhz(delivered.hi_hz), mhz(low.lo_hz), mhz(low.hi_hz), mhz(lost_low.lo_hz), mhz(lost_low.hi_hz), mhz(high.lo_hz), mhz(high.hi_hz), mhz(lost_high.lo_hz), mhz(lost_high.hi_hz) });
        return;
    }
    if (!low.isEmpty()) {
        try append(context, spec, .band_closure, false, "{s}: the {s}-side RF window {d:.3}-{d:.3} MHz for output band {d:.3}-{d:.3} MHz leaves the delivered passband {d:.3}-{d:.3} MHz — {d:.3}-{d:.3} MHz falls below it, costing output {d:.3}-{d:.3} MHz", .{ spec.name, sidebandName(side), mhz(window.required.lo_hz), mhz(window.required.hi_hz), mhz(band.lo_hz), mhz(band.hi_hz), mhz(delivered.lo_hz), mhz(delivered.hi_hz), mhz(low.lo_hz), mhz(low.hi_hz), mhz(lost_low.lo_hz), mhz(lost_low.hi_hz) });
        return;
    }
    try append(context, spec, .band_closure, false, "{s}: the {s}-side RF window {d:.3}-{d:.3} MHz for output band {d:.3}-{d:.3} MHz leaves the delivered passband {d:.3}-{d:.3} MHz — {d:.3}-{d:.3} MHz falls above it, costing output {d:.3}-{d:.3} MHz", .{ spec.name, sidebandName(side), mhz(window.required.lo_hz), mhz(window.required.hi_hz), mhz(band.lo_hz), mhz(band.hi_hz), mhz(delivered.lo_hz), mhz(delivered.hi_hz), mhz(high.lo_hz), mhz(high.hi_hz), mhz(lost_high.lo_hz), mhz(lost_high.hi_hz) });
}

fn sourceRange(context: *Context, spec: Spec, side: Sideband, window: RfWindow) std.mem.Allocator.Error!void {
    const range = spec.plan.source.range;
    if (!range.declared()) return;
    try append(context, spec, .source_range, window.in_range, "{s}: the {s}-side RF window {d:.3}-{d:.3} MHz against the source's electrical range {d:.3}-{d:.3} MHz", .{ spec.name, sidebandName(side), mhz(window.required.lo_hz), mhz(window.required.hi_hz), mhz(range.lo_hz), mhz(range.hi_hz) });
}

fn imageScreen(spec: Spec, side: Sideband) Image {
    const band = spurious.imageOf(spec.mixer.lo.frequency_hz, spec.plan.output_band, side);
    const filters = spec.plan.filters;
    if (filters.rf_low_pass_hz > 0 and band.lo_hz > filters.rf_low_pass_hz) return .{ .band = band, .rejection = .rf_low_pass };
    if (filters.rf_high_pass_hz > 0 and band.hi_hz < filters.rf_high_pass_hz) return .{ .band = band, .rejection = .rf_high_pass };
    const delivered = spec.plan.source.delivered;
    if (delivered.declared() and !delivered.overlaps(band)) return .{ .band = band, .rejection = .outside_delivered };
    return .{ .band = band, .rejection = .none };
}

fn imageAssertion(context: *Context, spec: Spec, side: Sideband, image: Image) std.mem.Allocator.Error!void {
    const other = if (side == .low) "high" else "low";
    try append(context, spec, .image_band, image.rejection != .none, "{s}: the {s}-side image of the {s}-side plan lands at {d:.3}-{d:.3} MHz and is {s}", .{ spec.name, other, sidebandName(side), mhz(image.band.lo_hz), mhz(image.band.hi_hz), rejectionPhrase(image.rejection) });
}

fn rejectionPhrase(rejection: Rejection) []const u8 {
    return switch (rejection) {
        .none => "removed by nothing declared — it reaches the mixer at full amplitude",
        .rf_low_pass => "wholly above the declared RF low-pass cutoff",
        .rf_high_pass => "wholly below the declared RF high-pass cutoff",
        .outside_delivered => "wholly outside the delivered source passband",
        .if_low_pass => "wholly above the declared IF low-pass cutoff",
    };
}

/// Enumerate every `(m,n)` product over the required RF sweep, in `(m, then
/// n)` order: the leakage rows `(0,1)` and `(1,0)` first, then the square.
fn enumerate(spec: Spec, required: Band, out: *[max_products]Product) usize {
    var count: usize = 0;
    out[count] = classify(spec, required, 0, 1);
    count += 1;
    out[count] = classify(spec, required, 1, 0);
    count += 1;
    var m: u8 = 1;
    while (m <= spec.spurs.max_order) : (m += 1) {
        var n: u8 = 1;
        while (n <= spec.spurs.max_order) : (n += 1) {
            out[count] = classify(spec, required, m, n);
            count += 1;
        }
    }
    return count;
}

fn classify(spec: Spec, required: Band, m: u8, n: u8) Product {
    const branches = spurious.productBranches(@floatFromInt(m), @floatFromInt(n), required, spec.mixer.lo.frequency_hz);
    var product = Product{ .order = .{ .m = m, .n = n }, .branches = branches, .band = branches.hull() };
    product.placement = placementOf(spec, branches, m, n);
    if (product.placement == .filter_rejected) product.rejection = rejectionOf(spec, branches);
    product.level = levelOf(spec, m, n, product.placement);
    return product;
}

fn placementOf(spec: Spec, branches: spurious.Branches, m: u8, n: u8) Placement {
    if (m == 1 and n == 1) return .wanted;
    if (branches.overlaps(spec.plan.output_band)) return .co_channel;
    if (rejectionOf(spec, branches) != .none) return .filter_rejected;
    return .out_of_band;
}

fn rejectionOf(spec: Spec, branches: spurious.Branches) Rejection {
    const filters = spec.plan.filters;
    if (filters.if_low_pass_hz > 0 and branches.aboveAll(filters.if_low_pass_hz)) return .if_low_pass;
    return .none;
}

fn levelOf(spec: Spec, m: u8, n: u8, placement: Placement) Level {
    for (spec.spurs.table_nodes) |node| {
        const entry = parseTableEntry(node) catch continue;
        if (entry.m != m or entry.n != n) continue;
        if (!spec.spurs.limit_declared or placement != .co_channel)
            return .{ .dbc = entry.dbc, .declared = true, .verdict = .unclaimed };
        const within = entry.dbc <= spec.spurs.in_band_limit_dbc;
        return .{ .dbc = entry.dbc, .declared = true, .verdict = if (within) .within_limit else .over_limit };
    }
    return .{};
}

const Tally = struct {
    co_channel: usize = 0,
    rejected: usize = 0,
    out_of_band: usize = 0,
    unlevelled: usize = 0,
    worst_index: ?usize = null,
    over_limit: usize = 0,
};

fn tally(products: []const Product) Tally {
    var out = Tally{};
    for (products, 0..) |product, index| {
        switch (product.placement) {
            .wanted => {},
            .co_channel => {
                out.co_channel += 1;
                if (!product.level.declared) out.unlevelled += 1;
                if (product.level.verdict == .over_limit) out.over_limit += 1;
                if (product.level.declared and (out.worst_index == null or product.level.dbc > products[out.worst_index.?].level.dbc))
                    out.worst_index = index;
            },
            .filter_rejected => out.rejected += 1,
            .out_of_band => out.out_of_band += 1,
        }
    }
    return out;
}

fn spurScreens(context: *Context, spec: Spec, side: Sideband, products: []const Product) std.mem.Allocator.Error!void {
    const counts = tally(products);
    try append(context, spec, .spur_placement, true, "{s}: the {s}-side plan enumerates {d} products to order {d} — {d} co-channel with the {d:.3}-{d:.3} MHz output band, {d} rejected by a declared cutoff, {d} out of band", .{ spec.name, sidebandName(side), products.len, spec.spurs.max_order, counts.co_channel, mhz(spec.plan.output_band.lo_hz), mhz(spec.plan.output_band.hi_hz), counts.rejected, counts.out_of_band });
    if (spec.spurs.limit_declared) if (counts.worst_index) |index| {
        const worst = products[index];
        try append(context, spec, .spur_levels, counts.over_limit == 0, "{s}: {d} of the {s}-side co-channel products carry declared suppression; the worst is ({d},{d}) at {d:.1} dBc against the {d:.1} dBc in-band limit", .{ spec.name, counts.co_channel - counts.unlevelled, sidebandName(side), worst.order.m, worst.order.n, worst.level.dbc, spec.spurs.in_band_limit_dbc });
    };
    if (counts.unlevelled > 0)
        try warning(context, .spur_coverage, "{s}: {d} of the {s}-side co-channel products carry no declared suppression; their placement is reported and no level is claimed for them", .{ spec.name, counts.unlevelled, sidebandName(side) });
}

fn diagonalOf(spec: Spec, products: []const Product) Diagonal {
    const band = spec.plan.output_band;
    var enumerated: usize = 0;
    for (products) |product| {
        if (product.order.m != product.order.n or product.placement != .co_channel) continue;
        enumerated += 1;
    }
    return .{
        .worst_case_if_hz = band.lo_hz,
        .worst_case_count = spurious.diagonalCount(band, band.lo_hz),
        .enumerated_count = enumerated,
        .clean_above_hz = spurious.diagonalCleanAbove(band),
    };
}

fn diagonalAssertion(context: *Context, spec: Spec, side: Sideband, diagonal: Diagonal) std.mem.Allocator.Error!void {
    try append(context, spec, .diagonal_family, true, "{s}: the {s}-side (m,m) diagonal family lands at multiples of the commanded IF — {d} sit inside {d:.3}-{d:.3} MHz at the {d:.3} MHz low edge ({d} within order {d}), and the band is diagonal-clean above {d:.3} MHz", .{ spec.name, sidebandName(side), diagonal.worst_case_count, mhz(spec.plan.output_band.lo_hz), mhz(spec.plan.output_band.hi_hz), mhz(diagonal.worst_case_if_hz), diagonal.enumerated_count, spec.spurs.max_order, mhz(diagonal.clean_above_hz) });
}

fn finish(context: *Context, spec: Spec) std.mem.Allocator.Error!Report {
    return .{
        .name = spec.name,
        .mode = spec.mode,
        .profile = .{
            .plan = spec.plan,
            .mixer = spec.mixer,
            .spurs = .{
                .max_order = spec.spurs.max_order,
                .in_band_limit_dbc = spec.spurs.in_band_limit_dbc,
                .limit_declared = spec.spurs.limit_declared,
                .table = try tableOf(context.allocator, spec),
            },
        },
        .outcome = context.outcome,
        .plans = try context.plans.toOwnedSlice(context.allocator),
    };
}

fn tableOf(allocator: std.mem.Allocator, spec: Spec) std.mem.Allocator.Error![]const TableEntry {
    var out: std.ArrayList(TableEntry) = .empty;
    for (spec.spurs.table_nodes) |node| {
        const entry = parseTableEntry(node) catch continue;
        try out.append(allocator, entry);
    }
    return out.toOwnedSlice(allocator);
}

fn sidebandName(side: Sideband) []const u8 {
    return switch (side) {
        .high => "high",
        .low => "low",
        .either => "either",
    };
}

/// Every assertion prints megahertz, so one plan reads on one scale from a
/// 50 MHz IF to a 12.9 GHz RF window.
fn mhz(hz: f64) f64 {
    return hz / 1e6;
}

fn append(context: *Context, spec: Spec, screen_id: Screen, passed: bool, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
    const is_warning = !passed and spec.mode == .advisory;
    const message = try std.fmt.allocPrint(context.allocator, fmt, args);
    errdefer context.allocator.free(message);
    try context.assertions.append(context.allocator, .{
        .passed = passed,
        .message = message,
        .is_warning = is_warning,
        .message_owned = true,
    });
    try context.verdicts.append(context.allocator, .{
        .screen = screen_id,
        .status = if (passed) .pass else if (is_warning) .warn else .fail,
        .message = message,
    });
}

fn warning(context: *Context, screen_id: Screen, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
    const message = try std.fmt.allocPrint(context.allocator, fmt, args);
    errdefer context.allocator.free(message);
    try context.assertions.append(context.allocator, .{
        .passed = false,
        .message = message,
        .is_warning = true,
        .message_owned = true,
    });
    try context.verdicts.append(context.allocator, .{ .screen = screen_id, .status = .warn, .message = message });
}

// ── Tests ─────────────────────────────────────────────────────────────────

const parser = @import("sexpr/parser.zig");

/// The real Board A plan: HMC733 swept X-band source behind a 12.9 GHz
/// filter pair, fixed LMX2595 LO into a Marki MM1-0626 mixer, 50-1500 MHz IF
/// through the 6 GHz low-pass pair. `lo_hz` is the one number the release has
/// an open conflict over — 10.95 GHz per the architecture, 10.00 GHz per a
/// firmware note — so the fixture takes it as an argument.
fn boardASpec(lo_hz: f64, mode: Mode) Spec {
    return .{
        .name = "Board A Band 1",
        .mode = mode,
        .mode_declared = true,
        .plan = .{
            .output_band = .{ .lo_hz = 50e6, .hi_hz = 1500e6 },
            .source = .{
                .range = .{ .lo_hz = 10e9, .hi_hz = 20e9 },
                .delivered = .{ .lo_hz = 10.5e9, .hi_hz = 12.9e9 },
            },
            .filters = .{ .if_low_pass_hz = 6e9, .rf_low_pass_hz = 12.9e9 },
        },
        .mixer = .{
            .sense = .difference,
            .sideband = .high,
            .declared = true,
            .lo = .{
                .frequency_hz = lo_hz,
                .drive_dbm = 21,
                .drive_declared = true,
                .window = .{ .min_dbm = 17, .max_dbm = 23, .declared = true },
            },
        },
        .spurs = .{ .max_order = 3 },
    };
}

fn freeAssertions(allocator: std.mem.Allocator, list: *std.ArrayList(env.AssertionResult)) void {
    for (list.items) |assertion| allocator.free(assertion.message);
    list.deinit(allocator);
}

fn freeReports(allocator: std.mem.Allocator, list: *std.ArrayList(Report)) void {
    for (list.items) |report| report.deinit(allocator);
    list.deinit(allocator);
}

fn verdictOf(report: Report, screen_id: Screen) ?Verdict {
    for (report.plans) |plan| {
        for (plan.verdicts) |verdict| if (verdict.screen == screen_id) return verdict;
    }
    return null;
}

fn productOf(plan: SidebandPlan, m: u8, n: u8) Product {
    for (plan.products) |product| {
        if (product.order.m == m and product.order.n == n) return product;
    }
    return .{ .order = .{ .m = m, .n = n } };
}

/// Concatenating the plans' verdict lists must reproduce the assertion list:
/// same count, same message bytes, same outcome. This is the invariant a
/// document renderer relies on to pair a typed row with its printed sentence.
fn expectVerdictsTrackAssertions(assertions: []const env.AssertionResult, plans: []const SidebandPlan) !void {
    var index: usize = 0;
    for (plans) |plan| for (plan.verdicts) |verdict| {
        try std.testing.expect(index < assertions.len);
        const assertion = assertions[index];
        try std.testing.expectEqual(assertion.message.ptr, verdict.message.ptr);
        const expected: Status = if (assertion.passed) .pass else if (assertion.is_warning) .warn else .fail;
        try std.testing.expectEqual(expected, verdict.status);
        index += 1;
    };
    try std.testing.expectEqual(assertions.len, index);
}

/// Run one declaration and hand back the report plus the assertion list, both
/// owned by the caller.
const Run = struct {
    assertions: std.ArrayList(env.AssertionResult) = .empty,
    reports: std.ArrayList(Report) = .empty,

    fn go(self: *Run, allocator: std.mem.Allocator, spec: Spec) !Report {
        try evaluate(allocator, &self.assertions, &self.reports, spec);
        return self.reports.items[self.reports.items.len - 1];
    }

    fn deinit(self: *Run, allocator: std.mem.Allocator) void {
        freeReports(allocator, &self.reports);
        freeAssertions(allocator, &self.assertions);
    }
};

// spec: frequency-plan - the required RF window is checked against the delivered passband, so a fixed LO that closes the commanded band passes and one 950 MHz lower fails naming the uncovered sub-interval and the output frequencies it costs
test "band closure decides the Board A LO between 10.95 and 10.00 GHz" {
    const allocator = std.testing.allocator;

    var good = Run{};
    defer good.deinit(allocator);
    const closes = try good.go(allocator, boardASpec(10.95e9, .gate));
    try std.testing.expectEqual(Outcome.screened, closes.outcome);
    try std.testing.expectEqual(@as(usize, 1), closes.plans.len);
    const window = closes.plans[0].rf;
    try std.testing.expect(window.covered);
    try std.testing.expect(window.in_range);
    try std.testing.expectApproxEqAbs(@as(f64, 11.0e9), window.required.lo_hz, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 12.45e9), window.required.hi_hz, 1);
    try std.testing.expectEqual(Status.pass, verdictOf(closes, .band_closure).?.status);
    try std.testing.expectEqual(Status.pass, verdictOf(closes, .lo_drive).?.status);

    var bad = Run{};
    defer bad.deinit(allocator);
    const misses = try bad.go(allocator, boardASpec(10.0e9, .gate));
    const short = misses.plans[0].rf;
    try std.testing.expect(!short.covered);
    try std.testing.expect(short.uncovered_high.isEmpty());
    try std.testing.expectApproxEqAbs(@as(f64, 10.05e9), short.uncovered_low.lo_hz, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 10.5e9), short.uncovered_low.hi_hz, 1);

    const verdict = verdictOf(misses, .band_closure).?;
    try std.testing.expectEqual(Status.fail, verdict.status);
    // The message names the uncovered RF sub-interval and the output band it
    // costs — 450 MHz of RF is the bottom 450 MHz of the commanded band.
    try std.testing.expect(std.mem.indexOf(u8, verdict.message, "10050.000-10500.000 MHz falls below it") != null);
    try std.testing.expect(std.mem.indexOf(u8, verdict.message, "costing output 50.000-500.000 MHz") != null);
    // The source's electrical range still covers it — only the delivered
    // passband does not, which is exactly the distinction the conflict turns on.
    try std.testing.expectEqual(Status.pass, verdictOf(misses, .source_range).?.status);
}

// spec: frequency-plan - a failed plan limit is a warning in advisory mode and a failure in gate mode, with the same message and the same typed row either way
test "advisory and gate modes differ only in severity" {
    const allocator = std.testing.allocator;
    var advisory = Run{};
    defer advisory.deinit(allocator);
    const soft = try advisory.go(allocator, boardASpec(10.0e9, .advisory));

    var gate = Run{};
    defer gate.deinit(allocator);
    const hard = try gate.go(allocator, boardASpec(10.0e9, .gate));

    try std.testing.expectEqual(Mode.advisory, soft.mode);
    try std.testing.expectEqual(Status.warn, verdictOf(soft, .band_closure).?.status);
    try std.testing.expectEqual(Status.fail, verdictOf(hard, .band_closure).?.status);
    try std.testing.expectEqualStrings(verdictOf(hard, .band_closure).?.message, verdictOf(soft, .band_closure).?.message);
    try std.testing.expect(advisory.assertions.items[1].is_warning);
    try std.testing.expect(!gate.assertions.items[1].is_warning);
}

// spec: frequency-plan - each enumerated product is classified against the output band and the declared cutoffs, with the leakage rows present and the wanted product distinguished from the co-channel ones
test "spur classification separates co-channel, rejected and out-of-band products" {
    const allocator = std.testing.allocator;
    var run = Run{};
    defer run.deinit(allocator);
    const report = try run.go(allocator, boardASpec(10.95e9, .gate));
    const plan = report.plans[0];

    // Two leakage rows first, then the 3x3 square, in (m, then n) order.
    try std.testing.expectEqual(@as(usize, 11), plan.products.len);
    try std.testing.expectEqual(Order{ .m = 0, .n = 1 }, plan.products[0].order);
    try std.testing.expectEqual(Order{ .m = 1, .n = 0 }, plan.products[1].order);
    try std.testing.expectEqual(Order{ .m = 1, .n = 1 }, plan.products[2].order);
    try std.testing.expectEqual(Order{ .m = 3, .n = 3 }, plan.products[10].order);

    // LO leakage sits at the LO itself; RF leakage covers the whole sweep.
    try std.testing.expectApproxEqAbs(@as(f64, 10.95e9), plan.products[0].band.lo_hz, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 11.0e9), plan.products[1].band.lo_hz, 1);
    // Both are far above the 6 GHz IF low-pass, so both are rejected.
    try std.testing.expectEqual(Placement.filter_rejected, plan.products[0].placement);
    try std.testing.expectEqual(Rejection.if_low_pass, plan.products[0].rejection);
    try std.testing.expectEqual(Placement.filter_rejected, plan.products[1].placement);

    // (1,1) is the wanted product and is never counted as a spur.
    try std.testing.expectEqual(Placement.wanted, productOf(plan, 1, 1).placement);

    // (2,2) is the first diagonal: 2·IF, 100-3000 MHz, straddling the band's
    // top edge, so it is co-channel and no filter can remove it.
    const diagonal = productOf(plan, 2, 2);
    try std.testing.expectApproxEqAbs(@as(f64, 100e6), diagonal.band.lo_hz, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 3000e6), diagonal.band.hi_hz, 1);
    try std.testing.expectEqual(Placement.co_channel, diagonal.placement);

    // (2,3) runs 7.95-10.85 GHz — wholly above the 6 GHz IF low-pass.
    const rejected = productOf(plan, 2, 3);
    try std.testing.expectApproxEqAbs(@as(f64, 7.95e9), rejected.band.lo_hz, 1);
    try std.testing.expectEqual(Placement.filter_rejected, rejected.placement);
    try std.testing.expectEqual(Rejection.if_low_pass, rejected.rejection);

    // (3,2) runs 11.1-15.45 GHz: also above the cutoff. Nothing here is
    // out-of-band-unfiltered, and the placement line says so.
    try std.testing.expect(std.mem.indexOf(u8, verdictOf(report, .spur_placement).?.message, "enumerates 11 products to order 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, verdictOf(report, .spur_placement).?.message, "co-channel with the 50.000-1500.000 MHz output band") != null);
}

// spec: frequency-plan - a product whose signed frequency changes sign inside the required RF sweep is split into both folded branches, so it is seen to reach DC and lands in band where a single-interval fold would miss it
test "a product that crosses DC inside the sweep is split and lands in band" {
    const allocator = std.testing.allocator;
    // A 1000 MHz LO delivering 50-700 MHz sweeps RF over 1050-1700 MHz, so
    // 3·RF − 4·LO runs −850 … +1100 MHz: the sign changes inside the sweep.
    var spec = boardASpec(10.95e9, .gate);
    spec.mixer.lo.frequency_hz = 1000e6;
    spec.plan.output_band = .{ .lo_hz = 50e6, .hi_hz = 700e6 };
    spec.plan.source = .{};
    spec.plan.filters = .{};
    spec.spurs.max_order = 4;
    var run = Run{};
    defer run.deinit(allocator);
    const report = try run.go(allocator, spec);
    const crossing = productOf(report.plans[0], 3, 4);

    try std.testing.expectEqual(@as(usize, 2), crossing.branches.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0), crossing.branches.parts[0].lo_hz, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 850e6), crossing.branches.parts[0].hi_hz, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 0), crossing.branches.parts[1].lo_hz, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 1100e6), crossing.branches.parts[1].hi_hz, 1);
    // The hull reaches DC, so the product covers the whole output band. A
    // naive |endpoint| fold would have reported 850-1100 MHz — entirely above
    // the 50-700 MHz band — and called the whole band clear of it.
    try std.testing.expectApproxEqAbs(@as(f64, 0), crossing.band.lo_hz, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 1100e6), crossing.band.hi_hz, 1);
    try std.testing.expect(!Band.overlaps(.{ .lo_hz = 850e6, .hi_hz = 1100e6 }, spec.plan.output_band));
    try std.testing.expectEqual(Placement.co_channel, crossing.placement);
}

// spec: frequency-plan - a declared suppression entry is checked against the in-band limit at the co-channel product it names, and no level is claimed for any product the table omits
test "spur-table levels are asserted only where they are declared" {
    const allocator = std.testing.allocator;
    const nodes_at_limit = try parser.parse(allocator, "(product 2 2 -60)");
    defer parser.freeNodes(allocator, nodes_at_limit);
    const nodes_over = try parser.parse(allocator, "(product 2 2 -55)");
    defer parser.freeNodes(allocator, nodes_over);

    var at_limit = boardASpec(10.95e9, .gate);
    at_limit.spurs.in_band_limit_dbc = -60;
    at_limit.spurs.limit_declared = true;
    at_limit.spurs.table_nodes = nodes_at_limit;
    var run_ok = Run{};
    defer run_ok.deinit(allocator);
    const passing = try run_ok.go(allocator, at_limit);
    const level = productOf(passing.plans[0], 2, 2).level;
    try std.testing.expect(level.declared);
    try std.testing.expectEqual(@as(f64, -60), level.dbc);
    try std.testing.expectEqual(LevelVerdict.within_limit, level.verdict);
    try std.testing.expectEqual(Status.pass, verdictOf(passing, .spur_levels).?.status);
    try std.testing.expectEqual(@as(usize, 1), passing.profile.spurs.table.len);
    try std.testing.expectEqual(@as(u8, 2), passing.profile.spurs.table[0].n);

    var over = at_limit;
    over.spurs.table_nodes = nodes_over;
    var run_bad = Run{};
    defer run_bad.deinit(allocator);
    const failing = try run_bad.go(allocator, over);
    try std.testing.expectEqual(LevelVerdict.over_limit, productOf(failing.plans[0], 2, 2).level.verdict);
    try std.testing.expectEqual(Status.fail, verdictOf(failing, .spur_levels).?.status);
    try std.testing.expect(std.mem.indexOf(u8, verdictOf(failing, .spur_levels).?.message, "the worst is (2,2) at -55.0 dBc") != null);

    // With no table at all, every co-channel product is placement-only: no
    // level screen is emitted and the coverage warning says so plainly.
    var run_none = Run{};
    defer run_none.deinit(allocator);
    const bare = try run_none.go(allocator, boardASpec(10.95e9, .gate));
    try std.testing.expectEqual(@as(?Verdict, null), verdictOf(bare, .spur_levels));
    try std.testing.expect(!productOf(bare.plans[0], 2, 2).level.declared);
    try std.testing.expectEqual(LevelVerdict.unclaimed, productOf(bare.plans[0], 2, 2).level.verdict);
    const coverage_verdict = verdictOf(bare, .spur_coverage).?;
    try std.testing.expectEqual(Status.warn, coverage_verdict.status);
    try std.testing.expect(std.mem.indexOf(u8, coverage_verdict.message, "no level is claimed") != null);
}

// spec: frequency-plan - the reported diagonal family matches the closed-form count at the band's low edge at several band positions and names the IF above which the band carries none
test "the diagonal count follows the band it is taken over" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { band: Band, count: usize, clean_hz: f64 }{
        .{ .band = .{ .lo_hz = 50e6, .hi_hz = 1500e6 }, .count = 29, .clean_hz = 750e6 },
        .{ .band = .{ .lo_hz = 100e6, .hi_hz = 1500e6 }, .count = 14, .clean_hz = 750e6 },
        .{ .band = .{ .lo_hz = 500e6, .hi_hz = 1000e6 }, .count = 1, .clean_hz = 500e6 },
        .{ .band = .{ .lo_hz = 800e6, .hi_hz = 1000e6 }, .count = 0, .clean_hz = 500e6 },
    };
    for (cases) |case| {
        var spec = boardASpec(10.95e9, .gate);
        spec.plan.output_band = case.band;
        var run = Run{};
        defer run.deinit(allocator);
        const report = try run.go(allocator, spec);
        const diagonal = report.plans[0].diagonal;
        try std.testing.expectEqual(case.count, diagonal.worst_case_count);
        try std.testing.expectEqual(case.band.lo_hz, diagonal.worst_case_if_hz);
        try std.testing.expectApproxEqAbs(case.clean_hz, diagonal.clean_above_hz, 1e-6);
        // The enumeration is capped at order 3, so it can never report more
        // diagonals than the closed form counts.
        try std.testing.expect(diagonal.enumerated_count <= diagonal.worst_case_count);
        try std.testing.expect(diagonal.enumerated_count <= spec.spurs.max_order - 1);
    }
}

// spec: frequency-plan - the image sideband is placed and is called rejected only when a declared cutoff or the delivered passband actually excludes it
test "the image band is reported rejected only when something declared removes it" {
    const allocator = std.testing.allocator;
    var run = Run{};
    defer run.deinit(allocator);
    const report = try run.go(allocator, boardASpec(10.95e9, .gate));
    const image = report.plans[0].image;
    // 10.95 − 1.5 … 10.95 − 0.05 GHz, which overlaps the 10.5-12.9 GHz
    // delivered passband and sits under the 12.9 GHz RF low-pass: nothing
    // declared removes it, and the screen says exactly that.
    try std.testing.expectApproxEqAbs(@as(f64, 9.45e9), image.band.lo_hz, 1);
    try std.testing.expectApproxEqAbs(@as(f64, 10.9e9), image.band.hi_hz, 1);
    try std.testing.expectEqual(Rejection.none, image.rejection);
    try std.testing.expectEqual(Status.fail, verdictOf(report, .image_band).?.status);

    // Add an RF high-pass above the image and it is rejected.
    var filtered = boardASpec(10.95e9, .gate);
    filtered.plan.filters.rf_high_pass_hz = 10.95e9;
    var run_hp = Run{};
    defer run_hp.deinit(allocator);
    const clean = try run_hp.go(allocator, filtered);
    try std.testing.expectEqual(Rejection.rf_high_pass, clean.plans[0].image.rejection);
    try std.testing.expectEqual(Status.pass, verdictOf(clean, .image_band).?.status);
}

// spec: frequency-plan - each declaration publishes a typed report whose plans concatenate back into assertion order, one verdict per screen matching that assertion's pass/warn/fail, and (sideband either) publishes both sidebands high side first
test "the typed report agrees with the assertion text it accompanies" {
    const allocator = std.testing.allocator;
    var spec = boardASpec(10.95e9, .gate);
    spec.mixer.sideband = .either;
    var run = Run{};
    defer run.deinit(allocator);
    const report = try run.go(allocator, spec);

    try std.testing.expectEqualStrings(spec.name, report.name);
    try std.testing.expectEqual(Sense.difference, report.profile.mixer.sense);
    try std.testing.expectEqual(@as(f64, 10.95e9), report.profile.mixer.lo.frequency_hz);
    try std.testing.expectEqual(@as(f64, 6e9), report.profile.plan.filters.if_low_pass_hz);
    try std.testing.expectEqual(@as(u8, 3), report.profile.spurs.max_order);

    // Both sidebands, high first; the low-side window is the high side's image.
    try std.testing.expectEqual(@as(usize, 2), report.plans.len);
    try std.testing.expectEqual(Sideband.high, report.plans[0].sideband);
    try std.testing.expectEqual(Sideband.low, report.plans[1].sideband);
    try std.testing.expectEqual(report.plans[0].image.band.lo_hz, report.plans[1].rf.required.lo_hz);

    // The LO drive screen is charged to the first plan, ahead of its own
    // band-closure verdict.
    try std.testing.expectEqual(Screen.lo_drive, report.plans[0].verdicts[0].screen);
    try std.testing.expectEqual(Screen.band_closure, report.plans[0].verdicts[1].screen);
    try expectVerdictsTrackAssertions(run.assertions.items, report.plans);

    // Every plan's numbers are the ones its assertions print.
    var buffer: [256]u8 = undefined;
    for (report.plans) |plan| {
        const text = try std.fmt.bufPrint(&buffer, "{d:.3}-{d:.3} MHz", .{ mhz(plan.rf.required.lo_hz), mhz(plan.rf.required.hi_hz) });
        try std.testing.expect(std.mem.indexOf(u8, plan.verdicts[plan.verdicts.len - 1].message, "diagonal-clean above 750.000 MHz") != null);
        var found = false;
        for (plan.verdicts) |verdict| {
            if (std.mem.indexOf(u8, verdict.message, text) != null) found = true;
        }
        try std.testing.expect(found);
    }
}

// spec: frequency-plan - evaluating one declaration twice produces byte-identical assertions and structurally identical reports, so the analysis is a pure function of what was declared
test "evaluation is deterministic" {
    const allocator = std.testing.allocator;
    var spec = boardASpec(10.95e9, .gate);
    spec.mixer.sideband = .either;
    spec.spurs.max_order = 5;

    var run = Run{};
    defer run.deinit(allocator);
    _ = try run.go(allocator, spec);
    _ = try run.go(allocator, spec);

    try std.testing.expectEqual(@as(usize, 2), run.reports.items.len);
    const first = run.reports.items[0];
    const second = run.reports.items[1];
    try std.testing.expectEqual(first.outcome, second.outcome);
    try std.testing.expectEqual(first.plans.len, second.plans.len);
    for (first.plans, second.plans) |a, b| {
        try std.testing.expectEqual(a.sideband, b.sideband);
        try std.testing.expectEqual(a.rf, b.rf);
        try std.testing.expectEqual(a.image, b.image);
        try std.testing.expectEqual(a.diagonal, b.diagonal);
        try std.testing.expectEqual(a.products.len, b.products.len);
        for (a.products, b.products) |p, q| try std.testing.expectEqual(p, q);
        try std.testing.expectEqual(a.verdicts.len, b.verdicts.len);
        for (a.verdicts, b.verdicts) |x, y| {
            try std.testing.expectEqual(x.screen, y.screen);
            try std.testing.expectEqual(x.status, y.status);
            try std.testing.expectEqualStrings(x.message, y.message);
        }
    }
    // Order 5 enumerates the full square plus both leakage rows, and stays
    // inside the hard ceiling.
    try std.testing.expectEqual(@as(usize, 27), first.plans[0].products.len);
    try std.testing.expect(first.plans[0].products.len <= max_products);
}

// spec: frequency-plan - the parser requires a title, mode, output band, LO and mixer sense, bounds the enumeration order at nine, and refuses sum mixing rather than approximating it
test "the parser holds its documented bounds" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { text: []const u8, err: ?ParseError }{
        .{ .text = "(frequency-plan \"p\" (mode gate) (output-band 50M 1500M) (lo 10.95G) (mixer difference))", .err = null },
        .{ .text = "(frequency-plan \"p\" (mode gate) (output-band 50M 1500M) (lo 10.95G) (mixer difference (sideband either)) (spurs (max-order 9)))", .err = null },
        .{ .text = "(frequency-plan \"p\" (mode gate) (output-band 50M 1500M) (lo 10.95G) (mixer difference) (spurs (max-order 10)))", .err = error.SpurOrderTooHigh },
        .{ .text = "(frequency-plan \"p\" (mode gate) (output-band 50M 1500M) (lo 10.95G) (mixer sum))", .err = error.SumMixingUnsupported },
        .{ .text = "(frequency-plan \"p\" (output-band 50M 1500M) (lo 10.95G) (mixer difference))", .err = error.InvalidForm },
        .{ .text = "(frequency-plan \"p\" (mode gate) (lo 10.95G) (mixer difference))", .err = error.InvalidForm },
        .{ .text = "(frequency-plan \"p\" (mode gate) (output-band 50M 1500M) (mixer difference))", .err = error.InvalidForm },
        .{ .text = "(frequency-plan \"p\" (mode gate) (output-band 50M 1500M) (lo 10.95G))", .err = error.InvalidForm },
        .{ .text = "(frequency-plan \"p\" (mode gate) (output-band 1500M 50M) (lo 10.95G) (mixer difference))", .err = error.InvalidForm },
        // The delivered passband must lie inside the electrical range.
        .{ .text = "(frequency-plan \"p\" (mode gate) (output-band 50M 1500M) (source (range 10G 12G) (delivered 10.5G 12.9G)) (lo 10.95G) (mixer difference))", .err = error.InvalidForm },
    };
    for (cases) |case| {
        const nodes = try parser.parse(allocator, case.text);
        defer parser.freeNodes(allocator, nodes);
        const form = nodes[0].asList().?;
        if (case.err) |expected| {
            try std.testing.expectError(expected, parse(form));
        } else {
            _ = try parse(form);
        }
    }
}

// spec: frequency-plan - the authored Board A declaration round-trips through the parser into the same plan the fixture screens, with SI-suffixed frequencies and signed dBm resolved
test "the authored form parses into the screened plan" {
    const allocator = std.testing.allocator;
    const text =
        \\(frequency-plan "Board A Band 1"
        \\  (mode advisory)
        \\  (output-band 50M 1500M)
        \\  (source (range 10G 20G) (delivered 10.5G 12.9G))
        \\  (lo 10.95G (drive 21) (drive-window 17 23))
        \\  (mixer difference (sideband high))
        \\  (if-filter (low-pass 6G))
        \\  (rf-filter (low-pass 12.9G))
        \\  (spurs (max-order 3) (in-band-limit -60))
        \\  (spur-table (product 2 2 -60) (product 3 3 -66)))
    ;
    const nodes = try parser.parse(allocator, text);
    defer parser.freeNodes(allocator, nodes);
    const spec = try parse(nodes[0].asList().?);

    try std.testing.expectEqualStrings("Board A Band 1", spec.name);
    try std.testing.expectEqual(Mode.advisory, spec.mode);
    try std.testing.expectEqual(@as(f64, 10.95e9), spec.mixer.lo.frequency_hz);
    try std.testing.expectEqual(@as(f64, 21), spec.mixer.lo.drive_dbm);
    try std.testing.expectEqual(@as(f64, 17), spec.mixer.lo.window.min_dbm);
    try std.testing.expectEqual(@as(f64, -60), spec.spurs.in_band_limit_dbc);
    try std.testing.expectEqual(@as(usize, 2), spec.spurs.table_nodes.len);

    var run = Run{};
    defer run.deinit(allocator);
    const report = try run.go(allocator, spec);
    try std.testing.expectEqual(@as(usize, 2), report.profile.spurs.table.len);
    try std.testing.expectEqual(@as(f64, -66), report.profile.spurs.table[1].dbc);
    try std.testing.expectEqual(Status.pass, verdictOf(report, .band_closure).?.status);
    // (2,2) and (3,3) both carry declared suppression at or under the limit.
    try std.testing.expectEqual(Status.pass, verdictOf(report, .spur_levels).?.status);
    try std.testing.expectEqual(LevelVerdict.within_limit, productOf(report.plans[0], 3, 3).level.verdict);
}

// spec: frequency-plan - a low-side plan under an LO below the commanded band is refused as unrealizable rather than screened against a negative RF window
test "an unrealizable sideband is refused rather than screened" {
    const allocator = std.testing.allocator;
    var spec = boardASpec(10.95e9, .gate);
    spec.mixer.sideband = .low;
    spec.mixer.lo.frequency_hz = 1000e6;
    spec.plan.source = .{};
    var run = Run{};
    defer run.deinit(allocator);
    const report = try run.go(allocator, spec);

    try std.testing.expectEqual(Outcome.unrealizable, report.outcome);
    try std.testing.expectEqual(@as(usize, 1), report.plans.len);
    try std.testing.expectEqual(@as(usize, 0), report.plans[0].products.len);
    try std.testing.expectEqual(Status.fail, verdictOf(report, .rf_window).?.status);
    try expectVerdictsTrackAssertions(run.assertions.items, report.plans);
}
