//! Connection rendering: walks a hub's pin group out to its terminals,
//! following passive spoke chains across the net (`findSpokeChain`) to resolve
//! what each pin ultimately reaches, then emits the grouped wires and branch
//! bodies. The bridge between a hub's pins and `branch.zig`'s trees.

const std = @import("std");
const env_mod = @import("../eval/env.zig");
const rails_mod = @import("../eval/rails.zig");
const PinRef = env_mod.PinRef;
const ctx_mod = @import("context.zig");
const RenderCtx = ctx_mod.RenderCtx;
const FlatInst = ctx_mod.FlatInst;
const AdjEntry = ctx_mod.AdjEntry;
const Endpoint = ctx_mod.Endpoint;
const Side = ctx_mod.Side;
const BranchBody = ctx_mod.BranchBody;
const PinGroup = ctx_mod.PinGroup;
const draw = @import("draw.zig");
const spoke_len = draw.spoke_len;
const per_conn_spacing = draw.per_conn_spacing;
const passive_bw = draw.passive_bw;
const passive_bh = draw.passive_bh;
const isGroundNet = draw.isGroundNet;
const baseNetName = draw.baseNetName;
const shortRef = draw.shortRef;
const formatShort = draw.formatShort;
const endpointEql = draw.endpointEql;
const drawNetWire = draw.drawNetWire;
const drawNcSymbol = draw.drawNcSymbol;
const drawSymbolShape = draw.drawSymbolShape;
const writeDebugPin = draw.writeDebugPin;
const hub_mod = @import("hub.zig");
const estimateBranchCount = hub_mod.estimateBranchCount;
const branch_mod = @import("branch.zig");
const RenderError = draw.RenderError;
const escape = @import("../escape.zig");

fn passiveRenderCount(inst: FlatInst) u32 {
    var digits: usize = 0;
    while (digits < inst.value.len and std.ascii.isDigit(inst.value[digits])) : (digits += 1) {}
    if (digits == 0 or !std.mem.startsWith(u8, inst.value[digits..], "× ")) return 1;
    return std.fmt.parseInt(u32, inst.value[0..digits], 10) catch 1;
}

// ── Layout constants ──────────────────────────────────────────────
const half_divisor: f64 = 2.0;
const nc_offset: f64 = 10.0;
const bus_offset_px: f64 = 10.0;
const pin_offset: f64 = 20.0;
const feedback_lane_gap: f64 = 24.0;
const branch_tree_bus_gap: f64 = draw.bus_gap;
const far_x_sentinel: f64 = 99999.0;
const vertical_label_gap: f64 = 9.0;
const vertical_hit_width: f64 = 96.0;
const vertical_hit_pad: f64 = 6.0;
const vertical_label_baseline: f64 = 4.0;
const boundary_termination_gap: f64 = 56.0;
const boundary_stub_len: f64 = 24.0;

const TerminalSortCtx = struct {
    functional: bool,
    pin_net: []const u8,
};

/// Terminal groups deferred until the whole hub has been drawn. Most terminal
/// labels can be emitted one pin row at a time, but a feedback divider is a
/// back-edge: one row reaches the output rail through its upper resistor while
/// a later row is the output pin itself. Seeing both rows at once lets us draw
/// that rail as one continuous, schematic-like loop instead of two matching
/// labels that merely imply the connection.
pub const DeferredTerminals = struct {
    const Run = struct {
        results: []const BranchBody,
        term_x: f64,
        side: Side,
        source_net: []const u8,
        source_is_feedback: bool,
    };

    runs: std.ArrayList(Run) = .empty,
};

const GroupRender = struct {
    hub_ref: []const u8,
    group: PinGroup,
    stub_x: f64,
    py: f64,
    side: Side,
};

const Classified = struct {
    conn: AdjEntry,
    terminal: []const u8,
    externally_visible: bool,
};

/// Feedback-loop closure is deliberately gated by the hub pin's function, not
/// just by repeated-net topology. Supply pull-ups have the same graph shape as
/// an output-to-feedback divider (a rail anchor plus a passive return), but a
/// human schematic only closes the latter as a long outside loop.
fn isFeedbackPinLabel(label: []const u8) bool {
    return std.ascii.eqlIgnoreCase(label, "FB") or
        std.ascii.eqlIgnoreCase(label, "VFB") or
        std.ascii.eqlIgnoreCase(label, "SENSE") or
        std.ascii.eqlIgnoreCase(label, "VSENSE") or
        std.ascii.startsWithIgnoreCase(label, "FB_(") or
        std.ascii.startsWithIgnoreCase(label, "VFB_(") or
        std.ascii.startsWithIgnoreCase(label, "SENSE_(") or
        std.ascii.startsWithIgnoreCase(label, "VSENSE_(");
}

fn groupHasFeedbackPin(group: PinGroup) bool {
    for (group.stub_labels) |label| {
        if (isFeedbackPinLabel(label)) return true;
    }
    return isFeedbackPinLabel(group.display_name);
}

test "feedback pin labels exclude ordinary supply and control pins" {
    const testing = std.testing;
    try testing.expect(isFeedbackPinLabel("FB"));
    try testing.expect(isFeedbackPinLabel("vfb"));
    try testing.expect(isFeedbackPinLabel("SENSE"));
    try testing.expect(isFeedbackPinLabel("VSENSE_(2)"));
    try testing.expect(!isFeedbackPinLabel("VDD_F"));
    try testing.expect(!isFeedbackPinLabel("PAR_C16"));
}

/// x-coordinate of a stub's no-connect glyph. Shared by the no-connections
/// path and the all-connections-filtered-away path so both mark a bare stub
/// the same way.
fn ncX(stub_x: f64, side: Side) f64 {
    return switch (side) {
        .left => stub_x - nc_offset,
        .right => stub_x + nc_offset,
    };
}

/// True when nothing this pin group reaches is a real connection: every net
/// endpoint sits on a net carrying no second pin, and no endpoint links straight
/// to another part's pin. That — not "the renderer drew nothing" — is what makes
/// a no-connect glyph an honest claim. Net membership is read off `net_index`,
/// which is keyed on the BASE net name, so the `<rail>.<ic>.<pad>` bypass-stub
/// spellings count as pins of their rail (which is what they are).
fn isDeadEndGroup(self: *RenderCtx, group: PinGroup) bool {
    for (group.conns) |conn| {
        const net = switch (conn.endpoint) {
            .net => |n| n,
            // A direct pin-to-pin link is a drawn part on the other end.
            .pin => return false,
        };
        const nps = self.net_index.get(baseNetName(net)) orelse continue;
        if (nps.items.len >= 2) return false;
    }
    return true;
}

/// Whether a connection back to the pin's OWN net earns a drawn wire and label.
/// A hub pin's own net is normally implicit — the pin stub already names it — so
/// it is suppressed unless the reader has somewhere to follow it: the net leaves
/// the schematic, an already-rendered spoke sits on it, a second hub does, or a
/// spoke on it lives in a different section (the net crosses a section boundary).
/// Shared with `render_json`'s scene-graph pass so the two surfaces can never
/// disagree about which net labels exist.
pub fn shouldShowOwnNet(self: *RenderCtx, term: []const u8, hub_ref: []const u8) bool {
    if (self.rendersWhenAlone(term)) return true;
    const nps = self.net_index.get(term) orelse return false;
    const my_section = self.section_map.get(hub_ref);
    for (nps.items) |np| {
        if (self.rendered_spokes.contains(np.ref_des)) return true;
        if (!self.spoke_set.contains(np.ref_des)) {
            if (!std.mem.eql(u8, np.ref_des, hub_ref)) return true;
            continue;
        }
        const other_section = self.section_map.get(np.ref_des);
        if (my_section != null and other_section != null and my_section.? != other_section.?) return true;
    }
    return false;
}

/// Render every connection out of one merged hub-pin group. Classifies each
/// connection as net-label or pin-link (spoke-chain), filters out
/// insignificant nets, then routes the surviving ones onto a per-pin local
/// bus and lays the chains/terminals out vertically without overlapping the
/// neighbouring pins.
pub fn renderGroupedConnections(self: *RenderCtx, w: anytype, hub_ref: []const u8, group: PinGroup, stub_x: f64, py: f64, side: Side) RenderError!void {
    return renderGroupedConnectionsImpl(self, w, .{
        .hub_ref = hub_ref,
        .group = group,
        .stub_x = stub_x,
        .py = py,
        .side = side,
    }, null);
}

/// Hub-level form of `renderGroupedConnections`: connection bodies are drawn
/// immediately, while their terminal wires/labels are collected for one final
/// pass. That pass can recognise and directly close a feedback loop without
/// changing the ordinary per-row renderer used by focused tests and callers.
pub fn renderGroupedConnectionsDeferred(
    self: *RenderCtx,
    w: anytype,
    render: GroupRender,
    deferred: *DeferredTerminals,
) RenderError!void {
    return renderGroupedConnectionsImpl(self, w, render, deferred);
}

