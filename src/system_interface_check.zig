//! `interface_mismatch` — the board-to-board contract checked against what the
//! two boards' evaluated netlists actually say.
//!
//! The strict manifest already proves that a declared contact map is complete,
//! internally consistent and matched by the observed nets. What it cannot say
//! is whether the CONTRACT ITSELF describes a working joint. That is this
//! module's job, and it is deliberately narrow about what counts as a defect:
//!
//!   * a contact wired on one side and dead (no net, or a floating net) on the
//!     other is a wiring defect — error;
//!   * a required signal whose two nets are both supplies or grounds but sit
//!     at different declared potentials is a domain defect — error;
//!   * a signal naming a pin the connector's pinout does not carry, a contract
//!     claiming more contacts than the connector has pads, and two signals
//!     claiming one contact are contract defects — error;
//!   * a connector with more pads than the contract covers (shield, mounting,
//!     spare) and a connector whose pinout is not available at all are
//!     reported, not blocked — warning.
//!
//! Two net NAMES differing is NOT a mismatch. The whole point of the manifest's
//! canonical/alias layer is that `V_12V` on one board and `V_12V_RF` on the
//! other are the same conductor; a checker that flagged that would fire on
//! every real contract and teach reviewers to ignore it.
//!
//! The module is pure: callers supply the evaluated evidence and decide where
//! the findings travel.

const std = @import("std");

const draw = @import("render_svg/draw.zig");
const json_writer = @import("json_writer.zig");
const rails = @import("eval/rails.zig");
const system_review = @import("system_review.zig");
const system_sexp = @import("system_sexp.zig");

/// Absolute slack allowed between two declared nominal potentials before they
/// are called different domains. Rail declarations are authored to two or
/// three digits, so anything under 50 mV is a rounding difference.
pub const voltage_tolerance_v: f64 = 0.05;
/// Relative slack applied on top of the absolute one, so a 12 V pair is not
/// flagged for a 1% difference in how the two boards round it.
pub const voltage_tolerance_fraction: f64 = 0.01;

/// Whether a finding blocks a system release or only annotates it.
pub const Severity = enum { @"error", warning };

/// Every mismatch this module reports.
pub const Kind = enum {
    /// A declared contact reaches a net on one side and nothing (or a
    /// single-pin floating net) on the other.
    contact_unconnected_one_side,
    /// A required signal joins two declared potentials that are not the same.
    voltage_domain_mismatch,
    /// A signal names a pad the connector's pinout does not carry.
    unknown_contact_pin,
    /// The contract claims more contacts than the connector has pads.
    contact_count_over_pads,
    /// The connector has pads the contract does not cover.
    contacts_not_covered,
    /// Two signal records claim the same physical contact.
    duplicate_contact_claim,
    /// The connector's pad table could not be read, so the pin-existence and
    /// pad-count checks could not run for that endpoint.
    connector_pinout_unavailable,
    /// A `system.sexp` and a `system.json` both exist; the sexp is the
    /// contract and the JSON is inert.
    manifest_shadowed,
};

/// Blocking policy per mismatch. Everything that names a concrete defect in
/// the contract or the wiring blocks; everything that reports absent or merely
/// surplus evidence does not.
pub fn severity(kind: Kind) Severity {
    return switch (kind) {
        .contact_unconnected_one_side,
        .voltage_domain_mismatch,
        .unknown_contact_pin,
        .contact_count_over_pads,
        .duplicate_contact_claim,
        => .@"error",
        .contacts_not_covered,
        .connector_pinout_unavailable,
        .manifest_shadowed,
        => .warning,
    };
}

/// Readiness finding class. Interface defects share one class so a consumer
/// can filter them as a group; the manifest-shadowing notice is its own.
pub fn class(kind: Kind) []const u8 {
    return switch (kind) {
        .manifest_shadowed => "manifest_shadowed",
        else => "interface_mismatch",
    };
}

/// One reported mismatch. `detail` is allocated by the caller's allocator;
/// every other slice borrows the manifest or the supplied evidence.
pub const Finding = struct {
    kind: Kind,
    interface: []const u8 = "",
    board: []const u8 = "",
    pin: []const u8 = "",
    detail: []const u8 = "",

    /// Blocking policy for this finding.
    pub fn severity(self: Finding) Severity {
        return @import("system_interface_check.zig").severity(self.kind);
    }
};

/// A declared nominal potential for one flattened board net.
pub const NetNominal = struct {
    net: []const u8,
    volts: f64,
};

