//! Emission half of channel folding (`import_fold.zig` detects, this file
//! writes). Turns the exemplar channel cluster into a `(defmodule …)` text
//! plus the per-channel stitching data the design emitter needs:
//!
//!  - Refs are normalized per prefix (IC2→IC1, J4→J1, FB20→FB1) so the
//!    module reads as a clean template; each channel's original ref-des
//!    survive in a provenance comment on its `(sub-block …)` line.
//!  - Indexed nets (`CH2_RF_IN`) become ports named from the family
//!    template (`CH~_RF_IN` → `RF_IN`); shared nets (GND, +5.0V, MOSI)
//!    become same-named ports; cluster-internal auto-nets get a cleaned
//!    local name (`Net-IC~-TTL_IN` → `TTL_IN`).
//!  - Cross-channel part correspondence comes from sorting each cluster
//!    by structural signature — valid because folding only ever groups
//!    channels with byte-identical signatures.

const std = @import("std");
const ik = @import("import_kicad.zig");
const fold = @import("import_fold.zig");

const FoldError = fold.FoldError;

/// Build the FoldResult (module text + stitching plan) for the verified
/// fold group. `fold_set` is sorted ascending; its first index is the
/// exemplar channel the module is written from.
pub fn emitFold(
    ctx: *fold.FoldCtx,
    fold_set: []const u64,
    skipped: []const u64,
    design_name: []const u8,
) FoldError!fold.FoldResult {
    const arena = ctx.arena;
    const exemplar = fold_set[0];

    const cluster = try sortedCluster(ctx, exemplar);
    const norm_refs = try normalizedRefs(ctx, cluster);
    var names = try NetNaming.build(ctx, cluster, exemplar);

    const prefix_lower = try arena.dupe(u8, ctx.prefix);
    for (prefix_lower) |*c| c.* = std.ascii.toLower(c.*);
    const module_name = try std.fmt.allocPrint(arena, "{s}-{s}", .{ design_name, prefix_lower });

    const module_text = try renderModule(ctx, module_name, cluster, norm_refs, &names, exemplar);

    // Per-channel stitching: indexed ports wired to that channel's family
    // member; ref provenance from signature-sorted correspondence.
    var channels: std.ArrayListUnmanaged(fold.FoldChannel) = .empty;
    for (fold_set) |k| {
        const k_cluster = try sortedCluster(ctx, k);
        var wires: std.ArrayListUnmanaged(fold.PortWire) = .empty;
        for (names.indexed.items) |ip| {
            if (familyMember(ctx, ip.template, k)) |raw| {
                try wires.append(arena, .{ .port = ip.port, .outer_raw = raw });
            }
        }
        var map_buf: std.ArrayListUnmanaged(u8) = .empty;
        for (k_cluster, 0..) |pi, slot| {
            if (slot > 0) try map_buf.appendSlice(arena, " ");
            try map_buf.appendSlice(arena, norm_refs[slot]);
            try map_buf.append(arena, '=');
            try map_buf.appendSlice(arena, ctx.parts[pi].ref);
        }
        try channels.append(arena, .{
            .index = k,
            .sub_name = try std.fmt.allocPrint(arena, "{s}{d}", .{ prefix_lower, k }),
            .wires = wires.items,
            .ref_map = map_buf.items,
        });
    }

    var folded = try arena.alloc(bool, ctx.parts.len);
    @memset(folded, false);
    for (ctx.claim, 0..) |c, i| {
        for (fold_set) |k| {
            if (c == k) folded[i] = true;
        }
    }

    return .{
        .active = true,
        .module_name = module_name,
        .module_text = module_text,
        .folded = folded,
        .channels = channels.items,
        .shared_nets = names.sharedNetList(),
        .skipped_indices = skipped,
        .parts_per_channel = cluster.len,
    };
}

