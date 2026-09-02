//! Item-level interpretation of the generated Board Review Audit.
//!
//! This layer is intentionally conservative. A deterministic pass is emitted
//! only when an existing analyzer proves the checklist's complete predicate.
//! Clear absence can close a component/interface family as N/A. Everything
//! else becomes an evidence packet for an agent or a person instead of a
//! misleading green checkbox.

const std = @import("std");
const catalog = @import("board_review_catalog.zig");
const json_writer = @import("json_writer.zig");
const review_audit = @import("review_audit.zig");

/// Machine-generated checklist disposition before a saved override is applied.
pub const Verdict = enum { open, pass, fail, na };
/// Evidence mechanism responsible for closing or queuing a checklist item.
pub const Method = enum { static, agent, manual };
/// Whether the evaluated board contains the population or feature in question.
pub const Applicability = enum { applies, not_applicable, uncertain };

/// Generated classification fields kept together for bounded item records.
pub const Classification = struct {
    verdict: Verdict = .open,
    method: Method = .agent,
    applicability: Applicability = .applies,
    confidence: u8 = 0,
};

/// One generated checklist result and its evidence packet.
pub const Item = struct {
    id: []const u8,
    text: []const u8,
    classification: Classification = .{},
    summary: []const u8 = "Queued for agent review",
    evidence: []const u8 = "No deterministic rule currently proves the complete criterion.",
    source: []const u8 = "board review catalog",
};

/// Totals displayed in the generated-review dashboard.
pub const Summary = struct {
    total: usize = 0,
    static_pass: usize = 0,
    static_fail: usize = 0,
    not_applicable: usize = 0,
    agent_queue: usize = 0,
    manual_queue: usize = 0,
};

fn itemText(line: []const u8) ?struct { id: []const u8, text: []const u8 } {
    const prefix = "- [ ] **";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = line[prefix.len..];
    const end = std.mem.indexOf(u8, rest, "**") orelse return null;
    const id = rest[0..end];
    if (!catalog.validItemId(id)) return null;
    return .{ .id = id, .text = std.mem.trim(u8, rest[end + 2 ..], " \t") };
}

fn isManualDefault(id: []const u8) bool {
    const exact = [_][]const u8{
        "1.6",  "1.8",  "1.10", "1.11", "1.12", "1.13",
        "8.19", "9.7",  "9.8",  "9.10", "11.7", "11.8",
        "12.2", "12.4", "12.5", "12.7",
    };
    for (exact) |candidate| if (std.mem.eql(u8, id, candidate)) return true;
    return false;
}

fn parseCatalog(allocator: std.mem.Allocator) std.mem.Allocator.Error![]Item {
    var out: std.ArrayList(Item) = .empty;
    var lines = std.mem.splitScalar(u8, catalog.markdown, '\n');
    while (lines.next()) |line| {
        const parsed = itemText(line) orelse continue;
        const manual = isManualDefault(parsed.id);
        try out.append(allocator, .{
            .id = parsed.id,
            .text = parsed.text,
            .classification = .{ .method = if (manual) .manual else .agent },
            .summary = if (manual) "Human decision or physical evidence required" else "Queued for agent review",
            .evidence = if (manual)
                "The design files cannot establish this product decision, vendor acceptance, or measured behavior."
            else
                "No deterministic rule currently proves the complete criterion; an agent should inspect the cited design and datasheet evidence.",
        });
    }
    return try out.toOwnedSlice(allocator);
}

fn find(items: []Item, id: []const u8) ?*Item {
    for (items) |*item| if (std.mem.eql(u8, item.id, id)) return item;
    return null;
}

fn set(
    items: []Item,
    comptime id: []const u8,
    verdict: Verdict,
    applicability: Applicability,
    confidence: u8,
    summary: []const u8,
    evidence: []const u8,
    comptime source: []const u8,
) void {
    const item = find(items, id) orelse return;
    item.classification = .{
        .verdict = verdict,
        .method = .static,
        .applicability = applicability,
        .confidence = confidence,
    };
    item.summary = summary;
    item.evidence = evidence;
    item.source = source;
}

