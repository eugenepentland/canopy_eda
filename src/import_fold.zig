//! Channel folding for KiCad-imported designs.
//!
//! Highly channelized boards (RF switch matrices, ADC banks, multi-channel
//! front-ends) duplicate the same little circuit N times, differing only in
//! an index that shows up in the net names (`CH1_RF_IN` … `CH8_RF_IN`).
//! A flat import faithfully reproduces all N copies — correct, but noisy.
//!
//! `import-kicad --fold-channels` detects that repetition and rewrites it
//! as one `(defmodule …)` plus N `(sub-block "chK" …)` calls:
//!
//!  1. **Seed**: group nets into indexed families by replacing digit runs
//!     with `~` (`CH~_RF_IN`). Families must vary in exactly one digit run,
//!     not be KiCad auto-names (`Net-*`), and share a letter prefix (`CH`).
//!     The dominant prefix group is the channel space (override with
//!     `--fold-prefix`). A part touching nets of exactly one index is
//!     seeded into that channel.
//!  2. **Grow**: nets outside the seed families propagate a channel claim
//!     when every already-claimed member agrees on the index — this pulls
//!     in parts wired only through auto-named nets (a TTL ferrite on
//!     `Net-IC4-TTL_IN`). Conflicts permanently mark a part shared.
//!  3. **Verify**: per channel, build a structural signature (component +
//!     value + DNP + pin→net-class bindings, with nets classed as indexed
//!     template / internal / shared-literal). Only the largest group of
//!     channels with *identical* signatures folds; deviants stay flat and
//!     are reported.
//!  4. **Emit**: the exemplar channel becomes a defmodule with normalized
//!     refs (IC1, J1, FB1 …), indexed nets become ports (CH~_RF_IN →
//!     RF_IN), shared nets (GND, +5.0V, control lines) become same-named
//!     ports, and fully-internal auto-nets keep a cleaned-up local name.
//!     The design gets `(sub-block …)` calls plus `(net "CH2_RF_IN"
//!     "ch2/RF_IN")` stitching, with original ref-des noted per channel.

const std = @import("std");
const ik = @import("import_kicad.zig");

// ── Public result model ───────────────────────────────────────────────

/// One stitched connection: design-level net → module port, for one channel.
pub const PortWire = struct {
    port: []const u8, // module port name
    outer_raw: []const u8, // raw KiCad net to stitch to (sanitized at emission)
};

/// One folded channel instance.
pub const FoldChannel = struct {
    index: u64,
    sub_name: []const u8, // e.g. "ch2"
    wires: []const PortWire, // indexed-net stitching for this channel
    ref_map: []const u8, // "IC1=IC2 J1=J4 FB1=FB20" provenance comment
};

/// A shared net entering the module: the design-level raw net plus the
/// module port carrying it. The port name is dot-free (net names with
/// dots collide with the `<rail>.<ic>.<pad>` bypass-stub convention), so
/// it can differ from the net: `+5.0V` enters through port `+5_0V`.
pub const SharedNet = struct {
    raw: []const u8,
    port: []const u8,
};

/// Everything the design emitter needs to write the folded form.
pub const FoldResult = struct {
    active: bool = false,
    module_name: []const u8 = "",
    module_text: []const u8 = "",
    /// Per parts-array index: true when the part lives inside the module.
    folded: []const bool = &.{},
    channels: []const FoldChannel = &.{},
    /// Shared nets entering the module, stitched once as
    /// `(net "<raw>" "ch2/<port>" … "ch8/<port>")`.
    shared_nets: []const SharedNet = &.{},
    /// Indices that matched the family pattern but deviated structurally.
    skipped_indices: []const u64 = &.{},
    parts_per_channel: usize = 0,
};

pub const FoldError = error{OutOfMemory};

// ── Net family detection ──────────────────────────────────────────────

const Family = struct {
    template: []const u8, // digit runs → '~'
    prefix: []const u8, // letters immediately before the varying run
    /// member net → index value parsed from the varying digit run
    nets: std.StringHashMapUnmanaged(u64),
};

