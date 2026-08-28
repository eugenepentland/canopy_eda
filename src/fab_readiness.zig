//! Pre-fab correctness gate (audit item 0.1). Before the Gerber ZIP goes to a
//! board house, this module runs a fab-readiness report over the SAME blessed
//! placement + persisted copper the export writes, so the check and the files
//! always describe the same board.
//!
//! It is deliberately a pure function of `(placement, copper)` — no server, no
//! disk — so it is unit-testable in isolation and shares the export's frame /
//! net / plane model exactly. The serve handler wraps it: clean → download,
//! errors → HTTP 409 (unless `?force=1`), warnings → an informational modal.
//!
//! Errors (block the export): a multi-location net whose persisted copper does
//! not connect all its pads (an airwire remaining — plane/pour nets count as
//! connected), an error-severity DRC violation against the persisted copper at
//! the current poses, a part unplaced / stranded in the off-board staging band,
//! a via with drill = 0 (a legacy synthetic via that would emit a bad Excellon
//! hole), and a missing board outline (the profile would fall back to the parts
//! bbox — a guess a fab shouldn't cut to). Warnings (informational): warning-
//! severity DRC findings (courtyard/mask-sliver/silk-over-pad), DNP parts kept
//! in the centroid when `?dnp=keep` overrides the drop-by-default, a malformed
//! (< 3 point) custom outline that fell back to the bounding rect, and a layout
//! coming from the optimizer cache rather than a saved snapshot.

const std = @import("std");
const optimizer = @import("placement/optimizer.zig");
const router = @import("placement/router.zig");
const drc = @import("placement/drc.zig");
const drc_compose = @import("placement/drc_compose.zig");
const drc_rules = @import("serve/drc_rules.zig");
const pour = @import("placement/pour.zig");
const implicit_plane = @import("placement/implicit_plane.zig");
const plane_stitch = @import("placement/plane_stitch.zig");
const export_gerber = @import("export_gerber.zig");
const export_fab = @import("export_fab.zig");
const pad_shape = @import("placement/pad_shape.zig");
const copper_contact = @import("placement/copper_contact.zig");
const outline_mod = @import("placement/outline.zig");
const board_layers = @import("board_layers.zig");
const net_analysis = @import("eval/net_analysis.zig");
const env_mod = @import("eval/env.zig");
const power_budget = @import("eval/power_budget.zig");
const flat_netlist = @import("flat_netlist.zig");
const net_identity = @import("placement/net_identity.zig");
const req_checks = @import("req_checks.zig");

/// A part is treated as off-board (staged, not on the real board) when its
/// courtyard centre sits more than this far outside the board outline — the
/// same "clearly off-board" band the `board_edge` DRC skips, promoted here to
/// an explicit export-blocking error.
pub const staging_band_mm: f64 = 10.0;

const touch_slack_mm = copper_contact.join_slack_mm;

/// One finding. `id` is a stable machine key (for the viewer to group/style),
/// `message` the human line, and the optional net/ref/count give the modal
/// something concrete to point at.
pub const Item = struct {
    id: []const u8,
    message: []const u8,
    net: ?[]const u8 = null,
    ref: ?[]const u8 = null,
    count: usize = 0,
};

/// Summary counts for the report header + the `stats` JSON object.
const ConnectivityDefects = struct {
    drc_violations: usize = 0,
    dangling_copper: usize = 0,
    implicit_junctions: usize = 0,
    hairline_gaps: usize = 0,
    coarsened: bool = false,
};

/// Summary counts for the report header and the stable `stats` JSON object.
pub const Stats = struct {
    parts: usize = 0,
    nets: usize = 0,
    tracks: usize = 0,
    vias: usize = 0,
    /// Nets that needed routing (pads in ≥2 board locations, not plane-carried).
    routable_nets: usize = 0,
    /// Of those, how many are fully connected by the persisted copper.
    connected_nets: usize = 0,
    connectivity: ConnectivityDefects = .{},
    has_outline: bool = false,
    dnp_parts: usize = 0,
};

/// The full report: two severity buckets + stats. `ok()` (no errors) is what
/// gates the export.
pub const Report = struct {
    errors: []const Item,
    warnings: []const Item,
    stats: Stats,

    /// True when nothing blocks the export (warnings alone never block).
    pub fn ok(self: Report) bool {
        return self.errors.len == 0;
    }
};

/// Extra context the serve handler knows but the placement doesn't: whether the
/// blessed layout came from a saved/starred snapshot (vs. the optimizer cache),
/// and whether the centroid CSV keeps DNP parts (`?dnp=keep`). Defaults keep the
/// pure/test path free of server concerns.
pub const ReleaseContext = struct {
    /// The exact full composed result is mandatory in release mode. Null is a
    /// check failure, never permission to fall back to geometry-only DRC.
    composed_drc: ?[]const drc.Violation = null,
    composed_drc_complete: bool = false,
    authored_board_w: f64 = 0,
    authored_board_h: f64 = 0,
    authored_corner_radius: f64 = 0,
};

/// Saved-layout and DNP policy supplied by fabrication-export callers.
pub const Context = struct {
    /// False ⇒ the layout is the single-slot optimizer cache, not a saved
    /// snapshot — a soft warning (a fab run should come off a blessed layout).
    from_saved_layout: bool = true,
    /// True ⇒ the caller asked to KEEP Do-Not-Populate parts in the centroid
    /// CSV (`?dnp=keep`). Since the default now DROPS them, the
    /// `dnp-in-centroid` warning fires only in keep-mode.
    keep_dnp: bool = false,
    /// The design's per-kind DRC severity overrides (`<design>.drc-rules.json`),
    /// pre-loaded by the caller — the gate must agree with the viewer on what
    /// counts as an error, so an `ignore`d kind never blocks the fab package.
    drc_rules: drc_rules.Rules = .{},
    /// This board's per-net connectivity, when the caller has ALREADY computed
    /// it from the same `(placement, copper)` — `netConnectivity` is a pure
    /// function of that pair, so re-deriving it here is duplicated work, and on
    /// a poured board it is the single most expensive thing either caller does
    /// (rastering every retained zone: 47 s of a 100 s `/api/layout-progress`
    /// request on barracuda-base, paid twice). Null ⇒ compute it, which keeps
    /// every existing caller and the pure/test path unchanged.
    conn: ?[]const NetStatus = null,
    /// Non-null only for a manufacturing handoff. It carries the mandatory
    /// composed DRC and enables identity/rating/outline release checks.
    release: ?ReleaseContext = null,
};

/// Run the readiness report. `copper` is the blessed layout's persisted routed
/// copper (the same slice the Gerber writer draws). All output is arena-owned.
pub fn check(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: export_gerber.Copper,
    ctx: Context,
) std.mem.Allocator.Error!Report {
    var errors: std.ArrayList(Item) = .empty;
    var warnings: std.ArrayList(Item) = .empty;
    var stats: Stats = .{
        .parts = placement.parts.len,
        .nets = placement.nets.len,
        .tracks = copper.tracks.len,
        .vias = copper.vias.len,
        .has_outline = placement.board_rect != null,
    };

    // ── Board outline ───────────────────────────────────────────────────────
    // The Edge.Cuts profile is a real cut line; without an authored/drawn
    // outline the writers synthesize one from the parts bbox, which is a guess
    // a fab shouldn't cut to. Block it (the user can draw a rect in one click).
    if (placement.board_rect == null) {
        try errors.append(arena, .{
            .id = "no-outline",
            .message = "no board outline — the " ++ board_layers.edge_cuts ++ " profile would be guessed from the parts bounding box; draw or author a board outline first",
        });
    }
    if (ctx.release) |release| {
        try appendReleaseIdentityChecks(arena, &errors, placement, ctx.keep_dnp);
        try appendOutlineDrift(arena, &errors, placement, release.authored_board_w, release.authored_board_h, release.authored_corner_radius);
        try appendRailRatingChecks(arena, &errors, &warnings, placement, ctx.keep_dnp);
    }

    // A flattened net pin that no longer resolves to a footprint land must not
    // disappear from the denominator. This is the renamed-pad failure mode:
    // silently skipping it can turn a two-terminal net into a one-pad net that
    // appears to need no copper at all.
    try appendUnresolvablePins(arena, &errors, placement);

    try appendPlacementAndViaChecks(arena, &errors, placement, copper.vias);

    // ── DRC against the persisted copper at the current poses ───────────────
    // The router/DRC normally only run on the Route button; here we DRC the
    // saved copper exactly as it will ship. The base clearance is the design's
    // resolved `(design-rules …)` rule (built-in 5-mil default when no form),
    // and `drc.check` layers per-net `(net-class …)` overrides from
    // `placement.rules.net` on top. The gate deliberately ignores any
    // interactive query/panel clearance — it must judge the board against the
    // authored rules, not whatever a user last routed with.
    const clearance = placement.rules.design.clearance;
    const routed = router.RouteResult{
        .tracks = copper.tracks,
        .vias = copper.vias,
        .arcs = copper.arcs,
        // Preserve the solver proof carried by the same RF paths the Gerber
        // writer sweeps into variable-width copper. Without it, DRC mistakes
        // every intentional land taper for an undersized ordinary track.
        .rf_port_outcomes = copper.rf_paths,
        .routed = 0,
        .total = 0,
    };
    const violations = if (ctx.release) |release| blk: {
        const composed = release.composed_drc orelse {
            try errors.append(arena, .{
                .id = "drc-missing",
                .message = "the mandatory full fabricated-fill DRC produced no report — export is blocked",
            });
            break :blk &.{};
        };
        if (!release.composed_drc_complete) try errors.append(arena, .{
            .id = "drc-incomplete",
            .message = "the full fabricated-fill DRC did not complete — export is blocked rather than trusting a partial report",
        });
        break :blk composed;
    } else drc_rules.apply(arena, ctx.drc_rules, drc_compose.checkGeometry(arena, placement, routed, clearance) catch &.{});
    stats.connectivity.drc_violations = violations.len;
    // Partition by severity: error-severity violations block the gate; warnings
    // (courtyard overlap, silkscreen over a pad) flow through as
    // an informational finding but never 409 the download.
    var drc_errs: std.ArrayList(drc.Violation) = .empty;
    var drc_warns: std.ArrayList(drc.Violation) = .empty;
    for (violations) |v| {
        if (v.kind == .dangling_copper) stats.connectivity.dangling_copper += 1;
        if (v.kind == .implicit_junction) stats.connectivity.implicit_junctions += 1;
        if (v.severity == .warn) try drc_warns.append(arena, v) else try drc_errs.append(arena, v);
    }
    if (drc_errs.items.len > 0) {
        try errors.append(arena, .{
            .id = "drc",
            .message = try std.fmt.allocPrint(arena, "{d} DRC violation(s) in the persisted copper ({s})" ++
                " — open the board's Route/DRC view to inspect them", .{ drc_errs.items.len, drcSummary(arena, drc_errs.items) }),
            .count = drc_errs.items.len,
        });
    }
    if (drc_warns.items.len > 0) {
        try warnings.append(arena, .{
            .id = "drc-warn",
            .message = try std.fmt.allocPrint(arena, "{d} DRC warning(s) in the persisted copper ({s})" ++
                " — assembly-hygiene advisories; they don't block the fab package", .{ drc_warns.items.len, drcSummary(arena, drc_warns.items) }),
            .count = drc_warns.items.len,
        });
    }

    // ── Connectivity: unrouted nets (airwires remaining) ────────────────────
    // Per-net routable/connected verdict is factored into `netConnectivity`
    // (shared with the progress ladder); here we only tally + raise airwires.
    // A caller that already ran it over this same `(placement, copper)` hands
    // it in (`ctx.conn`) rather than paying for the zone raster a second time.
    const conn = ctx.conn orelse try netConnectivity(arena, placement, copper);
    var routable: usize = 0;
    var connected: usize = 0;
    for (conn) |ns| {
        stats.connectivity.hairline_gaps += ns.hairline_gaps;
        stats.connectivity.coarsened = stats.connectivity.coarsened or ns.coarsened;
        if (!ns.routable) continue;
        routable += 1;
        if (ns.connected) {
            connected += 1;
        } else {
            try errors.append(arena, .{
                .id = "unrouted-net",
                .message = try std.fmt.allocPrint(arena, "net {s} is not fully connected" ++
                    " — {d} isolated copper island(s) remain (airwire)", .{ ns.name, ns.islands }),
                .net = ns.name,
                .count = ns.islands,
            });
        }
    }
    stats.routable_nets = routable;
    stats.connected_nets = connected;
    if (ctx.release != null and stats.connectivity.coarsened) {
        try warnings.append(arena, .{
            .id = "connectivity-coarsened",
            .message = "at least one plane/pour connectivity verdict used a coarsened raster to stay within the fill-cell budget — review or waive this approximation before release",
        });
    }
    if (stats.connectivity.hairline_gaps > 0) {
        try errors.append(arena, .{
            .id = "hairline-gap",
            .message = try std.fmt.allocPrint(arena, "{d} same-net copper gap(s) lie in the 1–20 µm fabrication-uncertain band — bridge them explicitly", .{stats.connectivity.hairline_gaps}),
            .count = stats.connectivity.hairline_gaps,
        });
    }

    // ── Warnings ────────────────────────────────────────────────────────────
    var dnp: usize = 0;
    for (placement.instances) |inst| {
        if (inst.dnp) dnp += 1;
    }
    stats.dnp_parts = dnp;
    // DNP parts are dropped from the centroid by default now, so this only
    // warns when the caller opted back in with `?dnp=keep`.
    if (dnp > 0 and ctx.keep_dnp) {
        try warnings.append(arena, .{
            .id = "dnp-in-centroid",
            .message = try std.fmt.allocPrint(arena, "{d} Do-Not-Populate part(s) are kept in the centroid CSV (?dnp=keep)" ++
                " — drop the ?dnp=keep opt-in if your assembler wants only stuffed parts", .{dnp}),
            .count = dnp,
        });
    }

    // A custom outline polygon with < 3 points is degenerate: every fab writer
    // silently falls back to the bounding rectangle, which may not be the shape
    // the user drew. Surface it so the profile isn't a silent guess.
    if (placement.board_poly) |poly| {
        if (poly.len < 3) {
            try warnings.append(arena, .{
                .id = "malformed-outline",
                .message = "malformed custom outline (< 3 points) — the board profile falls back to the bounding" ++
                    " rectangle; redraw the outline to cut the intended shape",
            });
        }
    }
    if (!ctx.from_saved_layout) {
        try warnings.append(arena, .{
            .id = "cache-layout",
            .message = "the exported layout is the optimizer cache, not a saved/starred snapshot" ++
                " — Save the layout so the fab package comes off a blessed board",
        });
    }

    return .{
        .errors = try errors.toOwnedSlice(arena),
        .warnings = try warnings.toOwnedSlice(arena),
        .stats = stats,
    };
}

fn appendPlacementAndViaChecks(
    arena: std.mem.Allocator,
    errors: *std.ArrayList(Item),
    placement: optimizer.Placement,
    vias: []const router.Via,
) std.mem.Allocator.Error!void {
    // A part whose courtyard centre is far outside the outline is stranded in
    // the staging band (or was never placed). It still lands in the centroid /
    // copper, so it would ship at a nonsense location.
    if (placement.board_rect) |board| for (placement.parts) |part| {
        const center = optimizer.worldPadCenter(&part, part.ccx, part.ccy);
        const inset = boardInset(board, placement.board_poly, center[0], center[1]);
        if (inset < -staging_band_mm) try errors.append(arena, .{
            .id = "part-off-board",
            .message = try std.fmt.allocPrint(arena, "{s} sits outside the board outline (staging band)" ++
                " — place it on the board or remove it", .{part.ref_des}),
            .ref = part.ref_des,
        });
    };

    // A drill = 0 via would emit a bad Excellon hole (and its annular ring is
    // unknowable). Count them once; report if any.
    var bad_vias: usize = 0;
    for (vias) |via| if (via.drill <= 0) {
        bad_vias += 1;
    };
    if (bad_vias == 0) return;
    try errors.append(arena, .{
        .id = "via-no-drill",
        .message = try std.fmt.allocPrint(arena, "{d} via(s) have no drill diameter (legacy synthetic)" ++
            " — they would emit bad drill data; re-route to regenerate them", .{bad_vias}),
        .count = bad_vias,
    });
}

fn propertyValue(inst: anytype, key: []const u8) ?[]const u8 {
    for (inst.properties) |prop| if (std.ascii.eqlIgnoreCase(prop.key, key)) return prop.value;
    return null;
}

fn appendReleaseIdentityChecks(
    arena: std.mem.Allocator,
    errors: *std.ArrayList(Item),
    placement: optimizer.Placement,
    keep_dnp: bool,
) std.mem.Allocator.Error!void {
    if (placement.instances.len != placement.parts.len) {
        try errors.append(arena, .{
            .id = "centroid-parity",
            .message = try std.fmt.allocPrint(arena, "the evaluated BOM has {d} instances but placement has {d} footprints", .{ placement.instances.len, placement.parts.len }),
        });
    }
    var seen = std.StringHashMapUnmanaged([]const u8).empty;
    for (placement.parts) |part| {
        if (!part.fallback) continue;
        try errors.append(arena, .{
            .id = "footprint-geometry-unresolved",
            .message = try std.fmt.allocPrint(arena, "{s} uses synthesized fallback geometry because its footprint could not be loaded", .{part.ref_des}),
            .ref = part.ref_des,
        });
    }
    for (placement.instances, 0..) |inst, index| {
        // Match export_fab.centroidCsv exactly: default export suppresses DNP
        // rows; ?dnp=keep emits them. A missing populated instance is never
        // hidden by comparing the two raw backing-array lengths.
        const emitted = export_fab.assemblyPopulated(inst, if (keep_dnp) .keep else .drop);
        if (emitted and index >= placement.parts.len) {
            try errors.append(arena, .{
                .id = "centroid-parity",
                .message = try std.fmt.allocPrint(arena, "populated BOM row {s} has no centroid footprint", .{inst.ref_des}),
                .ref = inst.ref_des,
            });
        } else if (emitted and !std.mem.eql(u8, inst.ref_des, placement.parts[index].ref_des)) {
            try errors.append(arena, .{
                .id = "centroid-parity",
                .message = try std.fmt.allocPrint(arena, "centroid row {d} names {s}, but the placed footprint is {s}", .{ index + 1, inst.ref_des, placement.parts[index].ref_des }),
                .ref = inst.ref_des,
            });
        }
        if (inst.uuid.len == 0) {
            try errors.append(arena, .{
                .id = "missing-identity",
                .message = try std.fmt.allocPrint(arena, "{s} has no stable PCB identity", .{inst.ref_des}),
                .ref = inst.ref_des,
            });
        } else if (seen.get(inst.uuid)) |first| {
            try errors.append(arena, .{
                .id = "duplicate-identity",
                .message = try std.fmt.allocPrint(arena, "{s} and {s} share PCB identity {s}", .{ first, inst.ref_des, inst.uuid }),
                .ref = inst.ref_des,
            });
        } else try seen.put(arena, inst.uuid, inst.ref_des);

        if (inst.footprint.len == 0 or !emitted) continue;
        const mpn = propertyValue(inst, "mpn") orelse "";
        const maker = propertyValue(inst, "manufacturer") orelse "";
        if (mpn.len == 0 or maker.len == 0) {
            const item = Item{
                .id = "bom-identity",
                .message = try std.fmt.allocPrint(arena, "{s} ({s} {s}) has no complete manufacturer/MPN selection", .{ inst.ref_des, inst.component, inst.value }),
                .ref = inst.ref_des,
            };
            try errors.append(arena, item);
        }
    }
}

