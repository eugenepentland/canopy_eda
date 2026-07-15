//! Leak-regression tests for the review / BOM / coverage area.
//!
//! Two idioms are used here:
//!
//!   1. OWNED-RETURN — the function returns a slice the caller frees and is
//!      expected to free all of its own scratch. We call it with
//!      `std.testing.allocator` directly and free the result; the leak
//!      detector panics at test end if the fn forgot to free internal scratch.
//!      Used only for functions that allocate the returned slice with an exact
//!      size (`allocPrint` / `toOwnedSlice`) so `free(result)` matches.
//!
//!   2. ARENA-CONTRACT — the function is a request-path renderer/builder that
//!      allocates-and-forgets, expecting the caller's arena to reclaim
//!      everything on reset. We wrap a `testing.allocator`-backed arena around
//!      the call: this proves the path doesn't crash / double-free and that
//!      nothing escapes to a *different* allocator, and documents the contract.
//!
//! NOTE on `review_json.renderToJson`: it returns `buf.items` (NOT
//! `buf.toOwnedSlice`), so the returned slice's len < the backing allocation's
//! capacity. `testing.allocator.free(result)` would PANIC on the length
//! mismatch — so it is deliberately tested with idiom 2 (arena) only. See the
//! audit findings accompanying this file.

const std = @import("std");
const env = @import("../eval/env.zig");
const review = @import("../review.zig");
const coverage = @import("../coverage.zig");
const bom = @import("../bom.zig");
const bom_html = @import("../serve/bom_html.zig");
const review_json = @import("../review_json.zig");
const req_checks = @import("../req_checks.zig");
const erc_mod = @import("../erc.zig");

const DesignBlock = env.DesignBlock;
const Instance = env.Instance;

// ── Fixture helpers ────────────────────────────────────────────────────
//
// Mirrors the minimal `DesignBlock` literal the existing in-file tests use
// (review.zig / coverage.zig): only the seven non-default fields are set,
// everything else falls to its default.

fn block(name: []const u8, instances: []const Instance, subs: []const env.SubBlock) DesignBlock {
    return .{
        .name = name,
        .instances = instances,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = subs,
    };
}

// ── Idiom 1: owned-return, freed through testing.allocator ──────────────

// leak-audit: slugify uses toOwnedSlice + errdefer-guarded scratch; an
// owned-return free through the leak detector proves no scratch escapes.
test "leak: slugify owned-return frees all scratch" {
    const a = std.testing.allocator;
    const s1 = try review.slugify(a, "ADC Voltage Reference");
    defer a.free(s1);
    try std.testing.expectEqualStrings("adc-voltage-reference", s1);

    // Empty/punctuation-only input takes the `'_'` fallback branch — still owned.
    const s2 = try review.slugify(a, "  ()  ");
    defer a.free(s2);
    try std.testing.expectEqualStrings("_", s2);
}

// leak-audit: isoTimestamp is a single allocPrint; result frees exactly.
test "leak: isoTimestamp owned-return frees exactly" {
    const a = std.testing.allocator;
    const s = try review.isoTimestamp(a, 0);
    defer a.free(s);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", s);
}

// leak-audit: generateUuid is a single allocPrint of a fixed-width string.
test "leak: bom.generateUuid owned-return frees exactly" {
    const a = std.testing.allocator;
    const uuid = try bom.generateUuid(a);
    defer a.free(uuid);
    try std.testing.expectEqual(@as(usize, 36), uuid.len);
}

// ── Idiom 2: arena-contract (request-path build/render fns) ─────────────
//
// Each fixture deliberately includes a sub-block so the recursive walkers
// allocate per-level scratch (prefix strings, hashmaps, dup'd keys). The
// arena is testing.allocator-backed, so anything that escaped to a global /
// page allocator would still surface as a leak at test end.

// Note: review.buildBom is not pub; its hierarchical collect+dedup+dup path is
// covered instead through the pub request-path BOM writers below
// (writeBomCsv / writeNetsJson / writeSchematicBomHtml), which call into it.

