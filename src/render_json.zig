//! Scene-graph JSON renderer: `renderSceneGraph` turns a `*const DesignBlock`
//! into the `/api/scene-graph/:name` JSON the live-push pipeline consumes. Runs
//! the same flatten → classify → adjacency → net-index `RenderCtx` pipeline as
//! `render_html.zig`, then additionally validates net consistency. Read-only
//! over the block; output is allocated into the caller's allocator. The
//! server-rendered HTML twin is `render_html.zig`.

const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const lib_limits = @import("lib_limits.zig");
const log = @import("infra/log.zig");
const env_mod = @import("eval/env.zig");
const json_writer = @import("json_writer.zig");
const asserted_fns_mod = @import("asserted_fns.zig");
const rails_mod = @import("eval/rails.zig");
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
const schematic_walk = @import("render_svg/schematic_walk.zig");
const membership = @import("diagram/membership.zig");
const rb_types = @import("render_block_types.zig");
const pin_roles = @import("placement/pin_roles.zig");
const numeric = @import("numeric.zig");
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
/// allocation-backed and I/O-backed `std.Io.Writer` implementations —
/// `draw.RenderError` propagates the same union
/// up through `visibleHubHeight` → `renderSceneGraph`.
pub const RenderError = std.mem.Allocator.Error || std.Io.Writer.Error;

// ── Layout constants ──────────────────────────────────────────────
const half_divisor: f64 = 2.0;
const hub_vpad: f64 = 40.0;
const pin_offset = schematic_walk.chain_gap;
const title_line_gap: f64 = 12.0;
const desc_line_gap: f64 = 6.0;
const note_block_pad: f64 = 16.0;
const section_pad_x: f64 = 8.0;
const section_border_w: f64 = 16.0;
const cell_block_gap: f64 = 40.0;
const min_vb_width: f64 = 850.0;
const min_vb_height: f64 = 400.0;
const vb_margin: f64 = 40.0;
const far_x_sentinel: f64 = 99999.0;
const bus_offset_px: f64 = 10.0;
const branch_bus_gap: f64 = 10.0;

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
    /// Canonical (base) net this pin group lands on. The client otherwise derives a
    /// pin's net from the wire drawn to it, so label-rendered pins (power/ground, and
    /// any pin shown as a net stub rather than a wire) carry no net — invisible to the
    /// connection map. Emitting it lets the map see power/ground and each pin's true
    /// net. Grouping is net-based, so one net covers the whole group.
    net: []const u8 = "",
    /// Electrical role of the pin group — "pwr" (supply), "gnd" (ground), or ""
    /// (signal). From the pinout function name (falling back to the net name),
    /// so schematic clients can order supplies top / grounds bottom without
    /// re-deriving the heuristics client-side.
    role: []const u8 = "",
    /// Feature-group label from the enclosing `(pins ref (group "X") …)`
    /// declaration; empty for ungrouped pins. Lets the map keep an authored
    /// pin group contiguous and label the run.
    pgroup: []const u8 = "",
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
    /// Authored sheet this hub files under: its `(section …)` name, with
    /// sub-block hubs folded into the section their sub-block attaches to
    /// (membership.computeSubBlockAttachments). Functional views group
    /// cells into bands by this instead of geometric containment, so a
    /// module's parts land on the author's sheet, not a module-title one.
    sec: []const u8 = "",
    /// Section-grid card index this hub renders in — shared with every passive
    /// the card emits, so clients pair a module's caps with its own IC.
    slot: ?usize = null,
    left_pins: std.ArrayList(JsonPin),
    right_pins: std.ArrayList(JsonPin),
};

/// Cached pinout data: symbol_name -> (pin_id -> []alt_names).
/// Populated lazily in renderSceneGraph; lives for the lifetime of a single render.
const PinoutAltMap = std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const []const u8));

fn loadPinoutAlts(allocator: Allocator, map: *PinoutAltMap, project_dir: []const u8, symbol: []const u8) std.mem.Allocator.Error!void {
    if (project_dir.len == 0 or symbol.len == 0) return;
    if (map.contains(symbol)) return;
    const path = std.fmt.allocPrint(allocator, "{s}/lib/pinouts/{s}.sexp", .{ project_dir, symbol }) catch return;
    const content = infra_fs.cwd().readFileAlloc(allocator, path, lib_limits.max_lib_file_bytes) catch |err| {
        // A component with no pinout file is ordinary (every passive), so
        // `FileNotFound` stays silent. Every other failure means a pinout that
        // EXISTS is being dropped from the scene graph while `render_html.zig`
        // and `erc.zig` — reading the same file at the same class cap — still
        // see it, which is the divergence this cap already caused once. Report
        // it; the degrade itself is unchanged.
        if (err != error.FileNotFound)
            log.warn("scene graph: pinout '{s}' not loaded ({s}) — pin alternates fall back to net names", .{ path, @errorName(err) });
        return;
    };
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
        // `tokenText`, not asAtom/asString: a bare-integer pad (`(pin 1 …)`) is
        // how 243 of the 265 pinout files spell their pads, and dropping those
        // left the schematic's alt display disagreeing with ERC, which keys the
        // same file through `erc.loadPinoutMap`.
        const pin_id = cl[1].tokenText(allocator) orelse continue;

        var alts: std.ArrayList([]const u8) = .empty;
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
/// already read "GP11" where the scene graph read the net "LED2_DRV").
fn loadPinoutNames(allocator: Allocator, path: []const u8) ?std.StringHashMapUnmanaged([]const u8) {
    const content = infra_fs.cwd().readFileAlloc(allocator, path, lib_limits.max_lib_file_bytes) catch |err| {
        // `hubPinNameMap` probes three candidate names per hub, so most calls
        // here legitimately miss — `FileNotFound` must stay quiet or every hub
        // would log twice. A pinout that exists and still fails to load is the
        // silent case worth naming: the hub falls back to labelling pins by net.
        if (err != error.FileNotFound)
            log.warn("scene graph: pinout '{s}' not loaded ({s}) — hub pins fall back to net names", .{ path, @errorName(err) });
        return null;
    };
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
            (std.fmt.allocPrint(allocator, "{d}", .{numeric.checkedInt(i64, n) orelse continue}) catch continue)
        else
            (cl[1].asAtom() orelse cl[1].asString() orelse continue);
        const name = cl[2].asString() orelse (cl[2].asAtom() orelse continue);
        map.put(allocator, id, name) catch continue;
    }
    return map;
}

/// Complete physical pin-name map for one hub. Flat instances do not carry
/// `PartPin` records, so supplement them from the component pinout file.
fn hubPinNameMap(
    ctx: *RenderCtx,
    allocator: Allocator,
    hub: FlatInst,
    part: ?env_mod.Part,
) std.StringHashMapUnmanaged([]const u8) {
    const parts: []const env_mod.Part = if (part) |p| &[_]env_mod.Part{p} else hub.parts;
    var names = hub_mod.buildPinNameMap(ctx, parts);
    if (ctx.project_dir.len == 0) return names;

    for ([_][]const u8{ hub.pinout, hub.symbol, hub.component }) |cand| {
        if (cand.len == 0) continue;
        const path = std.fmt.allocPrint(allocator, "{s}/lib/pinouts/{s}.sexp", .{ ctx.project_dir, cand }) catch continue;
        defer allocator.free(path);
        var pinmap = loadPinoutNames(allocator, path) orelse continue;
        var it = pinmap.iterator();
        while (it.next()) |kv| {
            if (!names.contains(kv.key_ptr.*)) names.put(allocator, kv.key_ptr.*, kv.value_ptr.*) catch break;
        }
        if (pinmap.count() > 0) break;
    }
    return names;
}

/// Union the connected netlist pads with explicitly accepted no-connect pads,
/// then return them in physical pin order. This keeps deliberate gaps visible
/// without rendering every unused pad from a large IC pinout.
const HubPinContext = struct {
    part: ?env_mod.Part,
    explicit_nc_oks: []const env_mod.NcOk,
};

fn collectHubPinIds(
    ctx: *RenderCtx,
    allocator: Allocator,
    hub: FlatInst,
    pin_ctx: HubPinContext,
) ![]const []const u8 {
    var pins: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    if (pin_ctx.part) |p| {
        for (p.pins) |pp| {
            if (seen.contains(pp.pin)) continue;
            try seen.put(allocator, pp.pin, {});
            try pins.append(allocator, pp.pin);
        }
    } else {
        for (ctx.nets.items) |net| {
            for (net.pins) |pin| {
                if (!std.mem.eql(u8, pin.ref_des, hub.ref_des) or seen.contains(pin.pin)) continue;
                try seen.put(allocator, pin.pin, {});
                try pins.append(allocator, pin.pin);
            }
        }
    }

    for (pin_ctx.explicit_nc_oks) |nc_ok| {
        if (nc_ok.reason.len == 0) continue;
        if (seen.contains(nc_ok.pin)) continue;
        try seen.put(allocator, nc_ok.pin, {});
        try pins.append(allocator, nc_ok.pin);
    }

    std.mem.sortUnstable([]const u8, pins.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return draw.pinOrder(a, b);
        }
    }.lt);
    return pins.toOwnedSlice(allocator);
}

const ExplicitNcMap = std.StringHashMapUnmanaged([]const env_mod.NcOk);

