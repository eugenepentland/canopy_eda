const std = @import("std");
const parser = @import("../sexpr/parser.zig");
const design_block = @import("design_block.zig");
const evaluator_mod = @import("evaluator.zig");
const env_mod = @import("env.zig");

fn evaluate(allocator: std.mem.Allocator, source: []const u8) !*env_mod.DesignBlock {
    const nodes = try parser.parse(allocator, source);
    const children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var evaluator = evaluator_mod.Evaluator.init(allocator, "");
    var env = env_mod.Env.init(allocator, null);
    return (try design_block.evalDesignBlock(&evaluator, children[1..], &env)).design_block;
}

// spec: eval/design_block - board-role form sets the explicit board/subcircuit role
test "design-block (board-role board) sets the board role" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const block = try evaluate(arena.allocator(), "(design-block \"test\" (board-role board))");
    try std.testing.expectEqual(env_mod.BoardRole.board, block.board.role);
}

// spec: eval/design_block - board-role defaults to subcircuit when the form is absent
test "design-block without (board-role …) defaults to subcircuit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const block = try evaluate(arena.allocator(), "(design-block \"test\" (board (size 80 55)))");
    try std.testing.expectEqual(env_mod.BoardRole.subcircuit, block.board.role);
}
