const std = @import("std");
const log = @import("../infra/log.zig");
const env_mod = @import("../eval/env.zig");
const DesignBlock = env_mod.DesignBlock;
const PinRef = env_mod.PinRef;
const draw = @import("draw.zig");
const isHub = draw.isHub;
const isGroundNet = draw.isGroundNet;
const baseNetName = draw.baseNetName;
const shortNetName = draw.shortNetName;

/// Check if a ref-des is a standard format (1-2 uppercase letters + digits), e.g. U10, R5, C3.
fn isStdRefDes(ref: []const u8) bool {
    if (ref.len < 2) return false;
    var i: usize = 0;
    // 1-2 uppercase letters
    while (i < ref.len and i < 2 and ref[i] >= 'A' and ref[i] <= 'Z') : (i += 1) {}
    if (i == 0) return false;
    // At least one digit
    const digit_start = i;
    while (i < ref.len and ref[i] >= '0' and ref[i] <= '9') : (i += 1) {}
    return i == ref.len and i > digit_start;
}

/// Sub-block origin of a flattened ref-des: everything before the last '/'
/// (the path of the sub-block that contains the part), or "" for a top-level
/// instance. Two parts with different origins live in different sub-blocks.
fn originOf(ref: []const u8) []const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, ref, '/') orelse return "";
    return ref[0..idx];
}

const Allocator = std.mem.Allocator;

// ── Flat types ────────────────────────────────────────────────────────

/// Schematic-renderer view of an instance after sub-block flattening:
/// path-qualified ref-des plus the few fields the renderer actually uses
/// (component, value, symbol, parts, requirements). Strips evaluator-only
/// metadata so the render context can be built without copying everything.
pub const FlatInst = struct {
    ref_des: []const u8,
    component: []const u8,
    value: []const u8,
    symbol: []const u8,
    /// Footprint name (matches `lib/footprints/<name>.sexp`), copied off the
    /// Instance so the sidebar can fetch a footprint-preview SVG without a
    /// second library parse. Empty for synthetic sub-block hubs.
    footprint: []const u8 = "",
    /// Pinout name (matches `lib/pinouts/<name>.sexp`), copied off the
    /// Instance so the hub renderer can label pins by their component
    /// function name even for flat `(pin …)` instances that carry no
    /// part-level pin names. Empty for synthetic sub-block hubs.
    pinout: []const u8 = "",
    parts: []const env_mod.Part = &.{},
    /// Library-declared rules for using this part, copied off the Instance at
    /// eval time. Lets the schematic renderer emit a per-hub "Requirements"
    /// dropdown without a second library parse.
    requirements: []const env_mod.Requirement = &.{},
    /// Manufacturer part number lookup from `(property "mpn" "...")` —
    /// surfaced in the sidebar search index so designers can find an
    /// instance by typing an MPN substring (e.g. "STM32N657").
    mpn: []const u8 = "",
    /// Manufacturer name from `(property "manufacturer" "...")` —
    /// also fed to the search index.
    manufacturer: []const u8 = "",
    /// Byte offset of the defining form in the *top-level design source*,
    /// copied off `Instance.source_offset`. Drives the sidebar's
    /// "Edit source →" jump. 0 means "no source link": sub-block children
    /// (their offsets point into the module file, which `/api/source/:name`
    /// can't serve) and synthetic instances.
    src_offset: u32 = 0,
    /// `(decouples "IC" PIN)` binding, copied off the Instance. Lets the
    /// spoke-attachment pass dock a bypass cap on the one hub pad it serves
    /// instead of fanning it onto every pin of the rail (the schematic twin of
    /// the per-pad binding the PCB placer already honors). `decouple_ic` is the
    /// (module-local) hub ref and `decouple_pin` the resolved pad; both empty
    /// when the cap declares no binding. `decouple_rail` marks a rail-level
    /// reservoir (`(decouples rail)`) — shown once on the rail, not per pin.
    decouple_ic: []const u8 = "",
    decouple_pin: []const u8 = "",
    decouple_rail: bool = false,
};

fn propertyValue(props: []const env_mod.Property, key: []const u8) []const u8 {
    for (props) |p| {
        if (std.mem.eql(u8, p.key, key)) return p.value;
    }
    return "";
}

/// Schematic-renderer view of a net after sub-block flattening — name plus
/// the list of pin refs that touch it. Equivalent of `env_mod.Net` once
/// hierarchy paths have been collapsed.
pub const FlatNet = struct {
    name: []const u8,
    pins: []const PinRef,
};

/// Which side of a hub a connection should render to. Drives whether the
/// chain extends leftward or rightward and whether labels are end-anchored
/// or start-anchored.
pub const Side = enum { left, right };

/// An endpoint in the adjacency list.
pub const Endpoint = union(enum) {
    net: []const u8,
    pin: struct { ref_des: []const u8, pin: []const u8 },
};

