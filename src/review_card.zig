//! The Board Review Card: one board's whole unit review as ONE value.
//!
//! The tool already answers every unit-review question somewhere — ERC in
//! `erc.zig`, class profiles and cited requirements in `preflight.zig` and
//! `review_profiles.zig`, applied stress against rating in the fabrication
//! gate, rails in `eval/power_budget.zig`, junction temperature in
//! `eval/thermal.zig`, copper in the DRC, the ladder in `placement/progress.zig`
//! — but each answered in its own vocabulary, on its own surface. What did not
//! exist was ONE shape a reviewer could read: the twelve fixed categories of
//! `review_registry.Category`, every row citing a registered check id, every
//! verdict spelled in the seven-word vocabulary, with the categories the board
//! never gave an input to saying `not_declared` rather than saying nothing.
//!
//! That is this module. `collect` runs the engines once and attributes their
//! findings to registry rows; the composer looks each id up in the registry, so
//! a row's category, scope, policy and "closes with" cannot drift from the
//! catalogue — the id decides them. An engine outcome with no registry row is a
//! registry bug, not a card bug: the fix is to register the row.
//!
//! Every surface renders from this one struct: `GET /api/review-card/:name`,
//! the `review_card` CLI tool, `netlisp review-card`, and the Board Review
//! Audit Markdown (`review_audit.render`), so an agent, a reviewer reading the
//! page and a committed audit document can never be told different verdicts
//! about the same board.
//!
//! Read-only: nothing here writes to the project directory.

