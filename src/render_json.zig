const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const env_mod = @import("eval/env.zig");
const json_writer = @import("json_writer.zig");
const asserted_fns_mod = @import("asserted_fns.zig");
const DesignBlock = env_mod.DesignBlock;

const ctx_mod = @import("render_svg/context.zig");
pub const RenderCtx = ctx_mod.RenderCtx;
const FlatInst = ctx_mod.FlatInst;
const AdjEntry = ctx_mod.AdjEntry;
const PinGroup = ctx_mod.PinGroup;
const Endpoint = ctx_mod.Endpoint;
const Side = ctx_mod.Side;

const hub_mod = @import("render_svg/hub.zig");
const connection = @import("render_svg/connection.zig");
const draw = @import("render_svg/draw.zig");
const branch_mod = @import("render_svg/branch.zig");

const hub_width = draw.hub_width;
const hub_x = draw.hub_x;
const pin_stub = draw.pin_stub;
const spoke_len = draw.spoke_len;
const passive_bw = draw.passive_bw;
const top_margin = draw.top_margin;
const per_conn_spacing = draw.per_conn_spacing;
const branch_spacing = draw.branch_spacing;
const bus_gap = draw.bus_gap;
const net_label_gap = draw.net_label_gap;
const isGroundNet = draw.isGroundNet;
const baseNetName = draw.baseNetName;
const shortRef = draw.shortRef;
const displayValue = draw.displayValue;
const formatShort = draw.formatShort;
const endpointEql = draw.endpointEql;

const Allocator = std.mem.Allocator;

/// Error set for the JSON scene-graph emitter — uses the same
/// `ArrayListUnmanaged(u8).writer()` (only OOM) plus `*std.Io.Writer`
/// (adds `WriteFailed`) — `draw.RenderError` propagates the same union
/// up through `mergeAwareHubHeight` → `renderSceneGraph`.
pub const RenderError = std.mem.Allocator.Error || std.Io.Writer.Error;

// ── Layout constants ──────────────────────────────────────────────
const HALF_DIVISOR: f64 = 2.0;
const HUB_VPAD: f64 = 40.0;
const PIN_OFFSET: f64 = 20.0;
const TITLE_LINE_GAP: f64 = 12.0;
const DESC_LINE_GAP: f64 = 6.0;
const NOTE_BLOCK_PAD: f64 = 16.0;
const SECTION_PAD_X: f64 = 8.0;
const SECTION_BORDER_W: f64 = 16.0;
const CELL_BLOCK_GAP: f64 = 40.0;
const MIN_VB_WIDTH: f64 = 850.0;
const MIN_VB_HEIGHT: f64 = 400.0;
const VB_MARGIN: f64 = 40.0;
const FAR_X_SENTINEL: f64 = 99999.0;
const BUS_OFFSET: f64 = 10.0;
const BRANCH_BUS_GAP: f64 = 10.0;

// ── JSON Scene Graph Types ───────────────────────────────────────────

const JsonSection = struct {
    name: []const u8,
    description: []const u8,
    notes: []const env_mod.SectionNote,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
};

const JsonPin = struct {
    pin_numbers: []const u8,
    display_name: []const u8,
    y: f64,
    side: []const u8,
    /// Alternate functions available for this pin (empty for power/ground and multi-pin groups).
    alts: []const []const u8 = &.{},
    /// Asserted function if the user wrote `(pin X (as "FN") …)`, else empty.
    active_fn: []const u8 = "",
};

const JsonHub = struct {
    ref: []const u8,
    component: []const u8,
    value: []const u8,
    symbol: []const u8,
    part: ?[]const u8,
    label: []const u8,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    icon: ?[]const u8,
    src_offset: u32 = 0,
    left_pins: std.ArrayListUnmanaged(JsonPin),
    right_pins: std.ArrayListUnmanaged(JsonPin),
};

/// Cached pinout data: symbol_name -> (pin_id -> []alt_names).
/// Populated lazily in renderSceneGraph; lives for the lifetime of a single render.
const PinoutAltMap = std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const []const u8));

fn loadPinoutAlts(allocator: Allocator, map: *PinoutAltMap, project_dir: []const u8, symbol: []const u8) std.mem.Allocator.Error!void {
    if (project_dir.len == 0 or symbol.len == 0) return;
    if (map.contains(symbol)) return;
    const path = std.fmt.allocPrint(allocator, "{s}/lib/pinouts/{s}.sexp", .{ project_dir, symbol }) catch return;
    const content = infra_fs.cwd().readFileAlloc(allocator, path, 1024 * 256) catch return;
    const parser_m = @import("sexpr/parser.zig");
    const nodes = parser_m.parse(allocator, content) catch return;
    if (nodes.len == 0) return;
    const top = nodes[0].asList() orelse return;
    if (top.len < 2) return;
    const head = top[0].asAtom() orelse return;
    if (!std.mem.eql(u8, head, "pinout")) return;

    var by_pin: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    for (top[2..]) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len < 4) continue;
        const ch = cl[0].asAtom() orelse continue;
        if (!std.mem.eql(u8, ch, "pin")) continue;
        const pin_id = cl[1].asAtom() orelse cl[1].asString() orelse continue;

        var alts: std.ArrayListUnmanaged([]const u8) = .empty;
        for (cl[3..]) |alt_node| {
            const al = alt_node.asList() orelse continue;
            if (al.len < 2) continue;
            const hd = al[0].asAtom() orelse continue;
            if (!std.mem.eql(u8, hd, "alt")) continue;
            const alt_name = al[1].asString() orelse (al[1].asAtom() orelse continue);
            alts.append(allocator, alt_name) catch continue;
        }
        if (alts.items.len > 0) {
            const owned = alts.toOwnedSlice(allocator) catch continue;
            by_pin.put(allocator, pin_id, owned) catch continue;
        }
    }
    try map.put(allocator, symbol, by_pin);
}

/// Parse `lib/pinouts/<x>.sexp` into pad -> function-name (e.g. "15" -> "GP11").
/// A hub pin should label by the component's own function, not the net it
/// reaches: part-level `(part …)` names (`buildPinNameMap`) cover multi-part
/// ICs, but flat `(pin …)` instances carry none, so we supplement from the
/// pinout file — the same source the HTML schematic uses (which is why it
/// already read "GP11" where the editor read the net "LED2_DRV").
fn loadPinoutNames(allocator: Allocator, path: []const u8) ?std.StringHashMapUnmanaged([]const u8) {
    const content = infra_fs.cwd().readFileAlloc(allocator, path, 1 << 18) catch return null;
    const parser_m = @import("sexpr/parser.zig");
    const nodes = parser_m.parse(allocator, content) catch return null;
    if (nodes.len == 0) return null;
    const top = nodes[0].asList() orelse return null;
    if (top.len < 2 or !std.mem.eql(u8, top[0].asAtom() orelse "", "pinout")) return null;
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (top[2..]) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len < 3 or !std.mem.eql(u8, cl[0].asAtom() orelse "", "pin")) continue;
        const id: []const u8 = if (cl[1].asNumber()) |n|
            (std.fmt.allocPrint(allocator, "{d}", .{@as(i64, @intFromFloat(n))}) catch continue)
        else
            (cl[1].asAtom() orelse cl[1].asString() orelse continue);
        const name = cl[2].asString() orelse (cl[2].asAtom() orelse continue);
        map.put(allocator, id, name) catch continue;
    }
    return map;
}

const JsonWire = struct {
    net: []const u8,
    points: std.ArrayListUnmanaged([2]f64),
    is_bus: bool,
};

/// A part's actual pin → net binding, read straight from the netlist. The editor
/// inspector reads nets from this (authoritative) instead of inferring them from
/// drawn wires — so a pin on a brand-new single-pin net (no wire rendered yet)
/// still shows its real net instead of appearing blank.
const PinNet = struct { pin: []const u8, net: []const u8 };

const JsonPassive = struct {
    ref: []const u8,
    component: []const u8,
    value: []const u8,
    symbol: []const u8,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    count: u32 = 1,
    src_offset: u32 = 0,
    /// True when the spoke sits on a left-going chain (its hub is to the right),
    /// so the renderer mirrors directional symbols (diode/LED) — the body is
    /// authored anode-toward-hub, so the cathode bar must face the far terminal
    /// on either side. Symmetric passives ignore it.
    flip: bool = false,
    /// Full (un-shortened) ref_des — used only to match against the netlist when
    /// filling `pin_nets`; not serialized.
    ref_full: []const u8 = "",
    /// Real pin→net bindings from the netlist (see `PinNet`).
    pin_nets: []const PinNet = &.{},
};

/// An instance the hub/spoke layout did not place (a floating passive — e.g. a
/// just-added cap with no hub-reaching net). Reported so the editor can stage it
/// for the user to drag onto a pin. Identity is the source offset, stable across
/// the build-time ref-des auto-renumber.
const JsonStaged = struct {
    ref: []const u8,
    component: []const u8,
    value: []const u8,
    symbol: []const u8,
    src_offset: u32 = 0,
    /// Real pin→net bindings from the netlist (a staged part can still name a
    /// net on a pin, e.g. one pin on "VDD2" with nothing else there yet).
    pin_nets: []const PinNet = &.{},
};

