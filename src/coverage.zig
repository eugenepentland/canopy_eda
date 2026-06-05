//! Per-instance / per-section / overall coverage checks. Answers the
//! "is this design ready for layout?" question by walking every placed
//! component and asking whether the data needed for fab is filled in:
//!
//!   - value (e.g. "100nF", "10k") — present for both passives and ICs
//!   - footprint (e.g. "0402", "qfn-48") — same
//!   - mpn / manufacturer / datasheet — only required for ICs
//!   - requirements_verified — only required for ICs that declare
//!     library `(requirement …)` rules; checks that every rule has a
//!     `pass`/`verified` status in the supplied req_checks map
//!
//! Test points and instances whose library sets `(ignore-requirements)`
//! are excluded entirely (they're board features / mounting hardware,
//! not parts being designed).
//!
//! Roll-up happens in two stages: `computeSectionCoverage` aggregates
//! per-instance results for one Section, and `computeOverallCoverage`
//! aggregates every top-level + sub-block instance into a single
//! percentage suitable for the summary banner.

const std = @import("std");
const env_mod = @import("eval/env.zig");
const req_checks = @import("req_checks.zig");
const DesignBlock = env_mod.DesignBlock;
const Section = env_mod.Section;
const Instance = env_mod.Instance;

/// Which dimension of completeness a check covers. The exact set varies
/// by component class — see `ComponentClass`.
pub const CheckCategory = enum {
    value,
    footprint,
    mpn,
    manufacturer,
    datasheet,
    requirements_verified,
};

/// Classification of a placed component. Drives which checks apply:
/// passives need value+footprint only, ICs need full BOM + datasheet +
/// verified requirements.
pub const ComponentClass = enum { passive, ic };

/// One pass/fail outcome for a single category on a single instance.
pub const CheckResult = struct {
    category: CheckCategory,
    ok: bool,
};

/// Coverage view of one Instance. `complete` is true iff every check in
/// `checks` passed. Length and contents of `checks` depend on `class`.
pub const InstanceCoverage = struct {
    ref_des: []const u8,
    component: []const u8,
    class: ComponentClass,
    checks: []const CheckResult,
    complete: bool,
};

/// Per-category running tallies. Mirrors the `CheckCategory` enum.
pub const CategoryCounts = struct {
    value: usize = 0,
    footprint: usize = 0,
    mpn: usize = 0,
    manufacturer: usize = 0,
    datasheet: usize = 0,
    requirements_verified: usize = 0,
};

/// Roll-up of `InstanceCoverage` over the instances inside one section.
/// `filled[cat]` is the number of *passing* items for that category;
/// `expected[cat]` is the number of items the category was *asked about*
/// (passives don't contribute to `expected.mpn`, ICs without library
/// requirements don't contribute to `expected.requirements_verified`,
/// etc.). The HTML renderer prints "MPN N/M" by reading both fields.
pub const SectionCoverage = struct {
    checked: usize = 0,
    complete: usize = 0,
    filled: CategoryCounts = .{},
    expected: CategoryCounts = .{},
    instances: []const InstanceCoverage = &.{},
};

/// Whole-design roll-up used by the summary banner. `percent` is
/// rounded down to an integer 0-100; an empty design (zero checkable
/// instances) reports 100 so the banner doesn't show a misleading 0%.
pub const OverallCoverage = struct {
    checked: usize = 0,
    complete: usize = 0,
    missing_total: usize = 0,
    percent: u8 = 100,
};

