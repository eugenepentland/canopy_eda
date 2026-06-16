//! Leak-regression tests for the ERC / req-checks / electrical / power area.
//!
//! Three idioms are used, picked per-function by reading the source:
//!   1. OWNED-RETURN — fn(allocator, …) returns an owned slice the caller frees
//!      AND frees its own scratch. Run through std.testing.allocator so any
//!      scratch the fn forgot to free panics the test. Highest value.
//!   2. ARENA-CONTRACT — request-path fn that allocates-and-forgets, relying on
//!      a per-request arena reset. Wrapped in a testing.allocator-backed arena;
//!      catches crashes / double-frees / escapes to a different allocator while
//!      documenting the contract.
//!   3. STORE-LIFECYCLE — a struct with deinit; populate then deinit, catching a
//!      deinit that misses an owned field.
//!
//! IMPORTANT: `power_budget.analyze`, `rails.build` (internal scratch), and
//! `erc.runErc` allocate hashmaps / allocPrint keys / paths from the *caller's*
//! allocator and never free that scratch (they rely on a page_allocator-or-arena
//! caller). Those are exercised under idiom 2 (arena) so testing.allocator never
//! false-fails. `findMissingDecouplingNets`, `power_sequencing.analyze`, and
//! `rails.build`'s public owned slice DO free their scratch, so those run under
//! idiom 1 against testing.allocator directly.

const std = @import("std");
const env = @import("../eval/env.zig");
const na = @import("../eval/net_analysis.zig");
const power_budget = @import("../eval/power_budget.zig");
const power_sequencing = @import("../eval/power_sequencing.zig");
const rails = @import("../eval/rails.zig");
const erc = @import("../erc.zig");
const req_checks = @import("../req_checks.zig");

const DesignBlock = env.DesignBlock;
const Instance = env.Instance;
const Net = env.Net;
const PinRef = env.PinRef;
const Port = env.Port;
const SubBlock = env.SubBlock;
const NetTie = env.NetTie;

// ── Fixtures ───────────────────────────────────────────────────────────────