/// Replace every maximal digit run with '~'.
fn netTemplate(arena: std.mem.Allocator, net: []const u8) FoldError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < net.len) {
        if (std.ascii.isDigit(net[i])) {
            try out.append(arena, '~');
            while (i < net.len and std.ascii.isDigit(net[i])) i += 1;
        } else {
            try out.append(arena, net[i]);
            i += 1;
        }
    }
    return out.items;
}

fn digitRuns(arena: std.mem.Allocator, net: []const u8) FoldError![]const u64 {
    var runs: std.ArrayList(u64) = .empty;
    var i: usize = 0;
    while (i < net.len) {
        if (std.ascii.isDigit(net[i])) {
            const start = i;
            while (i < net.len and std.ascii.isDigit(net[i])) i += 1;
            const v = std.fmt.parseInt(u64, net[start..i], 10) catch 0;
            try runs.append(arena, v);
        } else i += 1;
    }
    return runs.items;
}

/// Letters of `template` immediately before the `var_run`-th '~'.
fn prefixBeforeRun(template: []const u8, var_run: usize) []const u8 {
    var seen: usize = 0;
    var pos: usize = template.len;
    for (template, 0..) |ch, i| {
        if (ch != '~') continue;
        if (seen == var_run) {
            pos = i;
            break;
        }
        seen += 1;
    }
    var start = pos;
    while (start > 0 and std.ascii.isAlphabetic(template[start - 1])) start -= 1;
    return template[start..pos];
}

/// Build indexed families from the design's raw net names. A family is a
/// template with ≥2 members varying in exactly one digit-run position,
/// excluding KiCad auto-names and unconnected stubs.
fn detectFamilies(arena: std.mem.Allocator, nets: []const []const u8) FoldError![]Family {
    var by_template = std.StringHashMapUnmanaged(std.ArrayList([]const u8)).empty;
    for (nets) |net| {
        if (net.len == 0) continue;
        if (std.mem.startsWith(u8, net, "Net-")) continue;
        if (std.mem.startsWith(u8, net, ik.UNCONNECTED_PREFIX)) continue;
        const t = try netTemplate(arena, net);
        if (std.mem.indexOfScalar(u8, t, '~') == null) continue;
        const slot = try by_template.getOrPut(arena, t);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(arena, net);
    }

    var fams: std.ArrayList(Family) = .empty;
    var it = by_template.iterator();
    while (it.next()) |entry| {
        const members = entry.value_ptr.items;
        if (members.len < 2) continue;
        const var_run = varyingRun(arena, members) catch continue orelse continue;
        var fam = Family{
            .template = entry.key_ptr.*,
            .prefix = prefixBeforeRun(entry.key_ptr.*, var_run),
            .nets = std.StringHashMapUnmanaged(u64).empty,
        };
        if (fam.prefix.len == 0) continue; // pure-number prefix: not channel-like
        for (members) |net| {
            const runs = try digitRuns(arena, net);
            try fam.nets.put(arena, net, runs[var_run]);
        }
        try fams.append(arena, fam);
    }
    return fams.items;
}

/// The single digit-run position whose value differs across members, or
/// null when zero or several positions vary (not an indexed family).
fn varyingRun(arena: std.mem.Allocator, members: []const []const u8) FoldError!?usize {
    const first = try digitRuns(arena, members[0]);
    var varying: ?usize = null;
    for (members[1..]) |net| {
        const runs = try digitRuns(arena, net);
        if (runs.len != first.len) return null;
        for (runs, first, 0..) |a, b, i| {
            if (a == b) continue;
            if (varying != null and varying.? != i) return null;
            varying = i;
        }
    }
    return varying;
}

