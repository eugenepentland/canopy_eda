const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const env_mod = @import("env.zig");
const Evaluator = @import("evaluator.zig").Evaluator;
const DesignBlock = env_mod.DesignBlock;
const Node = ast.Node;
const Env = env_mod.Env;

/// Run post-build validations on a design block and its sub-blocks.
pub fn validateDesign(self: *Evaluator, block: *const DesignBlock) void {
    checkSinglePinNets(self, block);
}

/// Warn about nets that have only a single pin (dead-end connections).
fn checkSinglePinNets(self: *Evaluator, block: *const DesignBlock) void {
    for (block.nets) |net| {
        if (net.pins.len == 1) {
            const pin = net.pins[0];
            const msg = std.fmt.allocPrint(
                self.allocator,
                "Dead-end net \"{s}\" — only connected to {s} pin {s}",
                .{ net.name, pin.ref_des, pin.pin },
            ) catch continue;
            self.assertions.append(self.allocator, .{ .passed = false, .message = msg, .is_warning = true }) catch {};
        }
    }
    for (block.sub_blocks) |sb| {
        checkSinglePinNets(self, sb.block);
    }
}

/// Track the first argument of a (net ...) form for combinability warnings.
pub fn trackNetFormSource(self: *Evaluator, form_children: []const Node, env: *Env, sources: *std.StringHashMapUnmanaged(u32)) void {
    if (form_children.len < 3) return;
    const src_val = self.evalNode(form_children[1], env) catch return;
    const src = src_val.asString() orelse return;
    const gop = sources.getOrPut(self.allocator, src) catch return;
    if (!gop.found_existing) {
        gop.value_ptr.* = 1;
    } else {
        gop.value_ptr.* += 1;
    }
}

/// Emit warnings for net forms that share a common first net and could be combined.
pub fn warnCombinableNets(self: *Evaluator, sources: *std.StringHashMapUnmanaged(u32)) void {
    var iter = sources.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* > 1) {
            const msg = std.fmt.allocPrint(
                self.allocator,
                "Net \"{s}\" has {d} separate (net) forms that could be combined",
                .{ entry.key_ptr.*, entry.value_ptr.* },
            ) catch continue;
            self.assertions.append(self.allocator, .{ .passed = false, .message = msg, .is_warning = true }) catch {};
        }
    }
}