/// One side of an interface as the evaluated board reports it.
pub const Endpoint = struct {
    board: []const u8,
    connector: []const u8,
    /// The connector's complete pad table, from its pinout. Empty means the
    /// pad table could not be read, not that the connector has no pads.
    pads: []const []const u8 = &.{},
    /// Contacts the flattened netlist actually wires. A pad absent here has
    /// no net at all.
    wired: []const system_sexp.Contact = &.{},
    /// Nets the board's rule checks call floating — reachable copper with one
    /// pin on it, which is electrically the same as unwired across a joint.
    floating_nets: []const []const u8 = &.{},
    /// Declared nominal potentials, by flattened net name.
    nominals: []const NetNominal = &.{},

    fn hasPad(self: Endpoint, pin: []const u8) bool {
        for (self.pads) |pad| if (system_sexp.sameContact(pad, pin)) return true;
        return false;
    }

    fn wiredNet(self: Endpoint, pin: []const u8) ?[]const u8 {
        for (self.wired) |contact| {
            if (!system_sexp.sameContact(contact.pin, pin)) continue;
            if (contact.net.len == 0) return null;
            for (self.floating_nets) |floating| if (std.mem.eql(u8, floating, contact.net)) return null;
            return contact.net;
        }
        return null;
    }

    /// The declared potential of `net`, when the design states one. A ground
    /// name is 0 V by definition even with no explicit declaration.
    fn nominal(self: Endpoint, net: []const u8) ?f64 {
        for (self.nominals) |entry| if (std.mem.eql(u8, entry.net, net)) return entry.volts;
        if (draw.isGroundNet(net)) return 0;
        return null;
    }
};

/// True when `net` names a supply rail or a ground — the only nets whose
/// declared potentials are comparable across a joint.
pub fn isSupplyOrGround(net: []const u8) bool {
    return draw.isGroundNet(net) or rails.looksLikeRail(net);
}

/// True when two declared potentials describe the same domain.
pub fn sameDomain(left: f64, right: f64) bool {
    const slack = @max(voltage_tolerance_v, voltage_tolerance_fraction * @max(@abs(left), @abs(right)));
    return @abs(left - right) <= slack;
}