fn addAgentEvidence(items: []Item, id: []const u8, summary: []const u8, evidence: []const u8, source: []const u8) void {
    const item = find(items, id) orelse return;
    if (item.classification.method == .manual) return;
    item.summary = summary;
    item.evidence = evidence;
    item.source = source;
    item.classification.confidence = 60;
}

fn markPrefixNa(items: []Item, prefix: []const u8, evidence: []const u8) void {
    for (items) |*item| {
        if (!std.mem.startsWith(u8, item.id, prefix)) continue;
        item.classification = .{
            .verdict = .na,
            .method = .static,
            .applicability = .not_applicable,
            .confidence = 98,
        };
        item.summary = "Not applicable — no matching populated devices detected";
        item.evidence = evidence;
        item.source = "evaluated component inventory";
    }
}

fn hasFinding(facts: review_audit.Facts, kinds: []const []const u8) bool {
    for (facts.findings) |finding| for (kinds) |kind| {
        if (std.mem.eql(u8, finding.source, kind)) return true;
    };
    return false;
}

fn countFindings(facts: review_audit.Facts, kinds: []const []const u8) usize {
    var count: usize = 0;
    for (facts.findings) |finding| for (kinds) |kind| {
        if (std.mem.eql(u8, finding.source, kind)) {
            count += 1;
            break;
        }
    };
    return count;
}

fn hasFabId(ids: []const []const u8, wanted: []const []const u8) bool {
    for (ids) |id| for (wanted) |candidate| if (std.mem.eql(u8, id, candidate)) return true;
    return false;
}

fn layoutFrozen(facts: review_audit.Facts) bool {
    if (!facts.layout.available) return false;
    var placement = false;
    var sub_circuits = false;
    for (facts.layout.ladder) |stage| {
        const done = std.mem.eql(u8, stage.status, "done") or std.mem.eql(u8, stage.status, "complete") or
            (stage.total > 0 and stage.done == stage.total);
        if (std.mem.eql(u8, stage.id, "placement")) placement = done;
        if (std.mem.eql(u8, stage.id, "sub_circuits")) sub_circuits = done;
    }
    return placement and sub_circuits;
}

fn classifyPassiveApplicability(items: []Item, passives: review_audit.PassiveInventory) void {
    if (passives.resistors == 0) markPrefixNa(items, "3.1.", "0 populated resistors");
    const caps = passives.capacitors;
    if (caps.total == 0) {
        markPrefixNa(items, "3.2.", "0 populated capacitors");
        markPrefixNa(items, "3.3.", "0 populated capacitors");
        markPrefixNa(items, "3.4.", "0 populated capacitors");
        markPrefixNa(items, "3.5.", "0 populated capacitors");
    } else if (caps.unknown_caps == 0) {
        if (caps.ceramic_caps == 0) markPrefixNa(items, "3.2.", "0 populated ceramic capacitors");
        if (caps.tantalum_caps == 0) markPrefixNa(items, "3.3.", "0 populated tantalum capacitors");
        if (caps.electrolytic_caps == 0) markPrefixNa(items, "3.4.", "0 populated aluminum electrolytic capacitors");
        if (caps.film_caps == 0) markPrefixNa(items, "3.5.", "0 populated film or safety-rated capacitors");
    }
    if (passives.inductors + passives.ferrites == 0) markPrefixNa(items, "3.6.", "0 populated inductors or ferrite beads");
}

