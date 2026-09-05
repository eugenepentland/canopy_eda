//! The design-hierarchy flatten and the currency types it produces: what a
//! resolved `DesignBlock` collapses into once its `(sub-block …)` tree is
//! joined into `sub-block/REF` names and its `(net …)` ties are merged.
//!
//! This sits BENEATH every layer that wants a flat netlist — the KiCad netlist
//! and schematic exporters, `src/placement/*` (which computes a board from the
//! flat pin/net lists), the fab/gerber writers, the diagram engine and the
//! server. It was all declared in `export_kicad.zig` / `export_kicad_netlist.zig`
//! for want of a neutral home, so every placement module that needed a
//! `FlatPin` — or the same flatten the exporter runs — had to import an
//! exporter and reach UP a layer.
//!
//! Nothing here knows about KiCad, about placement, or about any output format.
//! Walking a hierarchy and merging ties is not a serialization concern, and
//! `uuidFromId` is a hash of a stable id, not a file format. The module depends
//! only on `std` and `eval/env.zig`, so it can be imported from any side
//! without a cycle. Both former homes re-export every name they used to
//! declare, so existing callers are untouched.

const std = @import("std");
const env_mod = @import("eval/env.zig");
const uuid = @import("uuid.zig");
const na = @import("eval/net_analysis.zig");
const Property = env_mod.Property;
const DesignBlock = env_mod.DesignBlock;

/// One component flattened out of the design hierarchy for KiCad export:
/// the joined `sub-block/REF` reference designator plus the value,
/// footprint, properties, and stable UUID written into the `.net` file.
pub const FlatInstance = struct {
    ref_des: []const u8,
    component: []const u8,
    /// Pinout lookup keys (`lib/pinouts/<key>.sexp`), carried from the source
    /// instance so post-flatten consumers — e.g. the placement optimizer's
    /// supply-pin detection — can resolve pin functions. Default "" so the
    /// netlist/export paths that build `FlatInstance` literals may omit them.
    symbol: []const u8 = "",
    pinout: []const u8 = "",
    /// The instance's stable source name (the first arg of `(instance …)`),
    /// carried through ref-des renumbering. Lets post-flatten consumers — e.g.
    /// the placement optimizer's `(placement-order …)` resolution — match a part
    /// by the name the design author wrote, not its volatile auto-assigned
    /// ref-des. Default "" so literal builders may omit it.
    origin_key: []const u8 = "",
    value: []const u8,
    footprint: []const u8,
    properties: []const Property,
    uuid: []const u8,
    /// Do Not Populate — carried from the source instance's `(dnp)` flag.
    /// Default false so literal builders may omit it. Already reflects the
    /// SELECTED assembly variant; `variants` below says why.
    dnp: bool = false,
    /// The part's assembly-variant clauses, carried from the source instance so
    /// a flattened listing can report the population matrix. Default empty so
    /// literal builders may omit it.
    variants: env_mod.InstanceVariants = .{},
    /// The part's authored PLACEMENT bindings — the hub pad a cap `(decouples …)`
    /// and the pad a passive declares itself `(near …)` — carried straight from
    /// the source instance (`env_mod.InstanceBinds`, which documents each).
    ///
    /// Every ref NAMED inside carries the same `sub-block/` prefix `ref_des`
    /// gets: a part and the part it names are siblings in one block, so the
    /// naming part's own prefix qualifies both. That matters because a pad
    /// number ALONE is ambiguous — a pad belongs to exactly one part, but a rail
    /// shared by several ICs has several parts carrying a pad of that number,
    /// and matching on the string picks whichever the net happens to list first.
    bind: env_mod.InstanceBinds = .{},
    /// The part's `(check (max-distance …))` requirements, already resolved
    /// against the built block (`req_physical_checks.resolveDistanceRules`):
    /// pad, candidate ref-des, budget. Carried so the layout lint can measure
    /// a datasheet placement rule without loading a pinout or parsing a
    /// component value. Default empty, like `bind`, so literal builders may
    /// omit it.
    distance_rules: []const env_mod.DistanceRule = &.{},
};

/// One net in the flattened design with a hierarchically-prefixed name and
/// the list of `FlatPin`s connected to it. Net ties from `applyNetTies`
/// merge multiple `FlatNet`s into one before the netlist is emitted.
pub const FlatNet = struct {
    name: []const u8,
    pins: []const FlatPin,
};