/// Check one interface contract against both endpoints' evaluated evidence,
/// appending every mismatch to `out`.
pub fn check(
    allocator: std.mem.Allocator,
    interface: system_review.InterfaceContract,
    left: Endpoint,
    right: Endpoint,
    out: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void {
    try checkEndpointCoverage(allocator, interface, left, true, out);
    try checkEndpointCoverage(allocator, interface, right, false, out);
    try checkDuplicateClaims(allocator, interface, out);
    for (interface.signals) |signal| {
        try checkContactContinuity(allocator, interface, signal, left, right, out);
        try checkVoltageDomain(allocator, interface, signal, left, right, out);
    }
}

fn checkEndpointCoverage(
    allocator: std.mem.Allocator,
    interface: system_review.InterfaceContract,
    endpoint: Endpoint,
    is_left: bool,
    out: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void {
    if (endpoint.pads.len == 0) {
        try out.append(allocator, .{
            .kind = .connector_pinout_unavailable,
            .interface = interface.id,
            .board = endpoint.board,
            .detail = try std.fmt.allocPrint(
                allocator,
                "connector {s} has no readable pad table, so its pin-existence and pad-count checks did not run",
                .{endpoint.connector},
            ),
        });
        return;
    }
    for (interface.signals) |signal| {
        const pin = if (is_left) signal.left_pin else signal.right_pin;
        if (endpoint.hasPad(pin)) continue;
        try out.append(allocator, .{
            .kind = .unknown_contact_pin,
            .interface = interface.id,
            .board = endpoint.board,
            .pin = pin,
            .detail = try std.fmt.allocPrint(
                allocator,
                "signal {s} names contact {s}, which connector {s} does not carry",
                .{ signal.canonical, pin, endpoint.connector },
            ),
        });
    }
    if (interface.contact_count > endpoint.pads.len) {
        try out.append(allocator, .{
            .kind = .contact_count_over_pads,
            .interface = interface.id,
            .board = endpoint.board,
            .detail = try std.fmt.allocPrint(
                allocator,
                "contract claims {d} contacts but connector {s} has {d} pads",
                .{ interface.contact_count, endpoint.connector, endpoint.pads.len },
            ),
        });
    } else if (endpoint.pads.len > interface.contact_count) {
        try out.append(allocator, .{
            .kind = .contacts_not_covered,
            .interface = interface.id,
            .board = endpoint.board,
            .detail = try std.fmt.allocPrint(
                allocator,
                "connector {s} has {d} pads and the contract covers {d}",
                .{ endpoint.connector, endpoint.pads.len, interface.contact_count },
            ),
        });
    }
}

fn checkDuplicateClaims(
    allocator: std.mem.Allocator,
    interface: system_review.InterfaceContract,
    out: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void {
    for (interface.signals, 0..) |signal, index| {
        for (interface.signals[0..index]) |earlier| {
            const left_clash = system_sexp.sameContact(earlier.left_pin, signal.left_pin);
            const right_clash = system_sexp.sameContact(earlier.right_pin, signal.right_pin);
            if (!left_clash and !right_clash) continue;
            try out.append(allocator, .{
                .kind = .duplicate_contact_claim,
                .interface = interface.id,
                .pin = if (left_clash) signal.left_pin else signal.right_pin,
                .detail = try std.fmt.allocPrint(
                    allocator,
                    "signals {s} and {s} both claim contact {s}",
                    .{ earlier.canonical, signal.canonical, if (left_clash) signal.left_pin else signal.right_pin },
                ),
            });
        }
    }
}

fn checkContactContinuity(
    allocator: std.mem.Allocator,
    interface: system_review.InterfaceContract,
    signal: system_review.InterfaceSignal,
    left: Endpoint,
    right: Endpoint,
    out: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void {
    const left_net = left.wiredNet(signal.left_pin);
    const right_net = right.wiredNet(signal.right_pin);
    if ((left_net == null) == (right_net == null)) return;
    const dead = if (left_net == null) left else right;
    const live = if (left_net == null) right else left;
    try out.append(allocator, .{
        .kind = .contact_unconnected_one_side,
        .interface = interface.id,
        .board = dead.board,
        .pin = if (left_net == null) signal.left_pin else signal.right_pin,
        .detail = try std.fmt.allocPrint(
            allocator,
            "contact {s} carries {s} on {s} and nothing on {s}",
            .{
                signal.canonical,
                (left_net orelse right_net).?,
                live.board,
                dead.board,
            },
        ),
    });
}

fn checkVoltageDomain(
    allocator: std.mem.Allocator,
    interface: system_review.InterfaceContract,
    signal: system_review.InterfaceSignal,
    left: Endpoint,
    right: Endpoint,
    out: *std.ArrayList(Finding),
) std.mem.Allocator.Error!void {
    if (!signal.required) return;
    if (!isSupplyOrGround(signal.left_net) or !isSupplyOrGround(signal.right_net)) return;
    const left_volts = left.nominal(signal.left_net) orelse return;
    const right_volts = right.nominal(signal.right_net) orelse return;
    if (sameDomain(left_volts, right_volts)) return;
    try out.append(allocator, .{
        .kind = .voltage_domain_mismatch,
        .interface = interface.id,
        .pin = signal.left_pin,
        .detail = try std.fmt.allocPrint(
            allocator,
            "required signal {s} joins {s} at {d:.3} V on {s} to {s} at {d:.3} V on {s}",
            .{
                signal.canonical,
                signal.left_net,
                left_volts,
                left.board,
                signal.right_net,
                right_volts,
                right.board,
            },
        ),
    });
}

/// True when any finding blocks a release.
pub fn blocked(findings: []const Finding) bool {
    for (findings) |finding| if (finding.severity() == .@"error") return true;
    return false;
}

/// Render the findings as the readiness document's `findings` array body —
/// the elements only, so the caller owns the brackets and any surrounding
/// commas. Every string goes through the canonical `json_writer` escaper.
pub fn writeFindings(writer: *std.Io.Writer, findings: []const Finding) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    for (findings, 0..) |finding, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"class\":");
        try json_writer.writeString(writer, class(finding.kind));
        try writer.writeAll(",\"kind\":");
        try json_writer.writeString(writer, @tagName(finding.kind));
        try writer.writeAll(",\"severity\":");
        try json_writer.writeString(writer, @tagName(finding.severity()));
        try writer.writeAll(",\"interface\":");
        try json_writer.writeString(writer, finding.interface);
        try writer.writeAll(",\"board\":");
        try json_writer.writeString(writer, finding.board);
        try writer.writeAll(",\"pin\":");
        try json_writer.writeString(writer, finding.pin);
        try writer.writeAll(",\"detail\":");
        try json_writer.writeString(writer, finding.detail);
        try writer.writeByte('}');
    }
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

const base_signals = [_]system_review.InterfaceSignal{
    .{ .canonical = "V_5V", .left_pin = "1", .left_net = "V_5V", .right_pin = "1", .right_net = "V_5V_SYS" },
    .{ .canonical = "GND", .left_pin = "2", .left_net = "GND", .right_pin = "2", .right_net = "GND" },
    .{ .canonical = "SPI_CLK", .left_pin = "3", .left_net = "SCK", .right_pin = "3", .right_net = "SPI_CLK" },
    .{ .canonical = "SPARE", .left_pin = "4", .left_net = "SPARE", .right_pin = "4", .right_net = "SPARE" },
};

const four_pads = [_][]const u8{ "1", "2", "3", "4" };
/// The right connector's pinout spells its contacts zero-padded, exactly as a
/// generated pinout file does; nothing here may treat that as a different pad.
const four_pads_padded = [_][]const u8{ "01", "02", "03", "04" };

const left_wired = [_]system_sexp.Contact{
    .{ .pin = "1", .net = "V_5V" },
    .{ .pin = "2", .net = "GND" },
    .{ .pin = "3", .net = "SCK" },
    .{ .pin = "4", .net = "SPARE" },
};
const right_wired = [_]system_sexp.Contact{
    .{ .pin = "1", .net = "V_5V_SYS" },
    .{ .pin = "2", .net = "GND" },
    .{ .pin = "3", .net = "SPI_CLK" },
    .{ .pin = "4", .net = "SPARE" },
};

fn fixtureInterface() system_review.InterfaceContract {
    return .{
        .id = "link",
        .left = .{ .board = "rf", .connector = "J1" },
        .right = .{ .board = "base", .connector = "J1" },
        .contact_count = 4,
        .signals = &base_signals,
    };
}

fn fixtureLeft() Endpoint {
    return .{ .board = "rf", .connector = "J1", .pads = &four_pads, .wired = &left_wired };
}

fn fixtureRight() Endpoint {
    return .{ .board = "base", .connector = "J1", .pads = &four_pads_padded, .wired = &right_wired };
}

fn run(
    allocator: std.mem.Allocator,
    interface: system_review.InterfaceContract,
    left: Endpoint,
    right: Endpoint,
) ![]const Finding {
    var out: std.ArrayList(Finding) = .empty;
    try check(allocator, interface, left, right, &out);
    return out.items;
}

fn firstOf(findings: []const Finding, kind: Kind) ?Finding {
    for (findings) |finding| if (finding.kind == kind) return finding;
    return null;
}

// spec: system-review - a contract whose contacts all mate reports no interface mismatch, and two differing net NAMES across the joint are never one
test "interface check accepts a sound contract and never flags a renamed net" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const findings = try run(arena_state.allocator(), fixtureInterface(), fixtureLeft(), fixtureRight());
    try testing.expectEqual(@as(usize, 0), findings.len);
    try testing.expect(!blocked(findings));
}

// spec: system-review - a contact wired on one side and unconnected or floating on the other is an error-severity interface mismatch
test "interface check reports a contact that dies on one side" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // Pad 4 has no net at all on the right.
    const dead = [_]system_sexp.Contact{
        .{ .pin = "1", .net = "V_5V_SYS" },
        .{ .pin = "2", .net = "GND" },
        .{ .pin = "3", .net = "SPI_CLK" },
        .{ .pin = "4", .net = "" },
    };
    var right = fixtureRight();
    right.wired = &dead;
    const findings = try run(allocator, fixtureInterface(), fixtureLeft(), right);
    const finding = firstOf(findings, .contact_unconnected_one_side) orelse return error.NoFinding;
    try testing.expectEqual(Severity.@"error", finding.severity());
    try testing.expectEqualStrings("base", finding.board);
    try testing.expectEqualStrings("4", finding.pin);
    try testing.expect(blocked(findings));

    // A net the board's own rule checks call floating is the same defect: the
    // contact reaches copper that goes nowhere.
    var floating = fixtureRight();
    floating.floating_nets = &.{"SPARE"};
    const floating_findings = try run(allocator, fixtureInterface(), fixtureLeft(), floating);
    try testing.expect(firstOf(floating_findings, .contact_unconnected_one_side) != null);
}