fn classifyDeviceApplicability(items: []Item, inv: review_audit.Inventory) void {
    const devices = inv.devices;
    const population = inv.population;
    if (devices.diodes == 0) markPrefixNa(items, "3.7.", "0 populated rectifier/switching/Schottky diodes");
    if (devices.transistors == 0) markPrefixNa(items, "3.9.", "0 populated MOSFETs or BJTs");
    if (devices.fuses == 0) markPrefixNa(items, "3.10.", "0 populated fuse or PPTC devices");
    if (devices.crystals == 0) markPrefixNa(items, "3.11.", "0 populated crystals or oscillators");
    if (devices.tvs_esd == 0 and devices.diodes == 0) markPrefixNa(items, "3.8.", "0 populated diode-class devices");
    if (devices.connectors == 0) {
        inline for (.{ "3.12.1", "3.12.2", "3.12.3" }) |id|
            set(items, id, .na, .not_applicable, 98, "Not applicable — no populated connectors detected", "0 populated connectors", "evaluated component inventory");
    }
    if (devices.relays == 0) set(items, "3.12.4", .na, .not_applicable, 98, "Not applicable — no populated relays detected", "0 populated relays", "evaluated component inventory");
    if (population.optocouplers == 0 and population.active_ics == 0) set(items, "3.12.5", .na, .not_applicable, 98, "Not applicable — no populated optocouplers detected", "0 populated optocouplers or unclassified active devices", "evaluated component inventory");
    if (population.leds == 0 and devices.diodes == 0) set(items, "3.12.6", .na, .not_applicable, 98, "Not applicable — no populated LEDs detected", "0 populated LED or unclassified diode devices", "evaluated component inventory");
    if (population.active_ics == 0) markPrefixNa(items, "4.", "0 populated active semiconductors");
    if (devices.crystals == 0) set(items, "4.5.3", .na, .not_applicable, 98, "Not applicable — no crystal network detected", "0 populated crystals or oscillators", "evaluated component inventory");
}

fn classifyInterfaceApplicability(items: []Item, inv: review_audit.Inventory) void {
    const interfaces = inv.interfaces;
    const no_unclassified_ic = inv.population.active_ics == 0;
    if (!interfaces.has_programmable and no_unclassified_ic) {
        inline for (.{ "4.5.4", "4.5.5", "10.1", "10.2", "10.3", "10.4", "10.5", "10.6", "10.7" }) |id|
            set(items, id, .na, .not_applicable, 95, "Not applicable — no programmable controller/processor detected", "No MCU, processor, SoC, or FPGA population was detected.", "evaluated component inventory");
    }
    if (!interfaces.has_fpga and no_unclassified_ic) {
        inline for (.{ "4.5.5", "4.5.8" }) |id|
            set(items, id, .na, .not_applicable, 98, "Not applicable — no FPGA population detected", "No FPGA component was detected.", "evaluated component inventory");
    }
    if (!interfaces.has_i2c and no_unclassified_ic) markPrefixNa(items, "4.6.", "No I²C/SDA/SCL nets or active devices were detected");
    if (!interfaces.has_i2c and no_unclassified_ic) set(items, "4.5.6", .na, .not_applicable, 96, "Not applicable — no I²C bus detected", "No I²C/SDA/SCL nets, components, or unclassified active devices were detected.", "evaluated net inventory");
    if (!interfaces.has_can_or_rs485 and no_unclassified_ic and inv.devices.connectors == 0) set(items, "6.16", .na, .not_applicable, 96, "Not applicable — no CAN or RS-485 bus detected", "No CAN/RS-485 names, unclassified active devices, or connectors were detected.", "evaluated net inventory");
    if (!interfaces.has_current_sense and inv.passives.resistors == 0) {
        inline for (.{ "3.1.5", "3.1.6", "5.4.4" }) |id|
            set(items, id, .na, .not_applicable, 90, "Not applicable — no current-sense/shunt population detected", "No populated component names or descriptions identify a current-sense resistor or shunt.", "evaluated component inventory");
    }
}

fn classifyPowerApplicability(allocator: std.mem.Allocator, items: []Item, inv: review_audit.Inventory) std.mem.Allocator.Error!void {
    const no_unclassified_ic = inv.population.active_ics == 0;
    if (!inv.power.has_ldo and no_unclassified_ic) markPrefixNa(items, "5.2.", "No populated LDO, linear regulator, or unclassified active device was detected");
    if (!inv.power.has_switcher and no_unclassified_ic) markPrefixNa(items, "5.3.", "No populated switcher or unclassified active device was detected");
    if (!inv.power.has_battery and inv.devices.connectors == 0 and inv.power.input_power_ports == 0) markPrefixNa(items, "5.5.", "No battery domain, input-power port, or connector was detected");
    if (inv.devices.connectors == 0) set(items, "7.1", .na, .not_applicable, 92, "Not applicable — no cable connector population detected", "0 populated connectors", "evaluated component inventory");
    if (!inv.board.has_high_voltage and inv.power.max_dc_v > 0) {
        set(items, "1.7", .na, .not_applicable, 90, "Not applicable to the detected SELV voltage range", try std.fmt.allocPrint(allocator, "Highest derived/declared DC magnitude is {d:.2} V; no mains/HV domain was detected.", .{inv.power.max_dc_v}), "evaluated voltage envelopes");
        if (inv.passives.capacitors.film_caps == 0 and inv.passives.capacitors.unknown_caps == 0) set(items, "3.5.2", .na, .not_applicable, 96, "Not applicable — no mains or safety-capacitor domain detected", "No mains/HV domain and no X/Y safety capacitor were detected.", "evaluated inventory and voltage envelopes");
    }
}

