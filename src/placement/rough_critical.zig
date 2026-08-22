//! Physical intent for authored `(rough (critical-loop …))` closed chains.
//! A priority group answers *when* parts are placed; a critical loop additionally
//! says the members form one physical object whose aggregate spread matters.

const std = @import("std");
const env = @import("../eval/env.zig");
const flat_netlist = @import("../flat_netlist.zig");
const identity = @import("rough_identity.zig");

const gap_mm: f64 = 0.25;

fn indexOf(instances: []const flat_netlist.FlatInstance, want: []const u8) ?usize {
    for (instances, 0..) |inst, i| {
        if (identity.nameMatch(inst.ref_des, inst.origin_key, want)) return i;
    }
    return null;
}

fn quarter(rot: f64) bool {
    const q = @mod(@round(rot / 90.0), 4.0);
    return q == 1 or q == 3;
}

fn halfX(comptime Part: type, p: Part) f64 {
    return if (quarter(p.rot)) p.hh else p.hw;
}

fn halfY(comptime Part: type, p: Part) f64 {
    return if (quarter(p.rot)) p.hw else p.hh;
}

/// Pull each authored loop into one legal-looking row/column immediately
/// outside the anchor. The existing pin-aware seed supplies the edge and the
/// along-edge coordinate; this pass only removes the failure mode where a
/// parallel/series feedback chain gets split into unrelated passive islands.
pub fn cohere(
    comptime Part: type,
    arena: std.mem.Allocator,
    parts: []Part,
    instances: []const flat_netlist.FlatInstance,
    rough: env.RoughSpec,
    anchor_index: usize,
    placed: []bool,
) std.mem.Allocator.Error!void {
    if (rough.critical_loops.len == 0) return;
    const anchor = parts[anchor_index];
    for (rough.critical_loops) |loop| {
        var members: std.ArrayList(usize) = .empty;
        var locked = false;
        for (loop.members) |want| {
            const pi = indexOf(instances, want) orelse continue;
            if (pi == anchor_index) continue;
            if (parts[pi].locked) locked = true;
            var duplicate = false;
            for (members.items) |old| duplicate = duplicate or old == pi;
            if (!duplicate) try members.append(arena, pi);
        }
        if (locked or members.items.len < 2) continue;

        var mx: f64 = 0;
        var my: f64 = 0;
        for (members.items) |pi| {
            mx += parts[pi].x - anchor.x;
            my += parts[pi].y - anchor.y;
        }
        const vertical_edge = @abs(mx) >= @abs(my);
        const positive = if (vertical_edge) mx >= 0 else my >= 0;

        // Preserve the pin seed's along-edge order and mean coordinate.
        for (members.items[1..], 1..) |pi, i| {
            var j = i;
            while (j > 0) : (j -= 1) {
                const a = if (vertical_edge) parts[members.items[j - 1]].y else parts[members.items[j - 1]].x;
                const b = if (vertical_edge) parts[pi].y else parts[pi].x;
                if (a <= b) break;
                members.items[j] = members.items[j - 1];
            }
            members.items[j] = pi;
        }
        var along_mean: f64 = 0;
        var total: f64 = gap_mm * @as(f64, @floatFromInt(members.items.len - 1));
        var cross_half: f64 = 0;
        for (members.items) |pi| {
            along_mean += if (vertical_edge) parts[pi].y else parts[pi].x;
            total += 2 * (if (vertical_edge) halfY(Part, parts[pi]) else halfX(Part, parts[pi]));
            cross_half = @max(cross_half, if (vertical_edge) halfX(Part, parts[pi]) else halfY(Part, parts[pi]));
        }
        along_mean /= @as(f64, @floatFromInt(members.items.len));
        var cursor = along_mean - total / 2;
        const sign: f64 = if (positive) 1.0 else -1.0;
        const cross = if (vertical_edge)
            anchor.x + sign * (halfX(Part, anchor) + cross_half + gap_mm)
        else
            anchor.y + sign * (halfY(Part, anchor) + cross_half + gap_mm);
        for (members.items) |pi| {
            const along_half = if (vertical_edge) halfY(Part, parts[pi]) else halfX(Part, parts[pi]);
            cursor += along_half;
            if (vertical_edge) {
                parts[pi].x = cross;
                parts[pi].y = cursor;
            } else {
                parts[pi].x = cursor;
                parts[pi].y = cross;
            }
            cursor += along_half + gap_mm;
            placed[pi] = true;
        }
    }
}

/// Sum of anchor-inclusive centre-bounding-box perimeters for authored loops.
/// This is intentionally a whole-chain term: a low individual airwire total
/// cannot hide one feedback member stranded on the opposite side of the IC.
pub fn perimeter(comptime Part: type, parts: []const Part, instances: []const flat_netlist.FlatInstance, rough: env.RoughSpec) f64 {
    if (rough.anchor.len == 0 or rough.critical_loops.len == 0) return 0;
    const ai = indexOf(instances, rough.anchor) orelse return 0;
    var total: f64 = 0;
    for (rough.critical_loops) |loop| {
        var min_x = parts[ai].x;
        var max_x = parts[ai].x;
        var min_y = parts[ai].y;
        var max_y = parts[ai].y;
        var n: usize = 0;
        for (loop.members) |want| {
            const pi = indexOf(instances, want) orelse continue;
            min_x = @min(min_x, parts[pi].x);
            max_x = @max(max_x, parts[pi].x);
            min_y = @min(min_y, parts[pi].y);
            max_y = @max(max_y, parts[pi].y);
            n += 1;
        }
        if (n >= 2) total += 2 * ((max_x - min_x) + (max_y - min_y));
    }
    return total;
}
