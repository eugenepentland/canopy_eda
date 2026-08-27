//! BOM identity resolution: matches each flattened instance to its part
//! identity (MPN, value, DNP) from the BOM sidecar and library, then writes the
//! resolved properties back into the `.sexp` source (`setBomProperty`). The
//! bridge between the netlist and the manufacturing BOM.

const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const log = @import("infra/log.zig");
const env_mod = @import("eval/env.zig");
const parts_mod = @import("parts.zig");
const DesignBlock = env_mod.DesignBlock;
const Instance = env_mod.Instance;
const Property = env_mod.Property;
const bom_mod = @import("bom.zig");
const export_kicad = @import("export_kicad.zig");
const kicad_format = @import("kicad_pcb/format.zig");
const FlatInfo = bom_mod.FlatInfo;
const refdes_stability = @import("refdes_stability.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

// ── Constants ─────────────────────────────────────────────────────

/// Error set for the BOM-resolve pipeline. Combines BOM file IO (open/read/
/// write the .bom sidecar) with `OutOfMemory` from the various
/// `ArrayList`/`HashMap` operations.
pub const ResolveError = std.mem.Allocator.Error ||
    infra_fs.File.OpenError ||
    infra_fs.File.ReadError ||
    infra_fs.File.WriteError ||
    error{ FileTooBig, StreamTooLong, EndOfStream, WriteFailed, DiskQuota, BrokenPipe, NotOpenForWriting, EntropyUnavailable };

/// Drop every property owned by the previous parts-table selection. Used when
/// component, value, or canonical net set changes under a stable id: the PCB
/// UUID remains stable, but the prior MPN/rating evidence must not survive.
fn filterOutPartProps(allocator: std.mem.Allocator, props: []const Property) ![]const Property {
    var out: std.ArrayList(Property) = .empty;
    const selected_keys = propertyValue(props, selected_part_keys_property) orelse "";
    for (props) |p| {
        if (std.ascii.eqlIgnoreCase(p.key, "manufacturer")) continue;
        if (std.ascii.eqlIgnoreCase(p.key, "mpn")) continue;
        if (std.ascii.eqlIgnoreCase(p.key, selected_part_keys_property)) continue;
        if (std.ascii.eqlIgnoreCase(p.key, selected_part_row_fingerprint_property)) continue;
        if (listedProperty(selected_keys, p.key)) continue;
        try out.append(allocator, p);
    }
    return out.toOwnedSlice(allocator);
}

/// Carry a prior selection only when its full source signature still matches.
/// Old sidecars lacking value/net identity deliberately cannot donate an MPN.
fn carryForwardProps(
    allocator: std.mem.Allocator,
    props_map: *std.StringHashMapUnmanaged([]const Property),
    info: FlatInfo,
    old_entry: bom_mod.BomEntry,
) !void {
    if (old_entry.properties.len == 0) return;
    // Fixed components carry their complete authored properties in `info`.
    // Their sidecar is identity evidence, never an alternate source of MPN or
    // manufacturer truth, so rebuilding also repairs any hand-edited row.
    if (!parameterizedPassive(info.component)) return;
    const current_fingerprint = sourceFingerprint(info);
    const same_source = old_entry.component.len > 0 and
        old_entry.value.len > 0 and
        old_entry.source_fingerprint.len == current_fingerprint.len and
        std.mem.eql(u8, old_entry.component, info.component) and
        std.mem.eql(u8, old_entry.value, info.value) and
        std.mem.eql(u8, old_entry.source_fingerprint, &current_fingerprint) and
        sameStringSet(old_entry.nets, info.nets);
    const props_to_keep = if (same_source)
        old_entry.properties
    else
        try filterOutPartProps(allocator, old_entry.properties);
    if (props_to_keep.len == 0) return;
    try props_map.put(allocator, info.ref_des, props_to_keep);
}

fn fingerprintField(hash: *Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(value.len), .little);
    hash.update(&length);
    hash.update(value);
}

fn parameterizedPassive(component: []const u8) bool {
    return std.mem.startsWith(u8, component, "cap-") or
        std.mem.startsWith(u8, component, "res-") or
        std.mem.startsWith(u8, component, "ferrite-") or
        std.mem.startsWith(u8, component, "ind-");
}

