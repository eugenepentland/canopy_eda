//! Per-net routing geometry resolved from the design's `(net-class …)`
//! declarations: which class each flattened net belongs to after hierarchy and
//! net-tie resolution, and the width / clearance / via / diff-pair / RF / match
//! numbers that class carries. Split out of `optimizer.zig` as its own module —
//! nothing here reads a placement, only the evaluated design block and its
//! flattened netlist, so the resolution is testable (and reviewable) on its own.
//!
//! `optimizer` re-exports the result types, so every existing `optimizer.NetRule`
//! spelling still resolves; this file is the one place they are defined.

const std = @import("std");
const env = @import("../eval/env.zig");
const flat_netlist = @import("../flat_netlist.zig");
const impedance = @import("impedance.zig");
const impedance_rules = @import("impedance_rules.zig");
const match_group = @import("match_group.zig");
const DesignBlock = env.DesignBlock;
const FlatNet = flat_netlist.FlatNet;

/// A net's leaf spelling — the segment after the last `/` of a hierarchical
/// name. Mirrors `optimizer.shortName`, kept local so this module imports no
/// placement code.
fn shortName(s: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| s[i + 1 ..] else s;
}

/// One flattened net's effective class identity and routing geometry in mm.
/// Zero-valued geometry keeps the corresponding router default.
pub const NetRule = struct {
    class: struct {
        /// Semantic identity after hierarchy/net-tie resolution. Empty means
        /// the net is not assigned to an authored class.
        name: []const u8 = "",
        /// Hierarchy path supplying membership ("" = board root).
        source: []const u8 = "",
        /// Equal-precedence child memberships named different classes.
        conflict: bool = false,
    } = .{},
    width: f64 = 0,
    /// Resolved SMD pad-local neck profile. The router keeps `width` as the
    /// nominal trunk geometry and uses this narrower profile only at lands.
    pad_neck: env.NetClassSpec.PadNeck = .{},
    clearance: f64 = 0,
    via_dia: f64 = 0,
    via_drill: f64 = 0,
    priority: u32 = 0,
    /// `(diff-pair [GAP])` from the winning class: <0 = not a pair; >=0 = a member
    /// (0 → couple at the clearance, >0 → explicit gap). See `diff_pairs.resolve`.
    diff_gap: f64 = -1,
    /// RF discipline the winning class declared (see `Rf`). Grouped because
    /// each member is meaningful only alongside — or defaults off — the class's
    /// `max_freq_hz`: `escape_mm`, `min_bend_ratio`, the via `fence` and the
    /// same-layer keepout halo.
    rf: Rf = .{},
    /// How finely this net's rescue windows are rastered (mm, 0 = the router's
    /// adaptive default). A hand places exact geometry; the maze must put a
    /// centerline on a lattice, so a net whose only legal path clears its
    /// obstacles by less than the grid pitch cannot be routed at ANY ordering
    /// or priority — barracuda's `SPI_SCK` has a legal detour clearing by
    /// 0.07-0.20 mm that a 0.11 mm raster provably cannot represent. Declaring
    /// `(net-class … (resolution 0.05))` buys that net a finer window; the cost
    /// is paid only by nets that ask.
    resolution_mm: f64 = 0,
    /// Length matching resolved from the winning class's `(match-group …)`.
    /// This is `env.ClassMatch` itself, not a mirror of it: unlike the fence and
    /// the RF sentinels, nothing about a group name or a tolerance is resolved
    /// into a different shape — 0 means "use the default" on both sides — so a
    /// second identical type would only be somewhere for the two to drift apart.
    match: env.ClassMatch = .{},
    /// Return-current policy from the winning class. Fast/RF auto-enablement
    /// is decided by the DRC from the electrical fields beside this policy.
    return_path: env.ClassReturnPath = .{},
};

/// Ground via fencing resolved from a `(net-class … (fence …))` declaration —
/// the placement-side mirror of `env.ClassFence`. The whole block is resolved
/// as ONE unit (a single winning declaration, never a field-by-field merge of
/// two different fences), because the numbers only make sense together: a pitch
/// from one class with an offset from another describes no fence anyone
/// authored. Sentinels are preserved verbatim, so "derive me" survives
/// resolution and is answered by `via_fence`'s helpers at generation time.
pub const FenceRule = struct {
    /// A `(fence …)` won for this net. False = the net is never fenced.
    declared: bool = false,
    /// Resolved `(pitch MM)` via spacing along the trace (0 = derive from
    /// `Rf.max_freq_hz`; see `via_fence.resolvedPitchMm`).
    pitch_mm: f64 = 0,
    /// Resolved generated and mask-open row counts. A zero mask-open count
    /// preserves the legacy default: expose every generated row.
    rows: struct { generated: u8 = 1, mask_open: u8 = 0 } = .{},
    /// Resolved `(offset MM)` copper-edge gap (0 = derive from the net's
    /// clearance; see `via_fence.resolvedGapMm`).
    offset_mm: f64 = 0,
    /// Resolved fence-via copper diameter, mm (0 = inherit the net's own via,
    /// else the board design rules; see `via_fence.resolvedFenceVia`).
    via_dia: f64 = 0,
    /// Resolved fence-via drill diameter, mm (same fallback chain as `via_dia`).
    via_drill: f64 = 0,
    /// Resolved stitched net name ("" = the board's first ground plane).
    net: []const u8 = "",
};