/// Pick the seed prefix: explicit override, else the prefix whose families
/// cover the most nets (the "CH" of CH1_RF_IN/CH2_LO/…).
fn pickPrefix(arena: std.mem.Allocator, fams: []const Family, override: ?[]const u8) FoldError!?[]const u8 {
    if (override) |p| return p;
    var totals = std.StringHashMapUnmanaged(usize).empty;
    for (fams) |fam| {
        const slot = try totals.getOrPut(arena, fam.prefix);
        if (!slot.found_existing) slot.value_ptr.* = 0;
        slot.value_ptr.* += fam.nets.count();
    }
    var best: ?[]const u8 = null;
    var best_n: usize = 0;
    var it = totals.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* > best_n) {
            best_n = e.value_ptr.*;
            best = e.key_ptr.*;
        }
    }
    if (best_n < 4) return null; // too little repetition to be a channel space
    return best;
}

// ── Folding pipeline ──────────────────────────────────────────────────

/// Claim sentinel: part not (yet) assigned to any channel.
pub const UNCLAIMED: u64 = std.math.maxInt(u64);
/// Claim sentinel: part reached from two channels — permanently shared.
pub const SHARED: u64 = std.math.maxInt(u64) - 1;

/// Working state shared between the folding pipeline and the emitter.
pub const FoldCtx = struct {
    arena: std.mem.Allocator,
    parts: []const ik.Part,
    net_parts: std.StringHashMapUnmanaged(std.ArrayList(usize)),
    seed: std.StringHashMapUnmanaged(u64), // raw net → channel index (seed families only)
    seed_template: std.StringHashMapUnmanaged([]const u8), // raw net → family template
    claim: []u64, // per part: channel index / UNCLAIMED / SHARED
    prefix: []const u8,
};

const Ctx = FoldCtx;

/// Detect and fold the dominant channel structure. `parts` must already be
/// classified (family/comp_name set) — signatures depend on it.
pub fn foldChannels(
    arena: std.mem.Allocator,
    parts: []const ik.Part,
    design_name: []const u8,
    prefix_override: ?[]const u8,
) FoldError!FoldResult {
    var ctx = Ctx{
        .arena = arena,
        .parts = parts,
        .net_parts = std.StringHashMapUnmanaged(std.ArrayList(usize)).empty,
        .seed = std.StringHashMapUnmanaged(u64).empty,
        .seed_template = std.StringHashMapUnmanaged([]const u8).empty,
        .claim = try arena.alloc(u64, parts.len),
        .prefix = "",
    };
    @memset(ctx.claim, UNCLAIMED);

    var all_nets: std.ArrayList([]const u8) = .empty;
    for (parts, 0..) |part, i| {
        for (part.pads) |pad| {
            if (pad.net.len == 0 or std.mem.startsWith(u8, pad.net, ik.UNCONNECTED_PREFIX)) continue;
            const slot = try ctx.net_parts.getOrPut(arena, pad.net);
            if (!slot.found_existing) {
                slot.value_ptr.* = .empty;
                try all_nets.append(arena, pad.net);
            }
            // a part may touch a net on several pads; record once
            if (slot.value_ptr.items.len == 0 or slot.value_ptr.items[slot.value_ptr.items.len - 1] != i) {
                try slot.value_ptr.append(arena, i);
            }
        }
    }

    const fams = try detectFamilies(arena, all_nets.items);
    const prefix = (try pickPrefix(arena, fams, prefix_override)) orelse return .{};
    ctx.prefix = prefix;
    for (fams) |fam| {
        if (!std.mem.eql(u8, fam.prefix, prefix)) continue;
        var it = fam.nets.iterator();
        while (it.next()) |e| {
            try ctx.seed.put(arena, e.key_ptr.*, e.value_ptr.*);
            try ctx.seed_template.put(arena, e.key_ptr.*, fam.template);
        }
    }
    if (ctx.seed.count() == 0) return .{};

    seedClaims(&ctx);
    try propagateClaims(&ctx);
    return finishFold(&ctx, design_name);
}

/// Claim parts whose seed-family nets all carry one index.
fn seedClaims(ctx: *Ctx) void {
    for (ctx.parts, 0..) |part, i| {
        var idx: u64 = UNCLAIMED;
        var conflict = false;
        for (part.pads) |pad| {
            const k = ctx.seed.get(pad.net) orelse continue;
            if (idx == UNCLAIMED) {
                idx = k;
            } else if (idx != k) {
                conflict = true;
            }
        }
        if (conflict) {
            ctx.claim[i] = SHARED;
        } else if (idx != UNCLAIMED) {
            ctx.claim[i] = idx;
        }
    }
}