fn standardRefDes(ref: []const u8) bool {
    if (ref.len < 2) return false;
    var i: usize = 0;
    while (i < ref.len and i < 2 and std.ascii.isUpper(ref[i])) : (i += 1) {}
    if (i == 0) return false;
    const digit_start = i;
    while (i < ref.len and std.ascii.isDigit(ref[i])) : (i += 1) {}
    return i == ref.len and i > digit_start;
}

/// Index explicit no-connect approvals by the same flattened ref-des scheme as
/// RenderCtx. Kept beside the JSON render pass instead of widening FlatInst,
/// because no-connect annotations are scene policy rather than component data.
fn collectExplicitNcOks(
    allocator: Allocator,
    map: *ExplicitNcMap,
    block: *const DesignBlock,
    prefix: []const u8,
) Allocator.Error!void {
    for (block.instances) |inst| {
        if (inst.nc_oks.len == 0) continue;
        const ref_des = if (prefix.len > 0 and !standardRefDes(inst.ref_des))
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, inst.ref_des })
        else
            inst.ref_des;
        try map.put(allocator, ref_des, inst.nc_oks);
    }
    for (block.sub_blocks) |sub_block| {
        const nested_prefix = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, sub_block.name })
        else
            sub_block.name;
        try collectExplicitNcOks(allocator, map, sub_block.block, nested_prefix);
    }
}

const JsonWire = struct {
    net: []const u8,
    points: std.ArrayList([2]f64),
    is_bus: bool,
};

/// A part's actual pin → net binding, read straight from the netlist. Schematic
/// clients read nets from this (authoritative) instead of inferring them from
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
    /// Section-grid card the emitting hub renders in (see JsonHub.slot).
    slot: ?usize = null,
    count: u32 = 1,
    src_offset: u32 = 0,
    /// `(decouples "IC" PAD)` binding (module-local ref + resolved pad), copied off
    /// the instance. Lets a graph view that has no spoke geometry dock a bypass cap on
    /// the one pad it serves — instead of every pin on its (shared) rail — exactly like
    /// the schematic's `boundHubPin`. Both empty for an unbound passive.
    decouple_ic: []const u8 = "",
    decouple_pin: []const u8 = "",
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
/// just-added cap with no hub-reaching net). Reported so clients can stage it
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

/// One resolved power-rail entry for the scene JSON: the sub-block-declared
/// source (from `eval/rails`) resolved down to the concrete IC instance inside
/// that sub-block, so the connection map can anchor the rail's
/// producer ghost and order the power tree without re-deriving module
/// structure client-side.
const ScenePowerRail = struct {
    /// Canonical (source-side) top-level net name, e.g. "V_6VA".
    net: []const u8,
    /// Sub-block handle that sources the rail, e.g. "buck_6v".
    source: []const u8,
    /// The source sub-block's output port name, e.g. "VOUT".
    source_port: []const u8,
    /// Ref-des of the producing IC inside that sub-block (parent-renumbered,
    /// so it matches the scene's hub refs). Empty when no IC could be resolved.
    source_hub: []const u8,
    nominal: ?f64,
    /// Ferrite-bridged downstream names that belong to this rail.
    aliases: []const []const u8,
};

/// First U-prefixed ref among the pins of `net_name` inside `sb` — the IC leg
/// of a sub-block's output net, when the IC touches it directly.
fn icOnSubBlockNet(sb: env_mod.SubBlock, net_name: []const u8) []const u8 {
    for (sb.block.nets) |n| {
        if (!std.mem.eql(u8, n.name, net_name)) continue;
        for (n.pins) |p| {
            if (p.ref_des.len > 0 and (p.ref_des[0] == 'U' or p.ref_des[0] == 'u')) return p.ref_des;
        }
    }
    return "";
}

/// First U-prefixed instance in the sub-block — the fallback producer when the
/// output net never touches the IC (a boost's L→D→cap output, say).
fn firstIcInSubBlock(sb: env_mod.SubBlock) []const u8 {
    for (sb.block.instances) |inst| {
        if (inst.ref_des.len > 0 and (inst.ref_des[0] == 'U' or inst.ref_des[0] == 'u')) return inst.ref_des;
    }
    return "";
}

/// Resolve each `eval/rails` PowerRail to its producing IC ref for the scene.
fn buildPowerRails(allocator: Allocator, block: *const DesignBlock) Allocator.Error![]const ScenePowerRail {
    const power_rails = try rails_mod.build(allocator, block);
    var out: std.ArrayList(ScenePowerRail) = .empty;
    for (power_rails) |r| {
        var hub: []const u8 = "";
        for (block.sub_blocks) |sb| {
            if (!std.mem.eql(u8, sb.name, r.source_ref_des)) continue;
            var port_net: []const u8 = "";
            for (sb.block.ports) |p| {
                if (std.mem.eql(u8, p.name, r.source_port)) port_net = p.net;
            }
            if (port_net.len > 0) hub = icOnSubBlockNet(sb, port_net);
            if (hub.len == 0) hub = firstIcInSubBlock(sb);
            break;
        }
        try out.append(allocator, .{
            .net = r.name,
            .source = r.source_ref_des,
            .source_port = r.source_port,
            .source_hub = hub,
            .nominal = r.nominal,
            .aliases = r.aliases,
        });
    }
    return out.toOwnedSlice(allocator);
}

/// One authored sheet (section, sub-section, or unattached sub-block) with the
/// coarse `render_block_types.Category` its name/instances classify to and the
/// authored one-line subtitle (the `(section "name" "subtitle" …)` spec text —
/// the glance layer's block caption). Empty for sub-blocks.
const SheetMeta = struct {
    name: []const u8,
    cat: []const u8,
    sub: []const u8 = "",
};

const SceneGraph = struct {
    allocator: Allocator,
    vb_w: f64 = 0,
    vb_h: f64 = 0,
    design_name: []const u8 = "",
    sections: std.ArrayList(JsonSection),
    hubs: std.ArrayList(JsonHub),
    wires: std.ArrayList(JsonWire),
    passives: std.ArrayList(JsonPassive),
    labels: std.ArrayList(JsonLabel),
    staged: std.ArrayList(JsonStaged),
    /// Names of the design's authored `(section …)` / sub-block structure, so the
    /// scene clients page by authored section — and collapses to a
    /// single whole-design sheet when there are none — instead of auto per-IC.
    authored_sections: []const []const u8 = &.{},
    /// The design's top-level boundary `(port …)` forms, so schematic clients
    /// can list / add / remove them (the design-level interface view).
    ports: []const env_mod.Port = &.{},
    /// Authored sheets with their block-diagram category (same classifier as
    /// the system overview), in authored order. The renderer orders its bands
    /// canonically (power → mcu → memory → …) and colors glance chips from
    /// this without duplicating the keyword tables client-side.
    sheet_meta: []const SheetMeta = &.{},
    /// Hand-authored `(function …)` super-blocks — the functional schematic's
    /// outermost grouping. Borrowed from the DesignBlock.
    functions: []const env_mod.FunctionSpec = &.{},
    /// Sub-block-sourced power rails with their producer IC resolved — the
    /// functional schematic draws the power tree from these.
    power_rails: []const ScenePowerRail = &.{},

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
        var pts: std.ArrayList([2]f64) = .empty;
        if (y1 == y2) {
            try pts.append(self.allocator, .{ x1, y1 });
            try pts.append(self.allocator, .{ x2, y2 });
        } else {
            const mid_x = (x1 + x2) / half_divisor;
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
            .decouple_ic = inst.decouple_ic,
            .decouple_pin = inst.decouple_pin,
        });
    }
};

// ── Visible-content height calculation ──────────────────────────────

fn visibleConnectionSlots(ctx: *RenderCtx, conn: AdjEntry, hub_ref: []const u8, pin_net_name: []const u8) u32 {
    return switch (conn.endpoint) {
        .net => |net| blk: {
            const term = baseNetName(net);
            if (!ctx.significant_nets.contains(term)) break :blk 0;
            const own = std.mem.eql(u8, term, baseNetName(pin_net_name));
            if (own and !connection.shouldShowOwnNet(ctx, term, hub_ref)) break :blk 0;
            break :blk 1;
        },
        .pin => |pin| if (ctx.spoke_set.contains(pin.ref_des))
            hub_mod.estimateBranchCount(ctx, pin.ref_des, hub_ref)
        else
            1,
    };
}

/// Compute group heights from the connections the scene graph actually draws.
/// Identical passives deliberately remain distinct slots.
fn visibleGroupHeights(ctx: *RenderCtx, allocator: Allocator, groups: []const PinGroup, hub_ref: []const u8) ![]f64 {
    var heights = try allocator.alloc(f64, groups.len);
    for (groups, 0..) |group, i| {
        var total_slots: u32 = 0;

        var first_pin_id: []const u8 = "";
        for (group.conns) |conn| {
            first_pin_id = conn.pin;
            break;
        }
        const canon_key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ hub_ref, first_pin_id });
        const pin_net_name = ctx.pin_canonical_nets.get(canon_key) orelse "";

        for (group.conns) |conn| total_slots += visibleConnectionSlots(ctx, conn, hub_ref, pin_net_name);

        const base: f64 = 40.0;
        heights[i] = base + @as(f64, @floatFromInt(@max(total_slots, 1) -| 1)) * per_conn_spacing;
    }
    return heights;
}