/// Hash source-authored selection inputs, excluding properties donated by the
/// previous BOM. Fixed parts include inline manufacturer/MPN identity; parts-
/// table passives prove those through strict lookup instead.
fn sourceFingerprint(info: FlatInfo) [64]u8 {
    var hash = Sha256.init(.{});
    fingerprintField(&hash, info.component);
    fingerprintField(&hash, info.value);
    fingerprintField(&hash, info.footprint);
    for (info.attrs) |attribute| fingerprintField(&hash, attribute);
    if (!parameterizedPassive(info.component)) for (info.properties) |property| {
        const identity = std.ascii.eqlIgnoreCase(property.key, "manufacturer") or std.ascii.eqlIgnoreCase(property.key, "mpn");
        if (!identity) continue;
        fingerprintField(&hash, if (std.ascii.eqlIgnoreCase(property.key, "mpn")) "mpn" else "manufacturer");
        fingerprintField(&hash, property.value);
    };
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn stabilizeRefdes(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    old_entries: []const bom_mod.BomEntry,
) std.mem.Allocator.Error!void {
    const priors = try allocator.alloc(refdes_stability.Prior, old_entries.len);
    defer allocator.free(priors);
    for (old_entries, priors) |entry, *prior| prior.* = .{ .id = entry.id, .ref_des = entry.ref_des };
    try refdes_stability.apply(allocator, block, priors);
}

const selected_part_keys_property = "selected-part-property-keys";
const selected_part_row_fingerprint_property = "selected-part-row-fingerprint";

fn propertyValue(props: []const Property, key: []const u8) ?[]const u8 {
    for (props) |prop| if (std.ascii.eqlIgnoreCase(prop.key, key)) return prop.value;
    return null;
}

fn listedProperty(keys: []const u8, key: []const u8) bool {
    var it = std.mem.splitScalar(u8, keys, ',');
    while (it.next()) |candidate| if (std.ascii.eqlIgnoreCase(candidate, key)) return true;
    return false;
}

fn selectedPartFingerprint(part: *const parts_mod.PartEntry) [64]u8 {
    var hash = Sha256.init(.{});
    fingerprintField(&hash, part.value);
    fingerprintField(&hash, part.manufacturer);
    fingerprintField(&hash, part.mpn);
    hash.update(&.{@intFromBool(part.preferred)});
    for (part.attrs) |attribute| {
        fingerprintField(&hash, attribute.key);
        fingerprintField(&hash, attribute.value);
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn selectedPartMatches(properties: []const Property, part: *const parts_mod.PartEntry) bool {
    const stored = propertyValue(properties, selected_part_row_fingerprint_property) orelse return false;
    const current = selectedPartFingerprint(part);
    if (!std.mem.eql(u8, stored, &current)) return false;
    if (!std.mem.eql(u8, propertyValue(properties, "manufacturer") orelse "", part.manufacturer)) return false;
    if (!std.mem.eql(u8, propertyValue(properties, "mpn") orelse "", part.mpn)) return false;
    const managed = propertyValue(properties, selected_part_keys_property) orelse return part.attrs.len == 0;
    var managed_count: usize = 0;
    var iterator = std.mem.splitScalar(u8, managed, ',');
    while (iterator.next()) |key| {
        if (key.len == 0) continue;
        managed_count += 1;
        var found = false;
        for (part.attrs) |attribute| {
            if (std.ascii.eqlIgnoreCase(key, attribute.key)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    if (managed_count != part.attrs.len) return false;
    for (part.attrs) |attribute| {
        if (!listedProperty(managed, attribute.key)) return false;
        if (!std.mem.eql(u8, propertyValue(properties, attribute.key) orelse "", attribute.value)) return false;
    }
    return true;
}

fn selectedRowMatches(current: FlatInfo, properties: []const Property, part: *const parts_mod.PartEntry) bool {
    if (!propertyKeysUnique(current.properties) or !propertyKeysUnique(properties)) return false;
    if (!selectedPartMatches(properties, part)) return false;
    if (parameterizedPassive(current.component)) return true;
    for (current.properties) |source| {
        if (std.ascii.eqlIgnoreCase(source.key, "manufacturer")) {
            if (source.value.len > 0 and !std.mem.eql(u8, source.value, part.manufacturer)) return false;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(source.key, "mpn")) {
            if (source.value.len > 0 and !std.mem.eql(u8, source.value, part.mpn)) return false;
            continue;
        }
        // A table selection may add properties, but a persisted row may never
        // alter a component-authored property under the same key. `mergeProps`
        // gives the BOM precedence, so this equality is the proof that an
        // inline electrical rating cannot be hand-edited upward in the sidecar.
        if (propertyValue(properties, source.key)) |persisted| {
            if (!std.mem.eql(u8, persisted, source.value)) return false;
        }
    }
    return true;
}

fn propertyKeysUnique(properties: []const Property) bool {
    for (properties, 0..) |property, index| {
        for (properties[0..index]) |prior| {
            if (std.ascii.eqlIgnoreCase(property.key, prior.key)) return false;
        }
    }
    return true;
}

fn appendSelectedPartProperties(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Property),
    attrs: []const Property,
) !void {
    for (attrs) |attr| {
        var present = false;
        for (out.items) |old| if (std.ascii.eqlIgnoreCase(old.key, attr.key)) {
            present = true;
            break;
        };
        if (!present) try out.append(allocator, .{
            .key = try allocator.dupe(u8, attr.key),
            .value = try allocator.dupe(u8, attr.value),
        });
    }
    if (attrs.len == 0) return;
    var keys: std.Io.Writer.Allocating = .init(allocator);
    defer keys.deinit();
    for (attrs, 0..) |attr, idx| {
        if (idx > 0) try keys.writer.writeByte(',');
        try keys.writer.writeAll(attr.key);
    }
    try out.append(allocator, .{
        .key = try allocator.dupe(u8, selected_part_keys_property),
        .value = try keys.toOwnedSlice(),
    });
}

fn selectedPartProperties(
    allocator: std.mem.Allocator,
    existing_props: []const Property,
    part: *const parts_mod.PartEntry,
) ![]const Property {
    var out: std.ArrayList(Property) = .empty;
    const old_selected_keys = propertyValue(existing_props, selected_part_keys_property) orelse "";
    for (existing_props) |prop| {
        if (startsWithIgnoreCase(prop.key, "pdn-")) continue;
        if (std.ascii.eqlIgnoreCase(prop.key, "manufacturer") or std.ascii.eqlIgnoreCase(prop.key, "mpn")) continue;
        if (std.ascii.eqlIgnoreCase(prop.key, selected_part_keys_property)) continue;
        if (std.ascii.eqlIgnoreCase(prop.key, selected_part_row_fingerprint_property)) continue;
        if (listedProperty(old_selected_keys, prop.key)) continue;
        try out.append(allocator, prop);
    }
    if (part.manufacturer.len > 0) try out.append(allocator, .{
        .key = try allocator.dupe(u8, "manufacturer"),
        .value = try allocator.dupe(u8, part.manufacturer),
    });
    if (part.mpn.len > 0) try out.append(allocator, .{
        .key = try allocator.dupe(u8, "mpn"),
        .value = try allocator.dupe(u8, part.mpn),
    });
    try appendSelectedPartProperties(allocator, &out, part.attrs);
    const fingerprint = selectedPartFingerprint(part);
    try out.append(allocator, .{
        .key = try allocator.dupe(u8, selected_part_row_fingerprint_property),
        .value = try allocator.dupe(u8, &fingerprint),
    });
    return out.toOwnedSlice(allocator);
}

// spec: bom-resolve - a selected parts-table row persists its complete rated and analysis properties, replaces the previous row's managed properties, and may migrate an exact legacy MPN to its declared current MPN
test "selected part properties and exact legacy MPN migration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const old = [_]Property{
        .{ .key = "manufacturer", .value = "Old Maker" },
        .{ .key = "mpn", .value = "OLD-1" },
        .{ .key = "pdn-esr-ohm", .value = "0.050" },
    };
    const attrs = [_]Property{
        .{ .key = "dielectric", .value = "x7r" },
        .{ .key = "legacy-mpn", .value = "OLD-1" },
        .{ .key = "pdn-esr-ohm", .value = "0.018" },
        .{ .key = "pdn-dc-bias-curve", .value = "0:1,5:0.4" },
    };
    const part = parts_mod.PartEntry{
        .value = "1uF",
        .manufacturer = "Current Maker",
        .mpn = "NEW-1",
        .attrs = &attrs,
        .preferred = true,
    };
    const out = try selectedPartProperties(alloc, &old, &part);
    try std.testing.expectEqualStrings("Current Maker", propertyValue(out, "manufacturer").?);
    try std.testing.expectEqualStrings("NEW-1", propertyValue(out, "mpn").?);
    try std.testing.expectEqualStrings("x7r", propertyValue(out, "dielectric").?);
    try std.testing.expectEqualStrings("0.018", propertyValue(out, "pdn-esr-ohm").?);
    try std.testing.expectEqualStrings("0:1,5:0.4", propertyValue(out, "pdn-dc-bias-curve").?);
    try std.testing.expect(selectedPartMatches(out, &part));
}

// spec: bom-resolve - a same-MPN parts-row rating correction invalidates persisted selected-row evidence
test "selected row fingerprint rejects same-MPN rating drift and duplicate managed keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const old_attrs = [_]Property{
        .{ .key = "voltage", .value = "50V" },
        .{ .key = "tolerance", .value = "10%" },
    };
    const new_attrs = [_]Property{
        .{ .key = "voltage", .value = "25V" },
        .{ .key = "tolerance", .value = "10%" },
    };
    const old_part = parts_mod.PartEntry{ .value = "1uF", .manufacturer = "Maker", .mpn = "SAME-MPN", .attrs = &old_attrs, .preferred = true };
    const new_part = parts_mod.PartEntry{ .value = "1uF", .manufacturer = "Maker", .mpn = "SAME-MPN", .attrs = &new_attrs, .preferred = true };
    const persisted = try selectedPartProperties(alloc, &.{}, &old_part);
    try std.testing.expect(selectedPartMatches(persisted, &old_part));
    try std.testing.expect(!selectedPartMatches(persisted, &new_part));
    var duplicated: std.ArrayList(Property) = .empty;
    try duplicated.appendSlice(alloc, persisted);
    try duplicated.append(alloc, .{ .key = "MPN", .value = "WRONG" });
    try std.testing.expect(!propertyKeysUnique(duplicated.items));
}

/// Resolve identities and BOM data for all instances in a design block.
pub fn resolveIdentities(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    bom_path: []const u8,
    project_dir: []const u8,
) ResolveError!void {
    const old_entries = try bom_mod.loadBom(allocator, bom_path);
    defer {
        for (old_entries) |e| {
            if (e.ref_des.len > 0) allocator.free(e.ref_des);
            if (e.uuid.len > 0) allocator.free(e.uuid);
            if (e.component.len > 0) allocator.free(e.component);
            if (e.value.len > 0) allocator.free(e.value);
            if (e.source_fingerprint.len > 0) allocator.free(e.source_fingerprint);
            if (e.id.len > 0) allocator.free(e.id);
            for (e.nets) |net| allocator.free(net);
            if (e.nets.len > 0) allocator.free(e.nets);
            for (e.properties) |p| {
                allocator.free(p.key);
                allocator.free(p.value);
            }
            if (e.properties.len > 0) allocator.free(e.properties);
        }
        allocator.free(old_entries);
    }

    try stabilizeRefdes(allocator, block, old_entries);

    var flat_list: std.ArrayList(FlatInfo) = .empty;
    defer flat_list.deinit(allocator);
    try bom_mod.collectFlatInstances(allocator, block, "", &flat_list);

    var result_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer result_map.deinit(allocator);
    var props_map = std.StringHashMapUnmanaged([]const Property).empty;
    defer props_map.deinit(allocator);

    // PROTOTYPE — deterministic identity (replaces the Pass 0..3.6 matcher).
    // uuid = uuidFromId(stable id). With sub-block ids now keyed off the stable
    // module-source label, every part's id is renumber-invariant, so the uuid
    // is fully determined by the design: it reproduces identically every build
    // and regenerates from scratch if the .bom is lost. Props (MPN) carry
    // forward by id from the previous .bom; Pass 4 fills any missing MPN.
    var old_by_id = std.StringHashMapUnmanaged(usize).empty;
    defer old_by_id.deinit(allocator);
    for (old_entries, 0..) |e, idx| {
        if (e.id.len > 0) try old_by_id.put(allocator, e.id, idx);
    }
    var used_uuids = std.StringHashMapUnmanaged(void).empty;
    defer used_uuids.deinit(allocator);
    // Track ids we've already consumed so the tiebreak below can tell a genuine
    // (astronomically unlikely) SHA-256 collision of two *different* ids from a
    // *duplicate* stable id — the latter is a source bug (copy-paste of an
    // `(id …)` token) and worth a loud warning, because its identity then
    // becomes renumber-sensitive (re-derived from ref_des), defeating the whole
    // renumber-proof-id design. id_insert already rejects duplicates it mints;
    // this catches ones a user hand-copied into the source.
    var seen_ids = std.StringHashMapUnmanaged(void).empty;
    defer seen_ids.deinit(allocator);
    for (flat_list.items) |info| {
        const uuid = blk: {
            if (info.id.len == 0) break :blk try bom_mod.generateUuid(allocator);
            const primary = try export_kicad.uuidFromId(allocator, info.id);
            if (!used_uuids.contains(primary)) {
                try seen_ids.put(allocator, info.id, {});
                break :blk primary;
            }
            if (seen_ids.contains(info.id)) {
                log.warn("duplicate stable id '{s}' on '{s}' — its board identity is now renumber-sensitive; give the copy-pasted instance a fresh (id …)", .{ info.id, info.ref_des });
            }
            // Deterministic collision tiebreak: re-derive from "id/ref_des".
            // ref_des is itself deterministic per design, so the result still
            // reproduces exactly build-to-build (just not across a renumber).
            allocator.free(primary);
            const combined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ info.id, info.ref_des });
            defer allocator.free(combined);
            break :blk try export_kicad.uuidFromId(allocator, combined);
        };
        try used_uuids.put(allocator, uuid, {});
        try result_map.put(allocator, info.ref_des, uuid);
        if (info.id.len > 0) {
            if (old_by_id.get(info.id)) |idx| {
                try carryForwardProps(allocator, &props_map, info, old_entries[idx]);
            }
        }
    }

    // Pass 4: auto-resolve manufacturer + MPN from parts DB
    var parts_db = parts_mod.PartsDb.init(allocator, project_dir);
    defer parts_db.deinit();

    for (flat_list.items) |info| {
        const existing_props = props_map.get(info.ref_des) orelse &.{};
        if (info.footprint.len == 0) {
            if (info.value.len > 0) {
                log.warn("{s} uses unsized family '{s}' — no footprint or MPN resolution", .{ info.ref_des, info.component });
            }
            continue;
        }
        if (parts_db.lookup(info.component, info.value, info.attrs)) |part| {
            // Persist the complete selected row: procurement/review needs the
            // rated properties, and physical analysis needs its PDN columns.
            try props_map.put(allocator, info.ref_des, try selectedPartProperties(allocator, existing_props, part));
        }
    }

    try applyBom(allocator, block, &result_map, &props_map, "");
    try saveBom(allocator, bom_path, flat_list.items, &result_map, &props_map);
}