/// Grow channel claims through nets whose claimed members all agree.
/// Rounds are synchronous (propose from a frozen snapshot, apply after the
/// sweep) — a sequential sweep would let a shared bus propagate the first
/// channel it happens to see before the other channels' private nets have
/// claimed their parts. A part proposed by two different channels in one
/// round becomes permanently SHARED.
fn propagateClaims(ctx: *Ctx) FoldError!void {
    const proposal = try ctx.arena.alloc(u64, ctx.parts.len);
    var changed = true;
    while (changed) {
        changed = false;
        @memcpy(proposal, ctx.claim);
        var it = ctx.net_parts.iterator();
        while (it.next()) |entry| {
            if (ctx.seed.contains(entry.key_ptr.*)) continue;
            const members = entry.value_ptr.items;
            var idx: u64 = UNCLAIMED;
            var mixed = false;
            for (members) |i| {
                const c = ctx.claim[i]; // frozen snapshot, not this round's proposals
                if (c == UNCLAIMED or c == SHARED) continue;
                if (idx == UNCLAIMED) {
                    idx = c;
                } else if (idx != c) {
                    mixed = true;
                }
            }
            if (mixed or idx == UNCLAIMED) continue;
            for (members) |i| {
                if (ctx.claim[i] != UNCLAIMED) continue;
                if (proposal[i] == UNCLAIMED) {
                    proposal[i] = idx;
                } else if (proposal[i] != idx and proposal[i] != SHARED) {
                    proposal[i] = SHARED; // tug-of-war between two channels
                }
            }
        }
        for (proposal, 0..) |p, i| {
            if (p != ctx.claim[i]) {
                ctx.claim[i] = p;
                changed = true;
            }
        }
    }
}

// ── Signatures & grouping ─────────────────────────────────────────────

/// Net classification relative to one channel, used in both signatures and
/// module emission: indexed port, shared port, or module-internal net.
pub const NetClass = enum { indexed, shared, internal };

/// Classify `net` from channel `chan`'s point of view: an indexed family
/// net (becomes a per-channel port), a net leaving the cluster (becomes a
/// same-named shared port), or one fully inside the cluster (internal).
pub fn classifyNet(ctx: *Ctx, net: []const u8, chan: u64) NetClass {
    if (ctx.seed.contains(net)) return .indexed;
    const members = (ctx.net_parts.getPtr(net) orelse return .shared).items;
    for (members) |i| {
        if (ctx.claim[i] != chan) return .shared;
    }
    return .internal;
}

/// Emit the head of a part's signature (component/family + value + DNP) —
/// shared by the base and full signatures so the two agree on everything
/// except how internal nets are labelled.
fn writePartHead(ctx: *Ctx, w: anytype, part: ik.Part) FoldError!void {
    if (part.family) |fam| {
        w.print("{s}|{s}|", .{ fam, part.value }) catch return error.OutOfMemory;
    } else {
        w.print("{s}|", .{part.comp_name orelse "?"}) catch return error.OutOfMemory;
    }
    if (part.dnp) w.writeAll("dnp|") catch return error.OutOfMemory;
    _ = ctx;
}

/// A part's *base* signature: like `partSignature`, but every internal net
/// collapses to a bare `I` marker (no per-net identity). Self-contained —
/// used to fingerprint a part's role independently of *which* internal net
/// each pad lands on, which is what `internalNetKey` then measures.
fn partBaseSignature(ctx: *Ctx, i: usize, chan: u64) FoldError![]const u8 {
    const part = ctx.parts[i];
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(ctx.arena);
    try writePartHead(ctx, w, part);

    var binds: std.ArrayList([]const u8) = .empty;
    for (part.pads) |pad| {
        if (pad.net.len == 0 or std.mem.startsWith(u8, pad.net, ik.UNCONNECTED_PREFIX)) continue;
        const label = switch (classifyNet(ctx, pad.net, chan)) {
            .indexed => try std.fmt.allocPrint(ctx.arena, "{s}=T:{s}", .{ pad.number, ctx.seed_template.get(pad.net).? }),
            .internal => try std.fmt.allocPrint(ctx.arena, "{s}=I", .{pad.number}),
            .shared => try std.fmt.allocPrint(ctx.arena, "{s}=S:{s}", .{ pad.number, pad.net }),
        };
        try binds.append(ctx.arena, label);
    }
    std.mem.sort([]const u8, binds.items, {}, strLess);
    for (binds.items) |b| {
        w.writeAll(b) catch return error.OutOfMemory;
        w.writeAll(";") catch return error.OutOfMemory;
    }
    return buf.items;
}