const Rating = struct { value: f64, present: bool };

fn ratingByte(c: u8) bool {
    if (std.ascii.isDigit(c)) return true;
    return switch (c) {
        '.', '+', '-', 'e', 'E' => true,
        else => false,
    };
}

fn ratingUnit(text: []const u8) bool {
    return text.len == 0 or
        std.ascii.eqlIgnoreCase(text, "W") or
        std.ascii.eqlIgnoreCase(text, "A") or
        std.ascii.eqlIgnoreCase(text, "V") or
        std.ascii.eqlIgnoreCase(text, "ohm") or
        std.mem.eql(u8, text, "Ω");
}

fn parseRating(raw: ?[]const u8) Rating {
    const text = raw orelse return .{ .value = 0, .present = false };
    var end: usize = 0;
    while (end < text.len and ratingByte(text[end])) : (end += 1) {}
    if (end == 0) return .{ .value = 0, .present = false };
    const parsed = std.fmt.parseFloat(f64, text[0..end]) catch return .{ .value = 0, .present = false };
    const suffix = std.mem.trim(u8, text[end..], " \t");
    const scale: f64 = if (ratingUnit(suffix))
        1
    else if (suffix.len > 1 and suffix[0] == 'm' and ratingUnit(suffix[1..]))
        1e-3
    else if (suffix.len > 1 and suffix[0] == 'u' and ratingUnit(suffix[1..]))
        @as(f64, 1.0) / 1_000_000.0
    else if (std.mem.startsWith(u8, suffix, "µ") and ratingUnit(suffix["µ".len..]))
        @as(f64, 1.0) / 1_000_000.0
    else if (suffix.len > 1 and suffix[0] == 'k' and ratingUnit(suffix[1..]))
        1e3
    else
        return .{ .value = 0, .present = false };
    const value = parsed * scale;
    return .{ .value = value, .present = std.math.isFinite(value) and value > 0 };
}

// spec: fabrication-release - SI-prefixed passive ratings are parsed with case-insensitive unit names, including the common `mOhm` spelling
test "passive rating parser treats mOhm as milliohms" {
    const parsed = parseRating("50mOhm");
    try std.testing.expect(parsed.present);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), parsed.value, 1e-12);
    try std.testing.expect(!parseRating("50mMystery").present);
    try std.testing.expect(!parseRating("1e5000V").present);
    try std.testing.expect(!parseRating("1e5000kV").present);
}

const VoltageRange = struct { min: f64, max: f64 };

fn railVoltage(placement: optimizer.Placement, name: []const u8) ?VoltageRange {
    if (net_analysis.isGroundName(name)) return .{ .min = 0, .max = 0 };
    const base = net_analysis.baseNetName(name);
    for (placement.rules.physical.rail_specs) |rail| {
        const minimum = rail.rated_voltage.min orelse rail.nominal orelse continue;
        const maximum = rail.rated_voltage.max orelse rail.nominal orelse continue;
        const range = VoltageRange{ .min = @min(minimum, maximum), .max = @max(minimum, maximum) };
        if (std.ascii.eqlIgnoreCase(base, rail.name)) return range;
        for (rail.aliases) |alias| if (std.ascii.eqlIgnoreCase(base, alias)) return range;
    }
    return null;
}

const EndpointEvidence = struct {
    connected: usize = 0,
    known: usize = 0,
    low: f64 = 0,
    high: f64 = 0,
};

fn endpointEvidence(placement: optimizer.Placement, ref: []const u8) EndpointEvidence {
    var result = EndpointEvidence{};
    for (placement.nets) |net| {
        var owns = false;
        for (net.pins) |pin| if (std.mem.eql(u8, pin.ref_des, ref)) {
            owns = true;
            break;
        };
        if (!owns) continue;
        result.connected += 1;
        const volts = railVoltage(placement, net.name) orelse continue;
        if (result.known == 0) result.low = volts.min;
        if (result.known == 0) result.high = volts.max;
        result.low = @min(result.low, volts.min);
        result.high = @max(result.high, volts.max);
        result.known += 1;
    }
    return result;
}

fn propertyAny(inst: flat_netlist.FlatInstance, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| if (propertyValue(inst, key)) |value| return value;
    return null;
}

fn requireProperty(
    arena: std.mem.Allocator,
    errors: *std.ArrayList(Item),
    inst: flat_netlist.FlatInstance,
    keys: []const []const u8,
    label: []const u8,
) std.mem.Allocator.Error!bool {
    if (propertyAny(inst, keys) != null) return true;
    try errors.append(arena, .{
        .id = "component-rating-missing",
        .message = try std.fmt.allocPrint(arena, "{s} selected MPN has no {s} property", .{ inst.ref_des, label }),
        .ref = inst.ref_des,
    });
    return false;
}

fn requirePositiveRating(
    arena: std.mem.Allocator,
    errors: *std.ArrayList(Item),
    inst: flat_netlist.FlatInstance,
    keys: []const []const u8,
    label: []const u8,
) std.mem.Allocator.Error!bool {
    const raw = propertyAny(inst, keys) orelse return requireProperty(arena, errors, inst, keys, label);
    if (parseRating(raw).present) return true;
    try errors.append(arena, .{
        .id = "component-rating-invalid",
        .message = try std.fmt.allocPrint(arena, "{s} selected MPN has invalid/nonpositive {s} '{s}'", .{ inst.ref_des, label, raw }),
        .ref = inst.ref_des,
    });
    return false;
}

fn netMatchesRailName(name: []const u8, rail_name: []const u8) bool {
    const base = net_analysis.baseNetName(name);
    return std.ascii.eqlIgnoreCase(base, net_analysis.baseNetName(rail_name));
}

fn railCurrentForRef(placement: optimizer.Placement, ref: []const u8) ?f64 {
    var result: ?f64 = null;
    for (placement.nets) |net| {
        var owns = false;
        for (net.pins) |pin| if (std.mem.eql(u8, pin.ref_des, ref)) {
            owns = true;
            break;
        };
        if (!owns) continue;
        for (placement.rules.physical.rails) |rail| {
            var matches = netMatchesRailName(net.name, rail.net);
            if (!matches) for (rail.consumers) |consumer| {
                if (netMatchesRailName(net.name, consumer.net)) {
                    matches = true;
                    break;
                }
            };
            if (!matches) continue;
            if (!rail.any_max_load) continue;
            if (!(rail.load_max_a > 0)) continue;
            result = @max(result orelse 0, rail.load_max_a);
        }
    }
    return result;
}

fn appendUnproven(
    arena: std.mem.Allocator,
    errors: *std.ArrayList(Item),
    inst: flat_netlist.FlatInstance,
    subject: []const u8,
) std.mem.Allocator.Error!void {
    try errors.append(arena, .{
        .id = "component-rating-unproven",
        .message = try std.fmt.allocPrint(arena, "{s} touches a power rail, but {s} cannot be proved from declared worst-case rail data", .{ inst.ref_des, subject }),
        .ref = inst.ref_des,
    });
}

const RatingContext = struct {
    arena: std.mem.Allocator,
    errors: *std.ArrayList(Item),
    warnings: *std.ArrayList(Item),
    placement: optimizer.Placement,
};

fn checkCapacitorRating(ctx: RatingContext, inst: flat_netlist.FlatInstance) std.mem.Allocator.Error!void {
    _ = try requireProperty(ctx.arena, ctx.errors, inst, &.{"dielectric"}, "dielectric");
    _ = try requireProperty(ctx.arena, ctx.errors, inst, &.{"tolerance"}, "tolerance");
    const has_voltage = try requirePositiveRating(ctx.arena, ctx.errors, inst, &.{"voltage"}, "voltage rating");
    const endpoints = endpointEvidence(ctx.placement, inst.ref_des);
    if (endpoints.known == 0) return;
    if (endpoints.connected < 2 or endpoints.known < endpoints.connected) {
        try appendUnproven(ctx.arena, ctx.errors, inst, "applied capacitor voltage");
        return;
    }
    const applied = @abs(endpoints.high - endpoints.low);
    if (!has_voltage or !(applied > 0)) return;
    const rated = parseRating(propertyValue(inst, "voltage"));
    if (rated.present and rated.value + 1e-9 < applied) {
        try ctx.errors.append(ctx.arena, .{
            .id = "component-underrated",
            .message = try std.fmt.allocPrint(ctx.arena, "{s} is rated {d:.3} V but is exposed to {d:.3} V", .{ inst.ref_des, rated.value, applied }),
            .ref = inst.ref_des,
        });
    } else if (rated.value < applied * 1.25) {
        try ctx.warnings.append(ctx.arena, .{
            .id = "component-rating-margin",
            .message = try std.fmt.allocPrint(ctx.arena, "{s} voltage rating {d:.3} V has less than 25% margin over {d:.3} V applied", .{ inst.ref_des, rated.value, applied }),
            .ref = inst.ref_des,
        });
    }
}

fn checkJumperRating(ctx: RatingContext, inst: flat_netlist.FlatInstance, has_power: bool) std.mem.Allocator.Error!void {
    const has_current = try requirePositiveRating(ctx.arena, ctx.errors, inst, &.{ "rated-current", "current-rating", "current" }, "jumper rated current");
    const has_max_resistance = try requirePositiveRating(ctx.arena, ctx.errors, inst, &.{ "max-resistance", "resistance-max" }, "maximum jumper resistance");
    // A signal/configuration jumper has no rail load to compare. Its intrinsic
    // selection evidence is still validated above, but absence of a power-rail
    // model is not itself a release error.
    if (endpointEvidence(ctx.placement, inst.ref_des).known == 0) return;
    const actual_current = railCurrentForRef(ctx.placement, inst.ref_des) orelse {
        try appendUnproven(ctx.arena, ctx.errors, inst, "zero-ohm jumper current");
        return;
    };
    if (has_current) {
        const rated_current = parseRating(propertyAny(inst, &.{ "rated-current", "current-rating", "current" }));
        if (rated_current.present and actual_current > rated_current.value + 1e-9) try ctx.errors.append(ctx.arena, .{
            .id = "component-underrated",
            .message = try std.fmt.allocPrint(ctx.arena, "{s} carries up to {d:.3} A but its zero-ohm jumper rating is {d:.3} A", .{ inst.ref_des, actual_current, rated_current.value }),
            .ref = inst.ref_des,
        });
    }
    if (!has_max_resistance or !has_power) return;
    const max_resistance = parseRating(propertyAny(inst, &.{ "max-resistance", "resistance-max" }));
    const power_rating = parseRating(propertyValue(inst, "power"));
    const dissipation = actual_current * actual_current * max_resistance.value;
    if (max_resistance.present and power_rating.present and dissipation > power_rating.value + 1e-12) try ctx.errors.append(ctx.arena, .{
        .id = "component-underrated",
        .message = try std.fmt.allocPrint(ctx.arena, "{s} may dissipate {d:.4} W at maximum jumper resistance, above its {d:.4} W rating", .{ inst.ref_des, dissipation, power_rating.value }),
        .ref = inst.ref_des,
    });
}

fn checkResistorRating(ctx: RatingContext, inst: flat_netlist.FlatInstance) std.mem.Allocator.Error!void {
    const resistance = req_checks.parseOhms(inst.value);
    const zero_ohm = resistance != null and resistance.? == 0;
    if (!zero_ohm) _ = try requireProperty(ctx.arena, ctx.errors, inst, &.{"tolerance"}, "tolerance");
    const has_power = try requirePositiveRating(ctx.arena, ctx.errors, inst, &.{"power"}, "power rating");
    const has_voltage = try requirePositiveRating(ctx.arena, ctx.errors, inst, &.{ "voltage", "working-voltage", "rated-voltage" }, "working voltage");
    // Current and maximum-resistance are intrinsic jumper evidence, so prove
    // they are positive and parseable even when neither endpoint is a declared
    // power rail. The rail load, when known, is an additional underrating test.
    if (zero_ohm) return checkJumperRating(ctx, inst, has_power);
    const endpoints = endpointEvidence(ctx.placement, inst.ref_des);
    if (endpoints.known == 0) return;
    if (endpoints.connected < 2) {
        try appendUnproven(ctx.arena, ctx.errors, inst, "resistor dissipation");
        return;
    }
    const ohms = resistance orelse {
        try appendUnproven(ctx.arena, ctx.errors, inst, "resistor dissipation");
        return;
    };
    if (endpoints.known != endpoints.connected) {
        try appendUnproven(ctx.arena, ctx.errors, inst, "resistor dissipation");
        return;
    }
    const delta = @abs(endpoints.high - endpoints.low);
    if (has_voltage and delta > 0) {
        const voltage_rating = parseRating(propertyAny(inst, &.{ "voltage", "working-voltage", "rated-voltage" }));
        if (voltage_rating.present and voltage_rating.value + 1e-9 < delta) try ctx.errors.append(ctx.arena, .{
            .id = "component-underrated",
            .message = try std.fmt.allocPrint(ctx.arena, "{s} sees up to {d:.3} V but is rated only {d:.3} V", .{ inst.ref_des, delta, voltage_rating.value }),
            .ref = inst.ref_des,
        });
    }
    if (!(ohms > 0) or !has_power) return;
    const actual = delta * delta / ohms;
    const rated = parseRating(propertyValue(inst, "power"));
    if (rated.present and actual > rated.value + 1e-12) {
        try ctx.errors.append(ctx.arena, .{
            .id = "component-underrated",
            .message = try std.fmt.allocPrint(ctx.arena, "{s} dissipates up to {d:.4} W from declared rail endpoints, above its {d:.4} W rating", .{ inst.ref_des, actual, rated.value }),
            .ref = inst.ref_des,
        });
    } else if (rated.present and actual > rated.value * 0.8) {
        try ctx.warnings.append(ctx.arena, .{
            .id = "component-rating-margin",
            .message = try std.fmt.allocPrint(ctx.arena, "{s} worst-case dissipation {d:.4} W uses over 80% of its {d:.4} W rating", .{ inst.ref_des, actual, rated.value }),
            .ref = inst.ref_des,
        });
    }
}

fn checkMagneticRating(ctx: RatingContext, inst: flat_netlist.FlatInstance) std.mem.Allocator.Error!void {
    const has_current = try requirePositiveRating(ctx.arena, ctx.errors, inst, &.{ "rated-current", "current-rating", "current" }, "rated current");
    const has_dcr = try requirePositiveRating(ctx.arena, ctx.errors, inst, &.{ "dcr-max", "dcr" }, "maximum DCR");
    if (std.mem.startsWith(u8, inst.component, "ind-")) _ = try requireProperty(ctx.arena, ctx.errors, inst, &.{"tolerance"}, "tolerance");
    const current = railCurrentForRef(ctx.placement, inst.ref_des) orelse {
        if (endpointEvidence(ctx.placement, inst.ref_des).known > 0) try appendUnproven(ctx.arena, ctx.errors, inst, "inductor/ferrite current rating");
        return;
    };
    if (has_current) {
        const rated = parseRating(propertyAny(inst, &.{ "rated-current", "current-rating", "current" }));
        if (rated.present and current > rated.value + 1e-9) try ctx.errors.append(ctx.arena, .{
            .id = "component-underrated",
            .message = try std.fmt.allocPrint(ctx.arena, "{s} carries up to {d:.3} A but is rated only {d:.3} A", .{ inst.ref_des, current, rated.value }),
            .ref = inst.ref_des,
        });
    }
    if (!has_dcr) return;
    const dcr = parseRating(propertyAny(inst, &.{ "dcr-max", "dcr" }));
    const endpoint_range = endpointEvidence(ctx.placement, inst.ref_des);
    const rail_v = @max(@abs(endpoint_range.low), @abs(endpoint_range.high));
    const drop = if (dcr.present) current * dcr.value else 0;
    if (dcr.present and rail_v > 0 and drop > rail_v * 0.05) try ctx.warnings.append(ctx.arena, .{
        .id = "component-rating-margin",
        .message = try std.fmt.allocPrint(ctx.arena, "{s} maximum DCR implies {d:.3} V drop at {d:.3} A ({d:.3} ohm)", .{ inst.ref_des, drop, current, dcr.value }),
        .ref = inst.ref_des,
    });
}

fn appendRailRatingChecks(
    arena: std.mem.Allocator,
    errors: *std.ArrayList(Item),
    warnings: *std.ArrayList(Item),
    placement: optimizer.Placement,
    keep_dnp: bool,
) std.mem.Allocator.Error!void {
    const ctx: RatingContext = .{ .arena = arena, .errors = errors, .warnings = warnings, .placement = placement };
    for (placement.instances) |inst| {
        if (!export_fab.assemblyPopulated(inst, if (keep_dnp) .keep else .drop)) continue;
        if (std.mem.startsWith(u8, inst.component, "cap-")) {
            try checkCapacitorRating(ctx, inst);
        } else if (std.mem.startsWith(u8, inst.component, "res-")) {
            try checkResistorRating(ctx, inst);
        } else if (std.mem.startsWith(u8, inst.component, "ferrite-") or std.mem.startsWith(u8, inst.component, "ind-")) {
            try checkMagneticRating(ctx, inst);
        }
    }
}