fn classifyApplicability(allocator: std.mem.Allocator, items: []Item, inv: review_audit.Inventory) std.mem.Allocator.Error!void {
    classifyPassiveApplicability(items, inv.passives);
    classifyDeviceApplicability(items, inv);
    classifyInterfaceApplicability(items, inv);
    try classifyPowerApplicability(allocator, items, inv);
}

fn applyPowerAndOutlineRules(allocator: std.mem.Allocator, items: []Item, facts: review_audit.Facts) std.mem.Allocator.Error!void {
    const inv = facts.inventory;
    const power = inv.power;
    const board = inv.board;
    const power_findings = countFindings(facts, &.{ "power_budget", "rail_voltage_unresolved" });
    if (power.rails > 0) {
        const evidence = try std.fmt.allocPrint(allocator, "{d} rail(s); {d} unresolved power-budget/rail finding(s).", .{ power.rails, power_findings });
        set(items, "1.3", if (power_findings == 0) .pass else .fail, .applies, 95, if (power_findings == 0) "Worst-case rail budget is declared and clean" else "Power-budget evidence is incomplete or failing", evidence, "power budget + ERC");
        set(items, "2.10", if (power_findings == 0) .pass else .fail, .applies, 95, if (power_findings == 0) "Every derived rail budget clears its source capacity" else "One or more rail budgets are unresolved or over capacity", evidence, "power budget + ERC");
        set(items, "5.4.6", if (power_findings == 0) .pass else .fail, .applies, 92, if (power_findings == 0) "Generated rail budget covers the declared board loads" else "Generated rail budget has open findings", evidence, "power budget + ERC");
    }

    if (!board.has_outline) {
        set(items, "1.14", .fail, .applies, 99, "Board outline/mechanical envelope is missing", "The evaluated board has no authored outline with non-zero size.", "board declaration");
        set(items, "8.16", .fail, .applies, 99, "Board outline cannot be matched", "The evaluated board has no authored outline with non-zero size.", "board declaration");
    } else addAgentEvidence(items, "1.14", "Mechanical outline exists; agent must compare the remaining enclosure interfaces", "An authored non-zero board outline is present.", "board declaration");
}

