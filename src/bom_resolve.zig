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
const FlatInfo = bom_mod.FlatInfo;

// ── Constants ─────────────────────────────────────────────────────
const MIN_TIE_BREAKER_OVERLAP: f64 = 0.5;
const STRONG_NET_MATCH_RATIO: f64 = 0.99;

/// Error set for the BOM-resolve pipeline. Combines BOM file IO (open/read/
/// write the .bom sidecar) with `OutOfMemory` from the various
/// `ArrayList`/`HashMap` operations.
pub const ResolveError = std.mem.Allocator.Error ||
    std.fs.File.OpenError ||
    std.fs.File.ReadError ||
    std.fs.File.WriteError ||
    error{ FileTooBig, StreamTooLong, EndOfStream };

/// Drop `manufacturer` and `mpn` from a property list. Used when the
/// component family on an instance changes: the UUID stays stable for PCB
/// identity, but the stored part info is now stale and must be re-resolved
/// from the new component's definition.
fn filterOutPartProps(allocator: std.mem.Allocator, props: []const Property) ![]const Property {
    var out: std.ArrayListUnmanaged(Property) = .empty;
    for (props) |p| {
        if (std.mem.eql(u8, p.key, "manufacturer")) continue;
        if (std.mem.eql(u8, p.key, "mpn")) continue;
        try out.append(allocator, p);
    }
    return out.toOwnedSlice(allocator);
}