/// A connection entry: (pin_id, endpoint).
pub const AdjEntry = struct {
    pin: []const u8,
    endpoint: Endpoint,
};

/// Branch: chain of instances + terminal net name.
pub const Branch = struct {
    chain: []const FlatInst,
    terminal: []const u8,
};

/// One rendered passive-chain stub: the x-coordinate of its furthest-out
/// component, the y-coordinate the chain sits at, and the terminal net or
/// pin name to label its open end with. Collected then post-processed so
/// terminals on the same net group into one shared label.
pub const BranchBody = struct {
    end_x: f64,
    cy: f64,
    terminal: []const u8,
};

/// Pin group for hub rendering.
pub const PinGroup = struct {
    display_name: []const u8,
    pin_numbers: []const u8,
    /// One label per rendered stub, parallel to `stub_pins`. A uniquely-named
    /// pin's label is its component function name; pins sharing a function-name
    /// stem on this net (GND_1, GND_2, …) collapse into one "<stem>_(<N>)"
    /// label. Pins with no pinout name (label == pin id) never collapse.
    stub_labels: []const []const u8 = &.{},
    /// Comma-joined physical pin ids backing each stub (parallel to
    /// `stub_labels`); a comma means the stub stands for several pins.
    stub_pins: []const []const u8 = &.{},
    conns: []const AdjEntry,
    /// Feature-group label propagated from `(pins ref (group "X") ...)`.
    /// Only the HTML unified card uses this; empty for ungrouped pins.
    group: []const u8 = "",
};

// ── Render Context ────────────────────────────────────────────────────

