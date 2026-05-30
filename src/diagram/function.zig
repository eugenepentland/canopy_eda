//! The **Function** view's coarsened graph — the glanceable "what does the
//! system do" abstraction that sits one level above the detailed System view.
//!
//! It collapses the detailed connectivity graph (one node per section /
//! sub-block) into a handful of *functional subsystems*, each labeled by what
//! it DOES (a verb phrase) rather than what parts it contains. Membership comes
//! first from declared `(function …)` forms (authoritative), then auto-groups
//! the remainder by category — so a design with no annotation still gets a
//! small functional view. The result is just another `Graph`, so the System
//! view's stage layout + renderer draw it unchanged.

const std = @import("std");
const types = @import("types.zig");
const rb = @import("../render_block_types.zig");
const env_mod = @import("../eval/env.zig");

const Allocator = std.mem.Allocator;
const Graph = types.Graph;
const Node = types.Node;
const Edge = types.Edge;
const Category = rb.Category;

const n_cat = @typeInfo(Category).@"enum".fields.len;

/// The auto-group template for a node's category: the functional name + verb
/// shown when a section isn't claimed by any declared `(function …)`, plus the
/// `key` that dedups sibling categories into one block (clocks fold into the
/// controller, protection into I/O) and the `cat` the resulting block wears
/// (which drives its stage band).
const Template = struct { key: []const u8, name: []const u8, verb: []const u8, cat: Category };

/// Category → auto-group template, indexed by `@intFromEnum`. Built as a table
/// (not a switch) so it stays a single source of truth and adds no extra
/// switch on `Category`.
const category_groups = blk: {
    var t: [n_cat]Template = undefined;
    t[@intFromEnum(Category.mcu)] = .{ .key = "core", .name = "Controller", .verb = "runs the firmware & real-time tasks", .cat = .mcu };
    t[@intFromEnum(Category.clock)] = .{ .key = "core", .name = "Controller", .verb = "runs the firmware & real-time tasks", .cat = .mcu };
    t[@intFromEnum(Category.power)] = .{ .key = "power", .name = "Power", .verb = "conditions input into board rails", .cat = .power };
    t[@intFromEnum(Category.memory)] = .{ .key = "memory", .name = "Memory", .verb = "stores firmware & data", .cat = .memory };
    t[@intFromEnum(Category.comms)] = .{ .key = "comms", .name = "Connectivity", .verb = "host & network interfaces", .cat = .comms };
    t[@intFromEnum(Category.sensor)] = .{ .key = "sensing", .name = "Sensing", .verb = "measures physical signals", .cat = .sensor };
    t[@intFromEnum(Category.analog)] = .{ .key = "analog", .name = "Analog", .verb = "conditions analog signals", .cat = .analog };
    t[@intFromEnum(Category.connector)] = .{ .key = "io", .name = "I/O", .verb = "external connectors & protection", .cat = .connector };
    t[@intFromEnum(Category.protection)] = .{ .key = "io", .name = "I/O", .verb = "external connectors & protection", .cat = .connector };
    t[@intFromEnum(Category.peripheral)] = .{ .key = "peripheral", .name = "Peripherals", .verb = "auxiliary on-board functions", .cat = .peripheral };
    break :blk t;
};