fn renderGroupedConnectionsImpl(
    self: *RenderCtx,
    w: anytype,
    render: GroupRender,
    deferred: ?*DeferredTerminals,
) RenderError!void {
    const previous_branch_mode = self.render_scratch.defer_branch_terminals;
    self.render_scratch.defer_branch_terminals = deferred != null;
    defer self.render_scratch.defer_branch_terminals = previous_branch_mode;

    const hub_ref = render.hub_ref;
    const group = render.group;
    const stub_x = render.stub_x;
    const py = render.py;
    const side = render.side;
    if (group.conns.len == 0) {
        try drawNcSymbol(w, ncX(stub_x, side), py);
        return;
    }

    var first_pin_id: []const u8 = "";
    for (group.conns) |c| {
        first_pin_id = c.pin;
        break;
    }
    const canon_key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ hub_ref, first_pin_id });
    const pin_net_name = self.pin_canonical_nets.get(canon_key) orelse "";

    var classified: std.ArrayList(Classified) = .empty;

    for (group.conns) |conn| {
        switch (conn.endpoint) {
            .net => |net| {
                const term = baseNetName(net);
                if (!self.significant_nets.contains(term)) continue;
                const own = std.mem.eql(u8, term, baseNetName(pin_net_name));
                if (own and !shouldShowOwnNet(self, term, hub_ref)) continue;
                try classified.append(self.allocator, .{
                    .conn = conn,
                    .terminal = term,
                    .externally_visible = terminalIsExternallyVisible(self, term),
                });
            },
            .pin => |p| {
                if (self.rendered_spokes.contains(p.ref_des)) continue;
                const term = try getConnTerminal(self, conn.endpoint, hub_ref, conn.pin);
                try classified.append(self.allocator, .{
                    .conn = conn,
                    .terminal = term,
                    .externally_visible = terminalIsExternallyVisible(self, term),
                });
            },
        }
    }

    try deduplicateGroupedSpokes(self, &classified, hub_ref);

    // Every connection on this stub filtered away. A glyph is a reviewable
    // CLAIM ("this pad goes nowhere"), so it may only be drawn when the claim is
    // true — filtering is not evidence of it. Three shapes reach here on
    // genuinely wired pads: a ground pad whose group renders before any of the
    // rail's spokes has entered `rendered_spokes` (a module page whose only hub
    // is the IC), two pads of the SAME hub tied together (an op-amp follower —
    // every `should_show` branch skips both pins, and the glyph landed on top of
    // the tie line), and a spoke already drawn off a sibling pin. Gate on real
    // connectivity instead: only a group whose every net is a lone dead end is a
    // no-connect. The others fall back to drawing nothing, which is the lesser
    // evil — a gap is ambiguous, a false claim is wrong.
    if (classified.items.len == 0) {
        if (isDeadEndGroup(self, group)) try drawNcSymbol(w, ncX(stub_x, side), py);
        return;
    }

    const sort_ctx: TerminalSortCtx = .{
        .functional = self.render_scratch.functional_layout,
        .pin_net = pin_net_name,
    };
    std.mem.sortUnstable(Classified, classified.items, sort_ctx, struct {
        fn lt(order: TerminalSortCtx, a: Classified, b: Classified) bool {
            return terminalLessThan(
                order.functional,
                order.pin_net,
                a.terminal,
                a.externally_visible,
                b.terminal,
                b.externally_visible,
            );
        }
    }.lt);

    var slot_counts = try self.allocator.alloc(u32, classified.items.len);
    var total_slots: u32 = 0;
    for (classified.items, 0..) |entry, i| {
        const slots: u32 = switch (entry.conn.endpoint) {
            .pin => |p| blk: {
                if (self.spoke_set.contains(p.ref_des)) {
                    break :blk estimateBranchCount(self, p.ref_des, hub_ref);
                }
                break :blk 1;
            },
            .net => 1,
        };
        slot_counts[i] = slots;
        total_slots += slots;
    }
    var results: std.ArrayList(BranchBody) = .empty;

    const multi = classified.items.len > 1;
    const bus_offset: f64 = bus_offset_px;
    const bus_x: f64 = switch (side) {
        .left => stub_x - bus_offset,
        .right => stub_x + bus_offset,
    };

    var consumed_slots: u32 = 0;
    var min_cy: f64 = py;
    var max_cy: f64 = py;
    const total_height = @as(f64, @floatFromInt(@max(total_slots, 1) -| 1)) * per_conn_spacing;

    for (classified.items, 0..) |entry, i| {
        const slots = slot_counts[i];
        const slot_center = @as(f64, @floatFromInt(consumed_slots)) + @as(f64, @floatFromInt(slots -| 1)) / half_divisor;
        const cy = py + slot_center * per_conn_spacing - total_height / half_divisor;
        consumed_slots += slots;
        if (cy < min_cy) min_cy = cy;
        if (cy > max_cy) max_cy = cy;

        const internal_net: []const u8 = switch (entry.conn.endpoint) {
            .net => entry.terminal,
            .pin => pin_net_name,
        };

        const conn_stub_x = if (multi) bus_x else stub_x;
        const conn_stub_y = if (multi) cy else py;

        self.render_scratch.functional_series_target_y = functionalSeriesTargetY(
            self,
            side,
            entry.terminal,
            i,
            classified.items.len,
            cy,
        );
        self.render_scratch.rendered_connection_end_y = null;
        const branch_start = self.render_scratch.deferred_branch_terminals.items.len;
        const end_x = try renderConnBody(self, w, entry.conn.endpoint, hub_ref, entry.conn.pin, conn_stub_x, conn_stub_y, cy, side, internal_net);
        const rendered_end_y = self.render_scratch.rendered_connection_end_y;
        const end_y = rendered_end_y orelse cy;
        self.render_scratch.functional_series_target_y = null;
        try appendDeferredBranchRun(
            self,
            deferred,
            branch_start,
            side,
            pin_net_name,
            groupHasFeedbackPin(group),
        );

        try results.append(self.allocator, .{
            .end_x = end_x,
            .cy = end_y,
            .terminal = entry.terminal,
            .inline_direct_lane = rendered_end_y != null,
        });
    }

    if (multi) {
        try drawNetWire(w, stub_x, py, bus_x, py, pin_net_name);
        if (min_cy != max_cy) {
            try w.writeAll("<g class=\"net\" data-net=\"");
            try escape.writeXml(w, pin_net_name);
            try w.print(
                \\" style="cursor:pointer">
                \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="transparent" stroke-width="12" class="hit-area"/>
                \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#4a9" stroke-width="1.5"/>
                \\</g>
                \\
            , .{ bus_x, min_cy, bus_x, max_cy, bus_x, min_cy, bus_x, max_cy });
        }
    }

    var default_term_x: f64 = switch (side) {
        .left => stub_x - spoke_len - pin_offset,
        .right => stub_x + spoke_len + pin_offset,
    };
    for (results.items) |r| {
        switch (side) {
            .left => {
                default_term_x = @min(default_term_x, r.end_x - pin_offset);
            },
            .right => {
                default_term_x = @max(default_term_x, r.end_x + pin_offset);
            },
        }
    }
    const term_x = default_term_x;

    if (deferred) |collector| {
        try collector.runs.append(self.allocator, .{
            .results = try results.toOwnedSlice(self.allocator),
            .term_x = term_x,
            .side = side,
            .source_net = pin_net_name,
            .source_is_feedback = groupHasFeedbackPin(group),
        });
    } else {
        try renderTerminalGroups(self, w, results.items, term_x, side);
    }
}

fn appendDeferredBranchRun(
    self: *RenderCtx,
    deferred: ?*DeferredTerminals,
    branch_start: usize,
    side: Side,
    source_net: []const u8,
    source_is_feedback: bool,
) RenderError!void {
    const collector = deferred orelse return;
    const scratch = self.render_scratch.deferred_branch_terminals.items[branch_start..];
    if (scratch.len == 0) return;

    var term_x = scratch[0].end_x;
    for (scratch) |body| term_x = switch (side) {
        .left => @min(term_x, body.end_x),
        .right => @max(term_x, body.end_x),
    };
    term_x += switch (side) {
        .left => -pin_offset,
        .right => pin_offset,
    };
    try collector.runs.append(self.allocator, .{
        .results = try self.allocator.dupe(BranchBody, scratch),
        .term_x = term_x,
        .side = side,
        .source_net = source_net,
        .source_is_feedback = source_is_feedback,
    });
}

const DeferredGroup = struct {
    results: []const BranchBody,
    term_x: f64,
    side: Side,
    source_net: []const u8,
    source_is_feedback: bool,
    terminal: []const u8,
};

const GroupBodyRef = struct {
    group: usize,
    body: usize,
};

const BoundaryAnchorQuery = struct {
    groups: []const DeferredGroup,
    handled: []const bool,
    side: Side,
    terminal: []const u8,
    bridge_y: f64,
    same_row: bool,
};

fn sameSide(a: Side, b: Side) bool {
    return @backingInt(a) == @backingInt(b);
}

fn sameDeferredNet(a: DeferredGroup, b: DeferredGroup) bool {
    return sameSide(a.side, b.side) and
        std.mem.eql(u8, baseNetName(a.terminal), baseNetName(b.terminal));
}

fn plainBoundaryAnchor(query: BoundaryAnchorQuery) ?GroupBodyRef {
    var found: ?GroupBodyRef = null;
    for (query.groups, 0..) |group, group_idx| {
        if (query.handled[group_idx] or !sameSide(group.side, query.side)) continue;
        if (!std.mem.eql(u8, baseNetName(group.terminal), baseNetName(query.terminal))) continue;
        if (group.results.len != 1) continue;
        const body = group.results[0];
        if (body.deferred_series != null or ((body.cy == query.bridge_y) != query.same_row)) continue;
        if (found != null) return null;
        found = .{ .group = group_idx, .body = 0 };
    }
    return found;
}

fn drawBoundaryTermination(
    self: *RenderCtx,
    w: anytype,
    side: Side,
    source: BranchBody,
    target: BranchBody,
    bridge: BranchBody,
) RenderError!void {
    const inst = bridge.deferred_series.?;
    const source_net = bridge.deferred_source_net;
    const target_net = bridge.terminal;
    const component_x = switch (side) {
        .left => bridge.deferred_start_x - boundary_termination_gap,
        .right => bridge.deferred_start_x + boundary_termination_gap,
    };
    const terminal_x = switch (side) {
        .left => component_x - boundary_stub_len,
        .right => component_x + boundary_stub_len,
    };
    const anchor: []const u8 = switch (side) {
        .left => "end",
        .right => "start",
    };

    // The branch tree already reaches deferred_start_x from the source-side
    // coupling capacitor. Extend that node to the vertical termination, while
    // the other coupling capacitor gets its own parallel horizontal leg.
    try drawNetWire(w, bridge.deferred_start_x, source.cy, component_x, source.cy, source_net);
    try drawNetWire(w, target.end_x, target.cy, component_x, target.cy, target_net);

    const center_y = (source.cy + target.cy) / half_divisor;
    const source_component_y = center_y + (if (target.cy > source.cy) -passive_bw else passive_bw) / half_divisor;
    const target_component_y = center_y + (if (target.cy > source.cy) passive_bw else -passive_bw) / half_divisor;
    try drawNetWire(w, component_x, source.cy, component_x, source_component_y, source_net);
    try drawVerticalPassive(w, inst, component_x, source_component_y, target_component_y, side);
    try drawNetWire(w, component_x, target_component_y, component_x, target.cy, target_net);

    try drawNetWire(w, component_x, source.cy, terminal_x, source.cy, source_net);
    try branch_mod.drawTerminal(self, w, terminal_x, source.cy, source_net, anchor);
    try drawNetWire(w, component_x, target.cy, terminal_x, target.cy, target_net);
    try branch_mod.drawTerminal(self, w, terminal_x, target.cy, target_net, anchor);
}

/// Turn a one-resistor bridge between two boundary signals into the conventional
/// differential-input drawing: two series paths remain beside their hub pins,
/// the termination stands vertically between their external nodes, and both
/// nodes retain short labeled stubs for off-sheet connections.
fn renderBoundaryTerminations(
    self: *RenderCtx,
    w: anytype,
    groups: []const DeferredGroup,
    handled: []bool,
) RenderError!void {
    for (groups, 0..) |group, bridge_group| {
        if (handled[bridge_group] or group.results.len != 1) continue;
        const bridge = group.results[0];
        if (bridge.deferred_series == null or bridge.deferred_source_net.len == 0) continue;
        if (!self.rendersWhenAlone(bridge.deferred_source_net) or !self.rendersWhenAlone(bridge.terminal)) continue;

        const source_ref = plainBoundaryAnchor(.{
            .groups = groups,
            .handled = handled,
            .side = group.side,
            .terminal = bridge.deferred_source_net,
            .bridge_y = bridge.cy,
            .same_row = true,
        }) orelse continue;
        const target_ref = plainBoundaryAnchor(.{
            .groups = groups,
            .handled = handled,
            .side = group.side,
            .terminal = bridge.terminal,
            .bridge_y = bridge.cy,
            .same_row = false,
        }) orelse continue;
        if (source_ref.group == target_ref.group) continue;

        const source = groups[source_ref.group].results[source_ref.body];
        const target = groups[target_ref.group].results[target_ref.body];
        try drawBoundaryTermination(self, w, group.side, source, target, bridge);
        handled[bridge_group] = true;
        handled[source_ref.group] = true;
        handled[target_ref.group] = true;
    }
}

fn terminalIsExternallyVisible(self: *const RenderCtx, terminal: []const u8) bool {
    return self.rendersWhenAlone(terminal) or self.rendersWhenAlone(baseNetName(terminal));
}

fn terminalRank(functional: bool, pin_net: []const u8, terminal: []const u8, externally_visible: bool) u2 {
    if (!functional) return 0;
    if (std.mem.eql(u8, baseNetName(pin_net), baseNetName(terminal))) return 0;
    if (isGroundNet(terminal)) return 1;
    return if (externally_visible) 3 else 2;
}

fn terminalLessThan(
    functional: bool,
    pin_net: []const u8,
    a: []const u8,
    a_externally_visible: bool,
    b: []const u8,
    b_externally_visible: bool,
) bool {
    const a_rank = terminalRank(functional, pin_net, a, a_externally_visible);
    const b_rank = terminalRank(functional, pin_net, b, b_externally_visible);
    if (a_rank != b_rank) return a_rank < b_rank;
    return std.mem.lessThan(u8, a, b);
}

// spec: render_svg - Functional pin rows put the pin's own net before a ground shunt so the shunt draws below the pin; Original remains alphabetical
test "functional terminal ordering places a ground shunt after the pin net" {
    const testing = std.testing;
    try testing.expect(terminalLessThan(true, "LMX_VTUNE", "LMX_VTUNE", false, "GND", false));
    try testing.expect(!terminalLessThan(true, "LMX_VTUNE", "GND", false, "LMX_VTUNE", false));
    try testing.expect(terminalLessThan(false, "LMX_VTUNE", "GND", false, "LMX_VTUNE", false));
    try testing.expect(terminalLessThan(true, "LMX_RFOUTAM", "GND", true, "LO_BIAS_A", false));
    try testing.expect(terminalLessThan(true, "LMX_RFOUTAP", "LO_BIAS_A", false, "LO1_SYNTH", true));
}