/// A canonical, name-free fingerprint of an internal net `net` within channel
/// `chan`: the sorted multiset of `<base-part-signature>@<pad>` over every pad
/// sitting on it. Two internal nets are given the same key only when they play
/// structurally identical roles; a passive swapped from IC pad-3's private net
/// to pad-7's changes the membership of both nets, so their keys — and hence the
/// swapped part's binding in `partSignature` — differ. That closes the hole
/// where two same-template auto-nets (`Net-(IC4-Pad3)` / `Net-(IC4-Pad7)`) were
/// indistinguishable and a rewired channel could fold silently.
fn internalNetKey(ctx: *Ctx, net: []const u8, chan: u64) FoldError![]const u8 {
    const members = (ctx.net_parts.getPtr(net) orelse return ctx.arena.dupe(u8, "?")).items;
    var terms: std.ArrayList([]const u8) = .empty;
    for (members) |mi| {
        const base = try partBaseSignature(ctx, mi, chan);
        // Which of this member's pads land on `net` (a part can touch one
        // internal net on several pads — a thermal-pad split).
        for (ctx.parts[mi].pads) |pad| {
            if (!std.mem.eql(u8, pad.net, net)) continue;
            try terms.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{s}@{s}", .{ base, pad.number }));
        }
    }
    std.mem.sort([]const u8, terms.items, {}, strLess);
    var buf: std.ArrayList(u8) = .empty;
    for (terms.items) |t| {
        buf.appendSlice(ctx.arena, t) catch return error.OutOfMemory;
        buf.append(ctx.arena, ',') catch return error.OutOfMemory;
    }
    return buf.items;
}

fn partSignature(ctx: *Ctx, i: usize, chan: u64) FoldError![]const u8 {
    const part = ctx.parts[i];
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(ctx.arena);
    try writePartHead(ctx, w, part);

    var binds: std.ArrayList([]const u8) = .empty;
    for (part.pads) |pad| {
        if (pad.net.len == 0 or std.mem.startsWith(u8, pad.net, ik.UNCONNECTED_PREFIX)) continue;
        const label = switch (classifyNet(ctx, pad.net, chan)) {
            .indexed => try std.fmt.allocPrint(ctx.arena, "{s}=T:{s}", .{ pad.number, ctx.seed_template.get(pad.net).? }),
            // Was `I:<netTemplate>` — same for every auto-net off one IC, so a
            // passive swapped between two of them read identically. The
            // membership-derived key disambiguates them (see internalNetKey).
            .internal => try std.fmt.allocPrint(ctx.arena, "{s}=I:{s}", .{ pad.number, try internalNetKey(ctx, pad.net, chan) }),
            .shared => try std.fmt.allocPrint(ctx.arena, "{s}=S:{s}", .{ pad.number, pad.net }),
        };
        try binds.append(ctx.arena, label);
    }
    std.mem.sort([]const u8, binds.items, {}, strLess);
    for (binds.items) |b| {
        w.writeAll(b) catch return error.OutOfMemory;
        w.writeAll(";") catch return error.OutOfMemory;
    }
    return buf.items;
}

