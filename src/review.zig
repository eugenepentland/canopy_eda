const std = @import("std");
const clock = @import("infra/clock.zig");
const env_mod = @import("eval/env.zig");
const erc_mod = @import("erc.zig");
const req_checks = @import("req_checks.zig");
const power_budget = @import("eval/power_budget.zig");
const power_sequencing = @import("eval/power_sequencing.zig");
const DesignBlock = env_mod.DesignBlock;
const Section = env_mod.Section;
const Instance = env_mod.Instance;
const Note = env_mod.Note;
const AssertionResult = env_mod.AssertionResult;

/// Error set for the review-builder pipeline. Mostly bubbles up the few I/O
/// callees (power-budget computation, sorting), all of which only allocate.
pub const ReviewError = std.mem.Allocator.Error;

/// Overall review verdict for a design.
pub const Status = enum { pass, warn, fail };

/// Top-of-page review summary: overall pass/warn/fail status plus the
/// roll-up counts (sections, instances, nets, ERC violations, assertions,
/// critical-IC requirement coverage). Computed by `buildSummary` from the
/// design's evaluator output and ERC results.
pub const Summary = struct {
    status: Status,
    section_count: usize,
    instance_count: usize,
    net_count: usize,
    violation_error: usize,
    violation_warning: usize,
    violation_info: usize,
    assertion_pass: usize,
    assertion_warn: usize,
    assertion_fail: usize,
    /// Hub-prefix instances (U/J/P/X/Q and any non-passive prefix) — the
    /// "main ICs" the user wants requirement coverage on. Mirrors the
    /// classification used by the SVG renderer (`render_svg.draw.isHub`).
    critical_count: usize = 0,
    /// Subset of `critical_count` whose library component declares at least
    /// one `(requirement ...)` form.
    critical_with_requirements: usize = 0,
    /// Path-qualified ref-deses of the critical components missing any
    /// requirements, sorted naturally so the user can scan and act on them.
    critical_missing_requirements: []const MissingRequirement = &.{},
    /// Total instances expected to have an MPN — every component except
    /// test points (which are board features, not parts a fab orders).
    bom_total: usize = 0,
    /// Subset of `bom_total` whose `(mpn …)` property is set in the
    /// `.bom` sidecar (or carried forward from the parts DB).
    bom_with_mpn: usize = 0,
    /// Path-qualified instances still missing an MPN. Sorted by ref_des.
    bom_missing_mpn: []const MissingMpn = &.{},
};

/// One instance in the design that doesn't yet have an MPN. Surfaced in the
/// summary so the user knows which BOM rows still need filling in.
pub const MissingMpn = struct {
    /// Sub-block-prefixed ref_des (e.g. "buck/L2") so duplicates across
    /// sub-blocks stay distinct.
    ref_des: []const u8,
    /// Library component family — useful context for picking an MPN.
    component: []const u8,
};

/// One critical-IC instance that the library hasn't declared any
/// `(requirement …)` rules for. Surfaced in the review summary so the
/// designer knows which `lib/components/<name>.sexp` files to add rules to.
pub const MissingRequirement = struct {
    /// Sub-block-prefixed ref_des (e.g. "pwr/U1") so duplicates across
    /// sub-blocks stay distinguishable.
    ref_des: []const u8,
    /// Library component name — points the user at the .sexp file under
    /// `lib/components/` they need to add `(requirement ...)` to.
    component: []const u8,
};

/// Section-level port flattened into review-friendly strings (direction
/// and signal_type are tag names rather than enums) so JSON / HTML
/// renderers can emit them without re-importing `env_mod`.
pub const PortSummary = struct {
    name: []const u8,
    direction: []const u8, // "in" | "out" | "io"
    signal_type: []const u8, // "power" | "signal" | "clock" | "data" | "differential"
    voltage: ?f64 = null,
    role: []const u8 = "",
    protocol: []const u8 = "",
};

/// Per-section review entry: title, slug for HTML anchors, status, design
/// notes, declared ports, and the subset of ERC violations that fall on
/// instances inside this section. Backs the per-section card on the
/// review page.
pub const SectionReport = struct {
    name: []const u8,
    slug: []const u8,
    status: env_mod.SectionStatus,
    description: []const u8,
    notes: []const env_mod.SectionNote,
    ports: []const PortSummary,
    instance_count: usize,
    /// ERC violations filtered to ref_des declared inside this section
    /// (including sub-sections). Violations with no ref_des aren't attributed
    /// here — they show up in `unresolved` only.
    violations: []const erc_mod.Violation,
    /// Component-level requirements aggregated from every instance in this
    /// section (and nested sub-sections). Read-only in the review UI; edited
    /// by changing `lib/components/<name>.sexp`. Sorted by ref_des.
    component_requirements: []const ComponentRequirementEntry = &.{},
};

/// One component's set of library-declared requirements as seen from a
/// specific placement in the design.
pub const ComponentRequirementEntry = struct {
    ref_des: []const u8,
    component: []const u8,
    requirements: []const env_mod.Requirement,
    /// Aligned with `requirements[i]` — pass/fail/na/verified plus the
    /// human-readable check message and any matching `(verifies …)`
    /// rationale. Empty slice when no check engine ran.
    req_results: []const req_checks.Result = &.{},
};

/// One row in the review's BOM table — a single placed instance with
/// its component family, value, and footprint. Sorting + grouping happens
/// at the BomGroup level above.
pub const BomEntry = struct {
    ref_des: []const u8,
    component: []const u8,
    value: []const u8,
    footprint: []const u8,
};

/// BOM rows bucketed by ref-des prefix letter (U, C, R, …) so the review
/// renders one collapsible section per part class. Entries inside are
/// natural-sorted (C2 before C10) for readability.
pub const BomGroup = struct {
    /// Ref-des letter prefix (e.g. "U", "C", "R", "TP").
    prefix: []const u8,
    entries: []const BomEntry,
};