/// All the pre-computed lookup tables the SVG schematic renderer needs:
/// flattened instances + nets, hub/spoke classification, adjacency lists,
/// per-pin canonical net mapping, port-net set, and the section→index
/// table that drives section-aware label placement. Built once via
/// `collectFlat` + helpers, then fed to the per-hub render passes.
pub const RenderCtx = struct {
    allocator: Allocator,
    /// Project directory for locating lib/pinouts/*.sexp (empty if unavailable).
    project_dir: []const u8 = "",
    instances: std.ArrayListUnmanaged(FlatInst),
    nets: std.ArrayListUnmanaged(FlatNet),
    hub_order: std.ArrayListUnmanaged([]const u8),
    inst_map: std.StringHashMapUnmanaged(FlatInst),
    spoke_set: std.StringHashMapUnmanaged(void),
    pin_net: std.StringHashMapUnmanaged([]const u8),
    adjacency: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(AdjEntry)),
    net_index: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(PinRef)),
    significant_nets: std.StringHashMapUnmanaged(void),
    /// Base names of (non-ground) nets shared across two or more sub-blocks —
    /// i.e. global rails/buses, not local passive junctions. The spoke-chain
    /// walker terminates and labels these instead of fanning out into every
    /// passive on the rail (which would pull in sibling sub-blocks' identical
    /// networks). Populated by `buildSignificantNets`.
    shared_rail_nets: std.StringHashMapUnmanaged(void),
    port_nets: std.StringHashMapUnmanaged(void),
    pin_canonical_nets: std.StringHashMapUnmanaged([]const u8),
    rendered_spokes: std.StringHashMapUnmanaged(void),
    section_map: std.StringHashMapUnmanaged(usize),
    /// Spoke ref-des → the base net name it should be drawn off (its "anchor"
    /// side). Populated for a 2-terminal passive that bridges a net with a
    /// single hub pin and a net with several hub pins: it renders off the
    /// single-pin side (e.g. a BOOT pull-up at the MCU's lone BOOT pin) instead
    /// of being buried among the busy rail's pins. See `computeSpokeAnchors`.
    spoke_anchor_net: std.StringHashMapUnmanaged([]const u8),

    pub fn init(allocator: Allocator) RenderCtx {
        return .{
            .allocator = allocator,
            .instances = .empty,
            .nets = .empty,
            .hub_order = .empty,
            .inst_map = .empty,
            .spoke_set = .empty,
            .pin_net = .empty,
            .adjacency = .empty,
            .net_index = .empty,
            .significant_nets = .empty,
            .shared_rail_nets = .empty,
            .port_nets = .empty,
            .pin_canonical_nets = .empty,
            .rendered_spokes = .empty,
            .section_map = .empty,
            .spoke_anchor_net = .empty,
        };
    }

    // ── Data collection ───────────────────────────────────────────────

    /// Build a net rename map from a block's net_ties, prefixed appropriately.
    /// A tie (a="VDD", b="buck/VOUT") at prefix="" means: rename net "buck/VOUT" to "VDD".
    fn buildNetRenameMap(self: *RenderCtx, block: *const DesignBlock, prefix: []const u8) !std.StringHashMap([]const u8) {
        var net_rename = std.StringHashMap([]const u8).init(self.allocator);
        for (block.net_ties) |nt| {
            const full_b = if (prefix.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, nt.b })
            else
                nt.b;
            const full_a = if (prefix.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, nt.a })
            else
                nt.a;
            try net_rename.put(full_b, full_a);
        }
        return net_rename;
    }

    /// Resolve a net name through a chain of rename maps (parent → grandparent → ...).
    /// For qualified names like "ldo/VIN.U1.IN", also tries resolving the base
    /// part "ldo/VIN" and preserves the suffix ".U1.IN".
    fn resolveNetName(allocator: std.mem.Allocator, net_name: []const u8, rename_maps: []const std.StringHashMap([]const u8)) []const u8 {
        // Try exact match first
        var resolved = net_name;
        for (rename_maps) |m| {
            if (m.get(resolved)) |renamed| {
                resolved = renamed;
            }
        }
        if (!std.mem.eql(u8, resolved, net_name)) return resolved;

        // Try resolving the base part (before first '.') with suffix preserved
        // e.g., "ldo/VIN.U1.IN" → try "ldo/VIN" → "VDD" → "VDD.U1.IN"
        if (std.mem.indexOfScalar(u8, net_name, '/')) |slash_idx| {
            const after_slash = net_name[slash_idx + 1 ..];
            if (std.mem.indexOfScalar(u8, after_slash, '.')) |dot_idx| {
                const base = net_name[0 .. slash_idx + 1 + dot_idx];
                const suffix = after_slash[dot_idx..];
                var base_resolved = base;
                for (rename_maps) |m| {
                    if (m.get(base_resolved)) |renamed| {
                        base_resolved = renamed;
                    }
                }
                if (!std.mem.eql(u8, base_resolved, base)) {
                    // Concatenate resolved base + suffix
                    return std.fmt.allocPrint(
                        allocator,
                        "{s}{s}",
                        .{ base_resolved, suffix },
                    ) catch net_name;
                }
            }
        }
        return resolved;
    }

    /// Run the full flatten → classify → adjacency → net-index pipeline that
    /// every renderer needs before it can walk the scene. Shared verbatim by
    /// `render_html.setupRenderCtx` and `render_json.renderSceneGraph` (the
    /// latter also calls `validateNetConsistency` afterward). The section map
    /// records each instance/pin-group's flat section index so cross-section
    /// detection works for multipart hubs. `project_dir` is set by the caller
    /// (before or after this call, matching each renderer's existing order).
    pub fn setup(self: *RenderCtx, block: *const DesignBlock) std.mem.Allocator.Error!void {
        try self.collectFlat(block, "");
        var flat_sec_idx: usize = 0;
        for (block.sections) |sec| {
            for (sec.instances) |inst| try self.section_map.put(self.allocator, inst.ref_des, flat_sec_idx);
            for (sec.pin_groups) |pg| {
                if (!self.section_map.contains(pg.ref_des)) {
                    try self.section_map.put(self.allocator, pg.ref_des, flat_sec_idx);
                }
            }
            flat_sec_idx += 1;
            for (sec.sub_sections) |sub| {
                for (sub.instances) |inst| try self.section_map.put(self.allocator, inst.ref_des, flat_sec_idx);
                for (sub.pin_groups) |pg| {
                    if (!self.section_map.contains(pg.ref_des)) {
                        try self.section_map.put(self.allocator, pg.ref_des, flat_sec_idx);
                    }
                }
                flat_sec_idx += 1;
            }
        }
        for (block.sub_blocks) |sb| {
            for (sb.block.instances) |inst| try self.section_map.put(self.allocator, inst.ref_des, flat_sec_idx);
            flat_sec_idx += 1;
        }
        try self.buildPinNetMap();
        try self.classify();
        try self.buildAdjacency();
        try self.synthesizeSpokeConnections();
        try self.buildNetIndex();
        try self.buildSignificantNets(block);
        try self.buildPinCanonicalNets();
    }

    pub fn collectFlat(self: *RenderCtx, block: *const DesignBlock, prefix: []const u8) !void {
        try self.collectFlatWithRenames(block, prefix, &.{});
    }

    fn collectFlatWithRenames(self: *RenderCtx, block: *const DesignBlock, prefix: []const u8, parent_renames: []const std.StringHashMap([]const u8)) !void {
        // Build rename map for this block's net_ties
        const my_rename = try self.buildNetRenameMap(block, prefix);
        // Combine with parent rename maps
        var all_renames: std.ArrayListUnmanaged(std.StringHashMap([]const u8)) = .empty;
        try all_renames.append(self.allocator, my_rename);
        for (parent_renames) |pr| {
            try all_renames.append(self.allocator, pr);
        }

        for (block.instances) |inst| {
            // Use global ref-des as-is (no prefix) if it's a standard ref-des (e.g., U10, R5)
            const rd = if (prefix.len > 0 and !isStdRefDes(inst.ref_des))
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, inst.ref_des })
            else
                inst.ref_des;
            const flat = FlatInst{
                .ref_des = rd,
                .component = inst.component,
                .value = inst.value,
                .symbol = inst.symbol,
                .footprint = inst.footprint,
                .pinout = inst.pinout,
                .parts = inst.parts,
                .requirements = inst.requirements,
                .mpn = propertyValue(inst.properties, "mpn"),
                .manufacturer = propertyValue(inst.properties, "manufacturer"),
                // Sub-block instances evaluate out of their module file, so
                // their offsets don't map into the design source — only
                // top-level (unprefixed) instances get a source link.
                .src_offset = if (prefix.len == 0) inst.source_offset else 0,
                .decouple_ic = inst.decouple_ic,
                .decouple_pin = inst.decouple_pin,
                .decouple_rail = inst.decouple_rail,
            };
            try self.instances.append(self.allocator, flat);
            try self.inst_map.put(self.allocator, rd, flat);
        }
        for (block.nets) |net| {
            var pins: std.ArrayListUnmanaged(PinRef) = .empty;
            for (net.pins) |pin| {
                const rd = if (prefix.len > 0 and !isStdRefDes(pin.ref_des))
                    try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, pin.ref_des })
                else
                    pin.ref_des;
                try pins.append(self.allocator, .{ .ref_des = rd, .pin = pin.pin });
            }
            var net_name = if (prefix.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, net.name })
            else
                net.name;
            // Apply cross-block net rename through all ancestor rename maps
            net_name = resolveNetName(self.allocator, net_name, all_renames.items);
            try self.nets.append(self.allocator, .{
                .name = net_name,
                .pins = try pins.toOwnedSlice(self.allocator),
            });
        }
        for (block.sub_blocks) |sb| {
            const np = if (prefix.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, sb.name })
            else
                sb.name;

            // Expand sub-block: flatten internal components into the schematic
            try self.collectFlatWithRenames(sb.block, np, all_renames.items);
        }
    }

    pub fn buildPinNetMap(self: *RenderCtx) !void {
        for (self.nets.items) |net| {
            for (net.pins) |pin| {
                const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ pin.ref_des, pin.pin });
                try self.pin_net.put(self.allocator, key, net.name);
            }
        }
    }

    pub fn classify(self: *RenderCtx) !void {
        for (self.instances.items) |inst| {
            if (isHub(inst)) {
                try self.hub_order.append(self.allocator, inst.ref_des);
            } else {
                try self.spoke_set.put(self.allocator, inst.ref_des, {});
            }
        }
    }

    pub fn buildAdjacency(self: *RenderCtx) !void {
        for (self.nets.items) |net| {
            const bn = baseNetName(net.name);
            for (net.pins) |pin| {
                try self.adjAppend(pin.ref_des, .{
                    .pin = pin.pin,
                    .endpoint = .{ .net = bn },
                });
            }
        }
    }

    /// A 2-terminal passive bridging a single-hub-pin net and a multi-hub-pin
    /// net belongs on its single-pin side. For each spoke, gather the distinct
    /// non-ground nets it touches; when there are exactly two and one has a lone
    /// hub pin while the other has two or more, record that lone-pin net as the
    /// spoke's anchor. `synthesizeSpokeConnections` then attaches the spoke only
    /// to its anchor net's hub, so it renders off that pin (e.g. a BOOT pull-up
    /// at the MCU's BOOT pin) and labels the busy rail at its far end instead.
    ///
    /// Only set the anchor when the spoke would actually attach to that lone hub
    /// under the section-preference rules below (same section, or one side has
    /// no section). Otherwise leave default behaviour so the spoke never ends up
    /// attached to neither side.
    fn computeSpokeAnchors(self: *RenderCtx) !void {
        const a = self.allocator;

        // Per base-net: hub-pin count, and the lone hub pin when the count is 1.
        var hub_count: std.StringHashMapUnmanaged(u32) = .empty;
        var sole_hub: std.StringHashMapUnmanaged(PinRef) = .empty;
        for (self.nets.items) |net| {
            const bn = baseNetName(net.name);
            for (net.pins) |pin| {
                if (self.spoke_set.contains(pin.ref_des)) continue;
                const gop = try hub_count.getOrPut(a, bn);
                gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) + 1;
                try sole_hub.put(a, bn, pin); // only read back when the count is 1
            }
        }

        // Per spoke: the distinct non-ground base nets its pins touch.
        var spoke_nets: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
        for (self.nets.items) |net| {
            const bn = baseNetName(net.name);
            if (isGroundNet(bn)) continue;
            for (net.pins) |pin| {
                if (!self.spoke_set.contains(pin.ref_des)) continue;
                const gop = try spoke_nets.getOrPut(a, pin.ref_des);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                var present = false;
                for (gop.value_ptr.items) |n| {
                    if (std.mem.eql(u8, n, bn)) {
                        present = true;
                        break;
                    }
                }
                if (!present) try gop.value_ptr.append(a, bn);
            }
        }

        var it = spoke_nets.iterator();
        while (it.next()) |kv| {
            const nets = kv.value_ptr.items;
            if (nets.len != 2) continue;
            const c0 = hub_count.get(nets[0]) orelse 0;
            const c1 = hub_count.get(nets[1]) orelse 0;

            // One side a lone hub pin, the other two or more.
            const anchor_net: ?[]const u8 = if (c0 == 1 and c1 >= 2)
                nets[0]
            else if (c1 == 1 and c0 >= 2)
                nets[1]
            else
                null;

            if (anchor_net) |an| {
                const hp = sole_hub.get(an) orelse continue;
                const ss = self.section_map.get(kv.key_ptr.*);
                const hs = self.section_map.get(hp.ref_des);
                if (ss == null or hs == null or ss.? == hs.?) {
                    try self.spoke_anchor_net.put(a, kv.key_ptr.*, an);
                }
            }
        }
    }

    /// The single hub pin a `(decouples …)` cap should dock on, chosen among
    /// `hubs` (the hub pins on the cap's current net). Returns null when the
    /// spoke declares no binding, or its bound pad isn't among this net's hub
    /// pins (a cross-net binding) — the caller then applies the default
    /// rail-wide fan-out so the spoke is never dropped.
    ///
    ///  - `(decouples "IC" PAD)` → the hub pin whose pad == PAD. An exact
    ///    `decouple_ic` ref match wins (non-renumbered designs); otherwise the
    ///    first pad match (the ref churns when a module flattens into a parent —
    ///    U1→U13 — but the physical pad number is stable, and net membership
    ///    already scopes the search to this rail).
    ///  - `(decouples rail)` → one representative pin on the rail's busiest hub,
    ///    so a reservoir shows once instead of reserving height on every pin.
    fn boundHubPin(self: *RenderCtx, spoke_ref: []const u8, hubs: []const PinRef) ?PinRef {
        const fi = self.inst_map.get(spoke_ref) orelse return null;
        if (fi.decouple_pin.len > 0) {
            var pad_match: ?PinRef = null;
            for (hubs) |hp| {
                if (!std.mem.eql(u8, hp.pin, fi.decouple_pin)) continue;
                if (fi.decouple_ic.len > 0 and std.mem.eql(u8, hp.ref_des, fi.decouple_ic)) return hp;
                if (pad_match == null) pad_match = hp;
            }
            return pad_match;
        }
        if (fi.decouple_rail) {
            // Pick the hub with the most pins on this net (the main consumer),
            // and dock on its first pin.
            var best: ?PinRef = null;
            var best_count: usize = 0;
            for (hubs) |cand| {
                var count: usize = 0;
                for (hubs) |hp| {
                    if (std.mem.eql(u8, hp.ref_des, cand.ref_des)) count += 1;
                }
                if (count > best_count) {
                    best_count = count;
                    best = cand;
                }
            }
            return best;
        }
        return null;
    }

    pub fn synthesizeSpokeConnections(self: *RenderCtx) !void {
        try self.computeSpokeAnchors();
        for (self.nets.items) |net| {
            const bn = baseNetName(net.name);
            if (isGroundNet(bn)) continue;

            const short = shortNetName(net.name);
            const hub_target: ?[]const u8 = blk: {
                const first_dot = std.mem.indexOfScalar(u8, short, '.') orelse break :blk null;
                const rest = short[first_dot + 1 ..];
                const second_dot = std.mem.indexOfScalar(u8, rest, '.') orelse break :blk null;
                break :blk rest[0..second_dot];
            };

            // Grow-as-needed rather than a fixed 64-slot buffer: a wide MCU
            // power rail can land on well over 64 pads or carry more than 64
            // per-pin bypass caps, and dropping the overflow silently produced
            // a wrong schematic (missing spokes reported as floating). All of
            // this is arena-backed, freed when the render context is torn down.
            var hub_pins: std.ArrayListUnmanaged(PinRef) = .empty;
            var spoke_pins: std.ArrayListUnmanaged(PinRef) = .empty;

            for (net.pins) |pin| {
                if (self.spoke_set.contains(pin.ref_des)) {
                    const is_ground_pin = self.isSpokeGroundPin(pin.ref_des, pin.pin);
                    if (!is_ground_pin) {
                        try spoke_pins.append(self.allocator, pin);
                    }
                } else {
                    try hub_pins.append(self.allocator, pin);
                }
            }

            if (hub_target != null and hub_pins.items.len == 0) {
                for (self.nets.items) |other_net| {
                    if (std.mem.eql(u8, other_net.name, net.name)) continue;
                    if (!std.mem.eql(u8, baseNetName(other_net.name), bn)) continue;
                    for (other_net.pins) |pin| {
                        if (!self.spoke_set.contains(pin.ref_des) and
                            std.mem.eql(u8, pin.ref_des, hub_target.?))
                        {
                            try hub_pins.append(self.allocator, pin);
                        }
                    }
                }
            }

            for (spoke_pins.items) |sp| {
                // Anchored spoke (single-pin-side passive): attach only on its
                // anchor net so it renders off the lone pin, not the busy rail.
                if (self.spoke_anchor_net.get(sp.ref_des)) |anchor| {
                    if (!std.mem.eql(u8, anchor, bn)) continue;
                }

                // `(decouples "IC" PAD)` / `(decouples rail)` binding: dock the
                // cap on the one hub pad it serves (or one rail pin for a
                // reservoir) instead of fanning it onto every pin of the rail.
                // This distributes per-pin bypass caps to the part bucket that
                // owns their pad and stops the reserved-height pile-up where one
                // group claims every cap on a multi-pad rail. The net-name
                // `<rail>.<ic>.<pad>` convention (from the (decouple per-pin …)
                // shorthand) is handled separately via `hub_target` above;
                // this covers the explicit (decouples …) form, which keeps the
                // cap on the plain rail net.
                if (self.boundHubPin(sp.ref_des, hub_pins.items)) |bp| {
                    try self.adjAppend(bp.ref_des, .{
                        .pin = bp.pin,
                        .endpoint = .{ .pin = .{ .ref_des = sp.ref_des, .pin = sp.pin } },
                    });
                    try self.adjAppend(sp.ref_des, .{
                        .pin = sp.pin,
                        .endpoint = .{ .pin = .{ .ref_des = bp.ref_des, .pin = bp.pin } },
                    });
                    continue;
                }

                const spoke_section = self.section_map.get(sp.ref_des);

                // When the spoke has a section, prefer hubs in the same section.
                // Only fall back to hubs without a section if no same-section hub exists.
                if (spoke_section) |ss| {
                    var has_same_section_hub = false;
                    for (hub_pins.items) |hp| {
                        if (hub_target) |target| {
                            if (!std.mem.eql(u8, hp.ref_des, target)) continue;
                        }
                        const hs = self.section_map.get(hp.ref_des);
                        if (hs != null and hs.? == ss) {
                            has_same_section_hub = true;
                            break;
                        }
                    }

                    for (hub_pins.items) |hp| {
                        if (hub_target) |target| {
                            if (!std.mem.eql(u8, hp.ref_des, target)) continue;
                        }
                        const hub_section = self.section_map.get(hp.ref_des);
                        if (hub_section) |hs| {
                            if (ss != hs) continue;
                        } else if (has_same_section_hub) {
                            // Skip hubs without a section when same-section hubs are available
                            continue;
                        }
                        try self.adjAppend(hp.ref_des, .{
                            .pin = hp.pin,
                            .endpoint = .{ .pin = .{ .ref_des = sp.ref_des, .pin = sp.pin } },
                        });
                        try self.adjAppend(sp.ref_des, .{
                            .pin = sp.pin,
                            .endpoint = .{ .pin = .{ .ref_des = hp.ref_des, .pin = hp.pin } },
                        });
                    }
                } else {
                    for (hub_pins.items) |hp| {
                        if (hub_target) |target| {
                            if (!std.mem.eql(u8, hp.ref_des, target)) continue;
                        }
                        try self.adjAppend(hp.ref_des, .{
                            .pin = hp.pin,
                            .endpoint = .{ .pin = .{ .ref_des = sp.ref_des, .pin = sp.pin } },
                        });
                        try self.adjAppend(sp.ref_des, .{
                            .pin = sp.pin,
                            .endpoint = .{ .pin = .{ .ref_des = hp.ref_des, .pin = hp.pin } },
                        });
                    }
                }
            }
        }
    }

    pub fn isSpokeGroundPin(self: *RenderCtx, ref_des: []const u8, pin_id: []const u8) bool {
        for (self.nets.items) |net| {
            for (net.pins) |p| {
                if (std.mem.eql(u8, p.ref_des, ref_des) and !std.mem.eql(u8, p.pin, pin_id)) {
                    if (isGroundNet(baseNetName(net.name))) return false;
                }
            }
        }
        for (self.nets.items) |net| {
            for (net.pins) |p| {
                if (std.mem.eql(u8, p.ref_des, ref_des) and std.mem.eql(u8, p.pin, pin_id)) {
                    if (isGroundNet(baseNetName(net.name))) return true;
                }
            }
        }
        return false;
    }

    pub fn buildNetIndex(self: *RenderCtx) !void {
        for (self.nets.items) |net| {
            const bn = baseNetName(net.name);
            for (net.pins) |pin| {
                const gop = try self.net_index.getOrPut(self.allocator, bn);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(self.allocator, pin);
            }
        }
    }

    pub fn buildSignificantNets(self: *RenderCtx, block: *const DesignBlock) !void {
        for (block.ports) |port| {
            try self.port_nets.put(self.allocator, baseNetName(port.net), {});
            try self.significant_nets.put(self.allocator, baseNetName(port.net), {});
        }
        for (block.sub_blocks) |sb| {
            for (sb.block.ports) |port| {
                const full = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ sb.name, baseNetName(port.net) });
                try self.port_nets.put(self.allocator, full, {});
                try self.significant_nets.put(self.allocator, full, {});
            }
        }
        for (self.nets.items) |net| {
            const bn = baseNetName(net.name);
            if (isGroundNet(bn)) continue;
            var has_hub = false;
            for (net.pins) |pin| {
                if (!self.spoke_set.contains(pin.ref_des)) {
                    has_hub = true;
                    break;
                }
            }
            if (has_hub) {
                try self.significant_nets.put(self.allocator, bn, {});
            }
        }
        // A (non-ground) net whose pins span two or more sections / sub-blocks
        // is a global rail/bus, not a local passive junction. The spoke-chain
        // walker must terminate (and label) there instead of fanning out into
        // every passive on the rail — otherwise one sub-block's passive network
        // drags in its siblings' identical networks (e.g. both PMA3 LNAs' VDD
        // bias resistors appearing on each LNA's hub SVG via the shared V5P0
        // rail). Marking it significant lets `renderTerminalGroups` draw the
        // rail label at the chain's terminus.
        //
        // `section_map` is the authoritative origin signal: every section and
        // every top-level sub-block gets a distinct index, and flattened
        // children keep their renumbered ref-des in it. (`originOf` only sees a
        // path prefix, which renumbering to standard ref-des erases — so it
        // alone can't tell R70/lna1 from R74/lna2. Kept as a cheap fallback for
        // any net whose pins carry a sub-block path but no section.)
        const NO_SECTION = std.math.maxInt(usize);
        var first_origin: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer first_origin.deinit(self.allocator);
        var first_section: std.StringHashMapUnmanaged(usize) = .empty;
        defer first_section.deinit(self.allocator);
        for (self.nets.items) |net| {
            const bn = baseNetName(net.name);
            if (isGroundNet(bn)) continue;
            if (self.shared_rail_nets.contains(bn)) continue;
            for (net.pins) |pin| {
                const origin = originOf(pin.ref_des);
                const sect = self.section_map.get(pin.ref_des) orelse NO_SECTION;
                const og = try first_origin.getOrPut(self.allocator, bn);
                const sg = try first_section.getOrPut(self.allocator, bn);
                if (!og.found_existing) {
                    og.value_ptr.* = origin;
                    sg.value_ptr.* = sect;
                    continue;
                }
                if (sg.value_ptr.* != sect or !std.mem.eql(u8, og.value_ptr.*, origin)) {
                    try self.shared_rail_nets.put(self.allocator, bn, {});
                    try self.significant_nets.put(self.allocator, bn, {});
                    break;
                }
            }
        }
        for ([_][]const u8{ "GND", "AGND", "DGND", "VSS" }) |g| {
            try self.significant_nets.put(self.allocator, g, {});
        }
    }

    pub fn buildPinCanonicalNets(self: *RenderCtx) !void {
        for (self.nets.items) |net| {
            const bn = baseNetName(net.name);
            for (net.pins) |pin| {
                if (!self.spoke_set.contains(pin.ref_des)) {
                    const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ pin.ref_des, pin.pin });
                    try self.pin_canonical_nets.put(self.allocator, key, bn);
                }
            }
        }
    }

    pub fn validateNetConsistency(self: *RenderCtx) !void {
        var adj_it = self.adjacency.iterator();
        while (adj_it.next()) |kv| {
            const ref_des = kv.key_ptr.*;
            if (self.spoke_set.contains(ref_des)) continue;
            for (kv.value_ptr.items) |entry| {
                switch (entry.endpoint) {
                    .net => |endpoint_net| {
                        if (isGroundNet(endpoint_net)) continue;
                        const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ ref_des, entry.pin });
                        const pin_net_name = self.pin_net.get(key) orelse continue;
                        const pin_bn = baseNetName(pin_net_name);
                        const ep_bn = baseNetName(endpoint_net);
                        if (!std.mem.eql(u8, pin_bn, ep_bn)) {
                            log.warn("NET VALIDATE: {s} pin {s}: pin_net=\"{s}\" but adjacency endpoint=\"{s}\"", .{ ref_des, entry.pin, pin_bn, ep_bn });
                        }
                    },
                    .pin => {},
                }
            }
        }

        var adj_it2 = self.adjacency.iterator();
        while (adj_it2.next()) |kv| {
            const ref_des = kv.key_ptr.*;
            if (!self.spoke_set.contains(ref_des)) continue;
            for (kv.value_ptr.items) |entry| {
                switch (entry.endpoint) {
                    .pin => |p| {
                        if (std.mem.order(u8, ref_des, p.ref_des) == .gt) continue;
                        const key_a = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ ref_des, entry.pin });
                        const key_b = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ p.ref_des, p.pin });
                        const net_a = self.pin_net.get(key_a) orelse continue;
                        const net_b = self.pin_net.get(key_b) orelse continue;
                        const bn_a = baseNetName(net_a);
                        const bn_b = baseNetName(net_b);
                        if (isGroundNet(bn_a) or isGroundNet(bn_b)) continue;
                        if (!std.mem.eql(u8, bn_a, bn_b)) {
                            log.warn(
                                "NET VALIDATE: spoke {s} pin {s} (net=\"{s}\") " ++
                                    "<-> {s} pin {s} (net=\"{s}\") — mismatch",
                                .{ ref_des, entry.pin, bn_a, p.ref_des, p.pin, bn_b },
                            );
                        }
                    },
                    .net => {},
                }
            }
        }

        var pcn_it = self.pin_canonical_nets.iterator();
        while (pcn_it.next()) |kv| {
            const key = kv.key_ptr.*;
            const canonical = kv.value_ptr.*;
            const raw = self.pin_net.get(key) orelse continue;
            const canon_bn = baseNetName(canonical);
            const raw_bn = baseNetName(raw);
            if (isGroundNet(canon_bn) or isGroundNet(raw_bn)) continue;
            if (!std.mem.eql(u8, canon_bn, raw_bn)) {
                log.warn("NET VALIDATE: {s}: pin_net=\"{s}\" but canonical=\"{s}\"", .{ key, raw_bn, canon_bn });
            }
        }
    }

    pub fn adjAppend(self: *RenderCtx, ref_des: []const u8, entry: AdjEntry) !void {
        const gop = try self.adjacency.getOrPut(self.allocator, ref_des);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, entry);
    }
};