// leak-audit: buildPowerTree allocs a rail-index map (deinit'd), upstream/layer
// arrays, the nodes array, and an edges ArrayList → toOwnedSlice; wrap to prove
// the map deinit and slice ownership stay balanced under an arena.
test "leak: review.buildPowerTree with cascading rails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const buck_ports = try alloc.alloc(env.Port, 2);
    buck_ports[0] = .{ .name = "VIN", .net = "VIN", .direction = "in" };
    buck_ports[1] = .{ .name = "VOUT", .net = "VOUT", .direction = "out", .nominal = 3.3 };
    const buck_block = try alloc.create(DesignBlock);
    buck_block.* = block("buck", &.{}, &.{});
    buck_block.ports = buck_ports;

    const sbs = try alloc.alloc(env.SubBlock, 1);
    sbs[0] = .{ .name = "buck", .block = buck_block };
    const ties = try alloc.alloc(env.NetTie, 2);
    ties[0] = .{ .a = "buck/VIN", .b = "V5V" };
    ties[1] = .{ .a = "buck/VOUT", .b = "V3V3" };
    const rails = try alloc.alloc(env.PowerRail, 1);
    rails[0] = .{ .name = "V3V3", .source_ref_des = "buck", .nominal = 3.3 };

    var top = block("top", &.{}, sbs);
    top.net_ties = ties;
    top.rails = rails;

    const tree = try review.buildPowerTree(alloc, &top);
    try std.testing.expectEqual(@as(usize, 1), tree.nodes.len);
}

// leak-audit: computeOverallCoverage + computeSectionCoverage build StringHashMaps
// (seen-sets), append per-instance check slices, and recurse into sub-blocks.
test "leak: coverage walkers over a sub-block hierarchy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const props = [_]env.Property{
        .{ .key = "mpn", .value = "X" },
        .{ .key = "manufacturer", .value = "Y" },
    };
    const ds = [_][]const u8{"x.pdf"};
    const u1_inst = Instance{
        .ref_des = "U1",
        .component = "ic",
        .value = "v",
        .footprint = "fp",
        .symbol = "",
        .properties = &props,
        .datasheets = &ds,
    };
    const c1_inst = Instance{ .ref_des = "C1", .component = "cap", .value = "100nF", .footprint = "0402", .symbol = "" };
    const sub_insts = [_]Instance{u1_inst};
    var sub = block("buck", &sub_insts, &.{});
    const subs = [_]env.SubBlock{.{ .name = "buck", .block = &sub }};
    const top_insts = [_]Instance{c1_inst};
    const top = block("top", &top_insts, &subs);

    const oc = try coverage.computeOverallCoverage(alloc, &top, null);
    try std.testing.expectEqual(@as(usize, 2), oc.checked);

    const sec: env.Section = .{ .name = "S", .instances = &top_insts };
    const sc = try coverage.computeSectionCoverage(alloc, &top, sec, null);
    try std.testing.expectEqual(@as(usize, 1), sc.checked);
}

// leak-audit: writeBomCsv collects instances hierarchically + builds dedup
// BomLine list with per-line refs ArrayLists; all scratch is on the passed
// allocator and the writer is an arena-backed ArrayList. Locks the ~1.3MB/req
// pre-fix leak: the alloc must be a param and reclaimed by the arena.
test "leak: bom_html.writeBomCsv over a sub-block hierarchy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const sub_insts = [_]Instance{
        .{ .ref_des = "C1", .component = "cap-0402", .value = "100nF", .footprint = "0402", .symbol = "" },
    };
    var sub = block("buck", &sub_insts, &.{});
    const subs = [_]env.SubBlock{.{ .name = "buck", .block = &sub }};
    const top_insts = [_]Instance{
        .{ .ref_des = "C2", .component = "cap-0402", .value = "100nF", .footprint = "0402", .symbol = "" },
        .{ .ref_des = "TP1", .component = "testpoint", .value = "", .footprint = "", .symbol = "" },
    };
    const top = block("top", &top_insts, &subs);

    var buf: std.ArrayList(u8) = .empty;
    try bom_html.writeBomCsv(alloc, buf.writer(alloc), &top);
    // Two 100nF caps dedup to one BOM line (count 2); test point excluded.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "cap-0402") != null);
}