/// Per-assertion outcome shown in the review's Assertions table.
/// `warn` is for `is_warning` assertions; `fail` is for hard failures.
pub const AssertionStatus = enum { pass, warn, fail };

/// One row in the review's Assertions table — the formatted message the
/// evaluator emitted (e.g. `VOUT = 3.30 (range 0.6-16.0)`) plus its
/// pass/warn/fail status pill.
pub const AssertionReport = struct {
    message: []const u8,
    status: AssertionStatus,
};

/// A single probe point on the board — resolved from any instance whose
/// component is `testpoint`. Pin 1's net gives the signal; optional notes
/// give the "what to look for" purpose column.
pub const TestPointEntry = struct {
    ref_des: []const u8,
    net: []const u8,
    purpose: []const u8 = "",
};

/// The fully-built review document for a design — everything the
/// `/review/:name` HTML and `/api/review/:name` JSON endpoints need to
/// render. Aggregates the summary, per-section reports, power-budget /
/// sequencing tables, BOM, assertions, and unresolved violations.
/// One node in the power-tree visualization. `layer` is the topological
/// distance from a rail with no upstream (board input or top-level
/// regulator) — feeds the column placement in `render_power_tree_svg`.
pub const PowerTreeNode = struct {
    rail: []const u8,
    nominal: ?f64,
    source_ref_des: []const u8 = "",
    layer: u32 = 0,
};

/// One directed edge from an upstream rail to a downstream rail.
pub const PowerTreeEdge = struct {
    from: []const u8,
    to: []const u8,
};

/// Topologically-arranged view of `block.rails` for visualisation. Empty
/// when the block declares no rails.
pub const PowerTree = struct {
    nodes: []const PowerTreeNode = &.{},
    edges: []const PowerTreeEdge = &.{},
};

pub const ReviewDoc = struct {
    design_name: []const u8,
    title: []const u8,
    generated_at: []const u8, // ISO-8601 UTC ("YYYY-MM-DDTHH:MM:SSZ")
    summary: Summary,
    sections: []const SectionReport,
    power_budget: []const power_budget.Rail,
    power_tree: PowerTree = .{},
    power_sequence: []const power_sequencing.SequenceRow,
    test_points: []const TestPointEntry,
    bom: []const BomGroup,
    assertions: []const AssertionReport,
    /// Flat list of every error+warning ERC violation (any severity-info is
    /// excluded to keep the unresolved list actionable).
    unresolved: []const erc_mod.Violation,
    /// Component requirements for instances that live inside a sub-block
    /// (and therefore aren't attached to any top-level section). The check
    /// engine already evaluates these; this field surfaces them in the
    /// review JSON / HTML so power-chain ICs (charger, buck, LDO, ADCs in
    /// modules, …) get the same coverage as top-level parts.
    subblock_requirements: []const ComponentRequirementEntry = &.{},
};

/// Build a review document for a design block. `assertions` comes from the
/// evaluator's `assertions` list (pass an empty slice when not available).
/// `check_results` is the (already verifies-overlaid) map from
/// `req_checks.runChecks` + `applyVerifications`; pass `null` to skip status
/// info (every requirement will surface as `na`).
/// All allocations use the supplied allocator; the returned struct references
/// those allocations plus string slices owned by the block.
pub fn buildReview(
    allocator: std.mem.Allocator,
    design_name: []const u8,
    block: *const DesignBlock,
    assertions: []const AssertionResult,
    violations: []const erc_mod.Violation,
    check_results: ?*const std.StringHashMapUnmanaged([]req_checks.Result),
) ReviewError!ReviewDoc {
    const sections = try buildSectionReports(allocator, block, violations, check_results);
    const sub_reqs = try collectSubblockRequirements(allocator, block, check_results);
    const rails = try power_budget.analyze(allocator, block);
    const rails_sorted = try sortRailsByTightness(allocator, rails);
    const power_tree = try buildPowerTree(allocator, block);
    const sequence = try power_sequencing.analyze(allocator, block);
    const test_points = try buildTestPoints(allocator, block);
    const bom = try buildBom(allocator, block);
    const asserts = try buildAssertionReports(allocator, assertions);
    const unresolved = try filterUnresolved(allocator, violations);

    const summary = try buildSummary(allocator, block, sections.len, violations, assertions);
    const generated_at = try isoTimestampNow(allocator);

    return .{
        .design_name = design_name,
        .title = block.name,
        .generated_at = generated_at,
        .summary = summary,
        .sections = sections,
        .power_budget = rails_sorted,
        .power_tree = power_tree,
        .power_sequence = sequence,
        .test_points = test_points,
        .bom = bom,
        .assertions = asserts,
        .unresolved = unresolved,
        .subblock_requirements = sub_reqs,
    };
}

/// Walk every nested sub-block instance and emit a ComponentRequirementEntry
/// for each one that has library requirements. Ref-des is prefixed with the
/// sub-block path (e.g. "buck/U12") to match the keys in `check_results`.
fn collectSubblockRequirements(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    check_results: ?*const std.StringHashMapUnmanaged([]req_checks.Result),
) ![]const ComponentRequirementEntry {
    var out: std.ArrayListUnmanaged(ComponentRequirementEntry) = .empty;
    for (block.sub_blocks) |sb| try walkSubblock(allocator, sb.block, sb.name, check_results, &out);
    std.mem.sort(ComponentRequirementEntry, out.items, {}, lessThanByRefDes);
    return out.items;
}

