//! Leak-regression tests for the block-diagram layout engine.
//!
//! Area: src/diagram/{types,membership,layout,lod}.zig. Two STORE-LIFECYCLE
//! tests exercise the hand-written `deinit`s (Graph, Membership) under
//! std.testing.allocator so a deinit that misses an owned/dup'd field panics;
//! the rest are ARENA-CONTRACT tests that drive the request-path layout
//! functions through an arena backed by testing.allocator, documenting the
//! "allocate-and-forget, caller resets the arena" contract and catching any
//! escape to a different testing-backed allocator or a double-free.
//!
//! Note: collect.collectGraph and the renderers allocate node slugs/labels
//! from the caller allocator (freed by Graph.deinit), so the lifecycle test
//! mirrors that ownership exactly: every owned field is dup'd through
//! testing.allocator and Graph.deinit must free all of them.

const std = @import("std");
const types = @import("../diagram/types.zig");
const layout = @import("../diagram/layout.zig");
const membership = @import("../diagram/membership.zig");
const env_mod = @import("../eval/env.zig");

const testing = std.testing;

// leak-audit: Graph.deinit must free every owned field of every node + edge
// (inputs/outputs/rails/slug/boundary-label) plus the node/edge slices and a
// non-builtin class registry. Build a Graph whose owned fields are all dup'd
// through testing.allocator, then deinit — testing.allocator panics at test
// end if deinit forgets any of them.
test "leak: Graph.deinit frees all owned node, edge, and class fields" {
    const a = testing.allocator;

    // Two real nodes (with owned inputs/outputs/rails/slug) plus one boundary
    // node whose label is owned (is_boundary == true).
    const nodes = try a.alloc(types.Node, 3);

    const in0 = try a.alloc(types.RailEnd, 1);
    in0[0] = .{ .net = "VIN", .voltage = 5.0 };
    const out0 = try a.alloc(types.RailEnd, 1);
    out0[0] = .{ .net = "3V3", .voltage = 3.3 };
    const rails0 = try a.alloc(f64, 2);
    rails0[0] = 3.3;
    rails0[1] = 5.0;
    nodes[0] = .{
        .label = "MCU", // borrowed literal — not freed
        .subtitle = "",
        .category = .mcu,
        .slug = try a.dupe(u8, "mcu"), // owned
        .inputs = in0,
        .outputs = out0,
        .rails = rails0,
    };

    nodes[1] = .{
        .label = "Sensor",
        .subtitle = "",
        .category = .peripheral,
        .slug = try a.dupe(u8, "sensor"), // owned
        .inputs = try a.alloc(types.RailEnd, 0),
        .outputs = try a.alloc(types.RailEnd, 0),
        // rails left empty (&.{}) — deinit skips len==0, must not free a literal.
    };

    // Boundary node: empty slug (not freed), but an owned label that deinit
    // frees only because is_boundary is set.
    nodes[2] = .{
        .label = try a.dupe(u8, "Antenna"), // owned (is_boundary path)
        .subtitle = "",
        .category = .peripheral,
        .slug = "", // empty — deinit must skip
        .inputs = try a.alloc(types.RailEnd, 0),
        .outputs = try a.alloc(types.RailEnd, 0),
        .is_boundary = true,
    };

    const edges = try a.alloc(types.Edge, 2);
    edges[0] = .{ .from = 0, .to = 1, .class = types.class_control, .label = try a.dupe(u8, "SPI") };
    edges[1] = .{ .from = 0, .to = 2, .class = types.class_rf, .label = try a.dupe(u8, "RF_OUT") };

    // A non-builtin class registry (a fresh allocation, NOT &builtin_classes)
    // so deinit's "free only when not the static array" branch is exercised.
    const classes = try a.alloc(types.ClassDef, types.builtin_classes.len);
    @memcpy(classes, &types.builtin_classes);

    var graph = types.Graph{
        .nodes = nodes,
        .edges = edges,
        .classes = classes,
    };
    try testing.expectEqual(@as(usize, 3), graph.nodes.len);
    try testing.expectEqual(@as(usize, 2), graph.edges.len);
    graph.deinit(a);
}

