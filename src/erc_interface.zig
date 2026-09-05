//! The two interface-bundle rules ERC runs, kept out of `erc.zig` because they
//! are one cohesive pair with their own vocabulary dependency.
//!
//! `interface_half_connected` mirrors the differential both-or-neither rule: a
//! `(port-group …)` states that its lanes belong together, so wiring SCK and
//! MOSI while leaving CS open is a half-finished edit and not a deliberate
//! connection. Optional lanes (UART's CTS/RTS, JTAG's TRST, anything the author
//! marked `optional`) are never demanded.
//!
//! `interface_naming` is the advisory half — INFO severity, and deliberately
//! quiet. A module that declares two or more ports out of one interface's
//! naming vocabulary without a `(port-group …)` gets one row naming the
//! interface and the exact line that would replace those ports. It is not a
//! warning on purpose: the release profile turns evaluator warnings into
//! errors, and "you could have written this more compactly" must never fail a
//! release.
//!
//! Findings come back in this module's own shape rather than as
//! `erc.Violation`s so the dependency runs one way — the same arrangement
//! `canonical_module_check` uses.

const std = @import("std");
const checks = @import("checks.zig");
const env_mod = @import("eval/env.zig");
const na = @import("eval/net_analysis.zig");
const interfaces = @import("eval/interfaces.zig");

const DesignBlock = env_mod.DesignBlock;
const PortGroup = env_mod.PortGroup;

/// One interface-bundle finding. `naming` selects which of the two rules
/// produced it, so the caller can stamp the right `ViolationKind`.
pub const Finding = struct {
    severity: checks.Severity,
    message: []const u8,
    net: []const u8 = "",
    /// True for the advisory `interface_naming` lint, false for the
    /// `interface_half_connected` rule.
    naming: bool = false,
};

/// How many matched signals of one vocabulary it takes before the naming lint
/// speaks. One `SCK` on its own says nothing; two lanes of the same bus with
/// the same prefix is a bundle written out by hand.
const naming_min_signals: usize = 2;

/// Run both rules over a whole design tree. Messages are allocator-owned; the
/// caller keeps them for the life of the report, exactly as `runErc` does with
/// every other check's.
pub fn run(allocator: std.mem.Allocator, block: *const DesignBlock) std.mem.Allocator.Error![]Finding {
    var findings: std.ArrayList(Finding) = .empty;
    errdefer {
        for (findings.items) |f| allocator.free(f.message);
        findings.deinit(allocator);
    }
    try checkHalfConnected(allocator, block, &findings);

    // One row per (module, interface, prefix): a module instantiated four
    // times is one authoring decision, not four. The keys are scratch — freed
    // here, unlike the messages, which the caller keeps.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var keys = seen.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        seen.deinit(allocator);
    }
    try checkNaming(allocator, block, &seen, &findings);
    return findings.toOwnedSlice(allocator);
}

// ── interface_half_connected ──────────────────────────────────────────

