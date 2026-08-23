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

// spec: eval/design_block - board-role remains authoritative whether it appears before or after the board geometry form
test "board role is independent of board form order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const role_first = try evaluate(allocator, "(design-block \"test\" (board-role board) (board (size 80 55)))");
    try std.testing.expectEqual(env_mod.BoardRole.board, role_first.board.role);

    const board_first = try evaluate(allocator, "(design-block \"test\" (board (size 80 55)) (board-role board))");
    try std.testing.expectEqual(env_mod.BoardRole.board, board_first.board.role);
}

// spec: eval/design_block - power-plane defaults on, and off remains authoritative before or after board geometry
test "implicit power plane is explicit and independent of board form order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const defaulted = try evaluate(allocator, "(design-block \"test\" (board (size 20 10)))");
    try std.testing.expect(defaulted.board.power_plane);
    const before = try evaluate(allocator, "(design-block \"test\" (power-plane off) (board (size 20 10)))");
    try std.testing.expect(!before.board.power_plane);
    const after = try evaluate(allocator, "(design-block \"test\" (board (size 20 10)) (power-plane off))");
    try std.testing.expect(!after.board.power_plane);
}