/// The controlled-impedance outcome for a net (see `impedance.Rule`).
pub const ImpedanceRule = impedance.Rule;

/// RF discipline resolved from a `(max-freq …)` class.
pub const Rf = struct {
    /// Lower edge of the return-loss evaluation band. A class that only uses
    /// legacy `(max-freq …)` resolves to max/100 for compatibility.
    electrical: struct {
        band_start_hz: f64 = 0,
        /// Minimum worst-case return loss over the resolved band (dB).
        return_loss_target_db: f64 = 20,
    } = .{},
    /// `(max-freq HZ)` from the winning class (0 = undeclared). Declaring it
    /// opts the net into RF bend discipline: routed corners are smoothed into
    /// arcs with centerline radius >= 3x the effective trace width
    /// (`bend_smooth.minBendRadius`), and under-radius corners DRC as
    /// `sharp_bend`.
    max_freq_hz: f64 = 0,
    /// Resolved `(escape MM)` straight pad-escape distance (0 = none): the
    /// net's traces leave each pad straight for this length before any bend —
    /// the maze penalizes early turns and the bend smoother keeps its arcs
    /// out of the reserve. Undeclared on a max-freq class defaults to
    /// `default_rf_escape_mm`.
    escape_mm: f64 = 0,
    /// Resolved `(min-bend-radius N)` bend-radius floor, as a multiple of the
    /// effective trace width (0 = undeclared → `bend_smooth.radius_width_ratio`,
    /// the 3× default). Only acts on a max-freq net; raising it flags more
    /// corners under-radius (and lifts the smoother's aim above the 5× cap when
    /// N exceeds it), lowering it accepts tighter sweeps.
    min_bend_ratio: f64 = 0,
    /// Resolved `(fence …)` ground-via fencing for this net (see `FenceRule`);
    /// `declared = false` when no winning class asked for a fence.
    fence: FenceRule = .{},
    /// Resolved `(mask-relief MM)` per-side solder-mask pullback from this
    /// net's routed copper. <0 = undeclared — the Gerber export then opens a
    /// max-freq net at the board's mask margin and leaves every other net
    /// tented; an explicit 0 keeps a max-freq net tented; >0 is the authored
    /// pullback (and opts in a class with no `(max-freq …)`). The sentinel is
    /// kept through resolution (like the fence's) because the default lives in
    /// `DesignRules.mask`, which this module never reads.
    mask_relief_mm: f64 = -1,
    /// Resolved `(keepout MM)` same-layer halo (mm, 0 = none): foreign copper
    /// on the SAME layer as this net's copper must stay this far away. Other
    /// layers are unconstrained (a crossing signal is free); a through-via
    /// barrel occupies every layer, so the halo still blocks it.
    keepout_mm: f64 = 0,
    /// Resolved keepout exemption radius around this net's own pads (mm, 0 =
    /// exempt nothing). The `(keepout … (escape MM))` sentinel is collapsed
    /// during resolution: an undeclared escape on a declared keepout inherits
    /// this net's resolved `escape_mm`, so it is always a concrete distance
    /// here (never the −1 the spec carries).
    keepout_escape_mm: f64 = 0,
    /// Resolved `(impedance OHMS)` target and whether the width came from it
    /// (see `ImpedanceRule`). Zeroed when the class declared no target, which
    /// makes every impedance path a no-op for a design that authored none.
    impedance: ImpedanceRule = .{},
};

/// Straight pad-escape distance a `(max-freq …)` class gets when it does not
/// author its own `(escape MM)`.
const default_rf_escape_mm: f64 = 1.0;

const ClassMemberDecl = struct {
    class_name: []const u8,
    net_name: []const u8,
    source: []const u8,
    depth: u16,
    order: u32,
};

const ClassProfileDecl = struct {
    spec: env.NetClassSpec,
    source: []const u8,
    depth: u16,
    order: u32,
};

const WinningClass = struct {
    class_name: []const u8,
    source: []const u8,
    depth: u16,
    order: u32,
};

const ClassCollectCtx = struct {
    arena: std.mem.Allocator,
    members: *std.ArrayList(ClassMemberDecl),
    profiles: *std.ArrayList(ClassProfileDecl),
    order: u32 = 0,
};

fn classNetName(arena: std.mem.Allocator, prefix: []const u8, name: []const u8) std.mem.Allocator.Error![]const u8 {
    if (prefix.len == 0) return arena.dupe(u8, name);
    if (name.len == 0) return arena.dupe(u8, prefix);
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, name });
}

fn collectNetClassDecls(
    ctx: *ClassCollectCtx,
    block: *const DesignBlock,
    prefix: []const u8,
    depth: u16,
) std.mem.Allocator.Error!void {
    for (block.net_classes) |nc| {
        const decl_order = ctx.order;
        ctx.order += 1;
        try ctx.profiles.append(ctx.arena, .{ .spec = nc, .source = prefix, .depth = depth, .order = decl_order });
        for (nc.nets) |name| try ctx.members.append(ctx.arena, .{
            .class_name = nc.name,
            .net_name = try classNetName(ctx.arena, prefix, name),
            .source = prefix,
            .depth = depth,
            .order = decl_order,
        });
    }
    for (block.sub_blocks) |sb| {
        const child = try classNetName(ctx.arena, prefix, sb.name);
        try collectNetClassDecls(ctx, sb.block, child, depth + 1);
    }
}