// spec: render_svg - Functional direct returns rotate an outside-edge series resistor toward the destination pin while Original keeps it horizontal
test "functional direct return turns its series resistor toward the destination" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const instances = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "lmx2595", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "R46", .component = "res-0402", .value = "18R", .footprint = "", .symbol = "generic-res" },
    };
    const cpout = [_]PinRef{
        .{ .ref_des = "U1", .pin = "12" },
        .{ .ref_des = "R46", .pin = "1" },
    };
    const vtune = [_]PinRef{
        .{ .ref_des = "U1", .pin = "35" },
        .{ .ref_des = "R46", .pin = "2" },
    };
    const nets = [_]env_mod.Net{
        .{ .name = "LMX_CPOUT", .pins = &cpout },
        .{ .name = "LMX_VTUNE", .pins = &vtune },
    };
    const block: env_mod.DesignBlock = .{
        .name = "vertical-series-return",
        .instances = &instances,
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };

    var functional_ctx = RenderCtx.init(allocator);
    try functional_ctx.setup(&block);
    functional_ctx.render_scratch.functional_series_target_y = 180.0;
    var functional: std.Io.Writer.Allocating = .init(allocator);
    const end_x = try renderConnBody(
        &functional_ctx,
        &functional.writer,
        .{ .pin = .{ .ref_des = "R46", .pin = "1" } },
        "U1",
        "12",
        100.0,
        100.0,
        100.0,
        .left,
        "LMX_CPOUT",
    );
    try testing.expectEqual(@as(f64, 100.0), end_x);
    try testing.expectEqual(@as(?f64, 140.0), functional_ctx.render_scratch.rendered_connection_end_y);
    try testing.expect(std.mem.indexOf(u8, functional.written(), "transform=\"rotate(90 100.0 120.0)\"") != null);
    try testing.expect(std.mem.indexOf(u8, functional.written(), ">R46 18R</text>") != null);
    try testing.expect(functional_ctx.render_scratch.functional_inline_nets.contains("LMX_VTUNE"));

    functional_ctx.render_scratch.functional_layout = true;
    var anchor: std.Io.Writer.Allocating = .init(allocator);
    const anchor_x = try renderConnBody(
        &functional_ctx,
        &anchor.writer,
        .{ .net = "LMX_VTUNE" },
        "U1",
        "35",
        100.0,
        180.0,
        180.0,
        .left,
        "LMX_VTUNE",
    );
    try testing.expectEqual(@as(f64, 100.0), anchor_x);
    try testing.expectEqual(@as(usize, 0), anchor.written().len);

    var original_ctx = RenderCtx.init(allocator);
    try original_ctx.setup(&block);
    var original: std.Io.Writer.Allocating = .init(allocator);
    _ = try renderConnBody(
        &original_ctx,
        &original.writer,
        .{ .pin = .{ .ref_des = "R46", .pin = "1" } },
        "U1",
        "12",
        100.0,
        100.0,
        100.0,
        .left,
        "LMX_CPOUT",
    );
    try testing.expect(std.mem.indexOf(u8, original.written(), "transform=\"rotate(90") == null);
    try testing.expectEqual(@as(?f64, null), original_ctx.render_scratch.rendered_connection_end_y);
}

// spec: render_svg - Functional direct returns rotate a one-inductor bridge vertically between two hub-pin rows
test "functional direct return turns its series inductor toward the destination" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const instances = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "tsy-83lnw+", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "L1", .component = "ind-0402", .value = "900nH", .footprint = "", .symbol = "generic-ind" },
    };
    const cm = [_]PinRef{
        .{ .ref_des = "U1", .pin = "2" },
        .{ .ref_des = "L1", .pin = "1" },
    };
    const amp_in = [_]PinRef{
        .{ .ref_des = "U1", .pin = "3" },
        .{ .ref_des = "L1", .pin = "2" },
    };
    const nets = [_]env_mod.Net{
        .{ .name = "CM", .pins = &cm },
        .{ .name = "AMP_IN", .pins = &amp_in },
    };
    const block: env_mod.DesignBlock = .{
        .name = "vertical-inductor-return",
        .instances = &instances,
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };

    var ctx = RenderCtx.init(allocator);
    try ctx.setup(&block);
    ctx.render_scratch.functional_series_target_y = 180.0;
    var rendered: std.Io.Writer.Allocating = .init(allocator);
    const end_x = try renderConnBody(
        &ctx,
        &rendered.writer,
        .{ .pin = .{ .ref_des = "L1", .pin = "1" } },
        "U1",
        "2",
        100.0,
        100.0,
        100.0,
        .left,
        "CM",
    );

    try testing.expectEqual(@as(f64, 100.0), end_x);
    try testing.expectEqual(@as(?f64, 140.0), ctx.render_scratch.rendered_connection_end_y);
    try testing.expect(std.mem.indexOf(u8, rendered.written(), "transform=\"rotate(90 100.0 120.0)\"") != null);
    try testing.expect(std.mem.indexOf(u8, rendered.written(), ">L1 900nH</text>") != null);
    try testing.expect(ctx.render_scratch.functional_inline_nets.contains("AMP_IN"));
}

// spec: render_svg - A vertical passive labels away from its hub: left of left-side parts and right of right-side parts
test "vertical passive labels face away from the hub" {
    const testing = std.testing;
    const resistor: FlatInst = .{
        .ref_des = "R46",
        .component = "res-0402",
        .value = "18R",
        .symbol = "generic-res",
    };

    var left: std.Io.Writer.Allocating = .init(testing.allocator);
    defer left.deinit();
    try drawVerticalPassive(&left.writer, resistor, 100.0, 100.0, 140.0, .left);
    try testing.expect(std.mem.indexOf(u8, left.written(), "<text x=\"91.0\" y=\"124.0\" text-anchor=\"end\"") != null);

    var right: std.Io.Writer.Allocating = .init(testing.allocator);
    defer right.deinit();
    try drawVerticalPassive(&right.writer, resistor, 100.0, 100.0, 140.0, .right);
    try testing.expect(std.mem.indexOf(u8, right.written(), "<text x=\"109.0\" y=\"124.0\" text-anchor=\"start\"") != null);
}

fn isFunctionalSignalTerminal(net: []const u8) bool {
    if (net.len == 0 or isGroundNet(net)) return false;
    for (rails_mod.schematic_supply_prefixes) |prefix| {
        if (std.ascii.startsWithIgnoreCase(net, prefix)) return false;
    }
    return true;
}

fn functionalSeriesTargetY(
    self: *RenderCtx,
    side: Side,
    terminal: []const u8,
    index: usize,
    connection_count: usize,
    cy: f64,
) ?f64 {
    if (!self.render_scratch.functional_layout) return null;
    if (!isFunctionalSignalTerminal(baseNetName(terminal))) return null;
    const target_y = switch (side) {
        .left => self.render_scratch.functional_left_pin_y.get(baseNetName(terminal)),
        .right => self.render_scratch.functional_right_pin_y.get(baseNetName(terminal)),
    } orelse return null;
    if (target_y > cy and index + 1 == connection_count) return target_y;
    if (target_y < cy and index == 0) return target_y;
    return null;
}

fn isDirectCandidate(groups: []const DeferredGroup, idx: usize) bool {
    const group = groups[idx];
    if (isGroundNet(group.terminal)) return false;

    var matching: usize = 0;
    var has_output_anchor = false;
    var has_return = false;
    var has_feedback_return = false;
    for (groups) |other| {
        if (!sameDeferredNet(group, other)) continue;
        matching += 1;
        if (std.mem.eql(u8, baseNetName(other.source_net), baseNetName(other.terminal))) {
            has_output_anchor = true;
        } else {
            has_return = true;
            if (other.source_is_feedback) has_feedback_return = true;
        }
    }
    const is_signal_return = has_return and isFunctionalSignalTerminal(baseNetName(group.terminal));
    return matching >= 2 and ((has_output_anchor and (has_feedback_return or is_signal_return)) or
        candidateHasLocalIslandBranch(groups, group));
}

/// A qualified `.local.` terminal is the SVG-only second attachment for one
/// side of a shared passive island. Matching it with the island owner's plain
/// terminal means both branches should meet on one visible rail, rather than
/// ending in two copies of the same generated label.
fn candidateHasLocalIslandBranch(groups: []const DeferredGroup, candidate: DeferredGroup) bool {
    for (groups) |other| {
        if (!sameDeferredNet(candidate, other)) continue;
        if (std.mem.indexOf(u8, other.terminal, ".local.") != null) return true;
    }
    return false;
}

fn candidateHasFeedbackReturn(groups: []const DeferredGroup, candidate: DeferredGroup) bool {
    for (groups) |other| {
        if (sameDeferredNet(candidate, other) and other.source_is_feedback) return true;
    }
    return false;
}

/// Count distinct feedback nets on `side`. A single outside lane is visually
/// unambiguous; two overlapping loops would need a full channel router, so that
/// rarer shape deliberately falls back to labels instead of drawing crossings.
fn feedbackNetCount(groups: []const DeferredGroup, candidates: []const bool, side: Side) usize {
    var count: usize = 0;
    for (groups, 0..) |group, i| {
        if (!candidates[i] or !sameSide(group.side, side)) continue;
        if (!candidateHasFeedbackReturn(groups, group)) continue;
        var seen = false;
        for (groups[0..i], 0..) |prior, j| {
            if (candidates[j] and sameDeferredNet(group, prior)) {
                seen = true;
                break;
            }
        }
        if (!seen) count += 1;
    }
    return count;
}

const VerticalInterval = struct { first: f64, last: f64 };

fn candidateInterval(groups: []const DeferredGroup, candidates: []const bool, candidate: DeferredGroup) VerticalInterval {
    var interval: VerticalInterval = .{ .first = far_x_sentinel, .last = -far_x_sentinel };
    for (groups, 0..) |group, i| {
        if (!candidates[i] or !sameDeferredNet(candidate, group)) continue;
        for (group.results) |body| {
            interval.first = @min(interval.first, body.cy);
            interval.last = @max(interval.last, body.cy);
        }
    }
    return interval;
}

/// Several ordinary signal returns may share one outside x-lane when their
/// vertical spans are disjoint. This is the common dual-RF-output shape on the
/// LMX2595. Overlapping spans still fall back to repeated local labels.
fn signalLaneIsClear(groups: []const DeferredGroup, candidates: []const bool, idx: usize) bool {
    const candidate = groups[idx];
    if (candidateHasLocalIslandBranch(groups, candidate)) return true;
    const own = candidateInterval(groups, candidates, candidate);
    const clearance: f64 = 12.0;
    for (groups, 0..) |other, other_idx| {
        if (!candidates[other_idx] or !sameSide(candidate.side, other.side)) continue;
        if (std.mem.eql(u8, baseNetName(candidate.terminal), baseNetName(other.terminal))) continue;
        if (candidateHasFeedbackReturn(groups, other)) continue;
        const theirs = candidateInterval(groups, candidates, other);
        const separated = own.last + clearance < theirs.first or theirs.last + clearance < own.first;
        if (!separated) return false;
    }
    return true;
}

/// Draw a branch resistor that was held until the Functional direct-return
/// lane became known. With `aligned_end_x`, the resistor's terminal lands
/// exactly on that lane; null reproduces the ordinary horizontal placement for
/// fallback label routing.
fn materializeDeferredSeries(
    self: *RenderCtx,
    w: anytype,
    body: BranchBody,
    side: Side,
    aligned_end_x: ?f64,
) RenderError!f64 {
    const inst = body.deferred_series orelse return body.end_x;
    const start_x = if (aligned_end_x) |end_x| switch (side) {
        .left => end_x + passive_bw,
        .right => end_x - passive_bw,
    } else body.deferred_start_x;
    if (start_x != body.deferred_start_x) {
        try drawNetWire(w, body.deferred_start_x, body.cy, start_x, body.cy, body.deferred_source_net);
    }
    return switch (side) {
        .left => branch_mod.drawPassiveChainLeft(self, w, start_x, body.cy, &.{inst}),
        .right => branch_mod.drawPassiveChainRight(self, w, start_x, body.cy, &.{inst}),
    };
}

