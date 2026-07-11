//! Build the diagram graph from a design: one node per visible section + one
//! per unattached sub-block, then inter-block edges derived from the *unified*
//! netlist (flattened across sub-blocks and merged on net-ties via the same
//! machinery the KiCad export uses). Each net is classified into a `NetClass`
//! and routed to the matching view; GND is dropped; differential pairs and
//! parallel nets between the same two blocks collapse into one edge.

const std = @import("std");
const env_mod = @import("../eval/env.zig");
const rb = @import("../render_block_types.zig");
const review = @import("../review.zig");
const netlist = @import("../export_kicad_netlist.zig");
const export_kicad = @import("../export_kicad.zig");
const types = @import("types.zig");
const classify = @import("classify.zig");
const membership = @import("membership.zig");
const layout_status = @import("../layout_status.zig");
const numeric = @import("../numeric.zig");
const DesignBlock = env_mod.DesignBlock;
const Section = env_mod.Section;
const SubBlock = env_mod.SubBlock;
const Allocator = std.mem.Allocator;
const Node = types.Node;
const Edge = types.Edge;
const RailEnd = types.RailEnd;
const ClassId = types.ClassId;
const Graph = types.Graph;

/// Build the full graph. Caller owns the result and must call `Graph.deinit`.
pub fn collectGraph(
    allocator: Allocator,
    block: *const DesignBlock,
    sub_attachments: []const ?usize,
    /// Project root, for reading each sub-module's `.layouts.json` to derive the
    /// `layout` maturity stage. Empty ⇒ no starred-layout lookup (chips cap at
    /// the `schematic` stage), the right degradation for the static export.
    project_dir: []const u8,
) Allocator.Error!Graph {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const scratch = arena_state.allocator();

    const sub_port_to_net = try buildSubPortToNet(scratch, block);

    // Diagram-local attachments: a power-*producer* sub-block (a buck/LDO/
    // regulator) must never fold into a section that merely consumes its rail
    // — otherwise it vanishes as a producer node and a consumer gets mis-elected
    // as the rail's driver. So un-adopt power sub-blocks for the graph only; the
    // schematic-card adoption (render_html) is unaffected.
    //
    // Likewise un-adopt a sub-block hosted by a `(diagram hidden)` concept-
    // section: that section has no diagram node to fold into, so the sub-block
    // must keep its own chip (which `applyHiddenSectionText` then lends the
    // section's description + card anchor). Without this it would vanish from
    // the diagram entirely.
    const dg_attach = try scratch.dupe(?usize, sub_attachments);
    for (block.sub_blocks, 0..) |sb, i| {
        if (i >= dg_attach.len or dg_attach[i] == null) continue;
        if (isPowerSubBlock(sb)) {
            dg_attach[i] = null;
            continue;
        }
        const sec_idx = dg_attach[i].?;
        if (sec_idx < block.sections.len and block.sections[sec_idx].diagram_hidden) dg_attach[i] = null;
    }

    var nodes: std.ArrayList(Node) = .empty;
    errdefer {
        for (nodes.items) |n| freeNode(allocator, n);
        nodes.deinit(allocator);
    }

    const sec_node = try allocator.alloc(?u32, block.sections.len);
    defer allocator.free(sec_node);
    @memset(sec_node, null);
    const sub_node = try allocator.alloc(?u32, block.sub_blocks.len);
    defer allocator.free(sub_node);
    @memset(sub_node, null);

    // Reverse of dg_attach: section index → adopted sub-block index.
    const sec_to_sub = try allocator.alloc(?usize, block.sections.len);
    defer allocator.free(sec_to_sub);
    @memset(sec_to_sub, null);
    for (dg_attach, 0..) |maybe_sec, sb_idx| {
        if (maybe_sec) |sec_idx| if (sec_idx < sec_to_sub.len) {
            sec_to_sub[sec_idx] = sb_idx;
        };
    }

    try buildSectionNodes(allocator, scratch, block, &sub_port_to_net, sec_to_sub, &nodes, sec_node, project_dir);
    try buildSubBlockNodes(allocator, scratch, block, &sub_port_to_net, dg_attach, &nodes, sub_node, project_dir);

    // Placeholder `(stub …)` parts: one node each, categorised by the stub's
    // declared category. Record ref-des → node so the netlist (built from the
    // stub's signals) resolves edges to it below.
    const stub_node = try allocator.alloc(?u32, block.parts.len);
    defer allocator.free(stub_node);
    @memset(stub_node, null);
    try buildStubNodes(allocator, block, &nodes, stub_node);

    var mem = try membership.build(allocator, block, sec_node, sub_node, dg_attach);
    // Register the cleanup *before* the put loop — an OOM in `put` would otherwise
    // leak both of mem's hash maps (the defer wasn't yet registered).
    defer mem.deinit(allocator);
    for (block.parts, 0..) |p, i| {
        if (stub_node[i]) |nid| try mem.ref_to_node.put(allocator, p.ref_des, nid);
    }
    const registry = try classify.buildRegistry(allocator, block);
    errdefer allocator.free(registry);
    var port_map = try classify.buildPortClassMap(allocator, block, registry);
    defer port_map.deinit(allocator);

    var producer_by_net: std.StringHashMapUnmanaged(u32) = .empty;
    for (nodes.items, 0..) |n, i| {
        for (n.outputs) |out| try producer_by_net.put(scratch, out.net, @intCast(i));
    }

    const flat = try buildFlatNets(scratch, block);

    var edge_list: std.ArrayList(Edge) = .empty;
    errdefer {
        for (edge_list.items) |e| allocator.free(e.label);
        edge_list.deinit(allocator);
    }
    try deriveEdges(allocator, scratch, flat, &mem, &port_map, &producer_by_net, nodes.items, &edge_list);
    // Board-edge antennas / EMVS cells: synthesise an endpoint node + edge for
    // each RF net that reaches only one on-board block. Appends to both lists.
    try antennaPass(allocator, scratch, block, flat, &mem, &port_map, &nodes, &edge_list);
    // On-board crystals feeding their block — makes the Clocks view useful on
    // MCU boards whose oscillator is sealed inside a module.
    try crystalPass(allocator, scratch, block, &mem, &nodes, &edge_list);
    try assignRails(allocator, scratch, flat, &mem, &port_map, nodes.items);
    // A `(diagram hidden)` concept-section that names its representative chip via
    // `(hosts …)` lends that chip its rich description + card anchor — otherwise
    // the authored prose is orphaned when the section is suppressed.
    try applyHiddenSectionText(allocator, block, nodes.items);

    // Take the node slice first, then the edge slice. If the second `toOwnedSlice`
    // OOMs, the `nodes` errdefer no longer covers the transferred slice (the list
    // is now empty), so free it explicitly here.
    const node_slice = try nodes.toOwnedSlice(allocator);
    errdefer {
        for (node_slice) |n| freeNode(allocator, n);
        allocator.free(node_slice);
    }
    const edge_slice = try edge_list.toOwnedSlice(allocator);
    return .{ .nodes = node_slice, .edges = edge_slice, .classes = registry, .layout = block.layout };
}

const RailCount = struct { v: f64, c: u32 };

