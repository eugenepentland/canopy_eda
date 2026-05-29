//! `(design-doc …)` editing — add/remove `(critical-ic …)` entries in a
//! design's `.sexp` by splicing the source text directly so hand-authored
//! formatting and comments survive. Mirrors `component_info`'s requirement
//! editors; backs the `add_critical_ic` / `remove_critical_ic` MCP tools.
//!
//! The critical-IC list is the design's up-front "design document": the set
//! of parts the schematic is being built around. Adding one here makes it
//! show up in the traceability panel immediately (red across every stage)
//! so the import → requirements → place progression has something to track.

const std = @import("std");
const json_writer = @import("../json_writer.zig");
const infra_fs = @import("../infra/fs.zig");
const paths = @import("../paths.zig");
const sexpr_parser = @import("../sexpr/parser.zig");
const ast = @import("../sexpr/ast.zig");

const MAX_DESIGN_BYTES: usize = 10 * 1024 * 1024;

const ERR_DESIGN_NOT_FOUND = "design not found";
const ERR_DESIGN_PARSE = "design parse failed";
const ERR_NOT_DESIGN_BLOCK = "not a design-block";
const ERR_INVALID_COMPONENT = "invalid component name";

/// Error set for the editors. Combines allocator/JSON-writer errors with the
/// file I/O the mutators incur. Unexported — callers propagate via `!bool`.
pub const EditError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    std.fs.File.OpenError || std.fs.File.ReadError || std.fs.File.WriteError ||
    std.fs.Dir.StatFileError || error{ FileTooBig, StreamTooLong };

/// Add a `(critical-ic <component> …)` entry to the design's `(design-doc …)`
/// form, creating the `(design-doc …)` block (placed first in the body) when
/// the design has none. Rejects a duplicate component. Emits
/// `{ok:true, component, created_design_doc}` on success.
pub fn addCriticalIc(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    component: []const u8,
    role: ?[]const u8,
    rationale: ?[]const u8,
    mpn: ?[]const u8,
    out: *std.ArrayListUnmanaged(u8),
) EditError!bool {
    if (!validComponentName(component)) return writeJsonError(allocator, out, ERR_INVALID_COMPONENT);

    const path = paths.designSourcePath(allocator, project_dir, name) catch
        return writeJsonError(allocator, out, ERR_DESIGN_NOT_FOUND);
    defer allocator.free(path);
    const src = infra_fs.cwd().readFileAlloc(allocator, path, MAX_DESIGN_BYTES) catch |e| switch (e) {
        error.FileNotFound => return writeJsonError(allocator, out, ERR_DESIGN_NOT_FOUND),
        else => return e,
    };
    defer allocator.free(src);

    const nodes = sexpr_parser.parse(allocator, src) catch return writeJsonError(allocator, out, ERR_DESIGN_PARSE);
    defer sexpr_parser.freeNodes(allocator, nodes);
    const db = designBlockNode(nodes) orelse return writeJsonError(allocator, out, ERR_NOT_DESIGN_BLOCK);
    const db_children = db.asList().?;

    const form = try formatCriticalIc(allocator, component, role, rationale, mpn);
    defer allocator.free(form);

    var created_design_doc = false;
    const new_src: []u8 = blk: {
        if (findDesignDoc(db_children)) |dd| {
            const dd_children = dd.asList().?;
            // Duplicate guard: refuse a second entry for the same component.
            for (dd_children[1..]) |child| {
                if (criticalIcComponent(child)) |c| {
                    if (std.mem.eql(u8, c, component))
                        return writeJsonError(allocator, out, "component already declared in design-doc");
                }
            }
            break :blk (try spliceIntoForm(allocator, src, dd.span.offset, form)) orelse
                return writeJsonError(allocator, out, ERR_DESIGN_PARSE);
        } else {
            created_design_doc = true;
            const block_text = try std.fmt.allocPrint(allocator, "(design-doc\n    {s})", .{form});
            defer allocator.free(block_text);
            break :blk (try insertBodyForm(allocator, src, db_children, block_text)) orelse
                return writeJsonError(allocator, out, ERR_DESIGN_PARSE);
        }
    };
    defer allocator.free(new_src);

    try writeFile(path, new_src);
    const w = out.writer(allocator);
    try w.writeAll("{\"ok\":true,\"component\":");
    try json_writer.writeString(w, component);
    try w.print(",\"created_design_doc\":{s}}}", .{if (created_design_doc) "true" else "false"});
    return true;
}

