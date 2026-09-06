//! Unified schematic preflight: turns executable component requirements,
//! design-side verifications, and digest-bound datasheet reviews into one
//! structured finding model. CLI `check`, CLI `run_checks`, and CLI `build`
//! all consume this module so they cannot disagree about requirement status.

const std = @import("std");
const brief_checks = @import("brief_checks.zig");
const checks = @import("checks.zig");
const component_classification = @import("component_classification.zig");
const env_mod = @import("eval/env.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;
const infra_fs = @import("infra/fs.zig");
const net_name = @import("net_name.zig");
const req_checks = @import("req_checks.zig");
const req_design_rules = @import("req_design_rules.zig");
const review_profiles = @import("review_profiles.zig");

const DesignBlock = env_mod.DesignBlock;
const Instance = env_mod.Instance;

/// Authoring remains backward compatible: pending manual requirements and
/// incomplete legacy review records are warnings. Preflight upgrades those
/// findings to errors; automated check failures are errors in every profile.
/// Release is preflight plus the component-class profile obligations, a
/// demand for at least one cited requirement on every active part, and the
/// evaluator's own warnings (an unknown sub-form is an error there).
pub const Profile = enum { authoring, preflight, release };

/// True for every profile that gates (preflight and release) — the predicate
/// callers use instead of comparing against `.preflight`, so a stricter
/// profile can never fall back to authoring leniency by accident.
pub fn isStrict(profile: Profile) bool {
    return profile != .authoring;
}

/// Severity of an unmet component-class profile obligation: informational
/// while authoring, a warning in preflight, an error at release.
pub fn profileSeverity(profile: Profile) checks.Severity {
    return switch (profile) {
        .authoring => .info,
        .preflight => .warning,
        .release => .@"error",
    };
}

/// Severity of an evaluator warning surfaced by the release profile: an
/// unknown sub-form is a stale declaration and blocks; anything else is kept
/// visible as a warning.
pub fn evalWarningSeverity(message: []const u8) checks.Severity {
    return if (std.mem.startsWith(u8, message, "unknown sub-form")) .@"error" else .warning;
}

/// Parse an optional CLI/CLI profile word, defaulting to backward-compatible
/// authoring behavior. Unknown words are rejected.
pub fn parseProfile(word: ?[]const u8) ?Profile {
    const value = word orelse return .authoring;
    return std.meta.stringToEnum(Profile, value);
}

/// Validation subsystem that emitted a structured preflight finding.
///
/// `brief` is the brief-driven family: the checks a board owes only because
/// the SYSTEM it belongs to declared a `(brief …)`. A `brief` finding carries
/// its `review_registry` row id in `requirement.id` and the row's assertion in
/// `requirement.text`, which is how a review surface tells a missed ambient
/// window from a missed temperature grade without a second vocabulary.
pub const FindingKind = enum { requirement, datasheet_review, profile_incomplete, eval_warning, brief };
/// Normalized outcome shared by machine checks and datasheet-review checks.
/// `unproven` and `deferred` mirror the two `req_checks.Status` outcomes that
/// are neither a verdict nor the reviewer-judgement hole `pending` names: a
/// check that ran and could not decide, and a geometry rule whose verdict
/// lives in a layout lint.
pub const FindingStatus = enum { pass, fail, pending, verified, missing, incomplete, stale, unproven, deferred };

/// Required topics for a complete active-component datasheet review. The DSL
/// accepts additional categories, but strict preflight requires each key here
/// to be either reviewed or explicitly N/A with a non-empty rationale.
pub const required_review_categories = [_][]const u8{
    "supply",
    "decoupling",
    "pin-straps",
    "sequencing",
    "thermal",
    "layout",
};

const RequirementDetails = struct {
    id: []const u8 = "",
    text: []const u8 = "",
    citation: ?env_mod.NoteRef = null,
    datasheet: []const u8 = "",
    /// Which authority wrote the rule: a component library, or the design
    /// itself. Gating is identical — this is what lets a reviewer tell an
    /// inherited datasheet obligation from a rule this board set for itself.
    source: env_mod.RuleSource = .library,
    /// What a design rule judged: the flattened net a `(net-rule …)` glob
    /// matched, the glob itself when it matched nothing, or the `(on "REF")`
    /// target. Empty for a library requirement, whose target IS `ref_des`.
    target: []const u8 = "",
    /// Sub-block path of the block that owns a design rule (`""` at the root),
    /// and the section path it was authored under. Both display-only.
    block_path: []const u8 = "",
    scope: []const u8 = "",
};

/// One normalized requirement or datasheet-review outcome returned by every
/// CLI/CLI validation surface.
pub const Finding = struct {
    kind: FindingKind,
    status: FindingStatus,
    severity: checks.Severity,
    ref_des: []const u8,
    component: []const u8,
    message: []const u8,
    requirement: RequirementDetails = .{},
};

/// Map an executable/manual requirement outcome to its profile-sensitive
/// validation severity. Machine failures remain errors in authoring mode.
pub fn requirementSeverity(status: req_checks.Status, profile: Profile) checks.Severity {
    if (status == .fail) return .@"error";
    if (status == .na) return if (isStrict(profile)) .@"error" else .warning;
    // A check that RAN and could not decide is a warning in every profile,
    // including release. Escalating it the way `na` escalates would punish the
    // parts that carry an executable rule harder than the ones that carry only
    // prose — the opposite of the incentive the check engine exists to create.
    // Closing it is authoring work (a rating attribute, a `(net-envelope …)`,
    // an `(enable …)`) or an explicit `(verifies …)` sign-off.
    if (status == .unproven) return .warning;
    // A layout-deferred rule is informational HERE by construction: the
    // netlist surface cannot answer it, and the layout lint that can is a
    // separate gate. Making it a warning would be noise no schematic edit
    // could ever clear.
    if (status == .layout_deferred) return .info;
    return .info;
}

/// Owned unified validation output. Call `deinit` after serialization.
pub const Report = struct {
    profile: Profile,
    findings: []const Finding,
    errors: usize,
    warnings: usize,
    /// The design-owned rule outcomes the design-rule findings were built
    /// from. The report OWNS them because the findings borrow strings out of
    /// them (`requirement.target`, `requirement.block_path`), so freeing them
    /// at the end of `run` would hand every caller a dangling target name.
    design_rules: []const req_design_rules.Outcome = &.{},

    pub fn deinit(self: Report, allocator: std.mem.Allocator) void {
        deinitFindings(allocator, self.findings);
        req_design_rules.deinit(allocator, self.design_rules);
    }
};

/// Free a findings slice and every owned message it contains.
pub fn deinitFindings(allocator: std.mem.Allocator, findings: []const Finding) void {
    for (findings) |finding| allocator.free(finding.message);
    allocator.free(findings);
}

/// Run and verify every component requirement, then append one datasheet
/// review-completeness finding for every active component instance.
pub fn run(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    project_dir: []const u8,
    profile: Profile,
) std.mem.Allocator.Error!Report {
    return runFor(allocator, eval, block, project_dir, profile, "");
}

/// `run`, told which design this block IS.
///
/// The lookup name is what `system_brief.governingBrief` needs to find the
/// system whose `(brief …)` governs the board — `block.name` cannot serve,
/// being a formatted title. A caller that passes `""` gets exactly the old
/// behaviour: no brief is resolved and no brief finding can be produced, so
/// this is additive for every surface that has not adopted it yet.
pub fn runFor(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    project_dir: []const u8,
    profile: Profile,
    design_name: []const u8,
) std.mem.Allocator.Error!Report {
    var results = try req_checks.runChecks(allocator, eval, block);
    defer req_checks.deinit(allocator, &results);
    req_checks.applyVerifications(&results, block, block.instances);

    const rules = try req_design_rules.run(allocator, eval, block);
    errdefer req_design_rules.deinit(allocator, rules);
    req_design_rules.applyVerifications(rules, block);

    var findings: std.ArrayList(Finding) = .empty;
    errdefer {
        for (findings.items) |finding| allocator.free(finding.message);
        findings.deinit(allocator);
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const forms = formsOf(eval);
    const walk = Walk{
        .allocator = allocator,
        .arena = arena.allocator(),
        .project_dir = project_dir,
        .profile = profile,
        .forms = forms,
        .results = &results,
        .findings = &findings,
        .design_ruled_refs = try designRuledRefs(arena.allocator(), rules),
    };
    try walkBlock(walk, block);
    try appendDesignRuleFindings(allocator, rules, profile, &findings);
    try appendBriefFindings(allocator, block, .{
        .project_dir = project_dir,
        .design_name = design_name,
        .profile = profile,
    }, &findings);
    if (profile == .release) try appendEvalWarnings(allocator, eval, &findings);

    var errors: usize = 0;
    var warnings: usize = 0;
    for (findings.items) |finding| {
        if (finding.severity == .@"error") errors += 1;
        if (finding.severity == .warning) warnings += 1;
    }
    return .{
        .profile = profile,
        .findings = try findings.toOwnedSlice(allocator),
        .errors = errors,
        .warnings = warnings,
        .design_rules = rules,
    };
}

/// Everything one run threads through the design walk: the owning allocator
/// for finding messages, the scratch arena, the strictness profile, the
/// design-level forms, the requirement outcomes and the findings sink.
const Walk = struct {
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    project_dir: []const u8,
    profile: Profile,
    forms: review_profiles.Forms,
    results: *const std.StringHashMapUnmanaged([]req_checks.Result),
    findings: *std.ArrayList(Finding),
    /// Ref-deses a design-owned `(on "REF")` rule covers — they satisfy the
    /// release profile's cited-requirement demand exactly as a library rule on
    /// the same part would.
    design_ruled_refs: []const []const u8 = &.{},
};

fn walkBlock(walk: Walk, block: *const DesignBlock) std.mem.Allocator.Error!void {
    for (block.instances) |inst| {
        if (inst.placeholder) continue;
        if (!inst.requirements_ignored) {
            try appendRequirementFindings(walk.allocator, inst, walk.profile, walk.results, walk.findings);
        }
        if (component_classification.isActiveSemiconductor(inst)) {
            const finding = try datasheetReviewFinding(walk.allocator, inst, walk.project_dir, walk.profile);
            try appendOwnedFinding(walk.allocator, walk.findings, finding);
            try appendProfileFindings(walk, inst, block);
        }
    }
    for (block.sub_blocks) |sub| {
        try walkBlock(walk, sub.block);
    }
}

/// Which analysis forms the evaluated design declared, and whether every one
/// of them gates. A single advisory loop or plan reads as "not gated".
fn formsOf(eval: *const Evaluator) review_profiles.Forms {
    var forms: review_profiles.Forms = .{};
    var pll_gate = true;
    for (eval.pll_reports.items) |report| {
        forms.pll_any = true;
        if (report.mode != .gate) pll_gate = false;
    }
    forms.pll_gate = forms.pll_any and pll_gate;
    var plan_gate = true;
    for (eval.frequency_plan_reports.items) |report| {
        forms.plan_any = true;
        if (report.mode != .gate) plan_gate = false;
    }
    forms.plan_gate = forms.plan_any and plan_gate;
    return forms;
}

/// One `profile_incomplete` finding per unmet class obligation of an active
/// part, at the profile's severity.
fn appendProfileFindings(walk: Walk, inst: Instance, block: *const DesignBlock) std.mem.Allocator.Error!void {
    const allocator = walk.allocator;
    const items = try review_profiles.evaluate(allocator, walk.arena, inst, .{
        .block = block,
        .project_dir = walk.project_dir,
        .forms = walk.forms,
        .require_requirements = walk.profile == .release,
        .design_ruled_refs = walk.design_ruled_refs,
    });
    defer allocator.free(items);
    var moved: usize = 0;
    errdefer for (items[moved..]) |item| allocator.free(item.message);
    for (items) |item| {
        try appendOwnedFinding(allocator, walk.findings, .{
            .kind = .profile_incomplete,
            .status = .incomplete,
            .severity = profileSeverity(walk.profile),
            .ref_des = inst.ref_des,
            .component = inst.component,
            .message = item.message,
        });
        moved += 1;
    }
}

/// What the brief walk needs beyond the block and the findings sink.
const BriefScope = struct {
    project_dir: []const u8,
    /// Design lookup name; empty ⇒ no brief is resolved.
    design_name: []const u8,
    profile: Profile,
};

/// One finding per brief-driven check the board does not meet.
///
/// The severity ladder is the class-profile one — informational while
/// authoring, a warning in preflight, an error at release — because these are
/// obligations of the same shape: a target somebody stated that the design has
/// not yet answered. A board whose system declares no brief produces nothing
/// here, so this is inert until a brief is written.
fn appendBriefFindings(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    scope: BriefScope,
    findings: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void {
    if (scope.design_name.len == 0) return;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const plan = brief_checks.planFor(scratch, scope.project_dir, scope.design_name);
    const observations = try brief_checks.observe(scratch, block, scope.project_dir, plan);
    for (observations) |observation| {
        const message = try allocator.dupe(u8, observation.message);
        try appendOwnedFinding(allocator, findings, .{
            .kind = .brief,
            .status = switch (observation.result) {
                .fail => .fail,
                .not_declared => .missing,
            },
            .severity = profileSeverity(scope.profile),
            .ref_des = observation.ref_des,
            .component = observation.component,
            .message = message,
            .requirement = .{ .id = observation.id, .source = .design },
        });
    }
}

/// The release profile surfaces every evaluator warning as a finding so a
/// stale declaration cannot hide on stderr while the gate reads green.
fn appendEvalWarnings(
    allocator: std.mem.Allocator,
    eval: *const Evaluator,
    findings: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void {
    for (eval.warnings.items, 0..) |warning, index| {
        // A module instantiated N times warns N times; one finding per text.
        var repeated = false;
        for (eval.warnings.items[0..index]) |earlier| if (std.mem.eql(u8, earlier.message, warning.message)) {
            repeated = true;
        };
        if (repeated) continue;
        const message = try allocator.dupe(u8, warning.message);
        try appendOwnedFinding(allocator, findings, .{
            .kind = .eval_warning,
            .status = .fail,
            .severity = evalWarningSeverity(warning.message),
            .ref_des = "",
            .component = "",
            .message = message,
        });
    }
}

fn appendRequirementFindings(
    allocator: std.mem.Allocator,
    inst: Instance,
    profile: Profile,
    results: *const std.StringHashMapUnmanaged([]req_checks.Result),
    findings: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void {
    const outcomes = results.get(inst.ref_des) orelse &.{};
    for (inst.requirements, 0..) |requirement, index| {
        const outcome: req_checks.Result = if (index < outcomes.len) outcomes[index] else .{ .status = .na };
        const status = findingStatus(outcome.status);
        const severity = requirementSeverity(outcome.status, profile);
        const borrowed_message = if (outcome.message.len > 0)
            outcome.message
        else if (outcome.status == .verified and outcome.verification != null)
            outcome.verification.?.rationale
        else
            "requirement needs explicit verification";
        const message = try allocator.dupe(u8, borrowed_message);
        try appendOwnedFinding(allocator, findings, .{
            .kind = .requirement,
            .status = status,
            .severity = severity,
            .ref_des = inst.ref_des,
            .component = inst.component,
            .message = message,
            .requirement = .{
                .id = requirement.id,
                .text = requirement.text,
                .citation = requirement.ref,
                .datasheet = if (requirement.ref) |ref| ref.pdf else "",
            },
        });
    }
}

/// Every ref-des a design-owned `(on "REF")` rule judges, in the ref-des space
/// the preflight walk sees (a sub-block target's leaf, since ref-deses are
/// globally unique once the block is materialized).
fn designRuledRefs(
    arena: std.mem.Allocator,
    rules: []const req_design_rules.Outcome,
) std.mem.Allocator.Error![]const []const u8 {
    var refs: std.ArrayList([]const u8) = .empty;
    for (rules) |rule| {
        if (rule.netScoped()) continue;
        for (rule.targets) |target| try refs.append(arena, net_name.leaf(target.name));
    }
    return refs.items;
}

/// One finding per THING a design rule judged — the instance an `(on …)` rule
/// named, or each net a `(net-rule …)` glob matched — because a gate has to
/// name what failed. The rule's rolled-up verdict is what the review document
/// shows one row for and what a `(verifies …)` addresses; here, where a finding
/// carries a severity, per-target is the only granularity that does not either
/// hide the failing net or count one rule's failure several times over.
fn appendDesignRuleFindings(
    allocator: std.mem.Allocator,
    rules: []const req_design_rules.Outcome,
    profile: Profile,
    findings: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void {
    for (rules) |rule| {
        for (rule.targets) |target| {
            // A sign-off closes every target of the rule it signed: the
            // reviewer judged the RULE, not one of its nets.
            const status = if (rule.status == .verified) req_checks.Status.verified else target.status;
            const message = if (rule.status == .verified and rule.verification != null)
                try allocator.dupe(u8, rule.verification.?.rationale)
            else if (rule.netScoped())
                try std.fmt.allocPrint(allocator, "{s}: {s}", .{ target.name, target.message })
            else
                try allocator.dupe(u8, target.message);
            try appendOwnedFinding(allocator, findings, .{
                .kind = .requirement,
                .status = findingStatus(status),
                .severity = requirementSeverity(status, profile),
                // A net rule has no part to attribute to; an (on "REF") rule
                // does, and naming it here is what lets the change filters and
                // the per-part review grouping pick the finding up.
                .ref_des = if (rule.netScoped()) "" else target.name,
                .component = "",
                .message = message,
                .requirement = .{
                    .id = rule.rule.id,
                    .text = rule.rule.text,
                    .citation = rule.rule.ref,
                    .datasheet = if (rule.rule.ref) |ref| ref.pdf else "",
                    .source = .design,
                    .target = target.name,
                    .block_path = rule.block_path,
                    .scope = rule.rule.scope,
                },
            });
        }
    }
}

fn findingStatus(status: req_checks.Status) FindingStatus {
    return switch (status) {
        .pass => .pass,
        .fail => .fail,
        .verified => .verified,
        .unproven => .unproven,
        .layout_deferred => .deferred,
        .na => .pending,
    };
}

/// Append one finding whose message is already owned by `allocator`. On an
/// ArrayList growth failure, ownership is released before propagating OOM.
fn appendOwnedFinding(
    allocator: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    finding: Finding,
) std.mem.Allocator.Error!void {
    errdefer allocator.free(finding.message);
    try findings.append(allocator, finding);
}

fn datasheetReviewFinding(
    allocator: std.mem.Allocator,
    inst: Instance,
    project_dir: []const u8,
    profile: Profile,
) std.mem.Allocator.Error!Finding {
    const severity_if_open: checks.Severity = if (isStrict(profile)) .@"error" else .warning;
    const review = inst.docs.review orelse return .{
        .kind = .datasheet_review,
        .status = .missing,
        .severity = severity_if_open,
        .ref_des = inst.ref_des,
        .component = inst.component,
        .message = try allocator.dupe(u8, "active component has no (datasheet-review ...) record"),
    };

    if (review.status != .complete) return .{
        .kind = .datasheet_review,
        .status = if (review.status == .stale) .stale else .incomplete,
        .severity = severity_if_open,
        .ref_des = inst.ref_des,
        .component = inst.component,
        .message = try allocator.dupe(
            u8,
            if (review.status == .stale) "datasheet review is marked stale" else "datasheet review is still draft",
        ),
        .requirement = .{ .datasheet = review.datasheet },
    };
    const issue = try reviewIssue(allocator, inst, review, project_dir);
    if (issue) |message| return .{
        .kind = .datasheet_review,
        .status = .incomplete,
        .severity = severity_if_open,
        .ref_des = inst.ref_des,
        .component = inst.component,
        .message = message,
        .requirement = .{ .datasheet = review.datasheet },
    };
    return .{
        .kind = .datasheet_review,
        .status = .pass,
        .severity = .info,
        .ref_des = inst.ref_des,
        .component = inst.component,
        .message = try allocator.dupe(u8, "datasheet review is complete and matches the current PDF"),
        .requirement = .{ .datasheet = review.datasheet },
    };
}

fn reviewIssue(
    allocator: std.mem.Allocator,
    inst: Instance,
    review: env_mod.DatasheetReview,
    project_dir: []const u8,
) std.mem.Allocator.Error!?[]const u8 {
    if (review.datasheet.len == 0) return try allocator.dupe(u8, "datasheet review does not name a PDF");
    if (!isSafeDatasheetName(review.datasheet)) {
        return try allocator.dupe(u8, "datasheet review PDF must be a basename under lib/datasheets");
    }
    if (!containsString(inst.docs.datasheets, review.datasheet)) {
        return try allocator.dupe(u8, "reviewed PDF is not attached with (datasheet ...)");
    }
    if (!isSha256(review.sha256)) {
        return try allocator.dupe(u8, "datasheet review sha256 must be 64 lowercase hexadecimal characters");
    }
    if (review.reviewed_by.len == 0) return try allocator.dupe(u8, "datasheet review is missing (reviewed-by ...)");
    if (!isIsoDateShape(review.date)) {
        return try allocator.dupe(u8, "datasheet review date must use YYYY-MM-DD");
    }

    for (required_review_categories) |category| {
        if (!reviewCoversCategory(review, category)) {
            return try std.fmt.allocPrint(
                allocator,
                "datasheet review has no category or reasoned N/A for '{s}'",
                .{category},
            );
        }
    }
    for (inst.requirements) |requirement| {
        const ref = requirement.ref orelse return try std.fmt.allocPrint(
            allocator,
            "requirement {s} has no datasheet citation",
            .{requirement.id},
        );
        if (!validCitation(ref, review.datasheet)) {
            return try std.fmt.allocPrint(
                allocator,
                "requirement {s} needs a page+quote citation to {s}",
                .{ requirement.id, review.datasheet },
            );
        }
    }
    if (project_dir.len == 0) return null;
    const pdf_path = try std.fmt.allocPrint(allocator, "{s}/lib/datasheets/{s}", .{ project_dir, review.datasheet });
    defer allocator.free(pdf_path);
    const pdf = infra_fs.cwd().readFileAlloc(allocator, pdf_path, 128 * 1024 * 1024) catch
        return try allocator.dupe(u8, "reviewed datasheet PDF cannot be read");
    defer allocator.free(pdf);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pdf, &digest, .{});
    const current = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, review.sha256, &current)) {
        return try allocator.dupe(u8, "datasheet PDF digest changed; review is stale");
    }
    return null;
}

fn validCitation(ref: env_mod.NoteRef, datasheet: []const u8) bool {
    if (!std.mem.eql(u8, ref.pdf, datasheet)) return false;
    if (ref.page == 0) return false;
    const quote = ref.quote orelse return false;
    return quote.len > 0;
}

fn isIsoDateShape(value: []const u8) bool {
    if (value.len != 10) return false;
    if (value[4] != '-' or value[7] != '-') return false;
    for (value, 0..) |character, index| {
        if (index == 4 or index == 7) continue;
        if (!std.ascii.isDigit(character)) return false;
    }
    return true;
}

fn containsString(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

fn reviewCoversCategory(review: env_mod.DatasheetReview, category: []const u8) bool {
    if (containsString(review.categories, category)) return true;
    for (review.not_applicable) |na| {
        if (std.mem.eql(u8, na.category, category) and na.rationale.len > 0) return true;
    }
    return false;
}

fn isSafeDatasheetName(name: []const u8) bool {
    return name.len > 0 and
        std.mem.indexOf(u8, name, "..") == null and
        std.mem.indexOfAny(u8, name, "/\\") == null;
}

fn isSha256(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |c| if (!std.ascii.isDigit(c) and (c < 'a' or c > 'f')) return false;
    return true;
}

// spec: preflight - authoring warns for pending requirements while strict preflight fails them
test "profile controls pending requirement severity" {
    try std.testing.expectEqual(Profile.authoring, parseProfile(null).?);
    try std.testing.expectEqual(Profile.preflight, parseProfile("preflight").?);
    try std.testing.expect(parseProfile("strictest") == null);
    try std.testing.expectEqual(checks.Severity.warning, requirementSeverity(.na, .authoring));
    try std.testing.expectEqual(checks.Severity.@"error", requirementSeverity(.na, .preflight));
    try std.testing.expectEqual(checks.Severity.@"error", requirementSeverity(.fail, .authoring));
}

// spec: preflight - the release profile fails profile gaps and unknown sub-forms that preflight only warns about
test "release strictness ranks above preflight" {
    try std.testing.expect(!isStrict(.authoring));
    try std.testing.expect(isStrict(.preflight));
    try std.testing.expect(isStrict(.release));
    try std.testing.expectEqual(Profile.release, parseProfile("release").?);
    try std.testing.expectEqual(checks.Severity.@"error", requirementSeverity(.na, .release));
    try std.testing.expectEqual(checks.Severity.info, profileSeverity(.authoring));
    try std.testing.expectEqual(checks.Severity.warning, profileSeverity(.preflight));
    try std.testing.expectEqual(checks.Severity.@"error", profileSeverity(.release));
    try std.testing.expectEqual(checks.Severity.@"error", evalWarningSeverity("unknown sub-form (placement-order …) in (design-block …)"));
    try std.testing.expectEqual(checks.Severity.warning, evalWarningSeverity("derived id collides with an existing id"));
}

// spec: preflight - complete reviews require every category or a reasoned N/A
test "review category coverage requires rationale for N/A" {
    const review = env_mod.DatasheetReview{
        .datasheet = "x.pdf",
        .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .categories = &.{"supply"},
        .not_applicable = &.{.{ .category = "thermal", .rationale = "" }},
    };
    try std.testing.expect(reviewCoversCategory(review, "supply"));
    try std.testing.expect(!reviewCoversCategory(review, "thermal"));
    try std.testing.expect(isIsoDateShape("2026-07-16"));
    try std.testing.expect(!isIsoDateShape("2026/07/16"));
    try std.testing.expect(!isIsoDateShape("26-07-16"));
}

// spec: preflight - digest identity uses canonical lowercase SHA-256 text
test "datasheet digest validation is strict" {
    try std.testing.expect(isSha256("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!isSha256("ABCDEF6789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!isSha256("short"));
}

// spec: preflight - replacing a reviewed PDF makes a completed digest-bound review stale
test "datasheet review detects PDF digest drift" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/datasheets");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/datasheets/part.pdf", .data = "reviewed bytes" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("reviewed bytes", &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    const requirement = env_mod.Requirement{
        .text = "supply must be valid",
        .id = "deadbeef",
        .ref = .{ .pdf = "part.pdf", .page = 3, .quote = "Supply voltage" },
    };
    const review = env_mod.DatasheetReview{
        .datasheet = "part.pdf",
        .sha256 = &digest_hex,
        .status = .complete,
        .reviewed_by = "test",
        .date = "2026-07-16",
        .categories = &required_review_categories,
    };
    const inst = Instance{
        .ref_des = "U1",
        .component = "part",
        .value = "part",
        .footprint = "x",
        .symbol = "x",
        .docs = .{ .datasheets = &.{"part.pdf"}, .review = review },
        .requirements = &.{requirement},
    };
    try std.testing.expect(try reviewIssue(allocator, inst, review, root) == null);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/datasheets/part.pdf", .data = "replacement" });
    const issue = (try reviewIssue(allocator, inst, review, root)).?;
    defer allocator.free(issue);
    try std.testing.expect(std.mem.indexOf(u8, issue, "digest changed") != null);
}

// spec: preflight - an append allocation failure releases the already-owned finding message
test "appendRequirementFindings cleans message when append fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const allocator = failing.allocator();
    const requirement = env_mod.Requirement{ .text = "manual check", .id = "deadbeef" };
    const inst = Instance{
        .ref_des = "U1",
        .component = "part",
        .value = "part",
        .footprint = "x",
        .symbol = "x",
        .requirements = &.{requirement},
    };
    var results: std.StringHashMapUnmanaged([]req_checks.Result) = .empty;
    var findings: std.ArrayList(Finding) = .empty;
    try std.testing.expectError(
        error.OutOfMemory,
        appendRequirementFindings(allocator, inst, .authoring, &results, &findings),
    );
}

// spec: preflight - design-owned rules are gated exactly like library requirements and satisfy the release profile's cited-requirement demand
test "design rules gate like library rules in every profile" {
    const allocator = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.createDirPath(std.testing.io, "lib/pinouts");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/pinouts/ldo.sexp",
        .data = "(pinout \"ldo\" (pin 1 \"VIN\") (pin 2 \"GND\") (pin 5 \"VOUT\"))",
    });
    // A part with NO library requirements at all: the release profile's
    // "at least one cited requirement" demand would normally fire on it, and
    // the design rule below is what answers it.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/ldo.sexp",
        .data = "(component \"ldo\" (pinout \"ldo\") (footprint \"sot23-5\") (class ldo))",
    });
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);

    var eval = Evaluator.init(allocator, project);
    defer eval.deinit();
    const value = try eval.evalSource(
        \\(import ldo)
        \\(design-block "board"
        \\  (instance "U1" ldo (pin 1 "V_5V0") (pin 2 "GND") (pin 5 "V_3V3"))
        \\  (requirement "The LDO input sits inside its recommended range"
        \\    (on "U1")
        \\    (ref "bench-notes.pdf" (page 1) (quote "5 V in"))
        \\    (check (voltage-range (pin "VIN") (min 2.7) (max 5.5))))
        \\  (net-rule "The output rail is classed" (nets "V_3V3") (in-net-class)))
    );
    const block = try designBlockOf(value);

    for ([_]Profile{ .authoring, .preflight, .release }) |profile| {
        const report = try run(allocator, &eval, block, project, profile);
        defer report.deinit(allocator);
        var design_findings: usize = 0;
        var net_rule_errors: usize = 0;
        var missing_requirements = false;
        for (report.findings) |finding| {
            if (finding.kind == .profile_incomplete and
                std.mem.indexOf(u8, finding.message, "no (requirement …) rules") != null)
                missing_requirements = true;
            if (finding.requirement.source != .design) continue;
            design_findings += 1;
            if (std.mem.eql(u8, finding.requirement.target, "V_3V3") and finding.severity == .@"error")
                net_rule_errors += 1;
        }
        // One finding per judged target: the (on "U1") instance and the one
        // net "V_3V3" matched.
        try std.testing.expectEqual(@as(usize, 2), design_findings);
        // A failing design rule is an error in EVERY profile, exactly as a
        // failing library check is — `requirementSeverity` is the one mapping.
        try std.testing.expectEqual(@as(usize, 1), net_rule_errors);
        // And the design rule discharges the release profile's demand for a
        // cited requirement on this part, which carries no library rules.
        try std.testing.expect(!missing_requirements);
    }
}

/// Unwrap an evaluated top-level form as the design block it must be.
fn designBlockOf(value: env_mod.Value) !*env_mod.DesignBlock {
    return switch (value) {
        .design_block => |b| b,
        else => error.TestNotADesign,
    };
}