/// Record, for each block, the supply rails it touches: `power_rail` is the rail
/// powering the most pins (ties → highest), and `rails` is the full ascending
/// set. Counted from the flattened netlist (every pin), not the collapsed edge
/// list — so a dual-rail part's secondary rail and a folded producer's rail are
/// both seen. The power view uses `power_rail` to pick a band and `rails` to
/// place a dual-rail part in an overlap.
fn assignRails(
    allocator: Allocator,
    scratch: Allocator,
    flat: []const export_kicad.FlatNet,
    mem: *const membership.Membership,
    port_map: *const classify.PortClassMap,
    nodes: []Node,
) Allocator.Error!void {
    const Key = struct { node: u32, vb: i64 };
    var counts: std.AutoHashMapUnmanaged(Key, u32) = .empty;
    for (flat) |net| {
        const clean = cleanNetName(net.name);
        if (classify.netClass(clean, port_map) != types.class_power) continue;
        const v = railVoltageAny(nodes, clean) orelse voltageFromName(clean) orelse continue;
        const vb: i64 = numeric.checkedInt(i64, @round(v * 100)) orelse 0;
        for (net.pins) |p| {
            const nid = mem.resolve(p.ref_des) orelse continue;
            const gop = try counts.getOrPut(scratch, .{ .node = nid, .vb = vb });
            gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) + 1;
        }
    }
    // Bucket rail counts per node.
    const per_node = try scratch.alloc(std.ArrayList(RailCount), nodes.len);
    for (per_node) |*l| l.* = .empty;
    var it = counts.iterator();
    while (it.next()) |e| {
        const v = @as(f64, @floatFromInt(e.key_ptr.vb)) / 100;
        try per_node[e.key_ptr.node].append(scratch, .{ .v = v, .c = e.value_ptr.* });
    }
    for (per_node, 0..) |*list, i| {
        if (list.items.len == 0) continue;
        std.mem.sort(RailCount, list.items, {}, cmpRailVolt);
        const rails = try allocator.alloc(f64, list.items.len);
        var best_c: u32 = 0;
        for (list.items, 0..) |rc, j| {
            rails[j] = rc.v;
            if (rc.c > best_c or (rc.c == best_c and rc.v > nodes[i].power_rail)) {
                best_c = rc.c;
                nodes[i].power_rail = rc.v;
            }
        }
        nodes[i].rails = rails;
    }
}

fn cmpRailVolt(_: void, a: RailCount, b: RailCount) bool {
    return a.v < b.v;
}

// ── node construction ──────────────────────────────────────────────────

fn buildSectionNodes(
    allocator: Allocator,
    scratch: Allocator,
    block: *const DesignBlock,
    sub_port_to_net: *const SubPortMap,
    sec_to_sub: []const ?usize,
    nodes: *std.ArrayList(Node),
    sec_node: []?u32,
    project_dir: []const u8,
) Allocator.Error!void {
    for (block.sections, 0..) |sec, sec_idx| {
        if (sec.diagram_hidden) continue;
        var input_buf: std.ArrayList(RailEnd) = .empty;
        var output_buf: std.ArrayList(RailEnd) = .empty;
        try collectSectionRails(scratch, sec, &input_buf, &output_buf);
        if (sec_to_sub[sec_idx]) |sb_idx| {
            try collectSubBlockRails(scratch, block.sub_blocks[sb_idx], sub_port_to_net, &input_buf, &output_buf);
        }
        const mp = try mainParts(allocator, scratch, sec.instances);
        try nodes.append(allocator, .{
            .label = sec.name,
            .subtitle = sec.description,
            .category = rb.classifySection(sec),
            .slug = try review.slugify(allocator, sec.name),
            .key = sec.name,
            .inputs = try dupeRails(allocator, input_buf.items),
            .outputs = try dupeRails(allocator, output_buf.items),
            .parts = mp.tokens,
            .maturity = sectionMaturity(scratch, project_dir, block, sec, sec_to_sub[sec_idx]),
        });
        sec_node[sec_idx] = @intCast(nodes.items.len - 1);
    }
}

fn buildSubBlockNodes(
    allocator: Allocator,
    scratch: Allocator,
    block: *const DesignBlock,
    sub_port_to_net: *const SubPortMap,
    sub_attachments: []const ?usize,
    nodes: *std.ArrayList(Node),
    sub_node: []?u32,
    project_dir: []const u8,
) Allocator.Error!void {
    for (block.sub_blocks, 0..) |sb, sb_idx| {
        if (sb_idx < sub_attachments.len and sub_attachments[sb_idx] != null) continue;
        var input_buf: std.ArrayList(RailEnd) = .empty;
        var output_buf: std.ArrayList(RailEnd) = .empty;
        try collectSubBlockRails(scratch, sb, sub_port_to_net, &input_buf, &output_buf);
        // Prefer the module's design-block title ("ESP32-S3 UI", "3.272V Buck
        // (TPS62933)") over the bare instance handle ("esp32", "buck_3v3") —
        // it's what a reader recognizes at a glance. Fall back to the handle
        // for an untitled module. The slug stays keyed on the handle so the
        // node's `#sec-<slug>` link still resolves to the schematic card.
        const label = if (sb.block.name.len > 0) sb.block.name else sb.name;
        // The module title (label) names the part family; `mp.role` adds a
        // one-line "what it does" pulled from a matching top-level critical-IC
        // (e.g. "VPWR_IN → 5 V system buck"), and `mp.tokens` the part numbers.
        const mp = try mainParts(allocator, scratch, sb.block.instances);
        try nodes.append(allocator, .{
            .label = label,
            .subtitle = mp.role,
            .category = rb.classifyByName(sb.name, sb.block.instances),
            .slug = try review.slugify(allocator, sb.name),
            .key = sb.name,
            .inputs = try dupeRails(allocator, input_buf.items),
            .outputs = try dupeRails(allocator, output_buf.items),
            .parts = mp.tokens,
            .maturity = subBlockMaturity(scratch, project_dir, sb),
        });
        sub_node[sb_idx] = @intCast(nodes.items.len - 1);
    }
}

/// Append one diagram node per placeholder `(stub …)` part. The node's column
/// and colour come from the stub's declared `(category …)` (falling back to the
/// name heuristic); the label prefers the stub's role, then its name; the mpn
/// becomes the subtitle. Labels/subtitles borrow from the design (not freed),
/// so `is_boundary` stays false. Records each stub's node id in `stub_node`.
fn buildStubNodes(
    allocator: Allocator,
    block: *const DesignBlock,
    nodes: *std.ArrayList(Node),
    stub_node: []?u32,
) Allocator.Error!void {
    for (block.parts, 0..) |p, i| {
        const label = if (p.role.len > 0) p.role else p.name;
        // The part number moves from the subtitle to the dedicated part row; the
        // subtitle is left open for `applyHiddenSectionText` to fill with the
        // represented concept-section's description (e.g. the CM4 stub).
        var stub_parts: []const []const u8 = &.{};
        if (p.mpn.len > 0) {
            const arr = try allocator.alloc([]const u8, 1);
            arr[0] = try allocator.dupe(u8, p.mpn);
            stub_parts = arr;
        }
        try nodes.append(allocator, .{
            .label = label,
            .subtitle = "",
            .category = rb.classifyCategoryKey(p.category, p.name),
            .slug = "",
            .key = p.name,
            .stack = p.channels,
            .inputs = &.{},
            .outputs = &.{},
            .parts = stub_parts,
            // A `(stub …)` is a rough part idea by definition — always concept.
            .maturity = .concept,
        });
        stub_node[i] = @intCast(nodes.items.len - 1);
    }
}

/// Derive a section's maturity (see `types.Maturity`). Auto from content, with
/// `(status concept)` as a manual clamp down. A section that hosts a sub-module
/// inherits the sub-module finish line (done only once every hosted module is
/// starred ★, blue while one is still un-laid-out); a section placed directly on
/// the main board needs no layout, so the schematic is its finish line and it
/// reports `done` straight away. `adopted_sub` is the sub-block this section
/// adopted via the net-count heuristic (when it declares no explicit `(hosts …)`).
fn sectionMaturity(alloc: Allocator, project_dir: []const u8, block: *const DesignBlock, sec: Section, adopted_sub: ?usize) types.Maturity {
    // (status concept) pins it (the evaluator also infers concept for an empty
    // section — no instances, pin-groups, or sub-sections — so this covers both).
    if (sec.status == .concept) return .concept;
    // A rough part among the section's own instances keeps it at concept.
    for (sec.instances) |inst| {
        if (inst.placeholder) return .concept;
    }
    // Explicit hosts are the authority on which sub-modules this section owns.
    if (sec.hosts.len > 0) {
        var all_starred = true;
        for (sec.hosts) |host| {
            const sb = findSubBlock(block, host) orelse continue;
            if (blockHasRoughPart(sb.block)) return .concept;
            if (!subBlockStarred(alloc, project_dir, sb)) all_starred = false;
        }
        return if (all_starred) .done else .schematic;
    }
    // Else a heuristically-adopted sub-block, if any, sets the finish line.
    if (adopted_sub) |sb_idx| {
        const sb = block.sub_blocks[sb_idx];
        if (blockHasRoughPart(sb.block)) return .concept;
        return if (subBlockStarred(alloc, project_dir, sb)) .done else .schematic;
    }
    // Direct-in-design section: schematic is its finish line → done.
    return .done;
}