/// Put a shared-bias pull-up beside the output pin it serves instead of on the
/// opposite pull-up's bias-tree branch. The outside lane then carries the bias
/// node, so both resistors read as branches sourced by their own hub pins.
fn rehomeDeferredSeries(
    self: *RenderCtx,
    w: anytype,
    bodies: []const BranchBody,
    side: Side,
    lane_x: f64,
) RenderError!bool {
    if (bodies.len != 2) return false;
    var branch: ?BranchBody = null;
    var anchor: ?BranchBody = null;
    for (bodies) |body| {
        if (body.deferred_series != null) {
            if (branch != null) return false;
            branch = body;
        } else {
            if (anchor != null) return false;
            anchor = body;
        }
    }
    const source = branch orelse return false;
    const output = anchor orelse return false;
    const inst = source.deferred_series.?;

    try drawNetWire(w, source.deferred_start_x, source.cy, lane_x, source.cy, source.deferred_source_net);
    const series_end = switch (side) {
        .left => try branch_mod.drawPassiveChainLeft(self, w, output.end_x, output.cy, &.{inst}),
        .right => try branch_mod.drawPassiveChainRight(self, w, output.end_x, output.cy, &.{inst}),
    };
    try drawNetWire(w, series_end, output.cy, lane_x, output.cy, source.deferred_source_net);
    if (source.cy != output.cy) try drawNetWire(w, lane_x, source.cy, lane_x, output.cy, source.deferred_source_net);
    try writeDebugPin(w, lane_x, output.cy);
    return true;
}

/// A direct rail already makes an internal one-IC net explicit, so repeating
/// its generated name adds noise. Keep a label when the net is a declared port,
/// reaches another hub, or the lightweight caller did not build a net index.
fn directNetNeedsLabel(self: *const RenderCtx, terminal: []const u8) bool {
    if (std.mem.indexOf(u8, terminal, ".local.") != null) return false;
    const net = baseNetName(terminal);
    if (self.isBoundaryPort(terminal) or self.isBoundaryPort(net)) return true;
    const pins = self.net_index.get(net) orelse return true;
    var first_hub: ?[]const u8 = null;
    for (pins.items) |pin| {
        if (self.spoke_set.contains(pin.ref_des)) continue;
        if (first_hub) |hub| {
            if (!std.mem.eql(u8, hub, pin.ref_des)) return true;
        } else {
            first_hub = pin.ref_des;
        }
    }
    return false;
}

fn renderDirectBodies(
    self: *RenderCtx,
    w: anytype,
    bodies: []const BranchBody,
    group: DeferredGroup,
    lane_x: f64,
    has_feedback_return: bool,
) RenderError!void {
    if (!has_feedback_return and try rehomeDeferredSeries(self, w, bodies, group.side, lane_x)) return;
    for (bodies) |body| {
        const end_x = try materializeDeferredSeries(self, w, body, group.side, lane_x);
        if (end_x != lane_x) try drawNetWire(w, end_x, body.cy, lane_x, body.cy, group.terminal);
    }
    const first_y = bodies[0].cy;
    const last_y = bodies[bodies.len - 1].cy;
    if (first_y != last_y) try drawNetWire(w, lane_x, first_y, lane_x, last_y, group.terminal);
    if (directNetNeedsLabel(self, group.terminal)) {
        try branch_mod.drawTerminal(self, w, lane_x, last_y, group.terminal, switch (group.side) {
            .left => "end",
            .right => "start",
        });
    } else {
        try writeDebugPin(w, lane_x, last_y);
    }
}

fn inlineDirectLane(bodies: []const BranchBody) ?f64 {
    for (bodies) |body| {
        if (body.inline_direct_lane) return body.end_x;
    }
    return null;
}

/// Emit every terminal collected for a hub. Recognised feedback and ordinary
/// signal returns route on an outside vertical lane. Board ports and nets that
/// reach another hub receive one label; purely local one-IC returns do not.
/// Supply pull-ups retain local labels, as do candidate lanes whose vertical
/// spans would overlap another direct connection.
pub fn renderDeferredTerminals(
    self: *RenderCtx,
    w: anytype,
    deferred: *const DeferredTerminals,
    functional: bool,
) RenderError!void {
    if (!functional) {
        for (deferred.runs.items) |run| {
            try renderTerminalGroups(self, w, run.results, run.term_x, run.side);
        }
        return;
    }

    var groups: std.ArrayList(DeferredGroup) = .empty;
    for (deferred.runs.items) |run| {
        var i: usize = 0;
        while (i < run.results.len) {
            const terminal = run.results[i].terminal;
            var j = i + 1;
            while (j < run.results.len and std.mem.eql(u8, run.results[j].terminal, terminal)) : (j += 1) {}
            try groups.append(self.allocator, .{
                .results = run.results[i..j],
                .term_x = run.term_x,
                .side = run.side,
                .source_net = run.source_net,
                .source_is_feedback = run.source_is_feedback,
                .terminal = terminal,
            });
            i = j;
        }
    }

    const handled = try self.allocator.alloc(bool, groups.items.len);
    @memset(handled, false);
    try renderBoundaryTerminations(self, w, groups.items, handled);

    const candidates = try self.allocator.alloc(bool, groups.items.len);
    for (groups.items, 0..) |_, i| {
        candidates[i] = !handled[i] and isDirectCandidate(groups.items, i);
    }
    const left_count = feedbackNetCount(groups.items, candidates, .left);
    const right_count = feedbackNetCount(groups.items, candidates, .right);

    for (groups.items, 0..) |group, i| {
        if (handled[i]) continue;
        if (!candidates[i]) {
            try renderTerminalGroups(self, w, group.results, group.term_x, group.side);
            continue;
        }
        const has_feedback_return = candidateHasFeedbackReturn(groups.items, group);
        const lane_is_clear = if (has_feedback_return) switch (group.side) {
            .left => left_count == 1,
            .right => right_count == 1,
        } else signalLaneIsClear(groups.items, candidates, i);
        if (!lane_is_clear) {
            try renderTerminalGroups(self, w, group.results, group.term_x, group.side);
            continue;
        }

        var already_drawn = false;
        for (groups.items[0..i], 0..) |prior, j| {
            if (candidates[j] and sameDeferredNet(group, prior)) {
                already_drawn = true;
                break;
            }
        }
        if (already_drawn) continue;

        var bodies: std.ArrayList(BranchBody) = .empty;
        var lane_x = switch (group.side) {
            .left => far_x_sentinel,
            .right => -far_x_sentinel,
        };
        for (groups.items, 0..) |other, j| {
            if (!candidates[j] or !sameDeferredNet(group, other)) continue;
            try bodies.appendSlice(self.allocator, other.results);
            lane_x = switch (group.side) {
                .left => @min(lane_x, other.term_x - feedback_lane_gap),
                .right => @max(lane_x, other.term_x + feedback_lane_gap),
            };
        }

        std.mem.sortUnstable(BranchBody, bodies.items, {}, struct {
            fn lt(_: void, a: BranchBody, b: BranchBody) bool {
                if (a.cy != b.cy) return a.cy < b.cy;
                return a.end_x < b.end_x;
            }
        }.lt);
        if (bodies.items.len == 0) continue;
        const has_local_island_branch = candidateHasLocalIslandBranch(groups.items, group);
        if (has_local_island_branch) {
            lane_x = switch (group.side) {
                .left => far_x_sentinel,
                .right => -far_x_sentinel,
            };
            for (bodies.items) |body| {
                lane_x = switch (group.side) {
                    .left => @min(lane_x, body.end_x - branch_tree_bus_gap),
                    .right => @max(lane_x, body.end_x + branch_tree_bus_gap),
                };
            }
        }
        lane_x = inlineDirectLane(bodies.items) orelse lane_x;
        try renderDirectBodies(self, w, bodies.items, group, lane_x, has_feedback_return);
    }
}

// spec: render_svg - A feedback divider return and its output pin on the same hub side draw as one outside rail with a single net label
test "deferred terminals directly close one feedback loop clear of intervening ground symbols" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = RenderCtx.init(a);
    try ctx.significant_nets.put(a, "V_5V7", {});
    try ctx.significant_nets.put(a, "GND", {});

    const feedback = [_]BranchBody{.{ .end_x = 210.0, .cy = 160.0, .terminal = "V_5V7" }};
    const ground = [_]BranchBody{.{ .end_x = 260.0, .cy = 200.0, .terminal = "GND" }};
    const output = [_]BranchBody{.{ .end_x = 250.0, .cy = 280.0, .terminal = "V_5V7" }};
    var deferred: DeferredTerminals = .{};
    try deferred.runs.append(a, .{ .results = &feedback, .term_x = 180.0, .side = .left, .source_net = "FB", .source_is_feedback = true });
    try deferred.runs.append(a, .{ .results = &ground, .term_x = 180.0, .side = .left, .source_net = "GND", .source_is_feedback = false });
    try deferred.runs.append(a, .{ .results = &output, .term_x = 180.0, .side = .left, .source_net = "V_5V7", .source_is_feedback = false });

    var got: std.Io.Writer.Allocating = .init(a);
    try renderDeferredTerminals(&ctx, &got.writer, &deferred, true);

    // Ordinary terminals sit at x=180. The feedback rail is one lane farther
    // out at x=156, leaving the GND glyph at x=180 untouched between its ends.
    try testing.expect(std.mem.indexOf(u8, got.written(), "points=\"156.0,160.0 156.0,160.0 156.0,280.0 156.0,280.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, got.written(), "x1=\"180.0\" y1=\"200.0\" x2=\"180.0\" y2=\"206.0\"") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got.written(), ">V_5V7</text>"));
}

test "functional signal return draws one direct terminal instead of duplicate labels" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ctx = RenderCtx.init(allocator);
    try ctx.significant_nets.put(allocator, "LMX_RFOUTBP", {});

    const matching = [_]BranchBody{.{ .end_x = 210.0, .cy = 120.0, .terminal = "LMX_RFOUTBP" }};
    const output = [_]BranchBody{.{ .end_x = 250.0, .cy = 180.0, .terminal = "LMX_RFOUTBP.U1.19" }};
    var deferred: DeferredTerminals = .{};
    try deferred.runs.append(allocator, .{
        .results = &matching,
        .term_x = 180.0,
        .side = .left,
        .source_net = "RFOUTBM",
        .source_is_feedback = false,
    });
    try deferred.runs.append(allocator, .{
        .results = &output,
        .term_x = 180.0,
        .side = .left,
        .source_net = "LMX_RFOUTBP",
        .source_is_feedback = false,
    });

    var got: std.Io.Writer.Allocating = .init(allocator);
    try renderDeferredTerminals(&ctx, &got.writer, &deferred, true);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got.written(), ">LMX_RFOUTBP</text>"));
    try testing.expect(std.mem.indexOf(u8, got.written(), "156.0,120.0 156.0,180.0") != null);
}