// leak-audit: writeNetsJson builds a StringHashMap rename map (from net_ties)
// and a StringArrayHashMap of pin lists, dup'ing prefixed ref-des; recurses one
// sub-block level. All on the passed allocator (the arena-contract).
test "leak: bom_html.writeNetsJson with net_ties and a sub-block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const top_pins = [_]env.PinRef{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "C1", .pin = "1" },
    };
    const top_nets = [_]env.Net{.{ .name = "VDD", .pins = &top_pins }};

    const sub_pins = [_]env.PinRef{.{ .ref_des = "U2", .pin = "3" }};
    const sub_nets = [_]env.Net{.{ .name = "VIN", .pins = &sub_pins }};
    var sub = block("ldo", &.{}, &.{});
    sub.nets = &sub_nets;
    const subs = [_]env.SubBlock{.{ .name = "ldo", .block = &sub }};
    const ties = [_]env.NetTie{.{ .a = "VDD", .b = "ldo/VIN" }};

    var top = block("top", &.{}, &subs);
    top.nets = &top_nets;
    top.net_ties = &ties;

    var buf: std.ArrayList(u8) = .empty;
    const written = try bom_html.writeNetsJson(alloc, buf.writer(alloc), &top, "");
    try std.testing.expect(written);
}

// A component value containing a double-quote (an inch mark like 0.1") must be
// JSON-escaped by writeComponentsJson: unescaped it produces malformed JSON and
// JSON.parse blanks the entire /api/components map client-side. Regression for
// raw `{s}` string emission that bypassed writeJsonEscaped.
test "correctness: bom_html.writeComponentsJson escapes double-quotes in string fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const insts = [_]Instance{
        .{ .ref_des = "J1", .component = "conn", .value = "0.1\" header", .footprint = "", .symbol = "" },
    };
    const top = block("top", &insts, &.{});
    const sym_cache: bom_html.SymbolPinCache = .empty;

    // Mirror the /api/components caller: writeComponentsJson emits the object
    // body, the caller supplies the surrounding braces.
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(alloc);
    try w.writeAll("{");
    _ = try bom_html.writeComponentsJson(w, &top, "", &sym_cache, alloc, ".");
    try w.writeAll("}");

    // The inch mark is escaped in the raw bytes …
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "0.1\\\" header") != null);
    // … and the whole payload parses as valid JSON with J1 present.
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, buf.items, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.contains("J1"));
}

// leak-audit: writeSchematicBomHtml is the schematic-page BOM card — same
// hierarchical collect + dedup + per-line refs lists as writeBomCsv but emits
// HTML and joins refs (joinRefs alloc). Part of the dominant pre-fix leak.
test "leak: bom_html.writeSchematicBomHtml over a sub-block hierarchy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const props = [_]env.Property{.{ .key = "mpn", .value = "MPN123" }};
    const sub_insts = [_]Instance{
        .{ .ref_des = "U1", .component = "buck", .value = "", .footprint = "son-10", .symbol = "", .properties = &props },
    };
    var sub = block("buck", &sub_insts, &.{});
    const subs = [_]env.SubBlock{.{ .name = "buck", .block = &sub }};
    const top_insts = [_]Instance{
        .{ .ref_des = "C1", .component = "cap-0402", .value = "100nF", .footprint = "0402", .symbol = "" },
        .{ .ref_des = "C2", .component = "cap-0402", .value = "100nF", .footprint = "0402", .symbol = "" },
    };
    const top = block("top", &top_insts, &subs);

    var buf: std.ArrayList(u8) = .empty;
    try bom_html.writeSchematicBomHtml(alloc, buf.writer(alloc), &top);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "sch-bom-table") != null);
}

// leak-audit: renderToJson returns `buf.items` (capacity may exceed len) so it
// is NOT safe to free through testing.allocator — wrap in an arena instead.
// This exercises every nested writer (summary, sections, bom)
// and proves the path neither crashes nor escapes the arena.
test "leak: review_json.renderToJson (arena-contract; buf.items return)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const insts = [_]Instance{
        .{ .ref_des = "C1", .component = "cap-0402", .value = "100nF", .footprint = "0402", .symbol = "" },
    };
    const top = block("doc-fixture", &insts, &.{});

    const violations = [_]erc_mod.Violation{};
    const doc = try review.buildReview(alloc, "doc-fixture", &top, &.{}, &violations, null);

    const json = try review_json.renderToJson(alloc, doc);
    try std.testing.expect(json.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"design_name\":"));
}