/// Derive an unattached sub-block chip's maturity. A sub-block IS a module, so
/// its finish line is a starred (★) layout: `done` once starred, blue `schematic`
/// while drawn-but-not-laid-out, and `concept` when it still holds a rough part.
fn subBlockMaturity(alloc: Allocator, project_dir: []const u8, sb: SubBlock) types.Maturity {
    if (blockHasRoughPart(sb.block)) return .concept;
    if (subBlockStarred(alloc, project_dir, sb)) return .done;
    return .schematic;
}

/// True when a (sub-)design still holds rough part ideas: a `(stub …)`
/// placeholder part or any instance flagged `placeholder`.
fn blockHasRoughPart(blk: *const DesignBlock) bool {
    if (blk.parts.len > 0) return true;
    for (blk.instances) |inst| {
        if (inst.placeholder) return true;
    }
    return false;
}

/// Has this sub-block's module starred a finished PCB layout? Reads the
/// `<module>.layouts.json` sidecar's `default` (★) entry. False when the source
/// isn't a bare module name or `project_dir` is unset (e.g. the static export).
fn subBlockStarred(alloc: Allocator, project_dir: []const u8, sb: SubBlock) bool {
    if (project_dir.len == 0) return false;
    const m = moduleNameOf(sb) orelse return false;
    return layout_status.read(alloc, project_dir, m).starred;
}

/// The bare module name a sub-block instantiates (non-empty source, no `/`), for
/// resolving its `.layouts.json`. Null for path / inline sources. Mirrors
/// `render_html.moduleSourceName`.
fn moduleNameOf(sb: SubBlock) ?[]const u8 {
    if (sb.source.len == 0) return null;
    if (std.mem.indexOfScalar(u8, sb.source, '/') != null) return null;
    return sb.source;
}

/// Find a sub-block by its handle (`(sub-block "name" …)`), for `(hosts …)`
/// resolution. Null when no sub-block carries that name.
fn findSubBlock(block: *const DesignBlock, name: []const u8) ?SubBlock {
    for (block.sub_blocks) |sb| {
        if (std.mem.eql(u8, sb.name, name)) return sb;
    }
    return null;
}

/// A sub-block classified as a power block (buck / LDO / regulator) — it
/// produces a rail and must stay its own producer node in the diagram graph.
fn isPowerSubBlock(sb: SubBlock) bool {
    return rb.classifyByName(sb.name, sb.block.instances) == .power;
}

fn dupeRails(allocator: Allocator, items: []const RailEnd) Allocator.Error![]RailEnd {
    const out = try allocator.alloc(RailEnd, items.len);
    @memcpy(out, items);
    return out;
}

fn freeNode(allocator: Allocator, n: Node) void {
    allocator.free(n.inputs);
    allocator.free(n.outputs);
    if (n.slug.len > 0) allocator.free(n.slug);
    if (n.is_boundary and n.label.len > 0) allocator.free(n.label);
    for (n.parts) |p| allocator.free(p);
    if (n.parts.len > 0) allocator.free(n.parts);
}

// ── headline-part extraction ───────────────────────────────────────────

/// Cap on the number of distinct part tokens shown per block.
const max_parts: usize = 3;

const MainParts = struct {
    /// Headline part tokens ("TPS62933DRLR", "3× LSF0108"), owned by the
    /// caller's allocator (each entry + the slice freed by `Graph.deinit`).
    tokens: []const []const u8 = &.{},
    /// One-line "what it does" subtitle fallback for blocks with no section
    /// description. Currently always empty (no per-part role source); kept so
    /// callers needn't change shape if a role source returns.
    role: []const u8 = "",
};

/// ASCII-uppercase `s` into `scratch` (component basenames are lowercase; part
/// numbers read as uppercase).
fn upperDup(scratch: Allocator, s: []const u8) Allocator.Error![]const u8 {
    const out = try scratch.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toUpper(c);
    return out;
}

/// Representative part number(s) for a block: walk its hub instances (skip
/// passives), map each to the uppercased component basename, then collapse
/// duplicates into "N× TOKEN" and cap at `max_parts` distinct tokens in
/// first-seen order.
fn mainParts(
    allocator: Allocator,
    scratch: Allocator,
    instances: []const env_mod.Instance,
) Allocator.Error!MainParts {
    var order: std.ArrayList([]const u8) = .empty;
    var counts: std.StringHashMapUnmanaged(usize) = .empty;
    const role: []const u8 = "";
    for (instances) |inst| {
        if (!isHubRef(inst.ref_des)) continue;
        if (inst.component.len == 0) continue;
        const token: []const u8 = try upperDup(scratch, inst.component);
        if (token.len == 0) continue;
        const gop = try counts.getOrPut(scratch, token);
        if (!gop.found_existing) {
            gop.value_ptr.* = 0;
            try order.append(scratch, token);
        }
        gop.value_ptr.* += 1;
    }
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |t| allocator.free(t);
        out.deinit(allocator);
    }
    for (order.items) |tok| {
        if (out.items.len >= max_parts) break;
        const n = counts.get(tok).?;
        const rendered = if (n > 1)
            try std.fmt.allocPrint(allocator, "{d}\u{00d7} {s}", .{ n, tok })
        else
            try allocator.dupe(u8, tok);
        try out.append(allocator, rendered);
    }
    return .{ .tokens = try out.toOwnedSlice(allocator), .role = role };
}

/// Lend each `(diagram hidden)` concept-section's description + card anchor to
/// the chip that represents it, named via `(hosts "<handle>")`. The hidden
/// section emits no node of its own, so without this its authored prose is lost
/// and the representative chip's `#sec-<handle>` link dangles (its schematic
/// card was folded into the section's `#sec-<section>` card).
fn applyHiddenSectionText(allocator: Allocator, block: *const DesignBlock, nodes: []Node) Allocator.Error!void {
    for (block.sections) |sec| {
        if (!sec.diagram_hidden) continue;
        for (sec.hosts) |host| {
            for (nodes) |*n| {
                if (n.key.len == 0 or !std.mem.eql(u8, n.key, host)) continue;
                if (sec.description.len > 0) n.subtitle = sec.description;
                if (sec.name.len > 0) {
                    const new_slug = try review.slugify(allocator, sec.name);
                    if (n.slug.len > 0) allocator.free(n.slug);
                    n.slug = new_slug;
                }
                break;
            }
        }
    }
}

// ── rail collection (ported from the old hub diagram) ──────────────────

const SubPortMap = std.StringHashMapUnmanaged([]const u8);

/// `"<sub>/<port>"` → parent net name, from the design's net-ties — lets a
/// sub-block's module-local `VOUT` resolve to the design rail it feeds.
fn buildSubPortToNet(scratch: Allocator, block: *const DesignBlock) Allocator.Error!SubPortMap {
    var m: SubPortMap = .empty;
    for (block.net_ties) |nt| {
        const a_slash = std.mem.indexOfScalar(u8, nt.a, '/');
        const b_slash = std.mem.indexOfScalar(u8, nt.b, '/');
        const sub_side: []const u8 = if (a_slash != null and b_slash == null) nt.a else if (b_slash != null and a_slash == null) nt.b else continue;
        const top_side: []const u8 = if (a_slash != null and b_slash == null) nt.b else nt.a;
        try m.put(scratch, sub_side, top_side);
    }
    return m;
}

fn collectSectionRails(
    scratch: Allocator,
    sec: Section,
    inputs: *std.ArrayList(RailEnd),
    outputs: *std.ArrayList(RailEnd),
) Allocator.Error!void {
    for (sec.ports) |p| {
        if (p.signal_type != .power) continue;
        switch (p.direction) {
            .in => try inputs.append(scratch, .{ .net = p.name, .voltage = p.voltage }),
            .out => try outputs.append(scratch, .{ .net = p.name, .voltage = p.voltage }),
            .io => {},
        }
    }
}

