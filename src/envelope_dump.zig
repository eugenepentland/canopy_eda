//! `netlisp envelopes` — every flattened net's DC voltage envelope, in one run.
//!
//!   netlisp envelopes [--project-dir <dir>] [--text] <design>…
//!
//! ## Why this exists
//!
//! The envelope of ONE net has always been readable: `netlisp net <design>
//! <net>` carries an `"envelope"` object, and `mcp_flatten.writeNetEnvelope`
//! writes it. There was no way to read them ALL. Answering "which nets' derived
//! envelopes moved between these two binaries" therefore meant driving 1,863
//! separate `netlisp net` invocations off a `netlist-dump`, each one re-reading
//! the project, re-evaluating the design and re-flattening the hierarchy — about
//! ten minutes per binary, twenty for the comparison the question actually was.
//!
//! Here the design is evaluated ONCE and every flat net is answered from that
//! one evaluation, so the same comparison is two commands and a `diff`.
//!
//! ## The identity claim
//!
//! The per-net `"envelope"` object is written by `mcp_flatten.writeNetEnvelope`
//! — the exact function `netlisp net` calls — against the exact block. It is
//! not a second renderer that agrees today: a bulk value and a single-net value
//! cannot differ, because only one of them exists.
//!
//! The net universe is `flat_netlist.flattenAndMergeNets`, which is the same
//! flatten `eval/net_envelopes.build` keys its table by and the same one the
//! netlist exporter, the placer and `netlist-dump` see. So a name printed here
//! is a name those surfaces will look up, `sub-block/` prefix and
//! `(bridge (rename …))` canonicalisation included.
//!
//! ## Unknown is not zero
//!
//! A net nothing bounds prints `"envelope": null` (JSON) or `unknown` (text).
//! It never prints `lo=0 hi=0`: "this node's potential is unproven" and "this
//! node is at ground" are different facts, and a rating check that confuses
//! them passes a part it should have failed. The `counts` block reports the
//! unknown total outright so a sweep can see coverage change.
//!
//! Output is READ-ONLY and deterministic: nets sort by name, and no timing
//! appears on stdout in JSON mode (it goes to stderr) so two runs of the same
//! design produce byte-identical bytes. `--text` follows `netlist-dump`'s
//! convention instead — `#` lines carry the timings, so `diff -I '^#'`
//! compares the envelopes alone.