const JsonLabel = struct {
    text: []const u8,
    x: f64,
    y: f64,
    anchor: []const u8,
    is_port: bool,
    is_ground: bool,
};

const SceneGraph = struct {
    allocator: Allocator,
    vb_w: f64 = 0,
    vb_h: f64 = 0,
    design_name: []const u8 = "",
    sections: std.ArrayListUnmanaged(JsonSection),
    hubs: std.ArrayListUnmanaged(JsonHub),
    wires: std.ArrayListUnmanaged(JsonWire),
    passives: std.ArrayListUnmanaged(JsonPassive),
    labels: std.ArrayListUnmanaged(JsonLabel),
    staged: std.ArrayListUnmanaged(JsonStaged),
    /// Names of the design's authored `(section …)` / sub-block structure, so the
    /// editor's sheet navigator pages by authored section — and collapses to a
    /// single whole-design sheet when there are none — instead of auto per-IC.
    authored_sections: []const []const u8 = &.{},
    /// The design's top-level boundary `(port …)` forms, so the editor can list /
    /// add / remove them (the design-level interface view).
    ports: []const env_mod.Port = &.{},

    fn init(allocator: Allocator) SceneGraph {
        return .{
            .allocator = allocator,
            .sections = .empty,
            .hubs = .empty,
            .wires = .empty,
            .passives = .empty,
            .labels = .empty,
            .staged = .empty,
        };
    }

    fn addWire(self: *SceneGraph, net: []const u8, x1: f64, y1: f64, x2: f64, y2: f64, is_bus: bool) !void {
        var pts: std.ArrayListUnmanaged([2]f64) = .empty;
        if (y1 == y2) {
            try pts.append(self.allocator, .{ x1, y1 });
            try pts.append(self.allocator, .{ x2, y2 });
        } else {
            const mid_x = (x1 + x2) / HALF_DIVISOR;
            try pts.append(self.allocator, .{ x1, y1 });
            try pts.append(self.allocator, .{ mid_x, y1 });
            try pts.append(self.allocator, .{ mid_x, y2 });
            try pts.append(self.allocator, .{ x2, y2 });
        }
        try self.wires.append(self.allocator, .{
            .net = net,
            .points = pts,
            .is_bus = is_bus,
        });
    }

    fn addLabel(self: *SceneGraph, text: []const u8, x: f64, y: f64, anchor: []const u8, is_port: bool, is_ground: bool) !void {
        try self.labels.append(self.allocator, .{
            .text = text,
            .x = x,
            .y = y,
            .anchor = anchor,
            .is_port = is_port,
            .is_ground = is_ground,
        });
    }

    fn addPassive(self: *SceneGraph, inst: FlatInst, x: f64, y: f64, flip: bool) !void {
        try self.passives.append(self.allocator, .{
            .ref = shortRef(inst.ref_des),
            .component = inst.component,
            .value = inst.value,
            .symbol = inst.symbol,
            .x = x,
            .y = y,
            .w = passive_bw,
            .h = 20.0,
            .src_offset = inst.src_offset,
            .flip = flip,
            .ref_full = inst.ref_des,
        });
    }

    fn addPassiveWithCount(self: *SceneGraph, inst: FlatInst, x: f64, y: f64, count: u32, flip: bool) !void {
        try self.passives.append(self.allocator, .{
            .ref = shortRef(inst.ref_des),
            .component = inst.component,
            .value = inst.value,
            .symbol = inst.symbol,
            .x = x,
            .y = y,
            .w = passive_bw,
            .h = 20.0,
            .count = count,
            .src_offset = inst.src_offset,
            .flip = flip,
            .ref_full = inst.ref_des,
        });
    }
};

// ── Merge-aware height calculation ──────────────────────────────────

/// Compute group heights accounting for identical spoke merging.
/// Unlike hub_mod.groupHeights which counts every spoke individually,
/// this groups identical single-passive spokes and counts them as one slot.
fn mergeAwareGroupHeights(ctx: *RenderCtx, allocator: Allocator, groups: []const PinGroup, hub_ref: []const u8) ![]f64 {
    var heights = try allocator.alloc(f64, groups.len);
    for (groups, 0..) |group, i| {
        var total_slots: u32 = 0;

        // Classify connections for this group (same logic as collectGroupConnections)
        var classified: std.ArrayListUnmanaged(Classified) = .empty;
        for (group.conns) |conn| {
            switch (conn.endpoint) {
                .net => |net| {
                    const term = baseNetName(net);
                    if (!ctx.significant_nets.contains(term)) continue;
                    try classified.append(allocator, .{ .conn = conn, .terminal = term });
                },
                .pin => |p| {
                    if (ctx.spoke_set.contains(p.ref_des)) {
                        const term = try connection.getConnTerminal(ctx, conn.endpoint, hub_ref, conn.pin);
                        try classified.append(allocator, .{ .conn = conn, .terminal = term });
                    } else {
                        try classified.append(allocator, .{ .conn = conn, .terminal = "" });
                        total_slots += 1;
                        continue; // Non-spoke hub connections are always 1 slot, skip merge logic
                    }
                },
            }
        }

        // Now count slots with merge awareness for spoke/net connections
        if (classified.items.len > 0) {
            // Build merge keys for single-passive spokes
            const SpokeKey = struct { key: []const u8, is_mergeable: bool };
            var infos = try allocator.alloc(SpokeKey, classified.items.len);
            var consumed = try allocator.alloc(bool, classified.items.len);
            for (consumed) |*c| c.* = false;

            for (classified.items, 0..) |entry, j| {
                switch (entry.conn.endpoint) {
                    .pin => |p| {
                        if (ctx.spoke_set.contains(p.ref_des)) {
                            const inst = ctx.inst_map.get(p.ref_des) orelse {
                                infos[j] = .{ .key = "", .is_mergeable = false };
                                continue;
                            };
                            var visited: std.StringHashMapUnmanaged(void) = .empty;
                            try visited.put(allocator, p.ref_des, {});
                            const chain = try connection.findSpokeChain(ctx, p.ref_des, .{ .pin = .{ .ref_des = hub_ref, .pin = entry.conn.pin } }, &visited);
                            if (chain.chain.len == 0 and chain.branches.len == 0) {
                                const val = if (inst.value.len > 0) inst.value else inst.component;
                                infos[j] = .{
                                    .key = try std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{ entry.terminal, val, inst.symbol }),
                                    .is_mergeable = true,
                                };
                            } else {
                                infos[j] = .{ .key = "", .is_mergeable = false };
                            }
                        } else {
                            infos[j] = .{ .key = "", .is_mergeable = false };
                        }
                    },
                    .net => {
                        infos[j] = .{ .key = "", .is_mergeable = false };
                    },
                }
            }

            // Count slots: merged groups count as 1 slot
            for (classified.items, 0..) |_, j| {
                if (consumed[j]) continue;
                consumed[j] = true;

                if (!infos[j].is_mergeable or infos[j].key.len == 0) {
                    // Non-mergeable: count normally
                    switch (classified.items[j].conn.endpoint) {
                        .pin => |p| {
                            if (ctx.spoke_set.contains(p.ref_des)) {
                                total_slots += hub_mod.estimateBranchCount(ctx, p.ref_des, hub_ref);
                            } else {
                                total_slots += 1;
                            }
                        },
                        .net => total_slots += 1,
                    }
                } else {
                    // Mergeable: consume all identical and count as 1 slot
                    for (j + 1..classified.items.len) |k| {
                        if (consumed[k]) continue;
                        if (infos[k].is_mergeable and std.mem.eql(u8, infos[k].key, infos[j].key)) {
                            consumed[k] = true;
                        }
                    }
                    total_slots += 1;
                }
            }
        }

        const base: f64 = 40.0;
        heights[i] = base + @as(f64, @floatFromInt(@max(total_slots, 1) -| 1)) * per_conn_spacing;
    }
    return heights;
}

/// Mirror of `hub_mod.SplitGroups` for the merge-aware path.
const MergeAwareSplit = struct {
    left: []const PinGroup,
    right: []const PinGroup,
    left_heights: []f64,
    right_heights: []f64,
};