fn collectSubBlockRails(
    scratch: Allocator,
    sb: SubBlock,
    sub_port_to_net: *const SubPortMap,
    inputs: *std.ArrayList(RailEnd),
    outputs: *std.ArrayList(RailEnd),
) Allocator.Error!void {
    for (sb.block.ports) |p| {
        const v = p.nominal orelse p.rated_max orelse continue;
        // A programmable rail (`(rated lo hi)` with no fixed nominal) keeps its
        // lower bound so the producer card can show the span "lo–hi V".
        const v_lo: ?f64 = if (p.nominal == null) blk: {
            const lo = p.rated_min orelse break :blk null;
            break :blk if (lo < v) lo else null;
        } else null;
        const key = try std.fmt.allocPrint(scratch, "{s}/{s}", .{ sb.name, p.name });
        const net = sub_port_to_net.get(key) orelse (if (p.net.len > 0) p.net else p.name);
        if (std.mem.eql(u8, p.direction, "in")) {
            try inputs.append(scratch, .{ .net = net, .voltage = v });
        } else if (std.mem.eql(u8, p.direction, "out")) {
            try outputs.append(scratch, .{ .net = net, .voltage = v, .v_lo = v_lo });
        }
    }
}

// ── netlist flatten + edge derivation ──────────────────────────────────

/// Flatten the design tree and merge net-ties into one canonical net list
/// (arena-owned). Reuses the KiCad-export netlist machinery so the diagram
/// sees exactly the same connectivity the board does.
fn buildFlatNets(scratch: Allocator, block: *const DesignBlock) Allocator.Error![]export_kicad.FlatNet {
    var nets: std.ArrayList(export_kicad.FlatNet) = .empty;
    // false: keep the diagram's internal flatten prefixed exactly as before —
    // it's a self-consistent rendering pipeline, independent of the board's
    // grouped-refdes ref-des strings.
    try netlist.collectNets(scratch, block, "", &nets, .hierarchical);
    var ties: std.ArrayList(netlist.FlatTie) = .empty;
    try netlist.collectNetTies(scratch, block, "", &ties);
    try netlist.applyNetTies(scratch, &nets, ties.items);
    return nets.items;
}

/// Accumulator while collapsing parallel/diff nets between the same node pair.
const AccEdge = struct {
    from: u32,
    to: u32,
    class: ClassId,
    label: []const u8, // arena slice; shrinks to the common prefix on collapse
    voltage: ?f64,
    fanout: u16,
};

fn deriveEdges(
    allocator: Allocator,
    scratch: Allocator,
    flat: []const export_kicad.FlatNet,
    mem: *const membership.Membership,
    port_map: *const classify.PortClassMap,
    producer_by_net: *const std.StringHashMapUnmanaged(u32),
    nodes: []const Node,
    edge_list: *std.ArrayList(Edge),
) Allocator.Error!void {
    var acc: std.ArrayList(AccEdge) = .empty;
    var key_to_idx: std.StringHashMapUnmanaged(usize) = .empty;
    var touched_set: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var touched: std.ArrayList(u32) = .empty;

    for (flat) |net| {
        const clean = cleanNetName(net.name);
        const cls = classify.netClass(clean, port_map);
        if (cls == types.class_ground) continue;

        touched_set.clearRetainingCapacity();
        touched.clearRetainingCapacity();
        for (net.pins) |p| {
            const nid = mem.resolve(p.ref_des) orelse continue;
            const gop = try touched_set.getOrPut(scratch, nid);
            if (!gop.found_existing) try touched.append(scratch, nid);
        }
        if (touched.items.len < 2) continue;

        const driver = pickDriver(cls, clean, touched.items, nodes, producer_by_net);
        const voltage: ?f64 = if (cls == types.class_power)
            (producerVoltage(nodes, driver, clean) orelse railVoltageAny(nodes, clean) orelse voltageFromName(clean))
        else
            null;
        for (touched.items) |other| {
            if (other == driver) continue;
            try accumulate(scratch, &acc, &key_to_idx, driver, other, cls, clean, voltage);
        }
    }

    for (acc.items) |a| {
        try edge_list.append(allocator, .{
            .from = a.from,
            .to = a.to,
            .class = a.class,
            .label = try allocator.dupe(u8, a.label),
            .voltage = a.voltage,
            .fanout = a.fanout,
        });
    }
}

// ── board-edge antennas / EMVS cells ────────────────────────────────────

/// True for an RF net that names a board boundary (antenna / EMVS cell): a
/// `_RFIN` / `_RFOUT` feed (exact suffix, so the internal `LMX_RFOUTB_SE` LO
/// output is excluded), a numbered/differential cell leg (`RX1_RFIN3+`), or a
/// `TX_EMVS_*` cell drive. The leading underscore also excludes `RFINB_4159_1`.
fn isBoundaryName(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "TX_EMVS")) return true;
    if (std.mem.startsWith(u8, name, "TXEMVS")) return true;
    if (std.mem.endsWith(u8, name, "_RFOUT") or std.mem.endsWith(u8, name, "_RFIN")) return true;
    const at = std.mem.indexOf(u8, name, "_RFIN") orelse return false;
    const after = at + "_RFIN".len;
    return after < name.len and isDigit(name[after]);
}

/// Group key for a boundary net, so a cell's many legs collapse to one node:
/// `TX_EMVS_*` → `TX_EMVS`, `BEAM1_RFIN` → `BEAM1`, `RX1_RFIN3+` → `RX1`.
fn antennaBase(name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "TX_EMVS")) return "TX_EMVS";
    if (std.mem.startsWith(u8, name, "TXEMVS")) return "TXEMVS";
    if (std.mem.indexOf(u8, name, "_RFOUT")) |i| return name[0..i];
    if (std.mem.indexOf(u8, name, "_RFIN")) |i| return name[0..i];
    return name;
}

/// Display label for a synthesised endpoint (allocated; freed by deinit).
fn antennaLabel(allocator: Allocator, base: []const u8) Allocator.Error![]const u8 {
    if (std.mem.eql(u8, base, "TX_EMVS") or std.mem.eql(u8, base, "TXEMVS")) return allocator.dupe(u8, "TX-EMVS cell");
    if (std.mem.startsWith(u8, base, "RX")) return std.fmt.allocPrint(allocator, "{s} EMVS cell", .{base});
    return std.fmt.allocPrint(allocator, "{s} antenna", .{base});
}

/// Net-name fallback for whether the *chip* drives a boundary net (so the
/// antenna is the sink): transmit feeds (`*_RFOUT`, `TX*`) drive outward.
fn nameDrivesOut(name: []const u8) bool {
    return std.mem.endsWith(u8, name, "_RFOUT") or std.mem.startsWith(u8, name, "TX");
}

/// `port name → declared as an output` for every section port, so an antenna
/// edge points the right way (chip→antenna when the chip's port is an output).
fn buildRfPortDir(scratch: Allocator, block: *const DesignBlock) Allocator.Error!std.StringHashMapUnmanaged(bool) {
    var m: std.StringHashMapUnmanaged(bool) = .empty;
    for (block.sections) |sec| {
        for (sec.ports) |p| try m.put(scratch, p.name, p.direction == .out);
        for (sec.sub_sections) |ss| {
            for (ss.ports) |p| try m.put(scratch, p.name, p.direction == .out);
        }
    }
    return m;
}