fn appendOutlineDrift(
    arena: std.mem.Allocator,
    errors: *std.ArrayList(Item),
    placement: optimizer.Placement,
    authored_w: f64,
    authored_h: f64,
    authored_radius: f64,
) std.mem.Allocator.Error!void {
    if (!(authored_w > 0 and authored_h > 0)) return;
    const saved = placement.board_rect orelse return;
    const dimensions_match = @abs(saved.w - authored_w) <= 0.01 and @abs(saved.h - authored_h) <= 0.01;
    const corners = [_][2]f64{
        .{ saved.minx, saved.miny },
        .{ saved.minx + saved.w, saved.miny },
        .{ saved.minx + saved.w, saved.miny + saved.h },
        .{ saved.minx, saved.miny + saved.h },
    };
    var shape_matches: bool = false;
    if (!(authored_radius > 0)) {
        shape_matches = placement.board_arcs.len == 0 and
            (placement.board_poly == null or polygonEquivalent(placement.board_poly.?, &corners, 0.01));
    } else {
        const radii = [_]f64{ authored_radius, authored_radius, authored_radius, authored_radius };
        const expected = try outline_mod.filletPath(arena, &corners, &radii, 0.01);
        shape_matches = placement.board_poly != null and
            polygonEquivalent(placement.board_poly.?, expected.poly, 0.01) and
            arcsEquivalent(placement.board_arcs, expected.arcs, 0.01);
    }
    if (dimensions_match and shape_matches) return;
    try errors.append(arena, .{
        .id = "outline-drift",
        .message = try std.fmt.allocPrint(arena, "saved fabrication outline is {d:.3} x {d:.3} mm with {d} native arcs, but source declares {d:.3} x {d:.3} mm and {d:.3} mm corner radius", .{ saved.w, saved.h, placement.board_arcs.len, authored_w, authored_h, authored_radius }),
    });
}

fn hasItemRef(items: []const Item, id: []const u8, ref: []const u8) bool {
    for (items) |item| {
        if (!std.mem.eql(u8, item.id, id)) continue;
        if (item.ref) |item_ref| if (std.mem.eql(u8, item_ref, ref)) return true;
    }
    return false;
}

fn hasItemRefMessage(items: []const Item, id: []const u8, ref: []const u8, text: []const u8) bool {
    for (items) |item| {
        if (!std.mem.eql(u8, item.id, id)) continue;
        if (item.ref == null or !std.mem.eql(u8, item.ref.?, ref)) continue;
        if (std.mem.indexOf(u8, item.message, text) != null) return true;
    }
    return false;
}

// spec: fabrication-release - rail checks use worst-case voltage, reject underrating, preserve unknown endpoints, and size zero-ohm jumpers by rail current
test "rail-aware passive ratings cover voltage unknown endpoints and zero-ohm current" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bad_cap_properties = [_]env_mod.Property{
        .{ .key = "voltage", .value = "6.3V" }, .{ .key = "dielectric", .value = "X7R" }, .{ .key = "tolerance", .value = "10%" },
    };
    const good_cap_properties = [_]env_mod.Property{
        .{ .key = "voltage", .value = "16V" }, .{ .key = "dielectric", .value = "X7R" }, .{ .key = "tolerance", .value = "10%" },
    };
    const resistor_properties = [_]env_mod.Property{
        .{ .key = "power", .value = "63mW" }, .{ .key = "voltage", .value = "25V" }, .{ .key = "tolerance", .value = "1%" },
    };
    const jumper_properties = [_]env_mod.Property{
        .{ .key = "power", .value = "63mW" }, .{ .key = "voltage", .value = "25V" }, .{ .key = "rated-current", .value = "1A" }, .{ .key = "max-resistance", .value = "50mOhm" },
    };
    const bad_jumper_properties = [_]env_mod.Property{
        .{ .key = "power", .value = "63mW" }, .{ .key = "voltage", .value = "25V" }, .{ .key = "rated-current", .value = "invalid" }, .{ .key = "max-resistance", .value = "0Ohm" },
    };
    const instances = [_]flat_netlist.FlatInstance{
        .{ .ref_des = "C_BAD", .component = "cap-0402", .value = "1uF", .footprint = "c0402", .uuid = "bad", .properties = &bad_cap_properties },
        .{ .ref_des = "C_OK", .component = "cap-0402", .value = "1uF", .footprint = "c0402", .uuid = "good", .properties = &good_cap_properties },
        .{ .ref_des = "R_UN", .component = "res-0402", .value = "10k", .footprint = "r0402", .uuid = "unknown", .properties = &resistor_properties },
        .{ .ref_des = "R0", .component = "res-0402", .value = "0R0", .footprint = "r0402", .uuid = "jumper", .properties = &jumper_properties },
        .{ .ref_des = "R0_BAD", .component = "res-0402", .value = "0R0", .footprint = "r0402", .uuid = "bad-jumper", .properties = &bad_jumper_properties },
    };
    const v12_pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "C_BAD", .pin = "1" }, .{ .ref_des = "C_OK", .pin = "1" }, .{ .ref_des = "R_UN", .pin = "1" }, .{ .ref_des = "R0", .pin = "1" },
    };
    const ground_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "C_BAD", .pin = "2" }, .{ .ref_des = "C_OK", .pin = "2" } };
    const signal_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R_UN", .pin = "2" }, .{ .ref_des = "R0_BAD", .pin = "1" } };
    const load_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R0", .pin = "2" }, .{ .ref_des = "R0_BAD", .pin = "2" } };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "V12", .pins = &v12_pins }, .{ .name = "GND", .pins = &ground_pins }, .{ .name = "SIG", .pins = &signal_pins }, .{ .name = "LOAD", .pins = &load_pins },
    };
    const rail_specs = [_]env_mod.PowerRail{.{ .name = "V12", .nominal = 12, .rated_voltage = .{ .min = 11.4, .max = 12.6 } }};
    const rails = [_]power_budget.Rail{.{ .net = "V12", .load_max_a = 2, .any_max_load = true, .status = .no_source }};
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &instances,
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = false,
        .rules = .{ .physical = .{ .rails = &rails, .rail_specs = &rail_specs } },
    };
    var errors: std.ArrayList(Item) = .empty;
    var warnings: std.ArrayList(Item) = .empty;
    try appendRailRatingChecks(arena, &errors, &warnings, placement, false);
    try std.testing.expect(hasItemRef(errors.items, "component-underrated", "C_BAD"));
    try std.testing.expect(!hasItemRef(errors.items, "component-underrated", "C_OK"));
    try std.testing.expect(hasItemRef(errors.items, "component-rating-unproven", "R_UN"));
    try std.testing.expect(hasItemRef(errors.items, "component-underrated", "R0"));
    try std.testing.expect(!hasItemRef(errors.items, "component-rating-missing", "R0"));
    try std.testing.expect(hasItemRefMessage(errors.items, "component-rating-invalid", "R0_BAD", "jumper rated current"));
    try std.testing.expect(hasItemRefMessage(errors.items, "component-rating-invalid", "R0_BAD", "maximum jumper resistance"));
    try std.testing.expect(!hasItemRef(errors.items, "component-rating-unproven", "R0_BAD"));
}

// spec: fabrication-release - saved rounded outlines must exactly match authored dimensions, radius, polygon, and native arcs
test "release outline drift compares exact rounded geometry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const corners = [_][2]f64{ .{ 0, 0 }, .{ 40, 0 }, .{ 40, 20 }, .{ 0, 20 } };
    const radii = [_]f64{ 2, 2, 2, 2 };
    const expected = try outline_mod.filletPath(arena, &corners, &radii, 0.01);
    var placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 40,
        .maxy = 20,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 40, .h = 20 },
        .board_poly = expected.poly,
        .board_arcs = expected.arcs,
    };
    var errors: std.ArrayList(Item) = .empty;
    try appendOutlineDrift(arena, &errors, placement, 40, 20, 2);
    try std.testing.expectEqual(@as(usize, 0), errors.items.len);
    try appendOutlineDrift(arena, &errors, placement, 41, 20, 2);
    try std.testing.expectEqual(@as(usize, 1), errors.items.len);
    errors.clearRetainingCapacity();
    try appendOutlineDrift(arena, &errors, placement, 40, 20, 3);
    try std.testing.expectEqual(@as(usize, 1), errors.items.len);
    const deformed = try arena.dupe([2]f64, expected.poly);
    deformed[0][0] += 0.5;
    placement.board_poly = deformed;
    errors.clearRetainingCapacity();
    try appendOutlineDrift(arena, &errors, placement, 40, 20, 2);
    try std.testing.expectEqual(@as(usize, 1), errors.items.len);
}

// spec: fabrication-release - synthesized footprint fallback geometry is a non-waivable release identity failure
test "release identity rejects fallback footprint geometry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = [_]optimizer.Part{.{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = true, .x = 5, .y = 5 }};
    const properties = [_]env_mod.Property{ .{ .key = "manufacturer", .value = "Maker" }, .{ .key = "mpn", .value = "PART-1" } };
    const instances = [_]flat_netlist.FlatInstance{.{ .ref_des = "U1", .component = "fixture", .value = "fixture", .footprint = "missing", .uuid = "uuid-1", .properties = &properties }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &instances,
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
    };
    var errors: std.ArrayList(Item) = .empty;
    try appendReleaseIdentityChecks(arena, &errors, placement, false);
    try std.testing.expect(hasItemRef(errors.items, "footprint-geometry-unresolved", "U1"));
}

fn pointNear(a: [2]f64, b: [2]f64, tolerance: f64) bool {
    return @abs(a[0] - b[0]) <= tolerance and @abs(a[1] - b[1]) <= tolerance;
}

fn polygonEquivalent(a: []const [2]f64, b: []const [2]f64, tolerance: f64) bool {
    if (a.len != b.len or a.len == 0) return false;
    for (b, 0..) |candidate, offset| {
        if (!pointNear(a[0], candidate, tolerance)) continue;
        var forward = true;
        var reverse = true;
        for (a, 0..) |point, index| {
            if (!pointNear(point, b[(offset + index) % b.len], tolerance)) forward = false;
            if (!pointNear(point, b[(offset + b.len - index) % b.len], tolerance)) reverse = false;
        }
        if (forward or reverse) return true;
    }
    return false;
}

fn arcNear(a: optimizer.BoardArc, b: optimizer.BoardArc, tolerance: f64) bool {
    const forward = pointNear(a.p1, b.p1, tolerance) and pointNear(a.pm, b.pm, tolerance) and pointNear(a.p2, b.p2, tolerance);
    const reverse = pointNear(a.p1, b.p2, tolerance) and pointNear(a.pm, b.pm, tolerance) and pointNear(a.p2, b.p1, tolerance);
    return forward or reverse;
}

fn arcsEquivalent(a: []const optimizer.BoardArc, b: []const optimizer.BoardArc, tolerance: f64) bool {
    if (a.len != b.len or a.len == 0) return false;
    for (b, 0..) |candidate, offset| {
        if (!arcNear(a[0], candidate, tolerance)) continue;
        var forward = true;
        var reverse = true;
        for (a, 0..) |arc, index| {
            if (!arcNear(arc, b[(offset + index) % b.len], tolerance)) forward = false;
            if (!arcNear(arc, b[(offset + b.len - index) % b.len], tolerance)) reverse = false;
        }
        if (forward or reverse) return true;
    }
    return false;
}

/// Serialize a report to the JSON the endpoint returns / the modal reads:
/// `{"ok":bool,"errors":[{id,message,net?,ref?,count?}],"warnings":[…],"stats":{…}}`.
pub fn writeJson(w: *std.Io.Writer, report: Report) std.Io.Writer.Error!void {
    try w.print("{{\"ok\":{s},\"errors\":[", .{if (report.ok()) "true" else "false"});
    try writeItems(w, report.errors);
    try w.writeAll("],\"warnings\":[");
    try writeItems(w, report.warnings);
    try w.writeAll("],\"stats\":{");
    const s = report.stats;
    try w.print("\"parts\":{d},\"nets\":{d},\"tracks\":{d},\"vias\":{d}," ++
        "\"routable_nets\":{d},\"connected_nets\":{d},\"drc_violations\":{d}," ++
        "\"dangling_copper\":{d},\"implicit_junctions\":{d},\"hairline_gaps\":{d}," ++
        "\"connectivity_coarsened\":{s},\"has_outline\":{s},\"dnp_parts\":{d}", .{
        s.parts,
        s.nets,
        s.tracks,
        s.vias,
        s.routable_nets,
        s.connected_nets,
        s.connectivity.drc_violations,
        s.connectivity.dangling_copper,
        s.connectivity.implicit_junctions,
        s.connectivity.hairline_gaps,
        if (s.connectivity.coarsened) "true" else "false",
        if (s.has_outline) "true" else "false",
        s.dnp_parts,
    });
    try w.writeAll("}}");
}

fn writeItems(w: *std.Io.Writer, items: []const Item) std.Io.Writer.Error!void {
    for (items, 0..) |it, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"id\":");
        try writeJsonStr(w, it.id);
        try w.writeAll(",\"message\":");
        try writeJsonStr(w, it.message);
        if (it.net) |n| {
            try w.writeAll(",\"net\":");
            try writeJsonStr(w, n);
        }
        if (it.ref) |r| {
            try w.writeAll(",\"ref\":");
            try writeJsonStr(w, r);
        }
        if (it.count > 0) try w.print(",\"count\":{d}", .{it.count});
        try w.writeAll("}");
    }
}

/// Minimal JSON string escaper (quotes + backslash + control chars) — the net
/// names and messages here never contain exotic characters, but be safe.
fn writeJsonStr(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}

// ── Connectivity model ──────────────────────────────────────────────────────

/// A net's connectivity picture: how many distinct board LOCATIONS its pads
/// occupy (single-location nets need no copper), and how many CONNECTED GROUPS
/// those pads fall into once the persisted copper (and any plane) is applied.
const NetConn = struct { locations: usize, groups: usize, coarsened: bool = false };

/// The identity AND copper of a `NetGraph` pad node — enough for a caller that
/// groups pads into copper islands (`net_open`) to NAME the island (`U17` pad
/// `3`) instead of reporting a bare coordinate, and to MEASURE from it when the
/// island is the bare pad (nothing routed to it, so the pad's own copper is all
/// the island has). `part` indexes `placement.parts`; every field is borrowed,
/// never owned.
pub const PadId = struct {
    part: i32 = -1,
    pad: []const u8 = "",
    shape: pad_shape.Shape = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 },
    side: optimizer.Side = .top,
    thru: bool = false,
};

/// One net's connectivity graph over the persisted copper: a union-find where
/// every pad, track segment, via, AND kept copper-pour component is a node, so
/// connectivity propagates through multi-segment route chains, via layer-jumps,
/// and the real (island-verified) plane fill. Node index layout:
///   `[0, n_pads)`                      → pad nodes
///   `[n_pads, n_pads + tracks.len)`    → track nodes (`tracks[node - n_pads]`)
///   `[.. , + vias.len)`                → via nodes
///   `[.. tail]`                        → pour-component nodes (no geometry)
/// The fab gate reads it for pad groups (`netComponents`) and the `net_open`
/// DRC marker reads it for drawn-copper islands, so the export blocker and the
/// viewer marker can never disagree on what "connected" means.
pub const NetGraph = struct {
    parent: []usize,
    n_pads: usize,
    /// Pad identities, one per pad node (`pads[i]` describes node `i`).
    pads: []const PadId,
    tracks: []const router.Track,
    vias: []const router.Via,
    locations: usize,
    /// How this net met the computed plane / pour copper (see `PlaneJoin`).
    plane: PlaneJoin = .{},

    /// The canonical union-find root of a node (path-halving; mutates `parent`).
    pub fn root(self: NetGraph, node: usize) usize {
        return find(self.parent, node);
    }
};

/// A net's relationship to the computed plane / pour copper: which graph nodes
/// that copper attached to, and whether the raster it was decided on was exact.
const PlaneJoin = struct {
    /// Nodes attached to the net's plane/pour copper: the fill-component tails
    /// `planeConnect` credited plus each user zone's first united member. An
    /// island sharing a root with one of these is already joined to that
    /// copper, so a plane stitch dropped beside it lands in copper it is
    /// already part of and can never merge it any further.
    nodes: []const usize = &.{},
    /// The pour raster this net's plane membership was decided on was DEGRADED
    /// to fit the fill cell budget (`pour.lattice` coarsened its pitch). A
    /// coarser raster can merge two fill components a fine one would keep
    /// apart, so the plane half of the verdict is approximate — the flag is
    /// carried so a caller CAN say so rather than presenting it as exact.
    /// False for every net on a board whose fill fits the budget.
    coarsened: bool = false,
};

/// One net's routability + connectedness verdict, exposed so a caller (the
/// progress ladder's serve seam) can read per-net connectivity WITHOUT running
/// the whole readiness gate. `routable` = pads in ≥2 board locations (so the
/// net needs copper); `connected` = that copper (and any plane) joins them into
/// one group; `islands` = the isolated-copper-group count behind an unconnected
/// net (what the gate's airwire error reports).
pub const NetStatus = struct {
    name: []const u8,
    routable: bool,
    connected: bool,
    islands: usize,
    /// At least one credited plane/pour fill was raster-coarsened to fit the
    /// cell budget, so the connectivity verdict is approximate.
    coarsened: bool = false,
    hairline_gaps: usize = 0,
};

/// Compute per-net connectivity over the persisted copper — one `NetStatus` per
/// design net, in `placement.nets` order. This is the loop `check` used to
/// inline; factoring it out lets serve code build a progress ladder from the
/// same numbers the fab gate reports (they call the identical `netComponents`).
pub fn netConnectivity(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: export_gerber.Copper,
) std.mem.Allocator.Error![]const NetStatus {
    const zone_fills = try userZoneFills(arena, placement, copper, null);
    const physical = try export_gerber.physicalCopper(arena, copper);
    var out: std.ArrayList(NetStatus) = .empty;
    const identity = try net_identity.Identity.init(arena, placement);
    for (placement.nets, 0..) |net, net_i| {
        const graph = try buildNetGraphPrepared(arena, placement, physical, net, @intCast(net_i), .{ .zone_fills = zone_fills, .identity = identity });
        try out.append(arena, try netStatusFromGraph(arena, net.name, graph, true));
    }
    return out.toOwnedSlice(arena);
}

/// The routable-net tally of a board's copper: how many nets are fully
/// connected, how many need copper at all, and the names still open.
pub const Tally = struct {
    /// Connection-level micro-net tally used by routing progress and repair
    /// gates. Per-pin stubs such as `VDD.U3.7` remain separate here.
    routed: usize = 0,
    total: usize = 0,
    /// User-facing logical-net tally: dot-suffixed micro-nets collapse onto
    /// their base name, and a base is routed only when every routable member
    /// is connected.
    unique_routed: usize = 0,
    unique_total: usize = 0,
    open: []const []const u8 = &.{},
    coarsened: bool = false,
    hairline_gaps: usize = 0,
};