/// Apply an already-generated BOM sidecar to a freshly evaluated block without
/// selecting parts, minting identities, or rewriting any project file.  Fab
/// export is a read-only release operation; it needs the exact MPN/rating data
/// captured by the last explicit build, but must not make a hidden BOM update
/// while the user is reviewing a release report.
pub fn applyExisting(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    bom_path: []const u8,
    project_dir: []const u8,
) ResolveError!void {
    const entries = try bom_mod.loadBom(allocator, bom_path);
    defer {
        for (entries) |entry| {
            if (entry.ref_des.len > 0) allocator.free(entry.ref_des);
            if (entry.uuid.len > 0) allocator.free(entry.uuid);
            if (entry.component.len > 0) allocator.free(entry.component);
            if (entry.value.len > 0) allocator.free(entry.value);
            if (entry.source_fingerprint.len > 0) allocator.free(entry.source_fingerprint);
            if (entry.id.len > 0) allocator.free(entry.id);
            for (entry.nets) |net| allocator.free(net);
            if (entry.nets.len > 0) allocator.free(entry.nets);
            for (entry.properties) |prop| {
                allocator.free(prop.key);
                allocator.free(prop.value);
            }
            if (entry.properties.len > 0) allocator.free(entry.properties);
        }
        allocator.free(entries);
    }
    var uuids = std.StringHashMapUnmanaged([]const u8).empty;
    defer uuids.deinit(allocator);
    var props = std.StringHashMapUnmanaged([]const Property).empty;
    defer props.deinit(allocator);
    var flat: std.ArrayList(FlatInfo) = .empty;
    defer flat.deinit(allocator);
    try bom_mod.collectFlatInstances(allocator, block, "", &flat);
    var source = std.StringHashMapUnmanaged(FlatInfo).empty;
    defer source.deinit(allocator);
    var parts_db = parts_mod.PartsDb.init(allocator, project_dir);
    defer parts_db.deinit();
    for (flat.items) |info| try source.put(allocator, info.ref_des, info);
    for (entries) |entry| {
        const current = source.get(entry.ref_des) orelse continue;
        // A sidecar row belongs to the source identity, not merely to the
        // ref-des currently occupying that label.  Ref-des reuse after a
        // component swap must never attach the old MPN/rating to the new part.
        if (entry.component.len == 0 or !std.mem.eql(u8, entry.component, current.component)) continue;
        if (entry.id.len == 0 or current.id.len == 0 or !std.mem.eql(u8, entry.id, current.id)) continue;
        if (!std.mem.eql(u8, entry.value, current.value)) continue;
        const fingerprint = sourceFingerprint(current);
        if (!std.mem.eql(u8, entry.source_fingerprint, &fingerprint)) continue;
        if (!sameStringSet(entry.nets, current.nets)) continue;
        if (entry.uuid.len > 0) try uuids.put(allocator, entry.ref_des, entry.uuid);
        const has_family = parts_db.hasFamily(current.component);
        const selected = parts_db.lookupStrict(current.component, current.value, current.attrs);
        const row_matches = propertyKeysUnique(entry.properties) and if (selected) |part|
            selectedRowMatches(current, entry.properties, part)
        else if (has_family)
            false
        else
            fixedPropertiesMatch(current.properties, entry.properties);
        if (row_matches and entry.properties.len > 0) try props.put(allocator, entry.ref_des, entry.properties);
    }
    try applyBom(allocator, block, &uuids, &props, "");
}