const std = @import("std");
const brief_checks = @import("brief_checks.zig");
const env = @import("eval/env.zig");
const erc_mod = @import("erc.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;
const frequency_plan = @import("frequency_plan.zig");
const json_writer = @import("json_writer.zig");
const part_review = @import("part_review.zig");
const paths = @import("paths.zig");
const pll_loop = @import("pll_loop.zig");
const power_budget = @import("eval/power_budget.zig");
const preflight = @import("preflight.zig");
const registry = @import("review_registry.zig");
const review_audit = @import("review_audit.zig");
const drc = @import("placement/drc.zig");
const thermal = @import("eval/thermal.zig");

/// The seven-word verdict vocabulary, taken from the registry so the card, the
/// catalogue and the per-part review spell verdicts one way.
pub const Verdict = registry.Verdict;

/// How many rows produced each verdict — the count stripe a category (and the
/// whole card) shows at a glance.
pub const Stripe = struct {
    /// Rows the engine decided in the design's favour.
    pass: usize = 0,
    /// Rows the engine decided against it.
    fail: usize = 0,
    /// Rows the engine ran and could not decide, naming the missing input.
    unproven: usize = 0,
    /// Rows a linked record closes.
    waived: usize = 0,
    /// Rows whose population this board does not have.
    not_applicable: usize = 0,
    /// Rows whose input the board never declared at all.
    not_declared: usize = 0,
    /// Rows only a person can close, with evidence.
    manual: usize = 0,

    /// Tally one more row.
    pub fn add(self: *Stripe, verdict: Verdict) void {
        switch (verdict) {
            .pass => self.pass += 1,
            .fail => self.fail += 1,
            .unproven => self.unproven += 1,
            .waived => self.waived += 1,
            .not_applicable => self.not_applicable += 1,
            .not_declared => self.not_declared += 1,
            .manual => self.manual += 1,
        }
    }

    /// How many rows the stripe counts.
    pub fn total(self: Stripe) usize {
        return self.pass + self.fail + self.unproven + self.waived +
            self.not_applicable + self.not_declared + self.manual;
    }

    /// The worst verdict the stripe carries — the order a reviewer triages in:
    /// fail, then a never-declared input, then an undecided engine, then a
    /// human's row, then a waiver, then a pass.
    pub fn worst(self: Stripe) Verdict {
        if (self.fail > 0) return .fail;
        if (self.not_declared > 0) return .not_declared;
        if (self.unproven > 0) return .unproven;
        if (self.manual > 0) return .manual;
        if (self.waived > 0) return .waived;
        if (self.pass > 0) return .pass;
        return .not_applicable;
    }
};

/// One judged check on this board: the registry id it cites, what it was about
/// and what the engine said.
pub const Row = struct {
    /// The registry id. Every field below the subject comes from its row.
    id: []const u8,
    /// The registered scope's tag (`part`, `pin`, `net`, `rail`, `board`,
    /// `system`).
    scope: []const u8,
    /// What this row is about: a ref, a net, a rail, or `board`.
    subject: []const u8,
    /// What the engine returned, as a reviewer reads it.
    result: []const u8,
    /// The verdict, in the shared seven-word vocabulary.
    verdict: Verdict,
    /// Which engine and finding produced the result.
    evidence: []const u8,
    /// The DSL form or action that closes the row, from the registry.
    closes_with: []const u8,
    /// The registered policy's tag (`blocking`, `waivable`, `advisory`).
    policy: []const u8,
    /// The record a `waived` row is closed by — a waiver register entry or a
    /// `(verifies …)` rationale. Empty on every other row.
    record: []const u8 = "",
};

/// One of the twelve fixed categories, with its rows and their stripe.
pub const Category = struct {
    /// The `review_registry.Category` tag.
    key: []const u8,
    /// The heading a surface prints.
    title: []const u8,
    /// Every row the run produced for this category, in composition order.
    rows: []const Row = &.{},
    /// The verdict tally of `rows`.
    stripe: Stripe = .{},
};

/// One active part's row in the card's part table — the audit's Stage 1b cells
/// plus the part's review chip.
pub const PartRow = struct {
    /// Sub-block-qualified ref (`ldo_3v3_lmx/U21`).
    ref: []const u8,
    /// The library component fitted there.
    component: []const u8,
    /// The class profile it was judged under, marked `(inferred)` when the
    /// class was guessed from the pins rather than declared.
    class: []const u8,
    /// The datasheet-review status preflight reported.
    review: []const u8,
    /// Requirement tally, `N ok / M unmet`.
    checks: []const u8,
    /// Electrical declarations and whether the supply-current item is open.
    data: []const u8,
    /// The unmet class-profile item codes, or `none`.
    unmet: []const u8,
    /// The part's slice of the card, as the BOM tab's Review column shows it.
    chip: part_review.Chip,
    /// The worst verdict any of the part's rows produced.
    verdict: Verdict,
};

/// The board-level answer: how many open rows there are at each policy, and
/// whether anything blocks a release.
pub const Overall = struct {
    /// The worst verdict on the card.
    verdict: Verdict = .not_applicable,
    /// Every row of the card, tallied.
    stripe: Stripe = .{},
    /// Open (`fail` or `not_declared`) rows whose policy blocks a release.
    blocking: usize = 0,
    /// Open rows a waiver record could close.
    waivable: usize = 0,
    /// Open rows that never block.
    advisory: usize = 0,
    /// True when nothing blocking is open.
    releasable: bool = false,
};

/// One board's whole unit review.
pub const Card = struct {
    /// The design the card is about.
    design: []const u8,
    /// The board and the run, as the fabrication gate settled them.
    identity: review_audit.Identity,
    /// The content digests the evidence is bound to.
    digests: review_audit.Digests = .{},
    /// The schematic-side tallies of the release-profile run.
    schematic: review_audit.Schematic = .{},
    /// The twelve categories, in `review_registry.Category` order.
    categories: []const Category = &.{},
    /// One row per active part.
    parts: []const PartRow = &.{},
    /// The fabrication gate's verdict, finding ids and board statistics.
    fab: review_audit.Fab = .{},
    /// The completion ladder and the DRC tallies of the reviewed layout.
    layout: review_audit.Layout = .{},
    /// Every error- or warning-severity finding, for the audit's register.
    findings: []const review_audit.FindingRow = &.{},
    /// The board-level answer.
    overall: Overall = .{},
    /// The ambient the thermal rows were screened at (°C).
    ambient_c: f64 = thermal.default_ambient_c,

    /// The category with this key, or null when the card was built without it.
    pub fn find(self: Card, key: registry.Category) ?Category {
        for (self.categories) |category| {
            if (std.mem.eql(u8, category.key, @tagName(key))) return category;
        }
        return null;
    }

    /// The first row citing `id`, or null when the run produced none. Surfaces
    /// that render one named check (the audit's stage tables) read it here so
    /// the text they print is the text the card carries.
    pub fn row(self: Card, id: []const u8) ?Row {
        for (self.categories) |category| {
            for (category.rows) |item| {
                if (std.mem.eql(u8, item.id, id)) return item;
            }
        }
        return null;
    }
};

/// Everything `collect` can fail with beyond allocation.
pub const CollectError = std.mem.Allocator.Error || error{ EvaluateFailed, NotADesign, InvalidName };

/// Which saved layout to review, and what ambient to screen the thermal rows
/// at. `layout` null means the starred one; `ambient_c` null means the
/// screen's default.
pub const Options = struct {
    /// Saved layout name, or null for the starred layout.
    layout: ?[]const u8 = null,
    /// Ambient temperature in °C, or null for `thermal.default_ambient_c`.
    ambient_c: ?f64 = null,
};

const category_count: usize = std.enums.values(registry.Category).len;

// ── Composition ───────────────────────────────────────────────────────────

/// One row on its way into the card. The registry supplies everything the
/// caller does not: the category the row lands in, its scope, its policy and
/// the form that closes it.
const Emit = struct {
    id: []const u8,
    subject: []const u8 = "board",
    result: []const u8,
    verdict: Verdict,
    evidence: []const u8,
    record: []const u8 = "",
};

/// Collects rows into their registered categories.
const Composer = struct {
    arena: std.mem.Allocator,
    lists: [category_count]std.ArrayList(Row) = @splat(.empty),

    /// Register one judged check. An id the catalogue does not carry is
    /// DROPPED rather than guessed at — a test enumerates every id this module
    /// emits and fails when one is unregistered, which is where that bug
    /// belongs.
    ///
    /// The three free-text cells are COPIED into the arena. Most engine strings
    /// live in the design block the arena also owns, but a few do not: an
    /// analysis verdict's message belongs to the evaluator's assertion list and
    /// dies with `Evaluator.deinit`, which a caller may run before it serializes
    /// the card (`collect` does exactly that). Copying here is what lets the
    /// card outlive the run that produced it.
    fn add(self: *Composer, emit: Emit) std.mem.Allocator.Error!void {
        const registered = registry.lookup(emit.id) orelse return;
        try self.lists[@backingInt(registered.category)].append(self.arena, .{
            .id = registered.id,
            .scope = @tagName(registered.scope),
            .subject = try self.arena.dupe(u8, emit.subject),
            .result = try self.arena.dupe(u8, emit.result),
            .verdict = emit.verdict,
            .evidence = try self.arena.dupe(u8, emit.evidence),
            .closes_with = registered.closes_with,
            .policy = @tagName(registered.policy),
            .record = try self.arena.dupe(u8, emit.record),
        });
    }

    /// Arena-owned formatted text for a result or subject cell.
    fn fmt(self: *Composer, comptime pattern: []const u8, args: anytype) std.mem.Allocator.Error![]const u8 {
        return std.fmt.allocPrint(self.arena, pattern, args);
    }

    /// Freeze the collected rows into the twelve categories, in registry order.
    fn finish(self: *Composer) std.mem.Allocator.Error![]const Category {
        const out = try self.arena.alloc(Category, category_count);
        for (std.enums.values(registry.Category), 0..) |key, index| {
            const rows = try self.lists[index].toOwnedSlice(self.arena);
            var stripe: Stripe = .{};
            for (rows) |item| stripe.add(item.verdict);
            out[index] = .{ .key = @tagName(key), .title = key.title(), .rows = rows, .stripe = stripe };
        }
        return out;
    }
};

/// The per-part review's verdict word as the registry spells it. The two enums
/// carry the same seven tags; this switch is what keeps them that way.
fn verdictOf(verdict: part_review.Verdict) Verdict {
    return switch (verdict) {
        .pass => .pass,
        .fail => .fail,
        .unproven => .unproven,
        .waived => .waived,
        .not_applicable => .not_applicable,
        .not_declared => .not_declared,
        .manual => .manual,
    };
}

fn passFail(ok: bool) Verdict {
    return if (ok) .pass else .fail;
}

// ── Identity and sources ──────────────────────────────────────────────────

/// The ladder rung with this id, or null when the ladder does not carry it.
fn ladderStage(layout: review_audit.Layout, id: []const u8) ?review_audit.StageRow {
    for (layout.ladder) |stage| {
        if (std.mem.eql(u8, stage.id, id)) return stage;
    }
    return null;
}

/// True when a rung reports itself finished.
fn stageDone(stage: review_audit.StageRow) bool {
    if (std.mem.eql(u8, stage.status, "done")) return true;
    return stage.total > 0 and stage.done == stage.total;
}

fn frozenVerdict(layout: review_audit.Layout) Verdict {
    if (!layout.available) return .unproven;
    const placement = ladderStage(layout, "placement") orelse return .unproven;
    const subs = ladderStage(layout, "sub_circuits") orelse return .unproven;
    if (stageDone(placement) and stageDone(subs)) return .pass;
    return .fail;
}

fn stageCell(c: *Composer, layout: review_audit.Layout, id: []const u8) std.mem.Allocator.Error![]const u8 {
    const stage = ladderStage(layout, id) orelse return c.fmt("{s}: not run", .{id});
    return c.fmt("{s}: {s} {d}/{d}", .{ id, stage.status, stage.done, stage.total });
}

fn identityRows(c: *Composer, facts: review_audit.Facts) std.mem.Allocator.Error!void {
    const identity = facts.identity;
    const clean = std.mem.eql(u8, identity.project_status, "clean");
    // "unknown" (the gate did not run) and "unavailable" (it ran where no
    // revision control could answer) are both an unread input, not a dirty
    // tree: the row says the screen could not decide rather than failing it.
    const known = !std.mem.eql(u8, identity.project_status, "unknown") and
        !std.mem.eql(u8, identity.project_status, "unavailable");
    try c.add(.{
        .id = "source-tree-clean",
        .result = identity.project_status,
        .verdict = if (!known) .unproven else passFail(clean),
        .evidence = "run_fab_readiness.project_status",
    });
    try c.add(.{
        .id = "revision-missing",
        .result = if (identity.revision.len > 0) identity.revision else "no (revision …) on the design block",
        .verdict = if (identity.revision.len > 0) .pass else .not_declared,
        .evidence = "board source",
    });
    const warnings = facts.schematic.build_warnings;
    try c.add(.{
        .id = "build-warning-free",
        .result = try c.fmt("{d} evaluator warning(s)", .{warnings.len}),
        .verdict = passFail(warnings.len == 0),
        .evidence = if (warnings.len > 0) warnings[0] else "netlisp build",
    });
    const placement = try stageCell(c, facts.layout, "placement");
    const subs = try stageCell(c, facts.layout, "sub_circuits");
    try c.add(.{
        .id = "layout-frozen",
        .result = try c.fmt("{s}; {s}", .{ placement, subs }),
        .verdict = frozenVerdict(facts.layout),
        .evidence = "get_layout_progress",
    });
    try identityGateRows(c, facts);
}

fn identityGateRows(c: *Composer, facts: review_audit.Facts) std.mem.Allocator.Error!void {
    const errors = facts.fab.error_ids;
    try c.add(.{
        .id = "release-gate-clear",
        .result = if (!facts.fab.available)
            "the fabrication gate did not run"
        else if (errors.len == 0)
            "no gate error"
        else
            try std.mem.join(c.arena, ", ", errors),
        .verdict = if (!facts.fab.available) .unproven else passFail(errors.len == 0),
        .evidence = "run_fab_readiness.errors",
    });
    const schematic = facts.schematic;
    try c.add(.{
        .id = "schematic-check-failed",
        .result = try c.fmt("release-profile check: {d} error(s) / {d} warning(s) / {d} info(s)", .{
            schematic.preflight_errors,
            schematic.preflight_warnings,
            schematic.preflight_infos,
        }),
        .verdict = passFail(schematic.preflight_errors == 0),
        .evidence = "netlisp check --profile release",
    });
    try c.add(.{
        .id = "erc-clean",
        .result = try c.fmt("{d} ERC error(s) / {d} warning(s)", .{ schematic.erc_errors, schematic.erc_warnings }),
        .verdict = passFail(schematic.erc_errors + schematic.erc_warnings == 0),
        .evidence = "netlisp check",
    });
    try c.add(.{
        .id = "design-notes-closed",
        .result = try c.fmt("{d} open design note(s)", .{schematic.notes_open}),
        .verdict = passFail(schematic.notes_open == 0),
        .evidence = "list_design_notes",
    });
    try c.add(.{
        .id = "release-differential-reviewed",
        .result = "a person diffs this package against the previous release",
        .verdict = .manual,
        .evidence = "gerber-dump --digest and netlist-dump on both commits",
    });
}

// ── Electrical rules ──────────────────────────────────────────────────────

/// How many violations of one kind the run reported, at which severities.
const Tally = struct {
    count: usize = 0,
    errors: usize = 0,
    warnings: usize = 0,
    first: []const u8 = "",
    subject: []const u8 = "board",
};

fn tallyKind(violations: []const erc_mod.Violation, kind: erc_mod.ViolationKind) Tally {
    var tally: Tally = .{};
    for (violations) |violation| {
        if (violation.kind != kind) continue;
        tally.count += 1;
        switch (violation.severity) {
            .@"error" => tally.errors += 1,
            .warning => tally.warnings += 1,
            .info => {},
        }
        if (tally.count > 1) continue;
        tally.first = violation.message;
        if (violation.ref_des.len > 0) tally.subject = violation.ref_des;
        if (violation.ref_des.len == 0 and violation.net.len > 0) tally.subject = violation.net;
    }
    return tally;
}

/// One row per electrical-rule kind, whether or not it fired: a kind the run
/// found nothing under is a `pass` a reviewer can see, not a silence.
fn ercRows(c: *Composer, violations: []const erc_mod.Violation) std.mem.Allocator.Error!void {
    for (std.enums.values(erc_mod.ViolationKind)) |kind| {
        const tally = tallyKind(violations, kind);
        if (tally.count == 0) {
            try c.add(.{
                .id = registry.ercId(kind),
                .result = "clean",
                .verdict = .pass,
                .evidence = try c.fmt("erc.zig {s}", .{@tagName(kind)}),
            });
            continue;
        }
        // An error or a warning is a decided failure; an informational
        // violation is the engine saying it could not decide, and names what it
        // was missing in the same sentence.
        const decided = tally.errors + tally.warnings > 0;
        try c.add(.{
            .id = registry.ercId(kind),
            .subject = tally.subject,
            .result = try c.fmt("{d} violation(s): {s}", .{ tally.count, tally.first }),
            .verdict = if (decided) .fail else .unproven,
            .evidence = try c.fmt("erc.zig {s}", .{@tagName(kind)}),
        });
    }
}

// ── Fabrication gate, DRC and the ladder ──────────────────────────────────

/// A gate warning is not a pass and not yet a waiver: the register entry that
/// would close it is the input the card is missing, so the row reads
/// `unproven` on a waivable check and `fail` on one that blocks outright.
fn warningVerdict(id: []const u8) Verdict {
    const registered = registry.lookup(id) orelse return .fail;
    return if (registered.policy == .blocking) .fail else .unproven;
}

fn fabRows(c: *Composer, fab: review_audit.Fab) std.mem.Allocator.Error!void {
    // The gate's finding id IS the registry id for its own screens, and an
    // alias for the check-run kinds it folds in — either way the registry, not
    // this loop, decides which category the finding lands in.
    for (fab.error_ids) |id| {
        try c.add(.{
            .id = registry.fabFindingId(id) orelse continue,
            .result = try c.fmt("fabrication gate error {s}", .{id}),
            .verdict = .fail,
            .evidence = "run_fab_readiness.errors",
        });
    }
    for (fab.warning_ids) |id| {
        const registered = registry.fabFindingId(id) orelse continue;
        try c.add(.{
            .id = registered,
            .result = try c.fmt("fabrication gate warning {s}", .{id}),
            .verdict = warningVerdict(registered),
            .evidence = "run_fab_readiness.warnings",
            .record = if (fab.needs_waiver) "docs/drc-waivers.md" else "",
        });
    }
}

/// One row per DRC kind the run reported. A warning-severity finding is
/// `unproven` whatever the kind's policy says: the run decided the geometry
/// and the reviewer's waiver record is the input the card is still missing.
fn drcKindRows(c: *Composer, counts: []const review_audit.KindCount, severity: []const u8) std.mem.Allocator.Error!void {
    const failed = std.mem.eql(u8, severity, "error");
    for (counts) |entry| {
        const kind = std.meta.stringToEnum(drc.Kind, entry.kind) orelse continue;
        try c.add(.{
            .id = registry.drcId(kind),
            .result = try c.fmt("{d} DRC {s}(s)", .{ entry.count, severity }),
            .verdict = if (failed) .fail else .unproven,
            .evidence = try c.fmt("run_fab_readiness.raw_drc {s}", .{entry.kind}),
            .record = if (failed) "" else "docs/drc-waivers.md",
        });
    }
}

fn layoutRows(c: *Composer, layout: review_audit.Layout) std.mem.Allocator.Error!void {
    if (!layout.available) {
        try c.add(.{
            .id = "layout-ladder-complete",
            .result = "no layout progress for this design",
            .verdict = .not_declared,
            .evidence = "get_layout_progress",
        });
    }
    for (layout.ladder) |stage| {
        try c.add(.{
            .id = "layout-ladder-complete",
            .subject = stage.id,
            .result = try c.fmt("{s} {d}/{d}", .{ stage.status, stage.done, stage.total }),
            .verdict = if (stageDone(stage)) .pass else .unproven,
            .evidence = "get_layout_progress",
        });
    }
    try c.add(.{
        .id = "drc",
        .result = try c.fmt("{d} DRC error(s) on the reviewed layout", .{layout.drc_errors}),
        .verdict = passFail(layout.drc_errors == 0),
        .evidence = "run_fab_readiness.raw_drc",
    });
    try c.add(.{
        .id = "drc-warn",
        .result = try c.fmt("{d} DRC warning(s) in {d} categor(ies)", .{ layout.drc_warnings, layout.by_kind.len }),
        .verdict = if (layout.drc_warnings == 0) .pass else .unproven,
        .evidence = "run_fab_readiness.raw_drc; docs/drc-waivers.md must list each count",
        .record = if (layout.drc_warnings > 0) "docs/drc-waivers.md" else "",
    });
    try drcKindRows(c, layout.error_by_kind, "error");
    try drcKindRows(c, layout.by_kind, "warning");
}

// ── Power budget ──────────────────────────────────────────────────────────

fn railMarginRow(c: *Composer, rail: power_budget.Rail) std.mem.Allocator.Error!void {
    const margin = rail.margin_pct orelse {
        try c.add(.{
            .id = "rail-budget-margin",
            .subject = rail.net,
            .result = "no margin: the source or the load is unannotated",
            .verdict = .not_declared,
            .evidence = "eval/power_budget.zig",
        });
        return;
    };
    try c.add(.{
        .id = "rail-budget-margin",
        .subject = rail.net,
        .result = try c.fmt("{d:.1} A typical of {d:.1} A source; {d:.0} % margin", .{
            rail.load_typ_a,
            rail.source_typ_a orelse 0,
            margin,
        }),
        .verdict = passFail(rail.status != .over),
        .evidence = try c.fmt("eval/power_budget.zig {s}", .{@tagName(rail.status)}),
    });
}

fn railRows(c: *Composer, rails: []const power_budget.Rail) std.mem.Allocator.Error!void {
    if (rails.len == 0) {
        try c.add(.{
            .id = "rail-sourced",
            .result = "the power budget resolved no rail: no source declares (current …) capacity",
            .verdict = .not_declared,
            .evidence = "eval/power_budget.zig",
        });
        return;
    }
    for (rails) |rail| {
        try c.add(.{
            .id = "rail-sourced",
            .subject = rail.net,
            .result = if (rail.source_label.len > 0)
                try c.fmt("sourced by {s}", .{rail.source_label})
            else
                "no source declares capacity for this rail",
            .verdict = if (rail.source_label.len > 0) .pass else .not_declared,
            .evidence = "eval/power_budget.zig",
        });
        try c.add(.{
            .id = "rail-consumers-annotated",
            .subject = rail.net,
            .result = if (rail.any_max_load)
                try c.fmt("{d} consumer(s), {d:.3} A worst case", .{ rail.consumers.len, rail.load_max_a })
            else
                try c.fmt("{d} consumer(s), no (i-max …) on any of them", .{rail.consumers.len}),
            .verdict = if (rail.any_max_load) .pass else .not_declared,
            .evidence = "eval/power_budget.zig",
        });
        try railMarginRow(c, rail);
    }
}

// ── Parts ─────────────────────────────────────────────────────────────────

fn datasheetRow(c: *Composer, part: part_review.PartReview) std.mem.Allocator.Error!void {
    const block = part.datasheet;
    try c.add(.{
        .id = "datasheet-review-complete",
        .subject = part.ref,
        .result = if (block.message.len > 0) block.message else try c.fmt("review {s}", .{block.status}),
        .verdict = verdictOf(block.verdict),
        .evidence = "run_checks datasheet_review",
        .record = block.record.date,
    });
}

fn profileRows(c: *Composer, part: part_review.PartReview) std.mem.Allocator.Error!void {
    for (part.profile_items) |item| {
        const id = registry.profileItemId(item.code) orelse continue;
        try c.add(.{
            .id = id,
            .subject = part.ref,
            .result = item.message,
            .verdict = .not_declared,
            .evidence = try c.fmt("review_profiles item {s}", .{item.code}),
        });
    }
}

fn requirementRows(c: *Composer, part: part_review.PartReview) std.mem.Allocator.Error!void {
    var open: usize = 0;
    for (part.requirements) |req| {
        if (req.verdict == .pass) continue;
        if (std.mem.eql(u8, req.check, "voltage-range")) continue;
        open += 1;
        const id = registry.checkPrimitiveId(req.check) orelse "requirement-check";
        try c.add(.{
            .id = id,
            .subject = try c.fmt("{s} {s}", .{ part.ref, req.id }),
            .result = if (req.message.len > 0) req.message else req.text,
            .verdict = verdictOf(req.verdict),
            .evidence = try c.fmt("preflight requirement {s}", .{req.status}),
            .record = req.rationale,
        });
    }
    if (open > 0) return;
    try c.add(.{
        .id = "requirement-check",
        .subject = part.ref,
        .result = try c.fmt("{d} cited requirement(s), all closed", .{part.requirements.len}),
        .verdict = if (part.requirements.len == 0) .not_declared else .pass,
        .evidence = "preflight requirement",
    });
}

fn supplyRows(c: *Composer, part: part_review.PartReview) std.mem.Allocator.Error!void {
    for (part.supply_windows) |window| {
        try c.add(.{
            .id = "check-voltage-range",
            .subject = try c.fmt("{s} {s}", .{ part.ref, window.pin }),
            .result = if (window.message.len > 0)
                window.message
            else
                try c.fmt("window {d} .. {d} V", .{ window.min_v, window.max_v }),
            .verdict = verdictOf(window.verdict),
            .evidence = "req_checks voltage-range over eval/net_envelopes",
        });
    }
}

/// Applied stress against rating, for EVERY placement — the screen judges the
/// passives a class profile never looks at, and those are most of the parts a
/// rating question is actually about. Returns how many rows it emitted so the
/// caller can state a clean screen rather than an empty category.
fn ratingRows(c: *Composer, part: part_review.PartReview) std.mem.Allocator.Error!usize {
    var emitted: usize = 0;
    for (part.ratings) |rating| {
        const id = registry.fabFindingId(rating.id) orelse continue;
        emitted += 1;
        try c.add(.{
            .id = id,
            .subject = part.ref,
            .result = rating.message,
            .verdict = verdictOf(rating.verdict),
            .evidence = try c.fmt("fab gate {s} ({s})", .{ rating.id, rating.severity }),
        });
    }
    return emitted;
}

fn partThermalRow(c: *Composer, part: part_review.PartReview) std.mem.Allocator.Error!void {
    const row = part.thermal orelse {
        try c.add(.{
            .id = "thermal-dissipation-known",
            .subject = part.ref,
            .result = "no dissipation declared and none derived",
            .verdict = .not_declared,
            .evidence = "eval/thermal.zig",
        });
        return;
    };
    if (row.has_power) {
        try c.add(.{
            .id = "thermal-dissipation-known",
            .subject = part.ref,
            .result = try c.fmt("{s} at theta-JA {s}; Tj {s}", .{ row.power, row.theta, row.tj }),
            .verdict = .pass,
            .evidence = "eval/thermal.zig",
        });
        return;
    }
    try c.add(.{
        .id = "thermal-dissipation-known",
        .subject = part.ref,
        .result = "no (power …) on the placement and none derived",
        .verdict = .not_declared,
        .evidence = "eval/thermal.zig",
    });
}

fn partRows(c: *Composer, board: part_review.Board) std.mem.Allocator.Error!void {
    var active: usize = 0;
    var met: usize = 0;
    var rating_rows: usize = 0;
    for (board.parts) |part| {
        rating_rows += try ratingRows(c, part);
        if (!part.active) continue;
        active += 1;
        if (part.profile_items.len == 0) met += 1;
        try datasheetRow(c, part);
        try profileRows(c, part);
        try requirementRows(c, part);
        try supplyRows(c, part);
        try partThermalRow(c, part);
    }
    if (rating_rows == 0) {
        try c.add(.{
            .id = "component-underrated",
            .result = try c.fmt("the rating screen judged {d} placement(s) and found none underrated", .{board.parts.len}),
            .verdict = if (board.parts.len == 0) .not_applicable else .pass,
            .evidence = "fab_readiness rating screen",
        });
    }
    try c.add(.{
        .id = "class-profile-items-met",
        .result = try c.fmt("{d} of {d} active part(s) meet every class-profile item", .{ met, active }),
        .verdict = if (active == 0) .not_applicable else if (met == active) .pass else .not_declared,
        .evidence = "run_checks profile_incomplete",
    });
    try bomRows(c, board);
}

fn bomRows(c: *Composer, board: part_review.Board) std.mem.Allocator.Error!void {
    var missing: usize = 0;
    var purchasable: usize = 0;
    for (board.parts) |part| {
        if (part.identity.dnp) continue;
        purchasable += 1;
        if (part.identity.mpn.len == 0) missing += 1;
    }
    try c.add(.{
        .id = "bom-identity",
        .result = try c.fmt("{d} of {d} purchasable placement(s) carry an MPN", .{ purchasable - missing, purchasable }),
        .verdict = if (purchasable == 0) .not_applicable else if (missing == 0) .pass else .not_declared,
        .evidence = "bom.zig resolve; run_fab_readiness bom-identity",
    });
    try c.add(.{
        .id = "bom-lifecycle-stock-dated",
        .result = "a person records lifecycle and a dated stock check per purchasable part",
        .verdict = .manual,
        .evidence = "resolve_mpn and check_stock",
    });
}

// ── Thermal and domain analyses ───────────────────────────────────────────

fn boardThermalVerdict(verdict: thermal.Verdict) Verdict {
    return switch (verdict) {
        .passive_ok => .pass,
        .needs_airflow, .needs_heatsink => .unproven,
        .over_limit => .fail,
        .insufficient_data => .not_declared,
    };
}

fn thermalRows(
    c: *Composer,
    heat: thermal.BoardThermal,
    block: *const env.DesignBlock,
    plan: brief_checks.Plan,
) std.mem.Allocator.Error!void {
    try c.add(.{
        .id = registry.thermalVerdictId(heat.verdict),
        .result = try c.fmt("{s} at {d:.0} °C ambient; limiting part {s}; usable to {d:.0} °C", .{
            @tagName(heat.verdict),
            heat.ambient_c,
            if (heat.limiting_ref.len > 0) heat.limiting_ref else "none",
            heat.max_ambient.c orelse 0,
        }),
        .verdict = boardThermalVerdict(heat.verdict),
        .evidence = "eval/thermal.zig board screen",
    });
    // Where the ambient came from: a governing system brief, or the bench
    // default nobody stated.
    const window = plan.window;
    try c.add(.{
        .id = "thermal-brief-ambient",
        .result = if (window) |w|
            try c.fmt("screened at {d:.0} °C, the ambient MAX of system {s}'s brief (window {d:.0} .. {d:.0} °C)", .{
                plan.ambient_c,
                plan.source.system,
                w.min_c,
                w.max_c,
            })
        else
            try c.fmt("no system brief states (environment (ambient …)); screened at the {d:.0} °C bench default", .{heat.ambient_c}),
        .verdict = if (window == null) .not_declared else .pass,
        .evidence = "brief_checks.planFor",
    });
    try coolingRow(c, block, plan);
}

fn coolingRow(c: *Composer, block: *const env.DesignBlock, plan: brief_checks.Plan) std.mem.Allocator.Error!void {
    const assembly = block.board.thermal;
    const cooled = assembly.heatsink != null or assembly.fan != null;
    if (plan.source.cooling.len > 0) {
        try c.add(.{
            .id = "thermal-board-cooling-scenario",
            .result = try c.fmt("the brief declares cooling {s}, screened as {s}{s}", .{
                plan.source.cooling,
                plan.source.scenario,
                if (plan.source.note.len > 0) " (approximated)" else "",
            }),
            .verdict = .pass,
            .evidence = "brief_checks.scenarioFor",
        });
        return;
    }
    try c.add(.{
        .id = "thermal-board-cooling-scenario",
        .result = if (cooled)
            "the board declares a cooling assembly, but no brief states the release scenario"
        else
            "no cooling declared; the screen ran in still air at the default ambient",
        .verdict = if (cooled) .unproven else .not_declared,
        .evidence = "(brief (environment (cooling …))) / (board (heatsink …))",
    });
}

/// The four checks a brief makes answerable, and the derating standard it
/// names. `observe` reports only what a board FAILED or never declared, so a
/// governed board that meets a check gets its `pass` row stated here — and a
/// board no brief governs gets `not_declared` on all five rather than silence.
fn briefRows(
    c: *Composer,
    plan: brief_checks.Plan,
    observations: []const brief_checks.Observation,
) std.mem.Allocator.Error!void {
    for (observations) |observation| {
        try c.add(.{
            .id = observation.id,
            .subject = if (observation.ref_des.len > 0) observation.ref_des else "board",
            .result = observation.message,
            .verdict = switch (observation.result) {
                .fail => .fail,
                .not_declared => .not_declared,
            },
            .evidence = "brief_checks.observe, via preflight kind brief",
        });
    }
    try briefCleanRows(c, plan, observations);
}

const brief_ids: []const []const u8 = &.{
    brief_checks.id_operating_range,
    brief_checks.id_temperature_grade,
    brief_checks.id_input_power,
    brief_checks.id_esd_protection,
};

fn briefCleanRows(
    c: *Composer,
    plan: brief_checks.Plan,
    observations: []const brief_checks.Observation,
) std.mem.Allocator.Error!void {
    const governed = plan.brief != null;
    for (brief_ids) |id| {
        var seen = false;
        for (observations) |observation| {
            if (std.mem.eql(u8, observation.id, id)) seen = true;
        }
        if (seen) continue;
        try c.add(.{
            .id = id,
            .result = if (governed)
                "every placement and net the brief governs meets this"
            else
                "no system brief governs this board, so nothing states the target",
            .verdict = if (governed) .pass else .not_declared,
            .evidence = "brief_checks.observe",
        });
    }
    const derating = if (plan.brief) |brief| brief.derating orelse "" else "";
    try c.add(.{
        .id = "component-derating-standard",
        .result = if (derating.len > 0)
            try c.fmt("the rating screen derates against {s}", .{derating})
        else
            "no (derating \"…\") in a governing brief; ratings are screened undated against the raw rating",
        .verdict = if (derating.len > 0) .pass else .not_declared,
        .evidence = "brief_checks.deratingForBoard; fab_readiness rating screen",
    });
}

/// The worst status any screen of one registry row reported, and the first
/// message that was not a pass.
const ScreenTally = struct {
    seen: usize = 0,
    fails: usize = 0,
    warns: usize = 0,
    message: []const u8 = "",
};

fn noteScreen(tally: *ScreenTally, status_fail: bool, status_warn: bool, message: []const u8) void {
    tally.seen += 1;
    if (status_fail) tally.fails += 1;
    if (status_warn) tally.warns += 1;
    if (tally.message.len == 0 and (status_fail or status_warn)) tally.message = message;
}

fn screenVerdict(tally: ScreenTally) Verdict {
    if (tally.fails > 0) return .fail;
    if (tally.warns > 0) return .unproven;
    return .pass;
}

fn emitScreens(c: *Composer, ids: []const []const u8, tallies: []const ScreenTally, name: []const u8) std.mem.Allocator.Error!void {
    for (ids, tallies) |id, tally| {
        if (tally.seen == 0) continue;
        try c.add(.{
            .id = id,
            .subject = name,
            .result = if (tally.message.len > 0)
                tally.message
            else
                try c.fmt("{d} screen(s) pass", .{tally.seen}),
            .verdict = screenVerdict(tally),
            .evidence = try c.fmt("{s} screens", .{id}),
        });
    }
}

const pll_ids: []const []const u8 = &.{
    "pll-loop-binding",
    "pll-loop-stability",
    "pll-loop-operating-range",
    "pll-loop-ramp-phase-error",
};

fn pllRows(c: *Composer, report: pll_loop.Report) std.mem.Allocator.Error!void {
    var tallies: [4]ScreenTally = @splat(.{});
    for (report.populations) |population| {
        for (population.verdicts) |verdict| {
            const id = registry.pllScreenId(verdict.screen);
            for (pll_ids, 0..) |candidate, index| {
                if (!std.mem.eql(u8, candidate, id)) continue;
                noteScreen(&tallies[index], verdict.status == .fail, verdict.status == .warn, verdict.message);
            }
        }
    }
    try emitScreens(c, pll_ids, &tallies, report.name);
}

const plan_ids: []const []const u8 = &.{
    "frequency-plan-lo-drive",
    "frequency-plan-band-coverage",
    "frequency-plan-spurious",
};

fn planRows(c: *Composer, report: frequency_plan.Report) std.mem.Allocator.Error!void {
    var tallies: [3]ScreenTally = @splat(.{});
    for (report.plans) |plan| {
        for (plan.verdicts) |verdict| {
            const id = registry.frequencyPlanScreenId(verdict.screen);
            for (plan_ids, 0..) |candidate, index| {
                if (!std.mem.eql(u8, candidate, id)) continue;
                noteScreen(&tallies[index], verdict.status == .fail, verdict.status == .warn, verdict.message);
            }
        }
    }
    try emitScreens(c, plan_ids, &tallies, report.name);
}

fn assertionRow(c: *Composer, eval: *const Evaluator) std.mem.Allocator.Error!void {
    var failed: usize = 0;
    var warned: usize = 0;
    for (eval.assertions.items) |assertion| {
        if (assertion.passed) continue;
        if (assertion.is_warning) warned += 1 else failed += 1;
    }
    const total = eval.assertions.items.len;
    try c.add(.{
        .id = "design-assertion",
        .result = if (total == 0)
            "the board states no (assert …)"
        else
            try c.fmt("{d} assertion(s): {d} failed, {d} warned", .{ total, failed, warned }),
        .verdict = if (total == 0) .not_applicable else if (failed > 0) .fail else if (warned > 0) .unproven else .pass,
        .evidence = "eval assertions",
    });
}

fn analysisRows(c: *Composer, eval: *const Evaluator, block: *const env.DesignBlock) std.mem.Allocator.Error!void {
    if (eval.pll_reports.items.len == 0) {
        try c.add(.{
            .id = "pll-loop-binding",
            .result = "the board declares no (pll-loop …)",
            .verdict = .not_applicable,
            .evidence = "eval pll_reports",
        });
    }
    for (eval.pll_reports.items) |report| try pllRows(c, report);
    if (eval.frequency_plan_reports.items.len == 0) {
        try c.add(.{
            .id = "frequency-plan-band-coverage",
            .result = "the board declares no (frequency-plan …)",
            .verdict = .not_applicable,
            .evidence = "eval frequency_plan_reports",
        });
    }
    for (eval.frequency_plan_reports.items) |report| try planRows(c, report);
    if (block.pdn_intents.len == 0) {
        try c.add(.{
            .id = "pdn-impedance-target",
            .result = "the board declares no (pdn …) target",
            .verdict = .not_applicable,
            .evidence = "eval pdn_intents",
        });
    }
    for (block.pdn_intents) |intent| {
        try c.add(.{
            .id = "pdn-impedance-target",
            .subject = intent.net,
            .result = try c.fmt("target ripple {d:.3} V; impedance solved on the layout's PDN view", .{intent.ripple_v}),
            .verdict = .unproven,
            .evidence = "eval pdn_intents",
        });
    }
    try assertionRow(c, eval);
}

// ── Part table and the board answer ───────────────────────────────────────

fn partTable(arena: std.mem.Allocator, board: part_review.Board) std.mem.Allocator.Error![]const PartRow {
    var rows: std.ArrayList(PartRow) = .empty;
    for (board.parts) |part| {
        if (!part.active) continue;
        var ok: usize = 0;
        var unmet: usize = 0;
        for (part.requirements) |req| {
            if (req.verdict == .pass or req.verdict == .waived) ok += 1 else unmet += 1;
        }
        var codes: std.ArrayList([]const u8) = .empty;
        var currents_open = false;
        for (part.profile_items) |item| {
            if (std.mem.eql(u8, item.code, "supply-current")) currents_open = true;
            try codes.append(arena, item.code);
        }
        try rows.append(arena, .{
            .ref = part.ref,
            .component = part.component,
            .class = if (part.class_declared)
                part.class
            else
                try std.fmt.allocPrint(arena, "{s} (inferred)", .{part.class}),
            .review = part.datasheet.status,
            .checks = try std.fmt.allocPrint(arena, "{d} ok / {d} unmet", .{ ok, unmet }),
            .data = try std.fmt.allocPrint(arena, "{d} electrical decl(s); supply-current item {s}", .{
                part.electrical.len,
                if (currents_open) "open" else "closed",
            }),
            .unmet = if (codes.items.len == 0)
                "none"
            else
                try std.mem.join(arena, ", ", codes.items),
            .chip = part.chip(),
            .verdict = verdictOf(part.counts.worst()),
        });
    }
    return rows.toOwnedSlice(arena);
}

fn overallOf(categories: []const Category) Overall {
    var overall: Overall = .{};
    for (categories) |category| {
        for (category.rows) |row| {
            overall.stripe.add(row.verdict);
            if (row.verdict != .fail and row.verdict != .not_declared) continue;
            if (std.mem.eql(u8, row.policy, "blocking")) {
                overall.blocking += 1;
            } else if (std.mem.eql(u8, row.policy, "waivable")) {
                overall.waivable += 1;
            } else overall.advisory += 1;
        }
    }
    overall.verdict = if (overall.blocking > 0) .fail else overall.stripe.worst();
    overall.releasable = overall.blocking == 0;
    return overall;
}

/// Everything one board-wide run computed, ready to be composed. Held as one
/// struct so `compose` stays inside the runtime parameter budget.
const Engines = struct {
    facts: review_audit.Facts,
    board: part_review.Board,
    rails: []const power_budget.Rail,
    heat: thermal.BoardThermal,
    eval: *const Evaluator,
    block: *const env.DesignBlock,
    /// The screening plan the governing system brief implies, and what the
    /// brief-driven checks observed under it.
    plan: brief_checks.Plan,
    observations: []const brief_checks.Observation,
};

fn compose(arena: std.mem.Allocator, name: []const u8, engines: Engines) std.mem.Allocator.Error!Card {
    var composer = Composer{ .arena = arena };
    const facts = engines.facts;
    try identityRows(&composer, facts);
    try ercRows(&composer, facts.violations);
    try fabRows(&composer, facts.fab);
    try layoutRows(&composer, facts.layout);
    try railRows(&composer, engines.rails);
    try partRows(&composer, engines.board);
    try thermalRows(&composer, engines.heat, engines.block, engines.plan);
    try briefRows(&composer, engines.plan, engines.observations);
    try analysisRows(&composer, engines.eval, engines.block);
    const categories = try composer.finish();
    return .{
        .design = name,
        .identity = facts.identity,
        .digests = facts.digests,
        .schematic = facts.schematic,
        .categories = categories,
        .parts = try partTable(arena, engines.board),
        .fab = facts.fab,
        .layout = facts.layout,
        .findings = facts.findings,
        .overall = overallOf(categories),
        .ambient_c = engines.board.ambient_c,
    };
}

// ── Collection ────────────────────────────────────────────────────────────

/// Compose the Board Review Card for `name`. `arena` must outlive the card:
/// every string in it is arena-owned or borrowed from the evaluated design,
/// which the arena also owns.
pub fn collect(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    options: Options,
) CollectError!Card {
    var eval = Evaluator.init(arena, project_dir);
    defer eval.deinit();
    return collectWith(arena, &eval, project_dir, name, options);
}

/// The same card, over an evaluator the CALLER owns and keeps alive, so the
/// server can retain the answer against the file read-set the evaluation
/// touched. `eval` must be freshly initialised over `project_dir`.
pub fn collectWith(
    arena: std.mem.Allocator,
    eval: *Evaluator,
    project_dir: []const u8,
    name: []const u8,
    options: Options,
) CollectError!Card {
    const board_path = try paths.designSourcePath(arena, project_dir, name);
    const result = eval.evalFile(board_path) catch return error.EvaluateFailed;
    const block = switch (result) {
        .design_block => |value| value,
        else => return error.NotADesign,
    };
    // The thermal screen runs at the ambient the governing system brief
    // states, exactly as every other thermal surface does; an explicit
    // `ambient_c` is a reader's what-if and wins over it.
    const plan = brief_checks.planFor(arena, project_dir, name);
    const ambient = options.ambient_c orelse plan.ambient_c;
    // The audit's facts and the per-part sheet each ran their OWN release
    // preflight over this one block — two identical passes, about half the
    // card's cold cost on a board the size of Barracuda. One cache, handed to
    // both, makes it one pass; the facts collector still runs first, so the
    // shared report is taken at exactly the point the first surface took it.
    var preflight_cache = preflight.Cache{
        .project_dir = project_dir,
        .profile = .release,
        .design_name = name,
    };
    const facts = try review_audit.collectFactsFor(arena, eval, block, project_dir, name, .{
        .layout = options.layout,
        .preflight_cache = &preflight_cache,
    });
    const board = try part_review.collectFor(arena, eval, block, project_dir, name, .{
        .ambient_c = ambient,
        .preflight_cache = &preflight_cache,
    });
    var heat = try thermal.analyze(arena, block, ambient);
    heat.ambient_source = plan.source;
    heat.ambient_source.overridden = options.ambient_c != null;
    return compose(arena, name, .{
        .facts = facts,
        .board = board,
        .rails = try power_budget.analyze(arena, block),
        .heat = heat,
        .eval = eval,
        .block = block,
        .plan = plan,
        .observations = try brief_checks.observe(arena, block, project_dir, plan),
    });
}

// ── Serialization ─────────────────────────────────────────────────────────

fn writeStripe(w: anytype, stripe: Stripe) json_writer.WriteError!void {
    try w.print("{{\"pass\":{d},\"fail\":{d},\"unproven\":{d},\"waived\":{d}," ++
        "\"not_applicable\":{d},\"not_declared\":{d},\"manual\":{d},\"total\":{d}}}", .{
        stripe.pass,
        stripe.fail,
        stripe.unproven,
        stripe.waived,
        stripe.not_applicable,
        stripe.not_declared,
        stripe.manual,
        stripe.total(),
    });
}

fn writeRow(w: anytype, row: Row) json_writer.WriteError!void {
    try w.writeAll("{\"id\":");
    try json_writer.writeString(w, row.id);
    try w.writeAll(",\"scope\":");
    try json_writer.writeString(w, row.scope);
    try w.writeAll(",\"subject\":");
    try json_writer.writeString(w, row.subject);
    try w.writeAll(",\"result\":");
    try json_writer.writeString(w, row.result);
    try w.print(",\"verdict\":\"{s}\",\"evidence\":", .{@tagName(row.verdict)});
    try json_writer.writeString(w, row.evidence);
    try w.writeAll(",\"closes_with\":");
    try json_writer.writeString(w, row.closes_with);
    try w.writeAll(",\"policy\":");
    try json_writer.writeString(w, row.policy);
    try w.writeAll(",\"record\":");
    try json_writer.writeString(w, row.record);
    try w.writeAll("}");
}

fn writeCategories(w: anytype, categories: []const Category) json_writer.WriteError!void {
    try w.writeAll("\"categories\":[");
    for (categories, 0..) |category, index| {
        if (index > 0) try w.writeAll(",");
        try w.writeAll("{\"key\":");
        try json_writer.writeString(w, category.key);
        try w.writeAll(",\"title\":");
        try json_writer.writeString(w, category.title);
        try w.writeAll(",\"stripe\":");
        try writeStripe(w, category.stripe);
        try w.writeAll(",\"rows\":[");
        for (category.rows, 0..) |row, row_index| {
            if (row_index > 0) try w.writeAll(",");
            try writeRow(w, row);
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]");
}

fn writeParts(w: anytype, parts: []const PartRow) json_writer.WriteError!void {
    try w.writeAll("\"parts\":[");
    for (parts, 0..) |part, index| {
        if (index > 0) try w.writeAll(",");
        try w.writeAll("{\"ref\":");
        try json_writer.writeString(w, part.ref);
        try w.writeAll(",\"component\":");
        try json_writer.writeString(w, part.component);
        try w.writeAll(",\"class\":");
        try json_writer.writeString(w, part.class);
        try w.writeAll(",\"review\":");
        try json_writer.writeString(w, part.review);
        try w.writeAll(",\"checks\":");
        try json_writer.writeString(w, part.checks);
        try w.writeAll(",\"electrical\":");
        try json_writer.writeString(w, part.data);
        try w.writeAll(",\"unmet\":");
        try json_writer.writeString(w, part.unmet);
        try w.print(",\"chip\":{{\"pass\":{d},\"unproven\":{d},\"fail\":{d},\"not_declared\":{d}}}," ++
            "\"verdict\":\"{s}\"}}", .{
            part.chip.pass,
            part.chip.unproven,
            part.chip.fail,
            part.chip.not_declared,
            @tagName(part.verdict),
        });
    }
    try w.writeAll("]");
}

fn writeIdentity(w: anytype, card: Card) json_writer.WriteError!void {
    const identity = card.identity;
    try w.writeAll("\"identity\":{\"name\":");
    try json_writer.writeString(w, identity.name);
    try w.writeAll(",\"revision\":");
    try json_writer.writeString(w, identity.revision);
    try w.writeAll(",\"part_number\":");
    try json_writer.writeString(w, identity.part_number);
    try w.writeAll(",\"layout\":");
    try json_writer.writeString(w, identity.layout);
    try w.writeAll(",\"project_status\":");
    try json_writer.writeString(w, identity.project_status);
    try w.writeAll(",\"tool_commit\":");
    try json_writer.writeString(w, identity.tool_commit);
    try w.writeAll(",\"generated_at\":");
    try json_writer.writeString(w, identity.generated_at);
    try w.writeAll("},\"digests\":{\"layout_sha256\":");
    try json_writer.writeString(w, card.digests.layout_sha256);
    try w.writeAll(",\"source_sha256\":");
    try json_writer.writeString(w, card.digests.source_sha256);
    try w.writeAll(",\"release_token\":");
    try json_writer.writeString(w, card.digests.release_token);
    try w.writeAll(",\"fab_id\":");
    try json_writer.writeString(w, card.digests.fab_id);
    try w.writeAll(",\"project_commit\":");
    try json_writer.writeString(w, card.digests.project_commit);
    try w.writeAll("}");
}

fn writeFab(w: anytype, card: Card) json_writer.WriteError!void {
    const fab = card.fab;
    try w.print("\"fab\":{{\"available\":{s},\"ok\":{s},\"needs_waiver\":{s},\"errors\":[", .{
        if (fab.available) "true" else "false",
        if (fab.ok) "true" else "false",
        if (fab.needs_waiver) "true" else "false",
    });
    for (fab.error_ids, 0..) |id, index| {
        if (index > 0) try w.writeAll(",");
        try json_writer.writeString(w, id);
    }
    try w.writeAll("],\"warnings\":[");
    for (fab.warning_ids, 0..) |id, index| {
        if (index > 0) try w.writeAll(",");
        try json_writer.writeString(w, id);
    }
    try w.print("],\"stats\":{{\"parts\":{d},\"nets\":{d},\"routable\":{d},\"connected\":{d}," ++
        "\"tracks\":{d},\"vias\":{d},\"dnp\":{d}}}}}", .{
        fab.stats.parts,
        fab.stats.nets,
        fab.stats.routable,
        fab.stats.connected,
        fab.stats.tracks,
        fab.stats.vias,
        fab.stats.dnp,
    });
}

fn writeLayout(w: anytype, layout: review_audit.Layout) json_writer.WriteError!void {
    try w.print("\"layout\":{{\"available\":{s},\"drc_errors\":{d},\"drc_warnings\":{d},\"ladder\":[", .{
        if (layout.available) "true" else "false",
        layout.drc_errors,
        layout.drc_warnings,
    });
    for (layout.ladder, 0..) |stage, index| {
        if (index > 0) try w.writeAll(",");
        try w.writeAll("{\"id\":");
        try json_writer.writeString(w, stage.id);
        try w.writeAll(",\"status\":");
        try json_writer.writeString(w, stage.status);
        try w.print(",\"done\":{d},\"total\":{d}}}", .{ stage.done, stage.total });
    }
    try w.writeAll("],\"by_kind\":[");
    for (layout.by_kind, 0..) |entry, index| {
        if (index > 0) try w.writeAll(",");
        try w.writeAll("{\"kind\":");
        try json_writer.writeString(w, entry.kind);
        try w.print(",\"count\":{d}}}", .{entry.count});
    }
    try w.writeAll("]}");
}

/// Serialize the whole card — the body `GET /api/review-card/:name` returns,
/// the `review_card` CLI tool's answer, and what `netlisp review-card` prints.
pub fn writeCardJson(w: anytype, card: Card) json_writer.WriteError!void {
    try w.writeAll("{\"design\":");
    try json_writer.writeString(w, card.design);
    try w.writeAll(",");
    try writeIdentity(w, card);
    try w.print(",\"ambient_c\":{d},\"overall\":{{\"verdict\":\"{s}\",\"blocking\":{d}," ++
        "\"waivable\":{d},\"advisory\":{d},\"releasable\":{s},\"stripe\":", .{
        card.ambient_c,
        @tagName(card.overall.verdict),
        card.overall.blocking,
        card.overall.waivable,
        card.overall.advisory,
        if (card.overall.releasable) "true" else "false",
    });
    try writeStripe(w, card.overall.stripe);
    try w.print("}},\"schematic\":{{\"preflight_errors\":{d},\"preflight_warnings\":{d}," ++
        "\"preflight_infos\":{d},\"erc_errors\":{d},\"erc_warnings\":{d},\"notes_open\":{d}}},", .{
        card.schematic.preflight_errors,
        card.schematic.preflight_warnings,
        card.schematic.preflight_infos,
        card.schematic.erc_errors,
        card.schematic.erc_warnings,
        card.schematic.notes_open,
    });
    try writeCategories(w, card.categories);
    try w.writeAll(",");
    try writeParts(w, card.parts);
    try w.writeAll(",");
    try writeFab(w, card);
    try w.writeAll(",");
    try writeLayout(w, card.layout);
    try w.writeAll("}");
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Write a board that declares two rails and annotates no `(i-max …)` on any
/// consumer, so the power-budget category has a real never-declared input to
/// report, plus one active IC and one passive so every part-shaped row has a
/// subject.
//
// twin-drift-ok: `serve/review_card_api.zig` writes its own fixture stating a
// DIFFERENT board — one cited requirement and one supply window, to exercise
// the endpoint's body — while this one deliberately withholds the current
// annotations. The overlap is the writeFile calls, not the boards.
fn writeCardFixture(dir: std.Io.Dir) !void {
    try dir.createDirPath(std.testing.io, "lib/components");
    try dir.createDirPath(std.testing.io, "lib/pinouts");
    try dir.createDirPath(std.testing.io, "src");
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/card-reg.sexp", .data =
        \\(component "card-reg"
        \\  (description "regulator with no annotated load")
        \\  (footprint "SOT-23-5")
        \\  (class ldo))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/pinouts/card-reg.sexp", .data =
        \\(pinout "card-reg"
        \\  (pin 1 "VIN")
        \\  (pin 2 "GND")
        \\  (pin 3 "VOUT"))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/card-bypass.sexp", .data =
        \\(component "card-bypass"
        \\  (description "bypass capacitor")
        \\  (footprint "C0402"))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "src/board.sexp", .data =
        \\(import card-reg)
        \\(import card-bypass)
        \\
        \\(design-block "Card Fixture"
        \\  (revision "C2")
        \\  (rail "V_12V" (nominal 12.0))
        \\  (rail "V_3V3" (nominal 3.3))
        \\  (port "V_12V" in (nominal 12.0) (current 1.0 2.0))
        \\  (instance "U1" card-reg
        \\    (pin 1 "VIN" "V_12V")
        \\    (pin 2 "GND" "GND")
        \\    (pin 3 "VOUT" "V_3V3"))
        \\  (instance "C1" card-bypass
        \\    (pin 1 "V_3V3")
        \\    (pin 2 "GND")))
    });
}

/// True when the category carries a row citing `id` with this verdict.
fn hasRow(category: Category, id: []const u8, verdict: Verdict) bool {
    for (category.rows) |row| {
        if (std.mem.eql(u8, row.id, id) and row.verdict == verdict) return true;
    }
    return false;
}

fn collectFixture(alloc: std.mem.Allocator, project: []const u8) CollectError!Card {
    return collect(alloc, project, "board", .{});
}

/// The fixture board, evaluated into a caller-owned evaluator.
fn evalFixtureBlock(
    alloc: std.mem.Allocator,
    eval: *Evaluator,
    project: []const u8,
) CollectError!*const env.DesignBlock {
    const board_path = try paths.designSourcePath(alloc, project, "board");
    const result = eval.evalFile(board_path) catch return error.EvaluateFailed;
    return switch (result) {
        .design_block => |value| value,
        else => error.NotADesign,
    };
}

// spec: review-card - the card carries all twelve review categories in registry order and every row cites a registered check
test "the card composes twelve categories whose rows all resolve in the registry" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeCardFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const card = try collectFixture(alloc, project);
    try testing.expectEqual(category_count, card.categories.len);
    try testing.expectEqual(@as(usize, 12), card.categories.len);
    for (card.categories, std.enums.values(registry.Category)) |category, key| {
        try testing.expectEqualStrings(@tagName(key), category.key);
        try testing.expectEqualStrings(key.title(), category.title);
        // No category is silent: a board that declared nothing for one still
        // gets rows saying so.
        try testing.expect(category.rows.len > 0);
        try testing.expectEqual(category.rows.len, category.stripe.total());
        for (category.rows) |row| {
            const registered = registry.lookup(row.id) orelse return error.UnregisteredCheckId;
            try testing.expectEqualStrings(@tagName(registered.category), category.key);
            try testing.expectEqualStrings(@tagName(registered.scope), row.scope);
            try testing.expectEqualStrings(@tagName(registered.policy), row.policy);
            try testing.expectEqualStrings(registered.closes_with, row.closes_with);
            try testing.expect(row.result.len > 0);
            try testing.expect(row.subject.len > 0);
        }
    }
}