/// Summarise `copper`'s connectivity into a `Tally`. This is the ONE routed/
/// total/open answer every reporting surface shares — `/api/pcb-describe`'s
/// `routed` block, the `add_tracks` result, and (via `netConnectivity` directly)
/// the completion ladder's routing rung — so they can never disagree on what
/// "routed" means the way they did when describe reported the router's own
/// counters for copper the router never routed.
///
/// Non-routable nets (pads in <2 board locations — a single pad, or a
/// plane-carried net the pour joins) are excluded from BOTH numerator and
/// denominator, matching the ladder's tally exactly.
pub fn routableTally(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: export_gerber.Copper,
) std.mem.Allocator.Error!Tally {
    const conn = try netConnectivity(arena, placement, copper);
    return summarizeConnectivity(arena, conn);
}

/// Fold per-net connectivity statuses into the connection-level and collapsed
/// logical-net totals reported by the PCB APIs.
pub fn summarizeConnectivity(arena: std.mem.Allocator, conn: []const NetStatus) std.mem.Allocator.Error!Tally {
    var t = Tally{};
    var open: std.ArrayList([]const u8) = .empty;
    var logical = std.StringArrayHashMapUnmanaged(bool).empty;
    for (conn) |ns| {
        t.coarsened = t.coarsened or ns.coarsened;
        t.hairline_gaps += ns.hairline_gaps;
        if (!ns.routable) continue;
        t.total += 1;
        const gop = try logical.getOrPut(arena, net_analysis.baseNetName(ns.name));
        if (!gop.found_existing) {
            gop.value_ptr.* = true;
            t.unique_total += 1;
        }
        gop.value_ptr.* = gop.value_ptr.* and ns.connected;
        if (ns.connected) {
            t.routed += 1;
        } else {
            try open.append(arena, ns.name);
        }
    }
    for (logical.values()) |connected| {
        if (connected) t.unique_routed += 1;
    }
    t.open = try open.toOwnedSlice(arena);
    return t;
}

/// One pad of an open net, tagged with the copper island it currently belongs
/// to. Two pads sharing an `island` are already joined; different islands are
/// what still has to be bridged.
pub const OpenPad = struct {
    ref: []const u8,
    pad: []const u8,
    x: f64,
    y: f64,
    side: optimizer.Side,
    thru: bool,
    island: usize,
};

/// One hop that would join two of an open net's islands: the closest pad pair
/// across them. `islands - 1` hops close the net.
pub const OpenGap = struct {
    from: OpenPad,
    to: OpenPad,
    mm: f64,
};

/// Everything needed to finish one unconnected net by hand.
pub const OpenNet = struct {
    net: []const u8,
    islands: usize,
    pads: []const OpenPad,
    gaps: []const OpenGap,
    /// Per island id: is that island already joined to the net's plane/pour
    /// copper? A stitch beside such an island can never merge anything — the via
    /// lands in copper the island is already part of — so stitch planners skip
    /// it and it rejoins the net by bridge instead.
    ///
    /// SEVERAL islands can be joined at once, and reading this as "at most one"
    /// (two pour-joined islands would surely be one island) is wrong: there is
    /// one plane node per pour COMPONENT (see `PlaneJoin.nodes`), so islands
    /// sitting on two disjoint pieces of the same net's pour are each joined, to
    /// different metal, and stay separate islands. Measured on barracuda's
    /// `dp-coupled-v3`: `GND` in three islands, all three plane-joined, zero
    /// stitchable. A planner that assumes one joined island reads that as "no
    /// hops for this net at all" — which is exactly what made a `close_open_nets`
    /// call scoped to `GND` plan nothing and return the board untouched.
    plane_joined: []const bool = &.{},
};

/// Per-net routing detail for every net that still has an airwire: WHERE each
/// pad is, which copper island it sits in, and the shortest pad-to-pad hops
/// that would close it.
///
/// This is the fact an agent could not previously obtain at all: `stuck[]`
/// reports precise coordinates for the copper BLOCKING a net but never for the
/// net's own pads, and the facts JSON reduced hub pads to compass words
/// ("edges":["center"]). Without endpoints there is nothing to aim
/// `add_tracks` at, so the write seam alone could not finish a board.
pub fn openNets(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: export_gerber.Copper,
) std.mem.Allocator.Error![]const OpenNet {
    return openNetsAmong(arena, placement, copper, null);
}

/// The `openNets` report restricted to exact net names. `names == null` means
/// every placement net; a non-null empty slice means none. Results retain
/// placement-net order, and unknown or duplicate requested names are ignored.
/// This lets bounded repair passes avoid building connectivity graphs (and
/// rasterising pour fills) for nets they cannot select.
pub fn openNetsAmong(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: export_gerber.Copper,
    names: ?[]const []const u8,
) std.mem.Allocator.Error![]const OpenNet {
    if (names) |wanted| if (wanted.len == 0) return &.{};
    const zone_fills = try userZoneFills(arena, placement, copper, null);
    const physical = try export_gerber.physicalCopper(arena, copper);
    var out: std.ArrayList(OpenNet) = .empty;
    const identity = try net_identity.Identity.init(arena, placement);
    for (placement.nets, 0..) |net, ni| {
        if (names) |wanted| {
            var selected = false;
            for (wanted) |name| {
                if (std.mem.eql(u8, name, net.name)) {
                    selected = true;
                    break;
                }
            }
            if (!selected) continue;
        }
        const detail = try openNetDetail(arena, placement, physical, net, @intCast(ni), .{ .zone_fills = zone_fills, .identity = identity });
        if (detail) |d| try out.append(arena, d);
    }
    return out.toOwnedSlice(arena);
}

/// Build one net's `OpenNet`, or null when the net needs no copper or is
/// already connected.
fn openNetDetail(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: export_gerber.Copper,
    net: export_kicad.FlatNet,
    net_i: i32,
    fills: SharedFills,
) std.mem.Allocator.Error!?OpenNet {
    // ONE graph for both the verdict and the island report: `buildNetGraph`
    // rasters the net's pour fills, so building it twice here paid that raster
    // twice per open net for an identical answer. `padNodes` is the same
    // deterministic list the graph's pad nodes were built from, so index `i`
    // still names node `i`.
    const g = try buildNetGraphPrepared(arena, placement, copper, net, net_i, fills);
    const comps = try netComponentsOf(arena, g);
    if (comps.locations < 2 or comps.groups <= 1) return null;

    // Densify each pad's union-find root into a 0-based island id.
    const items = try padNodes(arena, placement, net);
    var dense: std.AutoHashMapUnmanaged(usize, usize) = .empty;
    const pads = try arena.alloc(OpenPad, items.len);
    for (items, 0..) |p, i| {
        const r = g.root(i);
        const gop = try dense.getOrPut(arena, r);
        if (!gop.found_existing) gop.value_ptr.* = dense.count() - 1;
        pads[i] = .{
            .ref = p.ref,
            .pad = p.pad,
            .x = p.cx,
            .y = p.cy,
            .side = p.side,
            .thru = p.thru,
            .island = gop.value_ptr.*,
        };
    }
    // Which islands are already joined to plane/pour copper: a pad whose root
    // matches a plane node's root sits in an island the pour already carries.
    const plane_joined = try arena.alloc(bool, dense.count());
    @memset(plane_joined, false);
    for (g.plane.nodes) |pn| {
        const pr = g.root(pn);
        for (items, 0..) |_, i| {
            if (g.root(i) == pr) plane_joined[pads[i].island] = true;
        }
    }

    return .{
        .net = net.name,
        .islands = comps.groups,
        .pads = pads,
        .gaps = try closingGaps(arena, pads, dense.count()),
        .plane_joined = plane_joined,
    };
}

/// Greedy chain over the islands: repeatedly attach the nearest still-detached
/// island to the growing joined set, emitting the pad pair that bridges it.
/// Yields `islands - 1` hops — the minimum number of connections that closes
/// the net — nearest-first, so the cheapest work is listed first.
fn closingGaps(
    arena: std.mem.Allocator,
    pads: []const OpenPad,
    n_islands: usize,
) std.mem.Allocator.Error![]const OpenGap {
    if (n_islands < 2 or pads.len == 0) return &.{};
    var joined = try arena.alloc(bool, n_islands);
    @memset(joined, false);
    joined[pads[0].island] = true;
    var out: std.ArrayList(OpenGap) = .empty;
    var remaining = n_islands - 1;
    while (remaining > 0) : (remaining -= 1) {
        var best: ?OpenGap = null;
        for (pads) |a| {
            if (!joined[a.island]) continue;
            for (pads) |b| {
                if (joined[b.island]) continue;
                const d = std.math.hypot(b.x - a.x, b.y - a.y);
                if (best == null or d < best.?.mm) best = .{ .from = a, .to = b, .mm = d };
            }
        }
        const pick = best orelse break;
        joined[pick.to.island] = true;
        try out.append(arena, pick);
    }
    return out.toOwnedSlice(arena);
}

/// One pad terminal of a net, reduced to its world box + centre. `part` lets us
/// treat two pads of the same part on the same net as one location; `thru`/
/// `side` let the pour decide which copper layers the pad reaches.
const PadNode = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    poly: []const [2]f64,
    cx: f64,
    cy: f64,
    part: usize,
    /// Index of the flattened schematic pin that produced this geometry. A
    /// footprint may describe one logical pin with several same-number pads
    /// (a custom SMD land plus embedded plated barrels); those geometries are
    /// separate copper contact shapes but one component terminal.
    logical: usize,
    thru: bool,
    side: optimizer.Side,
    /// The pin this pad came from, kept so `openNets` can name the endpoint an
    /// agent has to route to (`U17` pad `3`) rather than a bare coordinate.
    ref: []const u8 = "",
    pad: []const u8 = "",
};

/// Resolve a net's pins to placed pad geometry, in `net.pins` order (pins whose
/// part/pad don't resolve are skipped). Shared by `buildNetGraph` and
/// `openNets` so both index the same node list.
fn padNodes(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    net: export_kicad.FlatNet,
) std.mem.Allocator.Error![]PadNode {
    var nodes: std.ArrayList(PadNode) = .empty;
    for (net.pins, 0..) |pin, logical| {
        const pi = partIndex(placement, pin.ref_des) orelse continue;
        const part = placement.parts[pi];
        for (part.pads) |pad| {
            if (!std.mem.eql(u8, pad.number, pin.pin)) continue;
            const sh = try pad_shape.worldShape(arena, part, pad);
            const anchor = pad_shape.copperAnchor(sh);
            try nodes.append(arena, .{
                .x0 = sh.x0,
                .y0 = sh.y0,
                .x1 = sh.x1,
                .y1 = sh.y1,
                .poly = sh.poly,
                .cx = anchor[0],
                .cy = anchor[1],
                .part = pi,
                .logical = logical,
                .thru = pad.thru,
                .side = part.side,
                .ref = pin.ref_des,
                .pad = pin.pin,
            });
        }
    }
    return nodes.toOwnedSlice(arena);
}

/// Unite every copper geometry belonging to one component pin. Repeated
/// same-number pads are one logical terminal: integrated thermal/output vias
/// connect the custom SMD land to the opposite face even though the flattened
/// netlist quite correctly names that pin only once.
fn uniteLogicalPads(parent: []usize, items: []const PadNode) void {
    if (items.len < 2) return;
    for (items[1..], 1..) |item, i| {
        if (item.logical == items[i - 1].logical) unite(parent, i, i - 1);
    }
}

fn firstLogicalGeometry(items: []const PadNode, i: usize) bool {
    return i == 0 or items[i - 1].logical != items[i].logical;
}

/// Distinct logical terminal positions, preserving the historical 0.05 mm
/// coincident-pad bucket while ignoring extra geometries of the same pin.
fn logicalPadLocations(items: []const PadNode) usize {
    var locations: usize = 0;
    for (items, 0..) |a, i| {
        if (!firstLogicalGeometry(items, i)) continue;
        var duplicate = false;
        for (items[0..i], 0..) |b, j| {
            if (!firstLogicalGeometry(items, j)) continue;
            if (@abs(a.cx - b.cx) < 0.05 and @abs(a.cy - b.cy) < 0.05) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) locations += 1;
    }
    return locations;
}

/// Unite every pair of this net's pad nodes whose LANDS meet. Two pads share
/// copper only where they share a face: both SMD on the same side, or either one
/// a through-hole barrel (which reaches every layer). A cheap inflated-box
/// reject runs first, so the O(pads²) sweep costs four comparisons per far pair
/// and the exact outline gap only for the neighbours that could actually touch.
fn unitePadOverlaps(parent: []usize, items: []const PadNode) void {
    for (items, 0..) |a, i| {
        for (items[i + 1 ..], i + 1..) |b, j| {
            const shares_face = a.thru or b.thru or a.side == b.side;
            if (!shares_face) continue;
            if (a.x1 + touch_slack_mm < b.x0 or b.x1 + touch_slack_mm < a.x0) continue;
            if (a.y1 + touch_slack_mm < b.y0 or b.y1 + touch_slack_mm < a.y0) continue;
            const ga = pad_shape.Shape{ .x0 = a.x0, .y0 = a.y0, .x1 = a.x1, .y1 = a.y1, .poly = a.poly };
            const gb = pad_shape.Shape{ .x0 = b.x0, .y0 = b.y0, .x1 = b.x1, .y1 = b.y1, .poly = b.poly };
            if (pad_shape.shapeGap(ga, gb, touch_slack_mm) <= touch_slack_mm) unite(parent, i, j);
        }
    }
}

/// Unite every pair of this net's VIA nodes whose barrel pads overlap or abut —
/// a via stitched on top of another, or a stitch pair dropped shoulder to
/// shoulder. Both vias span every layer, so there is no face test: touching is
/// connecting.
///
/// `route_cleanup.countCopperIslands` has always united abutting same-net vias
/// at this exact slack. Without the same rule here the cleanup pass and this
/// oracle disagree about one piece of copper — one island there, two here — and
/// the disagreement surfaces as a phantom `net_open` marker plus a phantom
/// fab-gate airwire on a net whose copper is solid. `net_open`'s `viaVia` probe
/// would then dutifully measure the gap of a join the graph could never make.
///
/// `base` is the first via node's index. O(vias²) over ONE net's vias (moderate
/// counts) behind a cheap axis reject, matching `unitePadOverlaps`' shape.
fn uniteViaOverlaps(parent: []usize, vias: []const router.Via, base: usize) void {
    for (vias, 0..) |a, i| {
        for (vias[i + 1 ..], i + 1..) |b, j| {
            const reach = a.dia / 2 + b.dia / 2 + touch_slack_mm;
            if (@abs(a.x - b.x) > reach or @abs(a.y - b.y) > reach) continue;
            if (std.math.hypot(a.x - b.x, a.y - b.y) <= reach) unite(parent, base + i, base + j);
        }
    }
}

/// Does this pad sit on the signal layer a user copper pour occupies? A
/// through-hole pad reaches every layer; an SMD pad only its own outer face
/// (top = layer 0, bottom = layer 1 — the router's outer-layer numbering). For
/// an INNER-layer zone (signal index ≥2) this is therefore true only for
/// through-hole pads — SMD copper lives on the outer faces and never touches an
/// inner layer, exactly the membership an inner pour needs.
fn padInZoneLayer(node: PadNode, layer: u8) bool {
    if (node.thru) return true;
    const face: u8 = if (node.side == .top) 0 else 1;
    return face == layer;
}

/// One net's candidate zone members as union-find nodes: its pads and vias,
/// with `via_base` the node index of `vias[0]`.
const ZoneNodes = struct {
    items: []const PadNode,
    tracks: []const router.Track,
    vias: []const router.Via,
    fills: ?[]const pour.Fill,
    track_base: usize,
    via_base: usize,
};

fn pointInZoneFill(fills: ?[]const pour.Fill, zones: []const pour.UserZone, zone_i: usize, x: f64, y: f64) bool {
    if (fills) |fs| return fs[zone_i].contains(x, y);
    if (!outline_mod.contains(zones[zone_i].poly, x, y)) return false;
    return !pour.clippedByHigher(zones, zone_i, x, y);
}

fn componentInZoneFill(fills: ?[]const pour.Fill, zones: []const pour.UserZone, zone_i: usize, x: f64, y: f64) i32 {
    if (fills) |fs| return fs[zone_i].componentAt(x, y);
    return if (pointInZoneFill(null, zones, zone_i, x, y)) 0 else -1;
}

fn trackEntersZoneFill(fills: ?[]const pour.Fill, zones: []const pour.UserZone, zone_i: usize, track: router.Track) bool {
    if (pointInZoneFill(fills, zones, zone_i, track.x1, track.y1)) return true;
    if (pointInZoneFill(fills, zones, zone_i, track.x2, track.y2)) return true;
    const crossing = outline_mod.segCrossesEdge(zones[zone_i].poly, track.x1, track.y1, track.x2, track.y2) orelse return false;
    return pointInZoneFill(fills, zones, zone_i, crossing[0], crossing[1]);
}

/// Union every same-net pad (on the zone's face) and same-net via whose centre
/// lies inside a filled, netted, non-keepout user copper pour into one
/// component per zone. Keepout zones never reach here (the serve layer filters
/// them before building `copper.zones`); `nodes` is already this net's.
/// Each zone's first united member is reported into `anchors` so the graph can
/// name which nodes sit in pour copper (see `PlaneJoin.nodes`).
fn uniteUserZones(
    arena: std.mem.Allocator,
    parent: []usize,
    zones: []const pour.UserZone,
    net_name: []const u8,
    nodes: ZoneNodes,
    anchors: *std.ArrayList(usize),
) std.mem.Allocator.Error!void {
    for (zones, 0..) |z, zi| {
        if (!std.mem.eql(u8, z.net, net_name)) continue;
        var component_anchors: std.AutoHashMapUnmanaged(i32, usize) = .empty;
        for (nodes.items, 0..) |p, pi| {
            if (!padInZoneLayer(p, z.layer)) continue;
            const component = componentInZoneFill(nodes.fills, zones, zi, p.cx, p.cy);
            if (component < 0) continue;
            // A pad inside a higher-priority overlapping pour sits where this
            // pour's copper receded (the clearance gap) — it is not united here.
            if (pour.clippedByHigher(zones, zi, p.cx, p.cy)) continue;
            const gop = try component_anchors.getOrPut(arena, component);
            if (gop.found_existing) unite(parent, gop.value_ptr.*, pi) else gop.value_ptr.* = pi;
        }
        for (nodes.tracks, 0..) |t, ti| {
            if (t.layer != z.layer) continue;
            const node = nodes.track_base + ti;
            const components = if (nodes.fills) |fills|
                try pour.segmentComponents(arena, fills[zi], t.x1, t.y1, t.x2, t.y2)
            else
                &[_]i32{if (trackEntersZoneFill(null, zones, zi, t)) 0 else -1};
            for (components) |component| {
                if (component < 0) continue;
                const gop = try component_anchors.getOrPut(arena, component);
                if (gop.found_existing) unite(parent, gop.value_ptr.*, node) else gop.value_ptr.* = node;
            }
        }
        for (nodes.vias, 0..) |v, vi| {
            const component = componentInZoneFill(nodes.fills, zones, zi, v.x, v.y);
            if (component < 0) continue;
            if (pour.clippedByHigher(zones, zi, v.x, v.y)) continue;
            const node = nodes.via_base + vi;
            const gop = try component_anchors.getOrPut(arena, component);
            if (gop.found_existing) unite(parent, gop.value_ptr.*, node) else gop.value_ptr.* = node;
        }
        var anchor_it = component_anchors.valueIterator();
        while (anchor_it.next()) |anchor| try anchors.append(arena, anchor.*);
    }
}