fn canonicalAlias(aliases: *const flat_netlist.CanonicalNetMap, name: []const u8) ?[]const u8 {
    if (aliases.get(name)) |n| return n;
    var it = aliases.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return entry.value_ptr.*;
    }
    return null;
}

fn netIndexNamed(nets: []const FlatNet, name: []const u8) ?usize {
    for (nets, 0..) |net, i| if (std.ascii.eqlIgnoreCase(net.name, name)) return i;
    return null;
}

fn isAncestorPath(ancestor: []const u8, child: []const u8) bool {
    if (ancestor.len == 0) return true;
    if (std.mem.eql(u8, ancestor, child)) return true;
    return child.len > ancestor.len and child[ancestor.len] == '/' and std.mem.startsWith(u8, child, ancestor);
}

fn betterProfile(p: ClassProfileDecl, best_depth: u16, best_order: u32) bool {
    return p.depth < best_depth or (p.depth == best_depth and p.order < best_order);
}

const ProfileRank = struct {
    depth: u16 = std.math.maxInt(u16),
    order: u32 = std.math.maxInt(u32),

    fn better(self: ProfileRank, p: ClassProfileDecl) bool {
        return betterProfile(p, self.depth, self.order);
    }

    fn take(self: *ProfileRank, p: ClassProfileDecl) void {
        self.* = .{ .depth = p.depth, .order = p.order };
    }
};

/// Depth/order tie-break bookkeeping for the `(fence …)` / `(keepout MM …)`
/// merge, held in its own struct so those three winners live outside
/// `profileRule`'s already-wide local set. `escape_declared` records whether any
/// candidate authored a keepout escape radius, which decides the sentinel
/// collapse after the merge loop.
const FenceMerge = struct {
    fence_depth: u16 = std.math.maxInt(u16),
    fence_order: u32 = std.math.maxInt(u32),
    keepout_depth: u16 = std.math.maxInt(u16),
    keepout_order: u32 = std.math.maxInt(u32),
    escape_depth: u16 = std.math.maxInt(u16),
    escape_order: u32 = std.math.maxInt(u32),
    escape_declared: bool = false,
};

/// Merge one candidate profile's `(fence …)` / `(keepout MM [(escape MM)])`
/// declarations into `out`. The fence resolves as ONE unit — the best-ranked
/// declaring profile wins the whole block, never a field-by-field blend of two
/// authored fences, since a pitch from one class with an offset from another
/// describes a fence nobody wrote. The keepout distance and its escape radius
/// resolve independently, like every other scalar profile field.
fn mergeFenceProfile(out: *NetRule, p: ClassProfileDecl, st: *FenceMerge) void {
    const f = p.spec.rf.fence;
    if (f.declared and betterProfile(p, st.fence_depth, st.fence_order)) {
        out.rf.fence = .{
            .declared = true,
            .pitch_mm = f.pitch_mm,
            .rows = .{ .generated = f.rows.generated, .mask_open = f.rows.mask_open },
            .offset_mm = f.offset_mm,
            .via_dia = f.via_dia,
            .via_drill = f.via_drill,
            .net = f.net,
        };
        st.fence_depth = p.depth;
        st.fence_order = p.order;
    }
    if (p.spec.rf.keepout_mm > 0 and betterProfile(p, st.keepout_depth, st.keepout_order)) {
        out.rf.keepout_mm = p.spec.rf.keepout_mm;
        st.keepout_depth = p.depth;
        st.keepout_order = p.order;
    }
    if (p.spec.rf.keepout_escape_mm >= 0 and betterProfile(p, st.escape_depth, st.escape_order)) {
        out.rf.keepout_escape_mm = p.spec.rf.keepout_escape_mm;
        st.escape_declared = true;
        st.escape_depth = p.depth;
        st.escape_order = p.order;
    }
}