/// Remove the `(critical-ic <component> …)` entry from the design's
/// `(design-doc …)` form. When it was the only entry, the now-empty
/// `(design-doc …)` form is removed too. Emits `{ok:true, component}`; returns
/// an error JSON when the design or the entry isn't found.
pub fn removeCriticalIc(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    component: []const u8,
    out: *std.ArrayListUnmanaged(u8),
) EditError!bool {
    if (!validComponentName(component)) return writeJsonError(allocator, out, ERR_INVALID_COMPONENT);

    const path = paths.designSourcePath(allocator, project_dir, name) catch
        return writeJsonError(allocator, out, ERR_DESIGN_NOT_FOUND);
    defer allocator.free(path);
    const src = infra_fs.cwd().readFileAlloc(allocator, path, MAX_DESIGN_BYTES) catch |e| switch (e) {
        error.FileNotFound => return writeJsonError(allocator, out, ERR_DESIGN_NOT_FOUND),
        else => return e,
    };
    defer allocator.free(src);

    const nodes = sexpr_parser.parse(allocator, src) catch return writeJsonError(allocator, out, ERR_DESIGN_PARSE);
    defer sexpr_parser.freeNodes(allocator, nodes);
    const db = designBlockNode(nodes) orelse return writeJsonError(allocator, out, ERR_NOT_DESIGN_BLOCK);
    const db_children = db.asList().?;

    const dd = findDesignDoc(db_children) orelse
        return writeJsonError(allocator, out, "design has no design-doc");
    const dd_children = dd.asList().?;

    var target_offset: ?u32 = null;
    var entry_count: usize = 0;
    for (dd_children[1..]) |child| {
        if (criticalIcComponent(child)) |c| {
            entry_count += 1;
            if (std.mem.eql(u8, c, component)) target_offset = child.span.offset;
        }
    }
    if (target_offset == null) return writeJsonError(allocator, out, "component not found in design-doc");

    // Removing the only entry empties the design-doc — drop the whole form.
    const remove_at: u32 = if (entry_count <= 1) dd.span.offset else target_offset.?;
    const new_src = (try removeFormSrc(allocator, src, remove_at)) orelse
        return writeJsonError(allocator, out, ERR_DESIGN_PARSE);
    defer allocator.free(new_src);

    try writeFile(path, new_src);
    const w = out.writer(allocator);
    try w.writeAll("{\"ok\":true,\"component\":");
    try json_writer.writeString(w, component);
    try w.writeAll("}");
    return true;
}

// ── AST helpers ──────────────────────────────────────────────────────────

/// The single top-level `(design-block …)` node, or null.
fn designBlockNode(nodes: []const ast.Node) ?ast.Node {
    for (nodes) |n| {
        if (n.isForm("design-block")) {
            const l = n.asList() orelse continue;
            if (l.len >= 2) return n;
        }
    }
    return null;
}

/// The `(design-doc …)` child of the design-block, or null.
fn findDesignDoc(db_children: []const ast.Node) ?ast.Node {
    for (db_children[1..]) |child| {
        if (child.isForm("design-doc")) return child;
    }
    return null;
}

/// The component atom/string of a `(critical-ic <component> …)` form, or null.
fn criticalIcComponent(node: ast.Node) ?[]const u8 {
    if (!node.isForm("critical-ic")) return null;
    const cl = node.asList() orelse return null;
    if (cl.len < 2) return null;
    return cl[1].asAtom() orelse cl[1].asString() orelse null;
}

// ── Source splicing (byte-level, formatting-preserving) ────────────────────

/// Insert `form` as the last child of the list beginning at byte `start`
/// (where `src[start] == '('`), just before its closing `)`. Returns null if
/// the form is unbalanced. Caller owns the result.
fn spliceIntoForm(allocator: std.mem.Allocator, src: []const u8, start: u32, form: []const u8) !?[]u8 {
    const end = formEnd(src, start) orelse return null;
    const close = end - 1; // index of the closing ')'
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, src[0..close]);
    try buf.appendSlice(allocator, "\n    ");
    try buf.appendSlice(allocator, form);
    try buf.appendSlice(allocator, src[close..]);
    return try buf.toOwnedSlice(allocator);
}

/// Insert `block_text` as the first body form of the design-block, just before
/// its first existing body child (children[2]). Falls back to inserting before
/// the design-block's closing `)` when the block has no body. Caller owns the
/// result.
fn insertBodyForm(allocator: std.mem.Allocator, src: []const u8, db_children: []const ast.Node, block_text: []const u8) !?[]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    if (db_children.len >= 3) {
        const at = db_children[2].span.offset;
        try buf.appendSlice(allocator, src[0..at]);
        try buf.appendSlice(allocator, block_text);
        try buf.appendSlice(allocator, "\n  ");
        try buf.appendSlice(allocator, src[at..]);
    } else {
        const close = lastParenIndex(src) orelse return null;
        try buf.appendSlice(allocator, src[0..close]);
        try buf.appendSlice(allocator, "\n  ");
        try buf.appendSlice(allocator, block_text);
        try buf.appendSlice(allocator, src[close..]);
    }
    return try buf.toOwnedSlice(allocator);
}