/// Distinct IC blocks reachable from a boundary net through its transparent
/// matching passives (R/C/L/F/D), traced transitively net→passive→net but never
/// through a power/GND net (so a shunt-to-ground match doesn't pull in the
/// plane). Returns the single chip when the closure holds exactly one IC (→ a
/// real antenna feed, where the radiator side is a component-free dead-end);
/// null otherwise — 0 ICs is dangling, ≥2 is an inter-IC signal that merely
/// *looks* like a boundary net (e.g. an `ADAR2001_RFIN` LO from the LMX through
/// a resistive pad + AC cap).
fn boundaryChip(
    scratch: Allocator,
    flat: []const export_kicad.FlatNet,
    mem: *const membership.Membership,
    port_map: *const classify.PortClassMap,
    part_nets: *const std.StringHashMapUnmanaged(std.ArrayList(usize)),
    start: usize,
) Allocator.Error!?u32 {
    var seen_ic: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var visited: std.AutoHashMapUnmanaged(usize, void) = .empty;
    var queue: std.ArrayList(usize) = .empty;
    try visited.put(scratch, start, {});
    try queue.append(scratch, start);
    var chip: ?u32 = null;
    var count: usize = 0;
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        for (flat[queue.items[head]].pins) |p| {
            if (isHubRef(leafRef(p.ref_des))) {
                const nid = mem.resolve(p.ref_des) orelse continue;
                const gop = try seen_ic.getOrPut(scratch, nid);
                if (!gop.found_existing) {
                    count += 1;
                    chip = nid;
                }
                continue;
            }
            // Transparent passive: enqueue its other (non-power, non-ground) nets.
            // GND must be excluded too (the doc contract: never cross a power/GND
            // net) — else a shunt-to-ground match element enqueues the whole GND
            // plane, whose pins reach every IC → count ≥ 2 → the antenna is never
            // synthesised. An L-network / shunt-C match is common, so this silently
            // dropped those feeds' Layout-tab antennas.
            const others = part_nets.get(p.ref_des) orelse continue;
            for (others.items) |oni| {
                if (visited.contains(oni)) continue;
                const cls = classify.netClass(cleanNetName(flat[oni].name), port_map);
                if (cls == types.class_power or cls == types.class_ground) continue;
                try visited.put(scratch, oni, {});
                try queue.append(scratch, oni);
            }
        }
    }
    return if (count == 1) chip else null;
}

/// Synthesise an endpoint node + edge for each RF boundary net that reaches
/// exactly one on-board block. Antennas grouped by `antennaBase`; the four
/// `TX_EMVS_*` legs collapse onto one cell with a fanout count.
fn antennaPass(
    allocator: Allocator,
    scratch: Allocator,
    block: *const DesignBlock,
    flat: []const export_kicad.FlatNet,
    mem: *const membership.Membership,
    port_map: *const classify.PortClassMap,
    nodes: *std.ArrayList(Node),
    edge_list: *std.ArrayList(Edge),
) Allocator.Error!void {
    const dir = try buildRfPortDir(scratch, block);
    var ant_id: std.StringHashMapUnmanaged(u32) = .empty;
    var pair_idx: std.AutoHashMapUnmanaged(u64, usize) = .empty;

    // ref_des → the flat-net indices it appears on, for tracing a boundary net
    // through a series matching element (DC-block / tuning cap) to the IC.
    var part_nets: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty;
    for (flat, 0..) |net, ni| {
        for (net.pins) |p| {
            const gop = try part_nets.getOrPut(scratch, p.ref_des);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(scratch, ni);
        }
    }

    for (flat, 0..) |net, net_idx| {
        const clean = cleanNetName(net.name);
        if (!isBoundaryName(clean)) continue;
        if (classify.netClass(clean, port_map) != types.class_rf) continue;

        // The single IC this boundary net feeds (series matching passives are
        // transparent; a hop to a *second* IC means it's a signal, not a feed).
        const chip = (try boundaryChip(scratch, flat, mem, port_map, &part_nets, net_idx)) orelse continue;
        // A real antenna terminates on an RF chip, never on the mezzanine. If a
        // boundary net resolves only to the connector it's an attachment
        // artifact (the chip's sub-block folded into the connector), so skip it.
        if (nodes.items[chip].category == .connector) continue;

        const base = antennaBase(clean);
        const aid = blk: {
            const gop = try ant_id.getOrPut(scratch, base);
            if (gop.found_existing) break :blk gop.value_ptr.*;
            try nodes.append(allocator, .{
                .label = try antennaLabel(allocator, base),
                .subtitle = "off-board",
                .category = .analog,
                .slug = "",
                .inputs = &.{},
                .outputs = &.{},
                .is_boundary = true,
            });
            const id: u32 = @intCast(nodes.items.len - 1);
            gop.value_ptr.* = id;
            break :blk id;
        };

        const chip_out = dir.get(clean) orelse nameDrivesOut(clean);
        const from = if (chip_out) chip else aid;
        const to = if (chip_out) aid else chip;
        const key = (@as(u64, from) << 32) | to;
        const pg = try pair_idx.getOrPut(scratch, key);
        if (pg.found_existing) {
            edge_list.items[pg.value_ptr.*].fanout +|= 1;
            continue;
        }
        pg.value_ptr.* = edge_list.items.len;
        try edge_list.append(allocator, .{
            .from = from,
            .to = to,
            .class = types.class_rf,
            .label = try allocator.dupe(u8, base),
            .voltage = null,
            .fanout = 1,
        });
    }
}

// ── on-board clock sources ──────────────────────────────────────────────

/// A 2-pin crystal / XTAL by its library component name. Excludes TCXO/oscillator
/// *chips*, which are modelled as their own sections (e.g. cyclops's SiT5157),
/// so we don't double-count them.
fn isCrystalComponent(component: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(component, "crystal") != null or
        std.ascii.indexOfIgnoreCase(component, "xtal") != null;
}

/// Surface an on-board crystal as a synthesized clock-source node feeding the
/// block it lives in. The crystal's XI/XO nets are block-internal, so they never
/// form an inter-block edge — without this the Clocks view of an MCU board whose
/// oscillator is sealed in a `*-core` module shows nothing. One source per host.
fn crystalPass(
    allocator: Allocator,
    scratch: Allocator,
    block: *const DesignBlock,
    mem: *const membership.Membership,
    nodes: *std.ArrayList(Node),
    edge_list: *std.ArrayList(Edge),
) Allocator.Error!void {
    var host_seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (block.instances) |inst| {
        if (!isCrystalComponent(inst.component)) continue;
        const host = mem.resolve(inst.ref_des) orelse continue;
        try emitCrystal(allocator, scratch, &host_seen, nodes, edge_list, host);
    }
    for (block.sub_blocks) |sb| {
        for (sb.block.instances) |inst| {
            if (!isCrystalComponent(inst.component)) continue;
            const key = try std.fmt.allocPrint(scratch, "{s}/{s}", .{ sb.name, inst.ref_des });
            const host = mem.resolve(key) orelse continue;
            try emitCrystal(allocator, scratch, &host_seen, nodes, edge_list, host);
        }
    }
}

fn emitCrystal(
    allocator: Allocator,
    scratch: Allocator,
    host_seen: *std.AutoHashMapUnmanaged(u32, void),
    nodes: *std.ArrayList(Node),
    edge_list: *std.ArrayList(Edge),
    host: u32,
) Allocator.Error!void {
    if ((try host_seen.getOrPut(scratch, host)).found_existing) return;
    try nodes.append(allocator, .{
        .label = "Crystal", // static; not freed by deinit (is_boundary = false)
        .subtitle = "",
        .category = .clock,
        .slug = "",
        .inputs = &.{},
        .outputs = &.{},
    });
    const xid: u32 = @intCast(nodes.items.len - 1);
    try edge_list.append(allocator, .{
        .from = xid,
        .to = host,
        .class = types.class_clock,
        .label = try allocator.dupe(u8, "XTAL"),
        .voltage = null,
        .fanout = 1,
    });
}