fn checkHalfConnected(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    findings: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void {
    // This block's own groups, judged by its internal connectivity.
    var connected_nets: std.StringHashMapUnmanaged(void) = .empty;
    defer connected_nets.deinit(allocator);
    for (block.nets) |net| {
        if (net.pins.len == 0) continue;
        try connected_nets.put(allocator, na.baseNetName(net.name), {});
    }
    for (block.net_ties) |nt| {
        try connected_nets.put(allocator, na.baseNetName(nt.a), {});
        try connected_nets.put(allocator, na.baseNetName(nt.b), {});
    }
    for (block.port_groups) |group| {
        try reportGroup(allocator, group, "", &connected_nets, findings);
    }

    // Each sub-block's groups, judged by the paths the parent tied.
    var connected_paths: std.StringHashMapUnmanaged(void) = .empty;
    defer connected_paths.deinit(allocator);
    for (block.net_ties) |nt| {
        try connected_paths.put(allocator, nt.a, {});
        try connected_paths.put(allocator, nt.b, {});
    }
    for (block.sub_blocks) |sb| {
        for (sb.block.port_groups) |group| {
            try reportGroup(allocator, group, sb.name, &connected_paths, findings);
        }
        try checkHalfConnected(allocator, sb.block, findings);
    }
}

/// Emit one finding for a group with some member wired and some REQUIRED
/// member open. `sub_block` is empty when judging a block's own group and the
/// sub-block's name when judging its group from the parent's ties.
fn reportGroup(
    allocator: std.mem.Allocator,
    group: PortGroup,
    sub_block: []const u8,
    connected: *const std.StringHashMapUnmanaged(void),
    findings: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void {
    var wired: usize = 0;
    var first_open: ?env_mod.PortGroupMember = null;
    var open_count: usize = 0;
    for (group.members) |member| {
        if (memberConnected(allocator, member, sub_block, connected)) {
            wired += 1;
            continue;
        }
        if (member.optional) continue;
        open_count += 1;
        if (first_open == null) first_open = member;
    }
    const open = first_open orelse return;
    if (wired == 0) return;

    const where = if (sub_block.len == 0)
        try std.fmt.allocPrint(allocator, "", .{})
    else
        try std.fmt.allocPrint(allocator, " of sub-block \"{s}\"", .{sub_block});
    defer allocator.free(where);
    const message = try std.fmt.allocPrint(
        allocator,
        "interface group \"{s}\" ({s}){s} is half connected — {d} of {d} lanes wired, but \"{s}\" is open; " ++
            "a (port-group …) is a both-or-neither bundle, so wire it or mark the lane optional",
        .{ group.name, group.interface, where, wired, wired + open_count, open.port },
    );
    try findings.append(allocator, .{
        .severity = .warning,
        .message = message,
        .net = open.net,
    });
}

/// Whether one member counts as wired. Fails open (reports connected) when the
/// path string cannot be built, so an allocation failure never invents a
/// finding.
fn memberConnected(
    allocator: std.mem.Allocator,
    member: env_mod.PortGroupMember,
    sub_block: []const u8,
    connected: *const std.StringHashMapUnmanaged(void),
) bool {
    if (sub_block.len == 0) return connected.contains(na.baseNetName(member.net));
    const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ sub_block, member.port }) catch return true;
    defer allocator.free(path);
    return connected.contains(path);
}

// ── interface_naming ──────────────────────────────────────────────────

/// One recognised bus written out as loose ports: which lanes were found,
/// under which shared prefix.
const NamingHit = struct {
    /// How many lanes one hand-written bundle can hold. No interface in the
    /// vocabulary has more than five; the cap only bounds a pathological
    /// module, which then reports the first `max_lanes` it found.
    const max_lanes = 16;

    prefix: []const u8,
    /// Port names, parallel to `signals`, in the order the ports were declared.
    ports: [max_lanes][]const u8 = @splat(""),
    signals: [max_lanes][]const u8 = @splat(""),
    count: usize = 0,

    fn has(self: NamingHit, signal: []const u8) bool {
        for (self.signals[0..self.count]) |s| {
            if (std.mem.eql(u8, s, signal)) return true;
        }
        return false;
    }
};