/// Decide which properties from the old BOM entry to carry forward onto the
/// new instance. Same component → full passthrough. Different component
/// (family swap) → drop manufacturer/mpn so the new component's freshly-
/// evaluated values (or Pass 4's parts-DB lookup) take effect. Empty
/// `old_entry.component` is treated as "same" so legacy .bom files
/// written before saveBom started persisting the component field don't
/// lose their MPN/manufacturer on first reload — and so the inline
/// edit-mpn endpoint (which writes via setBomProperty without knowing
/// the component) keeps the user's edit until the next full save
/// migrates the entry.
fn carryForwardProps(
    allocator: std.mem.Allocator,
    props_map: *std.StringHashMap([]const Property),
    info: FlatInfo,
    old_entry: bom_mod.BomEntry,
) !void {
    if (old_entry.properties.len == 0) return;
    const same_component = old_entry.component.len == 0 or
        std.mem.eql(u8, old_entry.component, info.component);
    const props_to_keep = if (same_component)
        old_entry.properties
    else
        try filterOutPartProps(allocator, old_entry.properties);
    if (props_to_keep.len == 0) return;
    try props_map.put(info.ref_des, props_to_keep);
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
            if (e.id.len > 0) allocator.free(e.id);
            for (e.properties) |p| {
                allocator.free(p.key);
                allocator.free(p.value);
            }
            if (e.properties.len > 0) allocator.free(e.properties);
        }
        allocator.free(old_entries);
    }

    var flat_list: std.ArrayListUnmanaged(FlatInfo) = .empty;
    defer flat_list.deinit(allocator);
    try bom_mod.collectFlatInstances(allocator, block, "", &flat_list);

    var old_by_ref = std.StringHashMap(usize).init(allocator);
    defer old_by_ref.deinit();
    for (old_entries, 0..) |e, i| {
        try old_by_ref.put(e.ref_des, i);
    }

    var claimed = try allocator.alloc(bool, old_entries.len);
    defer allocator.free(claimed);
    @memset(claimed, false);

    var result_map = std.StringHashMap([]const u8).init(allocator);
    defer result_map.deinit();
    var props_map = std.StringHashMap([]const Property).init(allocator);
    defer props_map.deinit();

    // Pass 0: match by (id ...)
    var old_by_id = std.StringHashMap(usize).init(allocator);
    defer old_by_id.deinit();
    for (old_entries, 0..) |e, i| {
        if (e.id.len > 0) try old_by_id.put(e.id, i);
    }
    for (flat_list.items) |info| {
        if (info.id.len > 0) {
            if (old_by_id.get(info.id)) |idx| {
                if (!claimed[idx]) {
                    try result_map.put(info.ref_des, try allocator.dupe(u8, old_entries[idx].uuid));
                    try carryForwardProps(allocator, &props_map, info, old_entries[idx]);
                    claimed[idx] = true;
                }
            }
        }
    }

    // Pass 1: exact ref_des match
    for (flat_list.items) |info| {
        if (result_map.contains(info.ref_des)) continue;
        if (old_by_ref.get(info.ref_des)) |idx| {
            if (claimed[idx]) continue;
            try result_map.put(info.ref_des, try allocator.dupe(u8, old_entries[idx].uuid));
            try carryForwardProps(allocator, &props_map, info, old_entries[idx]);
            claimed[idx] = true;
        }
    }

    // Pass 2: rename detection
    for (flat_list.items) |info| {
        if (result_map.contains(info.ref_des)) continue;
        var best_idx: ?usize = null;
        var sole_match: ?usize = null;
        var same_component_count: usize = 0;
        for (old_entries, 0..) |old, idx| {
            if (claimed[idx]) continue;
            if (std.mem.eql(u8, old.component, info.component)) {
                same_component_count += 1;
                sole_match = idx;
            }
        }
        if (same_component_count == 1) best_idx = sole_match;

        if (best_idx) |idx| {
            try result_map.put(info.ref_des, try allocator.dupe(u8, old_entries[idx].uuid));
            if (old_entries[idx].properties.len > 0) {
                try props_map.put(info.ref_des, old_entries[idx].properties);
            }
            claimed[idx] = true;
        }
    }

    // Pass 2.5: match by net overlap
    for (flat_list.items) |info| {
        if (result_map.contains(info.ref_des)) continue;
        if (info.nets.len == 0) continue;
        var best_idx: ?usize = null;
        var best_overlap: f64 = 0.0;
        var best_count: usize = 0;
        for (old_entries, 0..) |old, idx| {
            if (claimed[idx]) continue;
            if (old.nets.len == 0) continue;
            const overlap = bom_mod.netOverlap(info.nets, old.nets);
            if (overlap > best_overlap or (overlap == best_overlap and overlap > MIN_TIE_BREAKER_OVERLAP)) {
                best_overlap = overlap;
                best_idx = idx;
                best_count = 0;
            }
            if (overlap == best_overlap) best_count += 1;
        }
        if (best_idx) |idx| {
            if (best_overlap >= STRONG_NET_MATCH_RATIO and best_count == 1) {
                try result_map.put(info.ref_des, try allocator.dupe(u8, old_entries[idx].uuid));
                if (old_entries[idx].properties.len > 0) {
                    try props_map.put(info.ref_des, old_entries[idx].properties);
                }
                claimed[idx] = true;
            }
        }
    }

    // Pass 3: derive a stable UUID from the instance's stable id. This makes
    // new UUID assignments deterministic, so a given logical instance always
    // gets the same UUID regardless of when the BOM first sees it or how
    // global ref_des numbering shifts across builds. Random generateUuid is
    // only used as a last resort for instances that somehow lack an id.
    for (flat_list.items) |info| {
        if (result_map.contains(info.ref_des)) continue;
        const uuid = if (info.id.len > 0)
            try export_kicad.uuidFromId(allocator, info.id)
        else
            try bom_mod.generateUuid(allocator);
        try result_map.put(info.ref_des, uuid);
    }

    // Pass 3.5: correct UUID assignments by net matching.
    //
    // Phase C.2: collect every proposed swap first, then apply in one go.
    // The previous implementation mutated `result_map` as it iterated, which
    // meant a swap A↔B done early could enable a follow-on B↔C swap that
    // would have been wrong with the original state — the pass produced
    // different terminal states depending on visit order, and on the next
    // eval it would re-fire the inverse correction, causing the user-visible
    // `set_pad_net` flip-flop documented in docs/kicad-sync-phase-c.md.
    //
    // The fix: stage swaps in a list, then drop any cluster where one
    // ref_des wants to swap with two distinct partners (a sign that net
    // signatures don't bijectively partition the candidates — applying a
    // partial chain would leave the BOM worse off than skipping). Apply the
    // remaining bijective swaps in one pass.
    try runPass35Swaps(allocator, &result_map, flat_list.items, old_entries);

    // Pass 4: auto-resolve manufacturer + MPN from parts DB
    var parts_db = parts_mod.PartsDb.init(allocator, project_dir);
    defer parts_db.deinit();

    for (flat_list.items) |info| {
        if (props_map.get(info.ref_des)) |existing_props| {
            var has_mpn = false;
            for (existing_props) |p| {
                if (std.mem.eql(u8, p.key, "mpn")) {
                    has_mpn = true;
                    break;
                }
            }
            if (has_mpn) continue;
        }
        if (info.footprint.len == 0) {
            if (info.value.len > 0) {
                log.warn("{s} uses unsized family '{s}' — no footprint or MPN resolution", .{ info.ref_des, info.component });
            }
            continue;
        }
        var has_mpn_from_component = false;
        for (info.properties) |p| {
            if (std.mem.eql(u8, p.key, "mpn")) {
                has_mpn_from_component = true;
                break;
            }
        }
        if (has_mpn_from_component) continue;

        if (parts_db.lookup(info.component, info.value, info.attrs)) |part| {
            var new_props: std.ArrayListUnmanaged(Property) = .empty;
            if (props_map.get(info.ref_des)) |existing| {
                for (existing) |p| try new_props.append(allocator, p);
            }
            if (part.manufacturer.len > 0) {
                try new_props.append(allocator, .{
                    .key = try allocator.dupe(u8, "manufacturer"),
                    .value = try allocator.dupe(u8, part.manufacturer),
                });
            }
            if (part.mpn.len > 0) {
                try new_props.append(allocator, .{
                    .key = try allocator.dupe(u8, "mpn"),
                    .value = try allocator.dupe(u8, part.mpn),
                });
            }
            try props_map.put(info.ref_des, try new_props.toOwnedSlice(allocator));
        }
    }

    try applyBom(allocator, block, &result_map, &props_map, "");
    try saveBom(allocator, bom_path, flat_list.items, &result_map, &props_map);
}