fn profileRule(profiles: []const ClassProfileDecl, win: WinningClass, conflict: bool) NetRule {
    var out = NetRule{ .class = .{ .name = win.class_name, .source = win.source, .conflict = conflict } };
    var width_rank = ProfileRank{};
    var neck_width_rank = ProfileRank{};
    var neck_length_rank = ProfileRank{};
    var taper_length_rank = ProfileRank{};
    var clearance_rank = ProfileRank{};
    var via_dia_rank = ProfileRank{};
    var via_drill_rank = ProfileRank{};
    var priority_rank = ProfileRank{};
    var resolution_rank = ProfileRank{};
    var diff_gap_rank = ProfileRank{};
    var freq_rank = ProfileRank{};
    var band_rank = ProfileRank{};
    var return_loss_rank = ProfileRank{};
    var escape_rank = ProfileRank{};
    var bend_rank = ProfileRank{};
    var mask_relief_rank = ProfileRank{};
    var impedance_rank = ProfileRank{};
    var ground_gap_rank = ProfileRank{};
    var escape_declared = false;
    var fence_st = FenceMerge{};
    var match_st = match_group.Merge{};
    var return_path_rank = ProfileRank{};
    for (profiles) |p| {
        if (!std.ascii.eqlIgnoreCase(p.spec.name, win.class_name)) continue;
        if (!isAncestorPath(p.source, win.source)) continue;
        mergeFenceProfile(&out, p, &fence_st);
        match_group.mergeProfile(&out.match, p.spec.match, .{ .depth = p.depth, .order = p.order }, &match_st);
        if (p.spec.return_path.declared and return_path_rank.better(p)) {
            out.return_path = p.spec.return_path;
            return_path_rank.take(p);
        }
        if (p.spec.diff_gap >= 0 and diff_gap_rank.better(p)) {
            out.diff_gap = p.spec.diff_gap;
            diff_gap_rank.take(p);
        }
        if (p.spec.rf.max_freq_hz > 0 and freq_rank.better(p)) {
            out.rf.max_freq_hz = p.spec.rf.max_freq_hz;
            freq_rank.take(p);
        }
        if (p.spec.rf.electrical.band_start_hz > 0 and band_rank.better(p)) {
            out.rf.electrical.band_start_hz = p.spec.rf.electrical.band_start_hz;
            band_rank.take(p);
        }
        if (p.spec.rf.electrical.return_loss_target_db > 0 and return_loss_rank.better(p)) {
            out.rf.electrical.return_loss_target_db = p.spec.rf.electrical.return_loss_target_db;
            return_loss_rank.take(p);
        }
        if (p.spec.rf.escape_mm >= 0 and escape_rank.better(p)) {
            out.rf.escape_mm = p.spec.rf.escape_mm;
            escape_declared = true;
            escape_rank.take(p);
        }
        if (p.spec.rf.min_bend_ratio > 0 and bend_rank.better(p)) {
            out.rf.min_bend_ratio = p.spec.rf.min_bend_ratio;
            bend_rank.take(p);
        }
        if (p.spec.rf.mask_relief_mm >= 0 and mask_relief_rank.better(p)) {
            out.rf.mask_relief_mm = p.spec.rf.mask_relief_mm;
            mask_relief_rank.take(p);
        }
        if (p.spec.width > 0 and width_rank.better(p)) {
            out.width = p.spec.width;
            width_rank.take(p);
        }
        if (p.spec.pad_neck.width > 0 and neck_width_rank.better(p)) {
            out.pad_neck.width = p.spec.pad_neck.width;
            neck_width_rank.take(p);
        }
        if (p.spec.pad_neck.max_length > 0 and neck_length_rank.better(p)) {
            out.pad_neck.max_length = p.spec.pad_neck.max_length;
            neck_length_rank.take(p);
        }
        if (p.spec.pad_neck.taper_length > 0 and taper_length_rank.better(p)) {
            out.pad_neck.taper_length = p.spec.pad_neck.taper_length;
            taper_length_rank.take(p);
        }
        if (p.spec.clearance > 0 and clearance_rank.better(p)) {
            out.clearance = p.spec.clearance;
            clearance_rank.take(p);
        }
        if (p.spec.via_dia > 0 and via_dia_rank.better(p)) {
            out.via_dia = p.spec.via_dia;
            via_dia_rank.take(p);
        }
        if (p.spec.via_drill > 0 and via_drill_rank.better(p)) {
            out.via_drill = p.spec.via_drill;
            via_drill_rank.take(p);
        }
        if (p.spec.resolution_mm > 0 and resolution_rank.better(p)) {
            out.resolution_mm = p.spec.resolution_mm;
            resolution_rank.take(p);
        }
        if ((p.spec.rf.impedance.ohms > 0 or p.spec.rf.impedance.diff_ohms > 0) and impedance_rank.better(p)) {
            out.rf.impedance.ohms = p.spec.rf.impedance.ohms;
            out.rf.impedance.diff_ohms = p.spec.rf.impedance.diff_ohms;
            out.rf.impedance.layer = p.spec.rf.impedance.layer;
            impedance_rank.take(p);
        }
        if (p.spec.rf.impedance.ground_gap_mm > 0 and ground_gap_rank.better(p)) {
            out.rf.impedance.ground_gap_mm = p.spec.rf.impedance.ground_gap_mm;
            out.rf.impedance.ground_gap_max_mm = p.spec.rf.impedance.ground_gap_max_mm;
            ground_gap_rank.take(p);
        }
        if (p.spec.priority > 0 and priority_rank.better(p)) {
            out.priority = p.spec.priority;
            priority_rank.take(p);
        }
    }
    if (out.rf.max_freq_hz > 0 and out.rf.electrical.band_start_hz <= 0) out.rf.electrical.band_start_hz = out.rf.max_freq_hz / 100;
    if (!escape_declared and out.rf.max_freq_hz > 0) out.rf.escape_mm = default_rf_escape_mm;
    // A declared keepout with no authored escape radius inherits this net's
    // resolved pad escape (itself possibly the max-freq default just applied),
    // so the resolved rule never carries the spec's −1 "undeclared" sentinel.
    if (out.rf.keepout_mm > 0 and !fence_st.escape_declared) out.rf.keepout_escape_mm = out.rf.escape_mm;
    return out;
}