const std = @import("std");
const clock = @import("infra/clock.zig");
const infra_fs = @import("infra/fs.zig");
const log = @import("infra/log.zig");
const dump_args = @import("dump_args.zig");
const flat_netlist = @import("flat_netlist.zig");
const json_writer = @import("json_writer.zig");
const mcp_flatten = @import("serve/mcp_flatten.zig");
const modules_mod = @import("serve/modules.zig");
const net_envelopes = @import("eval/net_envelopes.zig");
const pcb_layout_page = @import("serve/pcb_layout_page.zig");
const env_mod = @import("eval/env.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;

const ns_per_ms: f64 = 1_000_000.0;

pub const DumpError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    error{ EnvelopeDumpUsage, UnresolvedDesign };

const Args = struct {
    project_dir: []const u8 = "projects/designs",
    /// Emit the diffable one-line-per-net form instead of JSON.
    text: bool = false,
    names: []const []const u8 = &.{},
};

/// `envelopes`' own flag, offered each argument before the shared scan.
fn takeEnvelopeFlag(out: *Args, args: []const []const u8, i: *usize) bool {
    if (!std.mem.eql(u8, args[i.*], "--text")) return false;
    out.text = true;
    return true;
}

fn parseArgs(arena: std.mem.Allocator, args: []const []const u8) DumpError!Args {
    var out: Args = .{};
    var common: dump_args.Common = .{};
    if (!try common.parse(arena, args, &out, takeEnvelopeFlag)) return error.EnvelopeDumpUsage;
    out.project_dir = common.project_dir;
    out.names = common.named.items;
    return out;
}

fn lessNet(_: void, a: flat_netlist.FlatNet, b: flat_netlist.FlatNet) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// How many of `nets` a lookup can bound. The JSON and text forms both report
/// it, so a coverage change is visible without parsing every row.
fn knownCount(block: *const env_mod.DesignBlock, nets: []const flat_netlist.FlatNet) usize {
    var known: usize = 0;
    for (nets) |net| {
        if (net_envelopes.lookup(block, net.name) != null) known += 1;
    }
    return known;
}

/// One design's nets as a JSON object. `nets` must already be sorted.
///
/// The `"envelope"` value is `writeNetEnvelope`'s, verbatim — see the module
/// comment. `bounded` and `domain` sit OUTSIDE it precisely so that object
/// stays the single-net answer byte for byte while this view can still carry
/// the two correlation facts a whole-board sweep is the only reader of.
fn writeDesignJson(
    w: *std.Io.Writer,
    name: []const u8,
    block: *const env_mod.DesignBlock,
    nets: []const flat_netlist.FlatNet,
) DumpError!void {
    try w.writeAll("{\"design\":");
    try json_writer.writeString(w, name);
    try w.writeAll(",\"nets\":[");
    for (nets, 0..) |net, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"net\":");
        try json_writer.writeString(w, net.name);
        // The comma belongs to writeNetEnvelope's own `,"envelope":` prefix.
        try mcp_flatten.writeNetEnvelope(w, block, net.name);
        const found = net_envelopes.lookup(block, net.name);
        try w.print(",\"bounded\":{},\"domain\":{d},\"pads\":{d}}}", .{
            if (found) |f| f.bounded else false,
            if (found) |f| f.domain else 0,
            net.pins.len,
        });
    }
    const known = knownCount(block, nets);
    try w.print("],\"counts\":{{\"nets\":{d},\"bounded\":{d},\"unknown\":{d}}}}}", .{
        nets.len, known, nets.len - known,
    });
}

/// One design's nets as `diff -I '^#'`-comparable lines, `netlist-dump` style.
fn writeDesignText(
    w: *std.Io.Writer,
    name: []const u8,
    block: *const env_mod.DesignBlock,
    nets: []const flat_netlist.FlatNet,
) DumpError!void {
    for (nets) |net| {
        try w.print("{s} envelope {s} ", .{ name, net.name });
        const found = net_envelopes.lookup(block, net.name) orelse {
            // Never `lo=0 hi=0`: unproven is its own state.
            try w.writeAll("unknown\n");
            continue;
        };
        try w.print("lo={d} hi={d} source={s} bounded={} domain={d} origin={s} path={s}\n", .{
            found.min,
            found.max,
            if (found.origin == .declared) "authored" else "derived",
            found.bounded,
            found.domain,
            if (found.provenance.rule.len > 0) found.provenance.rule else "-",
            if (found.provenance.root.len > 0) found.provenance.root else found.net,
        });
    }
}