fn applySchematicRules(allocator: std.mem.Allocator, items: []Item, facts: review_audit.Facts) std.mem.Allocator.Error!void {
    const population = facts.inventory.population;
    const power = facts.inventory.power;
    const board = facts.inventory.board;
    const erc_total = facts.schematic.erc_errors + facts.schematic.erc_warnings;
    set(items, "2.1", if (erc_total == 0) .pass else .fail, .applies, 99, if (erc_total == 0) "ERC is clean" else "ERC has unresolved findings", try std.fmt.allocPrint(allocator, "ERC returned {d} error(s) and {d} warning(s).", .{ facts.schematic.erc_errors, facts.schematic.erc_warnings }), "netlisp ERC");

    const connectivity_kinds = &.{ "floating_net", "unconnected_pin", "no_connect", "strap_tied_to_rail" };
    const connectivity = countFindings(facts, connectivity_kinds);
    set(items, "2.2", if (connectivity == 0) .pass else .fail, .applies, 98, if (connectivity == 0) "No unintended floating/unconnected input findings" else "Floating, no-connect, or strap findings remain", try std.fmt.allocPrint(allocator, "{d} matching ERC finding(s).", .{connectivity}), "ERC connectivity checks");

    if (hasFinding(facts, &.{"pin_multi_net"})) set(items, "2.3", .fail, .applies, 99, "A physical pin is assigned to multiple nets", "ERC emitted pin_multi_net.", "ERC pin/net consistency");
    if (hasFinding(facts, &.{"source_unused"})) set(items, "2.4", .fail, .applies, 95, "Unused or unresolved named source nets remain", "ERC emitted source_unused.", "ERC net-use checks");
    if (hasFinding(facts, &.{ "missing_footprint", "unresolvable-pin", "pin_function_unsupported", "pin_function_required" }))
        set(items, "2.6", .fail, .applies, 98, "Symbol/package evidence has structural failures", "Missing footprint or unresolved/unsupported physical pin evidence is present.", "ERC + fabrication gate");

    const rail_tree_bad = hasFinding(facts, &.{"rail_voltage_unresolved"});
    if (power.rails > 0) set(items, "2.9", if (rail_tree_bad) .fail else .pass, .applies, 95, if (rail_tree_bad) "Power tree contains an unresolved rail" else "Power tree is derived and every rail voltage resolves", try std.fmt.allocPrint(allocator, "{d} derived rail(s).", .{power.rails}), "rail graph + ERC");
    const sequence_bad = hasFinding(facts, &.{"sequence_cycle"});
    if (power.rails > 0 and sequence_bad) set(items, "2.11", .fail, .applies, 99, "Power sequence contains a cycle", "ERC emitted sequence_cycle.", "power sequencing");
    if (power.rails > 0 and !sequence_bad) addAgentEvidence(items, "2.11", "Sequence graph is acyclic; agent must verify device-specific timing", "No sequence_cycle finding; the rail ordering is available in the generated review.", "power sequencing");

    const identity_bad = hasFinding(facts, &.{"duplicate_refdes"}) or hasFabId(facts.fab.error_ids, &.{ "missing-identity", "duplicate-identity", "centroid-parity" });
    set(items, "2.12", if (identity_bad) .fail else .pass, .applies, 97, if (identity_bad) "Reference/PCB identities are inconsistent" else "Reference designators and PCB identities are unique and aligned", if (identity_bad) "Duplicate refdes, missing/duplicate identity, or centroid parity evidence is present." else "ERC and fabrication identity checks returned no inconsistency.", "ERC + fabrication identity gate");
    set(items, "2.13", .pass, .applies, 94, "DNP population is explicitly represented in the generated BOM", try std.fmt.allocPrint(allocator, "{d} DNP placement(s); the BOM and centroid exporters share the evaluated DNP flag.", .{population.dnp}), "evaluated BOM/centroid model");

    const tp_bad = hasFinding(facts, &.{"test_point_missing"});
    set(items, "2.14", if (!tp_bad and population.test_points > 0) .pass else .fail, .applies, 96, if (!tp_bad and population.test_points > 0) "Required rail test-point coverage is present" else "Test-point coverage is missing or empty", try std.fmt.allocPrint(allocator, "{d} test point(s); test_point_missing={s}.", .{ population.test_points, if (tp_bad) "true" else "false" }), "ERC test-point coverage");
    if (!board.has_revision) set(items, "2.15", .fail, .applies, 99, "Board revision declaration is missing", "No top-level revision form was evaluated.", "board declaration");
}

fn applyComponentRules(items: []Item, facts: review_audit.Facts) void {
    if (hasFinding(facts, &.{ "missing_decoupling", "decoupling_unbound", "invalid_decoupling_binding" }))
        set(items, "4.1.2", .fail, .applies, 98, "Supply-pin decoupling findings remain", "ERC reported missing or invalidly bound decoupling.", "ERC decoupling checks");
    if (hasFinding(facts, &.{"voltage_overstress"})) set(items, "4.2.1", .fail, .applies, 99, "A pin voltage exceeds its declared limit", "ERC emitted voltage_overstress.", "ERC electrical envelopes");
    if (hasFinding(facts, &.{ "voltage_domain_incompatible", "voltage_mismatch" })) set(items, "4.2.2", .fail, .applies, 99, "A driver/receiver voltage-domain mismatch remains", "ERC emitted voltage_domain_incompatible or voltage_mismatch.", "ERC electrical contracts");
    if (hasFinding(facts, &.{ "strap_tied_to_rail", "no_connect" })) set(items, "4.3.1", .fail, .applies, 98, "Boot/strap input definition findings remain", "ERC emitted strap_tied_to_rail or no_connect.", "ERC strap/no-connect checks");
    if (hasFinding(facts, &.{"diff_pair_half_connected"})) set(items, "4.5.7", .fail, .applies, 99, "A differential pair is only half connected", "ERC emitted diff_pair_half_connected.", "ERC differential-pair checks");
}