/// One `(node (ref …) (pin …))` entry in a KiCad netlist: the flattened
/// component reference designator and the physical pad name on the
/// component's footprint.
pub const FlatPin = struct {
    ref_des: []const u8,
    pin: []const u8,
};

// ── Design-hierarchy flattening ───────────────────────────────────────────

/// Derive a full UUID (36-char) from an 8-char hex ID by hashing it. Only the
/// digest is this module's; the version/variant stamping and the canonical
/// text form are `uuid.format`'s, shared with `bom.generateUuid`, so a part's
/// identity is spelled the same however it was minted.
pub fn uuidFromId(allocator: std.mem.Allocator, id: []const u8) std.mem.Allocator.Error![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("canopy:");
    hasher.update(id);
    const hash = hasher.finalResult();
    var bytes: [16]u8 = undefined;
    @memcpy(&bytes, hash[0..16]);
    return uuid.format(allocator, bytes, .name_v5);
}

// spec: bom - Derives a stable UUID from an instance id
test "uuidFromId pins the identity KiCad sync keys on" {
    const alloc = std.testing.allocator;
    const got = try uuidFromId(alloc, "aa000001");
    defer alloc.free(got);
    // Frozen on purpose: this string IS the part identity carried across the
    // .bom sidecar, the KiCad schematic and the board. Changing the digest,
    // the "canopy:" prefix or the text form re-identifies every existing part.
    try std.testing.expectEqualStrings("11d1e8b6-ab30-561d-9ee4-8da03a84febb", got);
}

fn prefixed(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) std.mem.Allocator.Error![]const u8 {
    if (prefix.len == 0) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });
}

/// `prefixed`, but an EMPTY name stays empty: a binding that names nothing must
/// not become the bare sub-block prefix, which would read as a real ref.
fn prefixedOrEmpty(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) std.mem.Allocator.Error![]const u8 {
    if (name.len == 0) return "";
    return prefixed(allocator, prefix, name);
}

/// Re-prefix every candidate ref-des in a part's resolved distance rules, so
/// a rule declared inside a module names the flattened parts the lint will
/// measure rather than a same-named part in another sub-block.
fn prefixedDistanceRules(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    rules: []const env_mod.DistanceRule,
) std.mem.Allocator.Error![]const env_mod.DistanceRule {
    if (rules.len == 0 or prefix.len == 0) return rules;
    const out = try allocator.alloc(env_mod.DistanceRule, rules.len);
    for (rules, out) |rule, *slot| {
        const refs = try allocator.alloc([]const u8, rule.candidates.len);
        for (rule.candidates, refs) |ref, *dest| dest.* = try prefixed(allocator, prefix, ref);
        slot.* = rule;
        slot.candidates = refs;
    }
    return out;
}

/// Walk the design tree and append a `FlatInstance` for every component,
/// joining `prefix` onto each ref-des as it descends into sub-blocks so
/// references stay unique. Each instance carries the BOM-assigned UUID
/// when available, falling back to a hash of the stable 8-char id.
pub fn collectInstances(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    prefix: []const u8,
    list: *std.ArrayList(FlatInstance),
) std.mem.Allocator.Error!void {
    for (block.instances) |inst| {
        const ref = try prefixed(allocator, prefix, inst.ref_des);

        // Use BOM-assigned UUID if available, otherwise derive from ID
        const effective_uuid = if (inst.uuid.len > 0)
            inst.uuid
        else if (inst.id.len > 0)
            (uuidFromId(allocator, inst.id) catch "")
        else
            "";

        try list.append(allocator, .{
            .ref_des = ref,
            .component = inst.component,
            .symbol = inst.symbol,
            .pinout = inst.pinout,
            .origin_key = inst.origin_key,
            .value = inst.value,
            .footprint = inst.footprint,
            .properties = inst.properties,
            .uuid = effective_uuid,
            .dnp = inst.dnp,
            .variants = inst.variants,
            // A `(decouples "IC" …)` / `(near "REF" …)` names a ref in the
            // part's OWN block, so it takes exactly the prefix the part's
            // ref-des takes — anything else would resolve to a same-named part
            // in another sub-block.
            .bind = .{
                .decouple = .{
                    .pin = inst.bind.decouple.pin,
                    .ic = try prefixedOrEmpty(allocator, prefix, inst.bind.decouple.ic),
                    .rail = inst.bind.decouple.rail,
                },
                .near = .{
                    .ref = try prefixedOrEmpty(allocator, prefix, inst.bind.near.ref),
                    .pin = inst.bind.near.pin,
                    .own = inst.bind.near.own,
                },
            },
            // A distance rule's candidates are siblings in the part's OWN
            // block, so they take exactly the prefix its ref-des takes — the
            // same reasoning `bind` records just above.
            .distance_rules = try prefixedDistanceRules(allocator, prefix, inst.distance_rules),
        });
    }
    for (block.sub_blocks) |sb| {
        const sub_prefix = try prefixed(allocator, prefix, sb.name);
        try collectInstances(allocator, sb.block, sub_prefix, list);
    }
}