fn walkSubblock(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    prefix: []const u8,
    check_results: ?*const std.StringHashMapUnmanaged([]req_checks.Result),
    out: *std.ArrayListUnmanaged(ComponentRequirementEntry),
) !void {
    for (block.instances) |inst| {
        if (inst.requirements.len == 0) continue;
        // Display the sub-block path (e.g. "buck/U12") so the reviewer knows
        // which sub-block placed it, but the check_results map is keyed by
        // the post-renumbering global ref_des (`req_checks.zig:150` uses
        // `inst.ref_des` directly), so look up under the plain ref.
        const display_ref = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, inst.ref_des });
        const results: []const req_checks.Result = if (check_results) |m|
            (m.get(inst.ref_des) orelse &.{})
        else
            &.{};
        try out.append(allocator, .{
            .ref_des = display_ref,
            .component = inst.component,
            .requirements = inst.requirements,
            .req_results = results,
        });
    }
    for (block.sub_blocks) |child| {
        const nested = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, child.name });
        try walkSubblock(allocator, child.block, nested, check_results, out);
    }
}

/// Collect all `testpoint`-component instances across the design and its
/// sub-blocks, joining each to its pin-1 net and any `(note "TPn" "...")`.
/// Sorted by ref_des in natural order so TP1, TP2, TP10 stay in sequence.
fn buildTestPoints(allocator: std.mem.Allocator, block: *const DesignBlock) ![]const TestPointEntry {
    var out: std.ArrayListUnmanaged(TestPointEntry) = .empty;
    try collectTestPoints(allocator, block, &out);
    std.mem.sort(TestPointEntry, out.items, {}, lessThanTestPoint);
    return out.items;
}

fn collectTestPoints(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    out: *std.ArrayListUnmanaged(TestPointEntry),
) !void {
    for (block.instances) |inst| {
        if (!isTestPoint(inst)) continue;
        const net = findPin1Net(block, inst.ref_des);
        const purpose = findNoteFor(block.notes, inst.ref_des);
        try out.append(allocator, .{
            .ref_des = inst.ref_des,
            .net = net,
            .purpose = purpose,
        });
    }
    for (block.sub_blocks) |sb| try collectTestPoints(allocator, sb.block, out);
}

fn isTestPoint(inst: Instance) bool {
    return std.mem.eql(u8, inst.component, "testpoint") or
        std.mem.startsWith(u8, inst.component, "testpoint-");
}

fn findPin1Net(block: *const DesignBlock, ref_des: []const u8) []const u8 {
    for (block.nets) |net| {
        for (net.pins) |p| {
            if (!std.mem.eql(u8, p.ref_des, ref_des)) continue;
            if (std.mem.eql(u8, p.pin, "1")) return net.name;
        }
    }
    return "";
}

fn findNoteFor(notes: []const Note, ref_des: []const u8) []const u8 {
    for (notes) |n| {
        if (std.mem.eql(u8, n.ref_des, ref_des)) return n.text;
    }
    return "";
}

fn lessThanTestPoint(_: void, a: TestPointEntry, b: TestPointEntry) bool {
    return lessThanNatural(a.ref_des, b.ref_des);
}

fn buildSummary(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    section_count: usize,
    violations: []const erc_mod.Violation,
    assertions: []const AssertionResult,
) !Summary {
    var err: usize = 0;
    var warn: usize = 0;
    var info: usize = 0;
    for (violations) |v| switch (v.severity) {
        .@"error" => err += 1,
        .warning => warn += 1,
        .info => info += 1,
    };

    var a_pass: usize = 0;
    var a_warn: usize = 0;
    var a_fail: usize = 0;
    for (assertions) |a| {
        if (a.passed) {
            a_pass += 1;
        } else if (a.is_warning) {
            a_warn += 1;
        } else {
            a_fail += 1;
        }
    }

    const status: Status = blk: {
        if (err > 0 or a_fail > 0) break :blk .fail;
        if (warn > 0 or a_warn > 0) break :blk .warn;
        break :blk .pass;
    };

    var critical_total: usize = 0;
    var critical_with_reqs: usize = 0;
    var missing: std.ArrayListUnmanaged(MissingRequirement) = .empty;
    try collectCriticalCoverage(allocator, block, "", &critical_total, &critical_with_reqs, &missing);
    std.mem.sort(MissingRequirement, missing.items, {}, lessThanMissing);

    var bom_total: usize = 0;
    var bom_with_mpn: usize = 0;
    var bom_missing: std.ArrayListUnmanaged(MissingMpn) = .empty;
    try collectMpnCoverage(allocator, block, "", &bom_total, &bom_with_mpn, &bom_missing);
    std.mem.sort(MissingMpn, bom_missing.items, {}, lessThanMissingMpn);

    return .{
        .status = status,
        .section_count = section_count,
        .instance_count = countInstancesRecursive(block),
        .net_count = countNetsRecursive(block),
        .violation_error = err,
        .violation_warning = warn,
        .violation_info = info,
        .assertion_pass = a_pass,
        .assertion_warn = a_warn,
        .assertion_fail = a_fail,
        .critical_count = critical_total,
        .critical_with_requirements = critical_with_reqs,
        .critical_missing_requirements = missing.items,
        .bom_total = bom_total,
        .bom_with_mpn = bom_with_mpn,
        .bom_missing_mpn = bom_missing.items,
    };
}

/// Walk the design (and every sub-block) and bucket every "critical" hub
/// instance into total, with-reqs, and missing-list. `path_prefix` carries
/// the sub-block path so a missing entry like "pwr/U1" stays distinct from
/// a top-level "U1".
fn collectCriticalCoverage(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    path_prefix: []const u8,
    total: *usize,
    with_reqs: *usize,
    missing: *std.ArrayListUnmanaged(MissingRequirement),
) !void {
    for (block.instances) |inst| {
        if (!isCriticalRefDes(inst.ref_des)) continue;
        if (isTestPoint(inst)) continue;
        if (inst.requirements_ignored) continue;
        total.* += 1;
        if (inst.requirements.len > 0) {
            with_reqs.* += 1;
        } else {
            const qualified = if (path_prefix.len == 0)
                try allocator.dupe(u8, inst.ref_des)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path_prefix, inst.ref_des });
            try missing.append(allocator, .{ .ref_des = qualified, .component = inst.component });
        }
    }
    for (block.sub_blocks) |sb| {
        const child_prefix = if (path_prefix.len == 0)
            try allocator.dupe(u8, sb.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path_prefix, sb.name });
        try collectCriticalCoverage(allocator, sb.block, child_prefix, total, with_reqs, missing);
    }
}

