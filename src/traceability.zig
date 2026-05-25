//! Design-document traceability. Answers the "where is each critical IC in
//! its lifecycle?" question by joining the up-front `(design-doc …)`
//! declaration (see `env.CriticalIc`) against three live sources:
//!
//!   - the **library** (`lib/components/<name>.sexp` + `lib/footprints/` +
//!     `lib/datasheets/`) — has the part been imported, given a footprint and
//!     datasheet, and given `(requirement …)` rules?
//!   - the **schematic** — is there an `(instance …)` that uses the component,
//!     anywhere in the design or its sub-blocks?
//!   - the **requirement checks** (`req_checks.Result`) — do that placed
//!     instance's requirements all pass / are they signed off?
//!
//! Each declared IC resolves to a `TraceRow` with four lifecycle booleans
//! (see `TraceStage`). A part that has been chosen but not yet placed shows
//! the early stages and a red "Placed + verified" — the forward-progress view
//! the reactive coverage engine (`coverage.zig`) can't give because it only
//! sees parts after they're placed.
//!
//! For a **placed** IC the stage signals are read straight off the resolved
//! `Instance` (the same fields `coverage.computeInstanceCoverage` consumes);
//! for an **unplaced** IC the component file is parsed directly and the
//! footprint / datasheet files are existence-checked on disk.

const std = @import("std");
const env_mod = @import("eval/env.zig");
const req_checks = @import("req_checks.zig");
const infra_fs = @import("infra/fs.zig");
const sexpr_parser = @import("sexpr/parser.zig");
const DesignBlock = env_mod.DesignBlock;
const Instance = env_mod.Instance;
const CriticalIc = env_mod.CriticalIc;

const MAX_COMPONENT_BYTES: usize = 1 * 1024 * 1024;

/// The four lifecycle stages tracked per declared critical IC. The index of
/// each variant lines up with `TraceRow.stages`.
pub const TraceStage = enum(usize) {
    footprint = 0,
    datasheet = 1,
    requirements = 2,
    placed_verified = 3,
};

/// One declared critical IC joined against the library + schematic + checks.
/// `stages` is indexed by `TraceStage`; `complete` is true iff every stage is.
pub const TraceRow = struct {
    component: []const u8,
    role: []const u8 = "",
    rationale: []const u8 = "",
    mpn: []const u8 = "",
    /// True when an `(instance …)` using this component exists in the design.
    placed: bool = false,
    /// [footprint, datasheet, requirements, placed_verified].
    stages: [4]bool = .{ false, false, false, false },
    complete: bool = false,
};

/// Whole-design traceability roll-up. `declared` is the count of
/// `(critical-ic …)` entries; `complete` is how many have every stage green.
pub const Traceability = struct {
    rows: []const TraceRow = &.{},
    declared: usize = 0,
    complete: usize = 0,
};

/// Build the traceability view for `block`. `project_dir` is the project root
/// (the dir holding `src/` and `lib/`); `check_results` is the per-ref-des
/// requirement-check map from `req_checks.runChecks` (null = checks not run,
/// treated as unverified). Allocations are owned by `allocator`.
pub fn build(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    check_results: ?*const std.StringHashMapUnmanaged([]req_checks.Result),
) std.mem.Allocator.Error!Traceability {
    var rows: std.ArrayListUnmanaged(TraceRow) = .empty;
    var complete: usize = 0;
    for (block.critical_ics) |cic| {
        const row = try buildRow(allocator, block, project_dir, cic, check_results);
        if (row.complete) complete += 1;
        try rows.append(allocator, row);
    }
    // Order most-complete first so the panel reads top-down from done to
    // not-started. Stable, so equally-complete ICs keep declaration order.
    std.mem.sort(TraceRow, rows.items, {}, moreComplete);
    return .{
        .rows = rows.items,
        .declared = rows.items.len,
        .complete = complete,
    };
}

/// Count of green lifecycle stages (0–4) — the row's completion score.
fn greenStages(row: TraceRow) usize {
    var n: usize = 0;
    for (row.stages) |s| {
        if (s) n += 1;
    }
    return n;
}

/// Stable sort predicate: rows with more green stages come first.
fn moreComplete(_: void, a: TraceRow, b: TraceRow) bool {
    return greenStages(a) > greenStages(b);
}

