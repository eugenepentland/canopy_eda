//! Unified schematic preflight: turns executable component requirements,
//! design-side verifications, and digest-bound datasheet reviews into one
//! structured finding model. CLI `check`, CLI `run_checks`, and CLI `build`
//! all consume this module so they cannot disagree about requirement status.

const std = @import("std");
const checks = @import("checks.zig");
const component_classification = @import("component_classification.zig");
const env_mod = @import("eval/env.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;
const infra_fs = @import("infra/fs.zig");
const req_checks = @import("req_checks.zig");

const DesignBlock = env_mod.DesignBlock;
const Instance = env_mod.Instance;

/// Authoring remains backward compatible: pending manual requirements and
/// incomplete legacy review records are warnings. Preflight upgrades those
/// findings to errors; automated check failures are errors in both profiles.
pub const Profile = enum { authoring, preflight };

/// Parse an optional CLI/CLI profile word, defaulting to backward-compatible
/// authoring behavior. Unknown words are rejected.
pub fn parseProfile(word: ?[]const u8) ?Profile {
    const value = word orelse return .authoring;
    return std.meta.stringToEnum(Profile, value);
}

/// Validation subsystem that emitted a structured preflight finding.
pub const FindingKind = enum { requirement, datasheet_review };
/// Normalized outcome shared by machine checks and datasheet-review checks.
pub const FindingStatus = enum { pass, fail, pending, verified, missing, incomplete, stale };

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
    if (status == .na) return if (profile == .preflight) .@"error" else .warning;
    return .info;
}

/// Owned unified validation output. Call `deinit` after serialization.
pub const Report = struct {
    profile: Profile,
    findings: []const Finding,
    errors: usize,
    warnings: usize,

    pub fn deinit(self: Report, allocator: std.mem.Allocator) void {
        deinitFindings(allocator, self.findings);
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
    var results = try req_checks.runChecks(allocator, eval, block);
    defer req_checks.deinit(allocator, &results);
    req_checks.applyVerifications(&results, block, block.instances);

    var findings: std.ArrayList(Finding) = .empty;
    errdefer {
        for (findings.items) |finding| allocator.free(finding.message);
        findings.deinit(allocator);
    }
    try walkBlock(allocator, block, project_dir, profile, &results, &findings);

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
    };
}

fn walkBlock(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    profile: Profile,
    results: *const std.StringHashMapUnmanaged([]req_checks.Result),
    findings: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void {
    for (block.instances) |inst| {
        if (inst.placeholder) continue;
        if (!inst.requirements_ignored) {
            try appendRequirementFindings(allocator, inst, profile, results, findings);
        }
        if (component_classification.isActiveSemiconductor(inst)) {
            const finding = try datasheetReviewFinding(allocator, inst, project_dir, profile);
            try appendOwnedFinding(allocator, findings, finding);
        }
    }
    for (block.sub_blocks) |sub| {
        try walkBlock(allocator, sub.block, project_dir, profile, results, findings);
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

fn findingStatus(status: req_checks.Status) FindingStatus {
    if (status == .pass) return .pass;
    if (status == .fail) return .fail;
    if (status == .verified) return .verified;
    return .pending;
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
    const severity_if_open: checks.Severity = if (profile == .preflight) .@"error" else .warning;
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