// spec: render_svg - A Functional turned series return shares the destination rail's x-coordinate so VTUNE closes straight down without an outside detour
test "functional turned series return closes on its inline rail" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ctx = RenderCtx.init(allocator);
    try ctx.significant_nets.put(allocator, "LMX_VTUNE", {});

    const cpout_return = [_]BranchBody{.{
        .end_x = 210.0,
        .cy = 140.0,
        .terminal = "LMX_VTUNE",
        .inline_direct_lane = true,
    }};
    const vtune_anchor = [_]BranchBody{.{
        .end_x = 250.0,
        .cy = 180.0,
        .terminal = "LMX_VTUNE",
    }};
    var deferred: DeferredTerminals = .{};
    try deferred.runs.append(allocator, .{
        .results = &cpout_return,
        .term_x = 180.0,
        .side = .left,
        .source_net = "LMX_CPOUT",
        .source_is_feedback = false,
    });
    try deferred.runs.append(allocator, .{
        .results = &vtune_anchor,
        .term_x = 180.0,
        .side = .left,
        .source_net = "LMX_VTUNE",
        .source_is_feedback = false,
    });

    var got: std.Io.Writer.Allocating = .init(allocator);
    try renderDeferredTerminals(&ctx, &got.writer, &deferred, true);

    try testing.expect(std.mem.indexOf(u8, got.written(), "points=\"210.0,140.0 210.0,140.0 210.0,180.0 210.0,180.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, got.written(), "x1=\"250.0\" y1=\"180.0\" x2=\"210.0\" y2=\"180.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, got.written(), "156.0,140.0 156.0,180.0") == null);
}

// spec: render_svg - A Functional local direct return omits its redundant generated net label
test "functional local direct return omits its generated net label" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const instances = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "lmx2595", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "R50", .component = "res-0402", .value = "50R", .footprint = "", .symbol = "generic-res" },
    };
    const output_pins = [_]PinRef{
        .{ .ref_des = "U1", .pin = "19" },
        .{ .ref_des = "R50", .pin = "1" },
    };
    const bias_pins = [_]PinRef{.{ .ref_des = "R50", .pin = "2" }};
    const nets = [_]env_mod.Net{
        .{ .name = "LMX_RFOUTBP", .pins = &output_pins },
        .{ .name = "LO_BIAS_B", .pins = &bias_pins },
    };
    const block: env_mod.DesignBlock = .{
        .name = "local-direct-return",
        .instances = &instances,
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var ctx = RenderCtx.init(allocator);
    try ctx.setup(&block);

    const matching = [_]BranchBody{.{ .end_x = 210.0, .cy = 120.0, .terminal = "LMX_RFOUTBP" }};
    const output = [_]BranchBody{.{ .end_x = 250.0, .cy = 180.0, .terminal = "LMX_RFOUTBP.U1.19" }};
    var deferred: DeferredTerminals = .{};
    try deferred.runs.append(allocator, .{
        .results = &matching,
        .term_x = 180.0,
        .side = .left,
        .source_net = "LMX_RFOUTBM",
        .source_is_feedback = false,
    });
    try deferred.runs.append(allocator, .{
        .results = &output,
        .term_x = 180.0,
        .side = .left,
        .source_net = "LMX_RFOUTBP",
        .source_is_feedback = false,
    });

    var got: std.Io.Writer.Allocating = .init(allocator);
    try renderDeferredTerminals(&ctx, &got.writer, &deferred, true);

    try testing.expect(std.mem.indexOf(u8, got.written(), "156.0,120.0 156.0,180.0") != null);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, got.written(), ">LMX_RFOUTBP</text>"));
}

// spec: render_svg - Functional differential inputs keep their coupling parts beside the hub, turn the boundary termination vertical, and retain both port stubs
test "functional differential boundary termination stands between two labeled input stubs" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ctx = RenderCtx.init(allocator);
    try ctx.lone_pin_nets.put(allocator, "REF_P", .internal);
    try ctx.lone_pin_nets.put(allocator, "REF_N", .internal);

    const resistor: FlatInst = .{
        .ref_des = "R2",
        .component = "res-0402",
        .value = "100R",
        .symbol = "generic-res",
    };
    const source = [_]BranchBody{.{ .end_x = 210.0, .cy = 100.0, .terminal = "REF_P" }};
    const bridge = [_]BranchBody{.{
        .end_x = 148.0,
        .cy = 100.0,
        .terminal = "REF_N",
        .deferred_series = resistor,
        .deferred_start_x = 180.0,
        .deferred_source_net = "REF_P",
    }};
    const target = [_]BranchBody{.{ .end_x = 210.0, .cy = 180.0, .terminal = "REF_N" }};
    var deferred: DeferredTerminals = .{};
    try deferred.runs.append(allocator, .{
        .results = &source,
        .term_x = 160.0,
        .side = .left,
        .source_net = "LOCAL_P",
        .source_is_feedback = false,
    });
    try deferred.runs.append(allocator, .{
        .results = &bridge,
        .term_x = 128.0,
        .side = .left,
        .source_net = "LOCAL_P",
        .source_is_feedback = false,
    });
    try deferred.runs.append(allocator, .{
        .results = &target,
        .term_x = 160.0,
        .side = .left,
        .source_net = "LOCAL_N",
        .source_is_feedback = false,
    });

    var got: std.Io.Writer.Allocating = .init(allocator);
    try renderDeferredTerminals(&ctx, &got.writer, &deferred, true);

    try testing.expect(std.mem.indexOf(u8, got.written(), "transform=\"rotate(90 124.0 140.0)\"") != null);
    try testing.expect(std.mem.indexOf(u8, got.written(), ">R2 100R</text>") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got.written(), ">REF_P</text>"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got.written(), ">REF_N</text>"));
    try testing.expect(std.mem.indexOf(u8, got.written(), "x1=\"210.0\" y1=\"180.0\" x2=\"124.0\"") != null);
}

// spec: render_svg - A Functional shared-bias pull-up is drawn from its own destination pin while the outside lane carries the common bias node
test "functional shared bias resistor moves beside its destination pin" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ctx = RenderCtx.init(allocator);

    const resistor: FlatInst = .{
        .ref_des = "R50",
        .component = "res-0402",
        .value = "50R",
        .symbol = "generic-res",
    };
    const matching = [_]BranchBody{.{
        .end_x = 140.0,
        .cy = 120.0,
        .terminal = "LMX_RFOUTBP",
        .deferred_series = resistor,
        .deferred_start_x = 100.0,
        .deferred_source_net = "LO_BIAS_B",
    }};
    const output = [_]BranchBody{.{ .end_x = 150.0, .cy = 180.0, .terminal = "LMX_RFOUTBP" }};
    var deferred: DeferredTerminals = .{};
    try deferred.runs.append(allocator, .{
        .results = &matching,
        .term_x = 180.0,
        .side = .right,
        .source_net = "LMX_RFOUTBM",
        .source_is_feedback = false,
    });
    try deferred.runs.append(allocator, .{
        .results = &output,
        .term_x = 180.0,
        .side = .right,
        .source_net = "LMX_RFOUTBP",
        .source_is_feedback = false,
    });

    var got: std.Io.Writer.Allocating = .init(allocator);
    try renderDeferredTerminals(&ctx, &got.writer, &deferred, true);

    // The right-side lane is x=204 and now carries LO_BIAS_B. R50 begins at
    // the destination pin's x=150 branch on y=180, mirroring its pair mate,
    // instead of sitting on the bias-tree branch at y=120.
    try testing.expect(std.mem.indexOf(u8, got.written(), "x1=\"100.0\" y1=\"120.0\" x2=\"204.0\" y2=\"120.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, got.written(), "x1=\"150.0\" y1=\"180.0\" x2=\"158.0\" y2=\"180.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, got.written(), "x1=\"190.0\" y1=\"180.0\" x2=\"204.0\" y2=\"180.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, got.written(), "points=\"204.0,120.0 204.0,120.0 204.0,180.0 204.0,180.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, got.written(), ">R50 50R</text>") != null);
}

// spec: render_svg - The Original schematic view keeps feedback endpoints label-connected without an outside cross-pin rail
test "original deferred terminals keep feedback endpoints as separate labels" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = RenderCtx.init(a);
    try ctx.significant_nets.put(a, "V_5V7", {});

    const feedback = [_]BranchBody{.{ .end_x = 210.0, .cy = 160.0, .terminal = "V_5V7" }};
    const output = [_]BranchBody{.{ .end_x = 250.0, .cy = 280.0, .terminal = "V_5V7" }};
    var deferred: DeferredTerminals = .{};
    try deferred.runs.append(a, .{ .results = &feedback, .term_x = 180.0, .side = .left, .source_net = "FB", .source_is_feedback = true });
    try deferred.runs.append(a, .{ .results = &output, .term_x = 180.0, .side = .left, .source_net = "V_5V7", .source_is_feedback = false });

    var got: std.Io.Writer.Allocating = .init(a);
    try renderDeferredTerminals(&ctx, &got.writer, &deferred, false);

    try testing.expect(std.mem.indexOf(u8, got.written(), "156.0") == null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, got.written(), ">V_5V7</text>"));
}

// spec: render_svg - A supply pull-up and the IC's own supply pin retain labels instead of masquerading as a feedback loop
test "deferred terminals do not close a supply pull-up as feedback" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = RenderCtx.init(a);
    try ctx.significant_nets.put(a, "VDD_F", {});

    const pullup = [_]BranchBody{.{ .end_x = 210.0, .cy = 80.0, .terminal = "VDD_F" }};
    const supply = [_]BranchBody{.{ .end_x = 250.0, .cy = 280.0, .terminal = "VDD_F" }};
    var deferred: DeferredTerminals = .{};
    try deferred.runs.append(a, .{ .results = &pullup, .term_x = 180.0, .side = .left, .source_net = "PAR_C16", .source_is_feedback = false });
    try deferred.runs.append(a, .{ .results = &supply, .term_x = 180.0, .side = .left, .source_net = "VDD_F", .source_is_feedback = false });

    var got: std.Io.Writer.Allocating = .init(a);
    try renderDeferredTerminals(&ctx, &got.writer, &deferred, true);

    try testing.expect(std.mem.indexOf(u8, got.written(), "156.0") == null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, got.written(), ">VDD_F</text>"));
}

// spec: render_svg - Two feedback loops competing for one outside side fall back to net labels instead of drawing overlapping rails
test "deferred terminals do not overlap two feedback rails on one hub side" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = RenderCtx.init(a);
    try ctx.significant_nets.put(a, "OUT_A", {});
    try ctx.significant_nets.put(a, "OUT_B", {});

    const a_return = [_]BranchBody{.{ .end_x = 210.0, .cy = 100.0, .terminal = "OUT_A" }};
    const a_output = [_]BranchBody{.{ .end_x = 250.0, .cy = 180.0, .terminal = "OUT_A" }};
    const b_return = [_]BranchBody{.{ .end_x = 210.0, .cy = 220.0, .terminal = "OUT_B" }};
    const b_output = [_]BranchBody{.{ .end_x = 250.0, .cy = 300.0, .terminal = "OUT_B" }};
    var deferred: DeferredTerminals = .{};
    try deferred.runs.append(a, .{ .results = &a_return, .term_x = 180.0, .side = .left, .source_net = "FB_A", .source_is_feedback = true });
    try deferred.runs.append(a, .{ .results = &a_output, .term_x = 180.0, .side = .left, .source_net = "OUT_A", .source_is_feedback = false });
    try deferred.runs.append(a, .{ .results = &b_return, .term_x = 180.0, .side = .left, .source_net = "FB_B", .source_is_feedback = true });
    try deferred.runs.append(a, .{ .results = &b_output, .term_x = 180.0, .side = .left, .source_net = "OUT_B", .source_is_feedback = false });

    var got: std.Io.Writer.Allocating = .init(a);
    try renderDeferredTerminals(&ctx, &got.writer, &deferred, true);

    try testing.expect(std.mem.indexOf(u8, got.written(), "156.0") == null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, got.written(), ">OUT_A</text>"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, got.written(), ">OUT_B</text>"));
}

/// Render terminal labels/symbols, grouping by terminal name.
pub fn renderTerminalGroups(self: *RenderCtx, w: anytype, results: []const BranchBody, term_x: f64, side: Side) RenderError!void {
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

        if (!self.significant_nets.contains(term)) {
            i = j;
            continue;
        }

        if (group_slice.len == 1) {
            const r = group_slice[0];
            const end_x = try materializeDeferredSeries(self, w, r, side, null);
            try drawNetWire(w, end_x, r.cy, term_x, r.cy, term);
            try branch_mod.drawTerminal(self, w, term_x, r.cy, term, anchor);
        } else {
            const nearest_x = blk: {
                var nx: f64 = switch (side) {
                    .left => far_x_sentinel,
                    .right => -far_x_sentinel,
                };
                for (group_slice) |r| {
                    switch (side) {
                        .left => {
                            nx = @min(nx, r.end_x);
                        },
                        .right => {
                            nx = @max(nx, r.end_x);
                        },
                    }
                }
                break :blk nx;
            };
            const grp_bus_x = switch (side) {
                .left => nearest_x - pin_offset,
                .right => nearest_x + pin_offset,
            };

            const first_cy = group_slice[0].cy;
            const last_cy = group_slice[group_slice.len - 1].cy;

            for (group_slice) |r| {
                const end_x = try materializeDeferredSeries(self, w, r, side, null);
                try drawNetWire(w, end_x, r.cy, grp_bus_x, r.cy, term);
            }

            try drawNetWire(w, grp_bus_x, first_cy, grp_bus_x, last_cy, term);
            try drawNetWire(w, grp_bus_x, last_cy, term_x, last_cy, term);
            try branch_mod.drawTerminal(self, w, term_x, last_cy, term, anchor);
        }

        i = j;
    }
}

