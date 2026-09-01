//! Shared render context for the hub-and-spoke schematic SVG. Defines the
//! flattened scene types the renderer works on — `FlatInst`/`FlatNet` (a
//! sub-block-flattened, path-qualified view of the design), adjacency, and
//! `PinGroup` — plus `RenderCtx`, the per-render state the `render_svg/*`
//! drawing modules thread through. Built once per page from a `DesignBlock`.

const std = @import("std");
const log = @import("../infra/log.zig");
const env_mod = @import("../eval/env.zig");
const na = @import("../eval/net_analysis.zig");
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
const HubCountMap = std.StringHashMapUnmanaged(u32);
const SoleHubMap = std.StringHashMapUnmanaged(PinRef);
const RefNetsMap = std.StringHashMapUnmanaged(std.ArrayList([]const u8));

const PassiveIsland = struct {
    refs: []const []const u8,
    has_explicit_binding: bool,
};

const IslandAnchorChoice = struct {
    has_busy_boundary: bool = false,
    candidate_hub_ref: ?[]const u8 = null,
    conflicting_candidate_hubs: bool = false,
    anchor_net: ?[]const u8 = null,
    anchor_pin: ?PinRef = null,
    anchor_reaches_port: bool = false,
};

const IslandAnchorInputs = struct {
    seed_ref: []const u8,
    refs: []const []const u8,
    hub_count: *const HubCountMap,
    sole_hub: *const SoleHubMap,
    spoke_nets: *const RefNetsMap,
};

const RenderScratch = struct {
    hub_splits: std.StringHashMapUnmanaged(MergeAwareSplit) = .empty,
    deferred_branch_terminals: std.ArrayList(BranchBody) = .empty,
    defer_branch_terminals: bool = false,
    /// Functional-view pin rows on each side of the current hub. Connection
    /// rendering consults these to turn an outside-edge series resistor toward
    /// the signal pin it feeds instead of spending another horizontal lane.
    functional_layout: bool = false,
    functional_left_pin_y: std.StringHashMapUnmanaged(f64) = .empty,
    functional_right_pin_y: std.StringHashMapUnmanaged(f64) = .empty,
    /// Nets whose Functional return already turns through a vertical series
    /// part. Their destination pin anchors directly on that inline rail rather
    /// than emitting a short outward terminal stub first.
    functional_inline_nets: std.StringHashMapUnmanaged(void) = .empty,
    functional_series_target_y: ?f64 = null,
    rendered_connection_end_y: ?f64 = null,
};

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
    /// A Functional vertical series return already defines the x-lane that
    /// should close its direct connection. Reusing it prevents the terminal
    /// pass from pulling the wire out to a separate label lane.
    inline_direct_lane: bool = false,
    /// Functional-only single resistor whose final horizontal position waits
    /// until the hub-level direct-return lane has been selected. Sequential
    /// rendering leaves this null and draws the chain immediately.
    deferred_series: ?FlatInst = null,
    deferred_start_x: f64 = 0,
    deferred_source_net: []const u8 = "",
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

/// Why a net is exempt from the single-pin significance filter — see
/// `RenderCtx.lone_pin_nets`. `.boundary_port` is a net that LEAVES this
/// schematic (a declared `(port …)`, or a sub-block port as this schematic
/// spells it) and is drawn in the boundary-port colour; `.internal` is ordinary
/// wiring that merely has to survive the filter, drawn like any other net.
pub const LonePinRole = enum { boundary_port, internal };

/// Result of splitting a hub's pin groups across the two columns using the
/// height of every visible connection. Lives here so `RenderCtx` can memoize
/// it — the scene-graph renderer computes it three times per hub otherwise.
pub const MergeAwareSplit = struct {
    left: []const PinGroup,
    right: []const PinGroup,
    left_heights: []f64,
    right_heights: []f64,
};

// ── Render Context ────────────────────────────────────────────────────