// spec: render_svg - Hub pin spacing reserves rows only for connections the scene graph actually draws
test "visible group height ignores a suppressed own-net label" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var ctx = RenderCtx.init(allocator);
    try ctx.significant_nets.put(allocator, "LOCAL", {});
    try ctx.significant_nets.put(allocator, "VISIBLE", {});
    try ctx.pin_canonical_nets.put(allocator, "U1.1", "LOCAL");

    const groups = [_]PinGroup{.{
        .display_name = "IO",
        .pin_numbers = "1",
        .conns = &.{
            .{ .pin = "1", .endpoint = .{ .net = "LOCAL" } },
            .{ .pin = "1", .endpoint = .{ .net = "VISIBLE" } },
        },
    }};
    const heights = try visibleGroupHeights(&ctx, allocator, &groups, "U1");

    // LOCAL is the pin's implicit own net and does not render. VISIBLE alone
    // occupies one row, so the group keeps the 40 px base height instead of
    // reserving an empty second row.
    try std.testing.expectEqual(@as(f64, 40.0), heights[0]);
}

/// Mirror of `hub_mod.SplitGroups` for the scene-graph path.
const MergeAwareSplit = ctx_mod.MergeAwareSplit;

/// Split ordered hub pin groups into sequential left/right ranges using their
/// visible-content heights.
/// Content key for the visible-height split memo: `hub_ref` plus each group's pin
/// ids. `groupHubPins` is deterministic in (ctx, pins), so identical pin ids ⇒
/// identical groups ⇒ identical split — a cache hit is only ever returned for
/// byte-identical inputs. Owned by `allocator` (arena; lives for the render).
fn splitCacheKey(allocator: Allocator, all_groups: []const PinGroup, hub_ref: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(allocator, hub_ref);
    for (all_groups) |g| {
        try buf.append(allocator, '|');
        try buf.appendSlice(allocator, g.pin_numbers);
    }
    return buf.items;
}

fn splitGroupsByVisibleHeight(
    ctx: *RenderCtx,
    allocator: Allocator,
    all_groups: []const PinGroup,
    hub_ref: []const u8,
) !MergeAwareSplit {
    // Memoize: the three per-hub render passes recompute an identical split
    // (visibleGroupHeights walks branch counts per connection — the
    // expensive part). Key on exact content so the cache is result-identical.
    const cache_key = try splitCacheKey(allocator, all_groups, hub_ref);
    if (ctx.render_scratch.hub_splits.get(cache_key)) |cached| return cached;

    const all_heights = try visibleGroupHeights(ctx, allocator, all_groups, hub_ref);
    defer allocator.free(all_heights);

    var total: f64 = 0;
    for (all_heights) |h| total += h;
    var split_idx: usize = all_groups.len;
    if (all_groups.len > 1) {
        var prefix: f64 = 0;
        var best_delta = std.math.inf(f64);
        for (all_heights[0 .. all_heights.len - 1], 0..) |h, i| {
            prefix += h;
            const delta = @abs(total - 2.0 * prefix);
            if (delta < best_delta) {
                best_delta = delta;
                split_idx = i + 1;
            }
        }
    }

    const result = MergeAwareSplit{
        .left = try allocator.dupe(PinGroup, all_groups[0..split_idx]),
        .right = try allocator.dupe(PinGroup, all_groups[split_idx..]),
        .left_heights = try allocator.dupe(f64, all_heights[0..split_idx]),
        .right_heights = try allocator.dupe(f64, all_heights[split_idx..]),
    };
    try ctx.render_scratch.hub_splits.put(allocator, cache_key, result);
    return result;
}

/// Compute hub height using visible scene-graph content.
fn visibleHubHeight(
    ctx: *RenderCtx,
    allocator: Allocator,
    hub: FlatInst,
    pin_ctx: HubPinContext,
) !f64 {
    const adj_entries = if (ctx.adjacency.get(hub.ref_des)) |list| list.items else &[_]AdjEntry{};
    var pn_map = hubPinNameMap(ctx, allocator, hub, pin_ctx.part);
    defer pn_map.deinit(allocator);
    const all_pins = try collectHubPinIds(ctx, allocator, hub, pin_ctx);

    const all_groups = try hub_mod.groupHubPins(ctx, all_pins, adj_entries, &pn_map);
    const split = try splitGroupsByVisibleHeight(ctx, allocator, all_groups, hub.ref_des);
    const left_heights = split.left_heights;
    const right_heights = split.right_heights;

    var left_total: f64 = 0;
    for (left_heights) |h| left_total += h;
    var right_total: f64 = 0;
    for (right_heights) |h| right_total += h;

    return @max(left_total, right_total) + hub_vpad;
}

// ── Public entry point ───────────────────────────────────────────────

/// Render a design's hub/spoke schematic as a JSON scene graph for the
/// Pixi.js canvas viewer. Flattens sub-blocks, classifies each instance as
/// hub or spoke (passive), groups pins, lays out sections in a grid, and
/// emits hub boxes plus the wires/labels needed to render the schematic.
/// Collect the names of the design's authored structural sections — `(section …)`
/// forms (and their sub-sections) plus `(sub-block …)`s. These are what the
/// schematic views use to group the design; when the list is empty the design
/// has no explicit sections and renders as a single whole-design sheet.
fn collectAuthoredSections(allocator: Allocator, block: *const DesignBlock, sub_attachments: []const ?usize) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (block.sections) |sec| {
        try list.append(allocator, sec.name);
        for (sec.sub_sections) |sub| try list.append(allocator, sub.name);
    }
    // A sub-block that attaches to an authored section files its cells under
    // that section, so listing its module title too would page an empty
    // duplicate sheet. Only unattached sub-blocks stay their own sheet.
    for (block.sub_blocks, 0..) |sb, sb_idx| {
        if (sub_attachments[sb_idx] != null) continue;
        try list.append(allocator, sb.block.name);
    }
    return list.items;
}

/// Build the scene's `sheet_meta`: one entry per authored sheet (same set and
/// order as `collectAuthoredSections`), each classified with the system-
/// overview category heuristics so clients can order bands canonically.
fn buildSheetMeta(allocator: Allocator, block: *const DesignBlock, sub_attachments: []const ?usize) ![]const SheetMeta {
    var list: std.ArrayList(SheetMeta) = .empty;
    for (block.sections) |sec| {
        try list.append(allocator, .{ .name = sec.name, .cat = @tagName(rb_types.classifySection(sec)), .sub = sec.description });
        for (sec.sub_sections) |sub| {
            try list.append(allocator, .{ .name = sub.name, .cat = @tagName(rb_types.classifySection(sub)), .sub = sub.description });
        }
    }
    for (block.sub_blocks, 0..) |sb, sb_idx| {
        if (sub_attachments[sb_idx] != null) continue;
        try list.append(allocator, .{ .name = sb.block.name, .cat = @tagName(rb_types.classifyByName(sb.block.name, sb.block.instances)) });
    }
    return list.items;
}

/// A hub (or one `(part …)` of a multi-part hub) assigned to a section slot.
const GridCell = struct {
    hub_inst: FlatInst,
    part: ?env_mod.Part,
    section_idx: usize,
};

/// One grid slot per authored section / sub-section / sub-block card. `sheet`
/// is the authored page the slot's cells file under — it differs from `name`
/// only for a sub-block attached to a section (the card keeps the module
/// title; the sheet is the adopting section).
const SectionInfo = struct {
    name: []const u8,
    description: []const u8,
    notes: []const env_mod.SectionNote,
    sheet: []const u8,
    cell_indices: std.ArrayList(usize),
};

const SectionGridState = struct {
    grid: std.ArrayList(SectionInfo),
    ref_to_section: std.StringHashMapUnmanaged(usize),
};

/// Build the section grid (one slot per authored section, sub-section, and
/// sub-block card) plus the instance-ref → slot map. An attached sub-block
/// keeps its own card but files under the adopting section's sheet, so the
/// rendered bands match the authored structure.
fn buildSectionGrid(allocator: Allocator, block: *const DesignBlock, sub_attachments: []const ?usize) !SectionGridState {
    var st = SectionGridState{ .grid = .empty, .ref_to_section = std.StringHashMapUnmanaged(usize).empty };
    for (block.sections) |sec| {
        const sec_idx = st.grid.items.len;
        try st.grid.append(allocator, .{
            .name = sec.name,
            .description = sec.description,
            .notes = sec.notes,
            .sheet = sec.name,
            .cell_indices = .empty,
        });
        for (sec.instances) |inst| try st.ref_to_section.put(allocator, inst.ref_des, sec_idx);
        for (sec.sub_sections) |sub| {
            const sub_idx = st.grid.items.len;
            try st.grid.append(allocator, .{
                .name = sub.name,
                .description = sub.description,
                .notes = sub.notes,
                .sheet = sub.name,
                .cell_indices = .empty,
            });
            for (sub.instances) |inst| try st.ref_to_section.put(allocator, inst.ref_des, sub_idx);
        }
    }
    for (block.sub_blocks, 0..) |sb, sb_idx| {
        const sec_idx = st.grid.items.len;
        const sheet: []const u8 = if (sub_attachments[sb_idx]) |att| block.sections[att].name else sb.block.name;
        try st.grid.append(allocator, .{
            .name = sb.block.name,
            .description = "",
            .notes = &.{},
            .sheet = sheet,
            .cell_indices = .empty,
        });
        for (sb.block.instances) |inst| try st.ref_to_section.put(allocator, inst.ref_des, sec_idx);
    }
    return st;
}