/// Evaluate `name` once and write every net's envelope. Returns false when the
/// design never resolved, so the run can fail rather than compare nothing.
fn dumpOne(
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    args: Args,
    name: []const u8,
    first: bool,
) DumpError!bool {
    var eval = Evaluator.init(alloc, args.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const t0 = clock.nanoTimestamp();
    const block = pcb_layout_page.resolveBlock(alloc, args.project_dir, name, &eval, &module_res) orelse {
        if (args.text) {
            try w.print("# {s} UNRESOLVED\n", .{name});
        } else {
            if (!first) try w.writeAll(",");
            try w.writeAll("{\"design\":");
            try json_writer.writeString(w, name);
            try w.writeAll(",\"error\":\"unresolved\"}");
        }
        return false;
    };
    var nets: std.ArrayList(flat_netlist.FlatNet) = .empty;
    try flat_netlist.flattenAndMergeNets(alloc, block, &nets);
    std.mem.sort(flat_netlist.FlatNet, nets.items, {}, lessNet);
    const ns = clock.nanoTimestamp() - t0;
    const ms = @as(f64, @floatFromInt(ns)) / ns_per_ms;

    if (args.text) {
        try w.print("# {s} ms={d:.1} nets={d} unknown={d}\n", .{
            name, ms, nets.items.len, nets.items.len - knownCount(block, nets.items),
        });
        try writeDesignText(w, name, block, nets.items);
    } else {
        if (!first) try w.writeAll(",");
        try writeDesignJson(w, name, block, nets.items);
        // stdout stays byte-identical across runs of the same design, so the
        // one number that cannot be reproducible goes to the other stream.
        var buf: [256]u8 = undefined;
        log.emitLine(&buf, std.fmt.bufPrint(&buf, "# {s} ms={d:.1} nets={d}\n", .{ name, ms, nets.items.len }));
    }
    return true;
}

fn runParsed(allocator: std.mem.Allocator, w: *std.Io.Writer, parsed: Args) DumpError!void {
    var unresolved: usize = 0;
    if (!parsed.text) try w.writeAll("{\"designs\":[");
    for (parsed.names, 0..) |name, i| {
        // A per-design arena, for `netlist-dump`'s reason: a large board's
        // evaluated AST plus its flattened netlist runs to hundreds of
        // megabytes, and a corpus sweep must peak at one design's worth.
        var design_state = std.heap.ArenaAllocator.init(allocator);
        defer design_state.deinit();
        if (!try dumpOne(design_state.allocator(), w, parsed, name, i == 0)) unresolved += 1;
        try w.flush();
    }
    if (!parsed.text) try w.writeAll("]}\n");
    try w.flush();
    // A design that never resolved compared nothing; failing here is what stops
    // a sweep from reading an empty dump as "no envelope moved".
    if (unresolved > 0) return error.UnresolvedDesign;
}

/// CLI entry: `netlisp envelopes [--project-dir <dir>] [--text] <design>…`.
pub fn cmdEnvelopes(allocator: std.mem.Allocator, args: []const []const u8) DumpError!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const parsed = try parseArgs(arena_state.allocator(), args);

    var buf: [64 * 1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(infra_fs.currentIo(), &buf);
    try runParsed(allocator, &fw.interface, parsed);
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A block carrying one published envelope table, enough for the renderers.
fn fixtureBlock(envelopes: []const env_mod.NetEnvelope) env_mod.DesignBlock {
    return .{
        .name = "demo",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .envelopes = .{ .published = envelopes },
    };
}

fn renderJson(nets: []const flat_netlist.FlatNet, block: *const env_mod.DesignBlock) ![]u8 {
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    errdefer out.deinit();
    try writeDesignJson(&out.writer, "demo", block, nets);
    return out.toOwnedSlice();
}

// spec: envelope dump - the CLI parses the project dir and text flag with positionals as design names and refuses a run that names no design
test "envelopes CLI parses flags and positionals" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = try parseArgs(arena, &.{ "--project-dir", "p", "--text", "board-a", "board-b" });
    try testing.expectEqualStrings("p", parsed.project_dir);
    try testing.expect(parsed.text);
    try testing.expectEqual(@as(usize, 2), parsed.names.len);
    try testing.expectEqualStrings("board-b", parsed.names[1]);
    try testing.expect(!(try parseArgs(arena, &.{"b"})).text);
    try testing.expectEqualStrings("projects/designs", (try parseArgs(arena, &.{"b"})).project_dir);
    // Naming no design, or an unknown flag, is a usage error rather than a
    // silent empty dump that any diff would call clean.
    try testing.expectError(error.EnvelopeDumpUsage, parseArgs(arena, &.{"--text"}));
    try testing.expectError(error.EnvelopeDumpUsage, parseArgs(arena, &.{ "--wat", "b" }));
}

// spec: envelope dump - a bulk row carries the same envelope object the single-net query writes for that net
test "a bulk envelope row matches the single-net envelope byte for byte" {
    const envelopes = [_]env_mod.NetEnvelope{
        .{ .net = "buck/VIN_F", .min = 10.8, .max = 13.2, .provenance = .{ .rule = "ferrite", .root = "V_12V" } },
    };
    const block = fixtureBlock(&envelopes);
    const nets = [_]flat_netlist.FlatNet{.{ .name = "buck/VIN_F", .pins = &.{} }};
    const bulk = try renderJson(&nets, &block);
    defer testing.allocator.free(bulk);

    // The single-net answer, produced by the very function `netlisp net` calls.
    var single = std.Io.Writer.Allocating.init(testing.allocator);
    defer single.deinit();
    try mcp_flatten.writeNetEnvelope(&single.writer, &block, "buck/VIN_F");
    try testing.expect(std.mem.indexOf(u8, bulk, single.written()) != null);
}

// spec: envelope dump - a net nothing bounds reports an explicit unknown rather than a zero-volt envelope
test "an unbounded net is unknown, never zero" {
    const block = fixtureBlock(&.{});
    const nets = [_]flat_netlist.FlatNet{.{ .name = "MYSTERY", .pins = &.{} }};
    const json = try renderJson(&nets, &block);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"envelope\":null") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"lo\":0") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"unknown\":1") != null);

    var text = std.Io.Writer.Allocating.init(testing.allocator);
    defer text.deinit();
    try writeDesignText(&text.writer, "demo", &block, &nets);
    try testing.expectEqualStrings("demo envelope MYSTERY unknown\n", text.written());
}