/// Channel cluster part indices, sorted by structural signature so the
/// ordering corresponds across isomorphic channels.
fn sortedCluster(ctx: *fold.FoldCtx, chan: u64) FoldError![]usize {
    var idxs: std.ArrayListUnmanaged(usize) = .empty;
    for (ctx.claim, 0..) |c, i| {
        if (c == chan) try idxs.append(ctx.arena, i);
    }
    const sigs = try ctx.arena.alloc([]const u8, idxs.items.len);
    for (idxs.items, 0..) |pi, j| sigs[j] = try fold.signatureOf(ctx, pi, chan);
    // insertion sort by signature (clusters are small)
    var j: usize = 1;
    while (j < idxs.items.len) : (j += 1) {
        var m = j;
        while (m > 0 and std.mem.lessThan(u8, sigs[m], sigs[m - 1])) : (m -= 1) {
            std.mem.swap([]const u8, &sigs[m], &sigs[m - 1]);
            std.mem.swap(usize, &idxs.items[m], &idxs.items[m - 1]);
        }
    }
    return idxs.items;
}

/// "IC1"/"J1"/"FB1"… per cluster slot, counting per original ref prefix.
fn normalizedRefs(ctx: *fold.FoldCtx, cluster: []const usize) FoldError![][]const u8 {
    var counters = std.StringHashMap(usize).init(ctx.arena);
    const refs = try ctx.arena.alloc([]const u8, cluster.len);
    for (cluster, 0..) |pi, slot| {
        const prefix = refPrefix(ctx.parts[pi].ref);
        const c = try counters.getOrPut(prefix);
        if (!c.found_existing) c.value_ptr.* = 0;
        c.value_ptr.* += 1;
        refs[slot] = try std.fmt.allocPrint(ctx.arena, "{s}{d}", .{ prefix, c.value_ptr.* });
    }
    return refs;
}

fn refPrefix(ref: []const u8) []const u8 {
    var i: usize = 0;
    while (i < ref.len and std.ascii.isAlphabetic(ref[i])) i += 1;
    return ref[0..i];
}

/// One indexed port: module port name + the family template it came from.
const IndexedPort = struct { port: []const u8, template: []const u8 };

/// Maps every raw net the exemplar cluster touches to its module-local
/// name, and remembers which ports exist (indexed vs shared).
const NetNaming = struct {
    arena: std.mem.Allocator,
    local: std.StringHashMap([]const u8), // raw net → module-local net name
    indexed: std.ArrayListUnmanaged(IndexedPort),
    shared: std.ArrayListUnmanaged(fold.SharedNet),
    taken: std.StringHashMap(void),

    fn build(ctx: *fold.FoldCtx, cluster: []const usize, chan: u64) FoldError!NetNaming {
        var self = NetNaming{
            .arena = ctx.arena,
            .local = std.StringHashMap([]const u8).init(ctx.arena),
            .indexed = .empty,
            .shared = .empty,
            .taken = std.StringHashMap(void).init(ctx.arena),
        };
        for (cluster) |pi| {
            for (ctx.parts[pi].pads) |pad| {
                if (pad.net.len == 0 or std.mem.startsWith(u8, pad.net, ik.UNCONNECTED_PREFIX)) continue;
                if (self.local.contains(pad.net)) continue;
                const class = fold.classifyNet(ctx, pad.net, chan);
                if (class == .indexed) {
                    const template = ctx.seed_template.get(pad.net).?;
                    const port = try self.unique(try portSafe(ctx.arena, try portFromTemplate(ctx.arena, template, ctx.prefix)));
                    try self.local.put(pad.net, port);
                    try self.indexed.append(ctx.arena, .{ .port = port, .template = template });
                } else if (class == .shared) {
                    const port = try self.unique(try portSafe(ctx.arena, try ik.sanitizeNetName(ctx.arena, pad.net)));
                    try self.local.put(pad.net, port);
                    try self.shared.append(ctx.arena, .{ .raw = pad.net, .port = port });
                } else {
                    const name = try self.unique(try portSafe(ctx.arena, try internalName(ctx.arena, pad.net)));
                    try self.local.put(pad.net, name);
                }
            }
        }
        return self;
    }

    fn unique(self: *NetNaming, want: []const u8) FoldError![]const u8 {
        var name = want;
        var n: u32 = 2;
        while (self.taken.contains(name)) {
            name = try std.fmt.allocPrint(self.arena, "{s}_{d}", .{ want, n });
            n += 1;
        }
        try self.taken.put(name, {});
        return name;
    }

    fn sharedNetList(self: *NetNaming) []const fold.SharedNet {
        return self.shared.items;
    }
};