/// Assign every hub (or hub part) to a section slot: declared membership
/// first, then a component-name match, else a synthetic slot minted from the
/// component name (also its sheet).
fn collectGridCells(
    allocator: Allocator,
    ctx: *RenderCtx,
    section_grid: *std.ArrayList(SectionInfo),
    ref_to_section: *const std.StringHashMapUnmanaged(usize),
) !std.ArrayList(GridCell) {
    var cells: std.ArrayList(GridCell) = .empty;
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
                try section_grid.append(allocator, .{
                    .name = hub_inst.component,
                    .description = "",
                    .notes = &.{},
                    .sheet = hub_inst.component,
                    .cell_indices = .empty,
                });
                break :blk si;
            };
            const ci = cells.items.len;
            try cells.append(allocator, .{ .hub_inst = hub_inst, .part = null, .section_idx = sec_idx });
            try section_grid.items[sec_idx].cell_indices.append(allocator, ci);
        }
    }
    return cells;
}

/// Build the live-push scene-graph JSON for `block`: flatten + classify,
/// lay hubs out into section cells, collect spokes/wires/labels, and serialize.
pub fn renderSceneGraph(allocator: Allocator, block: *const DesignBlock, project_dir: []const u8) RenderError![]const u8 {
    var ctx = RenderCtx.init(allocator);
    ctx.project_dir = project_dir;

    // Shared flatten → classify → adjacency → net-index pipeline (the same one
    // render_html.setupRenderCtx runs); the JSON path additionally validates
    // net consistency afterward.
    try ctx.setup(block);
    try ctx.validateNetConsistency();

    var explicit_nc_map: ExplicitNcMap = .empty;
    defer explicit_nc_map.deinit(allocator);
    try collectExplicitNcOks(allocator, &explicit_nc_map, block, "");

    var scene = SceneGraph.init(allocator);
    scene.design_name = block.name;
    const sub_attachments = try membership.computeSubBlockAttachments(allocator, block);
    defer allocator.free(sub_attachments);
    scene.authored_sections = try collectAuthoredSections(allocator, block, sub_attachments);
    scene.sheet_meta = try buildSheetMeta(allocator, block, sub_attachments);
    scene.functions = block.functions;
    scene.ports = block.ports;
    scene.power_rails = try buildPowerRails(allocator, block);

    var alt_map: PinoutAltMap = .empty;
    var asserted_fns = try asserted_fns_mod.buildMap(allocator, block);

    var grid_state = try buildSectionGrid(allocator, block, sub_attachments);
    var section_grid = grid_state.grid;
    const cells = try collectGridCells(allocator, &ctx, &section_grid, &grid_state.ref_to_section);

    // Auto grid dimensions
    const n_sections = section_grid.items.len;
    const n_cols: usize = if (n_sections == 0) 1 else blk: {
        var c: usize = 1;
        while (c * c < n_sections) : (c += 1) {}
        break :blk c;
    };
    const n_rows: usize = if (n_sections == 0) 1 else (n_sections + n_cols - 1) / n_cols;

    // Grid layout constants for the scene-graph section grid. These are
    // render_json's own — the SVG renderer lives in src/render_svg/ and sizes
    // its sections from its own measurements, so there is nothing here to keep
    // in step with it.
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
        var h: f64 = title_font_size + title_line_gap;
        if (sg.description.len > 0) h += desc_font_size + desc_line_gap;
        section_header_heights[si] = h;
    }

    // Compute per-section footer height
    var section_footer_heights = try allocator.alloc(f64, section_grid.items.len);
    defer allocator.free(section_footer_heights);
    for (section_grid.items, 0..) |sg, si| {
        if (sg.notes.len > 0) {
            section_footer_heights[si] = @as(f64, @floatFromInt(sg.notes.len)) * note_line_height + note_block_pad;
        } else {
            section_footer_heights[si] = 0;
        }
    }

    // Pass 1: Measure cell heights from every visible connection.
    var cell_heights = try allocator.alloc(f64, cells.items.len);
    defer allocator.free(cell_heights);

    for (cells.items, 0..) |cell, ci| {
        const nc_oks = explicit_nc_map.get(cell.hub_inst.ref_des) orelse &.{};
        const pin_ctx = HubPinContext{ .part = cell.part, .explicit_nc_oks = nc_oks };
        cell_heights[ci] = try visibleHubHeight(&ctx, allocator, cell.hub_inst, pin_ctx);
    }

    // Compute row heights
    var row_heights = try allocator.alloc(f64, n_rows);
    defer allocator.free(row_heights);
    for (row_heights) |*rh| rh.* = 0;

    for (section_grid.items, 0..) |sg, si| {
        const grid_row = si / n_cols;
        var sec_height: f64 = 0;
        for (sg.cell_indices.items) |ci| {
            sec_height += cell_heights[ci] + cell_block_gap;
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
            .x = x_offset + section_pad_x,
            .y = cell_y,
            .w = cell_width - section_border_w,
            .h = section_h,
        });

        var content_y = cell_y + header_h + section_pad;
        for (sg.cell_indices.items) |ci| {
            const cell = cells.items[ci];
            const h = cell_heights[ci];
            const nc_oks = explicit_nc_map.get(cell.hub_inst.ref_des) orelse &.{};
            const pin_ctx = HubPinContext{ .part = cell.part, .explicit_nc_oks = nc_oks };

            // Collect hub data
            var json_hub = try collectHubData(&ctx, allocator, cell.hub_inst, pin_ctx, x_offset, content_y, &alt_map, &asserted_fns);
            json_hub.sec = sg.sheet;
            json_hub.slot = cell.section_idx;
            try scene.hubs.append(allocator, json_hub);

            // Collect connections for this hub (writes wires/passives straight
            // into `scene`; it doesn't mutate the JsonHub row appended above).
            // Everything the card emits gets the card's slot id, so clients
            // can pair a module's decoupling caps with the module's own IC.
            const passives_before = scene.passives.items.len;
            try collectHubConnections(&ctx, &scene, allocator, cell.hub_inst, pin_ctx, x_offset, content_y);
            for (scene.passives.items[passives_before..]) |*jp| jp.slot = cell.section_idx;

            content_y += h + cell_block_gap;
        }
    }

    // Port blocks (skipped — interface ports not shown in schematic)

    // Real pin → net bindings per instance, straight from the netlist. The
    // clients read these (authoritative) instead of inferring a pin's net from
    // drawn wires, so a pin on a fresh single-pin net (no wire yet) still shows
    // its name. Keyed by full ref_des (nets reference instances by full ref).
    var pinnet_map: std.StringHashMapUnmanaged(std.ArrayList(PinNet)) = .empty;
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
    // Reported so clients can stage these for the user to wire by drag.
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
    scene.vb_w = @max(total_width, min_vb_width);
    scene.vb_h = @max(y + vb_margin, min_vb_height);

    // Serialize to JSON
    return serializeScene(allocator, &scene);
}

const BranchResult = struct { end_x: f64, cy: f64, terminal: []const u8 };
const Classified = struct { conn: AdjEntry, terminal: []const u8 };

fn markChainPassivesRendered(
    ctx: *RenderCtx,
    allocator: Allocator,
    result: connection.ChainResult,
) !void {
    for (result.chain) |inst| try ctx.rendered_spokes.put(allocator, inst.ref_des, {});
    for (result.branches) |branch| {
        for (branch.chain) |inst| try ctx.rendered_spokes.put(allocator, inst.ref_des, {});
    }
}

// ── Hub data collection ──────────────────────────────────────────────

/// The canonical (base) net a hub pin group lands on, via `ctx.pin_canonical_nets`
/// (the same map `collectGroupConnections` uses). Grouping is net-based, so the
/// first pad's net covers the whole group; "" when unknown. Arena-allocated key,
/// freed with the render pass — matches the no-free convention next door.
fn hubPinGroupNet(ctx: *RenderCtx, allocator: Allocator, ref: []const u8, group: anytype) []const u8 {
    if (group.conns.len == 0) return "";
    const key = std.fmt.allocPrint(allocator, "{s}.{s}", .{ ref, group.conns[0].pin }) catch return "";
    return ctx.pin_canonical_nets.get(key) orelse "";
}