/// Mirror of `render_svg.draw.isHub`: U/J/P/X/Q and any non-passive prefix
/// counts as a critical IC; R/C/L/F/D are passive spokes and excluded.
/// Operates on the bare ref_des as it appears in source — the caller adds
/// any sub-block path prefix separately.
fn isCriticalRefDes(ref_des: []const u8) bool {
    if (ref_des.len == 0) return false;
    return switch (ref_des[0]) {
        'U', 'J', 'P', 'X', 'Q' => true,
        'R', 'C', 'L', 'F', 'D' => false,
        else => true,
    };
}

fn lessThanMissing(_: void, a: MissingRequirement, b: MissingRequirement) bool {
    return lessThanNatural(a.ref_des, b.ref_des);
}

/// Walk the design (and every sub-block) bucketing every non-testpoint
/// instance into bom_total + bom_with_mpn, with leftovers appended to
/// `missing` so the summary table can name them. `path_prefix` carries
/// the sub-block path so a missing entry like "buck/L2" stays distinct
/// from a top-level "L2".
fn collectMpnCoverage(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    path_prefix: []const u8,
    total: *usize,
    with_mpn: *usize,
    missing: *std.ArrayListUnmanaged(MissingMpn),
) std.mem.Allocator.Error!void {
    for (block.instances) |inst| {
        if (isTestPoint(inst)) continue;
        total.* += 1;
        var has_mpn = false;
        for (inst.properties) |p| {
            if (std.mem.eql(u8, p.key, "mpn") and p.value.len > 0) {
                has_mpn = true;
                break;
            }
        }
        if (has_mpn) {
            with_mpn.* += 1;
        } else {
            const ref = if (path_prefix.len > 0)
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path_prefix, inst.ref_des })
            else
                try allocator.dupe(u8, inst.ref_des);
            try missing.append(allocator, .{ .ref_des = ref, .component = inst.component });
        }
    }
    for (block.sub_blocks) |sb| {
        const child_prefix = if (path_prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path_prefix, sb.name })
        else
            sb.name;
        try collectMpnCoverage(allocator, sb.block, child_prefix, total, with_mpn, missing);
    }
}

fn lessThanMissingMpn(_: void, a: MissingMpn, b: MissingMpn) bool {
    return lessThanNatural(a.ref_des, b.ref_des);
}

/// Flatten instance count across the design plus every sub-block.
/// `block.instances` already includes section instances (the evaluator adds
/// them to both lists), so recursing into sections would double-count.
fn countInstancesRecursive(block: *const DesignBlock) usize {
    var n: usize = block.instances.len;
    for (block.sub_blocks) |sb| n += countInstancesRecursive(sb.block);
    return n;
}

/// Flatten net count across the design plus every sub-block. Sub-block nets
/// remain separate from top-level nets until net-ties bridge them — this
/// counts each equivalence class as it appears in source, matching the
/// designs page tally.
fn countNetsRecursive(block: *const DesignBlock) usize {
    var n: usize = block.nets.len;
    for (block.sub_blocks) |sb| n += countNetsRecursive(sb.block);
    return n;
}

fn buildSectionReports(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: []const erc_mod.Violation,
    check_results: ?*const std.StringHashMapUnmanaged([]req_checks.Result),
) ![]const SectionReport {
    var out: std.ArrayListUnmanaged(SectionReport) = .empty;
    for (block.sections) |sec| {
        const rep = try reportFromSection(allocator, block, sec, violations, check_results);
        try out.append(allocator, rep);
    }
    return out.items;
}

fn reportFromSection(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    sec: Section,
    violations: []const erc_mod.Violation,
    check_results: ?*const std.StringHashMapUnmanaged([]req_checks.Result),
) !SectionReport {
    // Collect every ref_des that belongs to this section (including nested
    // sub-sections and pin-group attachments on top-level instances).
    var refs: std.StringHashMapUnmanaged(void) = .empty;
    try collectSectionRefs(allocator, sec, &refs);

    var filtered: std.ArrayListUnmanaged(erc_mod.Violation) = .empty;
    for (violations) |v| {
        if (v.ref_des.len == 0) continue;
        if (!refs.contains(v.ref_des)) continue;
        try filtered.append(allocator, v);
    }

    var ports: std.ArrayListUnmanaged(PortSummary) = .empty;
    for (sec.ports) |p| {
        try ports.append(allocator, .{
            .name = p.name,
            .direction = @tagName(p.direction),
            .signal_type = @tagName(p.signal_type),
            .voltage = p.voltage,
            .role = p.role,
            .protocol = p.protocol,
        });
    }

    const comp_reqs = try collectComponentRequirements(allocator, block, sec, &refs, check_results);

    return .{
        .name = sec.name,
        .slug = try slugify(allocator, sec.name),
        .status = sec.status,
        .description = sec.description,
        .notes = sec.notes,
        .ports = ports.items,
        .instance_count = countSectionInstances(sec),
        .violations = filtered.items,
        .component_requirements = comp_reqs,
    };
}

