//! Direct-instantiation policy for reusable component modules. Imports remain
//! unrestricted; the check runs where semantic intent is clear: an evaluated
//! instance in a board or non-implementing module.

const std = @import("std");
const checks = @import("checks.zig");
const env = @import("eval/env.zig");
const module_metadata = @import("module_metadata.zig");

/// One canonical/recommended implementation-policy finding.
pub const Finding = struct {
    severity: checks.Severity,
    message: []const u8,
    ref_des: []const u8,
};

/// Load module metadata and check a complete design tree. The implementing
/// module's body is exempt. `(module-bypass "reason")` on an instance is the
/// rationale-bearing escape hatch for intentionally custom topology.
pub fn run(
    allocator: std.mem.Allocator,
    block: *const env.DesignBlock,
    project_dir: []const u8,
) std.mem.Allocator.Error![]Finding {
    const matches = try module_metadata.collect(allocator, project_dir);
    defer module_metadata.freeMatches(allocator, matches);
    if (matches.len == 0) return &.{};
    var findings: std.ArrayList(Finding) = .empty;
    errdefer {
        for (findings.items) |finding| allocator.free(finding.message);
        findings.deinit(allocator);
    }
    try checkBlock(allocator, block, matches, "", true, &findings);
    return findings.toOwnedSlice(allocator);
}