/// Prove that the persisted BOM sidecar describes this exact evaluated source
/// identity. Missing, malformed, legacy (value-less), duplicate, or stale rows
/// return false; manufacturing uses this as non-waivable evidence completeness.
pub fn existingSidecarMatches(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    bom_path: []const u8,
    project_dir: []const u8,
) ResolveError!bool {
    const entries = try bom_mod.loadBom(allocator, bom_path);
    defer freeEntries(allocator, entries);
    var flat: std.ArrayList(FlatInfo) = .empty;
    defer flat.deinit(allocator);
    try bom_mod.collectFlatInstances(allocator, block, "", &flat);
    var parts_db = parts_mod.PartsDb.init(allocator, project_dir);
    defer parts_db.deinit();
    if (entries.len != flat.items.len) return false;
    for (flat.items) |current| {
        var matches: usize = 0;
        for (entries) |entry| {
            if (!std.mem.eql(u8, entry.ref_des, current.ref_des)) continue;
            if (entry.id.len == 0 or current.id.len == 0) continue;
            if (!std.mem.eql(u8, entry.id, current.id)) continue;
            if (!std.mem.eql(u8, entry.component, current.component)) continue;
            if (!std.mem.eql(u8, entry.value, current.value)) continue;
            const fingerprint = sourceFingerprint(current);
            if (!std.mem.eql(u8, entry.source_fingerprint, &fingerprint)) continue;
            if (!sameStringSet(entry.nets, current.nets)) continue;
            if (entry.uuid.len == 0) continue;
            if (!propertyKeysUnique(entry.properties)) continue;
            const has_family = parts_db.hasFamily(current.component);
            if (parts_db.lookupStrict(current.component, current.value, current.attrs)) |selected| {
                if (!selectedRowMatches(current, entry.properties, selected)) continue;
            } else if (has_family or !fixedPropertiesMatch(current.properties, entry.properties)) {
                continue;
            }
            matches += 1;
        }
        if (matches != 1) return false;
    }
    return true;
}

fn freeEntries(allocator: std.mem.Allocator, entries: []const bom_mod.BomEntry) void {
    for (entries) |entry| {
        if (entry.ref_des.len > 0) allocator.free(entry.ref_des);
        if (entry.uuid.len > 0) allocator.free(entry.uuid);
        if (entry.component.len > 0) allocator.free(entry.component);
        if (entry.value.len > 0) allocator.free(entry.value);
        if (entry.source_fingerprint.len > 0) allocator.free(entry.source_fingerprint);
        if (entry.id.len > 0) allocator.free(entry.id);
        for (entry.nets) |net| allocator.free(net);
        if (entry.nets.len > 0) allocator.free(entry.nets);
        for (entry.properties) |property| {
            allocator.free(property.key);
            allocator.free(property.value);
        }
        if (entry.properties.len > 0) allocator.free(entry.properties);
    }
    allocator.free(entries);
}

fn sameStringSet(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    // Compare as a multiset: a two-pin part can legally have the same net on
    // both pins, and a simple membership test would let {A,A} match {A,B}.
    for (a, 0..) |item, item_index| {
        var required: usize = 1;
        for (a[0..item_index]) |prior| {
            if (std.mem.eql(u8, item, prior)) required += 1;
        }
        var available: usize = 0;
        for (b) |candidate| {
            if (std.mem.eql(u8, item, candidate)) available += 1;
        }
        if (available < required) return false;
    }
    return true;
}

/// Fixed components source their procurement identity directly from the
/// component definition. A sidecar may restore UUIDs, but it cannot introduce
/// or override properties that are absent or different in that source.
fn fixedPropertiesMatch(source: []const Property, persisted: []const Property) bool {
    if (!propertyKeysUnique(source) or !propertyKeysUnique(persisted)) return false;
    if (source.len != persisted.len) return false;
    for (source) |expected| {
        const actual = propertyValue(persisted, expected.key) orelse return false;
        if (!std.mem.eql(u8, actual, expected.value)) return false;
    }
    return true;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

/// Merge component-defined properties with the .bom-resident ones (the .bom
/// wins on key collision). Extracted from applyBom to keep its nesting shallow.
fn mergeProps(
    allocator: std.mem.Allocator,
    inst_props: []const Property,
    bom_props: []const Property,
) ![]Property {
    var merged: std.ArrayList(Property) = .empty;
    for (inst_props) |cp| {
        var overridden = false;
        for (bom_props) |ip| {
            if (std.ascii.eqlIgnoreCase(cp.key, ip.key)) {
                overridden = true;
                break;
            }
        }
        if (!overridden) try merged.append(allocator, cp);
    }
    for (bom_props) |ip| try merged.append(allocator, .{
        .key = allocator.dupe(u8, ip.key) catch ip.key,
        .value = allocator.dupe(u8, ip.value) catch ip.value,
    });
    return merged.toOwnedSlice(allocator);
}

fn applyBom(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    uuid_map: *const std.StringHashMapUnmanaged([]const u8),
    props_map: *const std.StringHashMapUnmanaged([]const Property),
    prefix: []const u8,
) !void {
    const instances: []Instance = @constCast(block.instances);
    for (instances) |*inst| {
        const key = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, inst.ref_des })
        else
            inst.ref_des;
        defer if (prefix.len > 0) allocator.free(key);

        if (uuid_map.get(key)) |uuid| {
            inst.uuid = allocator.dupe(u8, uuid) catch uuid;
        }

        if (props_map.get(key)) |bom_props| {
            if (bom_props.len > 0) {
                inst.properties = try mergeProps(allocator, inst.properties, bom_props);
            }
        }
    }
    for (block.sub_blocks) |sb| {
        const child_prefix = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, sb.name })
        else
            sb.name;
        defer if (prefix.len > 0) allocator.free(child_prefix);
        try applyBom(allocator, sb.block, uuid_map, props_map, child_prefix);
    }
}