/// Resolve hierarchy-aware net-class membership and destination profiles into
/// index-aligned effective rules. Membership is attached to module-local aliases
/// before net ties are canonicalized; root profile fields then override module
/// fallbacks one field at a time. Public so KiCad sync uses the exact same
/// result as placement/route/DRC.
pub fn resolvedNetRules(
    arena: std.mem.Allocator,
    block: *const DesignBlock,
    nets: []const FlatNet,
) std.mem.Allocator.Error![]const NetRule {
    var members: std.ArrayList(ClassMemberDecl) = .empty;
    var profiles: std.ArrayList(ClassProfileDecl) = .empty;
    var collect = ClassCollectCtx{ .arena = arena, .members = &members, .profiles = &profiles };
    try collectNetClassDecls(&collect, block, "", 0);
    if (members.items.len == 0) return &.{};

    // Recreate the canonical alias map through the authoritative flattener.
    // This deliberately avoids any second, class-specific interpretation of
    // bridge/net-tie semantics.
    var ignored_nets: std.ArrayList(FlatNet) = .empty;
    var aliases: flat_netlist.CanonicalNetMap = .empty;
    try flat_netlist.flattenAndMergeNetsMapped(arena, block, &ignored_nets, &aliases);

    const wins = try arena.alloc(?WinningClass, nets.len);
    const conflicts = try arena.alloc(bool, nets.len);
    @memset(wins, null);
    @memset(conflicts, false);

    for (members.items) |m| {
        const target = canonicalAlias(&aliases, m.net_name);
        // Preserve the existing root-form convenience: `(nets "SW")` also
        // matches a unique/repeated flattened `child/SW` leaf.
        if (target == null and m.depth == 0) {
            for (nets, 0..) |net, ni| {
                if (!std.ascii.eqlIgnoreCase(m.net_name, net.name) and
                    !std.ascii.eqlIgnoreCase(m.net_name, shortName(net.name))) continue;
                const cand = WinningClass{
                    .class_name = m.class_name,
                    .source = m.source,
                    .depth = m.depth,
                    .order = m.order,
                };
                if (wins[ni]) |old| {
                    const class_conflict = old.depth == cand.depth and
                        !std.ascii.eqlIgnoreCase(old.class_name, cand.class_name);
                    if (class_conflict) conflicts[ni] = true;
                    if (cand.depth < old.depth or (cand.depth == old.depth and cand.order < old.order)) wins[ni] = cand;
                } else wins[ni] = cand;
            }
            continue;
        }
        const canon = target orelse continue;
        const ni = netIndexNamed(nets, canon) orelse continue;
        const cand = WinningClass{
            .class_name = m.class_name,
            .source = m.source,
            .depth = m.depth,
            .order = m.order,
        };
        if (wins[ni]) |old| {
            const class_conflict = old.depth == cand.depth and
                !std.ascii.eqlIgnoreCase(old.class_name, cand.class_name);
            if (class_conflict) conflicts[ni] = true;
            if (cand.depth < old.depth or (cand.depth == old.depth and cand.order < old.order)) wins[ni] = cand;
        } else wins[ni] = cand;
    }

    const out = try arena.alloc(NetRule, nets.len);
    var any = false;
    for (out, 0..) |*r, i| {
        if (wins[i]) |win| {
            r.* = profileRule(profiles.items, win, conflicts[i]);
            any = true;
        } else r.* = .{};
    }
    // Solve the width of any class that declared `(impedance …)` but no
    // `(width …)`. A no-op for every rule without a target — which is the whole
    // corpus — so no board's geometry moves because this pass exists.
    if (any) try impedance_rules.deriveWidths(arena, block, out);
    return if (any) out else &.{};
}

fn netRulesOf(
    arena: std.mem.Allocator,
    block: *const DesignBlock,
    nets: []const FlatNet,
) std.mem.Allocator.Error![]const NetRule {
    return resolvedNetRules(arena, block, nets);
}

// spec: placement/optimizer - a bridged subcircuit keeps its class and adopts destination profile fields
test "inherited net class resolves through canonical bridge names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const child_pins = [_]env.PinRef{.{ .ref_des = "U1", .pin = "1" }};
    const child_nets = [_]env.Net{.{ .name = "RFIN", .pins = &child_pins }};
    const child_classes = [_]env.NetClassSpec{.{
        .name = "rf-cpwg-50",
        .width = 0.20,
        .clearance = 0.15,
        .via_dia = 0.45,
        .return_path = .{ .declared = true, .reference_net = "AGND", .stitch_radius_mm = 2 },
        .nets = &.{"RFIN"},
    }};
    var child = DesignBlock{
        .name = "amp",
        .instances = &.{},
        .nets = &child_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .net_classes = &child_classes,
    };

    const root_pins = [_]env.PinRef{.{ .ref_des = "J1", .pin = "1" }};
    const root_nets = [_]env.Net{.{ .name = "ANT_IN", .pins = &root_pins }};
    const root_classes = [_]env.NetClassSpec{.{
        .name = "rf-cpwg-50",
        .width = 0.38,
        .clearance = 0.20,
        .via_drill = 0.30,
        .return_path = .{ .declared = true, .reference_net = "GND", .stitch_radius_mm = 1 },
    }};
    const subs = [_]env.SubBlock{.{ .name = "lna1", .block = &child }};
    const ties = [_]env.NetTie{.{ .a = "ANT_IN", .b = "lna1/RFIN" }};
    const root = DesignBlock{
        .name = "board",
        .instances = &.{},
        .nets = &root_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &subs,
        .net_ties = &ties,
        .net_classes = &root_classes,
    };

    var flat: std.ArrayList(FlatNet) = .empty;
    try flat_netlist.flattenAndMergeNets(arena, &root, &flat);
    try std.testing.expectEqual(@as(usize, 1), flat.items.len);
    try std.testing.expectEqualStrings("ANT_IN", flat.items[0].name);

    const rules = try resolvedNetRules(arena, &root, flat.items);
    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expectEqualStrings("rf-cpwg-50", rules[0].class.name);
    try std.testing.expectEqualStrings("lna1", rules[0].class.source);
    try std.testing.expectEqual(@as(f64, 0.38), rules[0].width);
    try std.testing.expectEqual(@as(f64, 0.20), rules[0].clearance);
    try std.testing.expectEqual(@as(f64, 0.45), rules[0].via_dia);
    try std.testing.expectEqual(@as(f64, 0.30), rules[0].via_drill);
    try std.testing.expect(rules[0].return_path.declared);
    try std.testing.expectEqualStrings("GND", rules[0].return_path.reference_net);
    try std.testing.expectEqual(@as(f64, 1), rules[0].return_path.stitch_radius_mm);
}