fn accumulate(
    scratch: Allocator,
    acc: *std.ArrayList(AccEdge),
    key_to_idx: *std.StringHashMapUnmanaged(usize),
    from: u32,
    to: u32,
    cls: ClassId,
    label: []const u8,
    voltage: ?f64,
) Allocator.Error!void {
    if (from == to) return;
    const key = try std.fmt.allocPrint(scratch, "{d}|{d}|{d}", .{ from, to, cls });
    const gop = try key_to_idx.getOrPut(scratch, key);
    if (gop.found_existing) {
        var e = &acc.items[gop.value_ptr.*];
        e.fanout +|= 1;
        // Adopt the shared prefix only when it stays meaningful (≥3 chars); a
        // mixed bus (SPI + I2C + GPIO) trims to a stub like "M", so keep the
        // first net name as a representative instead of an unhelpful "M ×16".
        const merged = commonPrefixTrim(e.label, label);
        if (merged.len >= 3) e.label = merged;
        if (e.voltage == null) e.voltage = voltage;
    } else {
        gop.value_ptr.* = acc.items.len;
        try acc.append(scratch, .{ .from = from, .to = to, .class = cls, .label = label, .voltage = voltage, .fanout = 1 });
    }
}

/// Choose the driver (edge `from`) for a net so the edge points source→sink.
/// Power nets use the rail producer; everything else uses a role-based
/// `sourceRank` (oscillator/host/regulator outrank PLL/mixer/chip sinks),
/// breaking ties toward the lowest node id for stability. Components here
/// don't declare pin electrical types, so role is inferred from the block's
/// name + category — grounded in the real Cyclops part names.
fn pickDriver(
    cls: ClassId,
    clean: []const u8,
    touched: []const u32,
    nodes: []const Node,
    producer_by_net: *const std.StringHashMapUnmanaged(u32),
) u32 {
    if (cls == types.class_power) {
        if (producer_by_net.get(clean)) |p| {
            for (touched) |t| if (t == p) return p;
        }
        // No declared producer: prefer a power-category node that *outputs* this
        // rail (i.e. does not list it as an input) over one that merely consumes
        // it — so a buck/LDO wins over a downstream regulator sharing the rail.
        var prod: ?u32 = null;
        for (touched) |t| {
            if (nodes[t].category != .power) continue;
            if (railEndsHave(nodes[t].inputs, clean)) continue;
            if (prod == null or t < prod.?) prod = t;
        }
        if (prod) |p| return p;
    }
    var best = touched[0];
    var best_rank = sourceRank(nodes[best], cls);
    for (touched[1..]) |t| {
        const r = sourceRank(nodes[t], cls);
        if (r > best_rank or (r == best_rank and t < best)) {
            best = t;
            best_rank = r;
        }
    }
    return best;
}

/// How source-like a block is for a given net class (higher ⇒ closer to the
/// signal origin). Drives edge orientation and, transitively, left→right
/// layering. Keyword tests run on the block label; `cat` is the fallback.
// Source-rank tiers (higher ⇒ closer to the signal origin). Named so the
// orientation logic stays readable and free of bare magic numbers.
const rank_origin: u8 = 5; // signal origin: oscillator / host / regulator
const rank_drive: u8 = 4; // active driver: fanout, LNA, VCO/LO/PLL, expander
const rank_relay: u8 = 3; // pass-through: level shifter
const rank_mid: u8 = 2; // mixer / generic
const rank_sink: u8 = 1; // PLL ref input, connector IF, plain chip

fn sourceRank(node: Node, cls: ClassId) u8 {
    const n = node.label;
    if (cls == types.class_power) return if (node.category == .power) rank_origin else rank_sink;
    if (cls == types.class_clock) return clockRank(n, node.category);
    if (cls == types.class_control) return controlRank(n, node.category);
    if (cls == types.class_rf) return rfRank(n, node.category);
    return rank_sink; // ground
}

fn clockRank(n: []const u8, cat: rb.Category) u8 {
    if (rb.containsCI(n, "TCXO") or rb.containsCI(n, "OSC") or rb.containsCI(n, "XTAL")) return rank_origin;
    if (rb.containsCI(n, "PLL") or rb.containsCI(n, "SYNTH")) return rank_sink; // ref consumer
    if (rb.containsCI(n, "FANOUT") or rb.containsCI(n, "BUFFER") or cat == .clock) return rank_drive;
    return rank_mid;
}

fn controlRank(n: []const u8, cat: rb.Category) u8 {
    if (cat == .mcu or cat == .connector) return rank_origin; // host side
    if (rb.containsCI(n, "EXPANDER") or rb.containsCI(n, "GPIO") or rb.containsCI(n, "PCAL")) return rank_drive;
    if (rb.containsCI(n, "LEVEL") or rb.containsCI(n, "SHIFT") or rb.containsCI(n, "TXS")) return rank_relay;
    return rank_sink;
}

fn rfRank(n: []const u8, cat: rb.Category) u8 {
    if (rb.containsCI(n, "LNA")) return rank_drive; // antenna → LNA → mixer
    if (rb.containsCI(n, "VCO") or rb.containsCI(n, "LMX") or rb.containsCI(n, "PLL") or rb.containsCI(n, "SYNTH")) return rank_drive;
    if (rb.containsCI(n, "MIXER") or rb.containsCI(n, "RX")) return rank_mid;
    if (cat == .connector) return rank_sink; // IF outputs land on the connector
    return rank_mid;
}

fn railEndsHave(ends: []const RailEnd, net: []const u8) bool {
    for (ends) |e| if (std.mem.eql(u8, e.net, net)) return true;
    return false;
}

fn producerVoltage(nodes: []const Node, driver: u32, net: []const u8) ?f64 {
    for (nodes[driver].outputs) |out| {
        if (std.mem.eql(u8, out.net, net)) return out.voltage;
    }
    return null;
}

/// Fall back to any block that declares the rail (producer output or consumer
/// input) when the chosen driver carries no explicit voltage — e.g. V_RF_3P3
/// has no on-board regulator port but every consumer rates it 3.3 V. Keeps the
/// edge label's voltage now that the in-box rail tags are gone.
fn railVoltageAny(nodes: []const Node, net: []const u8) ?f64 {
    for (nodes) |n| {
        for (n.outputs) |o| if (o.voltage != null and std.mem.eql(u8, o.net, net)) return o.voltage;
        for (n.inputs) |in| if (in.voltage != null and std.mem.eql(u8, in.net, net)) return in.voltage;
    }
    return null;
}

/// Last-resort: parse a rail voltage from the `V<d>P<d>` naming convention
/// (V5P0→5.0, V1P8_RF→1.8, V_RX_2P5→2.5). The `P` stands in for the decimal
/// point. Returns null when the name has no digit-`P`-digit run. Only consulted
/// for power nets, whose names follow this convention.
fn voltageFromName(name: []const u8) ?f64 {
    if (name.len < 3) return null;
    var i: usize = 1;
    while (i + 1 < name.len) : (i += 1) {
        if (name[i] != 'P') continue;
        if (!isDigit(name[i - 1]) or !isDigit(name[i + 1])) continue;
        var lo = i;
        while (lo > 0 and isDigit(name[lo - 1])) lo -= 1;
        var hi = i + 1;
        while (hi < name.len and isDigit(name[hi])) hi += 1;
        const whole = std.fmt.parseInt(u32, name[lo..i], 10) catch return null;
        const frac_str = name[i + 1 .. hi];
        const frac = std.fmt.parseInt(u32, frac_str, 10) catch return null;
        var scale: f64 = 1;
        for (frac_str) |_| scale *= 10;
        return @as(f64, @floatFromInt(whole)) + @as(f64, @floatFromInt(frac)) / scale;
    }
    return null;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

// ── label helpers ──────────────────────────────────────────────────────

/// Strip a per-pin micro-net suffix (`<base>.<ref>.<pin>` → `<base>`).
fn cleanNetName(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| return name[0..dot];
    return name;
}

/// Leaf ref-des — the part after the last sub-block `/` prefix
/// (`rx1/U1` → `U1`, `C_KRX1_DCB` → `C_KRX1_DCB`).
fn leafRef(r: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, r, '/')) |i| return r[i + 1 ..];
    return r;
}

/// A hub (IC/connector) ref-des vs a 2-pin passive (R/C/L/F/D) — mirrors the
/// hub/spoke split so antenna synthesis treats series matching passives as
/// transparent and attaches the antenna to the IC behind them.
fn isHubRef(ref: []const u8) bool {
    if (ref.len == 0) return true;
    return switch (ref[0]) {
        'R', 'C', 'L', 'F', 'D' => false,
        else => true,
    };
}