/// All the pre-computed lookup tables the SVG schematic renderer needs:
/// flattened instances + nets, hub/spoke classification, adjacency lists,
/// per-pin canonical net mapping, lone-pin/boundary-port roles, and the section→index
/// table that drives section-aware label placement. Built once via
/// `collectFlat` + helpers, then fed to the per-hub render passes.
pub const RenderCtx = struct {
    allocator: Allocator,
    /// Project directory for locating lib/pinouts/*.sexp (empty if unavailable).
    project_dir: []const u8 = "",
    instances: std.ArrayList(FlatInst),
    nets: std.ArrayList(FlatNet),
    hub_order: std.ArrayList([]const u8),
    inst_map: std.StringHashMapUnmanaged(FlatInst),
    spoke_set: std.StringHashMapUnmanaged(void),
    pin_net: std.StringHashMapUnmanaged([]const u8),
    adjacency: std.StringHashMapUnmanaged(std.ArrayList(AdjEntry)),
    net_index: std.StringHashMapUnmanaged(std.ArrayList(PinRef)),
    significant_nets: std.StringHashMapUnmanaged(void),
    /// Base names of (non-ground) nets shared across two or more sub-blocks —
    /// i.e. global rails/buses, not local passive junctions. The spoke-chain
    /// walker terminates and labels these instead of fanning out into every
    /// passive on the rail (which would pull in sibling sub-blocks' identical
    /// networks). Populated by `buildSignificantNets`.
    shared_rail_nets: std.StringHashMapUnmanaged(void),
    /// Nets exempt from the single-pin significance filter — a pin sitting alone
    /// on one still draws its wire and net label — each tagged with WHY.
    /// `.boundary_port` additionally paints the label boundary-blue and sets the
    /// scene graph's `port` flag; `.internal` does not. Keeping the two roles
    /// apart is load-bearing: a bridged sub-block port resolves to the PARENT's
    /// own net, which needs the filter escape but is ordinary internal wiring, and
    /// calling it a port recoloured stm32n6's labels 53 → 288 as board
    /// boundaries. Read through `rendersWhenAlone` / `isBoundaryPort`.
    lone_pin_nets: std.StringHashMapUnmanaged(LonePinRole),
    pin_canonical_nets: std.StringHashMapUnmanaged([]const u8),
    rendered_spokes: std.StringHashMapUnmanaged(void),
    section_map: std.StringHashMapUnmanaged(usize),
    /// Spoke ref-des → the base net name it should be drawn off (its "anchor"
    /// side). Populated for a passive, or a passive island joined through local
    /// junction nets, that bridges one or more lone signal pins to a busy hub
    /// rail. The whole island renders from the signal pin that continues to a
    /// declared port, or the lowest physical signal pin when none does, and
    /// labels the busy rail at its far end (e.g. a BOOT pull-up or RF bias tee)
    /// instead of being claimed by the first supply pin rendered.
    /// See `computeSpokeAnchors`.
    spoke_anchor_net: std.StringHashMapUnmanaged([]const u8),
    /// Memoized visible-height hub splits plus terminal bodies temporarily
    /// collected from passive branch trees for the final hub-level connection
    /// pass. Arena-backed like the rest of the render state.
    render_scratch: RenderScratch = .{},

    pub fn init(allocator: Allocator) RenderCtx {
        return .{
            .allocator = allocator,
            .render_scratch = .{},
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
            .lone_pin_nets = .empty,
            .pin_canonical_nets = .empty,
            .rendered_spokes = .empty,
            .section_map = .empty,
            .spoke_anchor_net = .empty,
        };
    }

    // ── Data collection ───────────────────────────────────────────────

    /// Build a net rename map from a block's net_ties, prefixed appropriately.
    /// A tie (a="VDD", b="buck/VOUT") at prefix="" means: rename net "buck/VOUT" to "VDD".
    fn buildNetRenameMap(self: *RenderCtx, block: *const DesignBlock, prefix: []const u8) !std.StringHashMapUnmanaged([]const u8) {
        var net_rename = std.StringHashMapUnmanaged([]const u8).empty;
        for (block.net_ties) |nt| {
            const full_b = if (prefix.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, nt.b })
            else
                nt.b;
            const full_a = if (prefix.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, nt.a })
            else
                nt.a;
            try net_rename.put(self.allocator, full_b, full_a);
        }
        return net_rename;
    }

    /// Resolve a net name through a chain of rename maps (parent → grandparent → ...).
    /// For qualified names like "ldo/VIN.U1.IN", also tries resolving the base
    /// part "ldo/VIN" and preserves the suffix ".U1.IN".
    fn resolveNetName(allocator: std.mem.Allocator, net_name: []const u8, rename_maps: []const std.StringHashMapUnmanaged([]const u8)) []const u8 {
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
        try self.buildNetIndex();
        try self.buildSignificantNets(block);
        try self.synthesizeSpokeConnections();
        try self.buildPinCanonicalNets();
    }

    pub fn collectFlat(self: *RenderCtx, block: *const DesignBlock, prefix: []const u8) !void {
        try self.collectFlatWithRenames(block, prefix, &.{});
    }

    fn collectFlatWithRenames(self: *RenderCtx, block: *const DesignBlock, prefix: []const u8, parent_renames: []const std.StringHashMapUnmanaged([]const u8)) !void {
        // Build rename map for this block's net_ties
        const my_rename = try self.buildNetRenameMap(block, prefix);
        // Combine with parent rename maps
        var all_renames: std.ArrayList(std.StringHashMapUnmanaged([]const u8)) = .empty;
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
                .decouple_ic = inst.bind.decouple.ic,
                .decouple_pin = inst.bind.decouple.pin,
                .decouple_rail = inst.bind.decouple.rail,
            };
            try self.instances.append(self.allocator, flat);
            try self.inst_map.put(self.allocator, rd, flat);
        }
        for (block.nets) |net| {
            var pins: std.ArrayList(PinRef) = .empty;
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

    /// A passive network bridging lone hub pins and a multi-hub-pin rail belongs
    /// on its signal side. The simple case is one 2-terminal passive (a BOOT
    /// pull-up). The general case is an island of passives joined through local
    /// nets with no hub pins, such as an RF bias tee whose choke reaches VCC and
    /// whose two load resistors reach RFOUTAM/RFOUTAP. Pin-order rendering must
    /// not let the earlier VCC pad claim that whole island.
    ///
    /// First preserve the direct-passive rule, then discover local passive
    /// islands. When one touches a busy rail plus one or more lone pins on the
    /// same hub, anchor every member to a signal pin. A pin whose off-island
    /// passive continues to a declared port wins (for example RFOUTAP feeding
    /// LO_OUT); otherwise the lowest physical pin is the deterministic tie-break.
    /// Only the member actually touching that net gets a synthesized hub
    /// attachment; the chain walker reaches the others through local junctions.
    ///
    /// Only set the anchor when the spoke would actually attach to that lone hub
    /// under the section-preference rules below (same section, or one side has
    /// no section). Otherwise leave default behaviour so the spoke never ends up
    /// attached to neither side.
    fn computeSpokeAnchors(self: *RenderCtx) !void {
        const a = self.allocator;

        // Per base-net: hub-pin count, and the lone hub pin when the count is 1.
        var hub_count: HubCountMap = .empty;
        var sole_hub: SoleHubMap = .empty;
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
        var spoke_nets: RefNetsMap = .empty;
        var net_spokes: RefNetsMap = .empty;
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

                const ngop = try net_spokes.getOrPut(a, bn);
                if (!ngop.found_existing) ngop.value_ptr.* = .empty;
                var net_has_spoke = false;
                for (ngop.value_ptr.items) |ref| {
                    if (std.mem.eql(u8, ref, pin.ref_des)) {
                        net_has_spoke = true;
                        break;
                    }
                }
                if (!net_has_spoke) try ngop.value_ptr.append(a, pin.ref_des);
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

        try self.anchorPassiveIslands(&hub_count, &sole_hub, &spoke_nets, &net_spokes);
    }

    /// Propagate one signal-side owner across every local passive island. Nets
    /// with hub pins are boundaries, not island links: crossing one would merge
    /// unrelated pull-ups, bypass caps, and sibling blocks through a rail.
    fn anchorPassiveIslands(
        self: *RenderCtx,
        hub_count: *const HubCountMap,
        sole_hub: *const SoleHubMap,
        spoke_nets: *const RefNetsMap,
        net_spokes: *const RefNetsMap,
    ) !void {
        var seen_spokes: std.StringHashMapUnmanaged(void) = .empty;
        for (self.instances.items) |seed_inst| {
            if (!self.spoke_set.contains(seed_inst.ref_des)) continue;
            if (seen_spokes.contains(seed_inst.ref_des)) continue;

            const island = try self.collectPassiveIsland(seed_inst.ref_des, hub_count, spoke_nets, net_spokes, &seen_spokes);
            // An explicit `(decouples ...)` declaration is stronger than any
            // inferred island owner and remains handled by `boundHubPin`.
            if (island.has_explicit_binding) continue;
            const anchor = try self.passiveIslandAnchor(seed_inst.ref_des, island.refs, hub_count, sole_hub, spoke_nets) orelse continue;
            for (island.refs) |ref| try self.spoke_anchor_net.put(self.allocator, ref, anchor);
        }
    }

    fn collectPassiveIsland(
        self: *RenderCtx,
        seed_ref: []const u8,
        hub_count: *const HubCountMap,
        spoke_nets: *const RefNetsMap,
        net_spokes: *const RefNetsMap,
        seen_spokes: *std.StringHashMapUnmanaged(void),
    ) !PassiveIsland {
        const a = self.allocator;
        var pending: std.ArrayList([]const u8) = .empty;
        var component: std.ArrayList([]const u8) = .empty;
        var has_explicit_binding = false;
        try pending.append(a, seed_ref);
        try seen_spokes.put(a, seed_ref, {});

        while (pending.pop()) |ref| {
            try component.append(a, ref);
            if (self.inst_map.get(ref)) |inst| {
                has_explicit_binding = has_explicit_binding or inst.decouple_pin.len > 0 or inst.decouple_rail;
            }
            const nets = spoke_nets.get(ref) orelse continue;
            for (nets.items) |net| {
                if ((hub_count.get(net) orelse 0) != 0) continue;
                try self.queueIslandNeighbours(seed_ref, net, net_spokes, seen_spokes, &pending);
            }
        }
        return .{ .refs = component.items, .has_explicit_binding = has_explicit_binding };
    }

    fn queueIslandNeighbours(
        self: *RenderCtx,
        seed_ref: []const u8,
        net: []const u8,
        net_spokes: *const RefNetsMap,
        seen_spokes: *std.StringHashMapUnmanaged(void),
        pending: *std.ArrayList([]const u8),
    ) !void {
        const neighbours = net_spokes.get(net) orelse return;
        for (neighbours.items) |other| {
            if (seen_spokes.contains(other)) continue;
            if (!self.renderSectionsCompatible(seed_ref, other)) continue;
            try seen_spokes.put(self.allocator, other, {});
            try pending.append(self.allocator, other);
        }
    }

    fn passiveIslandAnchor(
        self: *RenderCtx,
        seed_ref: []const u8,
        refs: []const []const u8,
        hub_count: *const HubCountMap,
        sole_hub: *const SoleHubMap,
        spoke_nets: *const RefNetsMap,
    ) !?[]const u8 {
        var boundary_seen: std.StringHashMapUnmanaged(void) = .empty;
        var choice: IslandAnchorChoice = .{};
        const inputs: IslandAnchorInputs = .{
            .seed_ref = seed_ref,
            .refs = refs,
            .hub_count = hub_count,
            .sole_hub = sole_hub,
            .spoke_nets = spoke_nets,
        };
        for (refs) |ref| {
            const nets = spoke_nets.get(ref) orelse continue;
            for (nets.items) |net| {
                if (boundary_seen.contains(net)) continue;
                try boundary_seen.put(self.allocator, net, {});
                self.considerIslandBoundary(inputs, net, &choice);
            }
        }
        if (!choice.has_busy_boundary or choice.conflicting_candidate_hubs) return null;
        const candidate_hub = choice.candidate_hub_ref orelse return null;
        if (!self.hubTouchesBusyIslandBoundary(candidate_hub, refs, hub_count, spoke_nets)) return null;
        return choice.anchor_net;
    }

    /// The lone-pin owner must also be one of the hubs on the island's busy
    /// boundary. This distinguishes an IC's own RF bias tee from a supply chain
    /// that merely runs from that IC's VDD pads through L/FB parts to a connector:
    /// the connector must not steal the supply chain from the IC schematic.
    fn hubTouchesBusyIslandBoundary(
        self: *RenderCtx,
        hub_ref: []const u8,
        refs: []const []const u8,
        hub_count: *const HubCountMap,
        spoke_nets: *const RefNetsMap,
    ) bool {
        for (refs) |ref| {
            const nets = spoke_nets.get(ref) orelse continue;
            for (nets.items) |net| {
                if ((hub_count.get(net) orelse 0) < 2) continue;
                if (self.hubHasPinOnNet(hub_ref, net)) return true;
            }
        }
        return false;
    }

    fn hubHasPinOnNet(self: *RenderCtx, hub_ref: []const u8, want_net: []const u8) bool {
        for (self.nets.items) |net| {
            if (!std.mem.eql(u8, baseNetName(net.name), want_net)) continue;
            for (net.pins) |pin| {
                if (std.mem.eql(u8, pin.ref_des, hub_ref) and !self.spoke_set.contains(pin.ref_des)) return true;
            }
        }
        return false;
    }

    fn considerIslandBoundary(
        self: *RenderCtx,
        inputs: IslandAnchorInputs,
        net: []const u8,
        choice: *IslandAnchorChoice,
    ) void {
        const count = inputs.hub_count.get(net) orelse 0;
        if (count >= 2) {
            choice.has_busy_boundary = true;
            return;
        }
        if (count != 1) return;

        const hp = inputs.sole_hub.get(net) orelse return;
        if (!self.renderSectionsCompatible(inputs.seed_ref, hp.ref_des)) return;
        if (choice.candidate_hub_ref) |owner| {
            if (!std.mem.eql(u8, owner, hp.ref_des)) choice.conflicting_candidate_hubs = true;
        } else {
            choice.candidate_hub_ref = hp.ref_des;
        }

        const reaches_port = self.islandBoundaryReachesPort(net, inputs.refs, inputs.spoke_nets);
        const better = if (choice.anchor_pin) |current|
            (reaches_port and !choice.anchor_reaches_port) or
                (reaches_port == choice.anchor_reaches_port and
                    (draw.pinOrder(hp.pin, current.pin) or
                        (std.mem.eql(u8, hp.pin, current.pin) and std.mem.lessThan(u8, net, choice.anchor_net.?))))
        else
            true;
        if (better) {
            choice.anchor_pin = hp;
            choice.anchor_net = net;
            choice.anchor_reaches_port = reaches_port;
        }
    }

    /// Whether `boundary_net` leaves this passive island through one extra
    /// passive and reaches a declared schematic port. This is the common RF
    /// output shape: the bias tee owns both differential pins, while only the
    /// used leg continues through its DC block to the module output.
    fn islandBoundaryReachesPort(
        self: *RenderCtx,
        boundary_net: []const u8,
        island_refs: []const []const u8,
        spoke_nets: *const RefNetsMap,
    ) bool {
        for (self.instances.items) |inst| {
            if (!self.spoke_set.contains(inst.ref_des)) continue;
            var in_island = false;
            for (island_refs) |ref| {
                if (std.mem.eql(u8, ref, inst.ref_des)) {
                    in_island = true;
                    break;
                }
            }
            if (in_island) continue;

            const nets = spoke_nets.get(inst.ref_des) orelse continue;
            var touches_boundary = false;
            for (nets.items) |candidate| {
                if (std.mem.eql(u8, candidate, boundary_net)) {
                    touches_boundary = true;
                    break;
                }
            }
            if (!touches_boundary) continue;
            for (nets.items) |candidate| {
                if (!std.mem.eql(u8, candidate, boundary_net) and self.isBoundaryPort(candidate)) return true;
            }
        }
        return false;
    }

    fn renderSectionsCompatible(self: *RenderCtx, a_ref: []const u8, b_ref: []const u8) bool {
        const a_section = self.section_map.get(a_ref);
        const b_section = self.section_map.get(b_ref);
        return a_section == null or b_section == null or a_section.? == b_section.?;
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
            var hub_pins: std.ArrayList(PinRef) = .empty;
            var spoke_pins: std.ArrayList(PinRef) = .empty;

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

    /// Record `net` as significant and exempt from the single-pin filter, in
    /// `role`. A `.boundary_port` claim never degrades to `.internal`: the same
    /// spelling can be both a declared port of this block and a sub-block's
    /// bridged port, and the boundary is the stronger fact.
    fn markLonePinNet(self: *RenderCtx, net: []const u8, role: LonePinRole) !void {
        const gop = try self.lone_pin_nets.getOrPut(self.allocator, net);
        if (!gop.found_existing or role == .boundary_port) gop.value_ptr.* = role;
        try self.significant_nets.put(self.allocator, net, {});
    }

    /// Whether a pin sitting ALONE on `net` still draws its wire and net label.
    pub fn rendersWhenAlone(self: *const RenderCtx, net: []const u8) bool {
        return self.lone_pin_nets.contains(net);
    }

    /// Whether `net` leaves this schematic — what paints its label the
    /// boundary-port colour and sets the scene graph's `port` flag.
    pub fn isBoundaryPort(self: *const RenderCtx, net: []const u8) bool {
        return (self.lone_pin_nets.get(net) orelse return false) == .boundary_port;
    }

    /// Register every sub-block's port nets under the spelling the *flattened*
    /// scene actually carries. `collectFlatWithRenames` resolves a bridged port
    /// net through the parent's net-ties — `(bridge "" TXOUT+)` / `(net "TXOUT+"
    /// "tx/TXOUT+")` rewrites `tx/TXOUT+` to `TXOUT+` — so keying on the
    /// pre-rename `"<slug>/<port>"` path left every bridged module port out of the
    /// set. A bridged port net whose only pin is the module's own pad (its far end
    /// being net-less printed copper) then failed the significance test in
    /// `connection.renderGroupedConnections` and the pad drew nothing at all.
    ///
    /// The two spellings are registered in DIFFERENT roles. The path name is the
    /// port as this schematic sees it, a genuine boundary. The resolved name is
    /// the parent's own net — internal wiring that merely needs the single-pin
    /// escape, so it lands `.internal`; calling it a port repainted every bridged
    /// internal net boundary-blue and set its scene `port` flag.
    fn registerSubBlockPortNets(self: *RenderCtx, block: *const DesignBlock) !void {
        var renames = try self.buildNetRenameMap(block, "");
        defer renames.deinit(self.allocator);
        const maps = [_]std.StringHashMapUnmanaged([]const u8){renames};
        for (block.sub_blocks) |sb| {
            for (sb.block.ports) |port| {
                const path = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}/{s}",
                    .{ sb.name, baseNetName(port.net) },
                );
                try self.markLonePinNet(path, .boundary_port);
                const resolved = baseNetName(resolveNetName(self.allocator, path, &maps));
                if (!std.mem.eql(u8, resolved, path)) try self.markLonePinNet(resolved, .internal);
            }
        }
    }

    pub fn buildSignificantNets(self: *RenderCtx, block: *const DesignBlock) !void {
        for (block.ports) |port| {
            try self.markLonePinNet(baseNetName(port.net), .boundary_port);
        }
        try self.registerSubBlockPortNets(block);
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
        // The names the schematic draws a GND symbol for, plus `VSS`.
        for (na.schematic_ground_names ++ [_][]const u8{"VSS"}) |g| {
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
        .{ .ref_des = "C1", .component = "cap", .value = "100nF", .footprint = "", .symbol = "", .bind = .{ .decouple = .{ .ic = "U1", .pin = "2" } } },
        .{ .ref_des = "C2", .component = "cap", .value = "100nF", .footprint = "", .symbol = "", .bind = .{ .decouple = .{ .ic = "U1", .pin = "1" } } },
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

// spec: render_svg - A passive bias island shared by RF output pins and a busy supply rail is owned by the pin that continues to a declared output port, falling back to the lowest RF pin
test "bias tee island anchors to the RF pin that continues to an output port" {
    const testing = std.testing;
    // L1/C1/R1/R2 are the LMX2595 output-bias shape: a choke from the busy VDD
    // rail feeds a local BIAS junction, and two 50R loads take that junction to
    // adjacent RF output pads. C3 continues RFOUTAP through a DC block to the
    // declared LO_OUT port, so that used leg owns the island even though pin 22
    // sorts first. C2 remains the real pin-7 bypass with explicit ownership.
    const insts = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "L1", .component = "ind", .value = "18nH", .footprint = "", .symbol = "" },
        .{ .ref_des = "C1", .component = "cap", .value = "10nF", .footprint = "", .symbol = "" },
        .{ .ref_des = "R1", .component = "res", .value = "50R", .footprint = "", .symbol = "" },
        .{ .ref_des = "R2", .component = "res", .value = "50R", .footprint = "", .symbol = "" },
        .{ .ref_des = "C2", .component = "cap", .value = "1uF", .footprint = "", .symbol = "", .bind = .{ .decouple = .{ .ic = "U1", .pin = "7" } } },
        .{ .ref_des = "C3", .component = "cap", .value = "10nF", .footprint = "", .symbol = "" },
    };
    const vdd_pins = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "7" }, .{ .ref_des = "U1", .pin = "11" },
        .{ .ref_des = "L1", .pin = "2" }, .{ .ref_des = "C2", .pin = "1" },
    };
    const bias_pins = [_]env_mod.PinRef{
        .{ .ref_des = "L1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" },
        .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "2" },
    };
    const am_pins = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "22" }, .{ .ref_des = "R1", .pin = "2" } };
    const ap_pins = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "23" }, .{ .ref_des = "R2", .pin = "1" }, .{ .ref_des = "C3", .pin = "1" } };
    const lo_out_pins = [_]env_mod.PinRef{.{ .ref_des = "C3", .pin = "2" }};
    const gnd_pins = [_]env_mod.PinRef{ .{ .ref_des = "C1", .pin = "2" }, .{ .ref_des = "C2", .pin = "2" } };
    const nets = [_]env_mod.Net{
        .{ .name = "VDD", .pins = &vdd_pins },
        .{ .name = "BIAS", .pins = &bias_pins },
        .{ .name = "RFOUTAM", .pins = &am_pins },
        .{ .name = "RFOUTAP", .pins = &ap_pins },
        .{ .name = "LO_OUT", .pins = &lo_out_pins },
        .{ .name = "GND", .pins = &gnd_pins },
    };
    const block: DesignBlock = .{
        .name = "bias-tee-anchor-test",
        .instances = &insts,
        .nets = &nets,
        .ports = &[_]env_mod.Port{.{ .name = "LO_OUT", .net = "LO_OUT", .direction = "out" }},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = RenderCtx.init(arena.allocator());
    try ctx.setup(&block);

    // Every member has one precomputed owner, so render order cannot move the
    // island. R2 is the member touching the port-feeding owner and therefore
    // the only synthesized entry into the island from U1.
    for ([_][]const u8{ "L1", "C1", "R1", "R2" }) |ref| {
        try testing.expectEqualStrings("RFOUTAP", ctx.spoke_anchor_net.get(ref).?);
    }
    try testing.expect(hubReachesSpokeOnPin(&ctx, "U1", "23", "R2"));
    try testing.expect(!hubReachesSpokeOnPin(&ctx, "U1", "7", "L1"));
    try testing.expect(!hubReachesSpokeOnPin(&ctx, "U1", "11", "L1"));
    try testing.expect(!hubReachesSpokeOnPin(&ctx, "U1", "22", "R1"));

    // The unrelated per-pin bypass still obeys `(decouples "U1" 7)`.
    try testing.expect(hubReachesSpokeOnPin(&ctx, "U1", "7", "C2"));
    try testing.expect(!hubReachesSpokeOnPin(&ctx, "U1", "11", "C2"));
}

test "isStdRefDes rejects a ref shorter than two characters" {
    // "U10"/"R5" are standard; a lone letter is not (a length-guard `return
    // false` flipped to `return true` would misclassify "U" as standard).
    try std.testing.expect(isStdRefDes("U10"));
    try std.testing.expect(isStdRefDes("R5"));
    try std.testing.expect(!isStdRefDes("U"));
    try std.testing.expect(!isStdRefDes(""));
}