/// Balance hub pin groups into left/right columns by visual height
/// (merge-aware variant). Mirrors `hub_mod.splitGroupsByHeight` but
/// uses `mergeAwareGroupHeights` so identical single-passive spokes
/// (e.g. a row of decoupling caps tied to the same rail) collapse to
/// one slot. Greedy: walks groups in their `groupHubPins` order and
/// assigns each to whichever column is currently shorter.
fn splitGroupsByMergeAwareHeight(
    ctx: *RenderCtx,
    allocator: Allocator,
    all_groups: []const PinGroup,
    hub_ref: []const u8,
) !MergeAwareSplit {
    const all_heights = try mergeAwareGroupHeights(ctx, allocator, all_groups, hub_ref);
    defer allocator.free(all_heights);

    var left: std.ArrayListUnmanaged(PinGroup) = .empty;
    var right: std.ArrayListUnmanaged(PinGroup) = .empty;
    var left_h: std.ArrayListUnmanaged(f64) = .empty;
    var right_h: std.ArrayListUnmanaged(f64) = .empty;
    var left_total: f64 = 0;
    var right_total: f64 = 0;

    for (all_groups, all_heights) |group, h| {
        if (left_total <= right_total) {
            try left.append(allocator, group);
            try left_h.append(allocator, h);
            left_total += h;
        } else {
            try right.append(allocator, group);
            try right_h.append(allocator, h);
            right_total += h;
        }
    }

    return .{
        .left = try left.toOwnedSlice(allocator),
        .right = try right.toOwnedSlice(allocator),
        .left_heights = try left_h.toOwnedSlice(allocator),
        .right_heights = try right_h.toOwnedSlice(allocator),
    };
}

/// Compute hub height using merge-aware group heights.
fn mergeAwareHubHeight(ctx: *RenderCtx, allocator: Allocator, hub: FlatInst, part: ?env_mod.Part) !f64 {
    const adj_entries = if (ctx.adjacency.get(hub.ref_des)) |list| list.items else &[_]AdjEntry{};

    var all_pins_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer all_pins_list.deinit(allocator);

    if (part) |p| {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(allocator);
        for (p.pins) |pp| {
            if (!seen.contains(pp.pin)) {
                try seen.put(allocator, pp.pin, {});
                try all_pins_list.append(allocator, pp.pin);
            }
        }
    } else {
        for (ctx.nets.items) |net| {
            for (net.pins) |pin| {
                if (std.mem.eql(u8, pin.ref_des, hub.ref_des)) {
                    try all_pins_list.append(allocator, pin.pin);
                }
            }
        }
    }

    std.mem.sortUnstable([]const u8, all_pins_list.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return draw.pinOrder(a, b);
        }
    }.lt);

    const parts_for_names: []const env_mod.Part = if (part) |p2| &[_]env_mod.Part{p2} else hub.parts;
    var pn_map = hub_mod.buildPinNameMap(ctx, parts_for_names);
    defer pn_map.deinit(allocator);

    const all_groups = try hub_mod.groupHubPins(ctx, all_pins_list.items, adj_entries, &pn_map);
    const split = try splitGroupsByMergeAwareHeight(ctx, allocator, all_groups, hub.ref_des);
    const left_heights = split.left_heights;
    const right_heights = split.right_heights;

    var left_total: f64 = 0;
    for (left_heights) |h| left_total += h;
    var right_total: f64 = 0;
    for (right_heights) |h| right_total += h;

    return @max(left_total, right_total) + HUB_VPAD;
}

// ── Public entry point ───────────────────────────────────────────────

/// Render a design's hub/spoke schematic as a JSON scene graph for the
/// Pixi.js canvas viewer. Flattens sub-blocks, classifies each instance as
/// hub or spoke (passive), groups pins, lays out sections in a grid, and
/// emits hub boxes plus the wires/labels needed to render the schematic.
/// Collect the names of the design's authored structural sections — `(section …)`
/// forms (and their sub-sections) plus `(sub-block …)`s. These are what the
/// editor pages by; when the list is empty the design has no explicit sections
/// and the editor shows a single whole-design sheet.
fn collectAuthoredSections(allocator: Allocator, block: *const DesignBlock) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    for (block.sections) |sec| {
        try list.append(allocator, sec.name);
        for (sec.sub_sections) |sub| try list.append(allocator, sub.name);
    }
    for (block.sub_blocks) |sb| try list.append(allocator, sb.block.name);
    return list.items;
}

/// Build the editor / live-push scene-graph JSON for `block`: flatten + classify,
/// lay hubs out into section cells, collect spokes/wires/labels, and serialize.
pub fn renderSceneGraph(allocator: Allocator, block: *const DesignBlock, project_dir: []const u8) RenderError![]const u8 {
    var ctx = RenderCtx.init(allocator);
    ctx.project_dir = project_dir;

    // Shared flatten → classify → adjacency → net-index pipeline (the same one
    // render_html.setupRenderCtx runs); the JSON path additionally validates
    // net consistency afterward.
    try ctx.setup(block);
    try ctx.validateNetConsistency();

    var scene = SceneGraph.init(allocator);
    scene.design_name = block.name;
    scene.authored_sections = try collectAuthoredSections(allocator, block);
    scene.ports = block.ports;

    var alt_map: PinoutAltMap = .empty;
    var asserted_fns = try asserted_fns_mod.buildMap(allocator, block);

    // Build grid cells from sections (same as render_svg.zig)
    const GridCell = struct {
        hub_inst: FlatInst,
        part: ?env_mod.Part,
        section_idx: usize,
    };

    const SectionInfo = struct {
        name: []const u8,
        description: []const u8,
        notes: []const env_mod.SectionNote,
        cell_indices: std.ArrayListUnmanaged(usize),
    };
    var section_grid: std.ArrayListUnmanaged(SectionInfo) = .empty;
    var ref_to_section = std.StringHashMap(usize).init(allocator);

    for (block.sections) |sec| {
        const sec_idx = section_grid.items.len;
        try section_grid.append(allocator, .{ .name = sec.name, .description = sec.description, .notes = sec.notes, .cell_indices = .empty });
        for (sec.instances) |inst| {
            try ref_to_section.put(inst.ref_des, sec_idx);
        }
        for (sec.sub_sections) |sub| {
            const sub_idx = section_grid.items.len;
            try section_grid.append(allocator, .{ .name = sub.name, .description = sub.description, .notes = sub.notes, .cell_indices = .empty });
            for (sub.instances) |inst| {
                try ref_to_section.put(inst.ref_des, sub_idx);
            }
        }
    }
    // Add sub-blocks as sections
    for (block.sub_blocks) |sb| {
        const sec_idx = section_grid.items.len;
        try section_grid.append(allocator, .{ .name = sb.block.name, .description = "", .notes = &.{}, .cell_indices = .empty });
        for (sb.block.instances) |inst| {
            try ref_to_section.put(inst.ref_des, sec_idx);
        }
    }

    var cells: std.ArrayListUnmanaged(GridCell) = .empty;

    for (ctx.hub_order.items) |hub_ref| {
        const hub_inst = ctx.inst_map.get(hub_ref) orelse continue;
        if (hub_inst.parts.len > 0) {
            for (hub_inst.parts) |part| {
                var sec_idx: usize = 0;
                for (section_grid.items, 0..) |sg, si| {
                    if (std.mem.eql(u8, sg.name, part.name)) {
                        sec_idx = si;
                        break;
                    }
                }
                const ci = cells.items.len;
                try cells.append(allocator, .{ .hub_inst = hub_inst, .part = part, .section_idx = sec_idx });
                try section_grid.items[sec_idx].cell_indices.append(allocator, ci);
            }
        } else {
            const sec_idx = ref_to_section.get(hub_inst.ref_des) orelse blk: {
                for (section_grid.items, 0..) |sg, si| {
                    if (std.mem.eql(u8, sg.name, hub_inst.component)) break :blk si;
                }
                const si = section_grid.items.len;
                try section_grid.append(allocator, .{ .name = hub_inst.component, .description = "", .notes = &.{}, .cell_indices = .empty });
                break :blk si;
            };
            const ci = cells.items.len;
            try cells.append(allocator, .{ .hub_inst = hub_inst, .part = null, .section_idx = sec_idx });
            try section_grid.items[sec_idx].cell_indices.append(allocator, ci);
        }
    }

    // Auto grid dimensions
    const n_sections = section_grid.items.len;
    const n_cols: usize = if (n_sections == 0) 1 else blk: {
        var c: usize = 1;
        while (c * c < n_sections) : (c += 1) {}
        break :blk c;
    };
    const n_rows: usize = if (n_sections == 0) 1 else (n_sections + n_cols - 1) / n_cols;

    // Grid layout constants (same as render_svg.zig)
    const cell_width: f64 = 850.0;
    const cell_gap_y: f64 = 30.0;
    const cell_gap_x: f64 = 40.0;
    const section_pad: f64 = 30.0;
    const title_font_size: f64 = 24.0;
    const desc_font_size: f64 = 15.0;
    const note_line_height: f64 = 15.0;

    // Compute per-section header height
    var section_header_heights = try allocator.alloc(f64, section_grid.items.len);
    defer allocator.free(section_header_heights);
    for (section_grid.items, 0..) |sg, si| {
        var h: f64 = title_font_size + TITLE_LINE_GAP;
        if (sg.description.len > 0) h += desc_font_size + DESC_LINE_GAP;
        section_header_heights[si] = h;
    }

    // Compute per-section footer height
    var section_footer_heights = try allocator.alloc(f64, section_grid.items.len);
    defer allocator.free(section_footer_heights);
    for (section_grid.items, 0..) |sg, si| {
        if (sg.notes.len > 0) {
            section_footer_heights[si] = @as(f64, @floatFromInt(sg.notes.len)) * note_line_height + NOTE_BLOCK_PAD;
        } else {
            section_footer_heights[si] = 0;
        }
    }

    // Pass 1: Measure cell heights (merge-aware)
    var cell_heights = try allocator.alloc(f64, cells.items.len);
    defer allocator.free(cell_heights);

    for (cells.items, 0..) |cell, ci| {
        cell_heights[ci] = try mergeAwareHubHeight(&ctx, allocator, cell.hub_inst, cell.part);
    }

    // Compute row heights
    var row_heights = try allocator.alloc(f64, n_rows);
    defer allocator.free(row_heights);
    for (row_heights) |*rh| rh.* = 0;

    for (section_grid.items, 0..) |sg, si| {
        const grid_row = si / n_cols;
        var sec_height: f64 = 0;
        for (sg.cell_indices.items) |ci| {
            sec_height += cell_heights[ci] + CELL_BLOCK_GAP;
        }
        const total = sec_height + section_pad * 2 + section_header_heights[si] + section_footer_heights[si];
        if (total > row_heights[grid_row]) row_heights[grid_row] = total;
    }

    // Compute row y-positions
    const row_y_positions = try allocator.alloc(f64, n_rows);
    defer allocator.free(row_y_positions);
    var y: f64 = top_margin;
    for (row_y_positions, 0..) |*ry, i| {
        ry.* = y;
        y += row_heights[i] + cell_gap_y;
    }

    var total_width: f64 = cell_width;
    if (n_cols > 1) {
        total_width = @as(f64, @floatFromInt(n_cols)) * cell_width + @as(f64, @floatFromInt(n_cols - 1)) * cell_gap_x;
    }

    // Pass 2: Collect scene graph data for each section
    for (section_grid.items, 0..) |sg, si| {
        if (sg.cell_indices.items.len == 0) continue;
        const grid_row = si / n_cols;
        const grid_col = si % n_cols;
        const x_offset = @as(f64, @floatFromInt(grid_col)) * (cell_width + cell_gap_x);
        const cell_y = row_y_positions[grid_row];
        const section_h = row_heights[grid_row];
        const header_h = section_header_heights[si];

        try scene.sections.append(allocator, .{
            .name = sg.name,
            .description = sg.description,
            .notes = sg.notes,
            .x = x_offset + SECTION_PAD_X,
            .y = cell_y,
            .w = cell_width - SECTION_BORDER_W,
            .h = section_h,
        });

        var content_y = cell_y + header_h + section_pad;
        for (sg.cell_indices.items) |ci| {
            const cell = cells.items[ci];
            const h = cell_heights[ci];

            // Collect hub data
            const json_hub = try collectHubData(&ctx, allocator, cell.hub_inst, cell.part, x_offset, content_y, &alt_map, &asserted_fns);
            try scene.hubs.append(allocator, json_hub);

            // Collect connections for this hub (writes wires/passives straight
            // into `scene`; it doesn't mutate the JsonHub row appended above).
            try collectHubConnections(&ctx, &scene, allocator, cell.hub_inst, cell.part, x_offset, content_y);

            content_y += h + CELL_BLOCK_GAP;
        }
    }

    // Port blocks (skipped — interface ports not shown in schematic)

    // Real pin → net bindings per instance, straight from the netlist. The
    // editor reads these (authoritative) instead of inferring a pin's net from
    // drawn wires, so a pin on a fresh single-pin net (no wire yet) still shows
    // its name. Keyed by full ref_des (nets reference instances by full ref).
    var pinnet_map: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(PinNet)) = .empty;
    for (ctx.nets.items) |net| {
        const bn = baseNetName(net.name);
        for (net.pins) |pin| {
            const gop = try pinnet_map.getOrPut(allocator, pin.ref_des);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, .{ .pin = pin.pin, .net = bn });
        }
    }
    for (scene.passives.items) |*p| {
        if (pinnet_map.get(p.ref_full)) |list| p.pin_nets = list.items;
    }

    // Unplaced spokes: a passive the layout never drew or merged (a floating
    // part — e.g. a just-added cap with no hub-reaching net). Hubs are always
    // placed; a spoke is placed once it's drawn or merged into rendered_spokes.
    // Reported so the editor can stage these for the user to wire by drag.
    for (ctx.instances.items) |inst| {
        if (!ctx.spoke_set.contains(inst.ref_des)) continue;
        if (ctx.rendered_spokes.contains(inst.ref_des)) continue;
        try scene.staged.append(allocator, .{
            .ref = shortRef(inst.ref_des),
            .component = inst.component,
            .value = inst.value,
            .symbol = inst.symbol,
            .src_offset = inst.src_offset,
            .pin_nets = if (pinnet_map.get(inst.ref_des)) |list| list.items else &.{},
        });
    }

    // Set viewBox
    scene.vb_w = @max(total_width, MIN_VB_WIDTH);
    scene.vb_h = @max(y + VB_MARGIN, MIN_VB_HEIGHT);

    // Serialize to JSON
    return serializeScene(allocator, &scene);
}