// spec: system-review - a required signal joining two supplies or grounds at different declared potentials is an error-severity interface mismatch, and an undeclared potential is not guessed
test "interface check reports a crossed supply domain and stays silent without declarations" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var left = fixtureLeft();
    left.nominals = &.{.{ .net = "V_5V", .volts = 5.0 }};
    var right = fixtureRight();
    right.nominals = &.{.{ .net = "V_5V_SYS", .volts = 3.3 }};
    const findings = try run(allocator, fixtureInterface(), left, right);
    const finding = firstOf(findings, .voltage_domain_mismatch) orelse return error.NoFinding;
    try testing.expectEqual(Severity.@"error", finding.severity());
    try testing.expect(std.mem.indexOf(u8, finding.detail, "5.000 V") != null);

    // The same rails within rounding slack are one domain.
    right.nominals = &.{.{ .net = "V_5V_SYS", .volts = 5.02 }};
    try testing.expectEqual(@as(usize, 0), (try run(allocator, fixtureInterface(), left, right)).len);

    // Neither board declaring a potential is absent evidence, not a defect.
    left.nominals = &.{};
    right.nominals = &.{};
    try testing.expectEqual(@as(usize, 0), (try run(allocator, fixtureInterface(), left, right)).len);

    // Ground is 0 V by definition, so a supply landing on a ground contact is
    // caught even though nothing declared the ground's potential.
    var crossed = base_signals;
    crossed[1].right_net = "GND";
    crossed[1].left_net = "V_5V";
    var crossed_interface = fixtureInterface();
    crossed_interface.signals = &crossed;
    left.nominals = &.{.{ .net = "V_5V", .volts = 5.0 }};
    try testing.expect(firstOf(try run(allocator, crossed_interface, left, right), .voltage_domain_mismatch) != null);
}