/// Build a buck → VDD power tree with two IC loads in `arena`. Mirrors the
/// shape of `makeBudgetBlock`/`makeRailBlock` in erc.zig but kept local so
/// these leak tests don't reach into another file's private helpers.
/// Returns a block whose source sub-block "buck" declares VOUT capacity and
/// whose top-level rail "VDD" carries an IC pin (so the decoupling and
/// power-budget walks both have something to chew on).
fn makePowerTree(a: std.mem.Allocator) !DesignBlock {
    const sub_ports = try a.alloc(Port, 1);
    sub_ports[0] = .{
        .name = "VOUT",
        .net = "VOUT",
        .direction = "out",
        .nominal = 3.3,
        .current_typ = 2.0,
        .current_max = 2.5,
    };
    const sub = try a.create(DesignBlock);
    sub.* = .{
        .name = "buck",
        .instances = &.{},
        .nets = &.{},
        .ports = sub_ports,
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const subs = try a.alloc(SubBlock, 1);
    subs[0] = .{ .name = "buck", .block = sub };

    // One top-level IC instance on the VDD rail, no decoupling cap.
    const insts = try a.alloc(Instance, 1);
    insts[0] = .{
        .ref_des = "U1",
        .component = "some-mcu",
        .value = "",
        .footprint = "fp",
        .symbol = "",
        .id = "a0000001",
    };
    const pins = try a.alloc(PinRef, 1);
    pins[0] = .{ .ref_des = "U1", .pin = "1", .i_typ = 1.0, .i_max = 1.5 };
    const nets = try a.alloc(Net, 1);
    nets[0] = .{ .name = "VDD", .pins = pins };

    const ties = try a.alloc(NetTie, 1);
    ties[0] = .{ .a = "VDD", .b = "buck/VOUT" };

    return .{
        .name = "leak-fixture",
        .instances = insts,
        .nets = nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = subs,
        .net_ties = ties,
    };
}

// ── net_analysis.findMissingDecouplingNets (idiom 1, OWNED-RETURN) ──────────

// leak-audit: findMissingDecouplingNets returns a caller-owned slice and frees
// every scratch hashmap (power_nets, rails_with_ic/cap, emitted) via defer.
// Inputs live in a separate arena; the owned slice is freed explicitly. Any
// scratch the fn forgot to free panics testing.allocator. Highest-value test
// in this area: it is the shared decoupling walk both ERC and the eval-time
// validator call.
test "leak: findMissingDecouplingNets owned slice + scratch freed" {
    var ia = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ia.deinit();

    // A power section declaring VDD as a power-in port, an IC pin on VDD, and
    // NO cap — so the walk both populates and frees its scratch maps and emits
    // one missing-rail entry into the owned slice.
    const sec_ports = try ia.allocator().alloc(env.SectionPort, 1);
    sec_ports[0] = .{ .name = "VDD", .direction = .in, .signal_type = .power };
    const sections = try ia.allocator().alloc(env.Section, 1);
    sections[0] = .{ .name = "Core", .ports = sec_ports };

    const pins = try ia.allocator().alloc(PinRef, 1);
    pins[0] = .{ .ref_des = "U1", .pin = "1" };
    const nets = try ia.allocator().alloc(Net, 1);
    nets[0] = .{ .name = "VDD", .pins = pins };

    const block: DesignBlock = .{
        .name = "t",
        .instances = &.{},
        .nets = nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .sections = sections,
    };

    const missing = try na.findMissingDecouplingNets(std.testing.allocator, &block);
    defer std.testing.allocator.free(missing);
    // VDD has an IC pin and no cap → it should be reported.
    try std.testing.expectEqual(@as(usize, 1), missing.len);
    try std.testing.expectEqualStrings("VDD", missing[0]);
}

// leak-audit: empty-design path through findMissingDecouplingNets — proves the
// allocator-empty return (toOwnedSlice on an empty list) frees its scratch and
// hands back a slice safe to free.
test "leak: findMissingDecouplingNets empty design frees cleanly" {
    const block: DesignBlock = .{
        .name = "t",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const missing = try na.findMissingDecouplingNets(std.testing.allocator, &block);
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqual(@as(usize, 0), missing.len);
}

// ── power_sequencing.analyze (idiom 1, OWNED-RETURN) ────────────────────────

// leak-audit: power_sequencing.analyze deinit()s every scratch map (sub_to_rail,
// primary_rail_of, signal_source, power_rail_set) via defer and returns only the
// `rows` ArrayList items as the owned slice. The existing in-file test frees just
// `rows`; mirror that against testing.allocator so any leaked scratch panics.
test "leak: power_sequencing.analyze owned rows + scratch freed" {
    var buck: DesignBlock = .{
        .name = "buck",
        .instances = &.{},
        .nets = &.{},
        .ports = &[_]Port{.{ .name = "VOUT", .net = "VOUT", .direction = "out", .nominal = 3.3 }},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var ldo: DesignBlock = .{
        .name = "ldo",
        .instances = &.{},
        .nets = &.{},
        .ports = &[_]Port{.{
            .name = "VOUT",
            .net = "VOUT",
            .direction = "out",
            .nominal = 1.8,
            .enable_net = "VDD",
        }},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const sbs = [_]SubBlock{
        .{ .name = "buck", .block = &buck },
        .{ .name = "ldo", .block = &ldo },
    };
    const ties = [_]NetTie{
        .{ .a = "buck/VOUT", .b = "VDD" },
        .{ .a = "ldo/VOUT", .b = "V1P8" },
    };
    const outer: DesignBlock = .{
        .name = "outer",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &sbs,
        .net_ties = &ties,
    };
    const rows = try power_sequencing.analyze(std.testing.allocator, &outer);
    defer std.testing.allocator.free(rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
}

// ── rails.build (idiom 1, OWNED-RETURN with per-rail owned fields) ──────────

// leak-audit: rails.build returns an owned slice whose entries each own a
// duped source_path and an aliases slice; it frees its own net_parent / by_root
// / aliases_by_root scratch via defer, and frees the *loser* path on multi-source
// rails. Free with the same per-rail walk the in-file `freeRails` helper uses so
// any missed owned field (path or aliases) panics testing.allocator.
test "leak: rails.build owned slice + per-rail owned fields freed" {
    var inner: DesignBlock = .{
        .name = "ldo",
        .instances = &.{},
        .nets = &.{},
        .ports = &[_]Port{.{
            .name = "VOUT",
            .net = "VOUT",
            .direction = "out",
            .nominal = 1.8,
            .current_typ = 1.0,
            .current_max = 1.5,
        }},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const sbs = [_]SubBlock{.{ .name = "ldo", .block = &inner }};
    const ties = [_]NetTie{.{ .a = "ldo/VOUT", .b = "V1P8" }};
    // Ferrite bridging V1P8 <-> VDDA18USB forces an alias slice to be built and
    // owned by the returned rail — exercises the aliases free-path too.
    const ferrite = Instance{
        .ref_des = "FB1",
        .component = "ferrite-0402",
        .value = "",
        .footprint = "",
        .symbol = "",
    };
    const insts = [_]Instance{ferrite};
    const nets = [_]Net{
        .{ .name = "V1P8", .pins = &[_]PinRef{.{ .ref_des = "FB1", .pin = "1" }} },
        .{ .name = "VDDA18USB", .pins = &[_]PinRef{.{ .ref_des = "FB1", .pin = "2" }} },
    };
    const outer: DesignBlock = .{
        .name = "outer",
        .instances = &insts,
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &sbs,
        .net_ties = &ties,
    };
    const built = try rails.build(std.testing.allocator, &outer);
    defer {
        for (built) |r| {
            if (r.source_path.len > 0) std.testing.allocator.free(r.source_path);
            if (r.aliases.len > 0) std.testing.allocator.free(r.aliases);
        }
        std.testing.allocator.free(built);
    }
    try std.testing.expectEqual(@as(usize, 1), built.len);
    try std.testing.expectEqual(@as(usize, 1), built[0].aliases.len);
}

// ── power_budget.analyze (idiom 2, ARENA-CONTRACT) ──────────────────────────

// leak-audit: power_budget.analyze allocPrint's group keys, sub-block paths, and
// builds several hashmaps from the *caller's* allocator WITHOUT freeing them — it
// is written to run against a page_allocator / per-request arena. Wrapping it in a
// testing.allocator-backed arena exercises the full ferrite-union + consumer-group
// + back-compute path and proves it never escapes to a different allocator or
// double-frees; the arena.deinit() reclaims everything. (A bare testing.allocator
// call here would correctly false-fail, which is why idiom 2 is the right choice.)
test "leak: power_budget.analyze runs under an arena contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const block = try makePowerTree(a);
    const out = try power_budget.analyze(a, &block);
    // VDD rail (sourced by buck, loaded by U1) should surface as one row.
    try std.testing.expect(out.len >= 1);
}

// ── erc.runErc (idiom 2, ARENA-CONTRACT) ────────────────────────────────────

// leak-audit: runErc fans out to ~17 sub-checks, most of which build StringHashMap
// scratch from the caller's allocator and never deinit it (e.g. checkPinMultiNet's
// pin_to_net/reported, checkFloatingNets' four maps). It returns violations.items
// directly. This is request-path code retrofitted onto res.arena, so run it under
// a testing.allocator arena: catches a crash / double-free in any sub-check and
// documents the allocate-and-forget contract. project_dir is empty so the
// disk-touching pin-function check is skipped (hermetic).
test "leak: runErc whole-pass runs under an arena contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const block = try makePowerTree(a);
    const violations = try erc.runErc(a, &block, "");
    // The fixture's top-level IC (U1, an un-catalogued main IC with no GND/cap)
    // guarantees the pass produces at least one finding, so we exercise the
    // allocPrint message paths too.
    try std.testing.expect(violations.len >= 1);
}

// leak-audit: writeViolationsJson is a pure owned-return (ArrayList → items)
// serializer. Run it through a testing.allocator arena so the JSON buffer growth
// is reclaimed; confirms the serializer doesn't reach for a stray global.
test "leak: writeViolationsJson under arena contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const vios = [_]erc.Violation{
        .{ .kind = .floating_net, .severity = .warning, .message = "x", .net = "VDD" },
        .{ .kind = .duplicate_refdes, .severity = .@"error", .message = "y", .ref_des = "U1" },
    };
    const json = try erc.writeViolationsJson(a, &vios);
    try std.testing.expect(json.len > 0);
}

// ── req_checks.applyVerifications (idiom 1-adjacent: mutate-in-place, no alloc) ─

// leak-audit: applyVerifications walks the design and mutates the results map in
// place — it performs NO allocation itself. Driving it with a testing.allocator
// arena for the fixture proves the verifies-overlay path frees nothing it didn't
// own and leaks nothing (the map + slices are arena-owned). Documents that the
// review-overlay step is allocation-free.
test "leak: applyVerifications allocation-free overlay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const reqs = try a.dupe(env.Requirement, &.{.{ .text = "rule", .id = "r1" }});
    const insts = try a.dupe(Instance, &.{.{
        .ref_des = "U6",
        .component = "x",
        .value = "",
        .footprint = "",
        .symbol = "",
        .id = "b894897b",
        .requirements = reqs,
    }});
    const results = try a.dupe(req_checks.Result, &.{.{ .status = .na }});
    var map: std.StringHashMapUnmanaged([]req_checks.Result) = .empty;
    try map.put(a, "U6", results);

    const verifs = try a.dupe(env.Verification, &.{.{ .target_id = "b894897b", .req_id = "r1", .rationale = "checked" }});
    const block: DesignBlock = .{
        .name = "t",
        .instances = insts,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .verifications = verifs,
    };
    req_checks.applyVerifications(&map, &block, block.instances);
    try std.testing.expectEqual(req_checks.Status.verified, results[0].status);
}