/// Common prefix of two labels, trimmed of trailing separators — collapses
/// `RF_SPI_SCK` + `RF_SPI_MOSI` → `RF_SPI`, `ADF_CH1P` + `ADF_CH2N` → `ADF_CH`.
fn commonPrefixTrim(a: []const u8, b: []const u8) []const u8 {
    var k: usize = 0;
    const n = @min(a.len, b.len);
    while (k < n and a[k] == b[k]) : (k += 1) {}
    while (k > 1 and (a[k - 1] == '_' or a[k - 1] == '-' or a[k - 1] == '.')) : (k -= 1) {}
    return a[0..k];
}

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn emptyBlock(name: []const u8) DesignBlock {
    return .{ .name = name, .instances = &.{}, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &.{} };
}

// spec: diagram/collect - Emits one diagram node per stub categorised by its declared category
test "collectGraph emits a categorised node for each stub" {
    const parts = [_]env_mod.PlaceholderPart{
        .{ .ref_des = "U1", .name = "my-mcu", .role = "MCU", .category = "mcu", .signals = &.{} },
        .{ .ref_des = "J1", .name = "usb", .role = "USB-C", .category = "connector", .channels = 4, .signals = &.{} },
    };
    var block = emptyBlock("t");
    block.parts = &parts;
    var g = try collectGraph(testing.allocator, &block, &.{}, "");
    defer g.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), g.nodes.len);
    // Node category comes from the stub's declared (category …); channels → stack.
    try testing.expect(g.nodes[0].category == .mcu);
    try testing.expect(g.nodes[1].category == .connector);
    try testing.expectEqual(@as(u8, 4), g.nodes[1].stack);
    // Authoring key is the stub name, for (layout (place "key" …)) matching.
    try testing.expectEqualStrings("my-mcu", g.nodes[0].key);
    // A stub is a rough part idea by definition → concept maturity.
    try testing.expect(g.nodes[0].maturity.? == .concept);
}

// spec: diagram/collect - Derives a 3-stage chip maturity (concept/schematic/done) from content
test "collectGraph derives chip maturity from content" {
    var clean_mod = emptyBlock("Clean Module");
    const stub_parts = [_]env_mod.PlaceholderPart{
        .{ .ref_des = "U9", .name = "rough-part", .signals = &.{} },
    };
    var rough_mod = emptyBlock("Rough Module");
    rough_mod.parts = &stub_parts;
    const subs = [_]SubBlock{
        .{ .name = "clean", .block = &clean_mod },
        .{ .name = "rough", .block = &rough_mod },
    };
    const secs = [_]Section{
        .{ .name = "Idea Block", .status = .concept },
        .{ .name = "Wired Block", .status = .implemented },
    };
    var block = emptyBlock("board");
    block.sections = &secs;
    block.sub_blocks = &subs;
    // project_dir "" ⇒ no starred-layout lookup, so no sub-module reaches done.
    var g = try collectGraph(testing.allocator, &block, &.{}, "");
    defer g.deinit(testing.allocator);
    // Order: section nodes first, then unattached sub-block nodes.
    try testing.expectEqual(@as(usize, 4), g.nodes.len);
    try testing.expect(g.nodes[0].maturity.? == .concept); // (status concept) pins it
    try testing.expect(g.nodes[1].maturity.? == .done); // direct section, no sub-module ⇒ schematic is its finish line
    try testing.expect(g.nodes[2].maturity.? == .schematic); // sub-module drawn, not starred ⇒ awaiting layout
    try testing.expect(g.nodes[3].maturity.? == .concept); // sub-module still holds a rough (stub) part
}

// spec: diagram/collect - Derives inter-block edges from the flattened netlist rather than an MCU hub
test "collectGraph connects two non-MCU sections via a shared net" {
    const pg0 = [_]env_mod.PinGroup{.{ .ref_des = "U7", .pins = &.{} }};
    const pg1 = [_]env_mod.PinGroup{.{ .ref_des = "U11", .pins = &.{} }};
    const secs = [_]Section{
        .{ .name = "ADF4159 Synth", .pin_groups = &pg0 },
        .{ .name = "ADF5901 VCO", .pin_groups = &pg1 },
    };
    const pins = [_]env_mod.PinRef{ .{ .ref_des = "U7", .pin = "1" }, .{ .ref_des = "U11", .pin = "2" } };
    const nets = [_]env_mod.Net{.{ .name = "CPOUT_1", .pins = &pins }};
    var block = emptyBlock("rf");
    block.sections = &secs;
    block.nets = &nets;
    var g = try collectGraph(testing.allocator, &block, &.{}, "");
    defer g.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), g.nodes.len);
    try testing.expect(g.edges.len >= 1);
    try testing.expectEqual(types.class_rf, g.edges[0].class);
}

// spec: diagram/collect - Labels an unattached sub-block by its module's design-block title
test "collectGraph labels an unattached sub-block by its module title" {
    var module = emptyBlock("ESP32-S3 UI"); // the module's design-block title
    const subs = [_]SubBlock{.{ .name = "esp32", .block = &module }};
    var block = emptyBlock("board");
    block.sub_blocks = &subs;
    var g = try collectGraph(testing.allocator, &block, &.{}, "");
    defer g.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), g.nodes.len);
    try testing.expectEqualStrings("ESP32-S3 UI", g.nodes[0].label);
}

// spec: diagram/collect - Carries a programmable rail's rated span onto the producer node
test "collectGraph keeps a programmable rail's lower bound" {
    const ports = [_]env_mod.Port{.{ .name = "VBANK", .net = "", .direction = "out", .rated_min = 1.8, .rated_max = 3.3 }};
    var module = emptyBlock("DUT Bank Rail");
    module.ports = &ports;
    const subs = [_]SubBlock{.{ .name = "bank_a", .block = &module }};
    var block = emptyBlock("board");
    block.sub_blocks = &subs;
    var g = try collectGraph(testing.allocator, &block, &.{}, "");
    defer g.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), g.nodes.len);
    try testing.expectEqual(@as(usize, 1), g.nodes[0].outputs.len);
    try testing.expectApproxEqAbs(@as(f64, 1.8), g.nodes[0].outputs[0].v_lo.?, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 3.3), g.nodes[0].outputs[0].voltage.?, 0.001);
}

// spec: diagram/collect - Surfaces an on-board crystal as a clock source feeding its block
test "collectGraph surfaces a module crystal as a clock source" {
    const xtal = [_]env_mod.Instance{.{ .ref_des = "X1", .component = "crystal", .value = "", .footprint = "", .symbol = "" }};
    var module = emptyBlock("RP2350B Core");
    module.instances = &xtal;
    const subs = [_]SubBlock{.{ .name = "mcu", .block = &module }};
    var block = emptyBlock("board");
    block.sub_blocks = &subs;
    var g = try collectGraph(testing.allocator, &block, &.{}, "");
    defer g.deinit(testing.allocator);
    // The mcu block node + the synthesized Crystal source, joined by a clock edge.
    try testing.expectEqual(@as(usize, 2), g.nodes.len);
    try testing.expectEqual(@as(usize, 1), g.edges.len);
    try testing.expectEqual(types.class_clock, g.edges[0].class);
}