fn checkBlock(
    allocator: std.mem.Allocator,
    block: *const env.DesignBlock,
    matches: []const module_metadata.Match,
    source: []const u8,
    root: bool,
    findings: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void {
    // A standalone module preview has no enclosing SubBlock.source. The
    // evaluator stamps the actual defmodule name separately from the display
    // block title; only that source provenance can grant self-exemption.
    const implementation_source = if (root and block.origin == .embedded) block.module_name else source;
    for (block.instances) |inst| {
        if (inst.component.len == 0) continue;
        if (sourceImplementsComponent(implementation_source, inst.component, matches)) continue;
        const implementation = bestImplementation(inst.component, matches) orelse continue;
        if (instanceModuleBypass(inst)) continue;
        try appendFinding(allocator, findings, inst, implementation);
    }
    for (block.sub_blocks) |sub_block| {
        try checkBlock(allocator, sub_block.block, matches, sub_block.source, false, findings);
    }
}

fn appendFinding(
    allocator: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    inst: env.Instance,
    implementation: module_metadata.Match,
) std.mem.Allocator.Error!void {
    const message = try messageFor(allocator, inst, implementation);
    errdefer allocator.free(message);
    try findings.append(allocator, .{
        .severity = if (implementation.policy == .canonical) .@"error" else .warning,
        .message = message,
        .ref_des = inst.ref_des,
    });
}

fn bestImplementation(component: []const u8, matches: []const module_metadata.Match) ?module_metadata.Match {
    var best: ?module_metadata.Match = null;
    for (matches) |match| {
        if (!std.mem.eql(u8, match.component, component)) continue;
        if (match.policy == .example) continue;
        if (best == null or match.policy.strength() > best.?.policy.strength()) best = match;
    }
    return best;
}

fn messageFor(
    allocator: std.mem.Allocator,
    inst: env.Instance,
    implementation: module_metadata.Match,
) std.mem.Allocator.Error![]const u8 {
    const action = if (implementation.policy == .canonical) "must" else "should";
    return std.fmt.allocPrint(
        allocator,
        "Component \"{s}\" directly instantiates {s}, which has {s} module \"{s}\" — {s} use " ++
            "(sub-block … ({s} …)); for custom topology add (module-bypass \"reason\") to this instance",
        .{
            inst.ref_des,
            inst.component,
            @tagName(implementation.policy),
            implementation.module,
            action,
            implementation.module,
        },
    );
}

fn instanceModuleBypass(inst: env.Instance) bool {
    for (inst.properties) |property| {
        if (!std.mem.eql(u8, property.key, "module-bypass")) continue;
        return std.mem.trim(u8, property.value, " \t\r\n").len > 0;
    }
    return false;
}

fn sourceImplementsComponent(
    source: []const u8,
    component: []const u8,
    matches: []const module_metadata.Match,
) bool {
    const module_name = moduleNameFromSource(source) orelse return false;
    for (matches) |match| {
        const same_module = std.mem.eql(u8, match.module, module_name);
        const same_component = std.mem.eql(u8, match.component, component);
        if (same_module and same_component) return true;
    }
    return false;
}

fn moduleNameFromSource(source: []const u8) ?[]const u8 {
    if (source.len == 0) return null;
    if (std.mem.indexOfScalar(u8, source, '/')) |_| {
        if (!std.mem.startsWith(u8, source, "lib/modules/")) return null;
    }
    const base = std.fs.path.basename(source);
    return if (std.mem.endsWith(u8, base, ".sexp")) base[0 .. base.len - ".sexp".len] else base;
}

fn freeFindingSlice(allocator: std.mem.Allocator, findings: []const Finding) void {
    for (findings) |finding| allocator.free(finding.message);
    if (findings.len > 0) allocator.free(findings);
}

test "canonical direct instance errors and rationale bypass suppresses it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/modules");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/modules/buck.sexp",
        .data = "(defmodule buck () (implements chip (policy canonical)) (design-block \"buck\"))",
    });
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(project);
    const direct = [_]env.Instance{.{
        .ref_des = "PS1",
        .component = "chip",
        .value = "",
        .footprint = "",
        .symbol = "",
    }};
    var block: env.DesignBlock = .{
        .name = "board",
        .instances = &direct,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const findings = try run(alloc, &block, project);
    defer freeFindingSlice(alloc, findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqual(checks.Severity.@"error", findings[0].severity);

    const props = [_]env.Property{.{ .key = "module-bypass", .value = "shared feedback network" }};
    var bypassed = direct;
    bypassed[0].properties = &props;
    block.instances = &bypassed;
    const bypass_findings = try run(alloc, &block, project);
    defer freeFindingSlice(alloc, bypass_findings);
    try std.testing.expectEqual(@as(usize, 0), bypass_findings.len);
}

test "implementing module body is exempt" {
    const implementation = module_metadata.Match{
        .module = "buck",
        .component = "chip",
        .policy = .canonical,
        .role = "regulator",
        .doc = "",
        .source_sha256 = @splat('0'),
    };
    const instances = [_]env.Instance{.{
        .ref_des = "U1",
        .component = "chip",
        .value = "",
        .footprint = "",
        .symbol = "",
    }};
    var child: env.DesignBlock = .{
        .name = "3V3 Supply",
        .instances = &instances,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .origin = .embedded,
        .module_name = "buck",
    };
    const subs = [_]env.SubBlock{.{ .name = "supply", .block = &child, .source = "buck" }};
    const board: env.DesignBlock = .{
        .name = "board",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &subs,
    };
    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(std.testing.allocator);
    try checkBlock(std.testing.allocator, &board, &.{implementation}, "", true, &findings);
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);

    // The formatted title does not participate in policy. True source
    // provenance self-exempts buck, while a wrapper with the same title fails.
    try checkBlock(std.testing.allocator, &child, &.{implementation}, "", true, &findings);
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
    child.module_name = "unrelated-wrapper";
    try checkBlock(std.testing.allocator, &child, &.{implementation}, "", true, &findings);
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    std.testing.allocator.free(findings.items[0].message);
}

test "recommended warns while example remains discovery only" {
    const direct = [_]env.Instance{.{
        .ref_des = "U1",
        .component = "chip",
        .value = "",
        .footprint = "",
        .symbol = "",
    }};
    const block: env.DesignBlock = .{
        .name = "board",
        .instances = &direct,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var implementation = module_metadata.Match{
        .module = "helper",
        .component = "chip",
        .policy = .recommended,
        .role = "",
        .doc = "",
        .source_sha256 = @splat('0'),
    };
    var findings: std.ArrayList(Finding) = .empty;
    defer findings.deinit(std.testing.allocator);
    try checkBlock(std.testing.allocator, &block, &.{implementation}, "", true, &findings);
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqual(checks.Severity.warning, findings.items[0].severity);
    std.testing.allocator.free(findings.items[0].message);
    findings.clearRetainingCapacity();

    implementation.policy = .example;
    try checkBlock(std.testing.allocator, &block, &.{implementation}, "", true, &findings);
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}