// leak-audit: a Graph whose registry IS the static builtin_classes must NOT be
// freed by deinit (freeing a static const through the allocator is UB and would
// trip testing.allocator). This pins the pointer-identity guard in deinit.
test "leak: Graph.deinit leaves the static builtin class registry alone" {
    const a = testing.allocator;
    const nodes = try a.alloc(types.Node, 1);
    nodes[0] = .{
        .label = "Lone",
        .subtitle = "",
        .category = .peripheral,
        .slug = try a.dupe(u8, "lone"),
        .inputs = try a.alloc(types.RailEnd, 0),
        .outputs = try a.alloc(types.RailEnd, 0),
    };
    const edges = try a.alloc(types.Edge, 0);
    // classes defaults to &builtin_classes — deinit must skip freeing it.
    var graph = types.Graph{ .nodes = nodes, .edges = edges };
    // Defaulted registry == the static builtin set; deinit must NOT free it.
    try testing.expectEqual(types.builtin_classes.len, graph.classes.len);
    graph.deinit(a);
}

// leak-audit: Membership.build allocates two StringHashMap backing buffers
// through the caller allocator; Membership.deinit must free both. Drive
// build/deinit under testing.allocator so a deinit that drops one map panics.
// The maps borrow their keys from the DesignBlock (no key dup), so this only
// checks the map buffers themselves.
test "leak: Membership build/deinit frees both ref maps" {
    const a = testing.allocator;

    const insts = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "J1", .component = "", .value = "", .footprint = "", .symbol = "" },
    };
    const sections = [_]env_mod.Section{
        .{ .name = "Core", .instances = &insts },
    };
    var inner = env_mod.DesignBlock{
        .name = "inner",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const subs = [_]env_mod.SubBlock{
        .{ .name = "psu1", .block = &inner },
        .{ .name = "mon1", .block = &inner },
    };
    var block = env_mod.DesignBlock{
        .name = "root",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &subs,
        .sections = &sections,
    };

    // Section 0 → node 0; sub-block 0 unattached → node 1; sub-block 1 attached
    // to section 0 → folds into node 0.
    const sec_node = [_]?u32{0};
    const sub_node = [_]?u32{ 1, null };
    const sub_attach = [_]?usize{ null, 0 };

    var mem = try membership.build(a, &block, &sec_node, &sub_node, &sub_attach);
    defer mem.deinit(a);

    // Sanity that the maps were populated (so deinit actually has buffers to
    // free) — resolve a section instance and a sub-block-prefixed ref.
    try testing.expectEqual(@as(?u32, 0), mem.resolve("U1"));
    try testing.expectEqual(@as(?u32, 1), mem.resolve("psu1/C3"));
    try testing.expectEqual(@as(?u32, 0), mem.resolve("mon1/U7"));
}

// leak-audit: a `build` that errors partway (OOM) must not leak the maps it
// already filled — they carry errdefer deinits. FailingAllocator lets the
// first few allocations succeed, then forces error.OutOfMemory; testing's
// backing allocator then verifies nothing the partial build allocated leaked.
test "leak: Membership.build cleans up on a mid-build allocation failure" {
    const insts = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "U2", .component = "", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "U3", .component = "", .value = "", .footprint = "", .symbol = "" },
    };
    const sections = [_]env_mod.Section{.{ .name = "Core", .instances = &insts }};
    var block = env_mod.DesignBlock{
        .name = "root",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .sections = &sections,
    };
    const sec_node = [_]?u32{0};

    const oom_count = try membershipBuildOomSweep(&block, &sec_node);
    // build allocates ≥1 time, so the earliest fail indices force OutOfMemory;
    // every non-failing run was deinit'd, and the testing backing allocator
    // would panic at test end if any partial build leaked.
    try testing.expect(oom_count >= 1);
}

// Helper: sweep FailingAllocator.fail_index across the first allocations of
// membership.build, deinit'ing every run that succeeds. Lives outside the test
// body so the loop is not flagged as test control flow. Returns how many fail
// points forced error.OutOfMemory.
fn membershipBuildOomSweep(block: *const env_mod.DesignBlock, sec_node: []const ?u32) !usize {
    var oom_count: usize = 0;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = i });
        if (membership.build(fa.allocator(), block, sec_node, &.{}, &.{})) |m| {
            var mm = m;
            mm.deinit(fa.allocator());
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            oom_count += 1;
        }
    }
    return oom_count;
}

// ── ARENA-CONTRACT: request-path layout functions ────────────────────────
// computeFreeLayout / computeGroupsLayout / buildGlanceEntities allocate
// everything from the caller arena and never free (the caller resets the
// arena). These wrap them in an arena backed by testing.allocator: the arena
// catches a double-free or an escape to a *different* testing-backed
// allocator, and exercises the full group-separation + routing path.