fn collectHubData(
    ctx: *RenderCtx,
    allocator: Allocator,
    hub: FlatInst,
    pin_ctx: HubPinContext,
    x_offset: f64,
    y_start: f64,
    alt_map: *PinoutAltMap,
    asserted_fns: *const std.StringHashMapUnmanaged([]const u8),
) !JsonHub {
    try loadPinoutAlts(allocator, alt_map, ctx.project_dir, hub.symbol);
    // Get pin groups (reuse hub.zig logic)
    const adj_entries = if (ctx.adjacency.get(hub.ref_des)) |list| list.items else &[_]AdjEntry{};
    var pn_map = hubPinNameMap(ctx, allocator, hub, pin_ctx.part);
    defer pn_map.deinit(allocator);
    const all_pins = try collectHubPinIds(ctx, allocator, hub, pin_ctx);

    const all_groups = try hub_mod.groupHubPins(ctx, all_pins, adj_entries, &pn_map);
    const split = try splitGroupsByVisibleHeight(ctx, allocator, all_groups, hub.ref_des);
    const left_groups = split.left;
    const right_groups = split.right;
    const left_heights = split.left_heights;
    const right_heights = split.right_heights;

    var left_total: f64 = 0;
    for (left_heights) |h| left_total += h;
    var right_total: f64 = 0;
    for (right_heights) |h| right_total += h;
    const hub_height = @max(left_total, right_total) + hub_vpad;

    const label = try std.fmt.allocPrint(allocator, "{s} {s}", .{ shortRef(hub.ref_des), displayValue(hub) });

    const icon = draw.classifyComponent(hub);

    var json_hub = JsonHub{
        .ref = hub.ref_des,
        .component = hub.component,
        .value = hub.value,
        .symbol = hub.symbol,
        .part = if (pin_ctx.part) |p| p.name else null,
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
    var py_left = y_start + hub_vpad;
    for (left_groups, 0..) |group, gi| {
        const height = left_heights[gi];
        const pin_cy = py_left + height / half_divisor;
        const enrich = pinEnrichment(allocator, group, hub.ref_des, hub.symbol, alt_map, asserted_fns);
        const gnet = hubPinGroupNet(ctx, allocator, hub.ref_des, group);
        try json_hub.left_pins.append(allocator, .{
            .pin_numbers = group.pin_numbers,
            .display_name = group.display_name,
            .y = pin_cy,
            .side = "left",
            .alts = enrich.alts,
            .active_fn = enrich.active_fn,
            .net = gnet,
            .role = pinGroupRole(group, gnet),
            .pgroup = group.group,
        });
        py_left += height;
    }

    // Collect right pin positions
    var py_right = y_start + hub_vpad;
    for (right_groups, 0..) |group, gi| {
        const height = right_heights[gi];
        const pin_cy = py_right + height / half_divisor;
        const enrich = pinEnrichment(allocator, group, hub.ref_des, hub.symbol, alt_map, asserted_fns);
        const gnet = hubPinGroupNet(ctx, allocator, hub.ref_des, group);
        try json_hub.right_pins.append(allocator, .{
            .pin_numbers = group.pin_numbers,
            .display_name = group.display_name,
            .y = pin_cy,
            .side = "right",
            .alts = enrich.alts,
            .active_fn = enrich.active_fn,
            .net = gnet,
            .role = pinGroupRole(group, gnet),
            .pgroup = group.group,
        });
        py_right += height;
    }

    return json_hub;
}

/// Strip the "_(N)" group-count suffix a multi-pin scene row carries
/// ("VSS_(9)" → "VSS") so the role heuristics see the bare function name.
fn stripFoldCount(name: []const u8) []const u8 {
    if (name.len < 4 or name[name.len - 1] != ')') return name;
    const open = std.mem.lastIndexOf(u8, name, "_(") orelse return name;
    for (name[open + 2 .. name.len - 1]) |c| {
        if (c < '0' or c > '9') return name;
    }
    return name[0..open];
}

/// Classify a pin group's electrical role for the scene: "gnd", "pwr", or ""
/// (signal). Function name first (the display name is the pinout function when
/// one exists), net name as fallback so unlabeled power pins still classify.
fn pinGroupRole(group: PinGroup, net: []const u8) []const u8 {
    const name = stripFoldCount(group.display_name);
    if (pin_roles.isGroundFn(name) or isGroundNet(net)) return "gnd";
    if (pin_roles.isSupplyFn(name)) return "pwr";
    if (net.len > 0 and pin_roles.isSupplyFn(net)) return "pwr";
    return "";
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
    pin_ctx: HubPinContext,
    x_offset: f64,
    y_start: f64,
) !void {
    const adj_entries = if (ctx.adjacency.get(hub.ref_des)) |list| list.items else &[_]AdjEntry{};
    var pn_map = hubPinNameMap(ctx, allocator, hub, pin_ctx.part);
    defer pn_map.deinit(allocator);
    const all_pins = try collectHubPinIds(ctx, allocator, hub, pin_ctx);

    const all_groups = try hub_mod.groupHubPins(ctx, all_pins, adj_entries, &pn_map);
    // Must mirror collectHubData's split exactly. That pass balances groups
    // left/right by visible-content *height* and places each pin by accumulating
    // those heights; if this pass splits differently (it used to balance by pin
    // *count*), a pin's connection wire is emitted on a different side / y than
    // the pin is drawn at — so nets visibly miss the IC pads. Share the one
    // split so every wire meets its pin.
    const split = try splitGroupsByVisibleHeight(ctx, allocator, all_groups, hub.ref_des);
    const left_groups = split.left;
    const right_groups = split.right;
    const left_heights = split.left_heights;
    const right_heights = split.right_heights;

    // Collect left connections
    var py_left = y_start + hub_vpad;
    for (left_groups, 0..) |group, gi| {
        const height = left_heights[gi];
        const pin_cy = py_left + height / half_divisor;
        const stub_x = x_offset + hub_x - pin_stub;
        try collectGroupConnections(ctx, scene, allocator, hub.ref_des, group, stub_x, pin_cy, .left);
        py_left += height;
    }

    // Collect right connections
    var py_right = y_start + hub_vpad;
    for (right_groups, 0..) |group, gi| {
        const height = right_heights[gi];
        const pin_cy = py_right + height / half_divisor;
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

    var classified: std.ArrayList(Classified) = .empty;

    for (group.conns) |conn| {
        switch (conn.endpoint) {
            .net => |net| {
                const term = baseNetName(net);
                if (!ctx.significant_nets.contains(term)) continue;
                const own = std.mem.eql(u8, term, baseNetName(pin_net_name));
                if (own and !connection.shouldShowOwnNet(ctx, term, hub_ref)) continue;
                try classified.append(allocator, .{ .conn = conn, .terminal = term });
            },
            .pin => |p| {
                if (ctx.rendered_spokes.contains(p.ref_des)) continue;
                const term = try connection.getConnTerminal(ctx, conn.endpoint, hub_ref, conn.pin);
                try classified.append(allocator, .{ .conn = conn, .terminal = term });
            },
        }
    }

    try connection.deduplicateGroupedSpokes(ctx, Classified, &classified, hub_ref);

    if (classified.items.len == 0) return;

    std.mem.sortUnstable(Classified, classified.items, {}, struct {
        fn lt(_: void, a: Classified, b: Classified) bool {
            return std.mem.lessThan(u8, a.terminal, b.terminal);
        }
    }.lt);

    var slot_counts = try allocator.alloc(u32, classified.items.len);
    var total_slots: u32 = 0;
    for (classified.items, 0..) |entry, i| {
        const slots: u32 = switch (entry.conn.endpoint) {
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

    const multi = classified.items.len > 1;
    const bus_offset: f64 = bus_offset_px;
    const bus_x: f64 = switch (side) {
        .left => stub_x - bus_offset,
        .right => stub_x + bus_offset,
    };

    var consumed_slots: u32 = 0;
    var min_cy: f64 = py;
    var max_cy: f64 = py;
    const total_h2 = @as(f64, @floatFromInt(@max(total_slots, 1) -| 1)) * per_conn_spacing;

    var results: std.ArrayList(BranchResult) = .empty;

    for (classified.items, 0..) |entry, i| {
        const slots = slot_counts[i];
        const slot_center = @as(f64, @floatFromInt(consumed_slots)) + @as(f64, @floatFromInt(slots -| 1)) / half_divisor;
        const cy = py + slot_center * per_conn_spacing - total_h2 / half_divisor;
        consumed_slots += slots;
        if (cy < min_cy) min_cy = cy;
        if (cy > max_cy) max_cy = cy;

        const internal_net: []const u8 = switch (entry.conn.endpoint) {
            .net => entry.terminal,
            .pin => pin_net_name,
        };

        const conn_stub_x = if (multi) bus_x else stub_x;
        const conn_stub_y = if (multi) cy else py;

        const end_x = try collectConnBody(
            ctx,
            scene,
            allocator,
            entry.conn.endpoint,
            hub_ref,
            entry.conn.pin,
            conn_stub_x,
            conn_stub_y,
            cy,
            side,
            internal_net,
        );
        try results.append(allocator, .{ .end_x = end_x, .cy = cy, .terminal = entry.terminal });
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
        .left => stub_x - spoke_len - pin_offset,
        .right => stub_x + spoke_len + pin_offset,
    };
    for (results.items) |r| {
        switch (side) {
            .left => default_term_x = @min(default_term_x, r.end_x - pin_offset),
            .right => default_term_x = @max(default_term_x, r.end_x + pin_offset),
        }
    }
    const term_x = default_term_x;

    try collectTerminals(ctx, scene, allocator, results.items, term_x, side);
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
                .left => stub_x - pin_offset,
                .right => stub_x + pin_offset,
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

                try markChainPassivesRendered(ctx, allocator, chain_result);

                var all_spokes: std.ArrayList(FlatInst) = .empty;
                try all_spokes.append(allocator, inst);
                for (chain_result.chain) |c| try all_spokes.append(allocator, c);

                switch (side) {
                    .left => {
                        try scene.addWire(net_name, stub_x, stub_y, stub_x - pin_offset, cy, false);
                        const chain_end_x = try collectPassiveChainLeft(scene, allocator, stub_x - pin_offset, cy, all_spokes.items);
                        if (chain_result.branches.len > 0) {
                            try collectBranchTreeLeft(ctx, scene, allocator, chain_end_x, cy, chain_result.branches, chain_result.terminal);
                        }
                        return chain_end_x;
                    },
                    .right => {
                        try scene.addWire(net_name, stub_x, stub_y, stub_x + pin_offset, cy, false);
                        const chain_end_x = try collectPassiveChainRight(scene, allocator, stub_x + pin_offset, cy, all_spokes.items);
                        if (chain_result.branches.len > 0) {
                            try collectBranchTreeRight(ctx, scene, allocator, chain_end_x, cy, chain_result.branches, chain_result.terminal);
                        }
                        return chain_end_x;
                    },
                }
            } else {
                const end_x: f64 = switch (side) {
                    .left => stub_x - spoke_len - pin_offset,
                    .right => stub_x + spoke_len + pin_offset,
                };
                try scene.addWire(net_name, stub_x, stub_y, end_x, cy, false);
                return end_x;
            }
        },
    }
}

/// The scene-graph backend of `schematic_walk.passiveChain`. A gap between two
/// bodies is an unnamed wire; a body is a scene passive recorded at its LEFT
/// edge, which is the chain cursor on a right-hand chain and one body width
/// back from it on a left-hand one.
const SceneChain = struct {
    scene: *SceneGraph,

    /// The pin gap between two bodies. Unnamed: a chain's internal segments
    /// belong to no net the viewer can select.
    pub fn wire(self: SceneChain, x1: f64, y1: f64, x2: f64, y2: f64) RenderError!void {
        try self.scene.addWire("", x1, y1, x2, y2, false);
    }

    /// One passive body. The scene records a body by its LEFT edge, so a
    /// left-hand chain's cursor is one body width past where it is recorded;
    /// `flip` is the same fact, drawn (the hub is on the body's right).
    pub fn passive(
        self: SceneChain,
        inst: FlatInst,
        x: f64,
        cy: f64,
        dir: schematic_walk.Direction,
    ) RenderError!void {
        const hub_right = dir == .left;
        try self.scene.addPassive(inst, if (hub_right) x - passive_bw else x, cy, hub_right);
    }
};

fn collectPassiveChainLeft(scene: *SceneGraph, _: Allocator, start_x: f64, cy: f64, spokes: []const FlatInst) !f64 {
    return schematic_walk.passiveChain(SceneChain{ .scene = scene }, .left, start_x, cy, spokes);
}

fn collectPassiveChainRight(scene: *SceneGraph, _: Allocator, start_x: f64, cy: f64, spokes: []const FlatInst) !f64 {
    return schematic_walk.passiveChain(SceneChain{ .scene = scene }, .right, start_x, cy, spokes);
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
    const start_y = center_y - total_height / half_divisor;

    const bx = junction_x - bus_gap;
    try scene.addWire(junction_net, junction_x, center_y, bx, center_y, false);
    if (n > 1) {
        try scene.addWire(junction_net, bx, start_y, bx, start_y + total_height, true);
    }

    const BranchBody = struct { end_x: f64, cy: f64, terminal: []const u8 };
    var bodies: std.ArrayList(BranchBody) = .empty;

    for (branches, 0..) |branch, idx| {
        const by = start_y + @as(f64, @floatFromInt(idx)) * branch_spacing;
        try scene.addWire(junction_net, bx, by, bx - branch_bus_gap, by, false);
        const chain_end_x = try collectPassiveChainLeft(scene, allocator, bx - branch_bus_gap, by, branch.chain);
        try bodies.append(allocator, .{ .end_x = chain_end_x, .cy = by, .terminal = branch.terminal });
    }

    // Terminals
    var term_x: f64 = 0;
    for (bodies.items) |b| {
        const tx = b.end_x - pin_offset;
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
    const start_y = center_y - total_height / half_divisor;

    const bx = junction_x + bus_gap;
    try scene.addWire(junction_net, junction_x, center_y, bx, center_y, false);
    if (n > 1) {
        try scene.addWire(junction_net, bx, start_y, bx, start_y + total_height, true);
    }

    const BranchBody = struct { end_x: f64, cy: f64, terminal: []const u8 };
    var bodies: std.ArrayList(BranchBody) = .empty;

    for (branches, 0..) |branch, idx| {
        const by = start_y + @as(f64, @floatFromInt(idx)) * branch_spacing;
        try scene.addWire(junction_net, bx, by, bx + branch_bus_gap, by, false);
        const chain_end_x = try collectPassiveChainRight(scene, allocator, bx + branch_bus_gap, by, branch.chain);
        try bodies.append(allocator, .{ .end_x = chain_end_x, .cy = by, .terminal = branch.terminal });
    }

    var term_x: f64 = 0;
    for (bodies.items) |b| {
        const tx = b.end_x + pin_offset;
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

/// The scene-graph backend of `schematic_walk.terminalGroups`. A branch body
/// already carries its end x, so nothing is materialised here; wires and
/// terminal labels go straight into the scene.
const SceneTerminals = struct {
    ctx: *RenderCtx,
    scene: *SceneGraph,

    /// Whether this terminal name is drawn at all.
    pub fn significant(self: SceneTerminals, term: []const u8) bool {
        return self.ctx.significant_nets.contains(term);
    }

    /// A branch body already carries its end x, so nothing is materialised.
    pub fn branchEnd(_: SceneTerminals, r: BranchResult) RenderError!f64 {
        return r.end_x;
    }

    /// One net-tagged segment, with the group's vertical collector bus kept
    /// distinct so the scene records it as a bus rather than as a wire.
    pub fn wire(self: SceneTerminals, seg: schematic_walk.Segment) RenderError!void {
        try self.scene.addWire(seg.term, seg.x1, seg.y1, seg.x2, seg.y2, seg.vertical);
    }

    /// The terminal's label or ground symbol at the end of the group.
    pub fn terminal(self: SceneTerminals, x: f64, cy: f64, term: []const u8, anchor: []const u8) RenderError!void {
        try collectTerminalLabel(self.ctx, self.scene, x, cy, term, anchor);
    }
};

fn collectTerminals(ctx: *RenderCtx, scene: *SceneGraph, _: Allocator, results: []const BranchResult, term_x: f64, side: Side) !void {
    return schematic_walk.terminalGroups(
        SceneTerminals{ .ctx = ctx, .scene = scene },
        results,
        term_x,
        side,
    );
}

fn collectTerminalLabel(ctx: *RenderCtx, scene: *SceneGraph, end_x: f64, cy: f64, term: []const u8, anchor: []const u8) !void {
    const display = baseNetName(term);
    if (isGroundNet(display)) {
        try scene.addLabel(display, end_x, cy, anchor, false, true);
    } else {
        const is_port = ctx.isBoundaryPort(term) or ctx.isBoundaryPort(display);
        const label_x: f64 = if (std.mem.eql(u8, anchor, "end")) end_x - net_label_gap else end_x + net_label_gap;
        try scene.addLabel(display, label_x, cy, anchor, is_port, false);
    }
}

// ── JSON Serialization ───────────────────────────────────────────────

/// Power rails (sub-block-sourced) with their producer IC resolved — the
/// scene graph draws the power tree from these (producer ghost on a
/// regulator's input rail, power-first cell ordering).
fn writeRailsJson(w: anytype, power_rails: []const ScenePowerRail) !void {
    try w.writeAll(",\"rails\":[");
    for (power_rails, 0..) |r, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"net\":");
        try json_writer.writeString(w, r.net);
        try w.writeAll(",\"source\":");
        try json_writer.writeString(w, r.source);
        try w.writeAll(",\"source_port\":");
        try json_writer.writeString(w, r.source_port);
        try w.writeAll(",\"source_hub\":");
        try json_writer.writeString(w, r.source_hub);
        if (r.nominal) |v| try w.print(",\"nominal\":{d}", .{v});
        try w.writeAll(",\"aliases\":[");
        for (r.aliases, 0..) |a, j| {
            if (j > 0) try w.writeAll(",");
            try json_writer.writeString(w, a);
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]");
}

fn serializeScene(allocator: Allocator, scene: *const SceneGraph) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

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
        try writeJsonHub(w, h);
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
        if (p.slot) |sl| try w.print(",\"slot\":{d}", .{sl});
        if (p.decouple_pin.len > 0) {
            try w.writeAll(",");
            try writeJsonString(w, "decouplePin", p.decouple_pin);
            if (p.decouple_ic.len > 0) {
                try w.writeAll(",");
                try writeJsonString(w, "decoupleIc", p.decouple_ic);
            }
        }
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

    // Authored section names (scene clients page by these).
    try w.writeAll(",\"authored_sections\":[");
    for (scene.authored_sections, 0..) |nm, i| {
        if (i > 0) try w.writeAll(",");
        try json_writer.writeString(w, nm);
    }
    try w.writeAll("]");

    // Shared opener for {"name":…} objects (sheet_meta / functions / ports).
    const obj_name_open = "{\"name\":";

    // Sheet categories (same names as authored_sections, classified) — the
    // Clients order bands canonically and color glance chips from these.
    try w.writeAll(",\"sheet_meta\":[");
    for (scene.sheet_meta, 0..) |sm, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(obj_name_open);
        try json_writer.writeString(w, sm.name);
        try w.writeAll(",\"cat\":");
        try json_writer.writeString(w, sm.cat);
        if (sm.sub.len > 0) {
            try w.writeAll(",\"sub\":");
            try json_writer.writeString(w, sm.sub);
        }
        try w.writeAll("}");
    }
    try w.writeAll("]");

    // Hand-authored (function …) super-blocks — the map's outermost zoom
    // level. Omitted entirely when the design authors none.
    if (scene.functions.len > 0) {
        try w.writeAll(",\"functions\":[");
        for (scene.functions, 0..) |f, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll(obj_name_open);
            try json_writer.writeString(w, f.name);
            if (f.caption.len > 0) {
                try w.writeAll(",\"cap\":");
                try json_writer.writeString(w, f.caption);
            }
            if (f.stack > 1) try w.print(",\"stack\":{d}", .{f.stack});
            try w.writeAll(",\"hosts\":[");
            for (f.hosts, 0..) |h, j| {
                if (j > 0) try w.writeAll(",");
                try json_writer.writeString(w, h);
            }
            try w.writeAll("]}");
        }
        try w.writeAll("]");
    }

    // Top-level boundary ports (the scene graph's design-interface list).
    try w.writeAll(",\"ports\":[");
    for (scene.ports, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(obj_name_open);
        try json_writer.writeString(w, p.name);
        try w.writeAll(",\"net\":");
        try json_writer.writeString(w, p.net);
        try w.writeAll(",\"dir\":");
        try json_writer.writeString(w, p.direction);
        try w.writeAll("}");
    }
    try w.writeAll("]");

    try writeRailsJson(w, scene.power_rails);

    try w.writeAll("}");
    return buf.toOwnedSlice();
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

/// Serialize one hub box (identity, geometry, authored sheet, both pin columns).
///
// not the json-escaper-def idiom: this and `writeJsonPin` are structural
/// emitters, not string escapers — the file's `writeJsonString` /
/// `writeEscaped` are already aliases of `json_writer.writeField` /
/// `json_writer.writeEscaped`.
fn writeJsonHub(w: anytype, h: JsonHub) !void {
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
    if (h.sec.len > 0) {
        try w.writeAll(",");
        try writeJsonString(w, "sec", h.sec);
    }
    if (h.slot) |sl| try w.print(",\"slot\":{d}", .{sl});
    try w.writeAll(",\"leftPins\":[");
    for (h.left_pins.items, 0..) |pin, pi| {
        if (pi > 0) try w.writeAll(",");
        try writeJsonPin(w, pin);
    }
    try w.writeAll("]");
    try w.writeAll(",\"rightPins\":[");
    for (h.right_pins.items, 0..) |pin, pi| {
        if (pi > 0) try w.writeAll(",");
        try writeJsonPin(w, pin);
    }
    try w.writeAll("]}");
}

fn writeJsonPin(w: anytype, pin: JsonPin) !void {
    try w.writeAll("{");
    try writeJsonString(w, "pins", pin.pin_numbers);
    try w.writeAll(",");
    try writeJsonString(w, "name", pin.display_name);
    try w.print(",\"y\":{d:.1}", .{pin.y});
    if (pin.net.len > 0) {
        try w.writeAll(",");
        try writeJsonString(w, "net", pin.net);
    }
    if (pin.active_fn.len > 0) {
        try w.writeAll(",");
        try writeJsonString(w, "activeFn", pin.active_fn);
    }
    if (pin.role.len > 0) {
        try w.writeAll(",");
        try writeJsonString(w, "role", pin.role);
    }
    if (pin.pgroup.len > 0) {
        try w.writeAll(",");
        try writeJsonString(w, "grp", pin.pgroup);
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

/// Test-only pin group with just the fields the role classifier reads.
fn testPinGroup(display_name: []const u8) PinGroup {
    return .{ .display_name = display_name, .pin_numbers = "1", .conns = &.{} };
}

// spec: render_svg - Pin groups classify supply and ground roles from function or net names
test "pinGroupRole classifies supplies, grounds, and signals" {
    try std.testing.expectEqualStrings("gnd", pinGroupRole(testPinGroup("VSS_(9)"), ""));
    try std.testing.expectEqualStrings("gnd", pinGroupRole(testPinGroup("3"), "GND"));
    try std.testing.expectEqualStrings("pwr", pinGroupRole(testPinGroup("VDDA18_USB"), ""));
    try std.testing.expectEqualStrings("pwr", pinGroupRole(testPinGroup("7"), "VBUS"));
    try std.testing.expectEqualStrings("", pinGroupRole(testPinGroup("PA3"), "SPI_SCK"));
}

/// Assemble the minimal block for the attached-sub-block sheet tests: one
/// authored section plus the caller-owned sub-blocks. The slice must live in
/// the caller's frame — a runtime-valued array literal here would be a stack
/// temporary of this function and dangle in the returned block.
fn testAttachBlock(subs: []const env_mod.SubBlock) DesignBlock {
    return .{
        .name = "t",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sections = &[_]env_mod.Section{.{ .name = "Boot NOR Flash", .description = "MX66UW 1Gb OctoSPI" }},
        .sub_blocks = subs,
    };
}

// spec: render_svg - An attached sub-block folds into its host section instead of paging its module title
test "collectAuthoredSections drops attached sub-block module titles" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var inner_a = DesignBlock{ .name = "MX66UW Flash", .instances = &.{}, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &.{} };
    var inner_b = DesignBlock{ .name = "Aux Module", .instances = &.{}, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &.{} };
    const subs = [_]env_mod.SubBlock{ .{ .name = "flash", .block = &inner_a }, .{ .name = "aux", .block = &inner_b } };
    const block = testAttachBlock(&subs);
    const attachments = [_]?usize{ 0, null };
    const names = try collectAuthoredSections(arena, &block, &attachments);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("Boot NOR Flash", names[0]);
    try std.testing.expectEqualStrings("Aux Module", names[1]);
}

// spec: render_svg - Sheet metadata classifies each authored sheet with the system-overview category
test "buildSheetMeta categorizes sections and unattached sub-blocks" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var inner_a = DesignBlock{ .name = "MX66UW Flash", .instances = &.{}, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &.{} };
    var inner_b = DesignBlock{ .name = "USB-C 2.0 HS", .instances = &.{}, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &.{} };
    const subs = [_]env_mod.SubBlock{ .{ .name = "flash", .block = &inner_a }, .{ .name = "aux", .block = &inner_b } };
    const block = testAttachBlock(&subs);
    const attachments = [_]?usize{ 0, null };
    const metas = try buildSheetMeta(arena, &block, &attachments);
    try std.testing.expectEqual(@as(usize, 2), metas.len);
    try std.testing.expectEqualStrings("memory", metas[0].cat); // "Boot NOR Flash" → Flash keyword
    try std.testing.expectEqualStrings("MX66UW 1Gb OctoSPI", metas[0].sub); // authored subtitle rides along
    try std.testing.expectEqualStrings("comms", metas[1].cat); // "USB-C 2.0 HS" → USB keyword
    try std.testing.expectEqualStrings("", metas[1].sub); // sub-blocks have no subtitle
}

// spec: render_svg - Scene hubs serialize their authored sheet and the scene lists sheet categories
test "serializeScene emits hub sec, pin role, and sheet_meta" {
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
    var hub = JsonHub{
        .ref = "U1",
        .component = "c",
        .value = "",
        .symbol = "s",
        .part = null,
        .label = "U1",
        .x = 0,
        .y = 0,
        .w = 10,
        .h = 10,
        .icon = null,
        .sec = "Boot NOR Flash",
        .left_pins = .empty,
        .right_pins = .empty,
    };
    try hub.left_pins.append(alloc, .{ .pin_numbers = "1", .display_name = "VSS", .y = 0, .side = "left", .net = "GND", .role = "gnd", .pgroup = "Power" });
    defer scene.hubs.items[0].left_pins.deinit(alloc);
    try scene.hubs.append(alloc, hub);
    scene.sheet_meta = &[_]SheetMeta{
        .{ .name = "Boot NOR Flash", .cat = "memory", .sub = "MX66UW 1Gb OctoSPI" },
        .{ .name = "Aux", .cat = "peripheral" },
    };
    const hosts = [_][]const u8{ "Boot NOR Flash", "Aux" };
    scene.functions = &[_]env_mod.FunctionSpec{
        .{ .name = "Storage", .caption = "1Gb NOR boot + scratch", .stack = 2, .hosts = &hosts },
    };
    const out = try serializeScene(alloc, &scene);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"sec\":\"Boot NOR Flash\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"role\":\"gnd\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"grp\":\"Power\"") != null);
    // Subtitle serialized when authored, omitted when empty.
    const want_meta = "\"sheet_meta\":[{\"name\":\"Boot NOR Flash\",\"cat\":\"memory\"," ++
        "\"sub\":\"MX66UW 1Gb OctoSPI\"},{\"name\":\"Aux\",\"cat\":\"peripheral\"}]";
    try std.testing.expect(std.mem.indexOf(u8, out, want_meta) != null);
    // Authored (function …) super-blocks ride along for the map's top level.
    const want_fns = "\"functions\":[{\"name\":\"Storage\",\"cap\":\"1Gb NOR boot + scratch\"," ++
        "\"stack\":2,\"hosts\":[\"Boot NOR Flash\",\"Aux\"]}]";
    try std.testing.expect(std.mem.indexOf(u8, out, want_fns) != null);
}