/// A resistor on a non-owner boundary of a shared passive island renders as a
/// local branch from that hub pin to the island net. The island's chosen owner
/// still draws the choke/bypass tree, so neither pin steals the other's load.
fn localIslandBranchTerminal(self: *RenderCtx, spoke_ref: []const u8, hub_ref: []const u8, hub_pin: []const u8) RenderError!?[]const u8 {
    const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ hub_ref, hub_pin });
    const source_net = self.pin_canonical_nets.get(key) orelse return null;
    const owner_net = self.spoke_anchor_net.get(spoke_ref) orelse return null;
    if (std.mem.eql(u8, baseNetName(owner_net), baseNetName(source_net))) return null;

    const adj = self.adjacency.get(spoke_ref) orelse return null;
    for (adj.items) |entry| switch (entry.endpoint) {
        .net => |net| {
            if (!std.mem.eql(u8, baseNetName(net), baseNetName(source_net))) {
                const terminal = try std.fmt.allocPrint(self.allocator, "{s}.local.{s}", .{ baseNetName(net), spoke_ref });
                try self.significant_nets.put(self.allocator, terminal, {});
                return terminal;
            }
        },
        .pin => {},
    };
    return null;
}

/// Get the terminal net name for a connection endpoint.
pub fn getConnTerminal(self: *RenderCtx, endpoint: Endpoint, hub_ref: []const u8, from_pin: []const u8) RenderError![]const u8 {
    switch (endpoint) {
        .net => |net| return net,
        .pin => |p| {
            if (self.spoke_set.contains(p.ref_des)) {
                if (try localIslandBranchTerminal(self, p.ref_des, hub_ref, from_pin)) |terminal| return terminal;
                var visited: std.StringHashMapUnmanaged(void) = .empty;
                try visited.put(self.allocator, p.ref_des, {});
                const result = try findSpokeChain(self, p.ref_des, .{ .pin = .{ .ref_des = hub_ref, .pin = from_pin } }, &visited);
                return result.terminal;
            } else {
                if (self.adjacency.get(p.ref_des)) |adj_list| {
                    for (adj_list.items) |ae| {
                        if (std.mem.eql(u8, ae.pin, p.pin)) {
                            switch (ae.endpoint) {
                                .net => |n| return n,
                                .pin => {},
                            }
                        }
                    }
                }
                return try std.fmt.allocPrint(self.allocator, "{s}_pin{s}", .{ p.ref_des, p.pin });
            }
        },
    }
}

/// Find spoke chain result.
pub const ChainResult = struct {
    chain: []const FlatInst,
    terminal: []const u8,
    branches: []const ctx_mod.Branch,
};

/// One passive already scheduled as part of a grouped connection walk. The
/// pin and terminal are part of the identity because the same passive island
/// can legitimately expose a local branch from another hub pin.
const PlannedSpoke = struct {
    hub_pin: []const u8,
    terminal: []const u8,
    ref_des: []const u8,
};

fn plannedSpokeContains(planned: []const PlannedSpoke, hub_pin: []const u8, terminal: []const u8, ref_des: []const u8) bool {
    for (planned) |entry| {
        if (std.mem.eql(u8, entry.hub_pin, hub_pin) and
            std.mem.eql(u8, entry.terminal, terminal) and
            std.mem.eql(u8, entry.ref_des, ref_des)) return true;
    }
    return false;
}

fn rememberPlannedSpoke(
    self: *RenderCtx,
    planned: *std.ArrayList(PlannedSpoke),
    hub_pin: []const u8,
    terminal: []const u8,
    ref_des: []const u8,
) error{OutOfMemory}!void {
    if (plannedSpokeContains(planned.items, hub_pin, terminal, ref_des)) return;
    try planned.append(self.allocator, .{ .hub_pin = hub_pin, .terminal = terminal, .ref_des = ref_des });
}

/// Reserve a passive island once before grouped-connection slot allocation.
/// The first spoke walk draws every chain and branch it discovers; later
/// adjacency entries for those same passives must not reserve empty rows that
/// extend the outer bus beyond its last visible connection.
fn reserveGroupedSpoke(
    self: *RenderCtx,
    planned: *std.ArrayList(PlannedSpoke),
    spoke_ref: []const u8,
    hub_ref: []const u8,
    hub_pin: []const u8,
    terminal: []const u8,
) error{OutOfMemory}!bool {
    if (plannedSpokeContains(planned.items, hub_pin, terminal, spoke_ref)) return false;
    try rememberPlannedSpoke(self, planned, hub_pin, terminal, spoke_ref);

    var visited: std.StringHashMapUnmanaged(void) = .empty;
    try visited.put(self.allocator, spoke_ref, {});
    const result = try findSpokeChain(self, spoke_ref, .{ .pin = .{ .ref_des = hub_ref, .pin = hub_pin } }, &visited);
    for (result.chain) |inst| try rememberPlannedSpoke(self, planned, hub_pin, terminal, inst.ref_des);
    for (result.branches) |branch| {
        for (branch.chain) |inst| try rememberPlannedSpoke(self, planned, hub_pin, terminal, inst.ref_des);
    }
    return true;
}

fn deduplicateGroupedSpokes(self: *RenderCtx, classified: *std.ArrayList(Classified), hub_ref: []const u8) error{OutOfMemory}!void {
    var retained: std.ArrayList(Classified) = .empty;
    var planned: std.ArrayList(PlannedSpoke) = .empty;
    for (classified.items) |entry| {
        const keep = switch (entry.conn.endpoint) {
            .net => true,
            .pin => |p| !self.spoke_set.contains(p.ref_des) or
                try reserveGroupedSpoke(self, &planned, p.ref_des, hub_ref, entry.conn.pin, entry.terminal),
        };
        if (keep) try retained.append(self.allocator, entry);
    }
    classified.* = retained;
}

// spec: render_svg - A parallel passive island reserves one grouped hub entry so its outer bus stops at the last visible branch
test "grouped spoke planning removes a parallel island's empty bus row" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const instances = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "L2", .component = "ind-0402", .value = "900nH", .footprint = "", .symbol = "generic-ind" },
        .{ .ref_des = "R4", .component = "res-0402", .value = "91R", .footprint = "", .symbol = "generic-res" },
        .{ .ref_des = "C5", .component = "cap-0402", .value = "100pF", .footprint = "", .symbol = "generic-cap" },
        .{ .ref_des = "FB", .component = "ferrite-0402", .value = "600R", .footprint = "", .symbol = "generic-ind" },
    };
    const amp_vdd = [_]PinRef{
        .{ .ref_des = "U1", .pin = "7" },
        .{ .ref_des = "L2", .pin = "2" },
        .{ .ref_des = "R4", .pin = "2" },
    };
    const vdd_filt = [_]PinRef{
        .{ .ref_des = "L2", .pin = "1" },
        .{ .ref_des = "R4", .pin = "1" },
        .{ .ref_des = "C5", .pin = "1" },
        .{ .ref_des = "FB", .pin = "2" },
    };
    const gnd = [_]PinRef{.{ .ref_des = "C5", .pin = "2" }};
    const vdd = [_]PinRef{.{ .ref_des = "FB", .pin = "1" }};
    const nets = [_]env_mod.Net{
        .{ .name = "AMP_VDD", .pins = &amp_vdd },
        .{ .name = "VDD_FILT", .pins = &vdd_filt },
        .{ .name = "GND", .pins = &gnd },
        .{ .name = "VDD", .pins = &vdd },
    };
    const block: env_mod.DesignBlock = .{
        .name = "parallel-vdd-island",
        .instances = &instances,
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };

    var ctx = RenderCtx.init(allocator);
    try ctx.setup(&block);
    var planned: std.ArrayList(PlannedSpoke) = .empty;
    try testing.expect(try reserveGroupedSpoke(&ctx, &planned, "L2", "U1", "7", "VDD_FILT"));
    try testing.expect(!try reserveGroupedSpoke(&ctx, &planned, "R4", "U1", "7", "VDD_FILT"));

    const group: PinGroup = .{
        .display_name = "VDD",
        .pin_numbers = "7",
        .conns = ctx.adjacency.get("U1").?.items,
    };
    var rendered: std.Io.Writer.Allocating = .init(allocator);
    try renderGroupedConnections(&ctx, &rendered.writer, "U1", group, 100.0, 300.0, .right);
    try testing.expect(std.mem.indexOf(u8, rendered.written(), "<line x1=\"110.0\"") == null);
}

/// Claim every passive contained in a resolved spoke walk. Branch members are
/// drawn as part of the first hub-pin tree that reaches their junction; if they
/// are not marked alongside the linear chain, a later pin on the same network
/// starts a second walk and emits the same physical passive again.
fn markChainPassivesRendered(self: *RenderCtx, result: ChainResult) error{OutOfMemory}!void {
    for (result.chain) |inst| try self.rendered_spokes.put(self.allocator, inst.ref_des, {});
    for (result.branches) |branch| {
        for (branch.chain) |inst| try self.rendered_spokes.put(self.allocator, inst.ref_des, {});
    }
}

/// Follow a chain of passives from a spoke, detecting branches at junctions.
pub fn findSpokeChain(self: *RenderCtx, ref_des: []const u8, came_from: Endpoint, visited: *std.StringHashMapUnmanaged(void)) error{OutOfMemory}!ChainResult {
    const adj_list = self.adjacency.get(ref_des) orelse return .{ .chain = &.{}, .terminal = "?", .branches = &.{} };

    var from_pins: std.ArrayList([]const u8) = .empty;
    for (adj_list.items) |ae| {
        if (endpointEql(ae.endpoint, came_from)) {
            try from_pins.append(self.allocator, ae.pin);
        }
    }

    var other_conns: std.ArrayList(AdjEntry) = .empty;
    for (adj_list.items) |ae| {
        var is_from_pin = false;
        for (from_pins.items) |fp| {
            if (std.mem.eql(u8, ae.pin, fp)) {
                is_from_pin = true;
                break;
            }
        }
        if (!is_from_pin) {
            try other_conns.append(self.allocator, ae);
        }
    }

    return tryChainConns(self, other_conns.items, ref_des, visited);
}