/// Build `net`'s connectivity graph over the persisted copper (see `NetGraph`).
/// Tracks/vias are union-find nodes themselves, so connectivity propagates
/// through a maze route's multi-segment chain and its via layer-jumps; the
/// computed copper POUR folds in as the honest plane connector (a pad counts as
/// plane-connected iff it lands in a KEPT pour component — one isolated by its
/// antipad ring, split off by a foreign trace, or on the wrong side of a
/// single-sided pour stays its own group). The full graph is always built (no
/// single-location short-circuit) so `net_open` can read the copper islands.
pub fn buildNetGraph(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: export_gerber.Copper,
    net: export_kicad.FlatNet,
    net_i: i32,
) std.mem.Allocator.Error!NetGraph {
    const zone_fills = try userZoneFills(arena, placement, copper, null);
    const physical = try export_gerber.physicalCopper(arena, copper);
    return buildNetGraphPrepared(arena, placement, physical, net, net_i, .{
        .zone_fills = zone_fills,
        .identity = try net_identity.Identity.init(arena, placement),
    });
}

/// Raster every retained user zone once per board-level connectivity query.
/// A zone's fill depends on the board/copper, not on the net whose union-find
/// graph happens to be inspected. Rebuilding this identical raster for every
/// one of a board's nets dominated the post-route connectivity report.
pub fn userZoneFills(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: export_gerber.Copper,
    base: ?pour.EdgeField,
) std.mem.Allocator.Error![]const pour.Fill {
    return userZoneFillsMemo(arena, placement, copper, base, null);
}

/// `userZoneFills` through a caller's per-fill memo (`pour.FillMemo`). Null is
/// exactly `userZoneFills`; a memo makes each zone's raster reusable across the
/// board edits that did not reach it.
pub fn userZoneFillsMemo(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: export_gerber.Copper,
    base: ?pour.EdgeField,
    memo: ?pour.FillMemo,
) std.mem.Allocator.Error![]const pour.Fill {
    const fills = try arena.alloc(pour.Fill, copper.zones.len);
    // One board, one lattice: seed the edge-margin field once for all zones.
    // `base` is the caller's shared field when the whole render pours the same
    // board (the page render, the fab gate) — without it we seed our own.
    const base_eff = if (base) |b| b else try pour.sharedEdgeField(arena, placement);
    for (copper.zones, 0..) |z, zi| {
        var spec = pour.zoneLayerSpec(z.net, pour.sideOfSignal(z.layer), z.layer, z.poly);
        spec.higher = try pour.higherPolys(arena, copper.zones, zi);
        fills[zi] = try pour.computeMemo(arena, placement, .{
            .tracks = copper.tracks,
            .vias = copper.vias,
            .arcs = copper.arcs,
            .rf_paths = copper.rf_paths,
        }, spec, base_eff, memo);
    }
    return fills;
}

/// `buildNetGraph` with the board's user-zone rasters already computed — the
/// form every whole-board loop wants. The fills depend on the board and its
/// copper, never on which net is being inspected, so a caller that walks all
/// nets calls `userZoneFills` once and hands the same slice to each net;
/// rebuilding it per net is what made a barracuda-sized DRC take a minute and a
/// half instead of a second.
/// The board-level fill state one net's graph reads and no net changes: the
/// user-zone rasters computed once for the whole sweep, plus the caller's
/// shared board-edge margin field. Bundled so `buildNetGraphPrepared` stays
/// under the function-size cap and every per-net call hands over the same
/// shared state.
pub const SharedFills = struct {
    zone_fills: []const pour.Fill,
    base: ?pour.EdgeField = null,
    /// Optional carrying-layer fills retained by full DRC's topology pass.
    /// When present, connectivity assigns components from these exact labels
    /// instead of rasterizing the same plane again.
    plane_fills: []const pour.NetFills = &.{},
    /// Canonical bypass-stub ownership, shared across a whole-board net sweep.
    identity: net_identity.Identity = .{},
};

fn preparedNetFills(all: []const pour.NetFills, name: []const u8) ?pour.NetFills {
    for (all) |prepared| if (std.mem.eql(u8, prepared.net_name, name)) return prepared;
    return null;
}

/// `buildNetGraph` with the board's user-zone rasters and edge-margin field
/// supplied by the caller. The fills depend on the board and its copper, never
/// on `net`, so a caller that walks every net rasters them once
/// (`userZoneFills`) and threads them through each call instead of rebuilding
/// them per net.
pub fn buildNetGraphPrepared(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: export_gerber.Copper,
    net: export_kicad.FlatNet,
    net_i: i32,
    fills: SharedFills,
) std.mem.Allocator.Error!NetGraph {
    const physical = try export_gerber.physicalCopper(arena, copper);
    const items = try padNodes(arena, placement, net);
    const identity = if (fills.identity.owner.len == placement.nets.len)
        fills.identity
    else
        try net_identity.Identity.init(arena, placement);
    const physical_name = identity.canonicalName(placement.nets, net_i);

    // Distinct board locations: unique pad-centre positions (0.05 mm buckets).
    // A net with <2 must not be flagged as unrouted (one pad, or all pads
    // coincident — a bridge/net-tie footprint).
    const locations = logicalPadLocations(items);

    // Same-net copper features become union-find nodes so connectivity chains
    // through them: pad↔track / pad↔via where copper lands on a pad, track↔track
    // at a same-layer joint, track↔via at a layer jump, via↔via where two
    // barrels abut.
    var segs: std.ArrayList(router.Track) = .empty;
    for (physical.tracks) |t| {
        if (identity.same(t.net, net_i)) try segs.append(arena, t);
    }
    var vs: std.ArrayList(router.Via) = .empty;
    for (physical.vias) |v| {
        if (identity.same(v.net, net_i)) try vs.append(arena, v);
    }
    const qpads = try planeQueries(arena, items);
    const query: pour.PlaneQuery = .{ .net_name = physical_name, .pads = qpads, .vias = vs.items, .base = fills.base };
    const join = if (preparedNetFills(fills.plane_fills, physical_name)) |prepared|
        try pour.planeConnectPrepared(arena, query, prepared)
    else
        try pour.planeConnect(arena, placement, .{ .tracks = physical.tracks, .vias = physical.vias, .arcs = physical.arcs, .zones = physical.zones }, query);
    const n_pads = items.len;
    const n_tracks = segs.items.len;
    const parent = try arena.alloc(usize, n_pads + n_tracks + vs.items.len + join.n_comp);
    for (parent, 0..) |*p, i| p.* = i;
    planeUnite(parent, join, n_pads, n_tracks);
    uniteLogicalPads(parent, items);
    // Every plane fill component is pour copper whether or not it credited a
    // pad, so its tail node marks the group it carries (see `PlaneJoin.nodes`).
    var plane_nodes: std.ArrayList(usize) = .empty;
    for (0..join.n_comp) |c| try plane_nodes.append(arena, n_pads + n_tracks + vs.items.len + c);

    for (segs.items, 0..) |t, ti| {
        // pad ↔ track: SMD lands join only copper on their own outer face;
        // through-hole lands reach every signal layer. A capsule graze is not
        // enough: the narrower feature's full transverse cross-section must
        // fit inside the other before the pair can carry connectivity.
        for (items, 0..) |p, pi| {
            const pad_layer: u8 = if (p.side == .top) 0 else 1;
            if (!copper_contact.padOnLayer(p.thru, pad_layer, t.layer)) continue;
            const shape = pad_shape.Shape{ .x0 = p.x0, .y0 = p.y0, .x1 = p.x1, .y1 = p.y1, .poly = p.poly };
            if (copper_contact.padTrackConnects(shape, .{ t.x1, t.y1 }, .{ t.x2, t.y2 }, t.width))
                unite(parent, pi, n_pads + ti);
        }
        // track ↔ track: a mere overlap between round caps or parallel flanks
        // is not a fabrication-robust join. The narrower trace must carry one
        // complete transverse cross-section inside the other trace's copper.
        // Mid-span crosses and explicit T/end junctions still unite. A cheap
        // inflated-bbox prefilter skips the exact test for the far pairs that
        // dominate a 900-track net.
        for (segs.items[ti + 1 ..], ti + 1..) |b, bi| {
            if (t.layer != b.layer) continue;
            const touch = t.width / 2 + b.width / 2 + touch_slack_mm;
            if (!bboxNear(t, b, touch)) continue;
            if (copper_contact.trackTrackConnects(
                .{ .a = .{ t.x1, t.y1 }, .b = .{ t.x2, t.y2 }, .width = t.width },
                .{ .a = .{ b.x1, b.y1 }, .b = .{ b.x2, b.y2 }, .width = b.width },
            ))
                unite(parent, n_pads + ti, n_pads + bi);
        }
        // track ↔ via: the cross-layer jump. As with pads and other traces, a
        // tangential copper sliver stays open; the narrower feature must carry
        // one complete cross-section inside the other feature.
        for (vs.items, 0..) |v, vi| {
            if (copper_contact.trackViaConnects(
                .{ .a = .{ t.x1, t.y1 }, .b = .{ t.x2, t.y2 }, .width = t.width },
                .{ .at = .{ v.x, v.y }, .dia = v.dia },
            ))
                unite(parent, n_pads + ti, n_pads + n_tracks + vi);
        }
    }
    // pad ↔ via (a via dropped on/next to a pad joins its group).
    for (vs.items, 0..) |v, vi| {
        const v_reach = v.dia / 2 + touch_slack_mm;
        for (items, 0..) |p, pi| {
            if (segShapeDist(v.x, v.y, v.x, v.y, p, v_reach) <= v_reach)
                unite(parent, pi, n_pads + n_tracks + vi);
        }
    }

    // via ↔ via: two of this net's own barrels that abut are one piece of
    // copper (see `uniteViaOverlaps`).
    uniteViaOverlaps(parent, vs.items, n_pads + n_tracks);

    // pad ↔ pad: two of this net's OWN lands that physically touch are one
    // piece of copper and need no trace between them — a split QFN supply pad
    // whose halves abut (barracuda's `adf4159/U20` pads 1 and 13 share an edge
    // at y = 107.375), a probe pad dropped onto a fanout pad, any footprint
    // that draws one shape as two. Nothing else in this graph joins them, so
    // without it the net reads as two islands and every reporting surface calls
    // a solid piece of copper an airwire.
    unitePadOverlaps(parent, items);

    // User-drawn copper pours credit only the same minimum-width-filtered fill
    // that Gerber emits. This prevents a narrow authored neck from closing a
    // net in readiness checks after the fabrication geometry removes it.
    try uniteUserZones(arena, parent, copper.zones, physical_name, .{
        .items = items,
        .tracks = segs.items,
        .vias = vs.items,
        .fills = fills.zone_fills,
        .track_base = n_pads,
        .via_base = n_pads + n_tracks,
    }, &plane_nodes);

    return .{
        .parent = parent,
        .n_pads = n_pads,
        .pads = try padIds(arena, items),
        .tracks = segs.items,
        .vias = vs.items,
        .locations = locations,
        .plane = .{ .nodes = plane_nodes.items, .coarsened = join.coarsened },
    };
}

/// `groups` counts the connected components over the PADS; `locations` counts
/// distinct pad positions (so a net whose every pad sits at one point isn't
/// "routable"). Derived from the one shared `buildNetGraph`.
fn netComponents(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: export_gerber.Copper,
    net: export_kicad.FlatNet,
    net_i: i32,
) std.mem.Allocator.Error!NetConn {
    return netComponentsOf(arena, try buildNetGraph(arena, placement, copper, net, net_i));
}

/// `netComponents` over an ALREADY-built graph — the half a caller that needs
/// the graph itself (`openNetDetail`) reuses instead of rasterizing the net's
/// pours a second time for the same answer.
fn netComponentsOf(arena: std.mem.Allocator, g: NetGraph) std.mem.Allocator.Error!NetConn {
    // A net whose pads all sit at one location needs no copper (single pad, or a
    // net-tie's coincident pads) — treat it as one group, never an airwire.
    if (g.locations < 2) return .{ .locations = g.locations, .groups = if (g.n_pads == 0) 0 else 1, .coarsened = g.plane.coarsened };
    var group_root: std.AutoHashMapUnmanaged(usize, void) = .empty;
    for (0..g.n_pads) |i| try group_root.put(arena, find(g.parent, i), {});
    return .{ .locations = g.locations, .groups = group_root.count(), .coarsened = g.plane.coarsened };
}

/// Derive one reporting status from an already-built connectivity graph.
/// Whole-board consumers that also need the graph use this seam so they do not
/// raster the same plane and rebuild the same unions a second time merely to
/// produce the routed tally. Callers that only expose that tally can skip the
/// separate quadratic hairline-gap audit with `include_hairline = false`.
pub fn netStatusFromGraph(arena: std.mem.Allocator, name: []const u8, graph: NetGraph, include_hairline: bool) std.mem.Allocator.Error!NetStatus {
    const comps = try netComponentsOf(arena, graph);
    const routable = comps.locations >= 2;
    return .{
        .name = name,
        .routable = routable,
        .connected = routable and comps.groups <= 1,
        .islands = comps.groups,
        .coarsened = comps.coarsened,
        .hairline_gaps = if (include_hairline) graphHairlineGaps(graph) else 0,
    };
}

/// Reduce the net's pad nodes to their reportable identity (`NetGraph.pads`).
fn padIds(arena: std.mem.Allocator, items: []const PadNode) std.mem.Allocator.Error![]const PadId {
    const out = try arena.alloc(PadId, items.len);
    for (items, 0..) |p, i| {
        out[i] = .{
            .part = std.math.cast(i32, p.part) orelse -1,
            .pad = p.pad,
            .shape = .{ .x0 = p.x0, .y0 = p.y0, .x1 = p.x1, .y1 = p.y1, .poly = p.poly },
            .side = p.side,
            .thru = p.thru,
        };
    }
    return out;
}

fn isHairlineGap(gap: f64) bool {
    return copper_contact.classifyGap(gap) == .hairline;
}

fn padsShareCopperFace(a: PadId, b: PadId) bool {
    if (a.thru or b.thru) return true;
    return a.side == b.side;
}

/// Count strict-graph feature pairs separated only by the 1–20 µm defect
/// band. Pairs already sharing a graph root are skipped, so a harmless near
/// approach elsewhere on copper that is solidly joined does not inflate the
/// readiness count.
fn graphHairlineGaps(g: NetGraph) usize {
    var count: usize = 0;
    const track_base = g.n_pads;
    const via_base = track_base + g.tracks.len;
    for (g.pads, 0..) |pad, pi| {
        const pad_layer: u8 = if (pad.side == .top) 0 else 1;
        for (g.tracks, 0..) |track, ti| {
            if (g.root(pi) == g.root(track_base + ti)) continue;
            if (!copper_contact.padOnLayer(pad.thru, pad_layer, track.layer)) continue;
            const distance = pad_shape.segmentDist(pad.shape, .{ track.x1, track.y1 }, .{ track.x2, track.y2 }, track.width / 2 + copper_contact.hairline_slack_mm);
            if (isHairlineGap(distance - track.width / 2)) count += 1;
        }
        for (g.vias, 0..) |via, vi| {
            if (g.root(pi) == g.root(via_base + vi)) continue;
            const distance = pad_shape.pointDist(pad.shape.x0, pad.shape.y0, pad.shape.x1, pad.shape.y1, pad.shape.poly, via.x, via.y, std.math.inf(f64));
            if (isHairlineGap(distance - via.dia / 2)) count += 1;
        }
        for (g.pads[pi + 1 ..], pi + 1..) |other, pj| {
            if (g.root(pi) == g.root(pj)) continue;
            if (!padsShareCopperFace(pad, other)) continue;
            if (isHairlineGap(pad_shape.shapeGap(pad.shape, other.shape, copper_contact.hairline_slack_mm))) count += 1;
        }
    }
    for (g.tracks, 0..) |track, ti| {
        for (g.tracks[ti + 1 ..], ti + 1..) |other, tj| {
            if (track.layer != other.layer or g.root(track_base + ti) == g.root(track_base + tj)) continue;
            const gap = drc.segSegDist(track.x1, track.y1, track.x2, track.y2, other.x1, other.y1, other.x2, other.y2) - track.width / 2 - other.width / 2;
            if (isHairlineGap(gap)) count += 1;
        }
        for (g.vias, 0..) |via, vi| {
            if (g.root(track_base + ti) == g.root(via_base + vi)) continue;
            const gap = segPointDist(track.x1, track.y1, track.x2, track.y2, via.x, via.y) - track.width / 2 - via.dia / 2;
            if (isHairlineGap(gap)) count += 1;
        }
    }
    for (g.vias, 0..) |via, vi| {
        for (g.vias[vi + 1 ..], vi + 1..) |other, vj| {
            if (g.root(via_base + vi) == g.root(via_base + vj)) continue;
            const gap = std.math.hypot(via.x - other.x, via.y - other.y) - via.dia / 2 - other.dia / 2;
            if (isHairlineGap(gap)) count += 1;
        }
    }
    return count;
}