/// Compute coverage for a single placed component. Returns `null` when
/// the instance is excluded entirely (test point, or a part whose
/// library declared `(ignore-requirements)`). The returned `checks`
/// slice is owned by `allocator` and lives until the caller frees it
/// (typical use is an arena that the whole review pipeline shares).
pub fn computeInstanceCoverage(
    allocator: std.mem.Allocator,
    inst: Instance,
    req_results: []const req_checks.Result,
) std.mem.Allocator.Error!?InstanceCoverage {
    if (env_mod.isTestPoint(inst.component)) return null;
    if (inst.requirements_ignored) return null;
    if (inst.ref_des.len == 0) return null;
    const class = classifyByRefDes(inst.ref_des);

    var checks: std.ArrayListUnmanaged(CheckResult) = .empty;
    try checks.append(allocator, .{ .category = .value, .ok = inst.value.len > 0 });
    try checks.append(allocator, .{ .category = .footprint, .ok = inst.footprint.len > 0 });

    if (class == .ic) {
        try checks.append(allocator, .{ .category = .mpn, .ok = hasProperty(inst, "mpn") });
        try checks.append(allocator, .{ .category = .manufacturer, .ok = hasProperty(inst, "manufacturer") });
        try checks.append(allocator, .{ .category = .datasheet, .ok = inst.datasheets.len > 0 });
        // Only ask about requirements_verified when the library actually
        // declared rules to verify — ICs without any `(requirement …)`
        // forms are already surfaced separately via `critical_missing_requirements`.
        if (inst.requirements.len > 0) {
            try checks.append(allocator, .{
                .category = .requirements_verified,
                .ok = allRequirementsVerified(req_results, inst.requirements.len),
            });
        }
    }

    var complete = true;
    for (checks.items) |c| {
        if (!c.ok) {
            complete = false;
            break;
        }
    }

    return .{
        .ref_des = inst.ref_des,
        .component = inst.component,
        .class = class,
        .checks = checks.items,
        .complete = complete,
    };
}

/// Aggregate coverage for every instance declared inside `sec` (and
/// any nested sub-sections), de-duped by ref_des. `block` is supplied
/// for symmetry with the other walkers but only its instances appear
/// here when a section's `pin_groups` reference top-level placements;
/// the current implementation walks only `sec.instances`, matching
/// review.zig's section-instance counting.
pub fn computeSectionCoverage(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    sec: Section,
    check_results: ?*const std.StringHashMapUnmanaged([]req_checks.Result),
) std.mem.Allocator.Error!SectionCoverage {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    var instances: std.ArrayListUnmanaged(InstanceCoverage) = .empty;
    try walkSection(allocator, sec, check_results, &seen, &instances);
    // Also pick up top-level instances attached via `(pins ref "Uxx" ...)` —
    // STM32-style multipart parts live on `block.instances` and reference
    // multiple sections through pin_groups. Matching how `reportFromSection`
    // scopes ERC violations.
    try walkSectionPinGroups(allocator, block, sec, check_results, &seen, &instances);
    return rollUpInstances(instances.items);
}

fn walkSectionPinGroups(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    sec: Section,
    check_results: ?*const std.StringHashMapUnmanaged([]req_checks.Result),
    seen: *std.StringHashMapUnmanaged(void),
    out: *std.ArrayListUnmanaged(InstanceCoverage),
) std.mem.Allocator.Error!void {
    for (sec.pin_groups) |pg| {
        if (pg.ref_des.len == 0) continue;
        if (seen.contains(pg.ref_des)) continue;
        const inst = findInstance(block, pg.ref_des) orelse continue;
        try seen.put(allocator, pg.ref_des, {});
        const results: []const req_checks.Result = if (check_results) |m|
            (m.get(inst.ref_des) orelse &.{})
        else
            &.{};
        const cov = (try computeInstanceCoverage(allocator, inst, results)) orelse continue;
        try out.append(allocator, cov);
    }
    for (sec.sub_sections) |sub| try walkSectionPinGroups(allocator, block, sub, check_results, seen, out);
}

fn findInstance(block: *const DesignBlock, ref_des: []const u8) ?Instance {
    for (block.instances) |inst| {
        if (std.mem.eql(u8, inst.ref_des, ref_des)) return inst;
    }
    return null;
}

fn walkSection(
    allocator: std.mem.Allocator,
    sec: Section,
    check_results: ?*const std.StringHashMapUnmanaged([]req_checks.Result),
    seen: *std.StringHashMapUnmanaged(void),
    out: *std.ArrayListUnmanaged(InstanceCoverage),
) std.mem.Allocator.Error!void {
    for (sec.instances) |inst| {
        if (inst.ref_des.len == 0) continue;
        if (seen.contains(inst.ref_des)) continue;
        try seen.put(allocator, inst.ref_des, {});
        const results: []const req_checks.Result = if (check_results) |m|
            (m.get(inst.ref_des) orelse &.{})
        else
            &.{};
        const cov = (try computeInstanceCoverage(allocator, inst, results)) orelse continue;
        try out.append(allocator, cov);
    }
    for (sec.sub_sections) |sub| try walkSection(allocator, sub, check_results, seen, out);
}

