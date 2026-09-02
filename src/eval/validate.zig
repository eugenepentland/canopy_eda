//! Post-build design validation: warns when nets that could be one `(net …)`
//! form are declared separately (a rail split across sections), tracking each
//! net's declaration sources. Advisory — it emits lint warnings, not the hard
//! errors ERC gates on. Runs after the `DesignBlock` is materialized.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const env_mod = @import("env.zig");
const na = @import("net_analysis.zig");
const net_suggest = @import("net_suggest.zig");
const Evaluator = @import("evaluator.zig").Evaluator;
const EvalError = @import("evaluator.zig").EvalError;
const DesignBlock = env_mod.DesignBlock;
const Node = ast.Node;
const Env = env_mod.Env;

// ── Constants ─────────────────────────────────────────────────────
const voltage_mismatch_tolerance_v: f64 = 0.01;
/// A section description is a one-line, high-level summary of what the block
/// is *for* — not a parts list. Anything longer than this (counted in Unicode
/// codepoints, so the em-dashes and arrows these summaries favour aren't
/// over-counted) should move to `;;` comments on the source. Warned, not
/// enforced, so already-verbose designs keep building.
const section_description_max_chars: usize = 100;

/// Run post-build validations on a design block and its sub-blocks.
pub fn validateDesign(self: *Evaluator, block: *const DesignBlock) EvalError!void {
    try checkSinglePinNets(self, block);
    try checkVoltageMismatches(self, block);
    try checkMissingDecoupling(self, block);
    try checkSectionDescriptionLength(self, block);
}

/// Warn about nets that have only a single pin (dead-end connections).
/// Groups nets by base name (before first '.') so that "VDD" and "VDD.U3.W6"
/// are counted together. Sub-blocks are excluded since their internal nets
/// connect to the parent design via net_ties.
fn checkSinglePinNets(self: *Evaluator, block: *const DesignBlock) !void {
    // Count total pins per base net name
    var net_pin_counts: std.StringHashMapUnmanaged(u32) = .empty;
    // Track a representative single-pin net for the error message
    const PinInfo = struct { ref_des: []const u8, pin: []const u8 };
    var net_single_pin: std.StringHashMapUnmanaged(PinInfo) = .empty;

    // Build set of port net names — these connect externally and aren't dead-ends
    var port_nets: std.StringHashMapUnmanaged(void) = .empty;
    for (block.ports) |port| {
        try port_nets.put(self.allocator, port.net, {});
        try port_nets.put(self.allocator, port.name, {});
    }

    for (block.nets) |net| {
        const base = na.baseNetName(net.name);
        if (port_nets.contains(base)) continue; // Port nets connect externally
        const gop = net_pin_counts.getOrPut(self.allocator, base) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += @intCast(net.pins.len);

        // Store single-pin info for the first occurrence
        if (net.pins.len == 1 and !net_single_pin.contains(base)) {
            try net_single_pin.put(self.allocator, base, .{
                .ref_des = net.pins[0].ref_des,
                .pin = net.pins[0].pin,
            });
        }
    }

    // Also count pins from sub-block port connections (via net_ties)
    for (block.net_ties) |nt| {
        // Each net_tie side that doesn't have '/' is a plain net in this block
        for ([_][]const u8{ nt.a, nt.b }) |side| {
            if (std.mem.indexOfScalar(u8, side, '/') == null) {
                const base = na.baseNetName(side);
                const gop = net_pin_counts.getOrPut(self.allocator, base) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
        }
    }

    // A dead-end net is very often a typo of a net that IS wired up; offer the
    // nearest established name rather than only stating the symptom.
    const established = net_suggest.establishedNets(self.allocator, block) catch &.{};

    var iter = net_pin_counts.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* == 1) {
            const base = entry.key_ptr.*;
            if (net_single_pin.get(base)) |info| {
                const hint = net_suggest.hint(self.allocator, base, established);
                defer if (hint.len > 0) self.allocator.free(hint);
                const msg = std.fmt.allocPrint(
                    self.allocator,
                    "Dead-end net \"{s}\" — only connected to {s} pin {s}{s}",
                    .{ base, info.ref_des, info.pin, hint },
                ) catch continue;
                try self.assertions.append(self.allocator, .{ .passed = false, .message = msg, .is_warning = true });
            }
        }
    }
}