const BranchResult = struct { end_x: f64, cy: f64, terminal: []const u8 };
const Classified = struct { conn: AdjEntry, terminal: []const u8 };

// ── Hub data collection ──────────────────────────────────────────────

fn collectHubData(
    ctx: *RenderCtx,
    allocator: Allocator,
    hub: FlatInst,
    part: ?env_mod.Part,
    x_offset: f64,
    y_start: f64,
    alt_map: *PinoutAltMap,
    asserted_fns: *const std.StringHashMapUnmanaged([]const u8),
) !JsonHub {
    try loadPinoutAlts(allocator, alt_map, ctx.project_dir, hub.symbol);
    // Get pin groups (reuse hub.zig logic)
    const adj_entries = if (ctx.adjacency.get(hub.ref_des)) |list| list.items else &[_]AdjEntry{};

    var all_pins_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer all_pins_list.deinit(allocator);

    if (part) |p| {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(allocator);
        for (p.pins) |pp| {
            if (!seen.contains(pp.pin)) {
                try seen.put(allocator, pp.pin, {});
                try all_pins_list.append(allocator, pp.pin);
            }
        }
    } else {
        for (ctx.nets.items) |net| {
            for (net.pins) |pin| {
                if (std.mem.eql(u8, pin.ref_des, hub.ref_des)) {
                    try all_pins_list.append(allocator, pin.pin);
                }
            }
        }
    }

    std.mem.sortUnstable([]const u8, all_pins_list.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return draw.pinOrder(a, b);
        }
    }.lt);

    const parts_for_names: []const env_mod.Part = if (part) |p| &[_]env_mod.Part{p} else hub.parts;
    var pn_map = hub_mod.buildPinNameMap(ctx, parts_for_names);
    defer pn_map.deinit(allocator);
    // Flat `(pin …)` instances carry no part-level pin names, so supplement from
    // the component's pinout file — hub pins then read by function ("GP11") like
    // the HTML schematic, not by the net they reach ("LED2_DRV"). First existing
    // file wins; existing part-level names are never overwritten. Grouping is
    // net-based, so this only changes labels, never group membership/positions.
    if (ctx.project_dir.len > 0) {
        for ([_][]const u8{ hub.pinout, hub.symbol, hub.component }) |cand| {
            if (cand.len == 0) continue;
            const path = std.fmt.allocPrint(allocator, "{s}/lib/pinouts/{s}.sexp", .{ ctx.project_dir, cand }) catch continue;
            defer allocator.free(path);
            var pinmap = loadPinoutNames(allocator, path) orelse continue;
            var it = pinmap.iterator();
            while (it.next()) |kv| {
                if (!pn_map.contains(kv.key_ptr.*)) pn_map.put(allocator, kv.key_ptr.*, kv.value_ptr.*) catch break;
            }
            if (pn_map.count() > 0) break;
        }
    }

    const all_groups = try hub_mod.groupHubPins(ctx, all_pins_list.items, adj_entries, &pn_map);
    const split = try splitGroupsByMergeAwareHeight(ctx, allocator, all_groups, hub.ref_des);
    const left_groups = split.left;
    const right_groups = split.right;
    const left_heights = split.left_heights;
    const right_heights = split.right_heights;

    var left_total: f64 = 0;
    for (left_heights) |h| left_total += h;
    var right_total: f64 = 0;
    for (right_heights) |h| right_total += h;
    const hub_height = @max(left_total, right_total) + HUB_VPAD;

    const label = try std.fmt.allocPrint(allocator, "{s} {s}", .{ shortRef(hub.ref_des), displayValue(hub) });

    const icon = draw.classifyComponent(hub);

    var json_hub = JsonHub{
        .ref = hub.ref_des,
        .component = hub.component,
        .value = hub.value,
        .symbol = hub.symbol,
        .part = if (part) |p| p.name else null,
        .label = label,
        .x = x_offset + hub_x,
        .y = y_start,
        .w = hub_width,
        .h = hub_height,
        .icon = icon,
        .src_offset = hub.src_offset,
        .left_pins = .empty,
        .right_pins = .empty,
    };

    // Collect left pin positions
    var py_left = y_start + HUB_VPAD;
    for (left_groups, 0..) |group, gi| {
        const height = left_heights[gi];
        const pin_cy = py_left + height / HALF_DIVISOR;
        const enrich = pinEnrichment(allocator, group, hub.ref_des, hub.symbol, alt_map, asserted_fns);
        try json_hub.left_pins.append(allocator, .{
            .pin_numbers = group.pin_numbers,
            .display_name = group.display_name,
            .y = pin_cy,
            .side = "left",
            .alts = enrich.alts,
            .active_fn = enrich.active_fn,
        });
        py_left += height;
    }

    // Collect right pin positions
    var py_right = y_start + HUB_VPAD;
    for (right_groups, 0..) |group, gi| {
        const height = right_heights[gi];
        const pin_cy = py_right + height / HALF_DIVISOR;
        const enrich = pinEnrichment(allocator, group, hub.ref_des, hub.symbol, alt_map, asserted_fns);
        try json_hub.right_pins.append(allocator, .{
            .pin_numbers = group.pin_numbers,
            .display_name = group.display_name,
            .y = pin_cy,
            .side = "right",
            .alts = enrich.alts,
            .active_fn = enrich.active_fn,
        });
        py_right += height;
    }

    return json_hub;
}