fn checkNaming(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    seen: *std.StringHashMapUnmanaged(void),
    findings: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void {
    const identity = if (block.module_name.len > 0) block.module_name else block.name;
    for (interfaces.vocabularies) |vocab| {
        try checkNamingVocabulary(allocator, block, identity, vocab, seen, findings);
    }
    for (block.sub_blocks) |sb| try checkNaming(allocator, sb.block, seen, findings);
}

fn checkNamingVocabulary(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    identity: []const u8,
    vocab: interfaces.Vocabulary,
    seen: *std.StringHashMapUnmanaged(void),
    findings: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void {
    var hits: std.ArrayList(NamingHit) = .empty;
    defer hits.deinit(allocator);
    for (block.ports) |port| {
        const match = interfaces.matchSignal(vocab, port.name) orelse continue;
        if (inSomeGroup(block.port_groups, port.name)) continue;
        try recordHit(allocator, &hits, match.prefix, match.canonical, port.name);
    }
    for (hits.items) |hit| {
        if (hit.count < naming_min_signals) continue;
        const key = try std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{ identity, vocab.interface, hit.prefix });
        if ((try seen.getOrPut(allocator, key)).found_existing) {
            allocator.free(key);
            continue;
        }
        try findings.append(allocator, .{
            .severity = .info,
            .message = try namingMessage(allocator, identity, vocab, hit),
            .naming = true,
        });
    }
}

/// True when `port_name` is already a member of some declared group — the
/// whole point of the lint is that the author has NOT done that yet.
fn inSomeGroup(groups: []const PortGroup, port_name: []const u8) bool {
    for (groups) |group| {
        for (group.members) |member| {
            if (std.mem.eql(u8, member.port, port_name)) return true;
        }
    }
    return false;
}

fn recordHit(
    allocator: std.mem.Allocator,
    hits: *std.ArrayList(NamingHit),
    prefix: []const u8,
    signal: []const u8,
    port_name: []const u8,
) std.mem.Allocator.Error!void {
    for (hits.items) |*hit| {
        if (!std.mem.eql(u8, hit.prefix, prefix)) continue;
        if (hit.has(signal) or hit.count == NamingHit.max_lanes) return;
        hit.signals[hit.count] = signal;
        hit.ports[hit.count] = port_name;
        hit.count += 1;
        return;
    }
    var fresh: NamingHit = .{ .prefix = prefix };
    fresh.signals[0] = signal;
    fresh.ports[0] = port_name;
    fresh.count = 1;
    try hits.append(allocator, fresh);
}

/// The advisory row: what was recognised, and the exact `(port-group …)` line
/// that declares those same ports — including a `(rename …)` for every lane
/// whose spelling is not the canonical join, and an `(omit …)` for the lanes
/// of the interface this block does not carry.
fn namingMessage(
    allocator: std.mem.Allocator,
    identity: []const u8,
    vocab: interfaces.Vocabulary,
    hit: NamingHit,
) std.mem.Allocator.Error![]const u8 {
    // `toOwnedSlice` empties the list, so the defer is a no-op on the success
    // path and the cleanup on every early return.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.print(allocator, "'{s}' declares ", .{identity});
    for (hit.ports[0..hit.count], 0..) |port, i| {
        if (i > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, port);
    }
    try out.print(
        allocator,
        " — the {s} signal vocabulary — as loose ports; declare the bundle instead: (port-group \"{s}\" {s}",
        .{ vocab.interface, hit.prefix, vocab.interface },
    );
    for (hit.ports[0..hit.count], hit.signals[0..hit.count]) |port, signal| {
        if (isCanonicalJoin(hit.prefix, signal, port)) continue;
        try out.print(allocator, " (rename {s} \"{s}\")", .{ signal, port });
    }
    var omitted: usize = 0;
    for (vocab.variants) |v| {
        if (!std.mem.eql(u8, v.token, v.canonical)) continue; // variants, not lanes
        if (hit.has(v.canonical)) continue;
        if (omitted == 0) try out.appendSlice(allocator, " (omit");
        try out.print(allocator, " {s}", .{v.canonical});
        omitted += 1;
    }
    if (omitted > 0) try out.appendSlice(allocator, ")");
    try out.appendSlice(allocator, ")");
    return out.toOwnedSlice(allocator);
}

/// True when `port` is exactly what `(port-group "PREFIX" …)` would have named
/// this lane, so no `(rename …)` is needed in the suggestion.
fn isCanonicalJoin(prefix: []const u8, signal: []const u8, port: []const u8) bool {
    if (prefix.len == 0) return std.mem.eql(u8, port, signal);
    if (port.len != prefix.len + 1 + signal.len) return false;
    return std.mem.startsWith(u8, port, prefix) and port[prefix.len] == '_' and
        std.mem.endsWith(u8, port, signal);
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

/// A block carrying just the ports and groups a rule reads. Every other field
/// keeps its default, so a fixture states only what the rule under test looks
/// at.
fn blockWith(ports: []const env_mod.Port, groups: []const PortGroup, nets: []const env_mod.Net) DesignBlock {
    return .{
        .name = "fixture",
        .instances = &.{},
        .nets = nets,
        .ports = ports,
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .port_groups = groups,
    };
}

const spi_group = PortGroup{
    .name = "IMU",
    .interface = "spi",
    .members = &.{
        .{ .signal = "SCK", .port = "IMU_SCK", .net = "IMU_SCK" },
        .{ .signal = "MOSI", .port = "IMU_MOSI", .net = "IMU_MOSI" },
        .{ .signal = "MISO", .port = "IMU_MISO", .net = "IMU_MISO", .optional = true },
        .{ .signal = "CS", .port = "IMU_CS", .net = "IMU_CS" },
    },
};

const one_pin: []const env_mod.PinRef = &.{.{ .ref_des = "U1", .pin = "1" }};

// spec: erc - A port group with some lanes wired and a required lane open is reported as interface_half_connected
test "a half-wired interface group is reported" {
    const alloc = testing.allocator;
    var block = blockWith(&.{}, &.{spi_group}, &.{
        .{ .name = "IMU_SCK", .pins = one_pin },
        .{ .name = "IMU_MOSI", .pins = one_pin },
    });
    const findings = try run(alloc, &block);
    defer {
        for (findings) |f| alloc.free(f.message);
        alloc.free(findings);
    }
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqual(checks.Severity.warning, findings[0].severity);
    try testing.expect(std.mem.indexOf(u8, findings[0].message, "IMU_CS") != null);
    try testing.expect(std.mem.indexOf(u8, findings[0].message, "half connected") != null);
}

// spec: erc - A fully wired port group and a wholly unwired one are both silent, and an optional lane is never demanded
test "a complete or wholly open interface group is silent" {
    const alloc = testing.allocator;
    // Every REQUIRED lane wired; the optional MISO left open on purpose.
    var complete = blockWith(&.{}, &.{spi_group}, &.{
        .{ .name = "IMU_SCK", .pins = one_pin },
        .{ .name = "IMU_MOSI", .pins = one_pin },
        .{ .name = "IMU_CS", .pins = one_pin },
    });
    const none = try run(alloc, &complete);
    defer alloc.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);

    // Nothing wired at all is a module that simply isn't used here, which the
    // required-port rule already covers.
    var unused = blockWith(&.{}, &.{spi_group}, &.{});
    const also_none = try run(alloc, &unused);
    defer alloc.free(also_none);
    try testing.expectEqual(@as(usize, 0), also_none.len);
}

// spec: erc - Two or more ports matching one interface vocabulary without a port-group raise the info-severity interface_naming lint
test "hand-written bus ports raise the naming advisory with a copy-pasteable line" {
    const alloc = testing.allocator;
    var block = blockWith(&.{
        .{ .name = "SPI_DSA_SCK", .net = "SPI_DSA_SCK", .direction = "in" },
        .{ .name = "SPI_DSA_SDI", .net = "SPI_DSA_SDI", .direction = "in" },
        .{ .name = "SPI_DSA_CSN", .net = "SPI_DSA_CSN", .direction = "in" },
    }, &.{}, &.{});
    const findings = try run(alloc, &block);
    defer {
        for (findings) |f| alloc.free(f.message);
        alloc.free(findings);
    }
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqual(checks.Severity.info, findings[0].severity);
    try testing.expect(findings[0].naming);
    // The suggestion names the interface, the shared prefix, a rename for
    // every non-canonical spelling and an omit for the lane that is absent.
    try testing.expect(std.mem.indexOf(u8, findings[0].message, "(port-group \"SPI_DSA\" spi") != null);
    try testing.expect(std.mem.indexOf(u8, findings[0].message, "(rename MOSI \"SPI_DSA_SDI\")") != null);
    try testing.expect(std.mem.indexOf(u8, findings[0].message, "(rename CS \"SPI_DSA_CSN\")") != null);
    try testing.expect(std.mem.indexOf(u8, findings[0].message, "(omit MISO)") != null);
    // SCK is already spelled the way the expansion would spell it.
    try testing.expect(std.mem.indexOf(u8, findings[0].message, "(rename SCK") == null);
}

// spec: erc - The interface naming lint stays silent for a declared port group and for a single matching port
test "the naming advisory is quiet where there is nothing to suggest" {
    const alloc = testing.allocator;
    // Ports that ARE a declared group.
    var declared = blockWith(&.{
        .{ .name = "IMU_SCK", .net = "IMU_SCK", .direction = "in" },
        .{ .name = "IMU_MOSI", .net = "IMU_MOSI", .direction = "in" },
        .{ .name = "IMU_CS", .net = "IMU_CS", .direction = "in" },
    }, &.{spi_group}, &.{});
    const none = try run(alloc, &declared);
    defer alloc.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);

    // One lone recognised port says nothing — plenty of parts have a single
    // `SCL` or a lone `TX`.
    var lonely = blockWith(&.{
        .{ .name = "SCL", .net = "SCL", .direction = "bidi" },
    }, &.{}, &.{});
    const also_none = try run(alloc, &lonely);
    defer alloc.free(also_none);
    try testing.expectEqual(@as(usize, 0), also_none.len);
}