// spec: review-card - a rail whose consumers carry no (i-max …) reports a not-declared power-budget row naming the missing form
test "an unannotated rail reports a not-declared power-budget row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeCardFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const card = try collectFixture(alloc, project);
    const power = card.find(.power_budget) orelse return error.MissingCategory;
    try testing.expect(hasRow(power, "rail-consumers-annotated", .not_declared));
    try testing.expect(power.stripe.not_declared > 0);
    const row = card.row("rail-consumers-annotated") orelse return error.MissingRow;
    try testing.expect(std.mem.indexOf(u8, row.result, "(i-max …)") != null);
    // The registry, not the composer, decides how hard the row blocks.
    try testing.expectEqualStrings("blocking", row.policy);
    try testing.expect(card.overall.blocking > 0);
    try testing.expect(!card.overall.releasable);

    // The thermal and domain categories state the same absence rather than
    // reporting nothing: no cooling assembly, no declared analysis form.
    const heat = card.find(.thermal) orelse return error.MissingCategory;
    try testing.expect(hasRow(heat, "thermal-board-cooling-scenario", .not_declared));
    const domain = card.find(.domain_analyses) orelse return error.MissingCategory;
    try testing.expect(hasRow(domain, "pll-loop-binding", .not_applicable));
}

// spec: review-card - the composer names the reason it could not review instead of answering an empty card
test "the composer names why it could not compose a card" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeCardFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    try testing.expectError(error.EvaluateFailed, collect(alloc, project, "nope", .{}));
    try testing.expectError(error.InvalidName, collect(alloc, project, "../etc/passwd", .{}));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/bare.sexp", .data = "42" });
    try testing.expectError(error.NotADesign, collect(alloc, project, "bare", .{}));
}

