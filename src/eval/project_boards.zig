//! Project-level KiCad board mapping: `<project-dir>/kicad-projects.sexp`
//! answers "where does design NAME push its board?" so the machine path does
//! not have to live inside `src/<design>.sexp`.
//!
//! The file is a flat list of one form per design, parsed with the same
//! S-expression reader as everything else:
//!
//! ```lisp
//! (kicad-pcb "board-a"  "/mnt/nas/kicad/board-a/board-a.kicad_pcb")
//! (kicad-pcb "rds3"       "/mnt/nas/kicad/rds3/rds3.kicad_pcb")
//! ```
//!
//! An entry OVERRIDES the design's own `(kicad-pcb "<path>")` form, and
//! supplies the target when the source declares none. That direction is what
//! makes the source form omittable: the checked-in design stays portable and
//! each checkout points its own boards wherever they live. The in-source form
//! keeps working unchanged, and a project with no such file behaves exactly as
//! before.
//!
//! Missing, unreadable, or malformed files resolve to "no override" rather
//! than failing a build — the same fail-open contract
//! `lib/models/model-config.json` uses, and for the same reason: a file of
//! machine-local paths must never be able to fail a build on a machine that
//! does not have one. A malformed entry is skipped, so a design it names keeps
//! whatever its own source declares.
//!
//! This module owns only the grammar; the file itself is read through the
//! evaluator's own path cache (`builders.loadFile`) so a design with fifty
//! sub-blocks parses it once.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");

const Node = ast.Node;

/// File name, relative to the project directory, holding the mapping.
pub const file_name = "kicad-projects.sexp";

/// One `(kicad-pcb "DESIGN" "PATH")` entry.
const Entry = struct {
    design: []const u8,
    path: []const u8,
};

/// The board path the mapping gives `design_name`, or null when it has none.
/// The first matching entry wins, so an appended duplicate cannot silently
/// shadow the line already in use.
pub fn lookup(nodes: []const Node, design_name: []const u8) ?[]const u8 {
    if (design_name.len == 0) return null;
    for (nodes) |node| {
        const e = entryOf(node) orelse continue;
        if (std.mem.eql(u8, e.design, design_name)) return e.path;
    }
    return null;
}

/// Read one `(kicad-pcb "DESIGN" "PATH")` form. Null for any other head, a
/// short form, or a non-string argument.
fn entryOf(node: Node) ?Entry {
    const l = node.asList() orelse return null;
    if (l.len < 3) return null;
    if (!std.mem.eql(u8, l[0].asAtom() orelse "", "kicad-pcb")) return null;
    const design = l[1].asString() orelse return null;
    const path = l[2].asString() orelse return null;
    if (design.len == 0 or path.len == 0) return null;
    return .{ .design = design, .path = path };
}

const testing = std.testing;
const parser = @import("../sexpr/parser.zig");

// spec: eval/project_boards - Project board map resolves a design name to its KiCad board path
test "project board map resolves a design name" {
    const a = testing.allocator;
    const src =
        \\(kicad-pcb "board-a" "/boards/board-a/board-a.kicad_pcb")
        \\(kicad-pcb "rds3" "/boards/rds3/rds3.kicad_pcb")
    ;
    const nodes = try parser.parse(a, src);
    defer parser.freeNodes(a, nodes);
    try testing.expectEqualStrings("/boards/rds3/rds3.kicad_pcb", lookup(nodes, "rds3").?);
    try testing.expect(lookup(nodes, "not-mapped") == null);
    try testing.expect(lookup(nodes, "") == null);
}

// spec: eval/project_boards - Project board map skips malformed entries instead of failing the build
test "project board map ignores malformed entries" {
    const a = testing.allocator;
    const src =
        \\(kicad-pcb "only-one-arg")
        \\(something-else "board-a" "/x.kicad_pcb")
        \\(kicad-pcb board-a "/unquoted-name.kicad_pcb")
        \\(kicad-pcb "board-a" "/boards/board-a.kicad_pcb")
    ;
    const nodes = try parser.parse(a, src);
    defer parser.freeNodes(a, nodes);
    try testing.expectEqualStrings("/boards/board-a.kicad_pcb", lookup(nodes, "board-a").?);
}