fn channelSignature(ctx: *Ctx, chan: u64) FoldError![]const u8 {
    var sigs: std.ArrayList([]const u8) = .empty;
    for (ctx.parts, 0..) |_, i| {
        if (ctx.claim[i] == chan) try sigs.append(ctx.arena, try partSignature(ctx, i, chan));
    }
    std.mem.sort([]const u8, sigs.items, {}, strLess);
    var buf: std.ArrayList(u8) = .empty;
    for (sigs.items) |s| {
        try buf.appendSlice(ctx.arena, s);
        try buf.append(ctx.arena, '\n');
    }
    return buf.items;
}

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Group channels by identical signature, fold the largest group (≥2).
fn finishFold(ctx: *Ctx, design_name: []const u8) FoldError!FoldResult {
    var indices: std.ArrayList(u64) = .empty;
    for (ctx.claim) |c| {
        if (c == UNCLAIMED or c == SHARED) continue;
        var known = false;
        for (indices.items) |k| {
            if (k == c) known = true;
        }
        if (!known) try indices.append(ctx.arena, c);
    }
    if (indices.items.len < 2) return .{};
    std.mem.sort(u64, indices.items, {}, std.sort.asc(u64));

    var groups = std.StringHashMapUnmanaged(std.ArrayList(u64)).empty;
    for (indices.items) |k| {
        const sig = try channelSignature(ctx, k);
        const slot = try groups.getOrPut(ctx.arena, sig);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(ctx.arena, k);
    }
    var best: ?[]u64 = null;
    var git = groups.iterator();
    while (git.next()) |e| {
        if (best == null or e.value_ptr.items.len > best.?.len) best = e.value_ptr.items;
    }
    const fold_set = best.?;
    if (fold_set.len < 2) return .{};

    var skipped: std.ArrayList(u64) = .empty;
    for (indices.items) |k| {
        var in_fold = false;
        for (fold_set) |f| {
            if (f == k) in_fold = true;
        }
        if (!in_fold) try skipped.append(ctx.arena, k);
    }

    const emit = @import("import_fold_emit.zig");
    return emit.emitFold(ctx, fold_set, skipped.items, design_name);
}

/// Sort key shared with the emitter: parts inside one channel sorted by
/// structural signature line up positionally across isomorphic channels,
/// which is what makes the per-channel "IC1=IC2" ref mapping valid.
pub fn signatureOf(ctx: *FoldCtx, part_idx: usize, chan: u64) FoldError![]const u8 {
    return partSignature(ctx, part_idx, chan);
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: import_fold - Detects indexed net families (digit run → ~) excluding KiCad auto-names
test "family detection finds CH~ and skips Net- auto names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const nets = [_][]const u8{ "CH1_RF_IN", "CH2_RF_IN", "CH1_LO", "CH2_LO", "Net-IC1-X", "Net-IC2-X", "GND" };
    const fams = try detectFamilies(arena, &nets);
    try testing.expectEqual(@as(usize, 2), fams.len);
    for (fams) |f| try testing.expectEqualStrings("CH", f.prefix);
    const prefix = try pickPrefix(arena, fams, null);
    try testing.expectEqualStrings("CH", prefix.?);
}

/// Three-channel synthetic board: per channel one 2-pad "switch" custom
/// part wired IN/OUT to CHk nets, GND, and a private auto-net to a ferrite.
/// Channel 3's ferrite has a different value, so it must deviate.
fn syntheticParts(arena: std.mem.Allocator) ![]ik.Part {
    var parts: std.ArrayList(ik.Part) = .empty;
    inline for (.{ 1, 2, 3 }) |k| {
        const ks = std.fmt.comptimePrint("{d}", .{k});
        var sw_pads: std.ArrayList(ik.Pad) = .empty;
        try sw_pads.append(arena, .{ .number = "1", .net = "CH" ++ ks ++ "_IN", .func = "IN" });
        try sw_pads.append(arena, .{ .number = "2", .net = "CH" ++ ks ++ "_OUT", .func = "OUT" });
        try sw_pads.append(arena, .{ .number = "3", .net = "+5.0V", .func = "VDD" });
        try sw_pads.append(arena, .{ .number = "4", .net = "Net-IC" ++ ks ++ "-CTL", .func = "CTL" });
        try parts.append(arena, .{
            .ref = "IC" ++ ks,
            .value = "SW",
            .lib_id = "X:SW",
            .descr = "",
            .mpn = "",
            .manufacturer = "",
            .dnp = false,
            .rot = 0,
            .pads = sw_pads.items,
            .node = undefined,
            .comp_name = "sw-part",
        });
        var fb_pads: std.ArrayList(ik.Pad) = .empty;
        try fb_pads.append(arena, .{ .number = "1", .net = "CTL_BUS", .func = "" });
        try fb_pads.append(arena, .{ .number = "2", .net = "Net-IC" ++ ks ++ "-CTL", .func = "" });
        try parts.append(arena, .{
            .ref = "FB" ++ ks,
            .value = if (k == 3) "600R" else "1K",
            .lib_id = "X:L_0402_1005Metric",
            .descr = "",
            .mpn = "",
            .manufacturer = "",
            .dnp = false,
            .rot = 0,
            .pads = fb_pads.items,
            .node = undefined,
            .family = "ferrite-0402",
        });
    }
    return parts.items;
}