/// Warn when two sections declare the same net with different voltages.
fn checkVoltageMismatches(self: *Evaluator, block: *const DesignBlock) !void {
    // Collect voltage declarations per net name across sections
    const Entry = struct { section: []const u8, voltage: f64 };
    var net_voltages: std.StringHashMapUnmanaged(std.ArrayList(Entry)) = .empty;

    for (block.sections) |sec| {
        for (sec.ports) |p| {
            if (p.voltage) |v| {
                const gop = net_voltages.getOrPut(self.allocator, p.name) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(self.allocator, .{ .section = sec.name, .voltage = v });
            }
        }
        for (sec.sub_sections) |sub| {
            for (sub.ports) |p| {
                if (p.voltage) |v| {
                    const gop = net_voltages.getOrPut(self.allocator, p.name) catch continue;
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(self.allocator, .{ .section = sub.name, .voltage = v });
                }
            }
        }
    }

    var iter = net_voltages.iterator();
    while (iter.next()) |entry| {
        const entries = entry.value_ptr.items;
        if (entries.len < 2) continue;
        const first_v = entries[0].voltage;
        for (entries[1..]) |e| {
            if (@abs(e.voltage - first_v) > voltage_mismatch_tolerance_v) {
                const msg = std.fmt.allocPrint(
                    self.allocator,
                    "Voltage mismatch on net \"{s}\": {s} declares {d:.1}V but {s} declares {d:.1}V",
                    .{ entry.key_ptr.*, entries[0].section, first_v, e.section, e.voltage },
                ) catch continue;
                try self.assertions.append(self.allocator, .{ .passed = false, .message = msg, .is_warning = true });
                break;
            }
        }
    }
}

/// Warn about power nets connected to ICs but missing decoupling capacitors.
/// Shares its core analysis with the on-demand ERC pass in `src/erc.zig` —
/// see `eval/net_analysis.zig` for the actual walk (including the follow
/// into sub-block ports tied to top-level rails).
fn checkMissingDecoupling(self: *Evaluator, block: *const DesignBlock) !void {
    const missing = try na.findMissingDecouplingNets(self.allocator, block);
    defer self.allocator.free(missing);
    for (missing) |base| {
        const msg = std.fmt.allocPrint(
            self.allocator,
            "Power net \"{s}\" connects to IC but has no decoupling capacitor",
            .{base},
        ) catch continue;
        try self.assertions.append(self.allocator, .{ .passed = false, .message = msg, .is_warning = true });
    }
}

/// Count a description's length in Unicode codepoints, falling back to byte
/// length on invalid UTF-8. The em-dashes and arrows these summaries favour
/// are one character each, so a multi-byte glyph doesn't inflate the count.
fn descriptionCharCount(desc: []const u8) usize {
    return std.unicode.utf8CountCodepoints(desc) catch desc.len;
}

/// Warn when a section (or sub-section) description runs long. A description
/// should say *what the block is for* at a high level; part numbers, bus
/// addresses, and implementation detail belong in `;;` comments on the
/// source. Non-fatal — the existing verbose descriptions still build.
fn checkSectionDescriptionLength(self: *Evaluator, block: *const DesignBlock) !void {
    for (block.sections) |sec| {
        try warnIfDescriptionLong(self, sec.name, sec.description);
        for (sec.sub_sections) |sub| {
            try warnIfDescriptionLong(self, sub.name, sub.description);
        }
    }
}

/// Append the over-limit warning for one section when its description exceeds
/// `SECTION_DESCRIPTION_MAX_CHARS` codepoints. Empty descriptions never warn.
fn warnIfDescriptionLong(self: *Evaluator, name: []const u8, description: []const u8) !void {
    const count = descriptionCharCount(description);
    if (count <= section_description_max_chars) return;
    const msg = std.fmt.allocPrint(
        self.allocator,
        "Section \"{s}\" description is {d} chars (limit {d}) — keep it high-level " ++
            "(what the block does); move part numbers / addresses / implementation " ++
            "detail to ;; comments in the .sexp",
        .{ name, count, section_description_max_chars },
    ) catch return;
    try self.assertions.append(self.allocator, .{ .passed = false, .message = msg, .is_warning = true });
}

/// Track the first argument of a (net ...) form for combinability warnings.
pub fn trackNetFormSource(self: *Evaluator, form_children: []const Node, env: *Env, sources: *std.StringHashMapUnmanaged(u32)) void {
    if (form_children.len < 3) return;
    const src_val = self.evalNode(form_children[1], env) catch return;
    const src = src_val.asString() orelse return;
    const gop = sources.getOrPut(self.allocator, src) catch return;
    if (!gop.found_existing) {
        gop.value_ptr.* = 1;
    } else {
        gop.value_ptr.* += 1;
    }
}