// spec: placement/optimizer - escape defaults to 1 mm on a max-freq class; explicit (escape) overrides
test "escape resolves from max-freq default, explicit value, and explicit zero" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pins_a = [_]env.PinRef{.{ .ref_des = "U1", .pin = "1" }};
    const pins_b = [_]env.PinRef{.{ .ref_des = "U1", .pin = "2" }};
    const pins_c = [_]env.PinRef{.{ .ref_des = "U1", .pin = "3" }};
    const nets = [_]env.Net{
        .{ .name = "LO", .pins = &pins_a },
        .{ .name = "IF", .pins = &pins_b },
        .{ .name = "RFX", .pins = &pins_c },
    };
    const classes = [_]env.NetClassSpec{
        .{ .name = "rf-default", .nets = &.{"LO"}, .rf = .{ .max_freq_hz = 12e9 } },
        .{ .name = "rf-long", .nets = &.{"IF"}, .rf = .{ .max_freq_hz = 12e9, .escape_mm = 2.5 } },
        .{ .name = "rf-off", .nets = &.{"RFX"}, .rf = .{ .max_freq_hz = 12e9, .escape_mm = 0 } },
    };
    const root = DesignBlock{
        .name = "board",
        .instances = &.{},
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .net_classes = &classes,
    };

    var flat: std.ArrayList(FlatNet) = .empty;
    try flat_netlist.flattenAndMergeNets(arena, &root, &flat);
    const rules = try resolvedNetRules(arena, &root, flat.items);
    try std.testing.expectEqual(@as(usize, 3), rules.len);
    for (flat.items, rules) |net, rule| {
        if (std.mem.eql(u8, net.name, "LO"))
            try std.testing.expectEqual(default_rf_escape_mm, rule.rf.escape_mm)
        else if (std.mem.eql(u8, net.name, "IF"))
            try std.testing.expectEqual(@as(f64, 2.5), rule.rf.escape_mm)
        else
            try std.testing.expectEqual(@as(f64, 0), rule.rf.escape_mm);
    }
}

test "pad neck geometry resolves independently from nominal class width" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pins = [_]env.PinRef{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]env.Net{.{ .name = "VDD", .pins = &pins }};
    const classes = [_]env.NetClassSpec{.{
        .name = "power",
        .width = 0.2532,
        .pad_neck = .{ .width = 0.1524, .max_length = 0.75, .taper_length = 0.35 },
        .nets = &.{"VDD"},
    }};
    const root = DesignBlock{
        .name = "board",
        .instances = &.{},
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .net_classes = &classes,
    };
    var flat: std.ArrayList(FlatNet) = .empty;
    try flat_netlist.flattenAndMergeNets(arena, &root, &flat);
    const rules = try resolvedNetRules(arena, &root, flat.items);
    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expectEqual(@as(f64, 0.2532), rules[0].width);
    try std.testing.expectEqual(@as(f64, 0.1524), rules[0].pad_neck.width);
    try std.testing.expectEqual(@as(f64, 0.75), rules[0].pad_neck.max_length);
    try std.testing.expectEqual(@as(f64, 0.35), rules[0].pad_neck.taper_length);
}

// spec: placement/optimizer - a net-class min-bend-radius lowers onto its nets' resolved rule
test "min-bend-radius resolves onto the class's nets and leaves others at the default sentinel" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pins_a = [_]env.PinRef{.{ .ref_des = "U1", .pin = "1" }};
    const pins_b = [_]env.PinRef{.{ .ref_des = "U1", .pin = "2" }};
    const nets = [_]env.Net{
        .{ .name = "GENTLE", .pins = &pins_a },
        .{ .name = "PLAIN", .pins = &pins_b },
    };
    const classes = [_]env.NetClassSpec{
        .{ .name = "gentle", .nets = &.{"GENTLE"}, .rf = .{ .max_freq_hz = 12e9, .min_bend_ratio = 5 } },
        .{ .name = "plain", .nets = &.{"PLAIN"}, .rf = .{ .max_freq_hz = 12e9 } },
    };
    const root = DesignBlock{
        .name = "board",
        .instances = &.{},
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .net_classes = &classes,
    };

    var flat: std.ArrayList(FlatNet) = .empty;
    try flat_netlist.flattenAndMergeNets(arena, &root, &flat);
    const rules = try resolvedNetRules(arena, &root, flat.items);
    try std.testing.expectEqual(@as(usize, 2), rules.len);
    for (flat.items, rules) |net, rule| {
        if (std.mem.eql(u8, net.name, "GENTLE"))
            try std.testing.expectEqual(@as(f64, 5), rule.rf.min_bend_ratio)
        else
            try std.testing.expectEqual(@as(f64, 0), rule.rf.min_bend_ratio);
    }
}