// spec: review-card - the stripe tallies every verdict and reports the worst one
test "the stripe tallies verdicts and reports the worst" {
    var stripe: Stripe = .{};
    try testing.expectEqual(Verdict.not_applicable, stripe.worst());
    stripe.add(.pass);
    stripe.add(.waived);
    try testing.expectEqual(Verdict.waived, stripe.worst());
    stripe.add(.manual);
    try testing.expectEqual(Verdict.manual, stripe.worst());
    stripe.add(.unproven);
    try testing.expectEqual(Verdict.unproven, stripe.worst());
    stripe.add(.not_declared);
    try testing.expectEqual(Verdict.not_declared, stripe.worst());
    stripe.add(.fail);
    try testing.expectEqual(Verdict.fail, stripe.worst());
    try testing.expectEqual(@as(usize, 6), stripe.total());
    try testing.expectEqual(Verdict.pass, verdictOf(part_review.Verdict.pass));
    try testing.expectEqual(Verdict.not_declared, verdictOf(part_review.Verdict.not_declared));
}

/// Add a system whose `(brief …)` governs the fixture board: an ambient
/// window, a cooling case, a temperature grade and a derating standard.
fn writeGoverningSystem(dir: std.Io.Dir) !void {
    try dir.createDirPath(std.testing.io, "src/systems/rigsys");
    try dir.writeFile(std.testing.io, .{ .sub_path = "src/systems/rigsys/system.sexp", .data =
        \\(system "rigsys"
        \\  (title "Card Fixture System") (part-number "CF-1") (revision "A")
        \\  (brief
        \\    (purpose "the card fixture product")
        \\    (environment (ambient -10 60) (cooling natural))
        \\    (temperature-grade industrial)
        \\    (derating "NASA EEE-INST-002"))
        \\  (board "board" (role main) (source "src/board.sexp") (part-number "P-1") (revision "C2"))
        \\  (document "release-checklist" (title "Release checklist")
        \\    (path "src/systems/rigsys/release-checklist.md") (classification checklist)))
    });
}