fn tryChainConns(
    self: *RenderCtx,
    conns: []const AdjEntry,
    current_ref: []const u8,
    visited: *std.StringHashMapUnmanaged(void),
) error{OutOfMemory}!ChainResult {
    if (conns.len == 0) return .{ .chain = &.{}, .terminal = "?", .branches = &.{} };

    const ae = conns[0];
    switch (ae.endpoint) {
        .net => |net| {
            // Ground is always a terminal.
            if (isGroundNet(net))
                return .{ .chain = &.{}, .terminal = net, .branches = &.{} };

            const net_pins = self.net_index.get(net) orelse return .{ .chain = &.{}, .terminal = net, .branches = &.{} };

            // A rail/bus shared across sub-blocks—or, in Functional, a net that
            // leaves this rendered circuit—is normally a terminal: do not walk
            // through it and erase its label. One exception is needed for a passive
            // that bridges two such nets but reaches no hub of its own (a
            // differential termination resistor, for example). Hang that
            // orphan spoke off the terminal as a local branch; passives already
            // attached to a hub remain terminal-side.
            const functional_external = self.render_scratch.functional_layout and self.rendersWhenAlone(net);
            if (self.shared_rail_nets.contains(net) or functional_external) {
                return sharedNetBranches(self, net, net_pins.items, current_ref, visited);
            }

            var has_hub = false;
            for (net_pins.items) |np| {
                if (!std.mem.eql(u8, np.ref_des, current_ref) and !self.spoke_set.contains(np.ref_des)) {
                    has_hub = true;
                    break;
                }
            }
            if (has_hub) return .{ .chain = &.{}, .terminal = net, .branches = &.{} };

            var other_spokes: std.ArrayList(PinRef) = .empty;
            for (net_pins.items) |np| {
                if (!isWalkableJunctionSpoke(self, np, current_ref, visited)) continue;
                try other_spokes.append(self.allocator, np);
            }

            if (other_spokes.items.len == 0) {
                return .{ .chain = &.{}, .terminal = net, .branches = &.{} };
            } else if (other_spokes.items.len == 1) {
                const next_ref = other_spokes.items[0].ref_des;
                const next_inst = self.inst_map.get(next_ref) orelse return .{ .chain = &.{}, .terminal = net, .branches = &.{} };
                try visited.put(self.allocator, next_ref, {});
                const rest = try findSpokeChain(self, next_ref, .{ .net = net }, visited);
                var chain: std.ArrayList(FlatInst) = .empty;
                try chain.append(self.allocator, next_inst);
                for (rest.chain) |c| try chain.append(self.allocator, c);
                return .{
                    .chain = try chain.toOwnedSlice(self.allocator),
                    .terminal = rest.terminal,
                    .branches = rest.branches,
                };
            } else {
                var branches: std.ArrayList(ctx_mod.Branch) = .empty;
                for (other_spokes.items) |sp| {
                    if (visited.contains(sp.ref_des)) continue;
                    const sib_inst = self.inst_map.get(sp.ref_des) orelse continue;
                    try visited.put(self.allocator, sp.ref_des, {});
                    const sub = try findSpokeChain(self, sp.ref_des, .{ .net = net }, visited);
                    var chain: std.ArrayList(FlatInst) = .empty;
                    try chain.append(self.allocator, sib_inst);
                    for (sub.chain) |c| try chain.append(self.allocator, c);
                    try branches.append(self.allocator, .{
                        .chain = try chain.toOwnedSlice(self.allocator),
                        .terminal = sub.terminal,
                    });
                }
                return .{
                    .chain = &.{},
                    .terminal = net,
                    .branches = try branches.toOwnedSlice(self.allocator),
                };
            }
        },
        .pin => |p| {
            if (self.spoke_set.contains(p.ref_des)) {
                if (visited.contains(p.ref_des)) {
                    if (conns.len > 1) {
                        return tryChainConns(self, conns[1..], current_ref, visited);
                    }
                    return .{ .chain = &.{}, .terminal = "?", .branches = &.{} };
                }
                const next_inst = self.inst_map.get(p.ref_des) orelse return .{ .chain = &.{}, .terminal = "?", .branches = &.{} };
                try visited.put(self.allocator, p.ref_des, {});
                const rest = try findSpokeChain(self, p.ref_des, .{ .pin = .{ .ref_des = current_ref, .pin = ae.pin } }, visited);
                var chain: std.ArrayList(FlatInst) = .empty;
                try chain.append(self.allocator, next_inst);
                for (rest.chain) |c| try chain.append(self.allocator, c);
                return .{
                    .chain = try chain.toOwnedSlice(self.allocator),
                    .terminal = rest.terminal,
                    .branches = rest.branches,
                };
            } else {
                if (self.adjacency.get(p.ref_des)) |adj_list| {
                    for (adj_list.items) |adj_ae| {
                        if (std.mem.eql(u8, adj_ae.pin, p.pin)) {
                            switch (adj_ae.endpoint) {
                                .net => |n| return .{ .chain = &.{}, .terminal = n, .branches = &.{} },
                                .pin => {},
                            }
                        }
                    }
                }
                return .{ .chain = &.{}, .terminal = try std.fmt.allocPrint(self.allocator, "{s}_pin{s}", .{ p.ref_des, p.pin }), .branches = &.{} };
            }
        },
    }
}

fn isWalkableJunctionSpoke(self: *RenderCtx, pin: PinRef, current_ref: []const u8, visited: *const std.StringHashMapUnmanaged(void)) bool {
    return !std.mem.eql(u8, pin.ref_des, current_ref) and
        self.spoke_set.contains(pin.ref_des) and
        !visited.contains(pin.ref_des) and
        !spokeHasNonOwnerHubConnection(self, pin.ref_des);
}

fn spokeHasNonOwnerHubConnection(self: *RenderCtx, spoke_ref: []const u8) bool {
    const owner = self.spoke_anchor_net.get(spoke_ref) orelse return false;
    const adj = self.adjacency.get(spoke_ref) orelse return false;
    for (adj.items) |entry| switch (entry.endpoint) {
        .pin => |pin| {
            if (self.spoke_set.contains(pin.ref_des)) continue;
            const key = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ pin.ref_des, pin.pin }) catch continue;
            const hub_net = self.pin_canonical_nets.get(key) orelse continue;
            if (!std.mem.eql(u8, baseNetName(owner), baseNetName(hub_net))) return true;
        },
        .net => {},
    };
    return false;
}

fn sharedNetBranches(
    self: *RenderCtx,
    net: []const u8,
    net_pins: []const PinRef,
    current_ref: []const u8,
    visited: *std.StringHashMapUnmanaged(void),
) error{OutOfMemory}!ChainResult {
    var branches: std.ArrayList(ctx_mod.Branch) = .empty;
    for (net_pins) |sp| {
        if (std.mem.eql(u8, sp.ref_des, current_ref)) continue;
        if (!self.spoke_set.contains(sp.ref_des)) continue;
        if (self.rendered_spokes.contains(sp.ref_des)) continue;
        if (visited.contains(sp.ref_des)) continue;
        if (spokeOwnedAwayFromNet(self, sp.ref_des, net)) continue;
        if (spokeHasHubConnection(self, sp.ref_des)) continue;
        if (!sameRenderSection(self, current_ref, sp.ref_des)) continue;

        const inst = self.inst_map.get(sp.ref_des) orelse continue;
        try visited.put(self.allocator, sp.ref_des, {});
        const sub = try findSpokeChain(self, sp.ref_des, .{ .net = net }, visited);
        var chain: std.ArrayList(FlatInst) = .empty;
        try chain.append(self.allocator, inst);
        for (sub.chain) |c| try chain.append(self.allocator, c);
        try branches.append(self.allocator, .{
            .chain = try chain.toOwnedSlice(self.allocator),
            .terminal = sub.terminal,
        });
    }
    return .{
        .chain = &.{},
        .terminal = net,
        .branches = try branches.toOwnedSlice(self.allocator),
    };
}

fn spokeOwnedAwayFromNet(self: *const RenderCtx, spoke_ref: []const u8, net: []const u8) bool {
    const owner = self.spoke_anchor_net.get(spoke_ref) orelse return false;
    return !std.mem.eql(u8, baseNetName(owner), baseNetName(net));
}

fn spokeHasHubConnection(self: *RenderCtx, spoke_ref: []const u8) bool {
    const adj = self.adjacency.get(spoke_ref) orelse return false;
    for (adj.items) |entry| switch (entry.endpoint) {
        .pin => |p| if (!self.spoke_set.contains(p.ref_des)) return true,
        .net => {},
    };
    return false;
}

fn sameRenderSection(self: *RenderCtx, a: []const u8, b: []const u8) bool {
    const sa = self.section_map.get(a);
    const sb = self.section_map.get(b);
    if (sa == null or sb == null) return sa == null and sb == null;
    return sa.? == sb.?;
}

