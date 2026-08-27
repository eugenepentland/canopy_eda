//! Strict schematic/BOM half of the fabrication release gate.
//!
//! PCB geometry alone cannot prove a board is safe to order.  This module
//! appends the same ERC, assertions and strict preflight used by `netlisp
//! check --profile preflight`, then proves that an attribute-constrained parts
//! request resolved to that exact library row.  It operates on an already
//! evaluated block whose persisted BOM properties have been applied read-only.

const std = @import("std");
const erc = @import("erc.zig");
const env = @import("eval/env.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;
const fab = @import("fab_readiness.zig");
const parts = @import("parts.zig");
const preflight = @import("preflight.zig");
const req_checks = @import("req_checks.zig");

fn propertyValue(properties: []const env.Property, key: []const u8) ?[]const u8 {
    for (properties) |property| if (std.ascii.eqlIgnoreCase(property.key, key)) return property.value;
    return null;
}

fn appendItem(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(fab.Item),
    id: []const u8,
    message: []const u8,
    ref: []const u8,
    net: []const u8,
) std.mem.Allocator.Error!void {
    try list.append(allocator, .{
        .id = id,
        .message = try allocator.dupe(u8, message),
        .ref = if (ref.len > 0) ref else null,
        .net = if (net.len > 0) net else null,
    });
}

/// Append strict schematic and BOM findings to `base`.  All returned storage
/// belongs to `allocator`; `preflight`'s temporary owned messages are copied
/// before its report is released.
pub fn append(
    allocator: std.mem.Allocator,
    base: fab.Report,
    evaluator: *Evaluator,
    block: *const env.DesignBlock,
    project_dir: []const u8,
    keep_dnp: bool,
) std.mem.Allocator.Error!fab.Report {
    var errors: std.ArrayList(fab.Item) = .empty;
    var warnings: std.ArrayList(fab.Item) = .empty;
    try errors.appendSlice(allocator, base.errors);
    try warnings.appendSlice(allocator, base.warnings);

    if (!block.revision.present or block.revision.id.len == 0) {
        try appendItem(allocator, &errors, "revision-missing", "design has no declared manufacturing (revision ...) identifier", "", "");
    }

    for (evaluator.warnings.items) |warning| {
        try appendItem(allocator, &warnings, "eval-warning", warning.message, "", "");
    }
    for (evaluator.assertions.items) |assertion| {
        if (assertion.passed) continue;
        if (assertion.is_warning)
            try appendItem(allocator, &warnings, "assertion", assertion.message, "", "")
        else
            try appendItem(allocator, &errors, "assertion", assertion.message, "", "");
    }

    const erc_findings = try erc.runErc(allocator, block, project_dir);
    for (erc_findings) |finding| switch (finding.severity) {
        .@"error" => try appendItem(allocator, &errors, @tagName(finding.kind), finding.message, finding.ref_des, finding.net),
        .warning => try appendItem(allocator, &warnings, @tagName(finding.kind), finding.message, finding.ref_des, finding.net),
        .info => {},
    };

    const strict = try preflight.run(allocator, evaluator, block, project_dir, .preflight);
    defer strict.deinit(allocator);
    for (strict.findings) |finding| switch (finding.severity) {
        .@"error" => try appendItem(allocator, &errors, @tagName(finding.kind), finding.message, finding.ref_des, ""),
        .warning => try appendItem(allocator, &warnings, @tagName(finding.kind), finding.message, finding.ref_des, ""),
        .info => {},
    };

    var db = parts.PartsDb.init(allocator, project_dir);
    defer db.deinit();
    var stable_ids = std.StringHashMapUnmanaged([]const u8).empty;
    defer stable_ids.deinit(allocator);
    var selection: SelectionContext = .{
        .allocator = allocator,
        .errors = &errors,
        .db = &db,
        .stable_ids = &stable_ids,
        .keep_dnp = keep_dnp,
    };
    try appendSelectionChecks(&selection, block, "");

    return .{
        .errors = try errors.toOwnedSlice(allocator),
        .warnings = try warnings.toOwnedSlice(allocator),
        .stats = base.stats,
    };
}

const SelectionContext = struct {
    allocator: std.mem.Allocator,
    errors: *std.ArrayList(fab.Item),
    db: *parts.PartsDb,
    stable_ids: *std.StringHashMapUnmanaged([]const u8),
    keep_dnp: bool,
};

fn appendSelectionChecks(
    ctx: *SelectionContext,
    block: *const env.DesignBlock,
    prefix: []const u8,
) std.mem.Allocator.Error!void {
    for (block.instances) |instance| {
        const ref = if (prefix.len == 0)
            instance.ref_des
        else
            try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ prefix, instance.ref_des });
        if (instance.id.len > 0) {
            if (ctx.stable_ids.get(instance.id)) |first| {
                try ctx.errors.append(ctx.allocator, .{
                    .id = "duplicate-source-identity",
                    .message = try std.fmt.allocPrint(ctx.allocator, "{s} and {s} share authored stable id {s}", .{ first, ref, instance.id }),
                    .ref = ref,
                });
            } else try ctx.stable_ids.put(ctx.allocator, instance.id, ref);
        }
        if (instance.footprint.len == 0 or (instance.dnp and !ctx.keep_dnp)) continue;
        if (!ctx.db.hasFamily(instance.component)) {
            if (parameterizedPassive(instance.component)) try ctx.errors.append(ctx.allocator, .{
                .id = "bom-spec-library-missing",
                .message = try std.fmt.allocPrint(ctx.allocator, "{s} requires a readable, non-empty {s} parts table", .{ ref, instance.component }),
                .ref = ref,
            });
            continue;
        }
        const exact = ctx.db.lookupStrict(instance.component, instance.value, instance.attrs) orelse {
            try ctx.errors.append(ctx.allocator, .{
                .id = "bom-spec-unmatched",
                .message = try std.fmt.allocPrint(ctx.allocator, "{s} ({s} {s}) has no parts-table row matching every authored attribute", .{ ref, instance.component, instance.value }),
                .ref = ref,
            });
            continue;
        };
        try requireAuthoredPassiveSpecs(ctx, instance, ref, exact);
        const selected = propertyValue(instance.properties, "mpn") orelse "";
        if (exact.mpn.len == 0 or selected.len == 0 or !std.mem.eql(u8, exact.mpn, selected)) {
            try ctx.errors.append(ctx.allocator, .{
                .id = "bom-selection-drift",
                .message = try std.fmt.allocPrint(ctx.allocator, "{s} selected MPN '{s}' does not match exact specified row '{s}'", .{ ref, selected, exact.mpn }),
                .ref = ref,
            });
        }
    }
    for (block.sub_blocks) |sub| {
        const child = if (prefix.len == 0)
            sub.name
        else
            try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ prefix, sub.name });
        try appendSelectionChecks(ctx, sub.block, child);
    }
}