fn applyAssemblyAndBomRules(allocator: std.mem.Allocator, items: []Item, facts: review_audit.Facts) std.mem.Allocator.Error!void {
    const population = facts.inventory.population;
    const board = facts.inventory.board;
    const fid_evidence = try std.fmt.allocPrint(allocator, "{d} populated fiducial(s).", .{population.fiducials});
    set(items, "8.15", if (population.fiducials > 0) .pass else .fail, .applies, 99, if (population.fiducials > 0) "Fiducials are present" else "No fiducials were detected", fid_evidence, "evaluated component inventory");
    if (hasFabId(facts.fab.error_ids, &.{ "no-outline", "outline-drift", "malformed-outline", "part-off-board" })) {
        set(items, "8.16", .fail, .applies, 99, "Board/mechanical outline gate is failing", "Fabrication readiness reports missing/drifted/malformed outline or an off-board part.", "fabrication readiness");
    } else if (board.has_outline) {
        addAgentEvidence(items, "8.16", "Board outline is internally consistent; agent must compare connector access and the mechanical drawing", "No outline-related fabrication finding is present.", "fabrication readiness");
    }

    const bom_bad = hasFabId(facts.fab.error_ids, &.{ "bom-identity", "missing-identity", "duplicate-identity", "centroid-parity", "dnp-in-centroid" });
    set(items, "9.1", if (facts.fab.available and !bom_bad) .pass else .fail, .applies, 97, if (facts.fab.available and !bom_bad) "Evaluated BOM, placement, identities, and DNP population agree" else "BOM/placement identity evidence is incomplete or failing", try std.fmt.allocPrint(allocator, "{d} populated part(s), {d} DNP part(s); fab evidence available={s}.", .{ facts.fab.stats.parts, facts.fab.stats.dnp, if (facts.fab.available) "true" else "false" }), "fabrication BOM identity gate");
    if (hasFabId(facts.fab.error_ids, &.{"bom-identity"})) set(items, "9.2", .fail, .applies, 99, "One or more populated BOM lines lack manufacturer/MPN identity", "Fabrication readiness emitted bom-identity.", "fabrication BOM identity gate");
    if (hasFabId(facts.fab.error_ids, &.{ "footprint-geometry-unresolved", "unresolvable-pin" })) set(items, "9.3", .fail, .applies, 99, "Footprint/package geometry is unresolved", "Fabrication readiness emitted footprint-geometry-unresolved or unresolvable-pin.", "fabrication readiness");
}