/// Recurse through the design tree and append a `FlatNet` per net, prefixing
/// both the net name and each pin's ref-des with `prefix` so sub-block-local
/// nets stay distinct before `applyNetTies` merges them onto the canonical
/// top-level name.
pub fn collectNets(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    prefix: []const u8,
    list: *std.ArrayList(FlatNet),
) std.mem.Allocator.Error!void {
    for (block.nets) |net| {
        const net_name = try prefixed(allocator, prefix, net.name);

        var pins = try allocator.alloc(FlatPin, net.pins.len);
        for (net.pins, 0..) |pin, i| {
            pins[i] = .{
                .ref_des = try prefixed(allocator, prefix, pin.ref_des),
                .pin = pin.pin,
            };
        }

        try list.append(allocator, .{
            .name = net_name,
            .pins = pins,
        });
    }
    for (block.sub_blocks) |sb| {
        const sub_prefix = try prefixed(allocator, prefix, sb.name);
        try collectNets(allocator, sb.block, sub_prefix, list);
    }
}

/// One side-to-side net-tie collected from the design hierarchy: `a` and
/// `b` are net names (already prefixed by sub-block path) that
/// `applyNetTies` should treat as the same electrical net when merging
/// the flat netlist.
pub const FlatTie = struct {
    a: []const u8,
    b: []const u8,
};

/// Every pre-merge net/tie name mapped to the final canonical flattened net
/// name selected by `applyNetTiesMapped`. Consumers that attach metadata to a
/// module-local net (for example inherited net-class membership) use this map
/// to follow that metadata through `(bridge (rename ...))` / `(net ...)` ties.
pub const CanonicalNetMap = std.StringHashMapUnmanaged([]const u8);

/// Gather (net "A" "B" ...) ties from the block tree, prefixing each side with
/// the sub-block path so they can be matched against names in the flat net
/// list produced by `collectNets`.
pub fn collectNetTies(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    prefix: []const u8,
    list: *std.ArrayList(FlatTie),
) std.mem.Allocator.Error!void {
    for (block.net_ties) |t| {
        const a = try prefixed(allocator, prefix, t.a);
        const b = try prefixed(allocator, prefix, t.b);
        try list.append(allocator, .{ .a = a, .b = b });
    }
    for (block.sub_blocks) |sb| {
        const sub_prefix = try prefixed(allocator, prefix, sb.name);
        try collectNetTies(allocator, sb.block, sub_prefix, list);
    }
}

/// Prefer topmost (fewest slashes), then shortest, then lexicographic.
fn preferName(candidate: []const u8, incumbent: []const u8) bool {
    const cs = std.mem.count(u8, candidate, "/");
    const is_ = std.mem.count(u8, incumbent, "/");
    if (cs != is_) return cs < is_;
    if (candidate.len != incumbent.len) return candidate.len < incumbent.len;
    return std.mem.lessThan(u8, candidate, incumbent);
}

const NetTieSets = struct {
    allocator: std.mem.Allocator,
    index: std.StringHashMapUnmanaged(u32) = .empty,
    names: std.ArrayList([]const u8) = .empty,
    parent: std.ArrayList(u32) = .empty,

    fn deinit(self: *NetTieSets) void {
        self.index.deinit(self.allocator);
        self.names.deinit(self.allocator);
        self.parent.deinit(self.allocator);
    }

    fn getOrAdd(self: *NetTieSets, name: []const u8) std.mem.Allocator.Error!u32 {
        const gop = try self.index.getOrPut(self.allocator, name);
        if (gop.found_existing) return gop.value_ptr.*;
        const i: u32 = @intCast(self.names.items.len);
        try self.names.append(self.allocator, name);
        try self.parent.append(self.allocator, i);
        gop.value_ptr.* = i;
        return i;
    }

    fn find(self: *NetTieSets, idx: u32) u32 {
        var i = idx;
        while (self.parent.items[i] != i) : (i = self.parent.items[i]) {}
        var j = idx;
        while (self.parent.items[j] != i) {
            const next = self.parent.items[j];
            self.parent.items[j] = i;
            j = next;
        }
        return i;
    }
};