test "collectPassiveChainLeft steps the chain leftward by pin offset and body width" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scene = SceneGraph.init(arena);
    const spokes = [_]FlatInst{
        .{ .ref_des = "R1", .component = "res", .value = "", .symbol = "" },
        .{ .ref_des = "R2", .component = "res", .value = "", .symbol = "" },
    };
    const start_x: f64 = 1000;
    const end_x = try collectPassiveChainLeft(&scene, arena, start_x, 50, &spokes);
    // First spoke steps back one body width; the second adds a pin-offset hop
    // then another body. `x -= PIN_OFFSET`→`+=` walks the second spoke the wrong
    // way, moving the chain end by +2·PIN_OFFSET.
    try std.testing.expectEqual(start_x - 2 * passive_bw - pin_offset, end_x);
    try std.testing.expectEqual(@as(usize, 2), scene.passives.items.len);
    try std.testing.expectEqual(start_x - 2 * passive_bw - pin_offset, scene.passives.items[1].x);
}

/// Parse the numeric `viewBox` height out of a rendered scene-graph JSON.
fn viewBoxHeight(json: []const u8) f64 {
    const vb = std.mem.indexOf(u8, json, "\"viewBox\"") orelse return std.math.nan(f64);
    const hk = "\"h\":";
    const hs = (std.mem.indexOfPos(u8, json, vb, hk) orelse return std.math.nan(f64)) + hk.len;
    var e = hs;
    while (e < json.len and (std.ascii.isDigit(json[e]) or json[e] == '.' or json[e] == '-')) e += 1;
    return std.fmt.parseFloat(f64, json[hs..e]) catch std.math.nan(f64);
}