const PinEnrichment = struct {
    alts: []const []const u8 = &.{},
    active_fn: []const u8 = "",
};

/// Return alt-function metadata for a single-pin group. Multi-pin groups get empty alts.
fn pinEnrichment(
    allocator: Allocator,
    group: PinGroup,
    ref_des: []const u8,
    symbol: []const u8,
    alt_map: *PinoutAltMap,
    asserted_fns: *const std.StringHashMapUnmanaged([]const u8),
) PinEnrichment {
    if (std.mem.indexOfScalar(u8, group.pin_numbers, ',')) |_| return .{};
    const pin_id = group.pin_numbers;

    var result = PinEnrichment{};
    if (alt_map.get(symbol)) |by_pin| {
        if (by_pin.get(pin_id)) |alts| result.alts = alts;
    }
    const key = std.fmt.allocPrint(allocator, "{s}|{s}", .{ ref_des, pin_id }) catch return result;
    if (asserted_fns.get(key)) |fn_name| result.active_fn = fn_name;
    return result;
}

// ── Connection collection ────────────────────────────────────────────

fn collectHubConnections(
    ctx: *RenderCtx,
    scene: *SceneGraph,
    allocator: Allocator,
    hub: FlatInst,
    part: ?env_mod.Part,
    x_offset: f64,
    y_start: f64,
) !void {
    const adj_entries = if (ctx.adjacency.get(hub.ref_des)) |list| list.items else &[_]AdjEntry{};

    var all_pins_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer all_pins_list.deinit(allocator);

    if (part) |p| {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(allocator);
        for (p.pins) |pp| {
            if (!seen.contains(pp.pin)) {
                try seen.put(allocator, pp.pin, {});
                try all_pins_list.append(allocator, pp.pin);
            }
        }
    } else {
        for (ctx.nets.items) |net| {
            for (net.pins) |pin| {
                if (std.mem.eql(u8, pin.ref_des, hub.ref_des)) {
                    try all_pins_list.append(allocator, pin.pin);
                }
            }
        }
    }

    std.mem.sortUnstable([]const u8, all_pins_list.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return draw.pinOrder(a, b);
        }
    }.lt);

    const parts_for_names: []const env_mod.Part = if (part) |p| &[_]env_mod.Part{p} else hub.parts;
    var pn_map = hub_mod.buildPinNameMap(ctx, parts_for_names);
    defer pn_map.deinit(allocator);

    const all_groups = try hub_mod.groupHubPins(ctx, all_pins_list.items, adj_entries, &pn_map);
    // Must mirror collectHubData's split exactly. That pass balances groups
    // left/right by merge-aware *height* and places each pin by accumulating
    // those heights; if this pass splits differently (it used to balance by pin
    // *count*), a pin's connection wire is emitted on a different side / y than
    // the pin is drawn at — so nets visibly miss the IC pads. Share the one
    // split so every wire meets its pin.
    const split = try splitGroupsByMergeAwareHeight(ctx, allocator, all_groups, hub.ref_des);
    const left_groups = split.left;
    const right_groups = split.right;
    const left_heights = split.left_heights;
    const right_heights = split.right_heights;

    // Collect left connections
    var py_left = y_start + HUB_VPAD;
    for (left_groups, 0..) |group, gi| {
        const height = left_heights[gi];
        const pin_cy = py_left + height / HALF_DIVISOR;
        const stub_x = x_offset + hub_x - pin_stub;
        try collectGroupConnections(ctx, scene, allocator, hub.ref_des, group, stub_x, pin_cy, .left);
        py_left += height;
    }

    // Collect right connections
    var py_right = y_start + HUB_VPAD;
    for (right_groups, 0..) |group, gi| {
        const height = right_heights[gi];
        const pin_cy = py_right + height / HALF_DIVISOR;
        const stub_x = x_offset + hub_x + hub_width + pin_stub;
        try collectGroupConnections(ctx, scene, allocator, hub.ref_des, group, stub_x, pin_cy, .right);
        py_right += height;
    }
}