fn buildRow(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    cic: CriticalIc,
    check_results: ?*const std.StringHashMapUnmanaged([]req_checks.Result),
) std.mem.Allocator.Error!TraceRow {
    var row = TraceRow{
        .component = cic.component,
        .role = cic.role,
        .rationale = cic.rationale,
        .mpn = cic.mpn,
    };

    if (findPlacedInstance(block, cic.component)) |inst| {
        // Placed: read the same signals coverage.zig reads off the resolved
        // instance, plus the requirement-check verdict for "verified".
        row.placed = true;
        row.stages[@intFromEnum(TraceStage.footprint)] = inst.footprint.len > 0;
        row.stages[@intFromEnum(TraceStage.datasheet)] = inst.datasheets.len > 0;
        row.stages[@intFromEnum(TraceStage.requirements)] = inst.requirements.len > 0;
        const results: []const req_checks.Result = if (check_results) |m|
            (m.get(inst.ref_des) orelse &.{})
        else
            &.{};
        row.stages[@intFromEnum(TraceStage.placed_verified)] =
            requirementsSatisfied(results, inst.requirements.len);
    } else {
        // Unplaced: derive footprint / datasheet / requirements from the
        // library files. "Placed + verified" stays false by definition.
        const lib = try resolveLibraryStages(allocator, project_dir, cic);
        row.stages[@intFromEnum(TraceStage.footprint)] = lib.footprint;
        row.stages[@intFromEnum(TraceStage.datasheet)] = lib.datasheet;
        row.stages[@intFromEnum(TraceStage.requirements)] = lib.requirements;
    }

    row.complete = row.stages[0] and row.stages[1] and row.stages[2] and row.stages[3];
    return row;
}

/// Recursively find the first instance whose `component` matches `name`,
/// descending into sub-blocks. Returns null when the part isn't placed.
fn findPlacedInstance(block: *const DesignBlock, name: []const u8) ?Instance {
    for (block.instances) |inst| {
        if (std.mem.eql(u8, inst.component, name)) return inst;
    }
    for (block.sub_blocks) |sb| {
        if (findPlacedInstance(sb.block, name)) |found| return found;
    }
    return null;
}

/// Are all `expected_n` requirement results pass/verified? Vacuously true when
/// the part declares no requirements (nothing to verify). Mirrors
/// `coverage.allRequirementsVerified`, but treats zero requirements as "ok"
/// so a placed part with nothing to check still earns the verified stage.
fn requirementsSatisfied(results: []const req_checks.Result, expected_n: usize) bool {
    if (expected_n == 0) return true;
    if (results.len < expected_n) return false;
    for (results[0..expected_n]) |r| {
        switch (r.status) {
            .pass, .verified => {},
            .fail, .na => return false,
        }
    }
    return true;
}

const LibraryStages = struct {
    footprint: bool = false,
    datasheet: bool = false,
    requirements: bool = false,
};

/// Parse `lib/components/<name>.sexp` and resolve the footprint / datasheet /
/// requirements stages for an unplaced IC. A missing or unparseable component
/// file leaves every stage false.
fn resolveLibraryStages(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    cic: CriticalIc,
) std.mem.Allocator.Error!LibraryStages {
    if (!safeLibName(cic.component)) return .{};

    const comp_path = std.fmt.allocPrint(allocator, "{s}/lib/components/{s}.sexp", .{ project_dir, cic.component }) catch return .{};
    defer allocator.free(comp_path);
    const src = infra_fs.cwd().readFileAlloc(allocator, comp_path, MAX_COMPONENT_BYTES) catch return .{};
    defer allocator.free(src);

    const nodes = sexpr_parser.parse(allocator, src) catch return .{};
    defer sexpr_parser.freeNodes(allocator, nodes);
    if (nodes.len == 0) return .{};
    const root = nodes[0].asList() orelse return .{};
    if (root.len < 2) return .{};

    var footprint_ref: []const u8 = "";
    var declared_datasheet: []const u8 = "";
    var req_count: usize = 0;
    for (root[2..]) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len < 1) continue;
        const tag = cl[0].asAtom() orelse continue;
        if (std.mem.eql(u8, tag, "footprint") and cl.len >= 2) {
            footprint_ref = cl[1].asString() orelse cl[1].asAtom() orelse "";
        } else if (std.mem.eql(u8, tag, "datasheet") and cl.len >= 2) {
            declared_datasheet = cl[1].asString() orelse cl[1].asAtom() orelse "";
        } else if (std.mem.eql(u8, tag, "requirement")) {
            req_count += 1;
        }
    }

    var stages = LibraryStages{ .requirements = req_count > 0 };
    if (footprint_ref.len > 0 and safeLibName(footprint_ref)) {
        const fp_path = std.fmt.allocPrint(allocator, "{s}/lib/footprints/{s}.sexp", .{ project_dir, footprint_ref }) catch return stages;
        defer allocator.free(fp_path);
        stages.footprint = fileExists(fp_path);
    }
    stages.datasheet = try datasheetPresent(allocator, project_dir, declared_datasheet, cic.component, cic.mpn);
    return stages;
}

