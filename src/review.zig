const std = @import("std");
const env_mod = @import("eval/env.zig");
const erc_mod = @import("erc.zig");
const power_budget = @import("eval/power_budget.zig");
const power_sequencing = @import("eval/power_sequencing.zig");
const DesignBlock = env_mod.DesignBlock;
const Section = env_mod.Section;
const Instance = env_mod.Instance;
const Note = env_mod.Note;
const AssertionResult = env_mod.AssertionResult;

/// Overall review verdict for a design.
pub const Status = enum { pass, warn, fail };

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
};

pub const PortSummary = struct {
    name: []const u8,
    direction: []const u8, // "in" | "out" | "io"
    signal_type: []const u8, // "power" | "signal" | "clock" | "data" | "differential"
    voltage: ?f64 = null,
    role: []const u8 = "",
    protocol: []const u8 = "",
};

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
};

pub const BomEntry = struct {
    ref_des: []const u8,
    component: []const u8,
    value: []const u8,
    footprint: []const u8,
};

pub const BomGroup = struct {
    /// Ref-des letter prefix (e.g. "U", "C", "R", "TP").
    prefix: []const u8,
    entries: []const BomEntry,
};

pub const AssertionStatus = enum { pass, warn, fail };

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

/// One user-written checklist item on a section — e.g. "Power pins wired",
/// "Decoupling placed". Server allocates the 8-char hex id on add so the
/// client never has to invent one.
pub const ChecklistItem = struct {
    id: []const u8,
    text: []const u8,
    checked: bool = false,
};

/// Per-section review state: the checklist plus an overall approval
/// stamped with reviewer + UTC timestamp when the user clicks Approve.
pub const SectionReviewState = struct {
    section_slug: []const u8,
    items: []const ChecklistItem = &.{},
    approved: bool = false,
    approved_by: []const u8 = "",
    approved_at: []const u8 = "",
    /// SHA-256 hex of the section's content at the moment of approval.
    /// Recomputed on every build and compared in `reconcile()`; mismatch
    /// flips `approval_stale` so the UI prompts a re-approval without
    /// mutating the on-disk approval record.
    content_hash: []const u8 = "",
    /// Derived at build-time, not persisted: true when the live content
    /// hash differs from `content_hash`. Reviewer must re-approve.
    approval_stale: bool = false,
};

/// The full review-state payload for a design, persisted at
/// `{project_dir}/reviews/{name}.state.json`.
pub const ReviewState = struct {
    sections: []const SectionReviewState = &.{},
};

pub const ReviewDoc = struct {
    design_name: []const u8,
    title: []const u8,
    generated_at: []const u8, // ISO-8601 UTC ("YYYY-MM-DDTHH:MM:SSZ")
    summary: Summary,
    sections: []const SectionReport,
    power_budget: []const power_budget.Rail,
    power_sequence: []const power_sequencing.SequenceRow,
    test_points: []const TestPointEntry,
    bom: []const BomGroup,
    assertions: []const AssertionReport,
    /// Flat list of every error+warning ERC violation (any severity-info is
    /// excluded to keep the unresolved list actionable).
    unresolved: []const erc_mod.Violation,
    /// Per-section checklist and approval state loaded from
    /// `reviews/{name}.state.json` and reconciled against the live section
    /// list, so every section report has a matching state entry by slug.
    review_state: ReviewState = .{},
};

/// Build a review document for a design block. `assertions` comes from the
/// evaluator's `assertions` list (pass an empty slice when not available).
/// All allocations use the supplied allocator; the returned struct references
/// those allocations plus string slices owned by the block.
pub fn buildReview(
    allocator: std.mem.Allocator,
    design_name: []const u8,
    block: *const DesignBlock,
    assertions: []const AssertionResult,
    violations: []const erc_mod.Violation,
) !ReviewDoc {
    const sections = try buildSectionReports(allocator, block, violations);
    const rails = power_budget.analyze(allocator, block);
    const rails_sorted = try sortRailsByTightness(allocator, rails);
    const sequence = power_sequencing.analyze(allocator, block);
    const test_points = try buildTestPoints(allocator, block);
    const bom = try buildBom(allocator, block);
    const asserts = try buildAssertionReports(allocator, assertions);
    const unresolved = try filterUnresolved(allocator, violations);

    const summary = buildSummary(block, sections.len, violations, assertions);
    const generated_at = try isoTimestampNow(allocator);

    return .{
        .design_name = design_name,
        .title = block.name,
        .generated_at = generated_at,
        .summary = summary,
        .sections = sections,
        .power_budget = rails_sorted,
        .power_sequence = sequence,
        .test_points = test_points,
        .bom = bom,
        .assertions = asserts,
        .unresolved = unresolved,
    };
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
    block: *const DesignBlock,
    section_count: usize,
    violations: []const erc_mod.Violation,
    assertions: []const AssertionResult,
) Summary {
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
    };
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
) ![]const SectionReport {
    var out: std.ArrayListUnmanaged(SectionReport) = .empty;
    for (block.sections) |sec| {
        const rep = try reportFromSection(allocator, block, sec, violations);
        try out.append(allocator, rep);
    }
    return out.items;
}