/// Collect `(requirement ...)` entries for every component placed in this
/// section. Walks `sec.instances` + sub-section instances, plus top-level
/// instances referenced by `(pins ref "Uxx" ...)` — the STM32-style multipart
/// case where one physical part is attached to several sections. Dedupes by
/// ref_des so a single instance only contributes one entry.
fn collectComponentRequirements(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    sec: Section,
    refs: *const std.StringHashMapUnmanaged(void),
    check_results: ?*const std.StringHashMapUnmanaged([]req_checks.Result),
) ![]const ComponentRequirementEntry {
    var by_ref: std.StringHashMapUnmanaged(Instance) = .empty;
    try collectSectionInstances(sec, &by_ref, allocator);
    // Add top-level instances that pin-groups attach to this section.
    var it = refs.iterator();
    while (it.next()) |e| {
        const rd = e.key_ptr.*;
        if (by_ref.contains(rd)) continue;
        for (block.instances) |inst| {
            if (std.mem.eql(u8, inst.ref_des, rd)) {
                try by_ref.put(allocator, rd, inst);
                break;
            }
        }
    }

    var out: std.ArrayListUnmanaged(ComponentRequirementEntry) = .empty;
    var it2 = by_ref.iterator();
    while (it2.next()) |e| {
        const inst = e.value_ptr.*;
        if (inst.requirements.len == 0) continue;
        const results: []const req_checks.Result = if (check_results) |m|
            (m.get(inst.ref_des) orelse &.{})
        else
            &.{};
        try out.append(allocator, .{
            .ref_des = inst.ref_des,
            .component = inst.component,
            .requirements = inst.requirements,
            .req_results = results,
        });
    }
    std.mem.sort(ComponentRequirementEntry, out.items, {}, lessThanByRefDes);
    return out.items;
}

fn collectSectionInstances(
    sec: Section,
    out: *std.StringHashMapUnmanaged(Instance),
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    for (sec.instances) |inst| {
        try out.put(allocator, inst.ref_des, inst);
    }
    for (sec.sub_sections) |sub| try collectSectionInstances(sub, out, allocator);
}

fn lessThanByRefDes(_: void, a: ComponentRequirementEntry, b: ComponentRequirementEntry) bool {
    return std.mem.lessThan(u8, a.ref_des, b.ref_des);
}

fn collectSectionRefs(
    allocator: std.mem.Allocator,
    sec: Section,
    refs: *std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!void {
    for (sec.instances) |inst| try refs.put(allocator, inst.ref_des, {});
    for (sec.pin_groups) |pg| try refs.put(allocator, pg.ref_des, {});
    for (sec.sub_sections) |sub| try collectSectionRefs(allocator, sub, refs);
}

fn countSectionInstances(sec: Section) usize {
    var n: usize = sec.instances.len;
    for (sec.sub_sections) |sub| n += countSectionInstances(sub);
    return n;
}

fn buildBom(allocator: std.mem.Allocator, block: *const DesignBlock) ![]const BomGroup {
    // Group by ref_des letter prefix (U, J, C, R, L, D, F, TP, SW, X, Q, ...).
    var by_prefix: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(BomEntry)) = .empty;
    var all_instances: std.ArrayListUnmanaged(Instance) = .empty;
    try appendInstances(allocator, &all_instances, block);

    for (all_instances.items) |inst| {
        if (inst.ref_des.len == 0) continue;
        const prefix = try prefixOf(allocator, inst.ref_des);
        const gop = try by_prefix.getOrPut(allocator, prefix);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, .{
            .ref_des = inst.ref_des,
            .component = inst.component,
            .value = inst.value,
            .footprint = inst.footprint,
        });
    }

    // Sort prefixes alphabetically so rendering is deterministic.
    var keys: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = by_prefix.iterator();
    while (it.next()) |e| try keys.append(allocator, e.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, lessThanString);

    var groups: std.ArrayListUnmanaged(BomGroup) = .empty;
    for (keys.items) |k| {
        const list = by_prefix.get(k) orelse continue;
        // Sort entries inside a group by numeric suffix when available
        // (so C1, C2, C10 order correctly instead of C1, C10, C2).
        const entries = try allocator.dupe(BomEntry, list.items);
        std.mem.sort(BomEntry, entries, {}, lessThanRefDes);
        try groups.append(allocator, .{ .prefix = k, .entries = entries });
    }
    return groups.items;
}

fn appendInstances(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(Instance),
    block: *const DesignBlock,
) std.mem.Allocator.Error!void {
    for (block.instances) |inst| try list.append(allocator, inst);
    for (block.sub_blocks) |sb| try appendInstances(allocator, list, sb.block);
}

