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
) std.mem.Allocator.Error![]const []const u8 {
    var power_nets: std.StringHashMapUnmanaged(void) = .empty;
    defer power_nets.deinit(allocator);
    for (block.sections) |sec| {
        // Concept sections haven't been implemented yet — skip so we don't
        // demand decoupling caps on rails that aren't wired to anything.
        if (sec.status == .concept) continue;
        for (sec.ports) |p| {
            if (p.signal_type == .power and p.direction == .in) {
                try power_nets.put(allocator, p.name, {});
            }
        }
    }

    // Aggregate IC- and cap-presence per *base* rail name, folding the trunk
    // net together with its per-pin bypass-stub nets (`<rail>.<ic>.<pad>`).
    // A `(decouple … per-pin PAD)` form hangs each local cap on such a stub and
    // pulls the bypassed pad off the trunk; `buildNets` then renames the stub to
    // share the canonical rail prefix when the pad's power-domain name merges
    // into a board rail (e.g. VDDSMPS/VDDIO2 → V1P8). So a rail whose pads are
    // all locally bypassed carries its caps only on the stubs, never the trunk —
    // a per-net check would falsely flag the trunk as undecoupled (the stm32n6
    // V1P8 1.8 V rail). Collapsing trunk + stubs to one base-name verdict fixes
    // that without weakening the check for genuinely bare rails.
    var rails_with_ic: std.StringHashMapUnmanaged(void) = .empty;
    defer rails_with_ic.deinit(allocator);
    var rails_with_cap: std.StringHashMapUnmanaged(void) = .empty;
    defer rails_with_cap.deinit(allocator);
    for (block.nets) |net| {
        const base = baseNetName(net.name);
        if (!power_nets.contains(base)) continue;
        for (net.pins) |pin| {
            if (pin.ref_des.len == 0) continue;
            switch (refDesLocalPrefix(pin.ref_des)) {
                'U' => try rails_with_ic.put(allocator, base, {}),
                'C' => try rails_with_cap.put(allocator, base, {}),
                else => {},
            }
        }
    }

    // Emit each undecoupled base rail once, walking `block.nets` for a stable
    // order rather than the (unordered) hash map.
    var missing: std.ArrayListUnmanaged([]const u8) = .empty;
    var emitted: std.StringHashMapUnmanaged(void) = .empty;
    defer emitted.deinit(allocator);
    for (block.nets) |net| {
        const base = baseNetName(net.name);
        if (!rails_with_ic.contains(base)) continue;
        if (rails_with_cap.contains(base)) continue;
        if (emitted.contains(base)) continue;
        // Decoupling may instead live inside a sub-block whose power port is
        // tied to this rail via a `(net "RAIL" "sub/PORT" …)` form.
        if (tiedSubBlockHasCap(block, base)) continue;
        try emitted.put(allocator, base, {});
        try missing.append(allocator, base);
    }
    return missing.toOwnedSlice(allocator);
}

/// True when `base` is tied — via a `(net …)` form / net-tie — to a sub-block
/// power port whose internal leaf net carries a decoupling cap. Lets a board
/// rail count a peripheral module's own bypassing (e.g. `flash/VDDIO` on V1P8).
fn tiedSubBlockHasCap(block: *const DesignBlock, base: []const u8) bool {
    for (block.net_ties) |tie| {
        const other: ?[]const u8 = if (std.mem.eql(u8, tie.a, base))
            tie.b
        else if (std.mem.eql(u8, tie.b, base))
            tie.a
        else
            null;
        if (other) |o| {
            if (std.mem.indexOfScalar(u8, o, '/') != null and subBlockNetHasCap(block, o)) {
                return true;
            }
        }
    }
    return false;
}