fn reportFromSection(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    sec: Section,
    violations: []const erc_mod.Violation,
) !SectionReport {
    // Collect every ref_des that belongs to this section (including nested
    // sub-sections and pin-group attachments on top-level instances).
    var refs: std.StringHashMapUnmanaged(void) = .empty;
    collectSectionRefs(allocator, sec, &refs);

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

    const comp_reqs = try collectComponentRequirements(allocator, block, sec, &refs);

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
) ![]const ComponentRequirementEntry {
    var by_ref: std.StringHashMapUnmanaged(Instance) = .empty;
    collectSectionInstances(sec, &by_ref, allocator);
    // Add top-level instances that pin-groups attach to this section.
    var it = refs.iterator();
    while (it.next()) |e| {
        const rd = e.key_ptr.*;
        if (by_ref.contains(rd)) continue;
        for (block.instances) |inst| {
            if (std.mem.eql(u8, inst.ref_des, rd)) {
                by_ref.put(allocator, rd, inst) catch {};
                break;
            }
        }
    }

    var out: std.ArrayListUnmanaged(ComponentRequirementEntry) = .empty;
    var it2 = by_ref.iterator();
    while (it2.next()) |e| {
        const inst = e.value_ptr.*;
        if (inst.requirements.len == 0) continue;
        try out.append(allocator, .{
            .ref_des = inst.ref_des,
            .component = inst.component,
            .requirements = inst.requirements,
        });
    }
    std.mem.sort(ComponentRequirementEntry, out.items, {}, lessThanByRefDes);
    return out.items;
}

fn collectSectionInstances(
    sec: Section,
    out: *std.StringHashMapUnmanaged(Instance),
    allocator: std.mem.Allocator,
) void {
    for (sec.instances) |inst| {
        out.put(allocator, inst.ref_des, inst) catch {};
    }
    for (sec.sub_sections) |sub| collectSectionInstances(sub, out, allocator);
}

fn lessThanByRefDes(_: void, a: ComponentRequirementEntry, b: ComponentRequirementEntry) bool {
    return std.mem.lessThan(u8, a.ref_des, b.ref_des);
}