fn partAttrAny(entry: *const parts.PartEntry, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| for (entry.attrs) |attribute| {
        if (std.ascii.eqlIgnoreCase(attribute.key, key)) return attribute.value;
    };
    return null;
}

fn authoredValue(instance: env.Instance, value: []const u8) bool {
    for (instance.attrs) |attribute| {
        if (std.ascii.eqlIgnoreCase(attribute, value)) return true;
    }
    return false;
}

fn zeroOhm(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t");
    const resistance = req_checks.parseOhms(trimmed) orelse return false;
    return resistance == 0;
}

fn parameterizedPassive(component: []const u8) bool {
    return std.mem.startsWith(u8, component, "cap-") or
        std.mem.startsWith(u8, component, "res-") or
        std.mem.startsWith(u8, component, "ferrite-") or
        std.mem.startsWith(u8, component, "ind-");
}

const AuthoredSpec = struct {
    keys: []const []const u8,
    label: []const u8,
};

fn requireAuthoredSpec(
    ctx: *SelectionContext,
    instance: env.Instance,
    ref: []const u8,
    entry: *const parts.PartEntry,
    spec: AuthoredSpec,
) std.mem.Allocator.Error!void {
    const selected = partAttrAny(entry, spec.keys) orelse {
        try ctx.errors.append(ctx.allocator, .{
            .id = "bom-spec-library-missing",
            .message = try std.fmt.allocPrint(ctx.allocator, "{s} selected parts row has no {s} evidence", .{ ref, spec.label }),
            .ref = ref,
        });
        return;
    };
    if (selected.len > 0 and authoredValue(instance, selected)) return;
    try ctx.errors.append(ctx.allocator, .{
        .id = "bom-spec-missing",
        .message = try std.fmt.allocPrint(ctx.allocator, "{s} does not author its required {s} ({s}) in the design call", .{ ref, spec.label, selected }),
        .ref = ref,
    });
}