/// Reduce the net's pad nodes to the pour engine's membership queries.
fn planeQueries(arena: std.mem.Allocator, items: []const PadNode) std.mem.Allocator.Error![]const pour.PadQuery {
    const out = try arena.alloc(pour.PadQuery, items.len);
    for (items, 0..) |p, i| {
        out[i] = .{
            .cx = p.cx,
            .cy = p.cy,
            .shape = .{ .x0 = p.x0, .y0 = p.y0, .x1 = p.x1, .y1 = p.y1, .poly = p.poly },
            .thru = p.thru,
            .side = p.side,
        };
    }
    return out;
}

/// Fold the pour-component assignment into the union-find: unite each pad / via
/// with the (arena-tail) node for the kept pour component it landed in. Pads /
/// vias in no component (-1) touch no pour node and stay their own group.
fn planeUnite(parent: []usize, join: pour.Join, n_pads: usize, n_tracks: usize) void {
    const base = n_pads + n_tracks + join.via_comp.len;
    for (join.pad_comp, 0..) |c, i| {
        if (c >= 0) unite(parent, i, base + @as(usize, @intCast(c)));
    }
    for (join.via_comp, 0..) |c, j| {
        if (c >= 0) unite(parent, n_pads + n_tracks + j, base + @as(usize, @intCast(c)));
    }
}

/// True when two tracks' axis-aligned bounding boxes, each inflated by `pad`,
/// overlap — the cheap reject that runs before the exact `segSegDist` so the
/// per-net track↔track scan stays affordable on a dense (900-track) net.
fn bboxNear(a: router.Track, b: router.Track, pad: f64) bool {
    return @min(b.x1, b.x2) <= @max(a.x1, a.x2) + pad and
        @max(b.x1, b.x2) >= @min(a.x1, a.x2) - pad and
        @min(b.y1, b.y2) <= @max(a.y1, a.y2) + pad and
        @max(b.y1, b.y2) >= @min(a.y1, a.y2) - pad;
}

/// Shortest distance from point (px,py) to segment (ax,ay)-(bx,by).
fn segPointDist(ax: f64, ay: f64, bx: f64, by: f64, px: f64, py: f64) f64 {
    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;
    if (len2 < 1e-12) return std.math.hypot(px - ax, py - ay);
    const t = std.math.clamp(((px - ax) * dx + (py - ay) * dy) / len2, 0, 1);
    return std.math.hypot(px - (ax + t * dx), py - (ay + t * dy));
}

/// Distance from segment (ax,ay)-(bx,by) to a pad's copper (0 inside it), or
/// `+inf` when the segment stays clear of the pad's `win`-inflated bounding box.
/// Sampled endpoints + a midpoint against the pad's real outline — exact
/// enough to decide "does this copper land on the pad" for connectivity.
///
/// `win` is the caller's touch threshold and drives an exact reject: a pad's
/// copper lies inside its box, so a segment whose own box stays more than `win`
/// away is more than `win` from the copper and cannot union. Only pairs that
/// survive it pay for the nine-sample outline walk. Without the reject the
/// (pads × tracks) and (pads × vias) sweeps ran that walk on every far pair —
/// 92 ms of barracuda's 150 ms DRC, spent proving that copper centimetres apart
/// does not touch. The track↔track sweep beside it has always had the same
/// prefilter (`bboxNear`); these two were the ones missing it.
fn segShapeDist(ax: f64, ay: f64, bx: f64, by: f64, p: PadNode, win: f64) f64 {
    var best = std.math.inf(f64);
    if (@min(ax, bx) - win > p.x1 or @max(ax, bx) + win < p.x0) return best;
    if (@min(ay, by) - win > p.y1 or @max(ay, by) + win < p.y0) return best;
    const samples = 8;
    var i: usize = 0;
    while (i <= samples) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / samples;
        const px = ax + (bx - ax) * t;
        const py = ay + (by - ay) * t;
        const d = pad_shape.pointDist(p.x0, p.y0, p.x1, p.y1, p.poly, px, py, best);
        if (d < best) best = d;
    }
    return best;
}

// ── Union-find over copper nodes (pads | tracks | vias) ─────────────────────

fn find(parent: []usize, i: usize) usize {
    var r = i;
    while (parent[r] != r) r = parent[r];
    // Path-halving.
    var x = i;
    while (parent[x] != r) {
        const next = parent[x];
        parent[x] = r;
        x = next;
    }
    return r;
}

fn unite(parent: []usize, a: usize, b: usize) void {
    const ra = find(parent, a);
    const rb = find(parent, b);
    if (ra != rb) parent[rb] = ra;
}

// ── Net / plane / geometry helpers ──────────────────────────────────────────

/// ref-des → part index (linear; net fan-out is small).
fn partIndex(placement: optimizer.Placement, ref: []const u8) ?usize {
    for (placement.parts, 0..) |p, i| {
        if (std.mem.eql(u8, p.ref_des, ref)) return i;
    }
    return null;
}

fn appendUnresolvablePins(
    arena: std.mem.Allocator,
    errors: *std.ArrayList(Item),
    placement: optimizer.Placement,
) std.mem.Allocator.Error!void {
    for (placement.nets) |net| {
        for (net.pins) |pin| {
            const part_i = partIndex(placement, pin.ref_des) orelse {
                try errors.append(arena, .{
                    .id = "unresolvable-pin",
                    .message = try std.fmt.allocPrint(arena, "net {s} references missing part {s}.{s}", .{ net.name, pin.ref_des, pin.pin }),
                    .net = net.name,
                    .ref = pin.ref_des,
                });
                continue;
            };
            if (padOf(placement.parts[part_i], pin.pin) == null) try errors.append(arena, .{
                .id = "unresolvable-pin",
                .message = try std.fmt.allocPrint(arena, "net {s} references missing pad {s}.{s}", .{ net.name, pin.ref_des, pin.pin }),
                .net = net.name,
                .ref = pin.ref_des,
            });
        }
    }
}

/// The pad on `part` with number `num`, or null.
fn padOf(part: optimizer.Part, num: []const u8) ?@import("placement/geometry.zig").Pad {
    for (part.pads) |pad| {
        if (std.mem.eql(u8, pad.number, num)) return pad;
    }
    return null;
}

/// Does a copper plane carry `name`? THE router's own predicate, re-exported
/// rather than restated: this file used to carry a second, character-for-
/// character equivalent body, so the gate and the router could drift into
/// disagreeing about which pads a pour reaches — a board where the router
/// assumes a plane the fab check does not is exactly the class of bug the
/// single definition rules out. See `plane_stitch.netHasPlane` for the rule
/// (no `(stackup …)` form ⇒ `implicit_plane.carries`; a declared stackup ⇒
/// exactly its `(plane …)` nets, case-insensitive on the full or leaf name).
pub const netHasPlane = plane_stitch.netHasPlane;

/// Signed distance from (x,y) to the nearest rectangle edge — positive inside.
fn edgeInset(br: optimizer.BoardRect, x: f64, y: f64) f64 {
    const dl = x - br.minx;
    const dr = br.minx + br.w - x;
    const dt = y - br.miny;
    const db = br.miny + br.h - y;
    return @min(@min(dl, dr), @min(dt, db));
}

/// Signed inset of (x,y) from the board outline — the exact polygon when the
/// board is non-rectangular (the same signedInset pcb_describe and the
/// board-edge DRC use), else the bounding rectangle. Positive = inside.
fn boardInset(br: optimizer.BoardRect, poly: ?[]const [2]f64, x: f64, y: f64) f64 {
    if (poly) |p| {
        if (p.len >= 3) return outline_mod.signedInset(p, x, y);
    }
    return edgeInset(br, x, y);
}

/// A compact "3× via_pad, 1× track_track" style summary of the DRC kinds, for
/// the error line (the full list lives behind the Route/DRC view).
fn drcSummary(arena: std.mem.Allocator, violations: []const drc.Violation) []const u8 {
    var counts = std.enums.EnumArray(drc.Kind, usize).initFill(0);
    for (violations) |v| counts.set(v.kind, counts.get(v.kind) + 1);
    var out: std.Io.Writer.Allocating = .init(arena);
    var first = true;
    inline for (@typeInfo(drc.Kind).@"enum".field_names, @typeInfo(drc.Kind).@"enum".field_values) |fname, fval| {
        const k: drc.Kind = @fromBackingInt(@intCast(fval));
        const c = counts.get(k);
        if (c > 0) {
            if (!first) out.writer.writeAll(", ") catch return "DRC";
            first = false;
            out.writer.print("{d}× {s}", .{ c, fname }) catch return "DRC";
        }
    }
    return out.written();
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("placement/geometry.zig");
const export_kicad = @import("export_kicad.zig");

// spec: fab_readiness - pad-to-track connectivity requires a full cross-section of the narrower copper feature; a capsule-only edge or corner graze stays open
test "pad connectivity rejects a corner graze and accepts a full-width entry" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // The (pads × tracks) sweep rejects a pair whose boxes stay more than the
    // touch reach apart. A DIAGONAL graze is where that box test is loosest —
    // the track reaches the pad only at a corner — so it is the case that would
    // break first if the reject were too tight. C1's pad spans (9.7..10.3), and
    // the track's end sits just off its lower-left corner.
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 12,
        .maxy = 2,
        .generated = false,
        .board_rect = .{ .minx = -2, .miny = -2, .w = 16, .h = 6 },
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };

    // Ends on the pad's lower-left corner diagonally. The round cap touches,
    // but no full-width chord lies on the land, so the net stays open.
    const graze = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 9.7, .y2 = -0.3, .layer = 0, .width = 0.2, .net = 0 }};
    try testing.expect(hasError(try check(arena, placement, .{ .tracks = &graze }, .{}), "unrouted-net"));

    // Reaching through the land centre gives the trace its complete 0.2 mm
    // transverse cross-section and closes the net.
    const entered = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    try testing.expect(!hasError(try check(arena, placement, .{ .tracks = &entered }, .{}), "unrouted-net"));

    // Stopping 2 mm short leaves the pad its own island — the window rejects
    // the pair, and the answer is the same one the exact test gave.
    const short = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 8, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    try testing.expect(hasError(try check(arena, placement, .{ .tracks = &short }, .{}), "unrouted-net"));
}

// spec: fab_readiness - a routed net is connected; an unrouted multi-pad net is flagged
test "connectivity flags an unrouted net and passes a routed one" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // U1.1 at (0,0) and C1.1 at (10,0), both on net SIG, at two board
    // locations 10 mm apart.
    const u_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const c_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &u_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &c_pads, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 12,
        .maxy = 2,
        .generated = false,
        .board_rect = .{ .minx = -2, .miny = -2, .w = 16, .h = 6 },
        // (stackup 2): no plane, so SIG must be routed as real copper.
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };

    // No copper: the net is unrouted (an airwire remains).
    const bare = try check(arena, placement, .{}, .{});
    try testing.expect(!bare.ok());
    try testing.expect(hasError(bare, "unrouted-net"));
    try testing.expectEqual(@as(usize, 1), bare.stats.routable_nets);
    try testing.expectEqual(@as(usize, 0), bare.stats.connected_nets);

    // A track spanning both pads connects them → no unrouted-net error.
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const routed = try check(arena, placement, .{ .tracks = &tracks }, .{});
    try testing.expect(!hasError(routed, "unrouted-net"));
    try testing.expectEqual(@as(usize, 1), routed.stats.connected_nets);

    // An RF path may persist only its compact sampled proof. Connectivity must
    // lower that proof to its private physical chords rather than seeing an
    // empty track list and reporting a false airwire.
    const rf_samples = [_]@import("placement/rf_path_solver.zig").Sample{
        .{ .at = .{ 0, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 0.2 },
        .{ .at = .{ 5, 1 }, .s_mm = 5.1, .curvature = 0, .width_mm = 0.3 },
        .{ .at = .{ 10, 0 }, .s_mm = 10.2, .curvature = 0, .width_mm = 0.2 },
    };
    const rf_paths = [_]@import("placement/rf_port_report.zig").Outcome{.{
        .net = 0,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = rf_samples.len, .samples = &rf_samples, .layer = 0 },
    }};
    const sampled = try netConnectivity(arena, placement, .{ .rf_paths = &rf_paths });
    try testing.expectEqual(@as(usize, 1), sampled.len);
    try testing.expect(sampled[0].connected);

    // A real maze route is a CHAIN of segments (only the end segments touch
    // the pads) — the union must propagate through the track↔track joints.
    const chain = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 3, .y1 = 0, .x2 = 3, .y2 = 1.5, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 3, .y1 = 1.5, .x2 = 10, .y2 = 1.5, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 10, .y1 = 1.5, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const chained = try check(arena, placement, .{ .tracks = &chain }, .{});
    try testing.expect(!hasError(chained, "unrouted-net"));
    try testing.expectEqual(@as(usize, 1), chained.stats.connected_nets);

    // …and through a via layer-jump: top stub → via → bottom run → via → top stub.
    const jump = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 8, .y2 = 0, .layer = 1, .width = 0.2, .net = 0 },
        .{ .x1 = 8, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const jvias = [_]router.Via{
        .{ .x = 2, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 },
        .{ .x = 8, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 },
    };
    const jumped = try check(arena, placement, .{ .tracks = &jump, .vias = &jvias }, .{});
    try testing.expect(!hasError(jumped, "unrouted-net"));
    try testing.expectEqual(@as(usize, 1), jumped.stats.connected_nets);

    // Two same-layer segments that do NOT touch stay two islands (no false
    // transitivity from the chain logic).
    const gap = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 4, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 6, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const gapped = try check(arena, placement, .{ .tracks = &gap }, .{});
    try testing.expect(hasError(gapped, "unrouted-net"));
}

test "Barracuda DIV_RAW sampled taper connects both RF landing pads" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const cap_pads = [_]geometry.Pad{.{
        .number = "2",
        .x = 0.48,
        .y = 0,
        // Barracuda's controlled-impedance adaptation has already reduced the
        // nominal 0.56 x 0.62 mm C0402 land to its qualified RF minimum.
        .w = 0.46,
        .h = 0.50,
        .shape = "roundrect",
    }};
    const attenuator_pads = [_]geometry.Pad{.{
        .number = "2",
        .x = -1,
        .y = 0,
        .w = 0.8,
        .h = 0.3,
    }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "C184", .kind = .passive, .hw = 0.85, .hh = 0.35, .pads = &cap_pads, .fallback = false, .x = 149.7, .y = 104.5, .rot = 90 },
        .{ .ref_des = "A1", .kind = .passive, .hw = 1.45, .hh = 0.85, .pads = &attenuator_pads, .fallback = false, .x = 147.4, .y = 105.5, .rot = 180 },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "C184", .pin = "2" }, .{ .ref_des = "A1", .pin = "2" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "vco_div4/DIV_RAW", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 145,
        .miny = 103,
        .maxx = 151,
        .maxy = 107,
        .generated = false,
        .board_rect = .{ .minx = 145, .miny = 103, .w = 6, .h = 4 },
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };
    const Sample = @import("placement/rf_path_solver.zig").Sample;
    const main_samples = [_]Sample{
        .{
            .at = .{ 149.7, 104.98 },
            .s_mm = 0,
            .curvature = 0,
            .width_mm = 0.6013448869340359,
        },
        .{
            .at = .{ 149.7, 105 },
            .s_mm = 0.02,
            .curvature = 0,
            .width_mm = 0.6013448869340359,
        },
        .{
            .at = .{ 149.2, 105.5 },
            .s_mm = 0.73,
            .curvature = 0,
            .width_mm = 0.18993671363271875,
        },
        .{ .at = .{ 148.8, 105.5 }, .s_mm = 1.13, .curvature = 0, .width_mm = 0.3 },
        .{ .at = .{ 148.4, 105.5 }, .s_mm = 1.53, .curvature = 0, .width_mm = 0.3 },
    };
    const Outcome = @import("placement/rf_port_report.zig").Outcome;
    const paths = [_]Outcome{.{
        .net = 0,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{
            .sample_count = main_samples.len,
            .samples = &main_samples,
            .layer = 0,
        },
    }};

    const conn = try netConnectivity(arena, placement, .{ .rf_paths = &paths });
    try testing.expectEqual(@as(usize, 1), conn.len);
    try testing.expect(conn[0].connected);
}

// spec: fab_readiness - An SMD pad joins routed copper only on its authored outer face; a through-hole pad joins every copper layer
test "a bottom trace passing under top SMD pads does not connect them" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 12,
        .maxy = 2,
        .generated = false,
        .board_rect = .{ .minx = -2, .miny = -2, .w = 16, .h = 6 },
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };
    const bottom = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 1, .width = 0.2, .net = 0 }};
    const top = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    try testing.expect(hasError(try check(arena, placement, .{ .tracks = &bottom }, .{}), "unrouted-net"));
    try testing.expect(!hasError(try check(arena, placement, .{ .tracks = &top }, .{}), "unrouted-net"));
}

// spec: fab_readiness - A flattened net pin whose part or pad no longer resolves is a fab-readiness error, never a silently dropped terminal
test "a renamed footprint pad is surfaced as an unresolvable pin" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{.{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 0 }};
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "U1", .pin = "9" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 2,
        .maxy = 2,
        .generated = false,
        .board_rect = .{ .minx = -2, .miny = -2, .w = 4, .h = 4 },
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };
    try testing.expect(hasError(try check(arena, placement, .{}, .{}), "unresolvable-pin"));
}

// spec: fab_readiness - connectivity propagates across an inner-signal-layer chain through its vias
test "an inner-layer route chain counts as connected" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const u_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const c_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &u_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &c_pads, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "SIG", .pins = &pins }};
    // (stackup 4 (plane 2 "GND")): SIG must be real copper; the run crosses on
    // the inner signal layer (index 2), reached through two vias.
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 12,
        .maxy = 2,
        .generated = false,
        .board_rect = .{ .minx = -2, .miny = -2, .w = 16, .h = 6 },
        .rules = .{ .plane_nets = &gnd_names, .copper_layers = 4, .planes = .{ .declared = &planes } },
    };

    // Top stub → via → INNER (l=2) run → via → top stub: one connected group.
    const chain = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 8, .y2 = 0, .layer = 2, .width = 0.2, .net = 0 },
        .{ .x1 = 8, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const cvias = [_]router.Via{
        .{ .x = 2, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 },
        .{ .x = 8, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 },
    };
    const linked = try check(arena, placement, .{ .tracks = &chain, .vias = &cvias }, .{});
    try testing.expect(!hasError(linked, "unrouted-net"));
    try testing.expectEqual(@as(usize, 1), linked.stats.connected_nets);

    // The same chain WITHOUT the vias must stay three islands — the inner run
    // never touches the top stubs on its own layer.
    const cut = try check(arena, placement, .{ .tracks = &chain }, .{});
    try testing.expect(hasError(cut, "unrouted-net"));
}