fn saveBom(
    allocator: std.mem.Allocator,
    bom_path: []const u8,
    flat_instances: []const FlatInfo,
    uuid_map: *const std.StringHashMapUnmanaged([]const u8),
    props_map: *const std.StringHashMapUnmanaged([]const Property),
) !void {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    try w.writeAll(";; BOM — auto-generated by netlisp build\n");
    try w.writeAll(";; Stores identity and properties per instance\n\n");

    for (flat_instances) |info| {
        const uuid = uuid_map.get(info.ref_des) orelse continue;
        const props = props_map.get(info.ref_des) orelse info.properties;

        // Escape every quoted field: ref-des/component/net names arrive from
        // third-party board imports and property values from HTTP edits, so a
        // raw `"`/trailing `\` would otherwise make the `.bom` unparseable
        // (loadBom's `catch return &.{}` then silently drops ALL entries).
        try w.print("(part \"{s}\" \"{s}\" \"{s}\"\n", .{
            try kicad_format.sexprEscape(allocator, info.ref_des),
            uuid,
            try kicad_format.sexprEscape(allocator, info.component),
        });
        try w.print("  (id \"{s}\")\n", .{info.id});
        try w.print("  (value \"{s}\")\n", .{try kicad_format.sexprEscape(allocator, info.value)});
        const fingerprint = sourceFingerprint(info);
        try w.print("  (source-fingerprint \"{s}\")\n", .{fingerprint});
        if (info.nets.len > 0) {
            try w.writeAll("  (nets");
            for (info.nets) |net| {
                try w.print(" \"{s}\"", .{try kicad_format.sexprEscape(allocator, net)});
            }
            try w.writeAll(")\n");
        }
        for (props) |p| {
            if (std.mem.eql(u8, p.key, "footprint") or
                std.mem.eql(u8, p.key, "value")) continue;
            try w.print("  ({s} \"{s}\")\n", .{ p.key, try kicad_format.sexprEscape(allocator, p.value) });
        }
        try w.writeAll(")\n");
    }

    // Skip the write when the .bom is byte-identical to what's on disk. An
    // unconditional rewrite bumps the file mtime on every resolve — including
    // the read-only schematic/home/review paths — which needlessly churns git
    // and, worse, defeats the server's mtime-keyed page caches (they track the
    // .bom as a dependency, so a no-op rewrite spuriously invalidates them).
    // Mirrors the ".refdes.json writes only on change" rule.
    if (infra_fs.cwd().readFileAlloc(allocator, bom_path, 16 * 1024 * 1024)) |existing| {
        defer allocator.free(existing);
        if (std.mem.eql(u8, existing, buf.written())) return;
    } else |_| {}

    const f = try infra_fs.cwd().createFile(bom_path, .{});
    defer f.close();
    try f.writeAll(buf.written());
}

/// Serialize a list of `BomEntry` back to the `.bom` sidecar grammar.
/// Used by `setBomProperty` for inline single-property edits, where we
/// load the existing entries, mutate one, and write the lot back without
/// re-running the full identity-resolution pipeline.
fn writeBomEntries(
    allocator: std.mem.Allocator,
    bom_path: []const u8,
    entries: []const bom_mod.BomEntry,
) !void {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    try w.writeAll(";; BOM — auto-generated by netlisp build\n");
    try w.writeAll(";; Stores identity and properties per instance\n\n");

    for (entries) |entry| {
        // entry.component may be "" for a brand-new stub from setBomProperty
        // or for a legacy .bom that pre-dates the component field. The next
        // full saveBom (after a design rebuild) re-populates it from FlatInfo.
        // Escape every quoted field — the property value here is the raw
        // HTTP-supplied edit from setBomProperty, so an embedded `"`/`\` must
        // not be allowed to corrupt the `.bom`.
        try w.print("(part \"{s}\" \"{s}\" \"{s}\"\n", .{
            try kicad_format.sexprEscape(allocator, entry.ref_des),
            entry.uuid,
            try kicad_format.sexprEscape(allocator, entry.component),
        });
        if (entry.id.len > 0) try w.print("  (id \"{s}\")\n", .{entry.id});
        if (entry.value.len > 0) try w.print("  (value \"{s}\")\n", .{try kicad_format.sexprEscape(allocator, entry.value)});
        if (entry.source_fingerprint.len > 0) try w.print("  (source-fingerprint \"{s}\")\n", .{entry.source_fingerprint});
        if (entry.nets.len > 0) {
            try w.writeAll("  (nets");
            for (entry.nets) |net| try w.print(" \"{s}\"", .{try kicad_format.sexprEscape(allocator, net)});
            try w.writeAll(")\n");
        }
        for (entry.properties) |p| {
            if (std.mem.eql(u8, p.key, "footprint") or std.mem.eql(u8, p.key, "value")) continue;
            try w.print("  ({s} \"{s}\")\n", .{ p.key, try kicad_format.sexprEscape(allocator, p.value) });
        }
        try w.writeAll(")\n");
    }

    const f = try infra_fs.cwd().createFile(bom_path, .{});
    defer f.close();
    try f.writeAll(buf.written());
}

/// Error set for `setBomProperty`. Combines `bom.loadBom`'s read-side
/// errors with the write-side errors from `writeBomEntries`.
pub const SetPropertyError = bom_mod.BomError || infra_fs.File.WriteError ||
    error{ WriteFailed, DiskQuota, BrokenPipe, NotOpenForWriting, EntropyUnavailable, Canceled };