// spec: review-card - a governing system brief sets the ambient the card screens at and turns its brief-driven checks into rows
test "a governing brief parametrizes the card's thermal and brief rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try writeCardFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    // Without a brief the five brief-driven rows say nobody stated a target.
    const ungoverned = try collectFixture(alloc, project);
    const cold = ungoverned.find(.thermal) orelse return error.MissingCategory;
    try testing.expect(hasRow(cold, "thermal-brief-ambient", .not_declared));
    try testing.expect(hasRow(cold, "part-operating-range", .not_declared));
    const cold_ratings = ungoverned.find(.component_ratings) orelse return error.MissingCategory;
    try testing.expect(hasRow(cold_ratings, "component-derating-standard", .not_declared));
    try testing.expectEqual(thermal.default_ambient_c, ungoverned.ambient_c);

    // With one, the screen runs at the brief's ambient MAX and the rows say so.
    try writeGoverningSystem(tmp.dir);
    const card = try collectFixture(alloc, project);
    try testing.expectEqual(@as(f64, 60), card.ambient_c);
    const heat = card.find(.thermal) orelse return error.MissingCategory;
    const ambient_row = card.row("thermal-brief-ambient") orelse return error.MissingRow;
    try testing.expectEqual(Verdict.pass, ambient_row.verdict);
    try testing.expect(std.mem.indexOf(u8, ambient_row.result, "rigsys") != null);
    const cooling_row = card.row("thermal-board-cooling-scenario") orelse return error.MissingRow;
    try testing.expectEqual(Verdict.pass, cooling_row.verdict);
    // The fixture's parts declare no (thermal (operating …)) and no grade, so
    // the governed board reports those as never declared rather than passing.
    try testing.expect(hasRow(heat, "part-operating-range", .not_declared));
    const ratings = card.find(.component_ratings) orelse return error.MissingCategory;
    try testing.expect(hasRow(ratings, "part-temperature-grade", .not_declared));
    const derating_row = card.row("component-derating-standard") orelse return error.MissingRow;
    try testing.expectEqual(Verdict.pass, derating_row.verdict);
    try testing.expect(std.mem.indexOf(u8, derating_row.result, "NASA") != null);
}

// spec: review-card - the composer runs one release preflight for the facts and the per-part sheet instead of repeating it
test "the composer shares one release preflight between the facts and the parts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeCardFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    // The cache is the seam the card composes through: filled once, it is what
    // both surfaces read, and a second `get` never runs the pass again.
    var eval = Evaluator.init(alloc, project);
    defer eval.deinit();
    const block = try evalFixtureBlock(alloc, &eval, project);
    var cache = preflight.Cache{ .project_dir = project, .profile = .release, .design_name = "board" };
    const first = try cache.get(alloc, &eval, block);
    const second = try cache.get(alloc, &eval, block);
    try testing.expectEqual(first.findings.ptr, second.findings.ptr);
    try testing.expectEqual(first.findings.len, second.findings.len);

    // And the shared run is the same review: the card composed over one
    // preflight still carries every category and a decided overall verdict.
    const card = try collectFixture(alloc, project);
    try testing.expectEqual(category_count, card.categories.len);
    try testing.expect(card.overall.stripe.total() > 0);
}