fn requireAuthoredPassiveSpecs(
    ctx: *SelectionContext,
    instance: env.Instance,
    ref: []const u8,
    entry: *const parts.PartEntry,
) std.mem.Allocator.Error!void {
    if (std.mem.startsWith(u8, instance.component, "cap-")) {
        try requireAuthoredSpec(ctx, instance, ref, entry, .{ .keys = &.{"voltage"}, .label = "voltage rating" });
        try requireAuthoredSpec(ctx, instance, ref, entry, .{ .keys = &.{"dielectric"}, .label = "dielectric" });
        try requireAuthoredSpec(ctx, instance, ref, entry, .{ .keys = &.{"tolerance"}, .label = "tolerance" });
    } else if (std.mem.startsWith(u8, instance.component, "res-")) {
        try requireAuthoredSpec(ctx, instance, ref, entry, .{ .keys = &.{"power"}, .label = "power rating" });
        try requireAuthoredSpec(ctx, instance, ref, entry, .{ .keys = &.{ "voltage", "working-voltage", "rated-voltage" }, .label = "working voltage" });
        if (zeroOhm(instance.value)) {
            try requireAuthoredSpec(ctx, instance, ref, entry, .{ .keys = &.{ "rated-current", "current-rating", "current" }, .label = "jumper current" });
            try requireAuthoredSpec(ctx, instance, ref, entry, .{ .keys = &.{ "max-resistance", "resistance-max" }, .label = "maximum jumper resistance" });
        } else try requireAuthoredSpec(ctx, instance, ref, entry, .{ .keys = &.{"tolerance"}, .label = "tolerance" });
    } else if (std.mem.startsWith(u8, instance.component, "ferrite-") or std.mem.startsWith(u8, instance.component, "ind-")) {
        try requireAuthoredSpec(ctx, instance, ref, entry, .{ .keys = &.{ "rated-current", "current-rating", "current" }, .label = "rated current" });
        try requireAuthoredSpec(ctx, instance, ref, entry, .{ .keys = &.{ "dcr-max", "dcr" }, .label = "maximum DCR" });
        if (std.mem.startsWith(u8, instance.component, "ind-")) try requireAuthoredSpec(ctx, instance, ref, entry, .{ .keys = &.{"tolerance"}, .label = "tolerance" });
    }
}

// spec: fabrication-release - 0R0 is a zero-ohm jumper that requires authored current and maximum-resistance evidence, never tolerance
test "0R0 uses jumper specification semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const attributes = [_]env.Property{
        .{ .key = "power", .value = "63mW" },
        .{ .key = "voltage", .value = "25V" },
        .{ .key = "rated-current", .value = "1A" },
        .{ .key = "max-resistance", .value = "50mOhm" },
        .{ .key = "tolerance", .value = "5%" },
    };
    const authored = [_][]const u8{ "63mW", "25V", "1A", "50mOhm" };
    const instance = env.Instance{
        .ref_des = "R1",
        .component = "res-0402",
        .value = "0R0",
        .footprint = "r0402",
        .symbol = "resistor",
        .attrs = &authored,
    };
    const entry = parts.PartEntry{
        .value = "0R0",
        .manufacturer = "Maker",
        .mpn = "JUMPER",
        .attrs = &attributes,
        .preferred = true,
    };
    var errors: std.ArrayList(fab.Item) = .empty;
    var stable_ids = std.StringHashMapUnmanaged([]const u8).empty;
    var db = parts.PartsDb.init(allocator, ".");
    var selection: SelectionContext = .{ .allocator = allocator, .errors = &errors, .db = &db, .stable_ids = &stable_ids, .keep_dnp = false };
    try requireAuthoredPassiveSpecs(&selection, instance, "R1", &entry);
    try std.testing.expect(zeroOhm("0R0"));
    try std.testing.expectEqual(@as(usize, 0), errors.items.len);
}