// spec: fab_readiness - a ground plane connects its pads without routed copper
test "a plane-carried net counts as connected" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const u_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.3 }};
    const c_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.3 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &u_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &c_pads, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "GND", .pins = &pins }};
    // No (stackup …) form → implicit planes → ground is plane-carried.
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 12,
        .maxy = 2,
        .generated = false,
        .board_rect = .{ .minx = -2, .miny = -2, .w = 16, .h = 6 },
    };
    const r = try check(arena, placement, .{}, .{});
    try testing.expect(!hasError(r, "unrouted-net"));
    try testing.expectEqual(@as(usize, 1), r.stats.connected_nets);
}

// spec: fab_readiness - a surface pad isolated from the plane is flagged until a plane via bridges it
test "a plane via bridges a surface pad to the ground plane" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // Two GND SURFACE-MOUNT pads (no barrel) over the implicit inner ground
    // plane. With no via they do not reach the inner plane — honestly isolated
    // (the old short-circuit believed them connected). The router's plane-via
    // pass drops a via on each pad; those vias land in the plane and bridge the
    // pads to it, so a routed board is one connected group again.
    const u_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const c_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &u_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &c_pads, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "GND", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 12,
        .maxy = 2,
        .generated = false,
        .board_rect = .{ .minx = -2, .miny = -2, .w = 16, .h = 6 },
    };

    // Unrouted: the surface pads cannot reach the inner plane → an airwire.
    const bare = try check(arena, placement, .{}, .{});
    try testing.expect(hasError(bare, "unrouted-net"));

    // A GND plane via on each pad bridges it to the plane → one group.
    const vias = [_]router.Via{
        .{ .x = 0, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 },
        .{ .x = 10, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 },
    };
    const wired = try check(arena, placement, .{ .vias = &vias }, .{});
    try testing.expect(!hasError(wired, "unrouted-net"));
    try testing.expectEqual(@as(usize, 1), wired.stats.connected_nets);
}

test "a plane via on a concave custom pad uses the authored copper outline" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // Barracuda's TPSM84338 GND pad in miniature: an L-shaped land whose
    // bounding-box centre is empty. The via sits on the horizontal arm, not at
    // that empty centre, and must join the SMD land to the implicit GND plane.
    const l_poly = [_][2]f64{
        .{ -0.375, -1.600 }, .{ -0.375, -0.811 }, .{ -0.550, -0.615 }, .{ -0.586, -0.601 },
        .{ -1.800, -0.601 }, .{ -1.850, -0.550 }, .{ -1.850, -0.376 }, .{ -1.800, -0.326 },
        .{ -0.175, -0.326 }, .{ -0.125, -0.376 }, .{ -0.125, -1.600 }, .{ -0.175, -1.650 },
        .{ -0.325, -1.650 }, .{ -0.375, -1.600 },
    };
    const custom = [_]geometry.Pad{.{
        .number = "1",
        .x = -0.988,
        .y = -0.988,
        .w = 1.725,
        .h = 1.324,
        .shape = "custom",
        .poly = &l_poly,
    }};
    const ordinary = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &custom, .fallback = false, .x = 203.2, .y = 95, .rot = 270 },
        .{ .ref_des = "TP1", .kind = .passive, .hw = 1, .hh = 1, .pads = &ordinary, .fallback = false, .x = 190, .y = 95 },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "TP1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "GND", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 185,
        .miny = 90,
        .maxx = 208,
        .maxy = 100,
        .generated = false,
        .board_rect = .{ .minx = 185, .miny = 90, .w = 23, .h = 10 },
    };
    const vias = [_]router.Via{
        .{ .x = 202.7, .y = 95.52447405648955, .dia = 0.4, .drill = 0.2, .net = 0 },
        .{ .x = 190, .y = 95, .dia = 0.4, .drill = 0.2, .net = 0 },
    };

    const wired = try check(arena, placement, .{ .vias = &vias }, .{});
    try testing.expect(!hasError(wired, "unrouted-net"));
    try testing.expectEqual(@as(usize, 1), wired.stats.connected_nets);
}

// spec: fab_readiness - a rail net joined only by an inner-layer copper pour passes the unrouted-net gate
test "an inner-layer copper pour connects a rail's through-hole pads" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // The barracuda case: a V_3V3A rail with two THROUGH-HOLE pads in different
    // board locations. With no copper the net is an airwire; a hand-drawn inner
    // pour (In2.Cu = signal index 2) enclosing both pads unites them — the real
    // inner copper the fab gate must credit as connecting the rail.
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.9, .h = 0.9, .thru = true, .drill = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pad, .fallback = false, .x = 2, .y = 5 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &pad, .fallback = false, .x = 18, .y = 5 },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "V_3V3A", .pins = &pins }};
    var placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 20,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 20, .h = 10 },
    };
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    placement.rules = .{ .plane_nets = &gnd_names, .copper_layers = 4, .planes = .{ .declared = &planes } };

    // No copper: the rail's two through-hole pads are an airwire.
    const bare = try check(arena, placement, .{}, .{});
    try testing.expect(hasError(bare, "unrouted-net"));

    // An inner-layer pour on In2.Cu (signal index 2) enclosing both THT pads.
    const poly = [_][2]f64{ .{ 0, 3 }, .{ 20, 3 }, .{ 20, 7 }, .{ 0, 7 } };
    const zones = [_]pour.UserZone{.{ .net = "V_3V3A", .layer = 2, .poly = &poly }};
    const poured = try check(arena, placement, .{ .zones = &zones }, .{});
    try testing.expect(!hasError(poured, "unrouted-net"));
    try testing.expectEqual(@as(usize, 1), poured.stats.connected_nets);
}

// spec: fab_readiness - a pad inside a higher-priority overlapping pour drops out of the lower pour's connectivity
test "priority-clipped pad falls out of the lower pour's net" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // Net VA's two THT pads are joined ONLY by an inner VA pour. A VB pour of a
    // different net overlaps the right pad. When VB outranks VA, VA's copper
    // recedes there, so the right pad drops out of VA and the rail is an airwire
    // again — the connectivity check now reflects the priority gap.
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.9, .h = 0.9, .thru = true, .drill = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pad, .fallback = false, .x = 3, .y = 5 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &pad, .fallback = false, .x = 17, .y = 5 },
    };
    const va_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "VA", .pins = &va_pins }};
    var placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 20,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 20, .h = 10 },
    };
    placement.rules = .{ .copper_layers = 4 };

    const va_poly = [_][2]f64{ .{ 0, 3 }, .{ 20, 3 }, .{ 20, 7 }, .{ 0, 7 } };
    const vb_poly = [_][2]f64{ .{ 14, 3 }, .{ 20, 3 }, .{ 20, 7 }, .{ 14, 7 } }; // over C1

    // Equal priority: VB does not clip VA, so the VA pour unites both pads.
    const eq = [_]pour.UserZone{
        .{ .net = "VA", .layer = 2, .poly = &va_poly, .priority = 0 },
        .{ .net = "VB", .layer = 2, .poly = &vb_poly, .priority = 0 },
    };
    try testing.expect(!hasError(try check(arena, placement, .{ .zones = &eq }, .{}), "unrouted-net"));

    // VB ranked above VA: C1 sits in VB's region, so VA's copper receded there —
    // C1 drops out of VA and the rail reads as an airwire.
    const ranked = [_]pour.UserZone{
        .{ .net = "VA", .layer = 2, .poly = &va_poly, .priority = 0 },
        .{ .net = "VB", .layer = 2, .poly = &vb_poly, .priority = 1 },
    };
    try testing.expect(hasError(try check(arena, placement, .{ .zones = &ranked }, .{}), "unrouted-net"));
}

// spec: fab_readiness - a missing outline, off-board part, drill-less via, and DNP all surface
test "outline, off-board, drill-less via, and DNP findings" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // U1 on the board, U2 stranded 50 mm off to the side.
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 5, .y = 5 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 60, .y = 5 },
    };
    const insts = [_]export_kicad.FlatInstance{
        .{ .ref_des = "U1", .component = "u", .value = "V", .footprint = "F", .uuid = "", .properties = &.{} },
        .{ .ref_des = "U2", .component = "u", .value = "V", .footprint = "F", .uuid = "", .properties = &.{}, .dnp = true },
    };

    // First: no board_rect at all → the no-outline error (and no off-board
    // check, which needs an outline).
    var placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &insts,
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = false,
    };
    const vias = [_]router.Via{.{ .x = 5, .y = 5, .dia = 0.4, .drill = 0, .net = 0 }};
    // keep_dnp mode: the DNP part is listed in the centroid, so the warning fires.
    const no_outline = try check(arena, placement, .{ .vias = &vias }, .{ .from_saved_layout = false, .keep_dnp = true });
    try testing.expect(hasError(no_outline, "no-outline"));
    try testing.expect(hasError(no_outline, "via-no-drill"));
    try testing.expect(hasWarning(no_outline, "dnp-in-centroid"));
    try testing.expect(hasWarning(no_outline, "cache-layout"));

    // Default (drop DNP): the same DNP part no longer warrants the warning.
    const drop_dnp = try check(arena, placement, .{ .vias = &vias }, .{ .from_saved_layout = false });
    try testing.expect(!hasWarning(drop_dnp, "dnp-in-centroid"));

    // Now give it an outline: U2 (at x=60) is >10 mm outside the 10×10 board.
    placement.board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 };
    const with_outline = try check(arena, placement, .{ .vias = &vias }, .{});
    try testing.expect(!hasError(with_outline, "no-outline"));
    try testing.expect(hasError(with_outline, "part-off-board"));
}

// spec: fab_readiness - a part in a concave notch is flagged off-board by the polygon inset, not just the bbox rect
test "off-board check is polygon-aware for a notch part" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // 40×40 board with a 20×20 notch removed at the top-right (y grows down).
    const notch_poly = [_][2]f64{
        .{ 0, 0 }, .{ 40, 0 }, .{ 40, 20 }, .{ 20, 20 }, .{ 20, 40 }, .{ 0, 40 },
    };
    // U1 in the main body; U2 sits deep in the removed notch — inside the 40×40
    // bounding rectangle, but > 10 mm outside the true polygon boundary.
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 10, .y = 10 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 32, .y = 32 },
    };
    var placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 40,
        .maxy = 40,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 40, .h = 40 },
        .board_poly = &notch_poly,
    };

    // Polygon-aware: the notch part is flagged off-board.
    const with_poly = try check(arena, placement, .{}, .{});
    try testing.expect(hasError(with_poly, "part-off-board"));

    // Rect-only (no polygon): the same part sits inside the bounding rectangle,
    // so it is NOT flagged — proving the polygon inset is what catches it.
    placement.board_poly = null;
    const rect_only = try check(arena, placement, .{}, .{});
    try testing.expect(!hasError(rect_only, "part-off-board"));
}

// spec: fab_readiness - a clean board produces no errors and reports ok
test "a clean routed board is export-ready" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const u_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const c_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &u_pads, .fallback = false, .x = 3, .y = 3 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &c_pads, .fallback = false, .x = 7, .y = 3 },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 6,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 6 },
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };
    const tracks = [_]router.Track{.{ .x1 = 3, .y1 = 3, .x2 = 7, .y2 = 3, .layer = 0, .width = 0.2, .net = 0 }};
    const vias = [_]router.Via{.{ .x = 5, .y = 3, .dia = 0.4, .drill = 0.2, .net = 0 }};
    const r = try check(arena, placement, .{ .tracks = &tracks, .vias = &vias }, .{});
    try testing.expect(r.ok());
    try testing.expectEqual(@as(usize, 0), r.errors.len);

    // The JSON round-trips (has "ok":true and the stats block).
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeJson(&aw.writer, r);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"ok\":true") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"routable_nets\":1") != null);
}

// spec: fab_readiness - the fab gate's DRC measures against the design's resolved clearance rule
test "fab gate DRC uses the design's clearance, not a hardcoded default" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // Two single-pad parts on different nets, 0.2 mm edge-to-edge apart (pad
    // half-width 0.3; centres 0.8 apart ⇒ 0.8 − 0.3 − 0.3 = 0.2). Each net has one
    // pad (no airwire) and there's no routed copper, and the courtyards are kept
    // small (hw 0.35 < half the 0.8 pitch) so they don't overlap — so the ONLY
    // thing that can flag is the pad↔pad clearance. At the 0.127 mm default the
    // board is clean; a (design-rules (clearance 0.3)) — resolved onto
    // placement.rules.design — must make the gate's DRC flag it, proving the gate
    // reads the authored rule.
    const u_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const c_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.35, .hh = 0.35, .pads = &u_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.35, .hh = 0.35, .pads = &c_pads, .fallback = false, .x = 0.8, .y = 0 },
    };
    const ap = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const bp = [_]export_kicad.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const nets = [_]export_kicad.FlatNet{ .{ .name = "A", .pins = &ap }, .{ .name = "B", .pins = &bp } };
    const base = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 4,
        .maxy = 4,
        .generated = false,
        .board_rect = .{ .minx = -2, .miny = -2, .w = 6, .h = 6 },
    };
    const empty = export_gerber.Copper{};

    // Default clearance ⇒ the 0.2 mm pad gap is legal; no DRC error.
    const r0 = try check(arena, base, empty, .{});
    try testing.expect(!hasError(r0, "drc"));

    // A 0.3 mm design clearance ⇒ the same gap flags; the gate reports a DRC error.
    var strict = base;
    strict.rules = .{ .design = .{ .clearance = 0.3 } };
    const r1 = try check(arena, strict, empty, .{});
    try testing.expect(hasError(r1, "drc"));
}

// spec: fab_readiness - solver-proven RF pad tapers retain their route metadata and do not become false track-width errors at the export gate
test "fab gate preserves RF path proof when checking Gerber copper" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const land = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.1 }};
    var parts = [_]optimizer.Part{.{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &land, .fallback = false, .x = 3, .y = 3 }};
    const pins = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]export_kicad.FlatNet{.{ .name = "RF", .pins = &pins }};
    const net_rules = [_]optimizer.NetRule{.{ .width = 0.2 }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 6,
        .generated = true,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 6 },
        .rules = .{ .net = &net_rules },
    };
    const tracks = [_]router.Track{.{ .x1 = 3, .y1 = 3, .x2 = 3.15, .y2 = 3, .layer = 0, .width = 0.15, .net = 0 }};
    const samples = [_]@import("placement/rf_path_solver.zig").Sample{
        .{ .at = .{ 3, 3 }, .s_mm = 0, .curvature = 0, .width_mm = 0.1 },
        .{ .at = .{ 3.15, 3 }, .s_mm = 0.15, .curvature = 0, .width_mm = 0.2 },
    };
    const outcomes = [_]@import("placement/rf_port_report.zig").Outcome{.{
        .net = 0,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = 2, .samples = &samples },
    }};

    const report = try check(arena, placement, .{ .tracks = &tracks, .rf_paths = &outcomes }, .{});
    try testing.expect(!hasError(report, "drc"));
}

// spec: fab_readiness - a warning-severity DRC finding flows through as a gate warning; an error-severity one blocks
test "the gate blocks on error-severity DRC but not on warnings" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // Two pad-less hubs whose 2×2 courtyards overlap (a warning-only finding)
    // on an otherwise clean, outlined board.
    var warn_parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 3, .y = 3 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 3.5, .y = 3 },
    };
    const warn_pl = optimizer.Placement{
        .parts = &warn_parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 6,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 6 },
    };
    const wr = try check(arena, warn_pl, .{}, .{});
    try testing.expect(wr.ok()); // a courtyard overlap alone never 409s
    try testing.expect(!hasError(wr, "drc"));
    try testing.expect(hasWarning(wr, "drc-warn"));

    // Two hubs with pads on DIFFERENT nets sitting on top of each other — a
    // pad↔pad copper clash (error severity) — must block.
    const a_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const b_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var err_parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &a_pad, .fallback = false, .x = 3, .y = 3 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = &b_pad, .fallback = false, .x = 3.2, .y = 3 },
    };
    const a_pin = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const b_pin = [_]export_kicad.FlatPin{.{ .ref_des = "U2", .pin = "1" }};
    const enets = [_]export_kicad.FlatNet{ .{ .name = "A", .pins = &a_pin }, .{ .name = "B", .pins = &b_pin } };
    const err_pl = optimizer.Placement{
        .parts = &err_parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &enets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 6,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 6 },
    };
    const er = try check(arena, err_pl, .{}, .{});
    try testing.expect(!er.ok()); // the pad clash blocks the download
    try testing.expect(hasError(er, "drc"));
}

// spec: fab_readiness - a custom outline polygon with fewer than 3 points warns that the profile fell back to a rect
test "a malformed custom outline surfaces a warning" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 5, .y = 3 },
    };
    // A board_poly with only 2 points is degenerate — the writers fall back to
    // the bbox rect, so warn.
    const bad_poly = [_][2]f64{ .{ 0, 0 }, .{ 10, 6 } };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 6,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 6 },
        .board_poly = &bad_poly,
    };
    const r = try check(arena, placement, .{}, .{});
    try testing.expect(hasWarning(r, "malformed-outline"));
    // A well-formed (≥ 3 point) polygon does not warn.
    var good = placement;
    const good_poly = [_][2]f64{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 6 }, .{ 0, 6 } };
    good.board_poly = &good_poly;
    try testing.expect(!hasWarning(try check(arena, good, .{}, .{}), "malformed-outline"));
}