// spec: envelope dump - a ground-class name is bounded at zero volts and counted as known
test "a ground-class net is bounded at zero and not counted unknown" {
    const block = fixtureBlock(&.{});
    const nets = [_]flat_netlist.FlatNet{.{ .name = "GND", .pins = &.{} }};
    const json = try renderJson(&nets, &block);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"lo\":0,\"hi\":0") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"unknown\":0") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"bounded\":1") != null);
}

// spec: envelope dump - hierarchical and non-ASCII net names survive the JSON encoding
test "hierarchical and unicode net names survive the dump" {
    const envelopes = [_]env_mod.NetEnvelope{
        .{ .net = "µctrl/VDD\"x", .min = 3.0, .max = 3.6, .provenance = .{ .rule = "rail", .root = "V_3V3" } },
    };
    const block = fixtureBlock(&envelopes);
    const nets = [_]flat_netlist.FlatNet{.{ .name = "µctrl/VDD\"x", .pins = &.{} }};
    const json = try renderJson(&nets, &block);
    defer testing.allocator.free(json);
    // The multi-byte name is carried through, and the embedded quote is escaped
    // rather than closing the string.
    try testing.expect(std.mem.indexOf(u8, json, "µctrl/VDD\\\"x") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"hi\":3.6") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const row = parsed.value.object.get("nets").?.array.items[0].object;
    try testing.expectEqualStrings("µctrl/VDD\"x", row.get("net").?.string);
}

// spec: envelope dump - nets sort by name so two runs of one design compare byte for byte
test "the dump is deterministic and sorted regardless of net order" {
    const envelopes = [_]env_mod.NetEnvelope{
        .{ .net = "A_NET", .min = 0, .max = 5 },
        .{ .net = "Z_NET", .min = 0, .max = 12 },
    };
    const block = fixtureBlock(&envelopes);
    var forward = [_]flat_netlist.FlatNet{
        .{ .name = "A_NET", .pins = &.{} },
        .{ .name = "Z_NET", .pins = &.{} },
    };
    var reversed = [_]flat_netlist.FlatNet{
        .{ .name = "Z_NET", .pins = &.{} },
        .{ .name = "A_NET", .pins = &.{} },
    };
    std.mem.sort(flat_netlist.FlatNet, &reversed, {}, lessNet);
    const a = try renderJson(&forward, &block);
    defer testing.allocator.free(a);
    const b = try renderJson(&reversed, &block);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
    try testing.expect(std.mem.indexOf(u8, a, "A_NET").? < std.mem.indexOf(u8, a, "Z_NET").?);
}

// spec: envelope dump - a design that fails to resolve fails the run instead of emitting an empty comparison
test "an unresolvable design fails the envelope dump instead of passing vacuously" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const parsed = try parseArgs(arena_state.allocator(), &.{ "--project-dir", "/nonexistent-netlisp-project", "no-such-design" });
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.UnresolvedDesign, runParsed(testing.allocator, &out.writer, parsed));
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"error\":\"unresolved\"") != null);
}