/// Module-local net/port names must avoid '.' — dotted nets collide with
/// the `<rail>.<ic>.<pad>` bypass-stub naming the evaluator canonicalizes,
/// which silently breaks the port↔net bond (`+5.0V` read back as `+5`).
fn portSafe(arena: std.mem.Allocator, name: []const u8) FoldError![]const u8 {
    if (std.mem.indexOfScalar(u8, name, '.') == null) return name;
    const out = try arena.dupe(u8, name);
    for (out) |*ch| {
        if (ch.* == '.') ch.* = '_';
    }
    return out;
}

/// `CH~_RF_IN` (prefix `CH`) → `RF_IN`; a bare `CH~` falls back to `CH`.
/// Leftover `~` from other digit runs are dropped.
fn portFromTemplate(arena: std.mem.Allocator, template: []const u8, prefix: []const u8) FoldError![]const u8 {
    var rest: []const u8 = template;
    const pat = try std.fmt.allocPrint(arena, "{s}~", .{prefix});
    if (std.mem.indexOf(u8, template, pat)) |at| rest = template[at + pat.len ..];
    while (rest.len > 0 and (rest[0] == '_' or rest[0] == '-')) rest = rest[1..];
    if (rest.len == 0) return arena.dupe(u8, prefix);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (rest) |ch| {
        if (ch != '~') try out.append(arena, ch);
    }
    return ik.sanitizeNetName(arena, out.items);
}