// spec: import_fold - Folds isomorphic channels into a module and leaves deviating channels flat
test "fold groups identical channels and skips the deviant" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parts = try syntheticParts(arena);
    const res = try foldChannels(arena, parts, "demo", null);
    try testing.expect(res.active);
    try testing.expectEqualStrings("demo-ch", res.module_name);
    try testing.expectEqual(@as(usize, 2), res.channels.len); // ch1+ch2; ch3 deviates (600R)
    try testing.expectEqual(@as(usize, 1), res.skipped_indices.len);
    try testing.expectEqual(@as(u64, 3), res.skipped_indices[0]);
    try testing.expectEqual(@as(usize, 2), res.parts_per_channel);

    // Module: normalized refs, ports from templates, internal CTL net.
    try testing.expect(std.mem.indexOf(u8, res.module_text, "(defmodule demo-ch ()") != null);
    try testing.expect(std.mem.indexOf(u8, res.module_text, "(instance \"IC1\" sw-part") != null);
    try testing.expect(std.mem.indexOf(u8, res.module_text, "(instance \"FB1\" (ferrite-0402 \"1K\")") != null);
    try testing.expect(std.mem.indexOf(u8, res.module_text, "(port \"IN\" bidi)") != null);
    try testing.expect(std.mem.indexOf(u8, res.module_text, "(port \"OUT\" bidi)") != null);
    // Dotted rail names enter through a dot-free port (portSafe).
    try testing.expect(std.mem.indexOf(u8, res.module_text, "(port \"+5_0V\" bidi)") != null);
    try testing.expect(std.mem.indexOf(u8, res.module_text, "(port \"CTL_BUS\" bidi)") != null);
    try testing.expect(std.mem.indexOf(u8, res.module_text, "\"CTL\"") != null);

    // Stitching: ch2 wires its own family members; provenance recorded.
    const ch2 = res.channels[1];
    try testing.expectEqualStrings("ch2", ch2.sub_name);
    try testing.expectEqualStrings("CH2_IN", wireOuter(ch2.wires, "IN") orelse "MISSING");
    try testing.expect(std.mem.indexOf(u8, ch2.ref_map, "IC2") != null);

    // Folded flags: ch1+ch2 parts folded, ch3 parts flat.
    try testing.expectEqual(@as(usize, 4), countFolded(res.folded));
}

fn wireOuter(wires: []const PortWire, port: []const u8) ?[]const u8 {
    for (wires) |wire| {
        if (std.mem.eql(u8, wire.port, port)) return wire.outer_raw;
    }
    return null;
}

fn countFolded(folded: []const bool) usize {
    var n: usize = 0;
    for (folded) |f| {
        if (f) n += 1;
    }
    return n;
}