test "findSpokeChain keeps a local terminator between two shared nets" {
    const testing = std.testing;
    // C1/C2 attach to U1. R1 is a local differential terminator between the
    // two shared boundary nets and therefore has no direct hub attachment.
    // The shared-net stop must retain R1 as a branch without walking into C2.
    const insts = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "C1", .component = "cap", .value = "100nF", .footprint = "", .symbol = "" },
        .{ .ref_des = "R1", .component = "res", .value = "100R", .footprint = "", .symbol = "" },
        .{ .ref_des = "C2", .component = "cap", .value = "100nF", .footprint = "", .symbol = "" },
    };
    const local_p = [_]PinRef{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const ref_p = [_]PinRef{ .{ .ref_des = "C1", .pin = "2" }, .{ .ref_des = "R1", .pin = "1" } };
    const ref_n = [_]PinRef{ .{ .ref_des = "R1", .pin = "2" }, .{ .ref_des = "C2", .pin = "1" } };
    const local_n = [_]PinRef{ .{ .ref_des = "C2", .pin = "2" }, .{ .ref_des = "U1", .pin = "2" } };
    const nets = [_]env_mod.Net{
        .{ .name = "LOCAL_P", .pins = &local_p },
        .{ .name = "REF_P", .pins = &ref_p },
        .{ .name = "REF_N", .pins = &ref_n },
        .{ .name = "LOCAL_N", .pins = &local_n },
    };
    const block: env_mod.DesignBlock = .{
        .name = "shared-termination-test",
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
    try ctx.setup(&block);
    try ctx.shared_rail_nets.put(ctx.allocator, "REF_P", {});
    try ctx.shared_rail_nets.put(ctx.allocator, "REF_N", {});

    var visited: std.StringHashMapUnmanaged(void) = .empty;
    try visited.put(ctx.allocator, "C1", {});
    const result = try findSpokeChain(&ctx, "C1", .{ .pin = .{ .ref_des = "U1", .pin = "1" } }, &visited);

    try testing.expectEqualStrings("REF_P", result.terminal);
    try testing.expectEqual(@as(usize, 1), result.branches.len);
    try testing.expectEqual(@as(usize, 1), result.branches[0].chain.len);
    try testing.expectEqualStrings("R1", result.branches[0].chain[0].ref_des);
    try testing.expectEqualStrings("REF_N", result.branches[0].terminal);

    // Once the P-side tree owns R1, walking from the N-side coupling cap must
    // terminate at REF_N without drawing the same terminator a second time.
    try ctx.rendered_spokes.put(ctx.allocator, "R1", {});
    visited = .empty;
    try visited.put(ctx.allocator, "C2", {});
    const reverse = try findSpokeChain(&ctx, "C2", .{ .pin = .{ .ref_des = "U1", .pin = "2" } }, &visited);
    try testing.expectEqualStrings("REF_N", reverse.terminal);
    try testing.expectEqual(@as(usize, 0), reverse.branches.len);

    // A standalone module has the same topology but classifies REF_P/REF_N as
    // externally rendered ports rather than cross-sub-block shared rails.
    ctx.shared_rail_nets.clearRetainingCapacity();
    ctx.rendered_spokes.clearRetainingCapacity();
    ctx.render_scratch.functional_layout = true;
    try ctx.lone_pin_nets.put(ctx.allocator, "REF_P", .internal);
    try ctx.lone_pin_nets.put(ctx.allocator, "REF_N", .internal);
    visited = .empty;
    try visited.put(ctx.allocator, "C1", {});
    const external = try findSpokeChain(&ctx, "C1", .{ .pin = .{ .ref_des = "U1", .pin = "1" } }, &visited);
    try testing.expectEqualStrings("REF_P", external.terminal);
    try testing.expectEqual(@as(usize, 1), external.branches.len);
    try testing.expectEqualStrings("R1", external.branches[0].chain[0].ref_des);
}

const NetBodyRender = struct {
    stub_x: f64,
    stub_y: f64,
    cy: f64,
    side: Side,
    net_name: []const u8,
};

fn renderNetBody(self: *RenderCtx, w: anytype, render: NetBodyRender) RenderError!f64 {
    if (self.render_scratch.functional_layout and
        self.render_scratch.functional_inline_nets.contains(baseNetName(render.net_name)))
    {
        return render.stub_x;
    }
    const end_x: f64 = switch (render.side) {
        .left => render.stub_x - pin_offset,
        .right => render.stub_x + pin_offset,
    };
    try drawNetWire(w, render.stub_x, render.stub_y, end_x, render.cy, render.net_name);
    return end_x;
}

/// Render the body of a connection. Returns end_x position.
pub fn renderConnBody(
    self: *RenderCtx,
    w: anytype,
    endpoint: Endpoint,
    hub_ref: []const u8,
    from_pin: []const u8,
    stub_x: f64,
    stub_y: f64,
    cy: f64,
    side: Side,
    net_name: []const u8,
) RenderError!f64 {
    switch (endpoint) {
        .net => return renderNetBody(self, w, .{
            .stub_x = stub_x,
            .stub_y = stub_y,
            .cy = cy,
            .side = side,
            .net_name = net_name,
        }),
        .pin => |p| {
            if (!self.spoke_set.contains(p.ref_des)) {
                const end_x: f64 = switch (side) {
                    .left => stub_x - spoke_len - pin_offset,
                    .right => stub_x + spoke_len + pin_offset,
                };
                try drawNetWire(w, stub_x, stub_y, end_x, cy, net_name);
                return end_x;
            }

            if (self.rendered_spokes.contains(p.ref_des)) {
                return stub_x;
            }

            const inst = self.inst_map.get(p.ref_des) orelse return stub_x;
            try self.rendered_spokes.put(self.allocator, p.ref_des, {});

            if (try localIslandBranchTerminal(self, p.ref_des, hub_ref, from_pin) != null) {
                switch (side) {
                    .left => {
                        try drawNetWire(w, stub_x, stub_y, stub_x - pin_offset, cy, net_name);
                        return branch_mod.drawPassiveChainLeft(self, w, stub_x - pin_offset, cy, &.{inst});
                    },
                    .right => {
                        try drawNetWire(w, stub_x, stub_y, stub_x + pin_offset, cy, net_name);
                        return branch_mod.drawPassiveChainRight(self, w, stub_x + pin_offset, cy, &.{inst});
                    },
                }
            }

            var visited: std.StringHashMapUnmanaged(void) = .empty;
            try visited.put(self.allocator, p.ref_des, {});
            const chain_result = try findSpokeChain(self, p.ref_des, .{ .pin = .{ .ref_des = hub_ref, .pin = from_pin } }, &visited);

            try markChainPassivesRendered(self, chain_result);

            var all_spokes: std.ArrayList(FlatInst) = .empty;
            try all_spokes.append(self.allocator, inst);
            for (chain_result.chain) |c| try all_spokes.append(self.allocator, c);

            if (self.render_scratch.functional_series_target_y) |target_y| {
                const can_turn = all_spokes.items.len == 1 and
                    chain_result.branches.len == 0 and
                    canTurnVertical(all_spokes.items[0]);
                if (can_turn) {
                    try self.render_scratch.functional_inline_nets.put(
                        self.allocator,
                        baseNetName(chain_result.terminal),
                        {},
                    );
                    const vertical_endpoint = try drawVerticalSeriesPassive(w, .{
                        .inst = all_spokes.items[0],
                        .stub_x = stub_x,
                        .stub_y = stub_y,
                        .cy = cy,
                        .side = side,
                        .source_net = net_name,
                        .target_y = target_y,
                    });
                    self.render_scratch.rendered_connection_end_y = vertical_endpoint.y;
                    return vertical_endpoint.x;
                }
            }

            switch (side) {
                .left => {
                    try drawNetWire(w, stub_x, stub_y, stub_x - pin_offset, cy, net_name);
                    const chain_end_x = try branch_mod.drawPassiveChainLeft(self, w, stub_x - pin_offset, cy, all_spokes.items);
                    if (chain_result.branches.len > 0) {
                        try branch_mod.drawBranchTreeLeft(self, w, chain_end_x, cy, chain_result.branches, chain_result.terminal);
                    }
                    return chain_end_x;
                },
                .right => {
                    try drawNetWire(w, stub_x, stub_y, stub_x + pin_offset, cy, net_name);
                    const chain_end_x = try branch_mod.drawPassiveChainRight(self, w, stub_x + pin_offset, cy, all_spokes.items);
                    if (chain_result.branches.len > 0) {
                        try branch_mod.drawBranchTreeRight(self, w, chain_end_x, cy, chain_result.branches, chain_result.terminal);
                    }
                    return chain_end_x;
                },
            }
        },
    }
}

fn canTurnVertical(inst: FlatInst) bool {
    return std.mem.eql(u8, inst.symbol, "generic-res") or
        std.mem.eql(u8, inst.symbol, "generic-ind");
}

const VerticalSeriesRender = struct {
    inst: FlatInst,
    stub_x: f64,
    stub_y: f64,
    cy: f64,
    side: Side,
    source_net: []const u8,
    target_y: f64,
};

const VerticalEndpoint = struct { x: f64, y: f64 };

fn drawVerticalSeriesPassive(w: anytype, render: VerticalSeriesRender) RenderError!VerticalEndpoint {
    const component_x = render.stub_x;
    const end_y = render.cy + (if (render.target_y > render.cy) passive_bw else -passive_bw);

    try drawNetWire(w, render.stub_x, render.stub_y, component_x, render.cy, render.source_net);
    try drawVerticalPassive(w, render.inst, component_x, render.cy, end_y, render.side);
    return .{ .x = component_x, .y = end_y };
}

fn drawVerticalPassive(w: anytype, inst: FlatInst, cx: f64, start_y: f64, end_y: f64, side: Side) RenderError!void {
    const cy = (start_y + end_y) / half_divisor;
    const top = @min(start_y, end_y);
    const label_x = switch (side) {
        .left => cx - vertical_label_gap,
        .right => cx + vertical_label_gap,
    };
    const anchor: []const u8 = switch (side) {
        .left => "end",
        .right => "start",
    };
    const hit_x = switch (side) {
        .left => cx - passive_bh / half_divisor,
        .right => cx - vertical_hit_width + passive_bh / half_divisor,
    };

    try w.writeAll("<g data-ref=\"");
    try escape.writeXml(w, shortRef(inst.ref_des));
    try w.print(
        \\" data-passive-count="{d}" class="component" style="cursor:pointer">
        \\<rect x="{d:.1}" y="{d:.1}" width="{d:.1}" height="{d:.1}" fill="transparent" class="hit-area"/>
        \\<g transform="rotate(90 {d:.1} {d:.1})">
        \\
    , .{
        passiveRenderCount(inst),
        hit_x,
        top - vertical_hit_pad,
        vertical_hit_width,
        passive_bw + vertical_hit_pad * half_divisor,
        cx,
        cy,
    });
    try drawSymbolShape(w, cx - passive_bw / half_divisor, passive_bw, cx, cy, inst);
    try w.writeAll("</g>\n");
    try w.print(
        \\<text x="{d:.1}" y="{d:.1}" text-anchor="{s}" font-size="9" fill="#888">
    , .{ label_x, cy + vertical_label_baseline, anchor });
    try escape.writeXml(w, shortRef(inst.ref_des));
    try w.writeAll(" ");
    try escape.writeXml(w, formatShort(inst));
    try w.writeAll("</text>\n</g>\n");
    try writeDebugPin(w, cx, start_y);
    try writeDebugPin(w, cx, end_y);
}

// spec: render_svg - A hub pin whose connections all filter away draws the no-connect glyph only when every net it reaches is a single-pin dead end
test "a fully-filtered group on a single-pin net draws the no-connect glyph" {
    const testing = std.testing;
    // U1.1 sits alone on net SPARE — a real, significant net (it carries a hub
    // pin), but with no second pin and no port declaration, so the
    // same-net-as-this-pin significance test drops its one connection. The group
    // then filters to zero and used to `return` before drawing anything: no
    // wire, no label, and no glyph either (that path only fired for an already
    // EMPTY group). A dropped connection on a genuine dead-end net must read as
    // an explicit no-connect.
    const insts = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .symbol = "" },
    };
    const spare_pins = [_]PinRef{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]env_mod.Net{.{ .name = "SPARE", .pins = &spare_pins }};
    const block: env_mod.DesignBlock = .{
        .name = "nc-fallback-test",
        .instances = &insts,
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = RenderCtx.init(a);
    try ctx.setup(&block);

    const conns = ctx.adjacency.get("U1").?.items;
    try testing.expectEqual(@as(usize, 1), conns.len);
    const group: PinGroup = .{ .display_name = "SPARE", .pin_numbers = "1", .conns = conns };

    const stub_x: f64 = 100.0;
    const py: f64 = 50.0;
    var got: std.Io.Writer.Allocating = .init(a);
    try renderGroupedConnections(&ctx, &got.writer, "U1", group, stub_x, py, .left);

    // Byte-identical to the glyph the zero-connection path draws for the same
    // stub — same symbol, same placement, nothing else emitted.
    var want: std.Io.Writer.Allocating = .init(a);
    try drawNcSymbol(&want.writer, ncX(stub_x, .left), py);
    try testing.expectEqualStrings(want.written(), got.written());
}

/// The stub the no-connect regression tests render at.
const probe_stub_x: f64 = 100.0;
const probe_stub_y: f64 = 50.0;

/// Render `hub_ref`'s connections on `pins` (all of them when `pins` is empty)
/// with `rendered_spokes` still empty — the state the FIRST group on a sheet
/// sees — and return whether a no-connect glyph came out.
fn probeNcGlyph(
    a: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    hub_ref: []const u8,
    pins: []const []const u8,
) !bool {
    var ctx = RenderCtx.init(a);
    try ctx.setup(block);
    var conns: std.ArrayList(AdjEntry) = .empty;
    for (ctx.adjacency.get(hub_ref).?.items) |ae| {
        if (pins.len == 0) {
            try conns.append(a, ae);
            continue;
        }
        for (pins) |p| {
            if (std.mem.eql(u8, ae.pin, p)) try conns.append(a, ae);
        }
    }
    if (conns.items.len == 0) return error.NoConnectionsToProbe;
    const group: PinGroup = .{ .display_name = "", .pin_numbers = "", .conns = conns.items };
    var got: std.Io.Writer.Allocating = .init(a);
    try renderGroupedConnections(&ctx, &got.writer, hub_ref, group, probe_stub_x, probe_stub_y, .left);
    var glyph: std.Io.Writer.Allocating = .init(a);
    try drawNcSymbol(&glyph.writer, ncX(probe_stub_x, .left), probe_stub_y);
    return std.mem.indexOf(u8, got.written(), glyph.written()) != null;
}

// spec: render_svg - A ground pad on a multi-pin rail draws no no-connect glyph when its group renders before any of the rail's spokes
test "a ground pad renders before its rail's spokes and draws no glyph" {
    const testing = std.testing;
    // The tpsm84338 module-page shape: the only hub on the page is the IC, so
    // its GND group is the FIRST thing rendered and `rendered_spokes` is still
    // empty. Every `should_show` branch then fails — the rail's other pins are
    // either this hub itself or not-yet-drawn spokes — so the one GND connection
    // filters away. The old gate read that as a no-connect and stamped a glyph on
    // a grounded pad, while the same page drew GND connected further down.
    const insts = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "C1", .component = "cap-0402", .value = "100nF", .footprint = "", .symbol = "" },
    };
    const gnd_pins = [_]PinRef{
        .{ .ref_des = "U1", .pin = "3" },
        .{ .ref_des = "C1", .pin = "2" },
    };
    const vdd_pins = [_]PinRef{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "C1", .pin = "1" },
    };
    const nets = [_]env_mod.Net{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "VDD", .pins = &vdd_pins },
    };
    const block: env_mod.DesignBlock = .{
        .name = "ground-order-test",
        .instances = &insts,
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Pin 3 only: the GND group on its own, rendered first.
    try testing.expect(!(try probeNcGlyph(a, &block, "U1", &.{"3"})));
}

// spec: render_svg - Two pads of one hub tied to each other draw no no-connect glyph
test "a tie between two pads of the same hub draws no glyph on either" {
    const testing = std.testing;
    // The dut-vref op-amp-follower shape: BUF_SP = {U2.13, U2.14}, an output
    // strapped back to its own inverting input. The net has no spoke and no hub
    // other than U2 itself, so every `should_show` branch fails for BOTH pins and
    // both groups filter to zero — the old gate drew a no-connect glyph on top of
    // the tie line it had just drawn.
    const insts = [_]env_mod.Instance{
        .{ .ref_des = "U2", .component = "opamp", .value = "", .footprint = "", .symbol = "" },
    };
    const tie_pins = [_]PinRef{
        .{ .ref_des = "U2", .pin = "13" },
        .{ .ref_des = "U2", .pin = "14" },
    };
    const nets = [_]env_mod.Net{.{ .name = "BUF_SP", .pins = &tie_pins }};
    const block: env_mod.DesignBlock = .{
        .name = "same-hub-tie-test",
        .instances = &insts,
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Either pin alone, and the two merged into one group: no glyph anywhere.
    try testing.expect(!(try probeNcGlyph(a, &block, "U2", &.{"13"})));
    try testing.expect(!(try probeNcGlyph(a, &block, "U2", &.{"14"})));
    try testing.expect(!(try probeNcGlyph(a, &block, "U2", &.{})));
}