// spec: diagram/collect - Excludes ground nets and collapses parallel or differential nets into one edge
test "collectGraph drops ground and merges a differential pair" {
    const pg0 = [_]env_mod.PinGroup{.{ .ref_des = "U8", .pins = &.{} }};
    const pg1 = [_]env_mod.PinGroup{.{ .ref_des = "J1", .pins = &.{} }};
    const secs = [_]Section{
        .{ .name = "ADAR2004 Mixer", .pin_groups = &pg0 },
        .{ .name = "Mezzanine Connector", .pin_groups = &pg1 },
    };
    const gnd = [_]env_mod.PinRef{ .{ .ref_des = "U8", .pin = "10" }, .{ .ref_des = "J1", .pin = "20" } };
    const chp = [_]env_mod.PinRef{ .{ .ref_des = "U8", .pin = "1" }, .{ .ref_des = "J1", .pin = "3" } };
    const chn = [_]env_mod.PinRef{ .{ .ref_des = "U8", .pin = "2" }, .{ .ref_des = "J1", .pin = "4" } };
    const nets = [_]env_mod.Net{
        .{ .name = "GND", .pins = &gnd },
        .{ .name = "ADF_CH1P", .pins = &chp },
        .{ .name = "ADF_CH1N", .pins = &chn },
    };
    var block = emptyBlock("rf");
    block.sections = &secs;
    block.nets = &nets;
    var g = try collectGraph(testing.allocator, &block, &.{}, "");
    defer g.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), g.edges.len);
    try testing.expectEqual(@as(u16, 2), g.edges[0].fanout);
    try testing.expectEqualStrings("ADF_CH1", g.edges[0].label);
}

// spec: diagram/collect - Resolves a power edge's voltage from any block that declares the rail
test "collectGraph resolves rail voltage from a consumer when no producer declares it" {
    const pg0 = [_]env_mod.PinGroup{.{ .ref_des = "U1", .pins = &.{} }};
    const pg1 = [_]env_mod.PinGroup{.{ .ref_des = "U2", .pins = &.{} }};
    // The load declares the rail (3.3 V) as a consumer input; no node produces it.
    const load_ports = [_]env_mod.SectionPort{.{ .name = "V_RF_3P3", .direction = .in, .signal_type = .power, .voltage = 3.3 }};
    const secs = [_]Section{
        .{ .name = "Buck Regulator", .pin_groups = &pg0 },
        .{ .name = "ADF5904 RX", .pin_groups = &pg1, .ports = &load_ports },
    };
    const pins = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "U2", .pin = "2" } };
    const nets = [_]env_mod.Net{.{ .name = "V_RF_3P3", .pins = &pins }};
    var block = emptyBlock("pwr");
    block.sections = &secs;
    block.nets = &nets;
    var g = try collectGraph(testing.allocator, &block, &.{}, "");
    defer g.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), g.edges.len);
    try testing.expectEqual(types.class_power, g.edges[0].class);
    try testing.expect(g.edges[0].voltage != null);
    try testing.expectApproxEqAbs(@as(f64, 3.3), g.edges[0].voltage.?, 0.01);
}

// spec: diagram/collect - Picks each block's primary supply rail by pin count and records its full rail set
test "collectGraph picks the primary rail by pin count" {
    const pg = [_]env_mod.PinGroup{.{ .ref_des = "U1", .pins = &.{} }};
    const secs = [_]Section{.{ .name = "DUAL", .pin_groups = &pg }};
    // U1 has two pins on the 3.3 V rail and one on 1.8 V ⇒ primary is 3.3 V.
    const v3 = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "U1", .pin = "2" } };
    const v1 = [_]env_mod.PinRef{.{ .ref_des = "U1", .pin = "3" }};
    const nets = [_]env_mod.Net{
        .{ .name = "V3P3", .pins = &v3 },
        .{ .name = "V1P8", .pins = &v1 },
    };
    var block = emptyBlock("d");
    block.sections = &secs;
    block.nets = &nets;
    var g = try collectGraph(testing.allocator, &block, &.{}, "");
    defer g.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), g.nodes.len);
    try testing.expectApproxEqAbs(@as(f64, 3.3), g.nodes[0].power_rail, 0.01);
    // Full rail set is recorded ascending (1.8 V and 3.3 V).
    try testing.expectEqual(@as(usize, 2), g.nodes[0].rails.len);
    try testing.expectApproxEqAbs(@as(f64, 1.8), g.nodes[0].rails[0], 0.01);
    try testing.expectApproxEqAbs(@as(f64, 3.3), g.nodes[0].rails[1], 0.01);
}

// spec: diagram/collect - Parses a rail voltage from its V<d>P<d> name when no port declares one
test "voltageFromName parses the V<d>P<d> convention" {
    try testing.expectApproxEqAbs(@as(f64, 5.0), voltageFromName("V5P0").?, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 1.8), voltageFromName("V1P8_RF").?, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 2.5), voltageFromName("V_RX_2P5").?, 0.001);
    try testing.expect(voltageFromName("VBATT") == null);
}

// spec: diagram/collect - Synthesises an antenna endpoint for a board-edge RF net touching one block
test "collectGraph adds an antenna node for a one-sided RF boundary net" {
    const pg = [_]env_mod.PinGroup{.{ .ref_des = "U9", .pins = &.{} }};
    const ports = [_]env_mod.SectionPort{.{ .name = "TX1_RFOUT", .direction = .out }};
    const secs = [_]Section{.{ .name = "HMC1131 MPA", .pin_groups = &pg, .ports = &ports }};
    // TX1_RFOUT reaches only U9's chip on-board; its other end is the antenna.
    const pins = [_]env_mod.PinRef{.{ .ref_des = "U9", .pin = "2" }};
    const nets = [_]env_mod.Net{.{ .name = "TX1_RFOUT", .pins = &pins }};
    var block = emptyBlock("rf");
    block.sections = &secs;
    block.nets = &nets;
    var g = try collectGraph(testing.allocator, &block, &.{}, "");
    defer g.deinit(testing.allocator);
    // The chip section plus one synthesised antenna endpoint (appended last).
    try testing.expectEqual(@as(usize, 2), g.nodes.len);
    const ant: u32 = @intCast(g.nodes.len - 1);
    try testing.expect(g.nodes[ant].is_boundary);
    try testing.expectEqual(@as(usize, 1), g.edges.len);
    try testing.expectEqual(types.class_rf, g.edges[0].class);
    // A chip *output* port drives the net, so the antenna is the sink.
    try testing.expectEqual(ant, g.edges[0].to);
}

// spec: diagram/collect - Resolves each block's headline part numbers from hub instances by uppercased component
test "mainParts maps hubs to uppercased component with multiplicity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const insts = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "tps62933drlr", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "U2", .component = "lsf0108rksr", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "U3", .component = "lsf0108rksr", .value = "", .footprint = "", .symbol = "" },
        // A passive (C-prefix) is not a hub → excluded from the part list.
        .{ .ref_des = "C1", .component = "cap-0402", .value = "100nF", .footprint = "", .symbol = "" },
    };
    const mp = try mainParts(testing.allocator, arena.allocator(), &insts);
    defer {
        for (mp.tokens) |t| testing.allocator.free(t);
        testing.allocator.free(mp.tokens);
    }
    try testing.expectEqual(@as(usize, 2), mp.tokens.len);
    try testing.expectEqualStrings("TPS62933DRLR", mp.tokens[0]); // uppercased component basename
    try testing.expectEqualStrings("2\u{00d7} LSF0108RKSR", mp.tokens[1]); // upper fallback + ×2 multiplicity
}

// spec: diagram/collect - A (diagram hidden) host section lends its description + card anchor to the chip
test "applyHiddenSectionText lends a hidden section's text to its hosted chip" {
    var module = emptyBlock("3.3V Buck (TPS62933)");
    const hosts = [_][]const u8{"buck"};
    const secs = [_]Section{
        .{ .name = "Core Rail", .description = "TPS62933 5V to 3.3V buck, 3A", .diagram_hidden = true, .hosts = &hosts },
    };
    const subs = [_]SubBlock{.{ .name = "buck", .block = &module }};
    var block = emptyBlock("board");
    block.sections = &secs;
    block.sub_blocks = &subs;
    // The card path adopts "buck" into the hidden section; the diagram must still
    // give it a chip (the un-adoption), then lend it the section's text + anchor.
    const attach = [_]?usize{0};
    var g = try collectGraph(testing.allocator, &block, &attach, "");
    defer g.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), g.nodes.len);
    try testing.expectEqualStrings("TPS62933 5V to 3.3V buck, 3A", g.nodes[0].subtitle);
    const want_slug = try review.slugify(testing.allocator, "Core Rail");
    defer testing.allocator.free(want_slug);
    try testing.expectEqualStrings(want_slug, g.nodes[0].slug);
}