/// Emit warnings for net forms that share a common first net and could be combined.
pub fn warnCombinableNets(self: *Evaluator, sources: *std.StringHashMapUnmanaged(u32)) EvalError!void {
    var iter = sources.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* > 1) {
            const msg = std.fmt.allocPrint(
                self.allocator,
                "Net \"{s}\" has {d} separate (net) forms that could be combined",
                .{ entry.key_ptr.*, entry.value_ptr.* },
            ) catch continue;
            try self.assertions.append(self.allocator, .{ .passed = false, .message = msg, .is_warning = true });
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const sexpr_parser = @import("../sexpr/parser.zig");
const design_block_mod = @import("design_block.zig");

test "descriptionCharCount counts codepoints, not bytes" {
    // Plain ASCII: byte length and codepoint count agree.
    try std.testing.expectEqual(@as(usize, 5), descriptionCharCount("ABCDE"));
    // An em-dash (U+2014) is three UTF-8 bytes but one character — the
    // section-description limit counts it once so dashed summaries aren't
    // penalised relative to their on-screen length.
    try std.testing.expectEqual(@as(usize, 3), descriptionCharCount("A—B"));
    try std.testing.expectEqual(@as(usize, 5), "A—B".len);
}

/// Evaluate `src`'s single `(design-block …)` against a two-terminal
/// `fakeres` part and return the evaluator, so a test can read the lint
/// assertions it recorded. Caller owns the evaluator.
fn evalDesign(a: std.mem.Allocator, eval: *Evaluator, src: []const u8) !void {
    eval.* = Evaluator.init(a, "");
    try eval.component_cache.put(a, "fakeres", .{
        .name = "fakeres",
        .symbol_name = "",
        .footprint_name = "",
        .is_family = false,
        .param_type = "",
    });
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var scope = Env.init(a, null);
    defer scope.deinit();
    _ = try design_block_mod.evalDesignBlock(eval, form_children[1..], &scope);
}

/// The first `is_warning` assertion whose message starts with `prefix`.
fn findWarning(eval: *const Evaluator, prefix: []const u8) ?[]const u8 {
    for (eval.assertions.items) |a| {
        if (!a.is_warning) continue;
        if (std.mem.startsWith(u8, a.message, prefix)) return a.message;
    }
    return null;
}

// spec: eval/validate - a dead-end net within two edits of a well-connected net suggests that net
test "dead-end net lint offers a did-you-mean for a near-miss name" {
    // page_allocator: assertion messages are allocated and never freed.
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    try evalDesign(a, &eval,
        \\(design-block "test"
        \\  (instance "R1" fakeres (pin 1 "V_3V3") (pin 2 "GND"))
        \\  (instance "R2" fakeres (pin 1 "V_3V3") (pin 2 "GND"))
        \\  (instance "R3" fakeres (pin 1 "V_3V3") (pin 2 "GNND")))
    );
    defer eval.deinit();
    const msg = findWarning(&eval, "Dead-end net \"GNND\"") orelse return error.TestExpectedWarning;
    try testing.expect(std.mem.endsWith(u8, msg, " — did you mean \"GND\"?"));
}

// spec: eval/validate - a dead-end net with no near neighbour keeps its plain message
test "dead-end net lint stays plain when nothing is close" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    try evalDesign(a, &eval,
        \\(design-block "test"
        \\  (instance "R1" fakeres (pin 1 "V_3V3") (pin 2 "GND"))
        \\  (instance "R2" fakeres (pin 1 "V_3V3") (pin 2 "GND"))
        \\  (instance "R3" fakeres (pin 1 "V_3V3") (pin 2 "MOSI")))
    );
    defer eval.deinit();
    const msg = findWarning(&eval, "Dead-end net \"MOSI\"") orelse return error.TestExpectedWarning;
    try testing.expectEqualStrings("Dead-end net \"MOSI\" — only connected to R3 pin 2", msg);
}

// spec: eval/validate - a design block with an empty net list produces no dead-end lint at all
test "an empty design block records no dead-end warnings" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    try evalDesign(a, &eval, "(design-block \"test\")");
    defer eval.deinit();
    try testing.expectEqual(@as(?[]const u8, null), findWarning(&eval, "Dead-end net"));
}

/// 80 characters — past `suggest.max_name_len`, so the distance scan must
/// reject it outright rather than index its fixed rows with it.
const long_net_name = "NET_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

// spec: eval/validate - an oversized net name is linted with no suggestion and a malformed one is ranked bytewise — the scan never panics and cannot overflow
test "oversized and malformed net names lint plainly" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    // A regular (escape-processing) literal: R4's net really does carry two
    // bytes that are not valid UTF-8, which a multiline literal cannot express.
    comptime std.debug.assert(long_net_name.len > @import("suggest.zig").max_name_len);
    try evalDesign(a, &eval, "(design-block \"test\"\n" ++
        "  (instance \"R1\" fakeres (pin 1 \"V_3V3\") (pin 2 \"GND\"))\n" ++
        "  (instance \"R2\" fakeres (pin 1 \"V_3V3\") (pin 2 \"GND\"))\n" ++
        "  (instance \"R3\" fakeres (pin 1 \"V_3V3\") (pin 2 \"" ++ long_net_name ++ "\"))\n" ++
        "  (instance \"R4\" fakeres (pin 1 \"V_3V3\") (pin 2 \"GN\xff\xfeD\")))\n");
    defer eval.deinit();
    const long = findWarning(&eval, "Dead-end net \"NET_AAAA") orelse return error.TestExpectedWarning;
    try testing.expect(std.mem.indexOf(u8, long, "did you mean") == null);
    // The malformed name is ranked byte by byte — no decode, no panic — and
    // lands close enough to GND to carry the same hint any typo would.
    const bad = findWarning(&eval, "Dead-end net \"GN") orelse return error.TestExpectedWarning;
    try testing.expect(std.mem.endsWith(u8, bad, " — did you mean \"GND\"?"));
}