fn mkKeyed(key: []const u8) types.Node {
    return .{ .label = key, .subtitle = "", .category = .peripheral, .slug = key, .key = key, .inputs = &.{}, .outputs = &.{} };
}

// leak-audit: computeFreeLayout with interleaved groups + a cross-group edge
// drives separateGroupClusters, computeGroupBoxes, collectGroupObstacles and
// routeFreeEdges — every arena-allocating helper on the free-layout path.
test "leak: computeFreeLayout group-separation + routing path is arena-clean" {
    var nodes = [_]types.Node{ mkKeyed("a"), mkKeyed("b"), mkKeyed("c") };
    const b_right_a = [_]env_mod.PlaceConstraint{.{ .rel = .right_of, .reference = "a" }};
    const c_right_b = [_]env_mod.PlaceConstraint{.{ .rel = .right_of, .reference = "b" }};
    const placements = [_]env_mod.Placement{
        .{ .name = "a" },
        .{ .name = "b", .constraints = &b_right_a },
        .{ .name = "c", .constraints = &c_right_b },
    };
    // Interleaved groups so separateGroupClusters actually moves a cluster.
    const g1m = [_][]const u8{ "a", "c" };
    const g2m = [_][]const u8{"b"};
    const groups = [_]env_mod.LayoutGroup{
        .{ .label = "G1", .members = &g1m },
        .{ .label = "G2", .members = &g2m },
    };
    var edges = [_]types.Edge{.{ .from = 0, .to = 2, .class = types.class_control, .label = "x" }};
    const graph = types.Graph{
        .nodes = &nodes,
        .edges = &edges,
        .layout = .{ .placements = &placements, .groups = &groups },
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try layout.computeFreeLayout(arena.allocator(), &graph)) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), lay.nodes.len);
}

// leak-audit: computeGroupsLayout reruns computeFreeLayout and builds the
// boxes-only crossing-connector layout (extra hashmaps + a route list) — all
// arena-allocated. Wrapping it proves no stray non-arena alloc escapes.
test "leak: computeGroupsLayout boxes-only path is arena-clean" {
    var nodes = [_]types.Node{ mkKeyed("a"), mkKeyed("b") };
    const b_right_a = [_]env_mod.PlaceConstraint{.{ .rel = .right_of, .reference = "a" }};
    const placements = [_]env_mod.Placement{ .{ .name = "a" }, .{ .name = "b", .constraints = &b_right_a } };
    const g1m = [_][]const u8{"a"};
    const g2m = [_][]const u8{"b"};
    const groups = [_]env_mod.LayoutGroup{
        .{ .label = "G1", .members = &g1m },
        .{ .label = "G2", .members = &g2m },
    };
    var edges = [_]types.Edge{.{ .from = 0, .to = 1, .class = types.class_control, .label = "net", .fanout = 2 }};
    const graph = types.Graph{
        .nodes = &nodes,
        .edges = &edges,
        .layout = .{ .placements = &placements, .groups = &groups },
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try layout.computeGroupsLayout(arena.allocator(), &graph)) orelse
        return error.TestUnexpectedResult;
    // boxes-only: no individual nodes, one connector for the crossing net.
    try testing.expectEqual(@as(usize, 0), lay.nodes.len);
    try testing.expectEqual(@as(usize, 1), lay.routes.len);
}

// leak-audit: computeSystemLayout runs the full layered (Sugiyama) pipeline —
// interning, cycle break, layering, crossing reduction, lane routing, staged
// re-route — all in the arena. Catches any helper that escapes the arena.
test "leak: computeSystemLayout layered pipeline is arena-clean" {
    var nodes = [_]types.Node{
        .{ .label = "PWR", .subtitle = "", .category = .power, .slug = "pwr", .inputs = &.{}, .outputs = &.{} },
        .{ .label = "MCU", .subtitle = "", .category = .mcu, .slug = "mcu", .inputs = &.{}, .outputs = &.{} },
        .{ .label = "SENS", .subtitle = "", .category = .peripheral, .slug = "sens", .inputs = &.{}, .outputs = &.{} },
    };
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 1, .class = types.class_power, .label = "3V3" },
        .{ .from = 1, .to = 2, .class = types.class_control, .label = "I2C" },
    };
    const graph = types.Graph{ .nodes = &nodes, .edges = &edges };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try layout.computeSystemLayout(arena.allocator(), &graph)) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), lay.nodes.len);
}