/// Delete the form beginning at byte `start`, plus the preceding newline +
/// indentation so no blank line is left behind. Returns null if unbalanced.
fn removeFormSrc(allocator: std.mem.Allocator, src: []const u8, start: u32) !?[]u8 {
    const end = formEnd(src, start) orelse return null;
    const del_start = std.mem.lastIndexOfScalar(u8, src[0..start], '\n') orelse start;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, src[0..del_start]);
    try buf.appendSlice(allocator, src[end..]);
    return try buf.toOwnedSlice(allocator);
}

/// Byte index one past the `)` closing the list that begins at `start`.
/// Respects string literals and `\` escapes. Returns null if unbalanced.
fn formEnd(src: []const u8, start: usize) ?usize {
    var depth: i32 = 0;
    var in_str = false;
    var i = start;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (in_str) {
            if (c == '\\') {
                i += 1;
                continue;
            }
            if (c == '"') in_str = false;
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return null;
}

/// Byte index of the last `)` in `src` (the design-block's closing paren).
fn lastParenIndex(src: []const u8) ?usize {
    var i = src.len;
    while (i > 0) {
        i -= 1;
        switch (src[i]) {
            ' ', '\t', '\r', '\n' => continue,
            ')' => return i,
            else => return null,
        }
    }
    return null;
}

// ── Formatting ─────────────────────────────────────────────────────────────

/// Render `(critical-ic <component> [(role …)] [(rationale …)] [(mpn …)])`.
fn formatCriticalIc(
    allocator: std.mem.Allocator,
    component: []const u8,
    role: ?[]const u8,
    rationale: ?[]const u8,
    mpn: ?[]const u8,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("(critical-ic ");
    if (atomSafe(component)) {
        try w.writeAll(component);
    } else {
        try w.writeByte('"');
        try writeSexprEscaped(w, component);
        try w.writeByte('"');
    }
    try writeOptClause(w, "role", role);
    try writeOptClause(w, "rationale", rationale);
    try writeOptClause(w, "mpn", mpn);
    try w.writeByte(')');
    return buf.toOwnedSlice(allocator);
}

fn writeOptClause(w: anytype, tag: []const u8, val: ?[]const u8) !void {
    if (val) |v| {
        if (v.len == 0) return;
        try w.print(" ({s} \"", .{tag});
        try writeSexprEscaped(w, v);
        try w.writeAll("\")");
    }
}

fn writeSexprEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
}

fn atomSafe(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_') return false;
    }
    return true;
}

fn validComponentName(name: []const u8) bool {
    return name.len > 0 and
        std.mem.indexOfAny(u8, name, "/\\\"") == null and
        std.mem.indexOf(u8, name, "..") == null;
}

fn writeFile(path: []const u8, contents: []const u8) !void {
    const file = try infra_fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(contents);
}

// ── JSON helpers (mirrors component_info) ──────────────────────────────────

fn writeJsonError(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), msg: []const u8) !bool {
    const w = out.writer(allocator);
    try w.writeAll("{\"ok\":false,\"error\":");
    try json_writer.writeString(w, msg);
    try w.writeAll("}");
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: serve/design_doc - formatCriticalIc renders bare-atom component with optional quoted clauses
test "formatCriticalIc emits atom component and clauses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const form = try formatCriticalIc(alloc, "stm32n6", "Main MCU", null, "STM32N657L0H3Q");
    try std.testing.expectEqualStrings(
        "(critical-ic stm32n6 (role \"Main MCU\") (mpn \"STM32N657L0H3Q\"))",
        form,
    );
}

// spec: serve/design_doc - formatCriticalIc quotes a component name that isn't a bare atom
test "formatCriticalIc quotes unsafe component name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const form = try formatCriticalIc(alloc, "weird name", null, null, null);
    try std.testing.expectEqualStrings("(critical-ic \"weird name\")", form);
}

// spec: serve/design_doc - spliceIntoForm inserts a new child before the form's closing paren
test "spliceIntoForm appends before closing paren" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src = "(design-doc\n    (critical-ic a))";
    const out = (try spliceIntoForm(alloc, src, 0, "(critical-ic b)")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(
        "(design-doc\n    (critical-ic a)\n    (critical-ic b))",
        out,
    );
}

// spec: serve/design_doc - removeFormSrc deletes a form and its preceding indentation
test "removeFormSrc drops form and leading whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const src = "(design-doc\n    (critical-ic a)\n    (critical-ic b))";
    // Offset of the second (critical-ic …) form.
    const start: u32 = @intCast(std.mem.indexOf(u8, src, "(critical-ic b)").?);
    const out = (try removeFormSrc(alloc, src, start)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("(design-doc\n    (critical-ic a))", out);
}