/// Phase C.2: Pass 3.5 reimplemented as a fixed-point swap collector.
///
/// Step 1: for every instance whose currently-assigned UUID has a weak net
/// overlap with its old BOM entry, look up the UUID whose old-BOM net
/// signature matches the instance's new signature. If some *other* ref_des
/// in the new flat list currently holds that UUID, record a proposed swap
/// `(a_ref ↔ b_ref)`.
///
/// Step 2: walk the swap list once and build a partner map. If a ref_des
/// is named in two swaps with different partners, log a warning and mark
/// the whole cluster as ambiguous — those swaps will not fire.
///
/// Step 3: apply every non-ambiguous bijective swap exactly once.
///
/// Step 4: re-check each instance against its old-by-uuid entry; if a
/// weak-overlap mismatch survived (no swap candidate or the swap was
/// dropped as ambiguous), log a warning. Repeated `eda kicad-sync` calls
/// will re-emit the same correction at this point — failing loud beats
/// silent flip-flop.
fn runPass35Swaps(
    allocator: std.mem.Allocator,
    result_map: *std.StringHashMap([]const u8),
    flat: []const FlatInfo,
    old_entries: []const bom_mod.BomEntry,
) ResolveError!void {
    var old_by_netsig = std.StringHashMap(usize).init(allocator);
    defer old_by_netsig.deinit();
    for (old_entries, 0..) |old, idx| {
        if (old.nets.len == 0) continue;
        const sig = bom_mod.netSignature(allocator, old.nets) catch continue;
        try old_by_netsig.put(sig, idx);
    }

    const Swap = struct { a_ref: []const u8, b_ref: []const u8 };
    var swaps: std.ArrayListUnmanaged(Swap) = .empty;
    defer swaps.deinit(allocator);

    for (flat) |info| {
        if (info.nets.len == 0) continue;
        const assigned_uuid = result_map.get(info.ref_des) orelse continue;

        var assigned_old_idx: ?usize = null;
        for (old_entries, 0..) |old, idx| {
            if (std.mem.eql(u8, old.uuid, assigned_uuid)) {
                assigned_old_idx = idx;
                break;
            }
        }
        const old_idx = assigned_old_idx orelse continue;
        const old = old_entries[old_idx];
        if (old.nets.len == 0) continue;

        if (bom_mod.netOverlap(info.nets, old.nets) >= STRONG_NET_MATCH_RATIO) continue;

        const new_sig = bom_mod.netSignature(allocator, info.nets) catch continue;
        const correct_old_idx = old_by_netsig.get(new_sig) orelse continue;
        const correct_uuid = old_entries[correct_old_idx].uuid;

        var other_ref: ?[]const u8 = null;
        for (flat) |other| {
            if (std.mem.eql(u8, other.ref_des, info.ref_des)) continue;
            const other_uuid = result_map.get(other.ref_des) orelse continue;
            if (std.mem.eql(u8, other_uuid, correct_uuid)) {
                other_ref = other.ref_des;
                break;
            }
        }

        if (other_ref) |oref| {
            try swaps.append(allocator, .{ .a_ref = info.ref_des, .b_ref = oref });
        }
    }

    // Cycle detection: if any ref_des appears in two swaps with distinct
    // partners, the bijection assumption is broken — drop the whole cluster.
    var partner = std.StringHashMap([]const u8).init(allocator);
    defer partner.deinit();
    var ambiguous = std.StringHashMap(void).init(allocator);
    defer ambiguous.deinit();

    for (swaps.items) |sw| {
        try recordPartner(&partner, &ambiguous, sw.a_ref, sw.b_ref);
        try recordPartner(&partner, &ambiguous, sw.b_ref, sw.a_ref);
    }

    // Apply bijective swaps once. The `applied` set keeps a swap from being
    // executed twice when both endpoints appear as `info.ref_des` in the
    // collection pass.
    var applied = std.StringHashMap(void).init(allocator);
    defer applied.deinit();
    for (swaps.items) |sw| {
        if (ambiguous.contains(sw.a_ref) or ambiguous.contains(sw.b_ref)) continue;
        if (applied.contains(sw.a_ref)) continue;
        const a_uuid = result_map.get(sw.a_ref) orelse continue;
        const b_uuid = result_map.get(sw.b_ref) orelse continue;
        const a_dup = try allocator.dupe(u8, a_uuid);
        const b_dup = try allocator.dupe(u8, b_uuid);
        result_map.putAssumeCapacity(sw.a_ref, b_dup);
        result_map.putAssumeCapacity(sw.b_ref, a_dup);
        try applied.put(sw.a_ref, {});
        try applied.put(sw.b_ref, {});
    }

    // Residual check: any ref_des that proposed a swap but was dropped as
    // ambiguous (cluster cycle) will keep its weak-overlap UUID and re-fire
    // the same correction next sync. Warn loudly — failing visible beats
    // silent flip-flop. No-op swaps (both endpoints already have the same
    // uuid because the legacy BOM has duplicates) are intentionally quiet:
    // they're stable across rebuilds and re-warning every eval just adds
    // noise — the underlying duplicate-uuid cleanup belongs to Phase C.3.
    for (swaps.items) |sw| {
        if (!ambiguous.contains(sw.a_ref) and !ambiguous.contains(sw.b_ref)) continue;
        const assigned_uuid = result_map.get(sw.a_ref) orelse continue;
        log.warn(
            "Pass 3.5: {s} kept assigned uuid={s} — swap with {s} dropped as ambiguous; re-sync will re-emit",
            .{ sw.a_ref, assigned_uuid, sw.b_ref },
        );
    }
}