fn writeCanonicalAliases(
    allocator: std.mem.Allocator,
    out: *CanonicalNetMap,
    sets: *NetTieSets,
    canonical: *const std.AutoHashMapUnmanaged(u32, u32),
    nets: []const FlatNet,
    per_pin: *const std.StringHashMapUnmanaged([]const u8),
) std.mem.Allocator.Error!void {
    for (sets.names.items, 0..) |name, i| {
        const canon_i = canonical.get(sets.find(@intCast(i))) orelse continue;
        try out.put(allocator, name, sets.names.items[canon_i]);
    }
    for (nets) |net| if (per_pin.get(net.name)) |name| try out.put(allocator, net.name, name);
}

/// Merge nets in `nets` according to `ties`. A tie `(a, b)` means the two net
/// names refer to the same electrical net. Per-pin split nets of the form
/// `<base>.<ref>.<pin>` get renamed alongside their base when the base is
/// merged, so `buck/VIN.U12.VIN_1` follows `buck/VIN` → `VBATT` to become
/// `VBATT.U12.VIN_1` (still a separate micro-net for decoupling, but rooted on
/// the right parent name).
pub fn applyNetTies(
    allocator: std.mem.Allocator,
    nets: *std.ArrayList(FlatNet),
    ties: []const FlatTie,
) std.mem.Allocator.Error!void {
    return applyNetTiesMapped(allocator, nets, ties, null);
}

/// `applyNetTies` plus an optional old-name → canonical-name result. The map is
/// arena-friendly and owned by the caller; when supplied it receives entries
/// for unchanged names too, so a private module net and a bridged port share one
/// lookup contract.
pub fn applyNetTiesMapped(
    allocator: std.mem.Allocator,
    nets: *std.ArrayList(FlatNet),
    ties: []const FlatTie,
    aliases: ?*CanonicalNetMap,
) std.mem.Allocator.Error!void {
    if (ties.len == 0 and nets.items.len == 0) return;

    var sets = NetTieSets{ .allocator = allocator };
    defer sets.deinit();

    // A name is "live" (eligible to be the canonical net name) if either it
    // has pins, or it's on the LHS of a tie — i.e., the user wrote it as the
    // preferred name in a `(net "LHS" "rhs" ...)` form. Without this, a tie
    // LHS like `PG_3V3` (all its pins come in through other nets) would be
    // dropped from canonical selection and a sub-block-prefixed RHS would
    // win. RHS names aren't marked live because auto-aliases created by
    // symbol pin-function lookup can produce junk names like "1" or "5"
    // that would otherwise hijack shorter-wins preference.
    var live_names: std.StringHashMapUnmanaged(void) = .empty;
    defer live_names.deinit(allocator);
    for (nets.items) |net| {
        _ = try sets.getOrAdd(net.name);
        try live_names.put(allocator, net.name, {});
    }
    for (ties) |t| {
        const ai = try sets.getOrAdd(t.a);
        const bi = try sets.getOrAdd(t.b);
        try live_names.put(allocator, t.a, {});
        const ra = sets.find(ai);
        const rb = sets.find(bi);
        if (ra != rb) sets.parent.items[rb] = ra;
    }

    // Canonical name per root — only among names that actually have pins.
    var canonical: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer canonical.deinit(allocator);
    for (sets.names.items, 0..) |nm, i| {
        if (!live_names.contains(nm)) continue;
        const root = sets.find(@intCast(i));
        const existing = canonical.get(root);
        if (existing) |best_i| {
            if (preferName(nm, sets.names.items[best_i])) {
                try canonical.put(allocator, root, @intCast(i));
            }
        } else {
            try canonical.put(allocator, root, @intCast(i));
        }
    }

    // old_name → canonical_name (only when they differ). If a root has no
    // live name (all tie-only), skip — nothing to rename.
    var rename_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer rename_map.deinit(allocator);
    for (sets.names.items, 0..) |nm, i| {
        const root = sets.find(@intCast(i));
        const canon_i = canonical.get(root) orelse continue;
        const canon_name = sets.names.items[canon_i];
        if (!std.mem.eql(u8, nm, canon_name)) {
            try rename_map.put(allocator, nm, canon_name);
        }
    }

    // Rename per-pin split nets: <base>.<ref>.<pin> inherits base's new name.
    var per_pin_renames: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer per_pin_renames.deinit(allocator);
    for (nets.items) |net| {
        const base = na.baseNetName(net.name);
        if (base.len == net.name.len) continue;
        const suffix = net.name[base.len..];
        const canon_base = rename_map.get(base) orelse continue;
        const new_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ canon_base, suffix });
        try per_pin_renames.put(allocator, net.name, new_name);
    }

    if (aliases) |out| try writeCanonicalAliases(allocator, out, &sets, &canonical, nets.items, &per_pin_renames);

    // Rebuild nets list, merging pins by canonical name.
    var merged: std.array_hash_map.String(std.ArrayList(FlatPin)) = .empty;
    defer {
        var it = merged.iterator();
        while (it.next()) |e| e.value_ptr.deinit(allocator);
        merged.deinit(allocator);
    }

    for (nets.items) |net| {
        const canon = if (per_pin_renames.get(net.name)) |pn|
            pn
        else if (rename_map.get(net.name)) |rn|
            rn
        else
            net.name;
        const gop = try merged.getOrPut(allocator, canon);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (net.pins) |p| try gop.value_ptr.append(allocator, p);
    }

    nets.clearRetainingCapacity();
    var mit = merged.iterator();
    while (mit.next()) |entry| {
        try nets.append(allocator, .{
            .name = entry.key_ptr.*,
            .pins = try entry.value_ptr.toOwnedSlice(allocator),
        });
    }
}