fn collectGroupConnections(
    ctx: *RenderCtx,
    scene: *SceneGraph,
    allocator: Allocator,
    hub_ref: []const u8,
    group: PinGroup,
    stub_x: f64,
    py: f64,
    side: Side,
) !void {
    if (group.conns.len == 0) return;

    var first_pin_id: []const u8 = "";
    for (group.conns) |c| {
        first_pin_id = c.pin;
        break;
    }
    const canon_key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ hub_ref, first_pin_id });
    const pin_net_name = ctx.pin_canonical_nets.get(canon_key) orelse "";

    var classified: std.ArrayListUnmanaged(Classified) = .empty;

    for (group.conns) |conn| {
        switch (conn.endpoint) {
            .net => |net| {
                const term = baseNetName(net);
                if (!ctx.significant_nets.contains(term)) continue;
                if (std.mem.eql(u8, term, baseNetName(pin_net_name))) {
                    var should_show = false;
                    if (ctx.port_nets.contains(term)) should_show = true;
                    if (!should_show) {
                        if (ctx.net_index.get(term)) |nps| {
                            const my_section = ctx.section_map.get(hub_ref);
                            for (nps.items) |np| {
                                if (ctx.rendered_spokes.contains(np.ref_des)) {
                                    should_show = true;
                                    break;
                                }
                                if (!ctx.spoke_set.contains(np.ref_des) and !std.mem.eql(u8, np.ref_des, hub_ref)) {
                                    should_show = true;
                                    break;
                                }
                                // Spoke in a different section: net crosses section boundaries,
                                // so the label belongs on this side of the crossing too.
                                if (ctx.spoke_set.contains(np.ref_des)) {
                                    const other_section = ctx.section_map.get(np.ref_des);
                                    if (my_section != null and other_section != null and my_section.? != other_section.?) {
                                        should_show = true;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    if (!should_show) continue;
                }
                try classified.append(allocator, .{ .conn = conn, .terminal = term });
            },
            .pin => |p| {
                if (ctx.rendered_spokes.contains(p.ref_des)) continue;
                const term = try connection.getConnTerminal(ctx, conn.endpoint, hub_ref, conn.pin);
                try classified.append(allocator, .{ .conn = conn, .terminal = term });
            },
        }
    }

    if (classified.items.len == 0) return;

    std.mem.sortUnstable(Classified, classified.items, {}, struct {
        fn lt(_: void, a: Classified, b: Classified) bool {
            return std.mem.lessThan(u8, a.terminal, b.terminal);
        }
    }.lt);

    // Merge identical single-passive spokes to the same terminal (e.g. 5x 100nF decoupling caps to GND)
    const merged = try mergeIdenticalSpokes(ctx, allocator, classified.items, hub_ref);

    var slot_counts = try allocator.alloc(u32, merged.items.len);
    var total_slots: u32 = 0;
    for (merged.items, 0..) |entry, i| {
        const slots: u32 = if (entry.merge_count > 1) 1 else switch (entry.classified.conn.endpoint) {
            .pin => |p| blk: {
                if (ctx.spoke_set.contains(p.ref_des)) {
                    break :blk hub_mod.estimateBranchCount(ctx, p.ref_des, hub_ref);
                }
                break :blk 1;
            },
            .net => 1,
        };
        slot_counts[i] = slots;
        total_slots += slots;
    }

    const multi = merged.items.len > 1;
    const bus_offset: f64 = BUS_OFFSET;
    const bus_x: f64 = switch (side) {
        .left => stub_x - bus_offset,
        .right => stub_x + bus_offset,
    };

    var consumed_slots: u32 = 0;
    var min_cy: f64 = py;
    var max_cy: f64 = py;
    const total_h2 = @as(f64, @floatFromInt(@max(total_slots, 1) -| 1)) * per_conn_spacing;

    var results: std.ArrayListUnmanaged(BranchResult) = .empty;

    for (merged.items, 0..) |entry, i| {
        const slots = slot_counts[i];
        const slot_center = @as(f64, @floatFromInt(consumed_slots)) + @as(f64, @floatFromInt(slots -| 1)) / HALF_DIVISOR;
        const cy = py + slot_center * per_conn_spacing - total_h2 / HALF_DIVISOR;
        consumed_slots += slots;
        if (cy < min_cy) min_cy = cy;
        if (cy > max_cy) max_cy = cy;

        const internal_net: []const u8 = switch (entry.classified.conn.endpoint) {
            .net => entry.classified.terminal,
            .pin => pin_net_name,
        };

        const conn_stub_x = if (multi) bus_x else stub_x;
        const conn_stub_y = if (multi) cy else py;

        if (entry.merge_count > 1) {
            const end_x = try collectMergedPassive(
                ctx,
                scene,
                allocator,
                entry.classified.conn.endpoint,
                conn_stub_x,
                conn_stub_y,
                cy,
                side,
                internal_net,
                entry.merge_count,
            );
            try results.append(allocator, .{ .end_x = end_x, .cy = cy, .terminal = entry.classified.terminal });
        } else {
            const end_x = try collectConnBody(
                ctx,
                scene,
                allocator,
                entry.classified.conn.endpoint,
                hub_ref,
                entry.classified.conn.pin,
                conn_stub_x,
                conn_stub_y,
                cy,
                side,
                internal_net,
            );
            try results.append(allocator, .{ .end_x = end_x, .cy = cy, .terminal = entry.classified.terminal });
        }
    }

    // Bus wires
    if (multi) {
        try scene.addWire(pin_net_name, stub_x, py, bus_x, py, false);
        if (min_cy != max_cy) {
            try scene.addWire(pin_net_name, bus_x, min_cy, bus_x, max_cy, true);
        }
    }

    // Terminal labels
    var default_term_x: f64 = switch (side) {
        .left => stub_x - spoke_len - PIN_OFFSET,
        .right => stub_x + spoke_len + PIN_OFFSET,
    };
    for (results.items) |r| {
        switch (side) {
            .left => default_term_x = @min(default_term_x, r.end_x - PIN_OFFSET),
            .right => default_term_x = @max(default_term_x, r.end_x + PIN_OFFSET),
        }
    }
    const term_x = default_term_x;

    try collectTerminals(ctx, scene, allocator, results.items, term_x, side);
}

const MergedEntry = struct {
    classified: Classified,
    merge_count: u32,
};

/// Find groups of identical single-passive spoke connections to the same terminal
/// and collapse them into one entry with a count (e.g. "5x 100nF" to GND).
fn mergeIdenticalSpokes(ctx: *RenderCtx, allocator: Allocator, classified: []const Classified, hub_ref: []const u8) !std.ArrayListUnmanaged(MergedEntry) {
    var result: std.ArrayListUnmanaged(MergedEntry) = .empty;

    // Build a key for each spoke connection: "terminal|value|symbol"
    // Non-spoke connections get unique keys so they never merge.
    const SpokeInfo = struct { key: []const u8, is_single_spoke: bool };
    var infos = try allocator.alloc(SpokeInfo, classified.len);
    var consumed = try allocator.alloc(bool, classified.len);
    for (consumed) |*c| c.* = false;

    for (classified, 0..) |entry, i| {
        switch (entry.conn.endpoint) {
            .pin => |p| {
                if (ctx.spoke_set.contains(p.ref_des)) {
                    const inst = ctx.inst_map.get(p.ref_des) orelse {
                        infos[i] = .{ .key = "", .is_single_spoke = false };
                        continue;
                    };
                    // Check it's a single passive (no chain)
                    var visited: std.StringHashMapUnmanaged(void) = .empty;
                    try visited.put(allocator, p.ref_des, {});
                    const chain = try connection.findSpokeChain(ctx, p.ref_des, .{ .pin = .{ .ref_des = hub_ref, .pin = entry.conn.pin } }, &visited);
                    if (chain.chain.len == 0 and chain.branches.len == 0) {
                        // Single passive to terminal — mergeable
                        const val = if (inst.value.len > 0) inst.value else inst.component;
                        infos[i] = .{
                            .key = try std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{ entry.terminal, val, inst.symbol }),
                            .is_single_spoke = true,
                        };
                    } else {
                        infos[i] = .{ .key = "", .is_single_spoke = false };
                    }
                } else {
                    infos[i] = .{ .key = "", .is_single_spoke = false };
                }
            },
            .net => {
                infos[i] = .{ .key = "", .is_single_spoke = false };
            },
        }
    }

    // Group by key
    for (classified, 0..) |entry, i| {
        if (consumed[i]) continue;
        if (!infos[i].is_single_spoke or infos[i].key.len == 0) {
            try result.append(allocator, .{ .classified = entry, .merge_count = 1 });
            consumed[i] = true;
            continue;
        }
        // Count identical entries
        var count: u32 = 1;
        for (classified[i + 1 ..], i + 1..) |_, j| {
            if (consumed[j]) continue;
            if (infos[j].is_single_spoke and std.mem.eql(u8, infos[j].key, infos[i].key)) {
                count += 1;
                consumed[j] = true;
                // Mark the merged spoke as rendered so SVG renderer doesn't re-draw
                switch (classified[j].conn.endpoint) {
                    .pin => |p2| try ctx.rendered_spokes.put(allocator, p2.ref_des, {}),
                    .net => {},
                }
            }
        }
        try result.append(allocator, .{ .classified = entry, .merge_count = count });
        consumed[i] = true;
    }

    return result;
}

/// Render a merged passive: one symbol with "Nx value" label. A merged passive
/// is a run of identical single-passive spokes collapsed into one symbol; its
/// chain end-x is fixed by the passive width alone, so — unlike the unmerged
/// `collectConnBody` — there is no terminal to walk to here.
fn collectMergedPassive(
    ctx: *RenderCtx,
    scene: *SceneGraph,
    allocator: Allocator,
    endpoint: Endpoint,
    stub_x: f64,
    stub_y: f64,
    cy: f64,
    side: Side,
    net_name: []const u8,
    count: u32,
) !f64 {
    switch (endpoint) {
        .net => {
            const end_x: f64 = switch (side) {
                .left => stub_x - PIN_OFFSET,
                .right => stub_x + PIN_OFFSET,
            };
            try scene.addWire(net_name, stub_x, stub_y, end_x, cy, false);
            return end_x;
        },
        .pin => |p| {
            const inst = ctx.inst_map.get(p.ref_des) orelse return stub_x;
            try ctx.rendered_spokes.put(allocator, p.ref_des, {});

            switch (side) {
                .left => {
                    try scene.addWire(net_name, stub_x, stub_y, stub_x - PIN_OFFSET, cy, false);
                    try scene.addPassiveWithCount(inst, stub_x - PIN_OFFSET - passive_bw, cy, count, true);
                    return stub_x - PIN_OFFSET - passive_bw;
                },
                .right => {
                    try scene.addWire(net_name, stub_x, stub_y, stub_x + PIN_OFFSET, cy, false);
                    try scene.addPassiveWithCount(inst, stub_x + PIN_OFFSET, cy, count, false);
                    return stub_x + PIN_OFFSET + passive_bw;
                },
            }
        },
    }
}

fn collectConnBody(
    ctx: *RenderCtx,
    scene: *SceneGraph,
    allocator: Allocator,
    endpoint: Endpoint,
    hub_ref: []const u8,
    from_pin: []const u8,
    stub_x: f64,
    stub_y: f64,
    cy: f64,
    side: Side,
    net_name: []const u8,
) !f64 {
    switch (endpoint) {
        .net => {
            const end_x: f64 = switch (side) {
                .left => stub_x - PIN_OFFSET,
                .right => stub_x + PIN_OFFSET,
            };
            try scene.addWire(net_name, stub_x, stub_y, end_x, cy, false);
            return end_x;
        },
        .pin => |p| {
            if (ctx.spoke_set.contains(p.ref_des)) {
                if (ctx.rendered_spokes.contains(p.ref_des)) {
                    return stub_x;
                }

                const inst = ctx.inst_map.get(p.ref_des) orelse return stub_x;
                try ctx.rendered_spokes.put(allocator, p.ref_des, {});

                var visited: std.StringHashMapUnmanaged(void) = .empty;
                try visited.put(allocator, p.ref_des, {});
                const chain_result = try connection.findSpokeChain(ctx, p.ref_des, .{ .pin = .{ .ref_des = hub_ref, .pin = from_pin } }, &visited);

                for (chain_result.chain) |c| {
                    try ctx.rendered_spokes.put(allocator, c.ref_des, {});
                }

                var all_spokes: std.ArrayListUnmanaged(FlatInst) = .empty;
                try all_spokes.append(allocator, inst);
                for (chain_result.chain) |c| try all_spokes.append(allocator, c);

                switch (side) {
                    .left => {
                        try scene.addWire(net_name, stub_x, stub_y, stub_x - PIN_OFFSET, cy, false);
                        const chain_end_x = try collectPassiveChainLeft(scene, allocator, stub_x - PIN_OFFSET, cy, all_spokes.items);
                        if (chain_result.branches.len > 0) {
                            try collectBranchTreeLeft(ctx, scene, allocator, chain_end_x, cy, chain_result.branches, chain_result.terminal);
                        }
                        return chain_end_x;
                    },
                    .right => {
                        try scene.addWire(net_name, stub_x, stub_y, stub_x + PIN_OFFSET, cy, false);
                        const chain_end_x = try collectPassiveChainRight(scene, allocator, stub_x + PIN_OFFSET, cy, all_spokes.items);
                        if (chain_result.branches.len > 0) {
                            try collectBranchTreeRight(ctx, scene, allocator, chain_end_x, cy, chain_result.branches, chain_result.terminal);
                        }
                        return chain_end_x;
                    },
                }
            } else {
                const end_x: f64 = switch (side) {
                    .left => stub_x - spoke_len - PIN_OFFSET,
                    .right => stub_x + spoke_len + PIN_OFFSET,
                };
                try scene.addWire(net_name, stub_x, stub_y, end_x, cy, false);
                return end_x;
            }
        },
    }
}

fn collectPassiveChainLeft(scene: *SceneGraph, _: Allocator, start_x: f64, cy: f64, spokes: []const FlatInst) !f64 {
    if (spokes.len == 0) return start_x;
    var x = start_x;
    for (spokes, 0..) |inst, i| {
        if (i > 0) {
            try scene.addWire("", x, cy, x - PIN_OFFSET, cy, false);
            x -= PIN_OFFSET;
        }
        try scene.addPassive(inst, x - passive_bw, cy, true); // left chain: hub on the right
        x -= passive_bw;
    }
    return x;
}

fn collectPassiveChainRight(scene: *SceneGraph, allocator: Allocator, start_x: f64, cy: f64, spokes: []const FlatInst) !f64 {
    _ = allocator;
    if (spokes.len == 0) return start_x;
    var x = start_x;
    for (spokes, 0..) |inst, i| {
        if (i > 0) {
            try scene.addWire("", x, cy, x + PIN_OFFSET, cy, false);
            x += PIN_OFFSET;
        }
        try scene.addPassive(inst, x, cy, false); // right chain: hub on the left
        x += passive_bw;
    }
    return x;
}

fn collectBranchTreeLeft(
    ctx: *RenderCtx,
    scene: *SceneGraph,
    allocator: Allocator,
    junction_x: f64,
    center_y: f64,
    branches: []const ctx_mod.Branch,
    junction_net: []const u8,
) !void {
    const n = branches.len;
    const total_height = @as(f64, @floatFromInt(n -| 1)) * branch_spacing;
    const start_y = center_y - total_height / HALF_DIVISOR;

    const bx = junction_x - bus_gap;
    try scene.addWire(junction_net, junction_x, center_y, bx, center_y, false);
    if (n > 1) {
        try scene.addWire(junction_net, bx, start_y, bx, start_y + total_height, true);
    }

    const BranchBody = struct { end_x: f64, cy: f64, terminal: []const u8 };
    var bodies: std.ArrayListUnmanaged(BranchBody) = .empty;

    for (branches, 0..) |branch, idx| {
        const by = start_y + @as(f64, @floatFromInt(idx)) * branch_spacing;
        try scene.addWire(junction_net, bx, by, bx - BRANCH_BUS_GAP, by, false);
        const chain_end_x = try collectPassiveChainLeft(scene, allocator, bx - BRANCH_BUS_GAP, by, branch.chain);
        try bodies.append(allocator, .{ .end_x = chain_end_x, .cy = by, .terminal = branch.terminal });
    }

    // Terminals
    var term_x: f64 = 0;
    for (bodies.items) |b| {
        const tx = b.end_x - PIN_OFFSET;
        if (term_x == 0 or tx < term_x) term_x = tx;
    }
    for (bodies.items) |b| {
        try scene.addWire(b.terminal, b.end_x, b.cy, term_x, b.cy, false);
    }
    if (bodies.items.len > 0) {
        const last = bodies.items[bodies.items.len - 1];
        try collectTerminalLabel(ctx, scene, term_x, last.cy, last.terminal, "end");
    }
}

fn collectBranchTreeRight(
    ctx: *RenderCtx,
    scene: *SceneGraph,
    allocator: Allocator,
    junction_x: f64,
    center_y: f64,
    branches: []const ctx_mod.Branch,
    junction_net: []const u8,
) !void {
    const n = branches.len;
    const total_height = @as(f64, @floatFromInt(n -| 1)) * branch_spacing;
    const start_y = center_y - total_height / HALF_DIVISOR;

    const bx = junction_x + bus_gap;
    try scene.addWire(junction_net, junction_x, center_y, bx, center_y, false);
    if (n > 1) {
        try scene.addWire(junction_net, bx, start_y, bx, start_y + total_height, true);
    }

    const BranchBody = struct { end_x: f64, cy: f64, terminal: []const u8 };
    var bodies: std.ArrayListUnmanaged(BranchBody) = .empty;

    for (branches, 0..) |branch, idx| {
        const by = start_y + @as(f64, @floatFromInt(idx)) * branch_spacing;
        try scene.addWire(junction_net, bx, by, bx + BRANCH_BUS_GAP, by, false);
        const chain_end_x = try collectPassiveChainRight(scene, allocator, bx + BRANCH_BUS_GAP, by, branch.chain);
        try bodies.append(allocator, .{ .end_x = chain_end_x, .cy = by, .terminal = branch.terminal });
    }

    var term_x: f64 = 0;
    for (bodies.items) |b| {
        const tx = b.end_x + PIN_OFFSET;
        if (term_x == 0 or tx > term_x) term_x = tx;
    }
    for (bodies.items) |b| {
        try scene.addWire(b.terminal, b.end_x, b.cy, term_x, b.cy, false);
    }
    if (bodies.items.len > 0) {
        const last = bodies.items[bodies.items.len - 1];
        try collectTerminalLabel(ctx, scene, term_x, last.cy, last.terminal, "start");
    }
}

fn collectTerminals(ctx: *RenderCtx, scene: *SceneGraph, _: Allocator, results: []const BranchResult, term_x: f64, side: Side) !void {
    if (results.len == 0) return;

    const anchor: []const u8 = switch (side) {
        .left => "end",
        .right => "start",
    };

    var i: usize = 0;
    while (i < results.len) {
        const term = results[i].terminal;
        var j = i + 1;
        while (j < results.len) : (j += 1) {
            if (!std.mem.eql(u8, results[j].terminal, term)) break;
        }
        const group_slice = results[i..j];

        if (!ctx.significant_nets.contains(term)) {
            i = j;
            continue;
        }

        if (group_slice.len == 1) {
            const r = group_slice[0];
            try scene.addWire(term, r.end_x, r.cy, term_x, r.cy, false);
            try collectTerminalLabel(ctx, scene, term_x, r.cy, term, anchor);
        } else {
            const nearest_x = blk: {
                var nx: f64 = switch (side) {
                    .left => FAR_X_SENTINEL,
                    .right => -FAR_X_SENTINEL,
                };
                for (group_slice) |r| {
                    switch (side) {
                        .left => nx = @min(nx, r.end_x),
                        .right => nx = @max(nx, r.end_x),
                    }
                }
                break :blk nx;
            };
            const grp_bus_x = switch (side) {
                .left => nearest_x - PIN_OFFSET,
                .right => nearest_x + PIN_OFFSET,
            };

            const first_cy = group_slice[0].cy;
            const last_cy = group_slice[group_slice.len - 1].cy;

            for (group_slice) |r| {
                try scene.addWire(term, r.end_x, r.cy, grp_bus_x, r.cy, false);
            }
            try scene.addWire(term, grp_bus_x, first_cy, grp_bus_x, last_cy, true);
            try scene.addWire(term, grp_bus_x, last_cy, term_x, last_cy, false);
            try collectTerminalLabel(ctx, scene, term_x, last_cy, term, anchor);
        }

        i = j;
    }
}

fn collectTerminalLabel(ctx: *RenderCtx, scene: *SceneGraph, end_x: f64, cy: f64, term: []const u8, anchor: []const u8) !void {
    const display = baseNetName(term);
    if (isGroundNet(display)) {
        try scene.addLabel(display, end_x, cy, anchor, false, true);
    } else {
        const is_port = ctx.port_nets.contains(term) or ctx.port_nets.contains(display);
        const label_x: f64 = if (std.mem.eql(u8, anchor, "end")) end_x - net_label_gap else end_x + net_label_gap;
        try scene.addLabel(display, label_x, cy, anchor, is_port, false);
    }
}

// ── JSON Serialization ───────────────────────────────────────────────

fn serializeScene(allocator: Allocator, scene: *const SceneGraph) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);

    try w.writeAll("{");

    // ViewBox
    try w.print("\"viewBox\":{{\"w\":{d:.0},\"h\":{d:.0}}}", .{ scene.vb_w, scene.vb_h });
    try w.writeAll(",\"name\":");
    try json_writer.writeString(w, scene.design_name);

    // Sections
    try w.writeAll(",\"sections\":[");
    for (scene.sections.items, 0..) |sec, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{");
        try writeJsonString(w, "name", sec.name);
        try w.writeAll(",");
        try writeJsonString(w, "description", sec.description);
        try w.print(",\"x\":{d:.1},\"y\":{d:.1},\"w\":{d:.1},\"h\":{d:.1}", .{ sec.x, sec.y, sec.w, sec.h });
        try w.writeAll(",\"notes\":[");
        for (sec.notes, 0..) |note, ni| {
            if (ni > 0) try w.writeAll(",");
            try w.writeAll("{\"text\":\"");
            try writeEscaped(w, note.text);
            try w.writeAll("\"");
            if (note.ref) |r| {
                try w.writeAll(",\"pdf\":\"");
                try writeEscaped(w, r.pdf);
                try w.print("\",\"page\":{d}", .{r.page});
            }
            try w.writeAll("}");
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]");

    // Hubs
    try w.writeAll(",\"hubs\":[");
    for (scene.hubs.items, 0..) |h, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{");
        try writeJsonString(w, "ref", h.ref);
        try w.writeAll(",");
        try writeJsonString(w, "component", h.component);
        try w.writeAll(",");
        try writeJsonString(w, "value", h.value);
        try w.writeAll(",");
        try writeJsonString(w, "symbol", h.symbol);
        try w.writeAll(",");
        if (h.part) |p| {
            try writeJsonString(w, "part", p);
        } else {
            try w.writeAll("\"part\":null");
        }
        try w.writeAll(",");
        try writeJsonString(w, "label", h.label);
        try w.print(",\"x\":{d:.1},\"y\":{d:.1},\"w\":{d:.0},\"h\":{d:.1}", .{ h.x, h.y, h.w, h.h });
        if (h.icon) |ic| {
            try w.writeAll(",");
            try writeJsonString(w, "icon", ic);
        } else {
            try w.writeAll(",\"icon\":null");
        }
        try w.print(",\"src\":{d}", .{h.src_offset});

        // Left pins
        try w.writeAll(",\"leftPins\":[");
        for (h.left_pins.items, 0..) |pin, pi| {
            if (pi > 0) try w.writeAll(",");
            try writeJsonPin(w, pin);
        }
        try w.writeAll("]");

        // Right pins
        try w.writeAll(",\"rightPins\":[");
        for (h.right_pins.items, 0..) |pin, pi| {
            if (pi > 0) try w.writeAll(",");
            try writeJsonPin(w, pin);
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]");

    // Wires
    try w.writeAll(",\"wires\":[");
    for (scene.wires.items, 0..) |wire, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{");
        try writeJsonString(w, "net", wire.net);
        try w.print(",\"bus\":{s}", .{if (wire.is_bus) "true" else "false"});
        try w.writeAll(",\"points\":[");
        for (wire.points.items, 0..) |pt, pi| {
            if (pi > 0) try w.writeAll(",");
            try w.print("[{d:.1},{d:.1}]", .{ pt[0], pt[1] });
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]");

    // Passives
    try w.writeAll(",\"passives\":[");
    for (scene.passives.items, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{");
        try writeJsonString(w, "ref", p.ref);
        try w.writeAll(",");
        try writeJsonString(w, "component", p.component);
        try w.writeAll(",");
        try writeJsonString(w, "value", p.value);
        try w.writeAll(",");
        try writeJsonString(w, "symbol", p.symbol);
        try w.print(",\"x\":{d:.1},\"y\":{d:.1},\"w\":{d:.1},\"h\":{d:.1}", .{ p.x, p.y, p.w, p.h });
        try w.print(",\"count\":{d},\"src\":{d},\"flip\":{s}", .{ p.count, p.src_offset, if (p.flip) "true" else "false" });
        try writePinNets(w, p.pin_nets);
        try w.writeAll("}");
    }
    try w.writeAll("]");

    // Labels
    try w.writeAll(",\"labels\":[");
    for (scene.labels.items, 0..) |l, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{");
        try writeJsonString(w, "text", l.text);
        try w.print(",\"x\":{d:.1},\"y\":{d:.1}", .{ l.x, l.y });
        try w.writeAll(",");
        try writeJsonString(w, "anchor", l.anchor);
        try w.print(",\"port\":{s},\"ground\":{s}", .{
            if (l.is_port) "true" else "false",
            if (l.is_ground) "true" else "false",
        });
        try w.writeAll("}");
    }
    try w.writeAll("]");

    // Staged (unplaced) instances
    try w.writeAll(",\"staged\":[");
    for (scene.staged.items, 0..) |st, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{");
        try writeJsonString(w, "ref", st.ref);
        try w.writeAll(",");
        try writeJsonString(w, "component", st.component);
        try w.writeAll(",");
        try writeJsonString(w, "value", st.value);
        try w.writeAll(",");
        try writeJsonString(w, "symbol", st.symbol);
        try w.print(",\"src\":{d}", .{st.src_offset});
        try writePinNets(w, st.pin_nets);
        try w.writeAll("}");
    }
    try w.writeAll("]");

    // Authored section names (the editor's sheet navigator pages by these).
    try w.writeAll(",\"authored_sections\":[");
    for (scene.authored_sections, 0..) |nm, i| {
        if (i > 0) try w.writeAll(",");
        try json_writer.writeString(w, nm);
    }
    try w.writeAll("]");

    // Top-level boundary ports (the editor's design-interface list).
    try w.writeAll(",\"ports\":[");
    for (scene.ports, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try json_writer.writeString(w, p.name);
        try w.writeAll(",\"net\":");
        try json_writer.writeString(w, p.net);
        try w.writeAll(",\"dir\":");
        try json_writer.writeString(w, p.direction);
        try w.writeAll("}");
    }
    try w.writeAll("]");

    try w.writeAll("}");
    return buf.toOwnedSlice(allocator);
}

/// Emit `,"pins":[{"pin":"1","net":"VDD2"},…]` — a part's real pin→net bindings.
fn writePinNets(w: anytype, pin_nets: []const PinNet) !void {
    try w.writeAll(",\"pins\":[");
    for (pin_nets, 0..) |pn, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{");
        try writeJsonString(w, "pin", pn.pin);
        try w.writeAll(",");
        try writeJsonString(w, "net", pn.net);
        try w.writeAll("}");
    }
    try w.writeAll("]");
}

const writeJsonString = json_writer.writeField;

fn writeJsonPin(w: anytype, pin: JsonPin) !void {
    try w.writeAll("{");
    try writeJsonString(w, "pins", pin.pin_numbers);
    try w.writeAll(",");
    try writeJsonString(w, "name", pin.display_name);
    try w.print(",\"y\":{d:.1}", .{pin.y});
    if (pin.active_fn.len > 0) {
        try w.writeAll(",");
        try writeJsonString(w, "activeFn", pin.active_fn);
    }
    if (pin.alts.len > 0) {
        try w.writeAll(",\"alts\":[");
        for (pin.alts, 0..) |alt, ai| {
            if (ai > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try writeEscaped(w, alt);
            try w.writeAll("\"");
        }
        try w.writeAll("]");
    }
    try w.writeAll("}");
}

const writeEscaped = json_writer.writeEscaped;

// spec: render_svg - Design name is JSON-escaped in the scene graph output
test "serializeScene escapes a quote/backslash in the design name" {
    const alloc = std.testing.allocator;
    var scene = SceneGraph.init(alloc);
    defer {
        scene.sections.deinit(alloc);
        scene.hubs.deinit(alloc);
        scene.wires.deinit(alloc);
        scene.passives.deinit(alloc);
        scene.labels.deinit(alloc);
        scene.staged.deinit(alloc);
    }
    // A hostile (design-block "…") title with a quote + backslash + a would-be
    // sibling key: without escaping this breaks out of the JSON string.
    scene.design_name = "\"},\"evil\":\"x\\";
    const out = try serializeScene(alloc, &scene);
    defer alloc.free(out);

    // The raw title must NOT appear verbatim — the quote/backslash are escaped.
    try std.testing.expect(std.mem.indexOf(u8, out, "\"name\":\"\\\"},\\\"evil\\\":\\\"x\\\\\"") != null);
    // No injected top-level "evil" key with an unescaped colon leaked out.
    try std.testing.expect(std.mem.indexOf(u8, out, ",\"evil\":\"x") == null);
}