/// Hash the review-relevant content of a section — instances + values + pin
/// bindings, design notes, and every library-declared requirement of the
/// parts placed in the section. Used by `review_state.reconcile()` to detect
/// whether a section has drifted from what the reviewer approved, so the UI
/// can demand a fresh approval. Keep the fed bytes stable across builds: we
/// sort instance + requirement lists first, and include both design-side and
/// library-side state (so editing `lib/components/<X>.sexp` invalidates every
/// design that uses X).
pub fn sectionContentHash(
    allocator: std.mem.Allocator,
    rep: SectionReport,
    block: *const DesignBlock,
    sec: Section,
) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(rep.name);
    hasher.update("\x00");
    hasher.update(rep.description);
    hasher.update("\x00");

    // Design notes.
    const notes_sorted = try allocator.alloc(env_mod.SectionNote, rep.notes.len);
    defer allocator.free(notes_sorted);
    @memcpy(notes_sorted, rep.notes);
    std.mem.sort(env_mod.SectionNote, notes_sorted, {}, lessThanNoteByText);
    for (notes_sorted) |n| {
        hasher.update("note:");
        hasher.update(n.text);
        if (n.ref) |r| {
            hasher.update("|ref=");
            hasher.update(r.pdf);
            var pbuf: [16]u8 = undefined;
            const ps = std.fmt.bufPrint(&pbuf, "@{d}", .{r.page}) catch "";
            hasher.update(ps);
        }
        hasher.update("\x00");
    }

    // Instances (gathered via the same refs set used for requirements).
    var refs: std.StringHashMapUnmanaged(void) = .empty;
    collectSectionRefs(allocator, sec, &refs);
    var insts: std.StringHashMapUnmanaged(Instance) = .empty;
    collectSectionInstances(sec, &insts, allocator);
    var it = refs.iterator();
    while (it.next()) |e| {
        const rd = e.key_ptr.*;
        if (insts.contains(rd)) continue;
        for (block.instances) |inst| {
            if (std.mem.eql(u8, inst.ref_des, rd)) {
                insts.put(allocator, rd, inst) catch {};
                break;
            }
        }
    }
    var refs_sorted: std.ArrayListUnmanaged([]const u8) = .empty;
    defer refs_sorted.deinit(allocator);
    var it2 = insts.iterator();
    while (it2.next()) |e| try refs_sorted.append(allocator, e.key_ptr.*);
    std.mem.sort([]const u8, refs_sorted.items, {}, lessThanStr);
    for (refs_sorted.items) |rd| {
        const inst = insts.get(rd).?;
        hasher.update("inst:");
        hasher.update(inst.ref_des);
        hasher.update("|");
        hasher.update(inst.component);
        hasher.update("|");
        hasher.update(inst.value);
        hasher.update("|pins:");
        try hashPinBindingsForRef(&hasher, block, inst.ref_des, allocator);
        hasher.update("|req:");
        for (inst.requirements) |r| {
            hasher.update(r.text);
            if (r.ref) |ref| {
                hasher.update("@");
                hasher.update(ref.pdf);
                var pbuf: [16]u8 = undefined;
                const ps = std.fmt.bufPrint(&pbuf, ":{d}", .{ref.page}) catch "";
                hasher.update(ps);
            }
            hasher.update(";");
        }
        hasher.update("\x00");
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex_chars = "0123456789abcdef";
    var out = try allocator.alloc(u8, 64);
    for (digest, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return out;
}

fn lessThanNoteByText(_: void, a: env_mod.SectionNote, b: env_mod.SectionNote) bool {
    return std.mem.lessThan(u8, a.text, b.text);
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn hashPinBindingsForRef(
    hasher: *std.crypto.hash.sha2.Sha256,
    block: *const DesignBlock,
    ref_des: []const u8,
    allocator: std.mem.Allocator,
) !void {
    var bindings: std.ArrayListUnmanaged([]const u8) = .empty;
    defer bindings.deinit(allocator);
    for (block.nets) |net| {
        for (net.pins) |p| {
            if (!std.mem.eql(u8, p.ref_des, ref_des)) continue;
            const s = try std.fmt.allocPrint(allocator, "{s}={s}", .{ p.pin, net.name });
            try bindings.append(allocator, s);
        }
    }
    std.mem.sort([]const u8, bindings.items, {}, lessThanStr);
    for (bindings.items) |s| {
        hasher.update(s);
        hasher.update(",");
    }
}

fn collectSectionRefs(
    allocator: std.mem.Allocator,
    sec: Section,
    refs: *std.StringHashMapUnmanaged(void),
) void {
    for (sec.instances) |inst| refs.put(allocator, inst.ref_des, {}) catch {};
    for (sec.pin_groups) |pg| refs.put(allocator, pg.ref_des, {}) catch {};
    for (sec.sub_sections) |sub| collectSectionRefs(allocator, sub, refs);
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
    appendInstances(allocator, &all_instances, block);

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

fn appendInstances(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(Instance), block: *const DesignBlock) void {
    for (block.instances) |inst| list.append(allocator, inst) catch {};
    for (block.sub_blocks) |sb| appendInstances(allocator, list, sb.block);
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
    const now_s: i64 = @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_s));
    return isoTimestamp(allocator, now_s);
}

pub fn isoTimestamp(allocator: std.mem.Allocator, unix_s: i64) ![]const u8 {
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
pub fn slugify(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
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
    const alloc = std.testing.allocator;
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
    const alloc = std.testing.allocator;
    // Unix epoch 0 is 1970-01-01T00:00:00Z.
    const s = try isoTimestamp(alloc, 0);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", s);
}

// spec: review - buildSummary marks status=pass when no errors or warnings
test "buildSummary status pass" {
    const alloc = std.testing.allocator;
    _ = alloc;
    const block: DesignBlock = .{
        .name = "test",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const summary = buildSummary(&block, 0, &.{}, &.{});
    try std.testing.expectEqual(Status.pass, summary.status);
}

// spec: review - buildSummary marks status=warn on warning-level violations
test "buildSummary status warn" {
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
    const summary = buildSummary(&block, 0, &violations, &.{});
    try std.testing.expectEqual(Status.warn, summary.status);
}

// spec: review - buildTestPoints collects testpoint instances with pin 1 net
test "buildTestPoints collects testpoint instances" {
    const alloc = std.testing.allocator;
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
    const alloc = std.testing.allocator;
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
    const summary = buildSummary(&block, 0, &violations, &.{});
    try std.testing.expectEqual(Status.fail, summary.status);
}