// spec: placement/optimizer - a net-class mask-relief resolves onto its nets' rule and leaves undeclared classes at the sentinel
test "mask-relief resolves onto the class's nets and keeps the derive-me sentinel elsewhere" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pins_a = [_]env.PinRef{.{ .ref_des = "U1", .pin = "1" }};
    const pins_b = [_]env.PinRef{.{ .ref_des = "U1", .pin = "2" }};
    const pins_c = [_]env.PinRef{.{ .ref_des = "U1", .pin = "3" }};
    const nets = [_]env.Net{
        .{ .name = "BARE", .pins = &pins_a },
        .{ .name = "TENTED", .pins = &pins_b },
        .{ .name = "PLAIN", .pins = &pins_c },
    };
    const classes = [_]env.NetClassSpec{
        .{ .name = "bare", .nets = &.{"BARE"}, .rf = .{ .max_freq_hz = 12e9, .mask_relief_mm = 0.1 } },
        .{ .name = "tented", .nets = &.{"TENTED"}, .rf = .{ .max_freq_hz = 12e9, .mask_relief_mm = 0 } },
        .{ .name = "plain", .nets = &.{"PLAIN"}, .rf = .{ .max_freq_hz = 12e9 } },
    };
    const root = DesignBlock{
        .name = "board",
        .instances = &.{},
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .net_classes = &classes,
    };

    var flat: std.ArrayList(FlatNet) = .empty;
    try flat_netlist.flattenAndMergeNets(arena, &root, &flat);
    const rules = try resolvedNetRules(arena, &root, flat.items);
    try std.testing.expectEqual(@as(usize, 3), rules.len);
    for (flat.items, rules) |net, rule| {
        if (std.mem.eql(u8, net.name, "BARE"))
            try std.testing.expectEqual(@as(f64, 0.1), rule.rf.mask_relief_mm)
        else if (std.mem.eql(u8, net.name, "TENTED"))
            // Explicit 0 survives resolution — the Gerber reads it as "tented".
            try std.testing.expectEqual(@as(f64, 0), rule.rf.mask_relief_mm)
        else
            // Undeclared keeps the sentinel; the export applies the max-freq
            // default there, because the mask margin lives in DesignRules.
            try std.testing.expectEqual(@as(f64, -1), rule.rf.mask_relief_mm);
    }
}

// spec: placement/rf-port-frame-routing - placement/net_rules - RF band and return-loss resolve with backward-compatible defaults
test "RF electrical band and return-loss resolve from class" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pins_a = [_]env.PinRef{.{ .ref_des = "U1", .pin = "1" }};
    const pins_b = [_]env.PinRef{.{ .ref_des = "U1", .pin = "2" }};
    const nets = [_]env.Net{
        .{ .name = "AUTHORED", .pins = &pins_a },
        .{ .name = "DEFAULT", .pins = &pins_b },
    };
    const classes = [_]env.NetClassSpec{
        .{ .name = "authored", .nets = &.{"AUTHORED"}, .rf = .{ .max_freq_hz = 6e9, .electrical = .{ .band_start_hz = 100e6, .return_loss_target_db = 23 } } },
        .{ .name = "default", .nets = &.{"DEFAULT"}, .rf = .{ .max_freq_hz = 12e9 } },
    };
    const root = DesignBlock{ .name = "board", .instances = &.{}, .nets = &nets, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &.{}, .net_classes = &classes };
    var flat: std.ArrayList(FlatNet) = .empty;
    try flat_netlist.flattenAndMergeNets(arena, &root, &flat);
    const rules = try resolvedNetRules(arena, &root, flat.items);
    for (flat.items, rules) |net, rule| {
        if (std.mem.eql(u8, net.name, "AUTHORED")) {
            try std.testing.expectEqual(@as(f64, 100e6), rule.rf.electrical.band_start_hz);
            try std.testing.expectEqual(@as(f64, 23), rule.rf.electrical.return_loss_target_db);
        } else {
            try std.testing.expectEqual(@as(f64, 120e6), rule.rf.electrical.band_start_hz);
            try std.testing.expectEqual(@as(f64, 20), rule.rf.electrical.return_loss_target_db);
        }
    }
}