/// Aggregate coverage for the whole design — every top-level instance
/// plus every sub-block instance recursively. Returns an
/// `OverallCoverage` with a percentage suitable for the summary banner.
pub fn computeOverallCoverage(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    check_results: ?*const std.StringHashMapUnmanaged([]req_checks.Result),
) std.mem.Allocator.Error!OverallCoverage {
    var checked: usize = 0;
    var complete: usize = 0;
    try walkAll(allocator, block, check_results, &checked, &complete);
    const missing = checked - complete;
    const percent: u8 = if (checked == 0) 100 else @intCast(@divTrunc(complete * 100, checked));
    return .{
        .checked = checked,
        .complete = complete,
        .missing_total = missing,
        .percent = percent,
    };
}

fn walkAll(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    check_results: ?*const std.StringHashMapUnmanaged([]req_checks.Result),
    checked: *usize,
    complete: *usize,
) std.mem.Allocator.Error!void {
    for (block.instances) |inst| {
        const results: []const req_checks.Result = if (check_results) |m|
            (m.get(inst.ref_des) orelse &.{})
        else
            &.{};
        const cov = (try computeInstanceCoverage(allocator, inst, results)) orelse continue;
        checked.* += 1;
        if (cov.complete) complete.* += 1;
    }
    for (block.sub_blocks) |sb| try walkAll(allocator, sb.block, check_results, checked, complete);
}

fn rollUpInstances(instances: []const InstanceCoverage) SectionCoverage {
    var sc: SectionCoverage = .{ .instances = instances };
    for (instances) |ic| {
        sc.checked += 1;
        if (ic.complete) sc.complete += 1;
        for (ic.checks) |c| {
            switch (c.category) {
                .value => {
                    sc.expected.value += 1;
                    if (c.ok) sc.filled.value += 1;
                },
                .footprint => {
                    sc.expected.footprint += 1;
                    if (c.ok) sc.filled.footprint += 1;
                },
                .mpn => {
                    sc.expected.mpn += 1;
                    if (c.ok) sc.filled.mpn += 1;
                },
                .manufacturer => {
                    sc.expected.manufacturer += 1;
                    if (c.ok) sc.filled.manufacturer += 1;
                },
                .datasheet => {
                    sc.expected.datasheet += 1;
                    if (c.ok) sc.filled.datasheet += 1;
                },
                .requirements_verified => {
                    sc.expected.requirements_verified += 1;
                    if (c.ok) sc.filled.requirements_verified += 1;
                },
            }
        }
    }
    return sc;
}

/// Same classification as `review.zig`'s `isCriticalRefDes` (passives
/// R/C/L/F/D versus everything else). Duplicated here so coverage.zig
/// stays independent of review.zig's internals.
fn classifyByRefDes(ref_des: []const u8) ComponentClass {
    return switch (ref_des[0]) {
        'R', 'C', 'L', 'F', 'D' => .passive,
        else => .ic,
    };
}

fn hasProperty(inst: Instance, key: []const u8) bool {
    for (inst.properties) |p| {
        if (std.mem.eql(u8, p.key, key) and p.value.len > 0) return true;
    }
    return false;
}

fn allRequirementsVerified(results: []const req_checks.Result, expected_n: usize) bool {
    if (results.len < expected_n) return false;
    for (results[0..expected_n]) |r| {
        switch (r.status) {
            .pass, .verified => {},
            .fail, .na => return false,
        }
    }
    return true;
}

/// Test helper — find a check by category in an InstanceCoverage's
/// `checks` slice. Returns `null` when the category wasn't asked about
/// (e.g., MPN on a passive). Keeps test bodies linear so they don't
/// hit guardian's "if at top level of test body" rule.
fn findCheck(cov: InstanceCoverage, category: CheckCategory) ?CheckResult {
    for (cov.checks) |c| {
        if (c.category == category) return c;
    }
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: coverage - computeInstanceCoverage classifies passives by ref-des prefix and requires only value+footprint
test "computeInstanceCoverage passive only counts value+footprint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const inst = Instance{
        .ref_des = "C1",
        .component = "cap-0402",
        .value = "100nF",
        .footprint = "0402",
        .symbol = "",
    };
    const cov = (try computeInstanceCoverage(alloc, inst, &.{})) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ComponentClass.passive, cov.class);
    try std.testing.expectEqual(@as(usize, 2), cov.checks.len);
    try std.testing.expect(cov.complete);

    // Missing value → not complete.
    const inst2 = Instance{
        .ref_des = "R5",
        .component = "res-0402",
        .value = "",
        .footprint = "0402",
        .symbol = "",
    };
    const cov2 = (try computeInstanceCoverage(alloc, inst2, &.{})) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!cov2.complete);
}