fn recordPartner(
    partner: *std.StringHashMap([]const u8),
    ambiguous: *std.StringHashMap(void),
    ref: []const u8,
    other: []const u8,
) std.mem.Allocator.Error!void {
    if (ambiguous.contains(ref)) {
        try ambiguous.put(other, {});
        return;
    }
    const existing = partner.get(ref);
    if (existing) |prev| {
        if (std.mem.eql(u8, prev, other)) return;
        log.warn(
            "Pass 3.5: {s} appears in conflicting swaps ({s} vs {s}) — skipping cluster",
            .{ ref, prev, other },
        );
        try ambiguous.put(ref, {});
        try ambiguous.put(prev, {});
        try ambiguous.put(other, {});
        return;
    }
    try partner.put(ref, other);
}

fn applyBom(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    uuid_map: *const std.StringHashMap([]const u8),
    props_map: *const std.StringHashMap([]const Property),
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
                var merged: std.ArrayListUnmanaged(Property) = .empty;
                for (inst.properties) |cp| {
                    var overridden = false;
                    for (bom_props) |ip| {
                        if (std.mem.eql(u8, cp.key, ip.key)) {
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
                inst.properties = try merged.toOwnedSlice(allocator);
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
    uuid_map: *const std.StringHashMap([]const u8),
    props_map: *const std.StringHashMap([]const Property),
) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll(";; BOM — auto-generated by eda build\n");
    try w.writeAll(";; Stores identity and properties per instance\n\n");

    for (flat_instances) |info| {
        const uuid = uuid_map.get(info.ref_des) orelse continue;
        const props = props_map.get(info.ref_des) orelse info.properties;

        try w.print("(part \"{s}\" \"{s}\" \"{s}\"\n", .{ info.ref_des, uuid, info.component });
        try w.print("  (id \"{s}\")\n", .{info.id});
        if (info.nets.len > 0) {
            try w.writeAll("  (nets");
            for (info.nets) |net| {
                try w.print(" \"{s}\"", .{net});
            }
            try w.writeAll(")\n");
        }
        for (props) |p| {
            if (std.mem.eql(u8, p.key, "footprint") or
                std.mem.eql(u8, p.key, "value")) continue;
            try w.print("  ({s} \"{s}\")\n", .{ p.key, p.value });
        }
        try w.writeAll(")\n");
    }

    const f = try infra_fs.cwd().createFile(bom_path, .{});
    defer f.close();
    try f.writeAll(buf.items);
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
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll(";; BOM — auto-generated by eda build\n");
    try w.writeAll(";; Stores identity and properties per instance\n\n");

    for (entries) |entry| {
        // entry.component may be "" for a brand-new stub from setBomProperty
        // or for a legacy .bom that pre-dates the component field. The next
        // full saveBom (after a design rebuild) re-populates it from FlatInfo.
        try w.print("(part \"{s}\" \"{s}\" \"{s}\"\n", .{ entry.ref_des, entry.uuid, entry.component });
        if (entry.id.len > 0) try w.print("  (id \"{s}\")\n", .{entry.id});
        if (entry.nets.len > 0) {
            try w.writeAll("  (nets");
            for (entry.nets) |net| try w.print(" \"{s}\"", .{net});
            try w.writeAll(")\n");
        }
        for (entry.properties) |p| {
            if (std.mem.eql(u8, p.key, "footprint") or std.mem.eql(u8, p.key, "value")) continue;
            try w.print("  ({s} \"{s}\")\n", .{ p.key, p.value });
        }
        try w.writeAll(")\n");
    }

    const f = try infra_fs.cwd().createFile(bom_path, .{});
    defer f.close();
    try f.writeAll(buf.items);
}

/// Error set for `setBomProperty`. Combines `bom.loadBom`'s read-side
/// errors with the write-side errors from `writeBomEntries`.
pub const SetPropertyError = bom_mod.BomError || std.fs.File.WriteError;

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

    var out: std.ArrayListUnmanaged(bom_mod.BomEntry) = .empty;
    defer out.deinit(allocator);

    var matched = false;
    for (old_entries) |entry| {
        if (!std.mem.eql(u8, entry.ref_des, ref_des)) {
            try out.append(allocator, entry);
            continue;
        }
        matched = true;
        var props: std.ArrayListUnmanaged(Property) = .empty;
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
        try out.append(allocator, .{
            .ref_des = entry.ref_des,
            .uuid = entry.uuid,
            .component = entry.component,
            .id = entry.id,
            .nets = entry.nets,
            .properties = try props.toOwnedSlice(allocator),
        });
    }

    if (!matched) {
        const new_uuid = try bom_mod.generateUuid(allocator);
        const props = try allocator.alloc(Property, 1);
        props[0] = .{ .key = key, .value = value };
        try out.append(allocator, .{
            .ref_des = ref_des,
            .uuid = new_uuid,
            .component = "",
            .id = "",
            .nets = &.{},
            .properties = props,
        });
    }

    try writeBomEntries(allocator, bom_path, out.items);
}

// ── Phase C.2 tests ────────────────────────────────────────────────

const test_evaluator = @import("eval/evaluator.zig");

// spec: bom-resolve - Pass 3.5 is a fixed point: two consecutive resolveIdentities calls produce a byte-identical BOM
test "resolveIdentities idempotent across two consecutive evaluations" {
    const alloc = std.heap.page_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(project_dir);

    try tmp.dir.makePath("lib/components");
    try tmp.dir.writeFile(.{
        .sub_path = "lib/components/cap.sexp",
        .data =
        \\(component-family cap
        \\  (param-type capacitance)
        \\  (footprint "0402"))
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "lib/components/0402.sexp",
        .data =
        \\(component 0402 (footprint "0402.kicad_mod"))
        ,
    });

    try tmp.dir.makePath("src/sample");
    try tmp.dir.writeFile(.{
        .sub_path = "src/sample/sample.sexp",
        .data =
        \\(design-block "Sample"
        \\  (instance "C1" (cap "100nF")
        \\    (pin 1 "VDD")
        \\    (pin 2 "GND"))
        \\  (instance "C2" (cap "100nF")
        \\    (pin 1 "VDD")
        \\    (pin 2 "GND"))
        \\  (instance "C3" (cap "100nF")
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

// spec: bom-resolve - Pass 3.5 with a forced two-instance UUID swap converges on the first call and stays put on the second
test "Pass 3.5 swap converges in one call" {
    const alloc = std.heap.page_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(project_dir);

    try tmp.dir.makePath("lib/components");
    try tmp.dir.writeFile(.{
        .sub_path = "lib/components/cap.sexp",
        .data =
        \\(component-family cap
        \\  (param-type capacitance)
        \\  (footprint "0402"))
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "lib/components/0402.sexp",
        .data =
        \\(component 0402 (footprint "0402.kicad_mod"))
        ,
    });

    try tmp.dir.makePath("src/swap");
    try tmp.dir.writeFile(.{
        .sub_path = "src/swap/swap.sexp",
        .data =
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

    // Hand-craft a BOM that ties each ref_des to the OTHER instance's UUID
    // (a deliberately swapped state) so Pass 3.5 has to perform exactly one
    // bijective correction.
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

    // Second resolve — must be a no-op now that the swap converged.
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