// spec: Web Server - routableTally summarises copper connectivity into routed/total/open counts, excluding nets that need no copper
test "routableTally counts connected nets and names the open ones, skipping non-routable nets" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // Three nets on a plane-free 2-layer board: DONE (2 pads, wired), OPEN
    // (2 pads, bare), and SOLO (a single pad, so it needs no copper at all).
    const p1 = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const p2 = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const p3 = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const p4 = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const p5 = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &p1, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &p2, .fallback = false, .x = 10, .y = 0 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = &p3, .fallback = false, .x = 0, .y = 5 },
        .{ .ref_des = "C2", .kind = .passive, .hw = 1, .hh = 1, .pads = &p4, .fallback = false, .x = 10, .y = 5 },
        .{ .ref_des = "TP1", .kind = .passive, .hw = 1, .hh = 1, .pads = &p5, .fallback = false, .x = 5, .y = 9 },
    };
    const done_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const open_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U2", .pin = "1" }, .{ .ref_des = "C2", .pin = "1" } };
    const solo_pins = [_]export_kicad.FlatPin{.{ .ref_des = "TP1", .pin = "1" }};
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "DONE", .pins = &done_pins },
        .{ .name = "OPEN", .pins = &open_pins },
        .{ .name = "SOLO", .pins = &solo_pins },
    };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 12,
        .maxy = 11,
        .generated = false,
        .board_rect = .{ .minx = -2, .miny = -2, .w = 16, .h = 15 },
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };

    // Only DONE (net index 0) gets copper.
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const t = try routableTally(arena, placement, .{ .tracks = &tracks });

    // SOLO is excluded from BOTH numerator and denominator — a single-pad net
    // needs no copper, so counting it would understate a finished board.
    try testing.expectEqual(@as(usize, 2), t.total);
    try testing.expectEqual(@as(usize, 1), t.routed);
    try testing.expectEqual(@as(usize, 2), t.unique_total);
    try testing.expectEqual(@as(usize, 1), t.unique_routed);
    try testing.expectEqual(@as(usize, 1), t.open.len);
    try testing.expectEqualStrings("OPEN", t.open[0]);

    // With no copper at all, nothing is routed and BOTH multi-pad nets are named
    // — never a silent 0/0 with an empty open list.
    const bare = try routableTally(arena, placement, .{});
    try testing.expectEqual(@as(usize, 2), bare.total);
    try testing.expectEqual(@as(usize, 0), bare.routed);
    try testing.expectEqual(@as(usize, 2), bare.unique_total);
    try testing.expectEqual(@as(usize, 0), bare.unique_routed);
    try testing.expectEqual(@as(usize, 2), bare.open.len);
}

// spec: placement/progress - netConnectivity credits parent-rail copper to structurally proven generated per-pin bypass connections
test "parent rail copper closes its generated bypass connection net" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const hub_pads = [_]geometry.Pad{.{ .number = "5", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const cap_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "core/U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &hub_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "core/C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &cap_pads, .fallback = false, .x = 4, .y = 0 },
    };
    const stub_pins = [_]export_kicad.FlatPin{
        .{ .ref_des = "core/U1", .pin = "5" },
        .{ .ref_des = "core/C1", .pin = "1" },
    };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "core/VDD", .pins = &.{} },
        .{ .name = "core/VDD.U1.5", .pins = &stub_pins },
    };
    const loops = [_]optimizer.Loop{.{
        .cap = 1,
        .hub = 0,
        .cap_pwr = .{ .x = 0, .y = 0, .w = 0.6, .h = 0.6 },
        .cap_gnd = .{ .x = 0, .y = 0, .w = 0.6, .h = 0.6 },
        .hub_pwr = &.{},
        .hub_pwr_pin = .{ .x = 0, .y = 0, .w = 0.6, .h = 0.6 },
        .hub_gnd = &.{},
        .pwr_net = 1,
        .explicit_pin = "5",
    }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &loops,
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 5,
        .maxy = 1,
        .generated = false,
        .board_rect = .{ .minx = -1, .miny = -1, .w = 6, .h = 2 },
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };
    const tracks = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 4, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    const status = try netConnectivity(arena, placement, .{ .tracks = &tracks });
    try testing.expect(status[1].routable);
    try testing.expect(status[1].connected);
    try testing.expectEqual(@as(usize, 1), status[1].islands);
}

// Regression guard for both halves of the detailed/logical tally contract.
test "routing tally reports unique logical nets without hiding connection detail" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const conn = [_]NetStatus{
        .{ .name = "CLK", .routable = true, .connected = true, .islands = 1 },
        .{ .name = "VDD.U1.7", .routable = true, .connected = true, .islands = 1 },
        .{ .name = "VDD.U2.8", .routable = true, .connected = false, .islands = 2 },
        .{ .name = "VDD", .routable = false, .connected = false, .islands = 1 },
        .{ .name = "SOLO", .routable = false, .connected = false, .islands = 1 },
    };
    const tally = try summarizeConnectivity(arena_i.allocator(), &conn);

    // Repair/DRC surfaces retain all three required connections and the exact
    // open micro-net. The UI sees only CLK and VDD, with VDD still incomplete.
    try testing.expectEqual(@as(usize, 3), tally.total);
    try testing.expectEqual(@as(usize, 2), tally.routed);
    try testing.expectEqual(@as(usize, 1), tally.open.len);
    try testing.expectEqualStrings("VDD.U2.8", tally.open[0]);
    try testing.expectEqual(@as(usize, 2), tally.unique_total);
    try testing.expectEqual(@as(usize, 1), tally.unique_routed);
}

/// Two 2-pad nets (WIRED, OPEN) plus a single-pad SOLO on a plane-free 2-layer
/// board — the fixture the tally / open-net scenarios build copper on.
fn tallyFixture(parts: []optimizer.Part, nets: []const export_kicad.FlatNet) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 12,
        .maxy = 11,
        .generated = false,
        .board_rect = .{ .minx = -2, .miny = -2, .w = 16, .h = 15 },
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };
}

// spec: Web Server - The fab-readiness gate reuses caller-supplied net connectivity instead of recomputing it
test "check reuses ctx.conn and reports the same airwires as computing it itself" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = tallyFixture(&parts, &nets);

    // Bare board: one routable net, nothing connecting it.
    const own = try check(arena, placement, .{}, .{});
    const conn = try netConnectivity(arena, placement, .{});
    const reused = try check(arena, placement, .{}, .{ .conn = conn });

    try testing.expectEqual(own.stats.routable_nets, reused.stats.routable_nets);
    try testing.expectEqual(own.stats.connected_nets, reused.stats.connected_nets);
    try testing.expectEqual(own.errors.len, reused.errors.len);
    try testing.expectEqual(own.warnings.len, reused.warnings.len);
    try testing.expectEqual(@as(usize, 1), reused.stats.routable_nets);
    try testing.expectEqual(@as(usize, 0), reused.stats.connected_nets);
}

// spec: Web Server - openNets reports each unconnected net's pads with their coordinates and copper island
test "openNets names an open net's pads, their coordinates, and their islands" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = tallyFixture(&parts, &nets);

    // No copper: two pads, two islands, one hop between them.
    const open = try openNets(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), open.len);
    try testing.expectEqualStrings("SIG", open[0].net);
    try testing.expectEqual(@as(usize, 2), open[0].pads.len);
    try testing.expectEqualStrings("U1", open[0].pads[0].ref);
    try testing.expectEqualStrings("1", open[0].pads[0].pad);
    try testing.expectEqual(@as(f64, 0), open[0].pads[0].x);
    try testing.expectEqual(@as(f64, 10), open[0].pads[1].x);
    // Distinct pads, distinct islands — and exactly one closing hop, 10 mm long.
    try testing.expect(open[0].pads[0].island != open[0].pads[1].island);
    try testing.expectEqual(@as(usize, 1), open[0].gaps.len);
    try testing.expectApproxEqAbs(@as(f64, 10), open[0].gaps[0].mm, 1e-6);

    // Wire them and the net drops out of the report entirely.
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    try testing.expectEqual(@as(usize, 0), (try openNets(arena, placement, .{ .tracks = &tracks })).len);
}

// spec: Web Server - openNetsAmong builds open-net detail only for requested exact names while retaining placement order
test "openNetsAmong scopes open-net detail by exact name" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "A1", .kind = .passive, .hw = 1, .hh = 1, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "A2", .kind = .passive, .hw = 1, .hh = 1, .pads = &pad, .fallback = false, .x = 5, .y = 0 },
        .{ .ref_des = "B1", .kind = .passive, .hw = 1, .hh = 1, .pads = &pad, .fallback = false, .x = 0, .y = 5 },
        .{ .ref_des = "B2", .kind = .passive, .hw = 1, .hh = 1, .pads = &pad, .fallback = false, .x = 5, .y = 5 },
    };
    const a_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "A1", .pin = "1" }, .{ .ref_des = "A2", .pin = "1" } };
    const b_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "B1", .pin = "1" }, .{ .ref_des = "B2", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "A", .pins = &a_pins },
        .{ .name = "B", .pins = &b_pins },
    };
    const placement = tallyFixture(&parts, &nets);

    const requested = [_][]const u8{ "B", "B", "UNKNOWN" };
    const scoped = try openNetsAmong(arena, placement, .{}, &requested);
    try testing.expectEqual(@as(usize, 1), scoped.len);
    try testing.expectEqualStrings("B", scoped[0].net);

    const none = [_][]const u8{};
    try testing.expectEqual(@as(usize, 0), (try openNetsAmong(arena, placement, .{}, &none)).len);

    const all = try openNetsAmong(arena, placement, .{}, null);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqualStrings("A", all[0].net);
    try testing.expectEqualStrings("B", all[1].net);
}

// spec: Web Server - closingGaps chains the islands nearest-first, emitting one hop per island beyond the first
test "closingGaps emits islands-1 hops, nearest first" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // Three islands strung out along x: 0, 1 (near) and 9 (far). Chaining from
    // island 0 must take the 1 mm hop before the 8 mm one — an agent should be
    // handed the cheapest work first.
    const pads = [_]OpenPad{
        .{ .ref = "A", .pad = "1", .x = 0, .y = 0, .side = .top, .thru = false, .island = 0 },
        .{ .ref = "B", .pad = "1", .x = 1, .y = 0, .side = .top, .thru = false, .island = 1 },
        .{ .ref = "C", .pad = "1", .x = 9, .y = 0, .side = .top, .thru = false, .island = 2 },
    };
    const gaps = try closingGaps(arena, &pads, 3);
    try testing.expectEqual(@as(usize, 2), gaps.len);
    try testing.expectApproxEqAbs(@as(f64, 1), gaps[0].mm, 1e-9);
    try testing.expectEqualStrings("B", gaps[0].to.ref);
    try testing.expectApproxEqAbs(@as(f64, 8), gaps[1].mm, 1e-9);
    try testing.expectEqualStrings("C", gaps[1].to.ref);
    // A single island needs no hops at all.
    try testing.expectEqual(@as(usize, 0), (try closingGaps(arena, pads[0..1], 1)).len);
}

fn hasError(r: Report, id: []const u8) bool {
    for (r.errors) |e| if (std.mem.eql(u8, e.id, id)) return true;
    return false;
}
fn hasWarning(r: Report, id: []const u8) bool {
    for (r.warnings) |wn| if (std.mem.eql(u8, wn.id, id)) return true;
    return false;
}

// spec: Web Server - two same-net pads whose lands touch are one island, and opposite-face SMD pads are not
test "touching same-net pads join without a trace; opposite faces stay separate" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // barracuda's `adf4159/U20` pads 1 and 13 in miniature: one net, two lands
    // on the same face sharing an edge. No trace runs between them because none
    // is needed — they are one piece of copper — yet the graph joined pads only
    // through tracks/vias/pours, so the net read as an airwire on every surface.
    const abut = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.2 },
        .{ .number = "13", .x = 0.22, .y = 0.2, .w = 0.15, .h = 0.2 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &abut, .fallback = false, .x = 0, .y = 0, .side = .top },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "U1", .pin = "13" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "V_1V8A", .pins = &pins }};
    const placement = tallyFixture(&parts, &nets);

    const joined = try routableTally(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), joined.total); // two board locations ⇒ routable
    try testing.expectEqual(@as(usize, 1), joined.routed); // …and already connected

    // The same two lands on OPPOSITE faces overlap only in 2D — no shared
    // copper, so the net is genuinely open.
    var split = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = abut[0..1], .fallback = false, .x = 0, .y = 0, .side = .top },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = abut[1..2], .fallback = false, .x = 0, .y = 0, .side = .bottom },
    };
    const split_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "U2", .pin = "13" } };
    const split_nets = [_]export_kicad.FlatNet{.{ .name = "V_1V8A", .pins = &split_pins }};
    const open = try routableTally(arena, tallyFixture(&split, &split_nets), .{});
    try testing.expectEqual(@as(usize, 1), open.total);
    try testing.expectEqual(@as(usize, 0), open.routed);
}

test "repeated same-number plated subpads carry a custom SMD land to the opposite face" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // TPSM84338 VOUT in miniature: one logical pad 4 is authored as a broad
    // custom surface land plus embedded same-number plated barrels. The bottom
    // capacitor touches a barrel, so the component footprint itself supplies
    // the top-to-bottom transition; there is no separate saved via.
    const module_pads = [_]geometry.Pad{
        .{ .number = "4", .x = 0, .y = 0, .w = 2, .h = 1 },
        .{ .number = "4", .x = 0.6, .y = 0, .w = 0.3, .h = 0.3, .shape = "circle", .thru = true, .drill = 0.2 },
    };
    const cap_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &module_pads, .fallback = false, .x = 0, .y = 0, .side = .top },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &cap_pads, .fallback = false, .x = 0.6, .y = 0, .side = .bottom },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "4" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "VOUT", .pins = &pins }};

    const connected = try routableTally(arena, tallyFixture(&parts, &nets), .{});
    try testing.expectEqual(@as(usize, 1), connected.total);
    try testing.expectEqual(@as(usize, 1), connected.routed);
}

// spec: fab_readiness - an open net's island report marks the island already joined to the net's plane or pour copper
// spec: fab_readiness - a same-net trace that enters a user pour joins it without a sacrificial via
test "openNets marks the pour-joined island and leaves the stranded one unmarked" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // R1.1 and R2.1 sit inside a top-layer pour on their own net; R3.1 sits
    // outside it with no copper at all — two islands, one already carried.
    const pads1 = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 1, .hh = 1, .pads = &pads1, .fallback = false, .x = 1, .y = 1 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 1, .hh = 1, .pads = &pads1, .fallback = false, .x = 3, .y = 1 },
        .{ .ref_des = "R3", .kind = .passive, .hw = 1, .hh = 1, .pads = &pads1, .fallback = false, .x = 10, .y = 1 },
    };
    const pins = [_]export_kicad.FlatPin{
        .{ .ref_des = "R1", .pin = "1" },
        .{ .ref_des = "R2", .pin = "1" },
        .{ .ref_des = "R3", .pin = "1" },
    };
    const nets = [_]export_kicad.FlatNet{.{ .name = "PWR", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 12,
        .maxy = 4,
        .generated = false,
        .board_rect = .{ .minx = -2, .miny = -2, .w = 16, .h = 8 },
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };
    const poly = [_][2]f64{ .{ 0, 0 }, .{ 5, 0 }, .{ 5, 2 }, .{ 0, 2 } };
    const zones = [_]pour.UserZone{.{ .net = "PWR", .layer = 0, .poly = &poly }};

    const open = try openNets(arena, placement, .{ .zones = &zones });
    try testing.expectEqual(@as(usize, 1), open.len);
    try testing.expectEqual(@as(usize, 2), open[0].islands);
    try testing.expectEqual(@as(usize, 2), open[0].plane_joined.len);
    // R1/R2's island is the pour's; R3's island is stranded and unmarked.
    const joined_island = open[0].pads[0].island;
    const stranded_island = open[0].pads[2].island;
    try testing.expect(open[0].plane_joined[joined_island]);
    try testing.expect(!open[0].plane_joined[stranded_island]);

    // A trace from the stranded pad into the pour is enough to close the net;
    // no via should be needed merely to teach the connectivity graph that the
    // trace and pour are the same copper island.
    const track = [_]router.Track{.{
        .x1 = 10,
        .y1 = 1,
        .x2 = 4,
        .y2 = 1,
        .layer = 0,
        .width = 0.2,
        .net = 0,
    }};
    const closed = try openNets(arena, placement, .{ .tracks = &track, .zones = &zones });
    try testing.expectEqual(@as(usize, 0), closed.len);
}

// spec: fab_readiness - two same-net vias that abut with no track between them are one copper island
test "abutting same-net vias unite; vias beyond the touch slack stay two islands" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const one_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &one_pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &one_pad, .fallback = false, .x = 10, .y = 0 },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 12,
        .maxy = 2,
        .generated = false,
        .board_rect = .{ .minx = -2, .miny = -2, .w = 16, .h = 6 },
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };

    // Two stubs, each ending on its own via, with a 0.4 mm gap between the
    // vias' centres — 0.4 mm ⌀ barrels, so they abut exactly (reach = 0.2 +
    // 0.2 + 0.02 slack). Every OTHER touch rule misses this pair by design:
    // the two tracks are 0.4 mm apart (reach 0.22) and each via clears the
    // FOREIGN track by 0.4 mm (reach 0.32), so the only join available is
    // via ↔ via.
    const abut_tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 4, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 4.4, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const abut_vias = [_]router.Via{
        .{ .x = 4, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 },
        .{ .x = 4.4, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 },
    };
    const joined = try netComponents(arena, placement, .{ .tracks = &abut_tracks, .vias = &abut_vias }, nets[0], 0);
    try testing.expectEqual(@as(usize, 2), joined.locations);
    try testing.expectEqual(@as(usize, 1), joined.groups);

    // Push the second via (and its stub) out to 0.8 mm between centres — past
    // the barrels' reach — and the same copper is honestly two islands.
    const split_tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 4, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 4.8, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const split_vias = [_]router.Via{
        .{ .x = 4, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 },
        .{ .x = 4.8, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 },
    };
    const split = try netComponents(arena, placement, .{ .tracks = &split_tracks, .vias = &split_vias }, nets[0], 0);
    try testing.expectEqual(@as(usize, 2), split.groups);
}

// spec: fab_readiness - the net graph reports whether its plane verdict was computed on a coarsened pour raster
test "the net graph flags a plane verdict computed on a coarsened raster" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const one_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.3 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &one_pad, .fallback = false, .x = 2, .y = 2 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &one_pad, .fallback = false, .x = 12, .y = 2 },
    };
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "GND", .pins = &pins }};
    var placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 16,
        .maxy = 6,
        .generated = false,
        // No (stackup …) form → implicit planes → GND is plane-carried, so the
        // pour raster really runs and the flag reports on something.
        .board_rect = .{ .minx = 0, .miny = 0, .w = 16, .h = 6 },
    };

    const fine = try buildNetGraph(arena, placement, .{}, nets[0], 0);
    try testing.expect(fine.plane.nodes.len > 0);
    try testing.expect(!fine.plane.coarsened);

    // The same net on a board whose raster cannot fit the fill cell budget:
    // 90 × 90 mm at a 0.05 mm pitch is 3.24 M cells, so `pour.lattice` degrades
    // the pitch and the plane half of this verdict is no longer exact.
    placement.board_rect = .{ .minx = 0, .miny = 0, .w = 90, .h = 90 };
    placement.rules = .{ .design = .{ .pour_clearance = 0.1 } };
    const coarse = try buildNetGraph(arena, placement, .{}, nets[0], 0);
    try testing.expect(coarse.plane.coarsened);
}