/// Case-insensitive substring test — `needle` ⊆ `hay`.
fn ciContains(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// The index of the first declared function whose `includes` list claims this
/// node label (matched as a forgiving substring, so `"Channel 1 PSU"` claims
/// the "Channel 1 PSU (Buck-Boost)" sub-block box), or null if none.
fn claimingGroup(funcs: []const env_mod.FunctionGroup, label: []const u8) ?usize {
    for (funcs, 0..) |f, fi| {
        for (f.includes) |inc| {
            if (ciContains(label, inc)) return fi;
        }
    }
    return null;
}

/// The modal category among a group's members (its `votes` tally), used as a
/// declared group's category so it lands in the right stage band.
fn modalCategory(votes: *const [n_cat]u16) Category {
    var best: usize = 0;
    for (votes, 0..) |v, ci| {
        if (v > votes[best]) best = ci;
    }
    return @enumFromInt(best);
}

/// Pick the class an aggregated super-edge should wear: a real signal class
/// (control/clock/RF) wins over the recessive power class, so a subsystem link
/// that carries both reads as the signal. The first signal class seen sticks.
fn pickClass(existing: types.ClassId, new: types.ClassId) types.ClassId {
    const new_signal = new != types.CLASS_POWER and new != types.CLASS_GROUND;
    const ex_signal = existing != types.CLASS_POWER and existing != types.CLASS_GROUND;
    if (ex_signal) return existing;
    if (new_signal) return new;
    return existing;
}

/// The leading word of `s` (up to the first space), or all of `s`.
fn firstWord(s: []const u8) []const u8 {
    const sp = std.mem.indexOfScalar(u8, s, ' ') orelse s.len;
    return s[0..sp];
}

/// Shorten a member block label for the in-box parts list: drop a trailing
/// "(part number)" parenthetical, and a leading word it shares with the group
/// name (so "DUT Fixture Connector" reads as "Fixture Connector" inside the
/// "DUT Interface" block). Returns a slice borrowed from `label`.
fn cleanMember(group_name: []const u8, label: []const u8) []const u8 {
    var s = label;
    if (std.mem.indexOf(u8, s, " (")) |p| s = s[0..p];
    const fw = firstWord(group_name);
    if (fw.len == 0 or s.len <= fw.len + 1) return s;
    if (s[fw.len] != ' ') return s;
    if (!std.ascii.eqlIgnoreCase(s[0..fw.len], fw)) return s;
    const rest = s[fw.len + 1 ..];
    // Don't strip if it would leave a dangling fragment ("Bring-up & Debug" must
    // not become "& Debug") — keep the original unless a real word follows.
    if (rest.len == 0 or !std.ascii.isAlphanumeric(rest[0])) return s;
    return rest;
}

/// True when `s` is substring-related to a label already in `list` — used to
/// dedup the parts list so a section and the sub-block inside it (e.g.
/// "ESP32-S3 UI" and "ESP32-S3 UI Co-processor") collapse to one entry.
fn relatedLabel(list: []const []const u8, s: []const u8) bool {
    for (list) |x| {
        if (ciContains(x, s)) return true;
        if (ciContains(s, x)) return true;
    }
    return false;
}

/// Build the coarsened Function graph from the detailed connectivity `g` and
/// the design's declared `(function …)` groups. Returns null when there's
/// nothing to coarsen or it collapses to fewer than two blocks (then the
/// Function view adds nothing over the System view). All output is arena-owned;
/// `classes` is borrowed from `g`, so the result must NOT be `Graph.deinit`-ed.
pub fn buildFunctionGraph(arena: Allocator, block: *const env_mod.DesignBlock, g: *const Graph) Allocator.Error!?Graph {
    if (g.nodes.len == 0) return null;
    const funcs = block.functions;
    const ndecl = funcs.len;

    // Map each detail node to a group. Declared functions occupy indices
    // [0, ndecl); auto groups (one per distinct category template) follow, keyed
    // so sibling categories share a block.
    var auto: std.ArrayListUnmanaged(Template) = .empty;
    var auto_of: std.StringHashMapUnmanaged(usize) = .empty;
    const group_of = try arena.alloc(usize, g.nodes.len);
    for (g.nodes, 0..) |n, i| {
        group_of[i] = if (claimingGroup(funcs, n.label)) |d| d else try autoIndex(arena, &auto, &auto_of, n.category, ndecl);
    }
    const ngroup = ndecl + auto.items.len;

    // Tally membership + per-group category votes (declared groups take their
    // modal member category; auto groups carry their template's).
    const members = try arena.alloc(u16, ngroup);
    @memset(members, 0);
    const votes = try arena.alloc([n_cat]u16, ngroup);
    @memset(votes, [_]u16{0} ** n_cat);
    for (g.nodes, 0..) |n, i| {
        members[group_of[i]] += 1;
        votes[group_of[i]][@intFromEnum(n.category)] += 1;
    }

    // Collect each group's member labels (cleaned + deduped, in node order) so
    // the super-node can list its key parts.
    const group_name = try arena.alloc([]const u8, ngroup);
    for (0..ngroup) |gi| group_name[gi] = if (gi < ndecl) funcs[gi].name else auto.items[gi - ndecl].name;
    const mlist = try arena.alloc(std.ArrayListUnmanaged([]const u8), ngroup);
    for (mlist) |*m| m.* = .empty;
    for (g.nodes, 0..) |n, i| {
        const gi = group_of[i];
        const cleaned = cleanMember(group_name[gi], n.label);
        if (!relatedLabel(mlist[gi].items, cleaned)) try mlist[gi].append(arena, cleaned);
    }

    // Materialise the surviving (non-empty) groups as super-nodes.
    const final_of = try arena.alloc(i32, ngroup);
    var nodes: std.ArrayListUnmanaged(Node) = .empty;
    for (0..ngroup) |gi| {
        if (members[gi] == 0) {
            final_of[gi] = -1;
            continue;
        }
        final_of[gi] = @intCast(nodes.items.len);
        var node = superNode(funcs, auto.items, ndecl, gi, &votes[gi]);
        node.members = try mlist[gi].toOwnedSlice(arena);
        try nodes.append(arena, node);
    }
    if (nodes.items.len < 2) return null;

    const edges = try aggregateEdges(arena, g, group_of, final_of, nodes.items.len);
    return Graph{
        .nodes = try nodes.toOwnedSlice(arena),
        .edges = edges,
        .classes = g.classes,
    };
}

/// Find or create the auto-group index for a node's category, returning the
/// global group index (offset past the declared groups).
fn autoIndex(
    arena: Allocator,
    auto: *std.ArrayListUnmanaged(Template),
    auto_of: *std.StringHashMapUnmanaged(usize),
    cat: Category,
    ndecl: usize,
) Allocator.Error!usize {
    const t = category_groups[@intFromEnum(cat)];
    const gop = try auto_of.getOrPut(arena, t.key);
    if (!gop.found_existing) {
        gop.value_ptr.* = auto.items.len;
        try auto.append(arena, t);
    }
    return ndecl + gop.value_ptr.*;
}

/// Build one super-node for group `gi`: a declared function uses its name +
/// verb (falling back to its subtitle) and its modal member category; an auto
/// group uses its template.
fn superNode(funcs: []const env_mod.FunctionGroup, auto: []const Template, ndecl: usize, gi: usize, votes: *const [n_cat]u16) Node {
    var label: []const u8 = undefined;
    var verb: []const u8 = undefined;
    var cat: Category = undefined;
    if (gi < ndecl) {
        const f = funcs[gi];
        label = f.name;
        verb = if (f.verb.len > 0) f.verb else f.subtitle;
        cat = modalCategory(votes);
    } else {
        const t = auto[gi - ndecl];
        label = t.name;
        verb = t.verb;
        cat = t.cat;
    }
    return .{ .label = label, .subtitle = verb, .category = cat, .slug = "", .inputs = &.{}, .outputs = &.{} };
}

/// Collapse the detail edges into one super-edge per ordered (from,to) group
/// pair. A super-edge takes a signal class over a power one, so the few
/// control/clock/RF links read on top of the power fan (labels are dropped —
/// the Function view shows flow, not net names).
fn aggregateEdges(arena: Allocator, g: *const Graph, group_of: []const usize, final_of: []const i32, nsuper: usize) Allocator.Error![]Edge {
    var edge_at: std.AutoHashMapUnmanaged(u64, usize) = .empty;
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    for (g.edges) |e| {
        const sf = final_of[group_of[e.from]];
        const st = final_of[group_of[e.to]];
        if (sf < 0 or st < 0) continue; // edge into a dropped (empty) group
        if (sf == st) continue; // intra-subsystem edge — not shown at this level
        const key = @as(u64, @intCast(sf)) * @as(u64, @intCast(nsuper)) + @as(u64, @intCast(st));
        const gop = try edge_at.getOrPut(arena, key);
        if (gop.found_existing) {
            const ex = &edges.items[gop.value_ptr.*];
            ex.class = pickClass(ex.class, e.class);
        } else {
            gop.value_ptr.* = edges.items.len;
            try edges.append(arena, .{ .from = @intCast(sf), .to = @intCast(st), .class = e.class, .label = "" });
        }
    }
    return edges.toOwnedSlice(arena);
}

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn tNode(label: []const u8, cat: Category) Node {
    return .{ .label = label, .subtitle = "", .category = cat, .slug = "sl", .inputs = &.{}, .outputs = &.{} };
}

const empty_block = env_mod.DesignBlock{ .name = "d", .instances = &.{}, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &.{} };

// spec: diagram/function - Auto-groups undeclared sections by category into functional blocks
test "buildFunctionGraph auto-groups by category when nothing is declared" {
    var nodes = [_]Node{
        tNode("5V Buck", .power),
        tNode("3V3 LDO", .power),
        tNode("STM32 Core", .mcu),
        tNode("IMU", .sensor),
    };
    var edges = [_]Edge{
        .{ .from = 0, .to = 2, .class = types.CLASS_POWER, .label = "5V" },
        .{ .from = 2, .to = 3, .class = types.CLASS_CONTROL, .label = "I2C" },
    };
    const g = Graph{ .nodes = &nodes, .edges = &edges };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fg = (try buildFunctionGraph(arena.allocator(), &empty_block, &g)) orelse return error.TestUnexpectedResult;
    // Two power sections collapse into one "Power" block, in first-seen order:
    // Power, Controller, Sensing.
    try testing.expectEqual(@as(usize, 3), fg.nodes.len);
    try testing.expectEqualStrings("Power", fg.nodes[0].label);
    try testing.expectEqualStrings("Controller", fg.nodes[1].label);
    try testing.expectEqualStrings("Sensing", fg.nodes[2].label);
}

// spec: diagram/function - Declared (function …) groups claim their member sections by name
test "buildFunctionGraph honors a declared function group" {
    var nodes = [_]Node{
        tNode("DMM Analog Front-End", .analog),
        tNode("DMM Reference EEPROM", .memory),
        tNode("STM32 Core", .mcu),
    };
    var edges = [_]Edge{.{ .from = 2, .to = 0, .class = types.CLASS_CONTROL, .label = "I2C" }};
    const g = Graph{ .nodes = &nodes, .edges = &edges };
    var includes = [_][]const u8{"DMM"};
    var funcs = [_]env_mod.FunctionGroup{.{ .name = "Measurement", .verb = "measures V/R", .includes = &includes }};
    var block = empty_block;
    block.functions = &funcs;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fg = (try buildFunctionGraph(arena.allocator(), &block, &g)) orelse return error.TestUnexpectedResult;
    // Both DMM sections fold into "Measurement" (group 0); the MCU auto-groups.
    try testing.expectEqual(@as(usize, 2), fg.nodes.len);
    try testing.expectEqualStrings("Measurement", fg.nodes[0].label);
    try testing.expectEqualStrings("measures V/R", fg.nodes[0].subtitle);
    try testing.expectEqualStrings("Controller", fg.nodes[1].label);
    // The control edge MCU→DMM survives as one super-edge between the 2 blocks.
    try testing.expectEqual(@as(usize, 1), fg.edges.len);
    try testing.expectEqual(types.CLASS_CONTROL, fg.edges[0].class);
}

// spec: diagram/function - Function blocks list their cleaned member part labels
test "buildFunctionGraph lists cleaned member parts" {
    var nodes = [_]Node{
        tNode("DUT Fixture Connector", .connector),
        tNode("DUT Bench Header", .connector),
        tNode("STM32 Core", .mcu),
    };
    var edges = [_]Edge{.{ .from = 2, .to = 0, .class = types.CLASS_CONTROL, .label = "IO" }};
    const g = Graph{ .nodes = &nodes, .edges = &edges };
    var includes = [_][]const u8{"DUT"};
    var funcs = [_]env_mod.FunctionGroup{.{ .name = "DUT Interface", .verb = "talks to the DUT", .includes = &includes }};
    var block = empty_block;
    block.functions = &funcs;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fg = (try buildFunctionGraph(arena.allocator(), &block, &g)) orelse return error.TestUnexpectedResult;
    // The DUT block lists its two connectors, with the shared "DUT" prefix dropped.
    try testing.expectEqualStrings("DUT Interface", fg.nodes[0].label);
    try testing.expectEqual(@as(usize, 2), fg.nodes[0].members.len);
    try testing.expectEqualStrings("Fixture Connector", fg.nodes[0].members[0]);
    try testing.expectEqualStrings("Bench Header", fg.nodes[0].members[1]);
}

// spec: diagram/function - A signal link outranks a power link when subsystems share both
test "pickClass upgrades power to a signal class" {
    try testing.expectEqual(types.CLASS_CONTROL, pickClass(types.CLASS_POWER, types.CLASS_CONTROL));
    try testing.expectEqual(types.CLASS_CONTROL, pickClass(types.CLASS_CONTROL, types.CLASS_POWER));
    try testing.expectEqual(types.CLASS_POWER, pickClass(types.CLASS_POWER, types.CLASS_POWER));
}