/// A datasheet counts as imported when the component's declared `(datasheet …)`
/// file exists in `lib/datasheets/`, or — as a fallback — any PDF in that
/// directory has a name containing the component basename or the MPN.
fn datasheetPresent(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    declared: []const u8,
    component: []const u8,
    mpn: []const u8,
) std.mem.Allocator.Error!bool {
    if (declared.len > 0 and !std.mem.containsAtLeast(u8, declared, 1, "/") and !std.mem.containsAtLeast(u8, declared, 1, "..")) {
        const path = std.fmt.allocPrint(allocator, "{s}/lib/datasheets/{s}", .{ project_dir, declared }) catch return false;
        defer allocator.free(path);
        if (fileExists(path)) return true;
    }

    const dir_path = std.fmt.allocPrint(allocator, "{s}/lib/datasheets", .{project_dir}) catch return false;
    defer allocator.free(dir_path);
    var dir = infra_fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return false;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch return false) |entry| {
        if (entry.kind != .file) continue;
        if (containsCI(entry.name, component)) return true;
        if (mpn.len > 0 and containsCI(entry.name, mpn)) return true;
    }
    return false;
}

fn fileExists(path: []const u8) bool {
    infra_fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Reject names that could escape the library directory. Library basenames are
/// `[A-Za-z0-9._-]` in practice; anything with a slash or `..` is refused.
fn safeLibName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.containsAtLeast(u8, name, 1, "/")) return false;
    if (std.mem.containsAtLeast(u8, name, 1, "..")) return false;
    return true;
}

/// Case-insensitive substring test (`needle` non-empty). Used for the
/// best-effort datasheet filename match.
fn containsCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────

fn emptyBlock(name: []const u8, instances: []const Instance, subs: []const env_mod.SubBlock) DesignBlock {
    return .{
        .name = name,
        .instances = instances,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = subs,
    };
}

// spec: traceability - build marks all four stages green for a placed IC with footprint, datasheet, requirements, and passing checks
test "build all stages green for fully-traced placed IC" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ds = [_][]const u8{"u1.pdf"};
    const reqs = [_]env_mod.Requirement{.{ .text = "VDD 3V3", .id = "abc12345" }};
    const u1_inst = Instance{
        .ref_des = "U1",
        .component = "stm32n6",
        .value = "STM32",
        .footprint = "tfbga-225",
        .symbol = "",
        .datasheets = &ds,
        .requirements = &reqs,
    };
    const insts = [_]Instance{u1_inst};
    const cics = [_]CriticalIc{.{ .component = "stm32n6", .role = "Main MCU" }};
    var block = emptyBlock("t", &insts, &.{});
    block.critical_ics = &cics;

    var map: std.StringHashMapUnmanaged([]req_checks.Result) = .empty;
    var results = [_]req_checks.Result{.{ .status = .pass, .message = "" }};
    try map.put(alloc, "U1", &results);

    const trace = try build(alloc, &block, "/nonexistent", &map);
    try std.testing.expectEqual(@as(usize, 1), trace.declared);
    try std.testing.expectEqual(@as(usize, 1), trace.complete);
    const row = trace.rows[0];
    try std.testing.expect(row.placed);
    try std.testing.expect(row.stages[0] and row.stages[1] and row.stages[2] and row.stages[3]);
    try std.testing.expect(row.complete);
}