/// Update or insert a single property on the BOM entry for `ref_des`.
/// Loads the sidecar, merges `(key, value)` into the entry's properties
/// (replacing any prior value for the same key; inserting a new entry
/// stub if no entry exists for `ref_des`), then writes the sidecar back.
/// The new-entry stub uses a freshly-generated UUID and empty nets — the
/// next full resolve pass will reconcile those from the design.
pub fn setBomProperty(
    allocator: std.mem.Allocator,
    bom_path: []const u8,
    ref_des: []const u8,
    key: []const u8,
    value: []const u8,
) SetPropertyError!void {
    const old_entries = try bom_mod.loadBom(allocator, bom_path);
    defer {
        for (old_entries) |e| {
            if (e.ref_des.len > 0) allocator.free(e.ref_des);
            if (e.uuid.len > 0) allocator.free(e.uuid);
            if (e.component.len > 0) allocator.free(e.component);
            if (e.value.len > 0) allocator.free(e.value);
            if (e.source_fingerprint.len > 0) allocator.free(e.source_fingerprint);
            if (e.id.len > 0) allocator.free(e.id);
            for (e.properties) |p| {
                allocator.free(p.key);
                allocator.free(p.value);
            }
            if (e.properties.len > 0) allocator.free(e.properties);
            for (e.nets) |n| allocator.free(n);
            if (e.nets.len > 0) allocator.free(e.nets);
        }
        allocator.free(old_entries);
    }

    var out: std.ArrayList(bom_mod.BomEntry) = .empty;
    defer out.deinit(allocator);

    // Property slices (and, for a brand-new entry, its uuid) that THIS function
    // allocates. `old_entries`' cleanup above only covers what `loadBom`
    // allocated, so without this a non-arena caller leaks one slice per edit.
    // Only the slices are freed — their key/value items point into `old_entries`
    // or into the caller's `key`/`value`.
    var owned_props: std.ArrayList([]Property) = .empty;
    var owned_uuid: ?[]const u8 = null;
    defer {
        for (owned_props.items) |p| allocator.free(p);
        owned_props.deinit(allocator);
        if (owned_uuid) |u| allocator.free(u);
    }

    var matched = false;
    for (old_entries) |entry| {
        if (!std.mem.eql(u8, entry.ref_des, ref_des)) {
            try out.append(allocator, entry);
            continue;
        }
        matched = true;
        var props: std.ArrayList(Property) = .empty;
        var replaced = false;
        for (entry.properties) |p| {
            if (std.mem.eql(u8, p.key, key)) {
                try props.append(allocator, .{ .key = p.key, .value = value });
                replaced = true;
            } else {
                try props.append(allocator, p);
            }
        }
        if (!replaced) try props.append(allocator, .{ .key = key, .value = value });
        const owned = try props.toOwnedSlice(allocator);
        try owned_props.append(allocator, owned);
        try out.append(allocator, .{
            .ref_des = entry.ref_des,
            .uuid = entry.uuid,
            .component = entry.component,
            .value = entry.value,
            .source_fingerprint = entry.source_fingerprint,
            .id = entry.id,
            .nets = entry.nets,
            .properties = owned,
        });
    }

    if (!matched) {
        const new_uuid = try bom_mod.generateUuid(allocator);
        owned_uuid = new_uuid;
        const props = try allocator.alloc(Property, 1);
        try owned_props.append(allocator, props);
        props[0] = .{ .key = key, .value = value };
        try out.append(allocator, .{
            .ref_des = ref_des,
            .uuid = new_uuid,
            .component = "",
            .value = "",
            .source_fingerprint = "",
            .id = "",
            .nets = &.{},
            .properties = props,
        });
    }

    try writeBomEntries(allocator, bom_path, out.items);
}

// ── Phase C.2 tests ────────────────────────────────────────────────

const test_evaluator = @import("eval/evaluator.zig");

fn testDesignBlock(value: env_mod.Value) error{TestExpectedDesignBlock}!*DesignBlock {
    return switch (value) {
        .design_block => |block| block,
        else => error.TestExpectedDesignBlock,
    };
}

// spec: bom-resolve - identity resolution is a fixed point: two consecutive resolveIdentities calls produce a byte-identical BOM
test "resolveIdentities idempotent across two consecutive evaluations" {
    const alloc = std.heap.page_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(project_dir);

    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/cap.sexp",
        .data =
        \\(component-family cap
        \\  (param-type capacitance)
        \\  (footprint "0402"))
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/0402.sexp",
        .data =
        \\(component 0402 (footprint "0402.kicad_mod"))
        ,
    });

    try tmp.dir.createDirPath(std.testing.io, "src/sample");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/sample/sample.sexp",
        .data =
        \\(import cap)
        \\(design-block "Sample"
        \\  (instance "C1" (cap "100nF")
        \\    (id ab000001)
        \\    (pin 1 "VDD")
        \\    (pin 2 "GND"))
        \\  (instance "C2" (cap "100nF")
        \\    (id ab000002)
        \\    (pin 1 "VDD")
        \\    (pin 2 "GND"))
        \\  (instance "C3" (cap "100nF")
        \\    (id ab000003)
        \\    (pin 1 "V3V3")
        \\    (pin 2 "GND")))
        ,
    });

    const design_path = try std.fmt.allocPrint(alloc, "{s}/src/sample/sample.sexp", .{project_dir});
    defer alloc.free(design_path);
    const bom_path = try std.fmt.allocPrint(alloc, "{s}/src/sample/sample.bom", .{project_dir});
    defer alloc.free(bom_path);

    // Run 1: build from empty BOM
    {
        var eval = test_evaluator.Evaluator.init(alloc, project_dir);
        defer eval.deinit();
        const result = try eval.evalFile(design_path);
        const block = switch (result) {
            .design_block => |b| b,
            else => return error.TestExpectedDesignBlock,
        };
        try resolveIdentities(alloc, block, bom_path, project_dir);
    }
    const bom1 = try infra_fs.cwd().readFileAlloc(alloc, bom_path, 1024 * 1024);
    defer alloc.free(bom1);

    // Run 2: with the BOM from run 1 already on disk
    {
        var eval = test_evaluator.Evaluator.init(alloc, project_dir);
        defer eval.deinit();
        const result = try eval.evalFile(design_path);
        const block = switch (result) {
            .design_block => |b| b,
            else => return error.TestExpectedDesignBlock,
        };
        try resolveIdentities(alloc, block, bom_path, project_dir);
    }
    const bom2 = try infra_fs.cwd().readFileAlloc(alloc, bom_path, 1024 * 1024);
    defer alloc.free(bom2);

    try std.testing.expectEqualStrings(bom1, bom2);
}

// spec: bom-resolve - a stable id cannot carry an old MPN across a value or canonical-net change
test "resolveIdentities replaces stale same-id passive selection" {
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(project_dir);
    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.createDirPath(std.testing.io, "lib/parts");
    try tmp.dir.createDirPath(std.testing.io, "src/demo");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/cap.sexp",
        .data =
        \\(component-family cap
        \\  (param-type capacitance)
        \\  (footprint "0402"))
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/0402.sexp",
        .data = "(component 0402 (footprint \"0402.kicad_mod\"))\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/parts/cap.sexp",
        .data =
        \\(parts "cap"
        \\  (part "100pF" (manufacturer "Murata") (mpn "OLD-100") preferred)
        \\  (part "1000pF" (manufacturer "Murata") (mpn "NEW-1000") preferred))
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/demo/demo.sexp",
        .data =
        \\(import cap)
        \\(design-block "Demo"
        \\  (instance "C1" (cap "100pF")
        \\    (id e1d4ce3c)
        \\    (pin 1 "VDD_OLD")
        \\    (pin 2 "GND")))
        ,
    });
    const design_path = try std.fmt.allocPrint(alloc, "{s}/src/demo/demo.sexp", .{project_dir});
    defer alloc.free(design_path);
    const bom_path = try std.fmt.allocPrint(alloc, "{s}/src/demo/demo.bom", .{project_dir});
    defer alloc.free(bom_path);
    {
        var evaluator = test_evaluator.Evaluator.init(alloc, project_dir);
        defer evaluator.deinit();
        const evaluated = try evaluator.evalFile(design_path);
        const block = try testDesignBlock(evaluated);
        try resolveIdentities(alloc, block, bom_path, project_dir);
    }
    const initial = try infra_fs.cwd().readFileAlloc(alloc, bom_path, 1024 * 1024);
    defer alloc.free(initial);
    try std.testing.expect(std.mem.indexOf(u8, initial, "OLD-100") != null);
    try std.testing.expect(std.mem.indexOf(u8, initial, "source-fingerprint") != null);
    try std.testing.expect(std.mem.indexOf(u8, initial, "selected-part-row-fingerprint") != null);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/demo/demo.sexp",
        .data =
        \\(import cap)
        \\(design-block "Demo"
        \\  (instance "C1" (cap "1000pF")
        \\    (id e1d4ce3c)
        \\    (pin 1 "VDD_NEW")
        \\    (pin 2 "GND")))
        ,
    });
    {
        var evaluator = test_evaluator.Evaluator.init(alloc, project_dir);
        defer evaluator.deinit();
        const evaluated = try evaluator.evalFile(design_path);
        const block = try testDesignBlock(evaluated);
        try resolveIdentities(alloc, block, bom_path, project_dir);
    }
    const rewritten = try infra_fs.cwd().readFileAlloc(alloc, bom_path, 1024 * 1024);
    defer alloc.free(rewritten);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "NEW-1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "OLD-100") == null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "(value \"1000pF\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten, "VDD_NEW") != null);
}