fn applyReleaseRules(allocator: std.mem.Allocator, items: []Item, facts: review_audit.Facts) std.mem.Allocator.Error!void {
    const population = facts.inventory.population;
    const board = facts.inventory.board;
    const tp_bad = hasFinding(facts, &.{"test_point_missing"});
    if (facts.fab.available) {
        set(items, "11.1", if (facts.fab.ok) .pass else .fail, .applies, 96, if (facts.fab.ok) "Fabrication dataset passes the release-readiness gate" else "Fabrication dataset is blocked", try std.fmt.allocPrint(allocator, "Fab gate: {d} error id(s), {d} warning id(s), {d}/{d} routable nets connected.", .{ facts.fab.error_ids.len, facts.fab.warning_ids.len, facts.fab.stats.connected, facts.fab.stats.routable }), "fabrication readiness");
        const drill_bad = hasFabId(facts.fab.error_ids, &.{"via-no-drill"});
        if (drill_bad) {
            set(items, "11.2", .fail, .applies, 99, "A drill-bearing feature lacks drill geometry", "Fabrication readiness emitted via-no-drill.", "fabrication readiness");
        } else if (facts.fab.ok) {
            set(items, "11.2", .pass, .applies, 95, "Drill files and drill-bearing geometry pass fabrication readiness", "The complete fabrication gate passed with no via-no-drill finding.", "fabrication readiness");
        } else {
            addAgentEvidence(items, "11.2", "No drill-geometry error; agent must verify the separated drill files, chart, and legend", "Fabrication readiness emitted no via-no-drill finding, but unrelated fabrication errors prevent a complete static pass.", "fabrication readiness");
        }
    }

    set(items, "12.3", if (!tp_bad and population.test_points > 0) .pass else .fail, .applies, 94, if (!tp_bad and population.test_points > 0) "Generated rail/key-signal test-point coverage is present" else "Generated test-point coverage is incomplete", try std.fmt.allocPrint(allocator, "{d} test point(s); test_point_missing={s}.", .{ population.test_points, if (tp_bad) "true" else "false" }), "ERC test-point coverage");
    const frozen = layoutFrozen(facts);
    const freeze_prereqs = board.has_revision and frozen;
    if (!freeze_prereqs or facts.schematic.notes_open > 0) {
        set(items, "12.6", .fail, .applies, 96, "Review freeze/sign-off prerequisites are not closed", try std.fmt.allocPrint(allocator, "revision={s}; layout_frozen={s}; open design notes={d}.", .{ if (board.has_revision) "present" else "missing", if (frozen) "true" else "false", facts.schematic.notes_open }), "revision + layout ladder + design notes");
    } else addAgentEvidence(items, "12.6", "Revision and layout are frozen with no open notes; agent must confirm the sign-off record", "Revision present, placement/sub-circuits complete, and no open design notes.", "revision + layout ladder + design notes");
}

fn inheritRepeatedGotchas(allocator: std.mem.Allocator, items: []Item) std.mem.Allocator.Error!void {
    // Repeated gotchas inherit an exact generated verdict when their primary
    // checklist item was already closed; otherwise they stay independently in
    // the agent queue rather than multiplying unsupported confidence.
    const aliases = [_]struct { target: []const u8, source: []const u8 }{
        .{ .target = "13.1", .source = "3.2.1" },  .{ .target = "13.2", .source = "3.6.8" },
        .{ .target = "13.3", .source = "3.3.1" },  .{ .target = "13.5", .source = "3.11.1" },
        .{ .target = "13.6", .source = "4.2.2" },  .{ .target = "13.10", .source = "2.8" },
        .{ .target = "13.13", .source = "3.2.6" }, .{ .target = "13.14", .source = "4.5.9" },
        .{ .target = "13.15", .source = "2.6" },   .{ .target = "13.4", .source = "4.5.1" },
        .{ .target = "13.7", .source = "10.5" },   .{ .target = "13.8", .source = "6.4" },
        .{ .target = "13.9", .source = "5.3.8" },  .{ .target = "13.11", .source = "3.12.6" },
    };
    for (aliases) |alias| {
        const source = find(items, alias.source) orelse continue;
        if (source.classification.verdict == .open) continue;
        const target = find(items, alias.target) orelse continue;
        target.classification = source.classification;
        target.summary = "Inherited from the primary checklist criterion";
        target.evidence = try std.fmt.allocPrint(allocator, "Mirrors checklist {s}: {s}", .{ alias.source, source.evidence });
        target.source = source.source;
    }
}

fn applyStaticRules(allocator: std.mem.Allocator, items: []Item, facts: review_audit.Facts) std.mem.Allocator.Error!void {
    try applyPowerAndOutlineRules(allocator, items, facts);
    try applySchematicRules(allocator, items, facts);
    applyComponentRules(items, facts);
    try applyAssemblyAndBomRules(allocator, items, facts);
    try applyReleaseRules(allocator, items, facts);
    try inheritRepeatedGotchas(allocator, items);
}

/// Generate applicability, deterministic results, and remaining work packets.
pub fn build(allocator: std.mem.Allocator, facts: review_audit.Facts) std.mem.Allocator.Error![]Item {
    const items = try parseCatalog(allocator);
    try classifyApplicability(allocator, items, facts.inventory);
    try applyStaticRules(allocator, items, facts);
    return items;
}

/// Count static and queued generated results.
pub fn summarize(items: []const Item) Summary {
    var summary: Summary = .{ .total = items.len };
    for (items) |item| switch (item.classification.verdict) {
        .pass => summary.static_pass += 1,
        .fail => summary.static_fail += 1,
        .na => summary.not_applicable += 1,
        .open => if (item.classification.method == .manual) {
            summary.manual_queue += 1;
        } else {
            summary.agent_queue += 1;
        },
    };
    return summary;
}

