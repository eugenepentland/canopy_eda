//! Server-side assembly of the PCB-completion `progress.Inputs` — the seam that
//! turns a solved board into the six-rung completion ladder (`placement/
//! progress.zig`). Kept out of `pcb_describe.zig` (a size-ratchet-friendly
//! sibling, the `mcp_flatten.zig` precedent) so the pure ladder stays a pure
//! function and only this file knows about ERC, the fab gate, and the layout
//! sidecars.
//!
//! `assemble` gathers, from the SAME solved placement `describeDesign` shows:
//! the ERC error count, the per-sub-block layout status, the board-outline
//! predicate, the blessed layout's persisted copper (one load), the per-net
//! connectivity + fab-readiness read off that copper, and the resolved
//! `(pcb-plan …)` (reusing the caller's one `module_policy` analysis). It is a
//! pure function of `(project_dir, block, placement, opts, policy)` — the only
//! disk it touches is read-only (ERC's lib/ lookups, the layout sidecar), so a
//! describe request and the `get_layout_progress` MCP tool compute the
//! identical `progress.Report`.

const std = @import("std");
const optimizer = @import("../placement/optimizer.zig");
const module_policy = @import("../placement/module_policy.zig");
const plan_resolve = @import("../placement/plan_resolve.zig");
const progress = @import("../placement/progress.zig");
const fab_readiness = @import("../fab_readiness.zig");
const export_gerber = @import("../export_gerber.zig");
const erc_mod = @import("../erc.zig");
const drc_rules = @import("drc_rules.zig");
const env_mod = @import("../eval/env.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");

const Allocator = std.mem.Allocator;

/// Build the completion-ladder report for `name`'s solved `placement`. `policy`
/// is the caller's already-computed `module_policy.analyze(placement)` (reused,
/// not recomputed). Runs ERC + the fab gate per call — acceptable per the
/// pcb-describe perf contract — but reuses the one placement selection and loads
/// the persisted copper exactly once (`shownLayoutCopper`).
pub fn assemble(
    arena: Allocator,
    project_dir: []const u8,
    name: []const u8,
    solved: pcb_layout_page.SolvedRequest,
    opts: pcb_layout_page.PngRequest,
    policy: module_policy.ModulePolicy,
) Allocator.Error!progress.Report {
    const block: *const env_mod.DesignBlock = solved.block;
    const placement = solved.placement;
    // One copper load: the persisted routed copper of the layout the described
    // board came from (named ?layout=, else the ★ starred default), plus whether
    // that layout is a saved snapshot (vs the auto cache / grid).
    const shown = pcb_layout_page.shownLayoutCopper(arena, project_dir, name, opts, placement);
    const copper = export_gerber.Copper{ .tracks = shown.tracks, .vias = shown.vias, .zones = shown.zones };

    // ONE connectivity pass feeds both the ladder's routing rung and the fab
    // gate's airwire tally: it is a pure function of `(placement, copper)`, and
    // rastering a poured board's zones for it is the dominant cost of this
    // whole request — computing it twice made `/api/layout-progress` take 100 s
    // on barracuda-base (15 zones) instead of 50 s.
    const conn = try fab_readiness.netConnectivity(arena, placement, copper);
    const fab = try fab_readiness.check(arena, placement, copper, .{
        .from_saved_layout = shown.from_saved,
        .drc_rules = drc_rules.load(arena, project_dir, name),
        .conn = conn,
    });

    const plan = try plan_resolve.resolve(arena, block.pcb_plan, .{
        .placement = placement,
        .net_class = policy.net_class,
        .part_role = policy.part_role,
        .modules = policy.modules,
        .sections = try plan_resolve.sectionMembers(arena, block),
        .net_class_specs = block.net_classes,
        // The shown layout's pours feed the resolver's reserved-layer audit:
        // a wave steered onto an inner layer the pours fully cover warns here
        // (the ladder + describe lint), the seam that knows the board's copper.
        .zones = shown.zones,
    });

    return progress.compute(arena, .{
        .erc_error_count = ercErrorCount(arena, block, project_dir),
        .sub_circuits = try subCircuitStatuses(arena, project_dir, block, placement),
        .has_outline = placement.board_rect != null,
        .placement = placement,
        .net_conn = try mapNetConn(arena, conn),
        .fab = fab,
        .from_saved_layout = shown.from_saved,
        .plan = plan,
    });
}