fn prefixOf(allocator: std.mem.Allocator, ref_des: []const u8) ![]const u8 {
    // Strip any "sub/" namespace prefix, then take leading alphabetic chars.
    var s = ref_des;
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| if (i + 1 < s.len) {
        s = s[i + 1 ..];
    };
    var end: usize = 0;
    while (end < s.len and std.ascii.isAlphabetic(s[end])) end += 1;
    if (end == 0) return try allocator.dupe(u8, "?");
    return try allocator.dupe(u8, s[0..end]);
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn lessThanRefDes(_: void, a: BomEntry, b: BomEntry) bool {
    return lessThanNatural(a.ref_des, b.ref_des);
}

/// Natural ordering: splits trailing digits so "C10" > "C2".
fn lessThanNatural(a: []const u8, b: []const u8) bool {
    const a_split = splitTrailingDigits(a);
    const b_split = splitTrailingDigits(b);
    const head_cmp = std.mem.order(u8, a_split.head, b_split.head);
    if (head_cmp != .eq) return head_cmp == .lt;
    const an = std.fmt.parseInt(u64, a_split.tail, 10) catch return std.mem.order(u8, a, b) == .lt;
    const bn = std.fmt.parseInt(u64, b_split.tail, 10) catch return std.mem.order(u8, a, b) == .lt;
    return an < bn;
}

fn splitTrailingDigits(s: []const u8) struct { head: []const u8, tail: []const u8 } {
    var i: usize = s.len;
    while (i > 0 and std.ascii.isDigit(s[i - 1])) i -= 1;
    return .{ .head = s[0..i], .tail = s[i..] };
}

fn buildAssertionReports(
    allocator: std.mem.Allocator,
    assertions: []const AssertionResult,
) ![]const AssertionReport {
    var out: std.ArrayListUnmanaged(AssertionReport) = .empty;
    for (assertions) |a| {
        const status: AssertionStatus = if (a.passed)
            .pass
        else if (a.is_warning)
            .warn
        else
            .fail;
        try out.append(allocator, .{ .message = a.message, .status = status });
    }
    return out.items;
}

fn filterUnresolved(allocator: std.mem.Allocator, violations: []const erc_mod.Violation) ![]const erc_mod.Violation {
    var out: std.ArrayListUnmanaged(erc_mod.Violation) = .empty;
    for (violations) |v| {
        if (v.severity == .info) continue;
        try out.append(allocator, v);
    }
    return out.items;
}

/// Compute a topologically-layered view of the rail graph for the
/// power-tree visualisation. Upstream is derived on-the-fly: a rail R
/// sourced by sub-block S has its upstream identified by walking S's
/// `direction == "in"` ports, following `net_ties` to top-level names,
/// and matching those against other rails in `block.rails`. Layer
/// assignment is BFS from rails with no resolved upstream.
///
/// The empty case (block.rails.len == 0) returns an empty `PowerTree`.
pub fn buildPowerTree(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
) std.mem.Allocator.Error!PowerTree {
    if (block.rails.len == 0) return .{};

    // Map rail name → index for fast existence checks.
    var rail_index: std.StringHashMapUnmanaged(usize) = .empty;
    defer rail_index.deinit(allocator);
    for (block.rails, 0..) |r, i| {
        try rail_index.put(allocator, r.name, i);
    }

    // For each rail, derive its upstream rail name. The walk is bounded:
    // few sub-blocks, few input ports per sub-block, few net-ties.
    var upstream = try allocator.alloc(?[]const u8, block.rails.len);
    @memset(upstream, null);
    for (block.rails, 0..) |rail, i| {
        if (rail.source_ref_des.len == 0) continue;
        const sb = findSubBlock(block, rail.source_ref_des) orelse continue;
        for (sb.block.ports) |port| {
            if (!std.mem.eql(u8, port.direction, "in")) continue;
            const top_net = findTopNetForPort(block, sb.name, port.name) orelse continue;
            if (rail_index.contains(top_net)) {
                upstream[i] = top_net;
                break;
            }
        }
    }

    // BFS layer assignment. Rails with null upstream are layer 0; rails
    // whose upstream sits at layer L become layer L+1. The fixed-point
    // loop converges in (max-depth) iterations; for typical trees that's
    // 3-4 passes.
    var layers = try allocator.alloc(u32, block.rails.len);
    @memset(layers, 0);
    var pass: u32 = 0;
    while (pass < block.rails.len + 1) : (pass += 1) {
        var changed = false;
        for (block.rails, 0..) |_, i| {
            const up = upstream[i] orelse continue;
            const up_idx = rail_index.get(up) orelse continue;
            const wanted = layers[up_idx] + 1;
            if (layers[i] != wanted) {
                layers[i] = wanted;
                changed = true;
            }
        }
        if (!changed) break;
    }

    // Build nodes + edges.
    const nodes = try allocator.alloc(PowerTreeNode, block.rails.len);
    for (block.rails, 0..) |rail, i| {
        nodes[i] = .{
            .rail = rail.name,
            .nominal = rail.nominal,
            .source_ref_des = rail.source_ref_des,
            .layer = layers[i],
        };
    }

    var edges: std.ArrayListUnmanaged(PowerTreeEdge) = .empty;
    for (block.rails, 0..) |rail, i| {
        if (upstream[i]) |up| try edges.append(allocator, .{ .from = up, .to = rail.name });
    }

    return .{
        .nodes = nodes,
        .edges = try edges.toOwnedSlice(allocator),
    };
}

fn findSubBlock(block: *const DesignBlock, name: []const u8) ?env_mod.SubBlock {
    for (block.sub_blocks) |sb| {
        if (std.mem.eql(u8, sb.name, name)) return sb;
    }
    return null;
}

fn findTopNetForPort(block: *const DesignBlock, sb_name: []const u8, port_name: []const u8) ?[]const u8 {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ sb_name, port_name }) catch return null;
    for (block.net_ties) |nt| {
        if (std.mem.eql(u8, nt.a, path)) return nt.b;
        if (std.mem.eql(u8, nt.b, path)) return nt.a;
    }
    return null;
}

