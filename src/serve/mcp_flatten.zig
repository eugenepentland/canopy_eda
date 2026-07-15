//! Flattened introspection for the MCP read tools. `list_instances`,
//! `get_net`, and `list_free_pins` answer top-level-only by default, which
//! is misleading on a hierarchical design: sub-block children are invisible
//! and a rail merged across a `(net …)` tie shows only its top-level pins.
//! These helpers reuse the KiCad-export flattener (`collectInstances` /
//! `flattenAndMergeNets`) — the same machinery the PCB / netlist paths run —
//! so the netlist an agent reads is the netlist the board is built from.
//! Also home to the `list_free_pins` pin classifier, shared with the
//! top-level path in `mcp_tools.zig`.

const std = @import("std");
const env_mod = @import("../eval/env.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const ids = @import("../eval/ids.zig");
const json_writer = @import("../json_writer.zig");
const export_kicad = @import("../export_kicad.zig");
const netlist_mod = @import("../export_kicad_netlist.zig");

const FlatInstance = export_kicad.FlatInstance;
const FlatNet = export_kicad.FlatNet;

/// Open a JSON object whose first key is the flattened `ref_des`.
fn writeRefDesOpen(w: anytype, ref: []const u8) !void {
    try w.writeAll("{\"ref_des\":");
    try json_writer.writeString(w, ref);
}

// ── Pin classification (shared with the top-level list_free_pins) ───────

/// Best-effort classification of a pinout function name. Used by
/// `list_free_pins` to filter and annotate unassigned pins. Heuristics are
/// tuned for STM32 / common MCU pinouts and will degrade gracefully (return
/// `.other`) on unfamiliar names — callers should not treat this as authoritative.
pub const PinCategory = enum { gpio, power, clock, analog, other };

/// Classify a pinout function name into a `PinCategory` (best-effort).
pub fn classifyPin(function: []const u8) PinCategory {
    if (function.len == 0) return .other;
    // STM32-style port pin: P[A-Z][digits], optionally followed by alt-function text.
    if (function.len >= 3 and function[0] == 'P' and function[1] >= 'A' and function[1] <= 'Z') {
        var all_digits = true;
        for (function[2..]) |c| {
            if (c < '0' or c > '9') {
                all_digits = false;
                break;
            }
        }
        if (all_digits) return .gpio;
    }
    // Power: VDD, VSS, VCC, VBAT, VBUS, VREF, VDDA…
    if (std.mem.startsWith(u8, function, "V") and function.len >= 2) {
        const rest = function[1..];
        if (std.mem.startsWith(u8, rest, "DD")) return .power;
        if (std.mem.startsWith(u8, rest, "SS")) return .power;
        if (std.mem.startsWith(u8, rest, "CC")) return .power;
        if (std.mem.startsWith(u8, rest, "BAT")) return .power;
        if (std.mem.startsWith(u8, rest, "BUS")) return .power;
        if (std.mem.startsWith(u8, rest, "REF")) return .power;
    }
    if (std.mem.eql(u8, function, "GND") or std.mem.startsWith(u8, function, "GND_")) return .power;
    // Analog: ADC_IN*, A[DI]C prefix, AIN*
    if (std.mem.startsWith(u8, function, "ADC") or
        std.mem.startsWith(u8, function, "AIN") or
        std.mem.startsWith(u8, function, "DAC"))
        return .analog;
    // Clock: OSC*, XTAL*, CLK / CLKIN / CLKOUT prefix
    if (std.mem.startsWith(u8, function, "OSC") or
        std.mem.startsWith(u8, function, "XTAL") or
        std.mem.startsWith(u8, function, "CLK"))
        return .clock;
    return .other;
}

/// The stable string name for a `PinCategory` (matches the tool's enum arg).
pub fn categoryName(c: PinCategory) []const u8 {
    return switch (c) {
        .gpio => "gpio",
        .power => "power",
        .clock => "clock",
        .analog => "analog",
        .other => "other",
    };
}

// ── Shared pin-count / pinout resolution ────────────────────────────────

/// Resolve the `lib/pinouts/<key>.sexp` lookup key for a part: the
/// component's declared pinout name, then its symbol name, then the
/// instance's own symbol string. Resolving through the component's pinout
/// name (not just `symbol`) is what lets a connector that declares
/// `(pinout …)` but no `(symbol …)` still find its pads.
fn pinoutLookupName(eval: *Evaluator, component: []const u8, symbol: []const u8) []const u8 {
    if (eval.component_cache.get(component)) |cd| {
        if (cd.pinout_name.len > 0) return cd.pinout_name;
        if (cd.symbol_name.len > 0) return cd.symbol_name;
    }
    return symbol;
}

/// Pin count for an instance: the explicit multi-part pins when present, else
/// the size of the resolved pinout map. Fixes the `pin_count: 0` a connector
/// used to report — a part that declares `(pinout …)` but no `(symbol …)` has
/// an empty `symbol`, so the old symbol-only lookup found nothing.
pub fn instancePinCount(
    eval: *Evaluator,
    component: []const u8,
    symbol: []const u8,
    parts: []const env_mod.Part,
) usize {
    if (parts.len > 0) {
        var total: usize = 0;
        for (parts) |p| total += p.pins.len;
        return total;
    }
    const key = pinoutLookupName(eval, component, symbol);
    if (key.len == 0) return 0;
    if (ids.getSymbolPins(eval, key)) |pm| return pm.count();
    return 0;
}

// ── Flattened ref helpers ───────────────────────────────────────────────

/// The sub-block-relative leaf of a flattened ref-des ("ldo/U2" → "U2").
fn leafOf(ref: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, ref, '/')) |i| return ref[i + 1 ..];
    return ref;
}