/// Map `fab_readiness.netConnectivity`'s per-net verdicts (in `placement.nets`
/// order, 1:1 with the plan's route-member net indices) onto the ladder's
/// leaner `NetConn`.
fn mapNetConn(arena: Allocator, conn: []const fab_readiness.NetStatus) Allocator.Error![]const progress.NetConn {
    const out = try arena.alloc(progress.NetConn, conn.len);
    for (conn, 0..) |ns, i| out[i] = .{ .name = ns.name, .routable = ns.routable, .connected = ns.connected };
    return out;
}

/// Count the error-severity ERC violations of `block` (the schematic rung's
/// gate). Read-only; degrades to 0 on an ERC failure so the ladder still renders.
fn ercErrorCount(arena: Allocator, block: *const env_mod.DesignBlock, project_dir: []const u8) usize {
    const violations = erc_mod.runErc(arena, block, project_dir) catch return 0;
    var n: usize = 0;
    for (violations) |v| {
        if (v.severity == .@"error") n += 1;
    }
    return n;
}

/// One `SubCircuitStatus` per `(sub-block …)`: `needs_layout` when the placement
/// carries parts under the sub-block's slug, `starred` when the sub-block's
/// module has a ★-default saved layout to reuse.
fn subCircuitStatuses(
    arena: Allocator,
    project_dir: []const u8,
    block: *const env_mod.DesignBlock,
    placement: optimizer.Placement,
) Allocator.Error![]const progress.SubCircuitStatus {
    var list: std.ArrayList(progress.SubCircuitStatus) = .empty;
    for (block.sub_blocks) |sb| {
        try list.append(arena, .{
            .name = sb.name,
            .pcb_target = pcbTarget(sb.source),
            .needs_layout = subNeedsLayout(placement, sb.name),
            .starred = moduleStarred(arena, project_dir, sb.source),
        });
    }
    return list.toOwnedSlice(arena);
}

/// A module-name source can be opened directly in /pcb-layout/:name; a file
/// path cannot fit that route and keeps the finding read-only.
fn pcbTarget(source: []const u8) ?[]const u8 {
    if (source.len == 0 or std.mem.endsWith(u8, source, ".sexp")) return null;
    if (std.mem.indexOfAny(u8, source, "/\\") != null) return null;
    return source;
}

/// True when any placed part carries `name` as a leading sub-block path segment
/// (`pwr` → `pwr/C1`) — i.e. the sub-block contributes parts to lay out.
fn subNeedsLayout(placement: optimizer.Placement, name: []const u8) bool {
    for (placement.parts) |part| {
        const r = part.ref_des;
        if (r.len > name.len and std.mem.startsWith(u8, r, name) and r[name.len] == '/') return true;
    }
    return false;
}

/// True when the module sourced by `source` has a ★-default saved layout with
/// parts — the reusable module layout the sub-circuits rung asks for. Empty
/// source (inline / test sub-blocks) is never starred.
fn moduleStarred(arena: Allocator, project_dir: []const u8, source: []const u8) bool {
    if (source.len == 0) return false;
    return layoutsHaveStarred(pcb_layout_page.readLayouts(arena, project_dir, source));
}

/// The ★-default-with-parts predicate `blessedLayout` / `defaultLayoutName`
/// use, hoisted here so the sub-circuits mapping is unit-testable off a slice.
fn layoutsHaveStarred(layouts: []const pcb_layout_page.SavedLayout) bool {
    for (layouts) |L| {
        if (L.default and L.parts.len > 0) return true;
    }
    return false;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn mkPart(ref: []const u8) optimizer.Part {
    return .{ .ref_des = ref, .kind = .passive, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false };
}

fn mkInst(ref: []const u8) env_mod.Instance {
    return .{ .ref_des = ref, .component = "", .value = "", .footprint = "", .symbol = "" };
}

fn fixturePlacement(parts: []optimizer.Part) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = false,
    };
}