/// Flatten a design's `(sub-block …)` hierarchy into `sub-block/`-prefixed
/// nets and merge its `(net …)` ties, leaving `nets` holding one entry per
/// canonical electrical net. The spelling every ordinary caller wants; use
/// `flattenAndMergeNetsMapped` when you also need to follow a module-local
/// name to the canonical one it merged into.
pub fn flattenAndMergeNets(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    nets: *std.ArrayList(FlatNet),
) std.mem.Allocator.Error!void {
    return flattenAndMergeNetsMapped(allocator, block, nets, null);
}

/// Flatten/merge a design while optionally returning every hierarchy-local net
/// alias mapped to its final canonical name. This is the metadata bridge used by
/// inherited net classes; ordinary exporters keep calling the wrapper above.
pub fn flattenAndMergeNetsMapped(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    nets: *std.ArrayList(FlatNet),
    aliases: ?*CanonicalNetMap,
) std.mem.Allocator.Error!void {
    try collectNets(allocator, block, "", nets);
    var ties: std.ArrayList(FlatTie) = .empty;
    defer ties.deinit(allocator);
    try collectNetTies(allocator, block, "", &ties);
    try applyNetTiesMapped(allocator, nets, ties.items, aliases);
}

// spec: export_kicad - Declares the flattened-netlist currency types in a neutral module beneath both the export and placement layers

test "flatten currency types default their optional fields" {
    const pin: FlatPin = .{ .ref_des = "U1", .pin = "3" };
    try std.testing.expectEqualStrings("U1", pin.ref_des);
    try std.testing.expectEqualStrings("3", pin.pin);

    const net: FlatNet = .{ .name = "VDD", .pins = &.{pin} };
    try std.testing.expectEqual(@as(usize, 1), net.pins.len);

    // Every field a literal builder is allowed to omit keeps its documented
    // default, so a `FlatInstance` built by the netlist writer and one built by
    // a placement fixture describe the same part.
    const inst: FlatInstance = .{
        .ref_des = "C1",
        .component = "cap-0402",
        .value = "100nF",
        .footprint = "c-0402",
        .properties = &.{},
        .uuid = "",
    };
    try std.testing.expectEqualStrings("", inst.symbol);
    try std.testing.expectEqualStrings("", inst.pinout);
    try std.testing.expectEqualStrings("", inst.origin_key);
    try std.testing.expect(!inst.dnp);
    try std.testing.expectEqualStrings("", inst.bind.decouple.pin);
    try std.testing.expectEqualStrings("", inst.bind.decouple.ic);
    try std.testing.expect(!inst.bind.decouple.rail);
    try std.testing.expectEqualStrings("", inst.bind.near.ref);
    try std.testing.expectEqualStrings("", inst.bind.near.pin);
    try std.testing.expectEqualStrings("", inst.bind.near.own);
}