/// True when hub `hub`'s adjacency reaches spoke `spoke` via its own pin `pin`.
fn hubReachesSpokeOnPin(ctx: *RenderCtx, hub: []const u8, pin: []const u8, spoke: []const u8) bool {
    const list = ctx.adjacency.get(hub) orelse return false;
    for (list.items) |ae| {
        if (!std.mem.eql(u8, ae.pin, pin)) continue;
        switch (ae.endpoint) {
            .pin => |p| if (std.mem.eql(u8, p.ref_des, spoke)) return true,
            .net => {},
        }
    }
    return false;
}

// spec: render_svg - Docks a (decouples ...) bypass cap on the bound hub pad instead of every pin of the rail
test "decouples binding docks each cap on its served hub pad" {
    const testing = std.testing;
    // U1 is a hub with two supply pads (1, 2) on one rail VDD plus a ground pad
    // (3). C1 binds to pad 2, C2 to pad 1 — so each cap must reach U1 on exactly
    // its bound pad. A plain rail bypass cap (no binding) fans onto every supply
    // pad, which is what piled every cap onto one part block before the fix.
    const insts = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "C1", .component = "cap", .value = "100nF", .footprint = "", .symbol = "", .decouple_ic = "U1", .decouple_pin = "2" },
        .{ .ref_des = "C2", .component = "cap", .value = "100nF", .footprint = "", .symbol = "", .decouple_ic = "U1", .decouple_pin = "1" },
    };
    const vdd_pins = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "U1", .pin = "2" },
        .{ .ref_des = "C1", .pin = "1" }, .{ .ref_des = "C2", .pin = "1" },
    };
    const gnd_pins = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "3" }, .{ .ref_des = "C1", .pin = "2" }, .{ .ref_des = "C2", .pin = "2" },
    };
    const nets = [_]env_mod.Net{
        .{ .name = "VDD", .pins = &vdd_pins },
        .{ .name = "GND", .pins = &gnd_pins },
    };
    const block: DesignBlock = .{
        .name = "decouple-bind-test",
        .instances = &insts,
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = RenderCtx.init(arena.allocator());
    try ctx.collectFlat(&block, "");
    try ctx.classify();
    try ctx.buildAdjacency();
    try ctx.synthesizeSpokeConnections();

    // Each cap docks on exactly its bound pad …
    try testing.expect(hubReachesSpokeOnPin(&ctx, "U1", "2", "C1"));
    try testing.expect(hubReachesSpokeOnPin(&ctx, "U1", "1", "C2"));
    // … and not on the other supply pad (the pre-fix fan-out attached every cap
    // to both pads, so one part block claimed them all).
    try testing.expect(!hubReachesSpokeOnPin(&ctx, "U1", "1", "C1"));
    try testing.expect(!hubReachesSpokeOnPin(&ctx, "U1", "2", "C2"));
}