// spec: coverage - computeInstanceCoverage requires MPN, manufacturer, datasheet, and verified requirements for ICs
test "computeInstanceCoverage IC needs MPN/manufacturer/datasheet/requirements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const props_full = [_]env_mod.Property{
        .{ .key = "mpn", .value = "STM32N657L0H3Q" },
        .{ .key = "manufacturer", .value = "ST" },
    };
    const datasheets = [_][]const u8{"stm32n657.pdf"};
    const reqs = [_]env_mod.Requirement{.{ .text = "VDD must be 3V3", .id = "abc12345" }};
    const results_pass = [_]req_checks.Result{.{ .status = .pass, .message = "" }};

    const u1_inst = Instance{
        .ref_des = "U1",
        .component = "stm32n657",
        .value = "STM32N657L0H3Q",
        .footprint = "tfbga-225",
        .symbol = "",
        .properties = &props_full,
        .datasheets = &datasheets,
        .requirements = &reqs,
    };
    const cov_full = (try computeInstanceCoverage(alloc, u1_inst, &results_pass)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(ComponentClass.ic, cov_full.class);
    try std.testing.expectEqual(@as(usize, 6), cov_full.checks.len);
    try std.testing.expect(cov_full.complete);

    // Drop the MPN — IC becomes incomplete and the mpn check is false.
    const props_no_mpn = [_]env_mod.Property{.{ .key = "manufacturer", .value = "ST" }};
    const u1_no_mpn = Instance{
        .ref_des = "U1",
        .component = "stm32n657",
        .value = "STM32N657L0H3Q",
        .footprint = "tfbga-225",
        .symbol = "",
        .properties = &props_no_mpn,
        .datasheets = &datasheets,
        .requirements = &reqs,
    };
    const cov_no_mpn = (try computeInstanceCoverage(alloc, u1_no_mpn, &results_pass)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!cov_no_mpn.complete);
    const mpn_check = findCheck(cov_no_mpn, .mpn) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!mpn_check.ok);

    // Drop the datasheet — IC becomes incomplete.
    const u1_no_ds = Instance{
        .ref_des = "U1",
        .component = "stm32n657",
        .value = "STM32N657L0H3Q",
        .footprint = "tfbga-225",
        .symbol = "",
        .properties = &props_full,
        .datasheets = &.{},
        .requirements = &reqs,
    };
    const cov_no_ds = (try computeInstanceCoverage(alloc, u1_no_ds, &results_pass)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!cov_no_ds.complete);

    // Drop verification — req status `na` flips the requirements_verified check off.
    const results_na = [_]req_checks.Result{.{ .status = .na, .message = "" }};
    const cov_na = (try computeInstanceCoverage(alloc, u1_inst, &results_na)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!cov_na.complete);
    const req_check = findCheck(cov_na, .requirements_verified) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!req_check.ok);
}

// spec: coverage - computeInstanceCoverage honours requirements_ignored opt-out
test "computeInstanceCoverage skips requirements_ignored parts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const h1 = Instance{
        .ref_des = "H1",
        .component = "screw-bushing",
        .value = "",
        .footprint = "",
        .symbol = "",
        .requirements_ignored = true,
    };
    const cov = try computeInstanceCoverage(alloc, h1, &.{});
    try std.testing.expect(cov == null);

    // Test points are also excluded.
    const tp = Instance{
        .ref_des = "TP1",
        .component = "testpoint",
        .value = "",
        .footprint = "",
        .symbol = "",
    };
    const cov_tp = try computeInstanceCoverage(alloc, tp, &.{});
    try std.testing.expect(cov_tp == null);
}

