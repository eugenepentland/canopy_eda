//! Shared net-analysis helpers used by both the eval-time validator
//! (`src/eval/validate.zig`) and the on-demand ERC pass (`src/erc.zig`).
//! Keeps the two checkers in lockstep — if one is fixed, both are fixed.

const std = @import("std");
const env_mod = @import("env.zig");
const DesignBlock = env_mod.DesignBlock;

/// Strip a `.subnet` suffix so `VDD.U3.W6` collapses to `VDD`. The `.`
/// separator is used by the eval builder to carve per-pin/per-port split
/// nets off a base rail; for most analyses we want the base name.
pub fn baseNetName(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, '.')) |idx| return name[0..idx];
    return name;
}

/// Return the leading character of a ref-des with any `sub-block/` namespace
/// prefix stripped (`ldo/C136` → 'C'). Sub-block parts get namespaced after
/// ref-des renaming, so a naive `ref_des[0]` would see `l`/`a`/etc. instead
/// of the local component class.
pub fn refDesLocalPrefix(ref_des: []const u8) u8 {
    if (ref_des.len == 0) return 0;
    if (std.mem.lastIndexOfScalar(u8, ref_des, '/')) |i| {
        if (i + 1 < ref_des.len) return ref_des[i + 1];
        return 0;
    }
    return ref_des[0];
}

/// Walk a sub-block path like `ldo/VOUT` or `adc1/VLOGIC` into the block
/// tree and return true if the leaf net carries at least one C-prefix pin.
/// Used to detect decoupling that lives inside a sub-block whose port is
/// tied to a top-level power rail via a `(net ...)` form.
pub fn subBlockNetHasCap(block: *const DesignBlock, net_path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, net_path, '/')) |slash| {
        const head = net_path[0..slash];
        const rest = net_path[slash + 1 ..];
        for (block.sub_blocks) |sb| {
            if (std.mem.eql(u8, sb.name, head)) return subBlockNetHasCap(sb.block, rest);
        }
        return false;
    }
    for (block.nets) |n| {
        if (!std.mem.eql(u8, n.name, net_path)) continue;
        for (n.pins) |pin| {
            if (pin.ref_des.len == 0) continue;
            if (refDesLocalPrefix(pin.ref_des) == 'C') return true;
        }
        return false;
    }
    return false;
}

/// Return the base names of every power-net on `block` that has at least
/// one IC pin connected but no decoupling cap — including caps reached via
/// a `(net "RAIL" "sub/PORT" ...)` tie into a sub-block.
///
/// Caller owns the returned slice (allocated with `allocator`); the net
/// name slices inside reference strings owned by `block`.
pub fn findMissingDecouplingNets(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
) []const []const u8 {
    var power_nets: std.StringHashMapUnmanaged(void) = .empty;
    defer power_nets.deinit(allocator);
    for (block.sections) |sec| {
        // Concept sections haven't been implemented yet — skip so we don't
        // demand decoupling caps on rails that aren't wired to anything.
        if (sec.status == .concept) continue;
        for (sec.ports) |p| {
            if (p.signal_type == .power and p.direction == .in) {
                power_nets.put(allocator, p.name, {}) catch {};
            }
        }
    }

    var missing: std.ArrayListUnmanaged([]const u8) = .empty;
    for (block.nets) |net| {
        const base = baseNetName(net.name);
        if (!power_nets.contains(base)) continue;

        var has_ic = false;
        var has_cap = false;
        for (net.pins) |pin| {
            if (pin.ref_des.len == 0) continue;
            const prefix = refDesLocalPrefix(pin.ref_des);
            if (prefix == 'U') has_ic = true;
            if (prefix == 'C') has_cap = true;
        }
        if (has_ic and !has_cap) {
            for (block.net_ties) |tie| {
                const other: ?[]const u8 = if (std.mem.eql(u8, tie.a, base))
                    tie.b
                else if (std.mem.eql(u8, tie.b, base))
                    tie.a
                else
                    null;
                if (other) |o| {
                    if (std.mem.indexOfScalar(u8, o, '/') != null and subBlockNetHasCap(block, o)) {
                        has_cap = true;
                        break;
                    }
                }
            }
        }
        if (has_ic and !has_cap) {
            missing.append(allocator, base) catch {};
        }
    }
    return missing.toOwnedSlice(allocator) catch &.{};
}