/// Board exercising the same-template internal-net hazard: each channel's IC
/// has two private auto-nets that differ only in a digit run
/// (`Net-ICk-3` / `Net-ICk-7` → both template to `Net-IC~-~`). A resistor of
/// the SAME value sits on the pad-4 net in the honest channels but is moved to
/// the pad-5 net in the last channel — a genuinely different netlist that the
/// old template-only signature could not see. `rewire_last` picks whether to
/// introduce that deviation.
fn ambiguousInternalParts(arena: std.mem.Allocator, comptime n: usize, rewire_last: bool) ![]ik.Part {
    var parts: std.ArrayList(ik.Part) = .empty;
    inline for (0..n) |ci| {
        const k = ci + 1;
        const ks = std.fmt.comptimePrint("{d}", .{k});
        const na = "Net-IC" ++ ks ++ "-3"; // IC pad 4's private net
        const nb = "Net-IC" ++ ks ++ "-7"; // IC pad 5's private net
        var ic_pads: std.ArrayList(ik.Pad) = .empty;
        try ic_pads.append(arena, .{ .number = "1", .net = "CH" ++ ks ++ "_IN", .func = "IN" });
        try ic_pads.append(arena, .{ .number = "2", .net = "CH" ++ ks ++ "_OUT", .func = "OUT" });
        try ic_pads.append(arena, .{ .number = "3", .net = "GND", .func = "GND" });
        try ic_pads.append(arena, .{ .number = "4", .net = na, .func = "A" });
        try ic_pads.append(arena, .{ .number = "5", .net = nb, .func = "B" });
        try parts.append(arena, .{
            .ref = "IC" ++ ks,
            .value = "SW",
            .lib_id = "X:SW",
            .descr = "",
            .mpn = "",
            .manufacturer = "",
            .dnp = false,
            .rot = 0,
            .pads = ic_pads.items,
            .node = undefined,
            .comp_name = "sw-part",
        });
        // The resistor: honest channels wire it to `na`; the deviant last
        // channel wires it to `nb` (same value, different net).
        const r_net = if (rewire_last and ci == n - 1) nb else na;
        var r_pads: std.ArrayList(ik.Pad) = .empty;
        try r_pads.append(arena, .{ .number = "1", .net = r_net, .func = "" });
        try r_pads.append(arena, .{ .number = "2", .net = "GND", .func = "" });
        try parts.append(arena, .{
            .ref = "R" ++ ks,
            .value = "10K",
            .lib_id = "X:R_0402_1005Metric",
            .descr = "",
            .mpn = "",
            .manufacturer = "",
            .dnp = false,
            .rot = 0,
            .pads = r_pads.items,
            .node = undefined,
            .family = "res-0402",
        });
    }
    return parts.items;
}

// spec: import_fold - A channel with a passive rewired between two same-template internal nets deviates instead of folding silently
test "same-template internal-net rewire is caught (never folds silently)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Control: three genuinely identical channels fold cleanly, all three.
    {
        const parts = try ambiguousInternalParts(arena, 3, false);
        const res = try foldChannels(arena, parts, "amb", null);
        try testing.expect(res.active);
        try testing.expectEqual(@as(usize, 3), res.channels.len);
        try testing.expectEqual(@as(usize, 0), res.skipped_indices.len);
    }

    // Hazard: the last channel's resistor moved to the sibling same-template
    // auto-net. The membership-derived internal-net key must expose that, so
    // channel 3 deviates and stays flat rather than folding with the exemplar's
    // (wrong-for-it) wiring.
    {
        const parts = try ambiguousInternalParts(arena, 3, true);
        const res = try foldChannels(arena, parts, "amb", null);
        try testing.expect(res.active);
        try testing.expectEqual(@as(usize, 2), res.channels.len); // ch1+ch2 fold
        try testing.expectEqual(@as(usize, 1), res.skipped_indices.len);
        try testing.expectEqual(@as(u64, 3), res.skipped_indices[0]);
    }
}

// spec: import_fold - Picks the varying digit run as the channel index when other runs are constant
test "varying run selection on multi-run names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // J5 constant, GP index varies → family indexes on the second run.
    const members = [_][]const u8{ "J5-GP1", "J5-GP2", "J5-GP3" };
    const run = (try varyingRun(arena, &members)).?;
    try testing.expectEqual(@as(usize, 1), run);
    try testing.expectEqualStrings("GP", prefixBeforeRun(try netTemplate(arena, members[0]), run));
}