// spec: review - buildPowerTree assigns each rail to a topological layer rooted at upstream sources
test "buildPowerTree layers cascade correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // 5V (layer 0) → 3V3 (layer 1) → 1V8 (layer 2)
    const buck_ports = try alloc.alloc(env_mod.Port, 2);
    buck_ports[0] = .{ .name = "VIN", .net = "VIN", .direction = "in" };
    buck_ports[1] = .{ .name = "VOUT", .net = "VOUT", .direction = "out", .nominal = 3.3, .current_max = 2.0 };
    const buck_block = try alloc.create(DesignBlock);
    buck_block.* = .{
        .name = "buck",
        .instances = &.{},
        .nets = &.{},
        .ports = buck_ports,
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const ldo_ports = try alloc.alloc(env_mod.Port, 2);
    ldo_ports[0] = .{ .name = "VIN", .net = "VIN", .direction = "in" };
    ldo_ports[1] = .{ .name = "VOUT", .net = "VOUT", .direction = "out", .nominal = 1.8, .current_max = 0.5 };
    const ldo_block = try alloc.create(DesignBlock);
    ldo_block.* = .{
        .name = "ldo",
        .instances = &.{},
        .nets = &.{},
        .ports = ldo_ports,
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const sbs = try alloc.alloc(env_mod.SubBlock, 2);
    sbs[0] = .{ .name = "buck", .block = buck_block };
    sbs[1] = .{ .name = "ldo", .block = ldo_block };
    const ties = try alloc.alloc(env_mod.NetTie, 4);
    ties[0] = .{ .a = "buck/VIN", .b = "V5V" };
    ties[1] = .{ .a = "buck/VOUT", .b = "V3V3" };
    ties[2] = .{ .a = "ldo/VIN", .b = "V3V3" };
    ties[3] = .{ .a = "ldo/VOUT", .b = "V1V8" };
    const rails_data = try alloc.alloc(env_mod.PowerRail, 2);
    rails_data[0] = .{ .name = "V3V3", .source_ref_des = "buck", .nominal = 3.3 };
    rails_data[1] = .{ .name = "V1V8", .source_ref_des = "ldo", .nominal = 1.8 };
    const block: DesignBlock = .{
        .name = "tree-fixture",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = sbs,
        .net_ties = ties,
        .rails = rails_data,
    };
    const tree = try buildPowerTree(alloc, &block);
    try std.testing.expectEqual(@as(usize, 2), tree.nodes.len);

    var v3v3_layer: u32 = 0;
    var v1v8_layer: u32 = 0;
    for (tree.nodes) |n| {
        if (std.mem.eql(u8, n.rail, "V3V3")) v3v3_layer = n.layer;
        if (std.mem.eql(u8, n.rail, "V1V8")) v1v8_layer = n.layer;
    }
    try std.testing.expectEqual(@as(u32, 0), v3v3_layer);
    try std.testing.expectEqual(@as(u32, 1), v1v8_layer);

    try std.testing.expectEqual(@as(usize, 1), tree.edges.len);
    try std.testing.expectEqualStrings("V3V3", tree.edges[0].from);
    try std.testing.expectEqualStrings("V1V8", tree.edges[0].to);
}

// spec: review - buildPowerTree emits an empty tree when the block declares no rails
test "buildPowerTree empty block produces empty tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const block: DesignBlock = .{
        .name = "empty",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const tree = try buildPowerTree(alloc, &block);
    try std.testing.expectEqual(@as(usize, 0), tree.nodes.len);
    try std.testing.expectEqual(@as(usize, 0), tree.edges.len);
}

fn sortRailsByTightness(allocator: std.mem.Allocator, rails: []const power_budget.Rail) ![]const power_budget.Rail {
    const out = try allocator.dupe(power_budget.Rail, rails);
    std.mem.sort(power_budget.Rail, out, {}, lessThanRailMargin);
    return out;
}

fn lessThanRailMargin(_: void, a: power_budget.Rail, b: power_budget.Rail) bool {
    // Ordering: over (worst) first, then tight, then lowest margin %, then
    // no_source/no_consumers, then ok. Keeps the most actionable rails on
    // top of the review table.
    const rank_a = statusRank(a.status);
    const rank_b = statusRank(b.status);
    if (rank_a != rank_b) return rank_a < rank_b;
    const ma = a.margin_pct orelse std.math.inf(f64);
    const mb = b.margin_pct orelse std.math.inf(f64);
    if (ma != mb) return ma < mb;
    return std.mem.order(u8, a.net, b.net) == .lt;
}

fn statusRank(s: power_budget.RailStatus) u8 {
    return switch (s) {
        .over => 0,
        .tight => 1,
        .no_source => 2,
        .no_consumers => 3,
        .ok => 4,
    };
}

/// Format the current UTC time as ISO-8601 "YYYY-MM-DDTHH:MM:SSZ".
fn isoTimestampNow(allocator: std.mem.Allocator) ![]const u8 {
    const now_s: i64 = @intCast(@divTrunc(clock.nanoTimestamp(), clock.ns_per_s));
    return isoTimestamp(allocator, now_s);
}

/// Format a unix-epoch second count as ISO-8601 UTC ("YYYY-MM-DDTHH:MM:SSZ").
/// Used for both `generated_at` on the review doc and the `approved_at`
/// stamp on each per-section approval. Allocates the returned string on
/// the supplied allocator.
pub fn isoTimestamp(allocator: std.mem.Allocator, unix_s: i64) std.mem.Allocator.Error![]const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(unix_s) };
    const day_secs = es.getDaySeconds();
    const ed = es.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            @as(u32, yd.year),
            @intFromEnum(md.month),
            md.day_index + 1,
            day_secs.getHoursIntoDay(),
            day_secs.getMinutesIntoHour(),
            day_secs.getSecondsIntoMinute(),
        },
    );
}

/// Replace any non-alphanumeric run with a single hyphen; lower-case the rest.
/// Used for HTML anchor ids like "#sec-usb".
pub fn slugify(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var last_hyphen = true; // suppresses leading hyphens
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try buf.append(allocator, std.ascii.toLower(c));
            last_hyphen = false;
        } else if (!last_hyphen) {
            try buf.append(allocator, '-');
            last_hyphen = true;
        }
    }
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == '-') buf.items.len -= 1;
    if (buf.items.len == 0) try buf.append(allocator, '_');
    return buf.items;
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: review - slugify converts section titles to anchor-safe identifiers
test "slugify basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const s1 = try slugify(alloc, "USB");
    defer alloc.free(s1);
    try std.testing.expectEqualStrings("usb", s1);

    const s2 = try slugify(alloc, "STM32N657L0H3Q");
    defer alloc.free(s2);
    try std.testing.expectEqualStrings("stm32n657l0h3q", s2);

    const s3 = try slugify(alloc, "ADC Voltage Reference");
    defer alloc.free(s3);
    try std.testing.expectEqualStrings("adc-voltage-reference", s3);

    const s4 = try slugify(alloc, "HSE (Main Clock)");
    defer alloc.free(s4);
    try std.testing.expectEqualStrings("hse-main-clock", s4);
}