test "renderSceneGraph sizes the viewBox to its section's stacked cell height" {
    // U1 is a tall hub (eight distinct rail pins, each with a bypass cap); its
    // one section's height accumulates every cell height. `sec_height += …`
    // flipped to `-=` drives that sum negative, collapsing the row to zero and
    // the viewBox to the MIN_VB_HEIGHT floor.
    const insts = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "C1", .component = "cap", .value = "100nF", .footprint = "", .symbol = "" },
        .{ .ref_des = "C2", .component = "cap", .value = "100nF", .footprint = "", .symbol = "" },
        .{ .ref_des = "C3", .component = "cap", .value = "100nF", .footprint = "", .symbol = "" },
        .{ .ref_des = "C4", .component = "cap", .value = "100nF", .footprint = "", .symbol = "" },
        .{ .ref_des = "C5", .component = "cap", .value = "100nF", .footprint = "", .symbol = "" },
        .{ .ref_des = "C6", .component = "cap", .value = "100nF", .footprint = "", .symbol = "" },
        .{ .ref_des = "C7", .component = "cap", .value = "100nF", .footprint = "", .symbol = "" },
        .{ .ref_des = "C8", .component = "cap", .value = "100nF", .footprint = "", .symbol = "" },
    };
    const p1 = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const p2 = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "2" }, .{ .ref_des = "C2", .pin = "1" } };
    const p3 = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "3" }, .{ .ref_des = "C3", .pin = "1" } };
    const p4 = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "4" }, .{ .ref_des = "C4", .pin = "1" } };
    const p5 = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "5" }, .{ .ref_des = "C5", .pin = "1" } };
    const p6 = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "6" }, .{ .ref_des = "C6", .pin = "1" } };
    const p7 = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "7" }, .{ .ref_des = "C7", .pin = "1" } };
    const p8 = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "8" }, .{ .ref_des = "C8", .pin = "1" } };
    const nets = [_]env_mod.Net{
        .{ .name = "V1", .pins = &p1 }, .{ .name = "V2", .pins = &p2 },
        .{ .name = "V3", .pins = &p3 }, .{ .name = "V4", .pins = &p4 },
        .{ .name = "V5", .pins = &p5 }, .{ .name = "V6", .pins = &p6 },
        .{ .name = "V7", .pins = &p7 }, .{ .name = "V8", .pins = &p8 },
    };
    var block: DesignBlock = .{
        .name = "vb-height-test",
        .instances = &insts,
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json = try renderSceneGraph(arena.allocator(), &block, "");
    try std.testing.expect(viewBoxHeight(json) > min_vb_height);
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, pos, needle)) |idx| {
        count += 1;
        pos = idx + needle.len;
    }
    return count;
}