// spec: Web Server - a sub-block needs a layout when the placement carries parts under its slug prefix
test "subNeedsLayout matches the sub-block slug prefix" {
    var parts = [_]optimizer.Part{ mkPart("pwr/C1"), mkPart("pwr/L1"), mkPart("C9") };
    const p = fixturePlacement(&parts);
    try testing.expect(subNeedsLayout(p, "pwr"));
    // A top-level part with no slug prefix does not make an unrelated sub-block
    // need a layout, and a name that is only a substring (not a segment) misses.
    try testing.expect(!subNeedsLayout(p, "mcu"));
    try testing.expect(!subNeedsLayout(p, "pw"));
}

// spec: Web Server - module source names become progress PCB targets while file sources remain read-only
test "pcbTarget accepts only bare module names" {
    try testing.expectEqualStrings("ldo_6v", pcbTarget("ldo_6v").?);
    try testing.expect(pcbTarget("") == null);
    try testing.expect(pcbTarget("lib/modules/ldo_6v.sexp") == null);
    try testing.expect(pcbTarget("local-block.sexp") == null);
}

// spec: Web Server - a module counts as starred when its saved layouts include a default snapshot with parts
test "layoutsHaveStarred requires a default snapshot with parts" {
    const one_pose = [_]pcb_layout_page.PartPose{.{ .ref = "U1", .x = 0, .y = 0, .rot = 0 }};
    const none = [_]pcb_layout_page.SavedLayout{
        .{ .name = "wip", .kind = "manual", .ts = 0, .score = null, .parts = &one_pose, .default = false },
    };
    try testing.expect(!layoutsHaveStarred(&none));

    const starred = [_]pcb_layout_page.SavedLayout{
        .{ .name = "best", .kind = "manual", .ts = 0, .score = null, .parts = &one_pose, .default = true },
    };
    try testing.expect(layoutsHaveStarred(&starred));

    // A ★ layout with no parts (a degenerate save) does not count.
    const empty_star = [_]pcb_layout_page.SavedLayout{
        .{ .name = "empty", .kind = "manual", .ts = 0, .score = null, .parts = &.{}, .default = true },
    };
    try testing.expect(!layoutsHaveStarred(&empty_star));
}

// spec: Web Server - the progress ladder maps the fab-gate net connectivity in placement-net order
test "mapNetConn copies the connectivity verdicts in order" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const conn = [_]fab_readiness.NetStatus{
        .{ .name = "VBUS", .routable = true, .connected = true, .islands = 1 },
        .{ .name = "SIG", .routable = true, .connected = false, .islands = 2 },
        .{ .name = "TP", .routable = false, .connected = false, .islands = 1 },
    };
    const out = try mapNetConn(arena, &conn);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqualStrings("SIG", out[1].name);
    try testing.expect(out[0].routable and out[0].connected);
    try testing.expect(out[1].routable and !out[1].connected);
    try testing.expect(!out[2].routable);
}

// spec: Web Server - the progress plan context records each section's declared instance ref-des
test "sectionMembers gathers a section's instances recursively" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const inner_insts = [_]env_mod.Instance{mkInst("R1")};
    const sub = [_]env_mod.Section{.{ .name = "Inner", .instances = &inner_insts }};
    const outer_insts = [_]env_mod.Instance{ mkInst("U1"), mkInst("C1") };
    const secs = [_]env_mod.Section{.{ .name = "USB", .instances = &outer_insts, .sub_sections = &sub }};
    const block = env_mod.DesignBlock{
        .name = "d",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .sections = &secs,
    };

    const members = try plan_resolve.sectionMembers(arena, &block);
    // "USB" carries its own instances plus the nested sub-section's, and "Inner"
    // is emitted as its own entry too.
    try testing.expectEqual(@as(usize, 2), members.len);
    try testing.expectEqualStrings("USB", members[0].name);
    try testing.expectEqual(@as(usize, 3), members[0].refs.len); // U1, C1, R1
    try testing.expectEqualStrings("Inner", members[1].name);
    try testing.expectEqual(@as(usize, 1), members[1].refs.len);
}