/// Serialize generated assessment data with the canonical JSON string writer.
pub fn writeAssessmentJson(w: *std.Io.Writer, items: []const Item) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    const summary = summarize(items);
    try w.print("{{\"summary\":{{\"total\":{d},\"static_pass\":{d},\"static_fail\":{d},\"not_applicable\":{d},\"agent_queue\":{d},\"manual_queue\":{d}}},\"items\":[", .{
        summary.total, summary.static_pass, summary.static_fail, summary.not_applicable, summary.agent_queue, summary.manual_queue,
    });
    for (items, 0..) |item, index| {
        if (index > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":");
        try json_writer.writeString(w, item.id);
        try w.writeAll(",\"text\":");
        try json_writer.writeString(w, item.text);
        try w.writeAll(",\"verdict\":");
        try json_writer.writeString(w, @tagName(item.classification.verdict));
        try w.writeAll(",\"method\":");
        try json_writer.writeString(w, @tagName(item.classification.method));
        try w.writeAll(",\"applicability\":");
        try json_writer.writeString(w, @tagName(item.classification.applicability));
        try w.print(",\"confidence\":{d},\"summary\":", .{item.classification.confidence});
        try json_writer.writeString(w, item.summary);
        try w.writeAll(",\"evidence\":");
        try json_writer.writeString(w, item.evidence);
        try w.writeAll(",\"source\":");
        try json_writer.writeString(w, item.source);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

// spec: serve/board-review - generated applicability closes an absent component or interface family only from evaluated board inventory, while present or uncertain families remain queued unless an analyzer proves the complete criterion
// spec: serve/board-review - generated Pass and Fail decisions cite current ERC, power-budget, layout, fabrication, BOM, identity, test-point, or board-declaration evidence rather than the saved sidecar
test "assessment closes only exact static and clear N-A predicates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const facts = review_audit.Facts{
        .identity = .{ .name = "demo", .revision = "A", .part_number = "P", .layout = "release", .project_status = "clean", .tool_commit = "t", .generated_at = "now" },
        .inventory = .{
            .passives = .{ .resistors = 2, .capacitors = .{ .total = 4, .ceramic_caps = 4 } },
            .population = .{ .test_points = 2, .fiducials = 3 },
            .power = .{ .rails = 2, .max_dc_v = 12 },
            .board = .{ .has_outline = true, .has_revision = true },
        },
        .fab = .{ .available = true, .ok = true, .stats = .{ .parts = 8, .nets = 3, .routable = 3, .connected = 3 } },
        .layout = .{ .available = true, .ladder = &.{
            .{ .id = "placement", .status = "done", .done = 8, .total = 8 },
            .{ .id = "sub_circuits", .status = "done", .done = 1, .total = 1 },
        } },
    };
    const items = try build(arena, facts);
    try std.testing.expectEqual(catalog.item_count, items.len);
    try std.testing.expectEqual(Verdict.pass, find(items, "2.1").?.classification.verdict);
    try std.testing.expectEqual(Verdict.pass, find(items, "8.15").?.classification.verdict);
    try std.testing.expectEqual(Verdict.na, find(items, "3.3.1").?.classification.verdict);
    try std.testing.expectEqual(Verdict.na, find(items, "3.8.1").?.classification.verdict);
    try std.testing.expectEqual(Verdict.na, find(items, "13.11").?.classification.verdict);
    try std.testing.expectEqual(Method.agent, find(items, "3.1.1").?.classification.method);
    try std.testing.expectEqual(Verdict.open, find(items, "3.1.1").?.classification.verdict);

    var unrelated_fab_failure = facts;
    unrelated_fab_failure.fab.ok = false;
    unrelated_fab_failure.fab.error_ids = &.{"outline-drift"};
    const blocked_items = try build(arena, unrelated_fab_failure);
    try std.testing.expectEqual(Verdict.open, find(blocked_items, "11.2").?.classification.verdict);
    try std.testing.expectEqual(Method.agent, find(blocked_items, "11.2").?.classification.method);
}