/// ASCII case-insensitive slice equality (the ref-matching convention the
/// PCB tools use).
fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toUpper(x) != std.ascii.toUpper(y)) return false;
    return true;
}

/// A passive by the first letter of its leaf ref-des (R/L/C/F/D) — the
/// sub-block prefix on a flattened ref must not fool the classifier.
fn isPassiveLeaf(ref: []const u8) bool {
    const leaf = leafOf(ref);
    if (leaf.len == 0) return false;
    return switch (leaf[0]) {
        'R', 'L', 'C', 'F', 'D' => true,
        else => false,
    };
}

fn findFlatByRef(insts: []const FlatInstance, ref: []const u8) ?FlatInstance {
    for (insts) |fi| if (std.mem.eql(u8, fi.ref_des, ref)) return fi;
    return null;
}

/// Match a flattened instance the way the PCB tools match `refs=`: an exact
/// ref-des, then a sub-block leaf, then the stable module-local origin name —
/// all case-insensitive, exact pass first so a full ref never loses to a leaf.
fn findFlatByRefOrLeaf(insts: []const FlatInstance, ref: []const u8) ?FlatInstance {
    for (insts) |fi| if (eqIgnoreCase(fi.ref_des, ref)) return fi;
    for (insts) |fi| if (eqIgnoreCase(leafOf(fi.ref_des), ref)) return fi;
    for (insts) |fi| if (fi.origin_key.len > 0 and eqIgnoreCase(fi.origin_key, ref)) return fi;
    return null;
}

// ── Flattened tools ─────────────────────────────────────────────────────

/// Flattened `list_instances`: every instance in the whole design tree with
/// its sub-block-prefixed ref, module-local origin (null at top level),
/// component, symbol, value, and pin count.
pub fn listInstancesFlat(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const env_mod.DesignBlock,
    w: anytype,
) !bool {
    var list: std.ArrayList(FlatInstance) = .empty;
    try netlist_mod.collectInstances(allocator, block, "", &list, block.refStyle());

    try w.writeAll("{\"instances\":[");
    for (list.items, 0..) |fi, i| {
        if (i > 0) try w.writeAll(",");
        try writeRefDesOpen(w, fi.ref_des);
        try w.writeAll(",\"origin\":");
        if (fi.origin_key.len > 0) try json_writer.writeString(w, fi.origin_key) else try w.writeAll("null");
        try w.writeAll(",\"component\":");
        try json_writer.writeString(w, fi.component);
        try w.writeAll(",\"symbol\":");
        try json_writer.writeString(w, fi.symbol);
        try w.writeAll(",\"value\":");
        try json_writer.writeString(w, fi.value);
        const pc = instancePinCount(eval, fi.component, fi.symbol, &.{});
        try w.print(",\"pin_count\":{d}}}", .{pc});
    }
    try w.writeAll("]}");
    return true;
}

