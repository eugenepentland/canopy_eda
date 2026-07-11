const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;

// ── Constants ─────────────────────────────────────────────────────
const fallback_int_width: usize = 12;
const fallback_float_width: usize = 12;
const fallback_unit_val_width: usize = 14;
const short_list_max_width: usize = 72;
/// Round-trip float comparison tolerance. `printFloat` uses Zig's
/// shortest-round-trip `{d}` decimal, so a print → parse cycle reproduces the
/// exact f64 bits — the tolerance is 0 (exact) rather than the old 0.0001 abs,
/// which was coarse enough to hide the `{d:.6}` truncation of small SI literals.
const node_eq_float_tolerance: f64 = 0.0;

/// Pretty-print a list of top-level nodes as S-expression text.
pub fn print(allocator: std.mem.Allocator, nodes: []const Node) std.mem.Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    for (nodes, 0..) |node, i| {
        if (i > 0) try writer.writeByte('\n');
        try printNode(writer, node, 0);
    }
    return buf.toOwnedSlice(allocator);
}

fn printNode(writer: anytype, node: Node, indent: u32) !void {
    switch (node.tag) {
        .list => |children| {
            if (children.len == 0) {
                try writer.writeAll("()");
                return;
            }

            // Short lists (no nested lists, total estimated width < 72) print on one line.
            if (isShortList(children)) {
                try writer.writeByte('(');
                for (children, 0..) |child, i| {
                    if (i > 0) try writer.writeByte(' ');
                    try printNode(writer, child, indent + 2);
                }
                try writer.writeByte(')');
            } else {
                try writer.writeByte('(');
                try printNode(writer, children[0], indent + 2);
                for (children[1..]) |child| {
                    try writer.writeByte('\n');
                    try writeIndent(writer, indent + 2);
                    try printNode(writer, child, indent + 2);
                }
                try writer.writeByte(')');
            }
        },
        .atom => |a| try writer.writeAll(a),
        .string => |s| {
            // `Node.string` only ever carries the raw source slice the
            // tokenizer captured between the quotes (see
            // `parser.parseNode`), which is already escape-encoded for
            // the grammar. Writing it verbatim round-trips exactly;
            // re-escaping here was the cause of the printer doubling
            // `\"` to `\\\"` and breaking the parse → print → parse
            // fixed point for any note containing escaped quotes.
            try writer.writeByte('"');
            try writer.writeAll(s);
            try writer.writeByte('"');
        },
        .int => |i| try writer.print("{d}", .{i}),
        .float => |f| try printFloat(writer, f),
        .unit_val => |u| {
            try printFloat(writer, u);
            try writer.writeAll("mm");
        },
    }
}

fn printFloat(writer: anytype, f: f64) !void {
    // `{d}` is Zig's shortest-round-trip decimal: it emits the fewest digits
    // that parse back to the exact same f64, and stays non-scientific across
    // the whole realistic range (1e-7 → "0.0000001", 1e20 → the full integer),
    // so an SI literal like `100n`/`22p` survives a print → parse round-trip.
    // The old `{d:.6}` fixed-precision format collapsed any |v| < 5e-7 to
    // "0.0" and rounded away anything needing >6 decimals — silently corrupting
    // the value it also uses to rewrite `.kicad_pcb` board files in place.
    var buf: [64]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{d}", .{f}) catch {
        try writer.print("{d}", .{f});
        return;
    };
    try writer.writeAll(formatted);
    // Keep the float/int distinction: a whole-number float prints as "100",
    // so append ".0" when there's no decimal point (and no exponent, which
    // `{d}` never emits here but guard anyway).
    if (std.mem.indexOfScalar(u8, formatted, '.') == null and
        std.mem.indexOfScalar(u8, formatted, 'e') == null and
        std.mem.indexOfScalar(u8, formatted, 'n') == null) // nan/inf
    {
        try writer.writeAll(".0");
    }
}

fn estimateWidth(node: Node, depth: u32) ?usize {
    if (depth > 3) return null;
    return switch (node.tag) {
        .list => |children| {
            var w: usize = 2; // parens
            for (children, 0..) |child, i| {
                if (i > 0) w += 1; // space
                w += estimateWidth(child, depth + 1) orelse return null;
            }
            return w;
        },
        .atom => |a| a.len,
        .string => |s| s.len + 2,
        .int => |i| blk: {
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch break :blk fallback_int_width;
            break :blk s.len;
        },
        .float => |f| blk: {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch break :blk fallback_float_width;
            break :blk s.len;
        },
        .unit_val => |u| blk: {
            var buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{u}) catch break :blk fallback_unit_val_width;
            break :blk s.len + 2; // +2 for "mm"
        },
    };
}

fn isShortList(children: []const Node) bool {
    var total_width: usize = 2; // outer parens
    for (children, 0..) |child, i| {
        if (i > 0) total_width += 1;
        total_width += estimateWidth(child, 0) orelse return false;
        if (total_width > short_list_max_width) return false;
    }
    return true;
}