// spec: render_svg - The scene graph preserves one entry per identical decoupling capacitor
test "renderSceneGraph keeps identical decoupling capacitors separate" {
    const insts = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "C1", .component = "cap", .value = "0.1uF", .footprint = "", .symbol = "generic-cap" },
        .{ .ref_des = "C2", .component = "cap", .value = "0.1uF", .footprint = "", .symbol = "generic-cap" },
    };
    const supply_pins = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "C1", .pin = "1" },
        .{ .ref_des = "C2", .pin = "1" },
    };
    const ground_pins = [_]env_mod.PinRef{
        .{ .ref_des = "C1", .pin = "2" },
        .{ .ref_des = "C2", .pin = "2" },
    };
    const nets = [_]env_mod.Net{
        .{ .name = "VCC", .pins = &supply_pins },
        .{ .name = "GND", .pins = &ground_pins },
    };
    var block: DesignBlock = .{
        .name = "separate-decoupling-test",
        .instances = &insts,
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json = try renderSceneGraph(arena.allocator(), &block, "");

    try std.testing.expectEqual(@as(usize, 1), countOccurrences(json, "\"ref\":\"C1\""));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(json, "\"ref\":\"C2\""));
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(json, "\"value\":\"0.1uF\""));
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(json, "\"count\":1"));
}

test "renderSceneGraph emits each passive junction member once" {
    // Pin 1 reaches a three-way passive junction. R2 and R3 are drawn in that
    // first branch tree, but each also touches another U1 pin's net. Unless the
    // branch chains enter `rendered_spokes`, those later hub pins walk back into
    // the same junction and emit R2/R3 a second time (the LMX2595 bias-tee bug).
    const insts = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "R1", .component = "res", .value = "50R", .footprint = "", .symbol = "generic-res" },
        .{ .ref_des = "R2", .component = "res", .value = "50R", .footprint = "", .symbol = "generic-res" },
        .{ .ref_des = "R3", .component = "res", .value = "50R", .footprint = "", .symbol = "generic-res" },
    };
    const n1_pins = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "R1", .pin = "1" } };
    const junction_pins = [_]env_mod.PinRef{
        .{ .ref_des = "R1", .pin = "2" },
        .{ .ref_des = "R2", .pin = "1" },
        .{ .ref_des = "R3", .pin = "1" },
    };
    const vdd_pins = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "2" }, .{ .ref_des = "R3", .pin = "2" } };
    const gnd_pins = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "3" }, .{ .ref_des = "R2", .pin = "2" } };
    const nets = [_]env_mod.Net{
        .{ .name = "N1", .pins = &n1_pins },
        .{ .name = "JUNCTION", .pins = &junction_pins },
        .{ .name = "VDD", .pins = &vdd_pins },
        .{ .name = "GND", .pins = &gnd_pins },
    };
    var block: DesignBlock = .{
        .name = "passive-junction-test",
        .instances = &insts,
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json = try renderSceneGraph(arena.allocator(), &block, "");

    try std.testing.expectEqual(@as(usize, 1), countOccurrences(json, "\"ref\":\"R1\""));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(json, "\"ref\":\"R2\""));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(json, "\"ref\":\"R3\""));
}

// spec: render_svg - A bare-integer pinout pad id carries its alternate functions into the scene graph
test "loadPinoutAlts reads bare-integer pad ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/pinouts");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/pinouts/chip.sexp", .data =
        \\(pinout "chip"
        \\  (pin 1 "PA1" (alt "SPI1_MOSI" io) (alt "TIM1_CH1" io))
        \\  (pin "B1" "PB1" (alt "I2C1_SDA" io))
        \\)
    });
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    var map: PinoutAltMap = .empty;
    try loadPinoutAlts(alloc, &map, project_dir, "chip");
    const by_pin = map.get("chip") orelse return error.TestUnexpectedResult;

    // The integer pad keys as "1" — the spelling `PinRef.pin` carries and the
    // one `erc.loadPinoutMap` uses, so the drawn alts agree with ERC's.
    const alts = by_pin.get("1") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), alts.len);
    try std.testing.expectEqualStrings("SPI1_MOSI", alts[0]);
    try std.testing.expectEqualStrings("TIM1_CH1", alts[1]);
    // A quoted pad in the same file still loads beside it.
    try std.testing.expect(by_pin.get("B1") != null);
}

// spec: render_svg - Both scene-graph pinout readers take the class-owned lib_limits cap, so a pinout past the retired 256 KiB figure still carries its pin names and alternates
test "the scene-graph pinout readers load a pinout past the retired 256 KiB cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // 256 KiB..1 MiB is the exact band this used to break in: the HTML page
    // (`render_html.zig`) and ERC both already read at the class cap and showed
    // the part's pin names, while these two readers — capped at 256 KiB behind
    // `catch return` / `catch return null` — dropped it to bare net names with
    // no diagnostic anywhere. The cap comes from `lib_limits`, so this file
    // never restates a figure of its own.
    const data = try lib_limits.synthPinoutSource(alloc, "big", lib_limits.retired_lib_file_cap_bytes + 4096);
    try std.testing.expect(data.len > lib_limits.retired_lib_file_cap_bytes);
    try std.testing.expect(data.len < lib_limits.max_lib_file_bytes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/pinouts");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/pinouts/big.sexp", .data = data });
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    // Reader 1 — alternates. Over the old cap the read failed outright, so the
    // symbol never entered the map at all.
    var map: PinoutAltMap = .empty;
    try loadPinoutAlts(alloc, &map, project_dir, "big");
    const by_pin = map.get("big") orelse return error.TestUnexpectedResult;
    const alts = by_pin.get("LAST") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("SENTINEL", alts[0]);

    // Reader 2 — the hub pin-name supplement, which spelled the same cap as
    // `1 << 18` and so diverged even from its own file's other reader.
    const path = try std.fmt.allocPrint(alloc, "{s}/lib/pinouts/big.sexp", .{project_dir});
    const names = loadPinoutNames(alloc, path) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("LASTFN", names.get("LAST") orelse return error.TestUnexpectedResult);
}