// spec: bom-resolve - a fixed component sidecar cannot override source-authored manufacturer/MPN, including through differently-cased duplicate keys
test "fixed component rejects tampered BOM identity and case duplicate" {
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(project_dir);
    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.createDirPath(std.testing.io, "src/demo");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/fixed-chip.sexp",
        .data =
        \\(component fixed-chip
        \\  (footprint "chip-qfn")
        \\  (manufacturer "Acme")
        \\  (mpn "GOOD-MPN"))
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/demo/demo.sexp",
        .data =
        \\(import fixed-chip)
        \\(design-block "Demo"
        \\  (instance "U1" fixed-chip
        \\    (id f1ced001)
        \\    (pin 1 "VDD")
        \\    (pin 2 "GND")))
        ,
    });
    const design_path = try std.fmt.allocPrint(alloc, "{s}/src/demo/demo.sexp", .{project_dir});
    defer alloc.free(design_path);
    const bom_path = try std.fmt.allocPrint(alloc, "{s}/src/demo/demo.bom", .{project_dir});
    defer alloc.free(bom_path);
    {
        var evaluator = test_evaluator.Evaluator.init(alloc, project_dir);
        defer evaluator.deinit();
        const evaluated = try evaluator.evalFile(design_path);
        const block = try testDesignBlock(evaluated);
        try resolveIdentities(alloc, block, bom_path, project_dir);
    }
    try setBomProperty(alloc, bom_path, "U1", "mpn", "TAMPERED");
    try setBomProperty(alloc, bom_path, "U1", "MPN", "CASE-DUPLICATE");

    var evaluator = test_evaluator.Evaluator.init(alloc, project_dir);
    defer evaluator.deinit();
    const evaluated = try evaluator.evalFile(design_path);
    const block = try testDesignBlock(evaluated);
    try std.testing.expect(!(try existingSidecarMatches(alloc, block, bom_path, project_dir)));
    try applyExisting(alloc, block, bom_path, project_dir);
    try std.testing.expectEqualStrings("GOOD-MPN", propertyValue(block.instances[0].properties, "mpn").?);
    try std.testing.expectEqualStrings("Acme", propertyValue(block.instances[0].properties, "manufacturer").?);
}

// spec: bom-resolve - a non-passive component with a parts table round-trips its exact selected row instead of being mistaken for inline-only fixed identity
test "non-passive parts-table selection round trips exact row" {
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(project_dir);
    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.createDirPath(std.testing.io, "lib/parts");
    try tmp.dir.createDirPath(std.testing.io, "src/demo");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/regulator.sexp",
        .data =
        \\(component regulator
        \\  (footprint "reg-qfn")
        \\  (manufacturer "Acme")
        \\  (mpn "REG-1")
        \\  (rated-current "1A"))
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/parts/regulator.sexp",
        .data =
        \\(parts "regulator"
        \\  (part "" (manufacturer "Acme") (mpn "REG-1")
        \\    (thermal-class "high") preferred))
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/demo/demo.sexp",
        .data =
        \\(import regulator)
        \\(design-block "Demo"
        \\  (instance "U1" regulator
        \\    (id 2ab1e001)
        \\    (pin 1 "VIN")
        \\    (pin 2 "GND")))
        ,
    });
    const design_path = try std.fmt.allocPrint(alloc, "{s}/src/demo/demo.sexp", .{project_dir});
    defer alloc.free(design_path);
    const bom_path = try std.fmt.allocPrint(alloc, "{s}/src/demo/demo.bom", .{project_dir});
    defer alloc.free(bom_path);
    {
        var evaluator = test_evaluator.Evaluator.init(alloc, project_dir);
        defer evaluator.deinit();
        const evaluated = try evaluator.evalFile(design_path);
        const block = try testDesignBlock(evaluated);
        try resolveIdentities(alloc, block, bom_path, project_dir);
    }

    var evaluator = test_evaluator.Evaluator.init(alloc, project_dir);
    defer evaluator.deinit();
    const evaluated = try evaluator.evalFile(design_path);
    const block = try testDesignBlock(evaluated);
    try std.testing.expect(try existingSidecarMatches(alloc, block, bom_path, project_dir));
    try applyExisting(alloc, block, bom_path, project_dir);
    try std.testing.expectEqualStrings("REG-1", propertyValue(block.instances[0].properties, "mpn").?);
    try std.testing.expectEqualStrings("1A", propertyValue(block.instances[0].properties, "rated-current").?);
    try std.testing.expectEqualStrings("high", propertyValue(block.instances[0].properties, "thermal-class").?);

    try setBomProperty(alloc, bom_path, "U1", "rated-current", "10A");
    var tampered_evaluator = test_evaluator.Evaluator.init(alloc, project_dir);
    defer tampered_evaluator.deinit();
    const tampered_evaluated = try tampered_evaluator.evalFile(design_path);
    const tampered_block = try testDesignBlock(tampered_evaluated);
    try std.testing.expect(!(try existingSidecarMatches(alloc, tampered_block, bom_path, project_dir)));
    try applyExisting(alloc, tampered_block, bom_path, project_dir);
    try std.testing.expectEqualStrings("1A", propertyValue(tampered_block.instances[0].properties, "rated-current").?);
}

// spec: bom-resolve - a non-passive component with a parts table cannot fall back to inline fixed identity when its authored selection has no exact row
test "non-passive parts-table mismatch cannot use fixed identity fallback" {
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(project_dir);
    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.createDirPath(std.testing.io, "lib/parts");
    try tmp.dir.createDirPath(std.testing.io, "src/demo");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/regulator.sexp",
        .data =
        \\(component regulator
        \\  (footprint "reg-qfn")
        \\  (manufacturer "Acme")
        \\  (mpn "REG-INLINE")
        \\  (rated-current "1A"))
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/demo/demo.sexp",
        .data =
        \\(import regulator)
        \\(design-block "Demo"
        \\  (instance "U1" regulator
        \\    (id 2ab1e002)
        \\    (pin 1 "VIN")
        \\    (pin 2 "GND")))
        ,
    });
    const design_path = try std.fmt.allocPrint(alloc, "{s}/src/demo/demo.sexp", .{project_dir});
    defer alloc.free(design_path);
    const bom_path = try std.fmt.allocPrint(alloc, "{s}/src/demo/demo.bom", .{project_dir});
    defer alloc.free(bom_path);
    {
        var evaluator = test_evaluator.Evaluator.init(alloc, project_dir);
        defer evaluator.deinit();
        const evaluated = try evaluator.evalFile(design_path);
        const block = try testDesignBlock(evaluated);
        // The first build intentionally has no parts table, so it persists a
        // valid current-format inline-fixed row.
        try resolveIdentities(alloc, block, bom_path, project_dir);
    }
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/parts/regulator.sexp",
        .data =
        \\(parts "regulator"
        \\  (part "different-variant" (manufacturer "Acme") (mpn "REG-TABLE") preferred))
        ,
    });

    var evaluator = test_evaluator.Evaluator.init(alloc, project_dir);
    defer evaluator.deinit();
    const evaluated = try evaluator.evalFile(design_path);
    const block = try testDesignBlock(evaluated);
    try std.testing.expect(!(try existingSidecarMatches(alloc, block, bom_path, project_dir)));
}