fn writeIndent(writer: anytype, indent: u32) !void {
    for (0..indent) |_| {
        try writer.writeByte(' ');
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: sexpr/printer - Prints a simple list as a single-line S-expression string
test "print simple list" {
    const alloc = std.testing.allocator;
    const parser = @import("parser.zig");
    const nodes = try parser.parse(alloc, "(hello 42 \"world\")");
    defer parser.freeNodes(alloc, nodes);

    const output = try print(alloc, nodes);
    defer alloc.free(output);

    try std.testing.expectEqualStrings("(hello 42 \"world\")", output);
}

// spec: sexpr/printer - Prints short nested lists inline on one line
test "print short nested lists inline" {
    const alloc = std.testing.allocator;
    const parser = @import("parser.zig");
    const nodes = try parser.parse(alloc, "(pad 1 smd rect (pos -1.25 1.75) (size 0.7 0.3))");
    defer parser.freeNodes(alloc, nodes);

    const output = try print(alloc, nodes);
    defer alloc.free(output);

    // Short enough to fit on one line
    try std.testing.expect(std.mem.indexOf(u8, output, "\n") == null);
}

// spec: sexpr/printer - Prints long nested lists with multiline indentation
test "print long nested lists multiline" {
    const alloc = std.testing.allocator;
    const parser = @import("parser.zig");
    // This is too long for one line (> 72 chars with nested lists)
    const nodes = try parser.parse(
        alloc,
        "(footprint \"QFN9-3.3x4.5\" " ++
            "(pad 1 smd rect (pos -1.25 1.75) (size 0.7 0.3)) " ++
            "(pad 2 smd rect (pos -1.25 0.75) (size 0.7 0.3)))",
    );
    defer parser.freeNodes(alloc, nodes);

    const output = try print(alloc, nodes);
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\n") != null);
}

// spec: sexpr/printer - Round-trips parse to print to parse producing identical AST
test "round-trip parse-print-parse" {
    const alloc = std.testing.allocator;
    const parser = @import("parser.zig");
    const input = "(net \"VIN\" (pin \"U1\" 6) (pin \"C1\" 1))";

    const nodes1 = try parser.parse(alloc, input);
    defer parser.freeNodes(alloc, nodes1);

    const printed = try print(alloc, nodes1);
    defer alloc.free(printed);

    const nodes2 = try parser.parse(alloc, printed);
    defer parser.freeNodes(alloc, nodes2);

    try std.testing.expectEqual(nodes1.len, nodes2.len);
    try expectNodesEqual(nodes1[0], nodes2[0]);
}

fn expectNodesEqual(a: Node, b: Node) !void {
    switch (a.tag) {
        .list => |ac| {
            const bc = b.asList() orelse return error.TestExpectedEqual;
            try std.testing.expectEqual(ac.len, bc.len);
            for (ac, bc) |ai, bi| {
                try expectNodesEqual(ai, bi);
            }
        },
        .atom => |av| try std.testing.expectEqualStrings(av, b.asAtom() orelse return error.TestExpectedEqual),
        .string => |sv| try std.testing.expectEqualStrings(sv, b.asString() orelse return error.TestExpectedEqual),
        .int => |iv| try std.testing.expectEqual(iv, switch (b.tag) {
            .int => |bv| bv,
            else => return error.TestExpectedEqual,
        }),
        .float => |fv| try std.testing.expectApproxEqAbs(fv, switch (b.tag) {
            .float => |bv| bv,
            else => return error.TestExpectedEqual,
        }, node_eq_float_tolerance),
        .unit_val => |uv| try std.testing.expectApproxEqAbs(uv, switch (b.tag) {
            .unit_val => |bv| bv,
            else => return error.TestExpectedEqual,
        }, node_eq_float_tolerance),
    }
}

// spec: sexpr/printer - Round-trips every .sexp and .kicad_pcb file under projects/designs through parse → print → parse with structurally equal AST
test "round-trip every project .sexp file" {
    const alloc = std.testing.allocator;
    const parser = @import("parser.zig");

    // Tests are normally invoked with the project root as CWD. When
    // that's not true (some sandboxes detach the runner from a real
    // working tree) the directory just isn't here — skip silently so
    // the unit-test step keeps working on its own.
    //
    // The walk covers both `.sexp` (project source) and `.kicad_pcb`
    // (KiCad PCB native format — same S-expression dialect, also under
    // `projects/designs/out/`). The PCB fixtures are the cheapest smoke
    // test for the file-based KiCad sync that mutates these files in
    // place; if parse → print → parse loses structure (hex literals like
    // 0x..._..., unit-suffix floats, layer ordering) it would silently
    // corrupt the board.
    var dir = std.fs.cwd().openDir("projects/designs", .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    var count: usize = 0;
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const is_sexp = std.mem.endsWith(u8, entry.basename, ".sexp");
        const is_pcb = std.mem.endsWith(u8, entry.basename, ".kicad_pcb");
        if (!is_sexp and !is_pcb) continue;

        const file = try dir.openFile(entry.path, .{});
        defer file.close();
        // 16 MiB cap protects the test from accidentally pointing at a
        // checked-in binary; every real source file in this tree is well
        // under that.
        const src = try file.readToEndAlloc(alloc, 16 * 1024 * 1024);
        defer alloc.free(src);

        const nodes1 = parser.parse(alloc, src) catch |err| {
            std.debug.print("parse failed for {s}: {s}\n", .{ entry.path, @errorName(err) });
            return err;
        };
        defer parser.freeNodes(alloc, nodes1);

        const printed = try print(alloc, nodes1);
        defer alloc.free(printed);

        const nodes2 = parser.parse(alloc, printed) catch |err| {
            std.debug.print("re-parse of printed output failed for {s}: {s}\n", .{ entry.path, @errorName(err) });
            return err;
        };
        defer parser.freeNodes(alloc, nodes2);

        try std.testing.expectEqual(nodes1.len, nodes2.len);
        for (nodes1, nodes2) |a, b| {
            expectNodesEqual(a, b) catch |err| {
                std.debug.print("AST mismatch in {s}\n", .{entry.path});
                return err;
            };
        }
        count += 1;
    }

    // Sanity: the walk should have found at least one file.
    try std.testing.expect(count > 0);
}