/// Resolve a net query to an index into the merged net list: exact canonical
/// name first, then a sub-scoped spelling ("ldo/VOUT") — locate the raw
/// pre-merge net of that name and follow one of its pins into the merged net
/// it was folded into.
fn resolveMergedNet(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    merged: []const FlatNet,
    query: []const u8,
) std.mem.Allocator.Error!?usize {
    for (merged, 0..) |n, i| {
        if (std.mem.eql(u8, n.name, query)) return i;
    }
    var raw: std.ArrayList(FlatNet) = .empty;
    try netlist_mod.collectNets(allocator, block, "", &raw, block.refStyle());
    for (raw.items) |rn| {
        if (!std.mem.eql(u8, rn.name, query)) continue;
        if (rn.pins.len == 0) continue;
        const p0 = rn.pins[0];
        for (merged, 0..) |mn, i| {
            for (mn.pins) |mp| {
                if (std.mem.eql(u8, mp.ref_des, p0.ref_des) and std.mem.eql(u8, mp.pin, p0.pin)) return i;
            }
        }
    }
    return null;
}

/// Flattened `get_net`: every pin on the merged rail (flattened refs +
/// resolved function names) plus the passives on it. `query` accepts the
/// canonical merged name or a sub-scoped spelling.
pub fn getNetFlat(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const env_mod.DesignBlock,
    query: []const u8,
    w: anytype,
) !bool {
    var nets: std.ArrayList(FlatNet) = .empty;
    try export_kicad.flattenAndMergeNets(allocator, block, &nets);

    const idx = (try resolveMergedNet(allocator, block, nets.items, query)) orelse {
        try w.writeAll("error: net not found");
        return false;
    };
    const net = nets.items[idx];

    var insts: std.ArrayList(FlatInstance) = .empty;
    try netlist_mod.collectInstances(allocator, block, "", &insts, block.refStyle());

    try w.writeAll("{\"name\":");
    try json_writer.writeString(w, net.name);
    try w.writeAll(",\"pins\":[");

    var passive_refs: std.StringHashMapUnmanaged(void) = .empty;
    defer passive_refs.deinit(allocator);

    for (net.pins, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        var fname: []const u8 = "";
        if (findFlatByRef(insts.items, p.ref_des)) |fi| {
            const key = pinoutLookupName(eval, fi.component, fi.symbol);
            if (key.len > 0) {
                if (ids.getSymbolPins(eval, key)) |pm| {
                    if (pm.get(p.pin)) |f| fname = f;
                }
            }
            if (isPassiveLeaf(fi.ref_des)) try passive_refs.put(allocator, fi.ref_des, {});
        }
        try writeRefDesOpen(w, p.ref_des);
        try w.writeAll(",\"pin\":");
        try json_writer.writeString(w, p.pin);
        try w.writeAll(",\"function\":");
        try json_writer.writeString(w, fname);
        try w.writeAll("}");
    }
    try w.writeAll("],\"passives\":[");

    var it = passive_refs.iterator();
    var first = true;
    while (it.next()) |e| {
        const fi = findFlatByRef(insts.items, e.key_ptr.*) orelse continue;
        if (!first) try w.writeAll(",");
        first = false;
        try writeRefDesOpen(w, fi.ref_des);
        try w.writeAll(",\"component\":");
        try json_writer.writeString(w, fi.component);
        try w.writeAll(",\"value\":");
        try json_writer.writeString(w, fi.value);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
    return true;
}

/// Emit one pin object of the free/assigned lists; `net` is null for a free pin.
fn emitFreePin(w: anytype, pin_id: []const u8, fname: []const u8, cat: PinCategory, net: ?[]const u8) !void {
    try w.writeAll("{\"pin\":");
    try json_writer.writeString(w, pin_id);
    try w.writeAll(",\"function\":");
    try json_writer.writeString(w, fname);
    if (net) |n| {
        try w.writeAll(",\"net\":");
        try json_writer.writeString(w, n);
    }
    try w.print(",\"category\":\"{s}\"}}", .{categoryName(cat)});
}

/// Flattened `list_free_pins`: `ref` matches a flattened instance by exact
/// ref / leaf / origin, and assignments come from the merged netlist, so a
/// sub-block child's assigned pins carry their canonical rail names.
pub fn listFreePinsFlat(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const env_mod.DesignBlock,
    ref_des: []const u8,
    filter: ?[]const u8,
    w: anytype,
) !bool {
    var insts: std.ArrayList(FlatInstance) = .empty;
    try netlist_mod.collectInstances(allocator, block, "", &insts, block.refStyle());

    const target = findFlatByRefOrLeaf(insts.items, ref_des) orelse {
        try w.writeAll("error: instance not found");
        return false;
    };

    const lookup_name = pinoutLookupName(eval, target.component, target.symbol);
    if (lookup_name.len == 0) {
        try w.writeAll("{\"free_pins\":[],\"assigned_pins\":[],\"note\":\"instance has no associated symbol pinout\"}");
        return true;
    }
    const pin_map = ids.getSymbolPins(eval, lookup_name) orelse {
        try w.writeAll("{\"free_pins\":[],\"assigned_pins\":[],\"note\":\"pinout file not found for symbol\"}");
        return true;
    };

    var nets: std.ArrayList(FlatNet) = .empty;
    try export_kicad.flattenAndMergeNets(allocator, block, &nets);
    var assigned: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer assigned.deinit(allocator);
    for (nets.items) |net| {
        for (net.pins) |p| {
            if (std.mem.eql(u8, p.ref_des, target.ref_des)) try assigned.put(allocator, p.pin, net.name);
        }
    }

    try w.writeAll("{\"free_pins\":[");
    var it = pin_map.iterator();
    var first = true;
    while (it.next()) |e| {
        const pin_id = e.key_ptr.*;
        if (assigned.contains(pin_id)) continue;
        const cat = classifyPin(e.value_ptr.*);
        if (filter) |f| if (!std.mem.eql(u8, f, categoryName(cat))) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try emitFreePin(w, pin_id, e.value_ptr.*, cat, null);
    }
    try w.writeAll("],\"assigned_pins\":[");
    var it2 = pin_map.iterator();
    var first2 = true;
    while (it2.next()) |e| {
        const pin_id = e.key_ptr.*;
        const net_name = assigned.get(pin_id) orelse continue;
        const cat = classifyPin(e.value_ptr.*);
        if (filter) |f| if (!std.mem.eql(u8, f, categoryName(cat))) continue;
        if (!first2) try w.writeAll(",");
        first2 = false;
        try emitFreePin(w, pin_id, e.value_ptr.*, cat, net_name);
    }
    try w.writeAll("]}");
    return true;
}

// ── Tests ───────────────────────────────────────────────────────────────

const ldochip_comp =
    \\(component "ldochip"
    \\  (description "test LDO IC")
    \\  (symbol ldochip)
    \\  (pinout ldochip)
    \\  (footprint fp-ldo)
    \\  (ignore-requirements))
;
const ldochip_pinout =
    \\(pinout "ldochip"
    \\  (pin 1 "VIN")
    \\  (pin 2 "VOUT")
    \\  (pin 3 "GND")
    \\  (pin 4 "EN")
    \\  (pin 5 "NC"))
;
const hdr4_comp =
    \\(component "hdr4"
    \\  (description "4-pin test header")
    \\  (pinout hdr4)
    \\  (footprint fp-hdr4)
    \\  (ignore-requirements))
;
const hdr4_pinout =
    \\(pinout "hdr4"
    \\  (pin 1 "1")
    \\  (pin 2 "2")
    \\  (pin 3 "3")
    \\  (pin 4 "4"))
;
const ldomod_src =
    \\(defmodule ldomod ((vout 3.3))
    \\  (design-block "LDO"
    \\    (instance "U1" ldochip
    \\      (pin 1 "VIN")
    \\      (pin 2 "VOUT")
    \\      (pin 3 "GND"))
    \\    (instance "C1" (cap-0402 "10uF")
    \\      (pin 1 "VOUT")
    \\      (pin 2 "GND"))
    \\    (port "VIN" in)
    \\    (port "VOUT" out)
    \\    (port "GND" bidi)))
;
const board_src =
    \\(import ldochip)
    \\(import hdr4)
    \\(import ldomod)
    \\(design-block "Flatten Test Board"
    \\  (instance "J1" hdr4
    \\    (pin 1 "VIN_5V")
    \\    (pin 2 "VIN_5V")
    \\    (pin 3 "GND")
    \\    (pin 4 "GND"))
    \\  (instance "D1" (led-0402 "green")
    \\    (pin 1 "V3P3")
    \\    (pin 2 "LED_K"))
    \\  (instance "R1" (res-0402 "1k")
    \\    (pin 1 "LED_K")
    \\    (pin 2 "GND"))
    \\  (sub-block "ldo" (ldomod))
    \\  (net "VIN_5V" "ldo/VIN")
    \\  (net "V3P3" "ldo/VOUT")
    \\  (net "GND" "ldo/GND"))
;

const cap_family =
    \\(component-family "cap-0402" (symbol generic-cap) (parameter "value" capacitance))
;
const res_family =
    \\(component-family "res-0402" (symbol generic-res) (parameter "value" resistance))
;
const led_family =
    \\(component-family "led-0402" (symbol generic-led) (parameter "color" string))
;

/// Write the full fixture project (passives + custom IC/connector + module +
/// design) under `dir`. Used by the flatten tests below.
fn writeFlattenFixture(dir: std.fs.Dir) !void {
    try dir.makePath("lib/components");
    try dir.makePath("lib/pinouts");
    try dir.makePath("lib/modules");
    try dir.makePath("src");
    try dir.writeFile(.{ .sub_path = "lib/components/cap-0402.sexp", .data = cap_family });
    try dir.writeFile(.{ .sub_path = "lib/components/res-0402.sexp", .data = res_family });
    try dir.writeFile(.{ .sub_path = "lib/components/led-0402.sexp", .data = led_family });
    try dir.writeFile(.{ .sub_path = "lib/components/ldochip.sexp", .data = ldochip_comp });
    try dir.writeFile(.{ .sub_path = "lib/pinouts/ldochip.sexp", .data = ldochip_pinout });
    try dir.writeFile(.{ .sub_path = "lib/components/hdr4.sexp", .data = hdr4_comp });
    try dir.writeFile(.{ .sub_path = "lib/pinouts/hdr4.sexp", .data = hdr4_pinout });
    try dir.writeFile(.{ .sub_path = "lib/modules/ldomod.sexp", .data = ldomod_src });
    try dir.writeFile(.{ .sub_path = "src/board.sexp", .data = board_src });
}

/// Eval `src/board.sexp` under `project` and return the design block. The
/// evaluator (which owns the block's memory) is returned so the caller keeps
/// it alive; project uses page_allocator because eval AST memory is never freed.
fn evalBoard(alloc: std.mem.Allocator, project: []const u8, eval: *Evaluator) !*env_mod.DesignBlock {
    const path = try std.fmt.allocPrint(alloc, "{s}/src/board.sexp", .{project});
    const result = try eval.evalFile(path);
    return switch (result) {
        .design_block => |b| b,
        else => error.TestNotADesign,
    };
}

test "flatten list_instances surfaces sub-block children with prefixed refs and origins" {
    // spec: serve/mcp_tools - flatten makes list_instances include sub-block children with prefixed refs and origins
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFlattenFixture(tmp.dir);
    const project = try tmp.dir.realpathAlloc(alloc, ".");

    var eval = Evaluator.init(alloc, project);
    defer eval.deinit();
    const block = try evalBoard(alloc, project, &eval);

    var out: std.ArrayList(u8) = .empty;
    try std.testing.expect(try listInstancesFlat(alloc, &eval, block, out.writer(alloc)));

    // The LDO module's children appear with sub-block-prefixed refs (renumbered
    // globally, e.g. ldo/U2) and their stable module-local origins (U1, C1) —
    // all invisible to the top-level-only listing.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"ref_des\":\"ldo/") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"origin\":\"U1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"origin\":\"C1\"") != null);
    // Top-level parts keep their refs.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"ref_des\":\"J1\"") != null);
    // The IC's pin count comes from its 5-pad pinout (only ldochip has 5 pads).
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"component\":\"ldochip\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"pin_count\":5") != null);
}