// spec: traceability - build leaves placed_verified false when a placed IC has an unverified (na) requirement
test "build placed IC with na requirement is not verified" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const reqs = [_]env_mod.Requirement{.{ .text = "x", .id = "id1" }};
    const u1_inst = Instance{
        .ref_des = "U1",
        .component = "part",
        .value = "v",
        .footprint = "fp",
        .symbol = "",
        .datasheets = &[_][]const u8{"d.pdf"},
        .requirements = &reqs,
    };
    const insts = [_]Instance{u1_inst};
    const cics = [_]CriticalIc{.{ .component = "part" }};
    var block = emptyBlock("t", &insts, &.{});
    block.critical_ics = &cics;

    var map: std.StringHashMapUnmanaged([]req_checks.Result) = .empty;
    var results = [_]req_checks.Result{.{ .status = .na, .message = "" }};
    try map.put(alloc, "U1", &results);

    const trace = try build(alloc, &block, "/nonexistent", &map);
    const row = trace.rows[0];
    try std.testing.expect(row.placed);
    try std.testing.expect(!row.stages[@intFromEnum(TraceStage.placed_verified)]);
    try std.testing.expect(!row.complete);
    try std.testing.expectEqual(@as(usize, 0), trace.complete);
}

// spec: traceability - build reports a declared IC with no matching instance as not placed
test "build declared IC with no instance is unplaced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cics = [_]CriticalIc{.{ .component = "not_imported_yet", .role = "RF" }};
    var block = emptyBlock("t", &.{}, &.{});
    block.critical_ics = &cics;

    // Nonexistent project dir → every library read fails → all stages false.
    const trace = try build(alloc, &block, "/nonexistent/path", null);
    try std.testing.expectEqual(@as(usize, 1), trace.declared);
    try std.testing.expectEqual(@as(usize, 0), trace.complete);
    const row = trace.rows[0];
    try std.testing.expect(!row.placed);
    try std.testing.expect(!row.stages[0] and !row.stages[1] and !row.stages[2] and !row.stages[3]);
}

// spec: traceability - build finds an instance placed inside a sub-block
test "build matches an instance inside a sub-block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const u2_inst = Instance{
        .ref_des = "U2",
        .component = "buck_ic",
        .value = "v",
        .footprint = "fp",
        .symbol = "",
        .datasheets = &[_][]const u8{"b.pdf"},
    };
    const sub_insts = [_]Instance{u2_inst};
    var sub_block = emptyBlock("buck", &sub_insts, &.{});
    const subs = [_]env_mod.SubBlock{.{ .name = "buck", .block = &sub_block }};
    const cics = [_]CriticalIc{.{ .component = "buck_ic" }};
    var block = emptyBlock("top", &.{}, &subs);
    block.critical_ics = &cics;

    const trace = try build(alloc, &block, "/nonexistent", null);
    const row = trace.rows[0];
    try std.testing.expect(row.placed);
    try std.testing.expect(row.stages[@intFromEnum(TraceStage.footprint)]);
    // No requirements declared → verified stage is vacuously true once placed.
    try std.testing.expect(row.stages[@intFromEnum(TraceStage.placed_verified)]);
    // But requirements stage is false (none declared), so not complete.
    try std.testing.expect(!row.stages[@intFromEnum(TraceStage.requirements)]);
    try std.testing.expect(!row.complete);
}

// spec: traceability - build orders rows most-complete first
test "build sorts rows by completion descending" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A fully-traced placed IC and an unplaced IC, declared least-complete
    // first; build must reorder the complete one to the front.
    const reqs = [_]env_mod.Requirement{.{ .text = "x", .id = "id1" }};
    const done_inst = Instance{
        .ref_des = "U1",
        .component = "done_ic",
        .value = "v",
        .footprint = "fp",
        .symbol = "",
        .datasheets = &[_][]const u8{"d.pdf"},
        .requirements = &reqs,
    };
    const insts = [_]Instance{done_inst};
    const cics = [_]CriticalIc{
        .{ .component = "not_imported_yet" }, // unplaced → 0 green stages
        .{ .component = "done_ic" }, // placed + verified → 4 green stages
    };
    var block = emptyBlock("t", &insts, &.{});
    block.critical_ics = &cics;

    var map: std.StringHashMapUnmanaged([]req_checks.Result) = .empty;
    var results = [_]req_checks.Result{.{ .status = .pass, .message = "" }};
    try map.put(alloc, "U1", &results);

    const trace = try build(alloc, &block, "/nonexistent", &map);
    try std.testing.expectEqualStrings("done_ic", trace.rows[0].component);
    try std.testing.expectEqualStrings("not_imported_yet", trace.rows[1].component);
}