// spec: review - isoTimestamp formats epoch seconds as ISO-8601 UTC
test "isoTimestamp formats epoch seconds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Unix epoch 0 is 1970-01-01T00:00:00Z.
    const s = try isoTimestamp(alloc, 0);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", s);
}

// spec: review - buildSummary marks status=pass when no errors or warnings
test "buildSummary status pass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const block: DesignBlock = .{
        .name = "test",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const summary = try buildSummary(alloc, &block, 0, &.{}, &.{});
    try std.testing.expectEqual(Status.pass, summary.status);
}

// spec: review - buildSummary marks status=warn on warning-level violations
test "buildSummary status warn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const block: DesignBlock = .{
        .name = "test",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const violations = [_]erc_mod.Violation{
        .{ .kind = .missing_decoupling, .severity = .warning, .message = "x" },
    };
    const summary = try buildSummary(alloc, &block, 0, &violations, &.{});
    try std.testing.expectEqual(Status.warn, summary.status);
}

// spec: review - buildTestPoints collects testpoint instances with pin 1 net
test "buildTestPoints collects testpoint instances" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const pins = [_]env_mod.PinRef{.{ .ref_des = "TP1", .pin = "1" }};
    const nets = [_]env_mod.Net{.{ .name = "VDD", .pins = &pins }};
    const insts = [_]Instance{.{
        .ref_des = "TP1",
        .component = "testpoint",
        .value = "",
        .footprint = "",
        .symbol = "",
    }};
    const notes = [_]Note{.{ .ref_des = "TP1", .text = "Probe 3V3 rail" }};
    const block: DesignBlock = .{
        .name = "t",
        .instances = &insts,
        .nets = &nets,
        .ports = &.{},
        .notes = &notes,
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const tps = try buildTestPoints(alloc, &block);
    try std.testing.expectEqual(@as(usize, 1), tps.len);
    try std.testing.expectEqualStrings("TP1", tps[0].ref_des);
    try std.testing.expectEqualStrings("VDD", tps[0].net);
    try std.testing.expectEqualStrings("Probe 3V3 rail", tps[0].purpose);
}

// spec: review - buildTestPoints ignores non-testpoints
test "buildTestPoints ignores non-testpoints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const insts = [_]Instance{.{
        .ref_des = "U1",
        .component = "stm32n657l0h3q",
        .value = "",
        .footprint = "",
        .symbol = "",
    }};
    const block: DesignBlock = .{
        .name = "t",
        .instances = &insts,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const tps = try buildTestPoints(alloc, &block);
    try std.testing.expectEqual(@as(usize, 0), tps.len);
}

// spec: review - buildSummary marks status=fail on error-level violations
test "buildSummary status fail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const block: DesignBlock = .{
        .name = "test",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const violations = [_]erc_mod.Violation{
        .{ .kind = .duplicate_refdes, .severity = .@"error", .message = "x" },
    };
    const summary = try buildSummary(alloc, &block, 0, &violations, &.{});
    try std.testing.expectEqual(Status.fail, summary.status);
}

// spec: review - buildSummary counts critical hub instances and lists those missing requirements
test "buildSummary tracks critical-component requirement coverage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const reqs = [_]env_mod.Requirement{.{ .text = "VDD must be 3V3" }};
    const insts = [_]Instance{
        .{ .ref_des = "U1", .component = "stm32", .value = "", .footprint = "", .symbol = "", .requirements = &reqs },
        .{ .ref_des = "U2", .component = "ltc6655", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "C1", .component = "cap-0402", .value = "100nF", .footprint = "", .symbol = "" },
        .{ .ref_des = "J1", .component = "usb-c", .value = "", .footprint = "", .symbol = "" },
        // Test points have hub-style ref_des (TPx) but should be excluded —
        // they get their own table elsewhere and don't need requirements.
        .{ .ref_des = "TP1", .component = "testpoint", .value = "", .footprint = "", .symbol = "" },
    };
    const block: DesignBlock = .{
        .name = "t",
        .instances = &insts,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const summary = try buildSummary(alloc, &block, 0, &.{}, &.{});
    defer {
        for (summary.critical_missing_requirements) |m| alloc.free(m.ref_des);
        alloc.free(summary.critical_missing_requirements);
    }
    try std.testing.expectEqual(@as(usize, 3), summary.critical_count);
    try std.testing.expectEqual(@as(usize, 1), summary.critical_with_requirements);
    try std.testing.expectEqual(@as(usize, 2), summary.critical_missing_requirements.len);
    try std.testing.expectEqualStrings("J1", summary.critical_missing_requirements[0].ref_des);
    try std.testing.expectEqualStrings("U2", summary.critical_missing_requirements[1].ref_des);
}

// spec: review - buildSummary skips instances whose component sets ignore-requirements
test "buildSummary respects requirements_ignored opt-out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const insts = [_]Instance{
        .{ .ref_des = "U1", .component = "stm32", .value = "", .footprint = "", .symbol = "" },
        // Mounting hardware: shows up as a hub (H prefix → critical) but the
        // library marked it `(ignore-requirements)`, so it must not count.
        .{ .ref_des = "H1", .component = "screw-bushing", .value = "", .footprint = "", .symbol = "", .requirements_ignored = true },
    };
    const block: DesignBlock = .{
        .name = "t",
        .instances = &insts,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const summary = try buildSummary(alloc, &block, 0, &.{}, &.{});
    defer {
        for (summary.critical_missing_requirements) |m| alloc.free(m.ref_des);
        alloc.free(summary.critical_missing_requirements);
    }
    try std.testing.expectEqual(@as(usize, 1), summary.critical_count);
    try std.testing.expectEqual(@as(usize, 1), summary.critical_missing_requirements.len);
    try std.testing.expectEqualStrings("U1", summary.critical_missing_requirements[0].ref_des);
}