// spec: bom-resolve - identity is deterministic: each part takes uuidFromId(its stable id), independent of any prior .bom contents
test "deterministic identity ignores a stale prior .bom" {
    const alloc = std.heap.page_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(project_dir);

    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/cap.sexp",
        .data =
        \\(component-family cap
        \\  (param-type capacitance)
        \\  (footprint "0402"))
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/0402.sexp",
        .data =
        \\(component 0402 (footprint "0402.kicad_mod"))
        ,
    });

    try tmp.dir.createDirPath(std.testing.io, "src/swap");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/swap/swap.sexp",
        .data =
        \\(import cap)
        \\(design-block "Swap"
        \\  (instance "C10" (cap "100nF")
        \\    (id aa000001)
        \\    (pin 1 "RAIL_A")
        \\    (pin 2 "GND"))
        \\  (instance "C11" (cap "100nF")
        \\    (id aa000002)
        \\    (pin 1 "RAIL_B")
        \\    (pin 2 "GND")))
        ,
    });

    const design_path = try std.fmt.allocPrint(alloc, "{s}/src/swap/swap.sexp", .{project_dir});
    defer alloc.free(design_path);
    const bom_path = try std.fmt.allocPrint(alloc, "{s}/src/swap/swap.bom", .{project_dir});
    defer alloc.free(bom_path);

    // Hand-craft a stale/swapped .bom. A deterministic resolver must ignore
    // it and re-derive each uuid from the part's own stable id.
    try infra_fs.cwd().writeFile(.{
        .sub_path = bom_path,
        .data =
        \\(part "C10" "11111111-1111-5111-9111-111111111111" "cap"
        \\  (id "aa000001")
        \\  (nets "GND" "RAIL_B"))
        \\(part "C11" "22222222-2222-5222-9222-222222222222" "cap"
        \\  (id "aa000002")
        \\  (nets "GND" "RAIL_A"))
        ,
    });

    // First resolve — Pass 3.5 should swap once.
    {
        var eval = test_evaluator.Evaluator.init(alloc, project_dir);
        defer eval.deinit();
        const result = try eval.evalFile(design_path);
        const block = switch (result) {
            .design_block => |b| b,
            else => return error.TestExpectedDesignBlock,
        };
        try resolveIdentities(alloc, block, bom_path, project_dir);
    }
    const bom1 = try infra_fs.cwd().readFileAlloc(alloc, bom_path, 1024 * 1024);
    defer alloc.free(bom1);

    // The swapped prior .bom is ignored: each part takes uuidFromId(its own id),
    // and the stale uuids from the prior .bom are gone.
    const uid10 = try export_kicad.uuidFromId(alloc, "aa000001");
    defer alloc.free(uid10);
    const uid11 = try export_kicad.uuidFromId(alloc, "aa000002");
    defer alloc.free(uid11);
    try std.testing.expect(std.mem.indexOf(u8, bom1, uid10) != null);
    try std.testing.expect(std.mem.indexOf(u8, bom1, uid11) != null);
    try std.testing.expect(std.mem.indexOf(u8, bom1, "11111111-1111-5111") == null);
}

// spec: bom-resolve - A property value containing a quote/backslash round-trips through the .bom without corrupting it
test "setBomProperty escapes a value with a quote and reloads cleanly" {
    // `writeBomEntries` escapes each quoted field with `kicad_format.sexprEscape`,
    // whose contract is an ARENA caller (the result is never individually freed) —
    // so run this on an arena rather than the raw testing allocator. The arena
    // itself is testing-allocator-backed, so a genuine leak still fails the test.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(dir_path);
    const bom_path = try std.fmt.allocPrint(alloc, "{s}/escape.bom", .{dir_path});
    defer alloc.free(bom_path);

    // A malicious/careless MPN edit with a raw quote and trailing backslash.
    const nasty = "MPN\"123\\";
    try setBomProperty(alloc, bom_path, "U1", "mpn", nasty);

    // loadBom must recover the ORIGINAL value (not `&.{}` from a parse failure,
    // which would silently drop every entry).
    const entries = try bom_mod.loadBom(alloc, bom_path);
    defer {
        for (entries) |e| {
            if (e.ref_des.len > 0) alloc.free(e.ref_des);
            if (e.uuid.len > 0) alloc.free(e.uuid);
            if (e.component.len > 0) alloc.free(e.component);
            if (e.value.len > 0) alloc.free(e.value);
            if (e.source_fingerprint.len > 0) alloc.free(e.source_fingerprint);
            if (e.id.len > 0) alloc.free(e.id);
            for (e.properties) |p| {
                alloc.free(p.key);
                alloc.free(p.value);
            }
            if (e.properties.len > 0) alloc.free(e.properties);
            for (e.nets) |n| alloc.free(n);
            if (e.nets.len > 0) alloc.free(e.nets);
        }
        alloc.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("U1", entries[0].ref_des);
    var got: ?[]const u8 = null;
    for (entries[0].properties) |p| {
        if (std.mem.eql(u8, p.key, "mpn")) got = p.value;
    }
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings(nasty, got.?);

    // Idempotency: re-writing the same value must not double-escape (the
    // load→save cycle stays a fixed point).
    try setBomProperty(alloc, bom_path, "U1", "mpn", got.?);
    const again = try bom_mod.loadBom(alloc, bom_path);
    defer {
        for (again) |e| {
            if (e.ref_des.len > 0) alloc.free(e.ref_des);
            if (e.uuid.len > 0) alloc.free(e.uuid);
            if (e.component.len > 0) alloc.free(e.component);
            if (e.value.len > 0) alloc.free(e.value);
            if (e.source_fingerprint.len > 0) alloc.free(e.source_fingerprint);
            if (e.id.len > 0) alloc.free(e.id);
            for (e.properties) |p| {
                alloc.free(p.key);
                alloc.free(p.value);
            }
            if (e.properties.len > 0) alloc.free(e.properties);
            for (e.nets) |n| alloc.free(n);
            if (e.nets.len > 0) alloc.free(e.nets);
        }
        alloc.free(again);
    }
    var got2: ?[]const u8 = null;
    for (again[0].properties) |p| {
        if (std.mem.eql(u8, p.key, "mpn")) got2 = p.value;
    }
    try std.testing.expect(got2 != null);
    try std.testing.expectEqualStrings(nasty, got2.?);
}