// spec: coverage - computeSectionCoverage rolls instance results into checked/complete counts per category
test "computeSectionCoverage rolls up per-category totals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const reqs = [_]env_mod.Requirement{.{ .text = "x", .id = "id1" }};
    const props = [_]env_mod.Property{
        .{ .key = "mpn", .value = "STM32" },
        .{ .key = "manufacturer", .value = "ST" },
    };
    // U1: missing datasheet → IC, 5/6 checks pass, complete=false.
    const u1_inst = Instance{
        .ref_des = "U1",
        .component = "stm",
        .value = "v",
        .footprint = "fp",
        .symbol = "",
        .properties = &props,
        .requirements = &reqs,
    };
    // C1: passive, value + footprint set → complete.
    const c1_inst = Instance{
        .ref_des = "C1",
        .component = "cap",
        .value = "100nF",
        .footprint = "0402",
        .symbol = "",
    };
    const insts = [_]Instance{ u1_inst, c1_inst };
    const sec: Section = .{
        .name = "test",
        .instances = &insts,
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
    var map: std.StringHashMapUnmanaged([]req_checks.Result) = .empty;
    var u1_results = [_]req_checks.Result{.{ .status = .pass, .message = "" }};
    try map.put(alloc, "U1", &u1_results);

    const sc = try computeSectionCoverage(alloc, &block, sec, &map);
    try std.testing.expectEqual(@as(usize, 2), sc.checked);
    try std.testing.expectEqual(@as(usize, 1), sc.complete);
    try std.testing.expectEqual(@as(usize, 2), sc.filled.value);
    try std.testing.expectEqual(@as(usize, 2), sc.expected.value);
    try std.testing.expectEqual(@as(usize, 2), sc.filled.footprint);
    try std.testing.expectEqual(@as(usize, 1), sc.expected.mpn);
    try std.testing.expectEqual(@as(usize, 1), sc.filled.mpn);
    try std.testing.expectEqual(@as(usize, 1), sc.expected.datasheet);
    try std.testing.expectEqual(@as(usize, 0), sc.filled.datasheet);
    try std.testing.expectEqual(@as(usize, 1), sc.expected.requirements_verified);
    try std.testing.expectEqual(@as(usize, 1), sc.filled.requirements_verified);
}

// spec: coverage - computeOverallCoverage aggregates every section plus orphan sub-block instances
test "computeOverallCoverage walks sub-blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const props_full = [_]env_mod.Property{
        .{ .key = "mpn", .value = "STM32" },
        .{ .key = "manufacturer", .value = "ST" },
    };
    const props_no_mfr = [_]env_mod.Property{.{ .key = "mpn", .value = "BUCK1" }};
    const datasheets = [_][]const u8{"x.pdf"};
    // Top: U1 is complete (no requirements declared, so requirements_verified is skipped).
    const u1_inst = Instance{
        .ref_des = "U1",
        .component = "stm",
        .value = "v",
        .footprint = "fp",
        .symbol = "",
        .properties = &props_full,
        .datasheets = &datasheets,
    };
    // Sub-block: U2 is missing manufacturer.
    const u2_inst = Instance{
        .ref_des = "U2",
        .component = "buck",
        .value = "v",
        .footprint = "fp",
        .symbol = "",
        .properties = &props_no_mfr,
        .datasheets = &datasheets,
    };
    const top_insts = [_]Instance{u1_inst};
    const sub_insts = [_]Instance{u2_inst};
    var sub_block: DesignBlock = .{
        .name = "buck",
        .instances = &sub_insts,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const subs = [_]env_mod.SubBlock{.{ .name = "buck", .block = &sub_block }};
    const block: DesignBlock = .{
        .name = "top",
        .instances = &top_insts,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &subs,
    };
    const oc = try computeOverallCoverage(alloc, &block, null);
    try std.testing.expectEqual(@as(usize, 2), oc.checked);
    try std.testing.expectEqual(@as(usize, 1), oc.complete);
    try std.testing.expectEqual(@as(usize, 1), oc.missing_total);
    try std.testing.expectEqual(@as(u8, 50), oc.percent);
}

// spec: coverage - computeOverallCoverage returns 100% when the design has zero checkable instances
test "computeOverallCoverage empty design reports 100 percent" {
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
    const oc = try computeOverallCoverage(alloc, &block, null);
    try std.testing.expectEqual(@as(usize, 0), oc.checked);
    try std.testing.expectEqual(@as(u8, 100), oc.percent);
}