// spec: placement/optimizer - a net-class fence resolves as one unit so the best-ranked declaring class wins the whole block
test "a destination fence declaration replaces the module's fence outright" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The module declares a fully specified fence; the destination board
    // declares the same class with a pitch only. The board outranks the module
    // (shallower depth), and a fence is ONE field: its bare pitch wins and the
    // module's offset/via/net go with it, rather than blending into a fence no
    // author wrote.
    const child_pins = [_]env.PinRef{.{ .ref_des = "U1", .pin = "1" }};
    const child_nets = [_]env.Net{.{ .name = "RFIN", .pins = &child_pins }};
    const child_classes = [_]env.NetClassSpec{.{
        .name = "rf-fenced",
        .nets = &.{"RFIN"},
        .rf = .{
            .max_freq_hz = 12e9,
            .fence = .{ .declared = true, .pitch_mm = 2.0, .rows = .{ .generated = 3, .mask_open = 1 }, .offset_mm = 0.9, .via_dia = 0.5, .net = "AGND" },
        },
    }};
    var child = DesignBlock{
        .name = "amp",
        .instances = &.{},
        .nets = &child_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .net_classes = &child_classes,
    };

    const root_pins = [_]env.PinRef{.{ .ref_des = "J1", .pin = "1" }};
    const root_nets = [_]env.Net{.{ .name = "ANT_IN", .pins = &root_pins }};
    const root_classes = [_]env.NetClassSpec{.{
        .name = "rf-fenced",
        .rf = .{ .fence = .{ .declared = true, .pitch_mm = 1.0 } },
    }};
    const subs = [_]env.SubBlock{.{ .name = "lna1", .block = &child }};
    const ties = [_]env.NetTie{.{ .a = "ANT_IN", .b = "lna1/RFIN" }};
    const root = DesignBlock{
        .name = "board",
        .instances = &.{},
        .nets = &root_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &subs,
        .net_ties = &ties,
        .net_classes = &root_classes,
    };

    var flat: std.ArrayList(FlatNet) = .empty;
    try flat_netlist.flattenAndMergeNets(arena, &root, &flat);
    const rules = try resolvedNetRules(arena, &root, flat.items);
    try std.testing.expectEqual(@as(usize, 1), rules.len);
    const fence = rules[0].rf.fence;
    try std.testing.expect(fence.declared);
    try std.testing.expectEqual(@as(f64, 1.0), fence.pitch_mm);
    try std.testing.expectEqual(@as(u8, 1), fence.rows.generated);
    try std.testing.expectEqual(@as(u8, 0), fence.rows.mask_open);
    try std.testing.expectEqual(@as(f64, 0), fence.offset_mm);
    try std.testing.expectEqual(@as(f64, 0), fence.via_dia);
    try std.testing.expectEqualStrings("", fence.net);
    // The module's (max-freq …) still resolves normally — only the fence block
    // is all-or-nothing.
    try std.testing.expectEqual(@as(f64, 12e9), rules[0].rf.max_freq_hz);
}

// spec: placement/optimizer - a declared keepout with no escape radius inherits the net's resolved rf escape
test "keepout escape collapses to the resolved rf escape unless authored" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pins_a = [_]env.PinRef{.{ .ref_des = "U1", .pin = "1" }};
    const pins_b = [_]env.PinRef{.{ .ref_des = "U1", .pin = "2" }};
    const pins_c = [_]env.PinRef{.{ .ref_des = "U1", .pin = "3" }};
    const pins_d = [_]env.PinRef{.{ .ref_des = "U1", .pin = "4" }};
    const nets = [_]env.Net{
        .{ .name = "INHERIT", .pins = &pins_a },
        .{ .name = "LONG", .pins = &pins_b },
        .{ .name = "STRICT", .pins = &pins_c },
        .{ .name = "PLAIN", .pins = &pins_d },
    };
    const classes = [_]env.NetClassSpec{
        // No (escape …) anywhere: the keepout inherits the max-freq default.
        .{ .name = "k-inherit", .nets = &.{"INHERIT"}, .rf = .{ .max_freq_hz = 12e9, .keepout_mm = 0.5 } },
        // An authored class escape is what the keepout inherits, not the default.
        .{ .name = "k-long", .nets = &.{"LONG"}, .rf = .{ .max_freq_hz = 12e9, .escape_mm = 2.5, .keepout_mm = 0.5 } },
        // An explicit (keepout … (escape 0)) exempts nothing and is preserved.
        .{
            .name = "k-strict",
            .nets = &.{"STRICT"},
            .rf = .{ .max_freq_hz = 12e9, .keepout_mm = 0.5, .keepout_escape_mm = 0 },
        },
        // No keepout at all: no halo, and no exemption radius to resolve.
        .{ .name = "k-none", .nets = &.{"PLAIN"}, .rf = .{ .max_freq_hz = 12e9 } },
    };
    const root = DesignBlock{
        .name = "board",
        .instances = &.{},
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .net_classes = &classes,
    };

    var flat: std.ArrayList(FlatNet) = .empty;
    try flat_netlist.flattenAndMergeNets(arena, &root, &flat);
    const rules = try resolvedNetRules(arena, &root, flat.items);
    try std.testing.expectEqual(@as(usize, 4), rules.len);
    for (flat.items, rules) |net, rule| {
        if (std.mem.eql(u8, net.name, "INHERIT")) {
            try std.testing.expectEqual(@as(f64, 0.5), rule.rf.keepout_mm);
            try std.testing.expectEqual(default_rf_escape_mm, rule.rf.keepout_escape_mm);
        } else if (std.mem.eql(u8, net.name, "LONG")) {
            try std.testing.expectEqual(@as(f64, 2.5), rule.rf.keepout_escape_mm);
        } else if (std.mem.eql(u8, net.name, "STRICT")) {
            try std.testing.expectEqual(@as(f64, 0), rule.rf.keepout_escape_mm);
        } else {
            try std.testing.expectEqual(@as(f64, 0), rule.rf.keepout_mm);
            try std.testing.expectEqual(@as(f64, 0), rule.rf.keepout_escape_mm);
        }
    }
}