// spec: system-review - a signal naming a pin its connector does not carry, a contract claiming more contacts than the connector has pads, and two signals claiming one contact are error-severity interface mismatches
test "interface check reports contract defects against the connector's own pad table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var phantom = base_signals;
    phantom[3].left_pin = "9";
    var phantom_interface = fixtureInterface();
    phantom_interface.signals = &phantom;
    const phantom_findings = try run(allocator, phantom_interface, fixtureLeft(), fixtureRight());
    const unknown = firstOf(phantom_findings, .unknown_contact_pin) orelse return error.NoFinding;
    try testing.expectEqualStrings("9", unknown.pin);
    try testing.expectEqual(Severity.@"error", unknown.severity());

    var oversized = fixtureInterface();
    oversized.contact_count = 6;
    const over = firstOf(try run(allocator, oversized, fixtureLeft(), fixtureRight()), .contact_count_over_pads) orelse
        return error.NoFinding;
    try testing.expectEqual(Severity.@"error", over.severity());

    var doubled = base_signals;
    doubled[3].left_pin = "3";
    var doubled_interface = fixtureInterface();
    doubled_interface.signals = &doubled;
    const clash = firstOf(try run(allocator, doubled_interface, fixtureLeft(), fixtureRight()), .duplicate_contact_claim) orelse
        return error.NoFinding;
    try testing.expectEqual(Severity.@"error", clash.severity());
}

// spec: system-review - surplus connector pads and an unreadable connector pad table are reported without blocking, because neither names a defect
test "interface check reports absent and surplus pad evidence without blocking" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    // A shield or mounting pad beyond the contract's contacts is normal.
    const with_shield = [_][]const u8{ "1", "2", "3", "4", "SH" };
    var wide = fixtureLeft();
    wide.pads = &with_shield;
    const surplus = try run(allocator, fixtureInterface(), wide, fixtureRight());
    try testing.expect(firstOf(surplus, .contacts_not_covered) != null);
    try testing.expect(!blocked(surplus));

    // A connector with no readable pinout is absent evidence: it is said out
    // loud and the checks it would have fed are skipped, not faked.
    var blind = fixtureLeft();
    blind.pads = &.{};
    const unavailable = try run(allocator, fixtureInterface(), blind, fixtureRight());
    try testing.expect(firstOf(unavailable, .connector_pinout_unavailable) != null);
    try testing.expect(firstOf(unavailable, .unknown_contact_pin) == null);
    try testing.expect(!blocked(unavailable));
}

// spec: system-review - every interface finding renders its class, kind, severity and locating fields into the readiness document
test "interface findings render into the readiness document" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(allocator);
    try writeFindings(&out.writer, &.{
        .{ .kind = .contact_unconnected_one_side, .interface = "link", .board = "base", .pin = "4", .detail = "dead" },
        .{ .kind = .manifest_shadowed, .detail = "shadowed" },
    });
    const rendered = try std.fmt.allocPrint(allocator, "[{s}]", .{out.written()});
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, rendered, .{});
    try testing.expectEqualStrings("interface_mismatch", parsed.array.items[0].object.get("class").?.string);
    try testing.expectEqualStrings("error", parsed.array.items[0].object.get("severity").?.string);
    try testing.expectEqualStrings("4", parsed.array.items[0].object.get("pin").?.string);
    try testing.expectEqualStrings("manifest_shadowed", parsed.array.items[1].object.get("class").?.string);
    try testing.expectEqualStrings("warning", parsed.array.items[1].object.get("severity").?.string);
}