/// Local name for a cluster-internal net: `Net-IC2-TTL_IN` → `TTL_IN`
/// (auto-name: drop `Net-` and the ref token); otherwise the digit-less
/// template so all channels agree on the name.
fn internalName(arena: std.mem.Allocator, raw: []const u8) FoldError![]const u8 {
    if (std.mem.startsWith(u8, raw, "Net-")) {
        const body = raw["Net-".len..];
        if (std.mem.indexOfScalar(u8, body, '-')) |dash| {
            if (dash + 1 < body.len) return ik.sanitizeNetName(arena, body[dash + 1 ..]);
        }
        return ik.sanitizeNetName(arena, body);
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (raw) |ch| {
        if (!std.ascii.isDigit(ch)) try out.append(arena, ch);
    }
    return ik.sanitizeNetName(arena, out.items);
}

/// Render the defmodule text: imports for the cluster's custom components,
/// instances with normalized refs and net-grouped pins, then port
/// declarations for every indexed and shared net.
fn renderModule(
    ctx: *fold.FoldCtx,
    module_name: []const u8,
    cluster: []const usize,
    norm_refs: []const []const u8,
    names: *NetNaming,
    chan: u64,
) FoldError![]const u8 {
    _ = chan;
    const arena = ctx.arena;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(arena);

    w.writeAll(";; Auto-generated by `netlisp import-kicad --fold-channels` — one channel\n") catch return error.OutOfMemory;
    w.print(";; of the {s} repetition. Edit freely; re-import never overwrites.\n", .{ctx.prefix}) catch return error.OutOfMemory;

    var imports: std.ArrayListUnmanaged([]const u8) = .empty;
    for (cluster) |pi| {
        const part = ctx.parts[pi];
        if (part.family != null) continue;
        const comp = part.comp_name orelse continue;
        var dup = false;
        for (imports.items) |existing| {
            if (std.mem.eql(u8, existing, comp)) dup = true;
        }
        if (!dup) try imports.append(arena, comp);
    }
    std.mem.sort([]const u8, imports.items, {}, strLess);
    for (imports.items) |imp| w.print("(import {s})\n", .{imp}) catch return error.OutOfMemory;

    w.print("\n(defmodule {s} ()\n", .{module_name}) catch return error.OutOfMemory;
    w.print("  \"One {s} channel ({d} parts), folded from the imported board.\"\n\n", .{ ctx.prefix, cluster.len }) catch return error.OutOfMemory;
    w.print("  (design-block \"{s} Channel\"\n", .{ctx.prefix}) catch return error.OutOfMemory;

    // Hubs before passives, both in normalized-ref order for readability.
    for ([2]bool{ true, false }) |want_hub| {
        for (cluster, 0..) |pi, slot| {
            if (isHubRef(ctx.parts[pi].ref) != want_hub) continue;
            try renderInstance(ctx, w, pi, norm_refs[slot], names);
        }
    }

    w.writeAll("\n") catch return error.OutOfMemory;
    for (names.indexed.items) |ip| {
        w.print("    (port \"{s}\" bidi)\n", .{ip.port}) catch return error.OutOfMemory;
    }
    for (names.shared.items) |sn| {
        w.print("    (port \"{s}\" bidi)\n", .{sn.port}) catch return error.OutOfMemory;
    }
    w.writeAll("))\n") catch return error.OutOfMemory;
    return buf.items;
}

fn renderInstance(ctx: *fold.FoldCtx, w: anytype, pi: usize, ref: []const u8, names: *NetNaming) FoldError!void {
    const part = ctx.parts[pi];
    if (part.dnp) w.writeAll("    ;; DNP on the source board\n") catch return error.OutOfMemory;
    if (part.family) |fam| {
        const value = if (part.value.len > 0 and !std.mem.eql(u8, part.value, "~")) part.value else "?";
        w.print("    (instance \"{s}\" ({s} \"{s}\")", .{ ref, fam, value }) catch return error.OutOfMemory;
    } else {
        w.print("    (instance \"{s}\" {s}", .{ ref, part.comp_name.? }) catch return error.OutOfMemory;
    }

    // Group pads by module-local net, first-seen order, dedup pad numbers.
    var order: std.ArrayListUnmanaged([]const u8) = .empty; // local net order
    var pins_of = std.StringHashMap(std.ArrayListUnmanaged([]const u8)).init(ctx.arena);
    for (part.pads) |pad| {
        if (pad.net.len == 0 or std.mem.startsWith(u8, pad.net, ik.UNCONNECTED_PREFIX)) continue;
        const local = names.local.get(pad.net) orelse continue;
        const slot = try pins_of.getOrPut(local);
        if (!slot.found_existing) {
            slot.value_ptr.* = .empty;
            try order.append(ctx.arena, local);
        }
        var dup = false;
        for (slot.value_ptr.items) |p| {
            if (std.mem.eql(u8, p, pad.number)) dup = true;
        }
        if (!dup) try slot.value_ptr.append(ctx.arena, pad.number);
    }
    for (order.items) |local| {
        const pins = pins_of.get(local).?;
        w.writeAll("\n      (pin") catch return error.OutOfMemory;
        for (pins.items) |p| w.print(" {s}", .{p}) catch return error.OutOfMemory;
        w.print(" \"{s}\")", .{local}) catch return error.OutOfMemory;
    }
    // First-class DNP (the `;; DNP on the source board` comment above stays for
    // provenance) so a folded channel's option part re-exports as DNP too.
    if (part.dnp) w.writeAll("\n      (dnp)") catch return error.OutOfMemory;
    w.writeAll(")\n") catch return error.OutOfMemory;
}

fn isHubRef(ref: []const u8) bool {
    if (ref.len == 0) return true;
    return switch (ref[0]) {
        'R', 'C', 'L', 'F', 'D' => false,
        else => true,
    };
}

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Raw net carrying index `k` in the family identified by `template`.
fn familyMember(ctx: *fold.FoldCtx, template: []const u8, k: u64) ?[]const u8 {
    var it = ctx.seed.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != k) continue;
        const t = ctx.seed_template.get(e.key_ptr.*) orelse continue;
        if (std.mem.eql(u8, t, template)) return e.key_ptr.*;
    }
    return null;
}