test "instancePinCount counts a connector's pads from its pinout when it has no symbol" {
    // spec: serve/mcp_tools - list_instances counts pins from the component pinout when the part declares no symbol
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFlattenFixture(tmp.dir);
    const project = try tmp.dir.realpathAlloc(alloc, ".");

    var eval = Evaluator.init(alloc, project);
    defer eval.deinit();
    const block = try evalBoard(alloc, project, &eval);

    // J1 is a pin header: it declares (pinout hdr4) but no (symbol …), so its
    // instance symbol is empty. The old symbol-only lookup returned 0.
    var j1: ?env_mod.Instance = null;
    for (block.instances) |inst| {
        if (std.mem.eql(u8, inst.ref_des, "J1")) j1 = inst;
    }
    try std.testing.expect(j1 != null);
    try std.testing.expectEqualStrings("", j1.?.symbol);
    try std.testing.expectEqual(@as(usize, 4), instancePinCount(&eval, j1.?.component, j1.?.symbol, j1.?.parts));
}

test "flatten get_net returns the merged rail and resolves a sub-scoped spelling" {
    // spec: serve/mcp_tools - flatten makes get_net return the merged rail and resolve a sub-scoped net spelling
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFlattenFixture(tmp.dir);
    const project = try tmp.dir.realpathAlloc(alloc, ".");

    var eval = Evaluator.init(alloc, project);
    defer eval.deinit();
    const block = try evalBoard(alloc, project, &eval);

    // Canonical name: V3P3 merges the top-level LED pin with the module's VOUT
    // pins (LDO output + output cap) — flattened refs, sub-block pins included.
    var out: std.ArrayList(u8) = .empty;
    try std.testing.expect(try getNetFlat(alloc, &eval, block, "V3P3", out.writer(alloc)));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"name\":\"V3P3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"ref_des\":\"D1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"ref_des\":\"ldo/") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"function\":\"VOUT\"") != null);

    // The sub-scoped spelling resolves to the same canonical merged net.
    var out2: std.ArrayList(u8) = .empty;
    try std.testing.expect(try getNetFlat(alloc, &eval, block, "ldo/VOUT", out2.writer(alloc)));
    try std.testing.expect(std.mem.indexOf(u8, out2.items, "\"name\":\"V3P3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out2.items, "\"ref_des\":\"ldo/") != null);
}

test "flatten list_free_pins matches a child by name and reads assignments from the merged net" {
    // spec: serve/mcp_tools - flatten makes list_free_pins match a flattened child by name and read merged assignments
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFlattenFixture(tmp.dir);
    const project = try tmp.dir.realpathAlloc(alloc, ".");

    var eval = Evaluator.init(alloc, project);
    defer eval.deinit();
    const block = try evalBoard(alloc, project, &eval);

    // The module IC renumbers to ldo/U2, but its module-local origin "U1" still
    // finds it. Pins EN/NC are unwired; the wired VOUT pad reports the merged
    // canonical rail name "V3P3".
    var out: std.ArrayList(u8) = .empty;
    try std.testing.expect(try listFreePinsFlat(alloc, &eval, block, "U1", null, out.writer(alloc)));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"function\":\"EN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"function\":\"NC\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"function\":\"VOUT\",\"net\":\"V3P3\"") != null);
}
