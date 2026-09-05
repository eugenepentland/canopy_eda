//! `split-design` — move a design's physical and diagram declarations out of
//! its `.sexp` and into the two autoloaded sidecars.
//!
//! The flagship board measured 1867 lines of which the circuit — its
//! `(section …)` bodies — was 7.6%; `pcb-plan` alone was 20%. Those forms are
//! valid where they are, and this tool never rewrites what they SAY: it lifts
//! each top-level form out at its parser span, byte for byte, together with the
//! comment block written directly above it, and appends it to
//! `<name>.layout.sexp` or `<name>.diagram.sexp` (see `eval/sidecars.zig` for
//! which form belongs where). Everything else — the circuit, `board-role`,
//! `hierarchical-ids`, every `(id …)` — stays exactly where it was.
//!
//! The move is refused unless the ORIGINAL and the SPLIT tree evaluate to the
//! same design: the flattened netlist AND the evaluated design-scope form set
//! (stackup, net classes, pcb-plan, envelopes, diagram layout, …) are compared
//! field for field. A dry run is the default and returns the three unified
//! diffs; `write:true` writes only after that proof passes.

const std = @import("std");
const ast = @import("sexpr/ast.zig");
const parser_mod = @import("sexpr/parser.zig");
const paren_span = @import("sexpr/paren_span.zig");
const infra_fs = @import("infra/fs.zig");
const json_writer = @import("json_writer.zig");
const paths = @import("paths.zig");
const flat_netlist = @import("flat_netlist.zig");
const netlist_dump = @import("netlist_dump.zig");
const env_mod = @import("eval/env.zig");
const evaluator_mod = @import("eval/evaluator.zig");
const eval_modules = @import("eval/modules.zig");
const eval_builders = @import("eval/builders.zig");
const sidecars = @import("eval/sidecars.zig");

const Node = ast.Node;
const Evaluator = evaluator_mod.Evaluator;
const Env = env_mod.Env;

pub const ToolError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    infra_fs.AtomicFile.InitError || infra_fs.AtomicFile.FinishError;

const max_source_bytes: usize = 10 * 1024 * 1024;
const diff_context_lines: usize = 3;

/// The banner a freshly created sidecar opens with, so the file explains
/// itself to whoever opens it next.
fn header(kind: sidecars.Kind) []const u8 {
    return switch (kind) {
        .layout => "; Layout sidecar — autoloaded and spliced into the design body.\n" ++
            "; Board, stackup, net classes, PCB plan, design rules, PDN, envelopes.\n" ++
            "; See docs/sexpr-language.md → \"Sidecar files\".\n\n",
        .diagram => "; Diagram sidecar — autoloaded and spliced into the design body.\n" ++
            "; Block-diagram arrangement, design-scope groups and functions.\n" ++
            "; See docs/sexpr-language.md → \"Sidecar files\".\n\n",
        .checks => "",
    };
}

// ── Planning ───────────────────────────────────────────────────────────

/// One top-level form to move: the exact source bytes, and where they came
/// from. `start` is line-aligned and already covers the comment block written
/// immediately above the form.
const Move = struct {
    kind: sidecars.Kind,
    head: []const u8,
    start: usize,
    end: usize,
    /// 0-based line indices of `[start, end)` in the original source.
    first_line: usize,
    last_line: usize,
};

/// The complete split: what moves, and the three resulting file texts.
pub const Plan = struct {
    moves: []const Move,
    /// The design file with every move removed.
    main_text: []const u8,
    /// Per kind (indexed by `@intFromEnum`), the sidecar's full new text.
    sidecar_text: [sidecars.kinds.len]?[]const u8,
    /// Per kind, what the sidecar held before (empty when it did not exist).
    sidecar_before: [sidecars.kinds.len][]const u8,
    /// Per kind, the number of forms moved into it.
    moved: [sidecars.kinds.len]usize,
};

pub const PlanError = std.mem.Allocator.Error || error{NoDesignBlock};

/// Locate every sidecar-eligible top-level form and build the three texts.
/// `existing` is the current content of each sidecar ("" when absent), so a
/// design that already has one is appended to rather than overwritten.
pub fn planSplit(
    arena: std.mem.Allocator,
    source: []const u8,
    nodes: []const Node,
    existing: [sidecars.kinds.len][]const u8,
) PlanError!Plan {
    var design: ?Node = null;
    for (nodes) |n| if (n.isForm("design-block")) {
        design = n;
        break;
    };
    const block = design orelse return error.NoDesignBlock;
    const children = block.asList() orelse return error.NoDesignBlock;

    const starts = try lineStarts(arena, source);
    var moves: std.ArrayList(Move) = .empty;
    for (children[1..]) |child| {
        const head = headName(child) orelse continue;
        const kind = sidecars.homeOf(head) orelse continue;
        const open = child.span.offset;
        if (open >= source.len or source[open] != '(') continue;
        const close = paren_span.matchingClose(source, open, .line_semicolon) orelse continue;
        const start = withLeadingComments(source, starts, open);
        const end = throughEndOfLine(source, close + 1);
        try moves.append(arena, .{
            .kind = kind,
            .head = head,
            .start = start,
            .end = end,
            .first_line = lineOf(starts, start),
            .last_line = lineOf(starts, end -| 1),
        });
    }

    var main_text: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    for (moves.items) |m| {
        try main_text.appendSlice(arena, source[at..m.start]);
        at = m.end;
    }
    try main_text.appendSlice(arena, source[at..]);

    var plan = Plan{
        .moves = moves.items,
        .main_text = main_text.items,
        .sidecar_text = @splat(null),
        .sidecar_before = existing,
        .moved = @splat(0),
    };
    for (sidecars.kinds) |kind| {
        const slot = @backingInt(kind);
        var body: std.ArrayList(u8) = .empty;
        var count: usize = 0;
        for (moves.items) |m| {
            if (m.kind != kind) continue;
            count += 1;
            const chunk = source[m.start..m.end];
            try body.appendSlice(arena, chunk);
            // A form sharing its line with the design-block's own closing paren
            // stops at that paren, so the chunk can end mid-line; the sidecar
            // needs the newline back or the next form concatenates onto it.
            if (!std.mem.endsWith(u8, chunk, "\n")) try body.append(arena, '\n');
        }
        plan.moved[slot] = count;
        if (count == 0) continue;
        var text: std.ArrayList(u8) = .empty;
        if (existing[slot].len == 0) {
            try text.appendSlice(arena, header(kind));
        } else {
            try text.appendSlice(arena, existing[slot]);
            if (!std.mem.endsWith(u8, existing[slot], "\n")) try text.append(arena, '\n');
            try text.append(arena, '\n');
        }
        try text.appendSlice(arena, body.items);
        plan.sidecar_text[slot] = text.items;
    }
    return plan;
}

fn headName(node: Node) ?[]const u8 {
    const children = node.asList() orelse return null;
    if (children.len == 0) return null;
    return children[0].asAtom();
}

/// Byte offset of the start of every line, so a span can be widened to whole
/// lines without rescanning the file per form.
fn lineStarts(arena: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error![]const usize {
    var out: std.ArrayList(usize) = .empty;
    try out.append(arena, 0);
    for (source, 0..) |c, i| {
        if (c == '\n') try out.append(arena, i + 1);
    }
    return out.toOwnedSlice(arena);
}

fn lineOf(starts: []const usize, offset: usize) usize {
    var lo: usize = 0;
    var hi: usize = starts.len;
    while (lo + 1 < hi) {
        const mid = lo + (hi - lo) / 2;
        if (starts[mid] <= offset) lo = mid else hi = mid;
    }
    return lo;
}

/// Widen `open` back to the start of its own line, then keep absorbing whole
/// lines above it while they are pure `;` comment lines. A comment block sits
/// directly above the form it documents, so moving the form without it would
/// leave the explanation orphaned in the design file.
fn withLeadingComments(source: []const u8, starts: []const usize, open: usize) usize {
    var line = lineOf(starts, open);
    // Only widen to the line start when nothing but whitespace precedes the
    // form on that line — otherwise a second form shares the line and the
    // bytes before `open` belong to it.
    if (!blankBetween(source, starts[line], open)) return open;
    while (line > 0 and isCommentLine(source, starts, line - 1)) line -= 1;
    return starts[line];
}

fn blankBetween(source: []const u8, from: usize, to: usize) bool {
    for (source[from..to]) |c| {
        if (c != ' ' and c != '\t') return false;
    }
    return true;
}

fn isCommentLine(source: []const u8, starts: []const usize, line: usize) bool {
    const from = starts[line];
    const to = if (line + 1 < starts.len) starts[line + 1] else source.len;
    var i = from;
    while (i < to and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}
    return i < to and source[i] == ';';
}

/// Extend `from` past trailing spaces, one optional trailing `;` comment, and
/// the newline, so a removed form takes its whole line with it.
fn throughEndOfLine(source: []const u8, from: usize) usize {
    var i = from;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}
    if (i < source.len and source[i] == ';') {
        while (i < source.len and source[i] != '\n') : (i += 1) {}
    }
    if (i < source.len and source[i] == '\n') return i + 1;
    if (i == source.len) return i;
    return from;
}

// ── Equivalence proof ──────────────────────────────────────────────────

/// The design's identity for split purposes: its flattened netlist followed by
/// every evaluated design-scope declaration, field for field. Null when the
/// tree does not evaluate to a design block.
fn signature(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    design_path: []const u8,
    main_source: []const u8,
    loaded: []const sidecars.Loaded,
) ?[]const u8 {
    var eval = Evaluator.init(arena, project_dir);
    const parsed = parser_mod.parse(arena, main_source) catch return null;
    const spliced = sidecars.splice(&eval, design_path, parsed, loaded) catch return null;
    const nodes = spliced orelse parsed;
    var env = Env.init(arena, null);
    defer env.deinit();
    eval_modules.loadPassivesPrelude(&eval, &env);
    const value = eval.evalNodes(nodes, &env) catch return null;
    const block = switch (value) {
        .design_block => |b| b,
        else => return null,
    };

    var aw: std.Io.Writer.Allocating = .init(arena);
    var nets: std.ArrayList(flat_netlist.FlatNet) = .empty;
    flat_netlist.flattenAndMergeNets(arena, block, &nets) catch return null;
    const rendered = netlist_dump.lines(arena, block.name, nets.items) catch return null;
    for (rendered) |line| aw.writer.print("{s}\n", .{line}) catch return null;
    writeScope(&aw.writer, block) catch return null;
    return aw.written();
}

/// Every design-scope declaration the sidecars can carry, rendered field for
/// field. `{any}` walks the whole struct, so a field added to one of these
/// specs is covered by the proof without this list being touched — the point
/// is to catch a move that silently dropped or reordered a declaration.
fn writeScope(w: *std.Io.Writer, block: *const env_mod.DesignBlock) std.Io.Writer.Error!void {
    try w.print("scope name {s}\n", .{block.name});
    try w.print("scope board {any}\n", .{block.board});
    try w.print("scope stackup {any}\n", .{block.stackup});
    try w.print("scope design-rules {any}\n", .{block.design_rules});
    try w.print("scope pcb-plan {any}\n", .{block.pcb_plan});
    try w.print("scope rough {any}\n", .{block.rough});
    try w.print("scope diagram-layout {any}\n", .{block.layout});
    try w.print("scope revision {any}\n", .{block.revision});
    try w.print("scope kicad-pcb {any}\n", .{block.kicad_pcb_path});
    for (block.net_classes) |c| try w.print("scope net-class {any}\n", .{c});
    for (block.net_class_pins) |c| try w.print("scope net-class-pin {any}\n", .{c});
    for (block.envelopes.published) |c| try w.print("scope net-envelope {any}\n", .{c});
    for (block.pdn_intents) |c| try w.print("scope pdn {any}\n", .{c});
    for (block.fabrication_layers) |c| try w.print("scope fabrication-layer {any}\n", .{c});
    for (block.groups) |g| try w.print("scope group {any}\n", .{g});
    for (block.functions) |f| try w.print("scope function {any}\n", .{f});
}

/// Parse in-memory sidecar text into the `Loaded` shape the splice expects.
fn loadedFromText(
    arena: std.mem.Allocator,
    kind: sidecars.Kind,
    path: []const u8,
    text: []const u8,
) ?sidecars.Loaded {
    if (text.len == 0) return null;
    const nodes = parser_mod.parse(arena, text) catch return null;
    if (nodes.len == 0) return null;
    return .{ .kind = kind, .path = path, .nodes = nodes };
}

/// The first line at which two signatures disagree, or null when they match.
fn firstDifference(arena: std.mem.Allocator, before: []const u8, after: []const u8) ?[]const u8 {
    var a = std.mem.splitScalar(u8, before, '\n');
    var b = std.mem.splitScalar(u8, after, '\n');
    while (true) {
        const la = a.next();
        const lb = b.next();
        if (la == null and lb == null) return null;
        const sa = la orelse return std.fmt.allocPrint(arena, "+{s}", .{lb.?}) catch "(added)";
        const sb = lb orelse return std.fmt.allocPrint(arena, "-{s}", .{sa}) catch "(removed)";
        if (!std.mem.eql(u8, sa, sb)) return sb;
    }
}

// ── Diff rendering ─────────────────────────────────────────────────────

/// Unified diff of the design file, built from the removed ranges rather than
/// from a generic line diff: the split only ever DELETES whole lines, so the
/// hunks are known exactly.
fn removalDiff(
    arena: std.mem.Allocator,
    path: []const u8,
    source: []const u8,
    moves: []const Move,
) std.mem.Allocator.Error![]const u8 {
    if (moves.len == 0) return "";
    const old_lines = try splitLines(arena, source);
    var aw: std.Io.Writer.Allocating = .init(arena);
    aw.writer.print("--- a/{s}\n+++ b/{s}\n", .{ path, path }) catch return error.OutOfMemory;

    var removed_before: usize = 0;
    var i: usize = 0;
    while (i < moves.len) {
        // Absorb the following moves whose context windows overlap this one.
        var last = i;
        while (last + 1 < moves.len and
            moves[last + 1].first_line <= moves[last].last_line + 2 * diff_context_lines + 1) : (last += 1)
        {}
        const start = moves[i].first_line -| diff_context_lines;
        const stop = @min(old_lines.len, moves[last].last_line + diff_context_lines + 1);
        var cut: usize = 0;
        for (moves[i .. last + 1]) |m| cut += m.last_line + 1 - m.first_line;
        aw.writer.print("@@ -{d},{d} +{d},{d} @@\n", .{
            start + 1,
            stop - start,
            start + 1 - removed_before,
            stop - start - cut,
        }) catch return error.OutOfMemory;
        for (start..stop) |n| {
            const dropped = inAnyMove(moves[i .. last + 1], n);
            aw.writer.print("{s}{s}\n", .{ if (dropped) "-" else " ", old_lines[n] }) catch
                return error.OutOfMemory;
        }
        removed_before += cut;
        i = last + 1;
    }
    return aw.written();
}

fn inAnyMove(moves: []const Move, line: usize) bool {
    for (moves) |m| {
        if (line >= m.first_line and line <= m.last_line) return true;
    }
    return false;
}

/// Unified diff for a sidecar, which is only ever created or appended to.
fn additionDiff(
    arena: std.mem.Allocator,
    path: []const u8,
    before: []const u8,
    after: []const u8,
) std.mem.Allocator.Error![]const u8 {
    if (after.len == 0) return "";
    const old_lines = try splitLines(arena, before);
    const new_lines = try splitLines(arena, after);
    const kept = if (before.len == 0) 0 else old_lines.len;
    var aw: std.Io.Writer.Allocating = .init(arena);
    aw.writer.print("--- a/{s}\n+++ b/{s}\n", .{
        if (before.len == 0) "/dev/null" else path,
        path,
    }) catch return error.OutOfMemory;
    const context = @min(kept, diff_context_lines);
    aw.writer.print("@@ -{d},{d} +{d},{d} @@\n", .{
        kept - context + 1,
        context,
        kept - context + 1,
        context + (new_lines.len - kept),
    }) catch return error.OutOfMemory;
    for (old_lines[kept - context ..]) |line| aw.writer.print(" {s}\n", .{line}) catch
        return error.OutOfMemory;
    for (new_lines[kept..]) |line| aw.writer.print("+{s}\n", .{line}) catch
        return error.OutOfMemory;
    return aw.written();
}

fn splitLines(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try out.append(arena, line);
    return out.toOwnedSlice(arena);
}

// ── Tool handler ───────────────────────────────────────────────────────

/// `split-design` — the registered structured tool. Every refusal is an
/// `ok:false` envelope: an unusable name, a file that does not parse or
/// evaluate, and a split whose netlist or design-scope form set moved.
pub fn tool(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) ToolError!bool {
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    const name = stringArg(args_val, "design") orelse return refuse(&aw.writer, "design is required");
    const design_path = paths.designSourcePath(allocator, project_dir, name) catch
        return refuse(&aw.writer, "design must be a bare design name under src/");
    const source = infra_fs.cwd().readFileAlloc(allocator, design_path, max_source_bytes) catch
        return refuse(&aw.writer, "cannot read the design source");

    var sidecar_paths: [sidecars.kinds.len][]const u8 = undefined;
    var existing: [sidecars.kinds.len][]const u8 = @splat("");
    for (sidecars.kinds) |kind| {
        const slot = @backingInt(kind);
        sidecar_paths[slot] = sidecars.siblingPath(allocator, design_path, kind) orelse
            return refuse(&aw.writer, "the design source is not a .sexp");
        existing[slot] = infra_fs.cwd().readFileAlloc(allocator, sidecar_paths[slot], max_source_bytes) catch "";
    }

    const nodes = parser_mod.parse(allocator, source) catch
        return refuse(&aw.writer, "the design does not parse");
    const plan = planSplit(allocator, source, nodes, existing) catch |err| switch (err) {
        error.NoDesignBlock => return refuse(&aw.writer, "the file has no (design-block …) to split"),
        error.OutOfMemory => return error.OutOfMemory,
    };

    if (plan.moves.len > 0) {
        const before = signature(allocator, project_dir, design_path, source, try diskSidecars(allocator, design_path, sidecar_paths, existing)) orelse
            return refuse(&aw.writer, "the design does not evaluate — fix it before splitting");
        const after = signature(allocator, project_dir, design_path, plan.main_text, try splitSidecars(allocator, sidecar_paths, existing, plan)) orelse
            return refuse(&aw.writer, "the split design does not evaluate");
        if (firstDifference(allocator, before, after)) |line|
            return refuseAt(&aw.writer, "the split changes the evaluated design", line);
    }

    const want_write = boolArg(args_val, "write") orelse false;
    const written = want_write and plan.moves.len > 0;
    if (written) {
        try writeFile(design_path, plan.main_text);
        for (sidecars.kinds) |kind| {
            const slot = @backingInt(kind);
            if (plan.sidecar_text[slot]) |text| try writeFile(sidecar_paths[slot], text);
        }
    }
    try writeResult(allocator, &aw.writer, .{
        .name = name,
        .design_path = design_path,
        .sidecar_paths = sidecar_paths,
        .source = source,
        .written = written,
    }, plan);
    return true;
}

/// The sidecars as they are on disk today: the ORIGINAL tree's closure.
fn diskSidecars(
    arena: std.mem.Allocator,
    design_path: []const u8,
    sidecar_paths: [sidecars.kinds.len][]const u8,
    existing: [sidecars.kinds.len][]const u8,
) std.mem.Allocator.Error![]const sidecars.Loaded {
    _ = design_path;
    var out: std.ArrayList(sidecars.Loaded) = .empty;
    for (sidecars.kinds) |kind| {
        const slot = @backingInt(kind);
        if (loadedFromText(arena, kind, sidecar_paths[slot], existing[slot])) |l| try out.append(arena, l);
    }
    return out.toOwnedSlice(arena);
}

/// The sidecars the split would produce: the SPLIT tree's closure.
fn splitSidecars(
    arena: std.mem.Allocator,
    sidecar_paths: [sidecars.kinds.len][]const u8,
    existing: [sidecars.kinds.len][]const u8,
    plan: Plan,
) std.mem.Allocator.Error![]const sidecars.Loaded {
    var out: std.ArrayList(sidecars.Loaded) = .empty;
    for (sidecars.kinds) |kind| {
        const slot = @backingInt(kind);
        const text = plan.sidecar_text[slot] orelse existing[slot];
        if (loadedFromText(arena, kind, sidecar_paths[slot], text)) |l| try out.append(arena, l);
    }
    return out.toOwnedSlice(arena);
}

/// Replace a file atomically (tmp → rename), the way `id_insert` writes the
/// other hand-authored files this tool family touches.
fn writeFile(path: []const u8, bytes: []const u8) ToolError!void {
    var buf: [4096]u8 = undefined;
    var atomic = try infra_fs.cwd().atomicFile(path, .{ .write_buffer = &buf });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(bytes);
    try atomic.finish();
}

/// Where the split ran and what it did to disk — the half of the answer that
/// is not the `Plan` itself.
const Target = struct {
    name: []const u8,
    design_path: []const u8,
    sidecar_paths: [sidecars.kinds.len][]const u8,
    source: []const u8,
    written: bool,
};

fn writeResult(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    target: Target,
    plan: Plan,
) ToolError!void {
    try w.writeAll("{\"ok\":true,\"design\":");
    try json_writer.writeString(w, target.name);
    try w.print(",\"moved\":{d},\"written\":{},\"equivalent\":true,\"files\":[", .{ plan.moves.len, target.written });
    const main_diff = removalDiff(arena, target.design_path, target.source, plan.moves) catch "";
    try writeFileEntry(w, target.design_path, plan.moves.len, lineCount(plan.main_text), main_diff);
    for (sidecars.kinds) |kind| {
        const slot = @backingInt(kind);
        const text = plan.sidecar_text[slot] orelse continue;
        const diff = additionDiff(arena, target.sidecar_paths[slot], plan.sidecar_before[slot], text) catch "";
        try w.writeAll(",");
        try writeFileEntry(w, target.sidecar_paths[slot], plan.moved[slot], lineCount(text), diff);
    }
    try w.writeAll("]}");
}

fn writeFileEntry(
    w: *std.Io.Writer,
    path: []const u8,
    moved: usize,
    lines: usize,
    diff: []const u8,
) json_writer.WriteError!void {
    try w.writeAll("{\"path\":");
    try json_writer.writeString(w, path);
    try w.print(",\"forms\":{d},\"lines\":{d},\"diff\":", .{ moved, lines });
    try json_writer.writeString(w, diff);
    try w.writeAll("}");
}

fn lineCount(text: []const u8) usize {
    if (text.len == 0) return 0;
    var n: usize = 1;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    if (std.mem.endsWith(u8, text, "\n")) n -= 1;
    return n;
}

fn refuse(w: *std.Io.Writer, message: []const u8) json_writer.WriteError!bool {
    try w.writeAll("{\"ok\":false,\"error\":");
    try json_writer.writeString(w, message);
    try w.writeAll("}");
    return false;
}

fn refuseAt(w: *std.Io.Writer, message: []const u8, line: []const u8) json_writer.WriteError!bool {
    try w.writeAll("{\"ok\":false,\"error\":");
    try json_writer.writeString(w, message);
    try w.writeAll(",\"first_difference\":");
    try json_writer.writeString(w, line);
    try w.writeAll("}");
    return false;
}

fn namedArg(args_val: ?std.json.Value, key: []const u8) ?std.json.Value {
    const av = args_val orelse return null;
    if (av != .object) return null;
    return av.object.get(key);
}

fn stringArg(args_val: ?std.json.Value, key: []const u8) ?[]const u8 {
    const v = namedArg(args_val, key) orelse return null;
    return if (v == .string) v.string else null;
}

fn boolArg(args_val: ?std.json.Value, key: []const u8) ?bool {
    const v = namedArg(args_val, key) orelse return null;
    return if (v == .bool) v.bool else null;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const mcp_tools = @import("serve/mcp_tools.zig");

const split_board =
    \\;; Banner comment — belongs to the file, not to any form.
    \\(design-block "Split Me"
    \\  (board-role main)
    \\
    \\  ;; Four-layer construction, 1.6 mm finished.
    \\  ;; Seeded from the fab's standard stack.
    \\  (stackup 4 (thickness 1.6))
    \\
    \\  (section "Power"
    \\    (note "R1" "the circuit stays put"))
    \\
    \\  (net-class "power" (width 0.4))
    \\  (group "Rail" ("R1")))
;

/// Write `split_board` (plus optional extra files) into a tmp project.
fn splitFixture(arena: std.mem.Allocator, tmp: *testing.TmpDir, extra: []const [2][]const u8) ![]const u8 {
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/sm.sexp", .data = split_board });
    for (extra) |f| {
        const sub = try std.fmt.allocPrint(arena, "src/{s}", .{f[0]});
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub, .data = f[1] });
    }
    return tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
}

fn runTool(arena: std.mem.Allocator, project: []const u8, args_json: []const u8) !std.json.Value {
    var out: std.ArrayList(u8) = .empty;
    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{});
    _ = try tool(arena, project, args, &out);
    return std.json.parseFromSliceLeaky(std.json.Value, arena, out.items, .{});
}

// spec: split-design - each moved form leaves the design file with the comment block written directly above it and reaches its sidecar byte for byte, while the circuit and the file banner stay behind
test "the split lifts each form with its comment block, byte for byte" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const nodes = try parser_mod.parse(arena, split_board);
    const plan = try planSplit(arena, split_board, nodes, @splat(""));
    try testing.expectEqual(@as(usize, 3), plan.moves.len);

    const layout = plan.sidecar_text[@backingInt(sidecars.Kind.layout)].?;
    const diagram = plan.sidecar_text[@backingInt(sidecars.Kind.diagram)].?;
    // The two comment lines above `(stackup …)` travel with it.
    try testing.expect(std.mem.indexOf(u8, layout, ";; Four-layer construction, 1.6 mm finished.\n") != null);
    try testing.expect(std.mem.indexOf(u8, layout, "  (stackup 4 (thickness 1.6))\n") != null);
    try testing.expect(std.mem.indexOf(u8, layout, "  (net-class \"power\" (width 0.4))\n") != null);
    try testing.expect(std.mem.indexOf(u8, diagram, "  (group \"Rail\" (\"R1\"))\n") != null);

    // What stays: the banner, the circuit, and nothing that moved.
    try testing.expect(std.mem.startsWith(u8, plan.main_text, ";; Banner comment"));
    try testing.expect(std.mem.indexOf(u8, plan.main_text, "the circuit stays put") != null);
    try testing.expect(std.mem.indexOf(u8, plan.main_text, "stackup") == null);
    try testing.expect(std.mem.indexOf(u8, plan.main_text, "Four-layer construction") == null);
    try testing.expect(std.mem.indexOf(u8, plan.main_text, "net-class") == null);

    // A file with no design-block is refused rather than half-split.
    const board_only = try parser_mod.parse(arena, "(component-family cap (param-type capacitance))");
    try testing.expectError(error.NoDesignBlock, planSplit(arena, "(component-family cap (param-type capacitance))", board_only, @splat("")));
}

// spec: split-design - the default run writes nothing and returns one unified diff per file, and write true writes all three files after proving the split evaluates to the identical design
test "split-design is a dry run by default and writes three proven files" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try splitFixture(arena, &tmp, &.{});

    const dry = try runTool(arena, project, "{\"design\":\"sm\"}");
    try testing.expect(dry.object.get("ok").?.bool);
    try testing.expectEqual(@as(i64, 3), dry.object.get("moved").?.integer);
    try testing.expect(!dry.object.get("written").?.bool);
    const files = dry.object.get("files").?.array.items;
    try testing.expectEqual(@as(usize, 3), files.len);
    for (files) |f| try testing.expect(f.object.get("diff").?.string.len > 0);
    // Nothing on disk moved.
    const untouched = try tmp.dir.readFileAlloc(std.testing.io, "src/sm.sexp", arena, .limited(1 << 20));
    try testing.expectEqualStrings(split_board, untouched);
    try testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "src/sm.layout.sexp", .{}));

    const wrote = try runTool(arena, project, "{\"design\":\"sm\",\"write\":true}");
    try testing.expect(wrote.object.get("written").?.bool);
    const main_after = try tmp.dir.readFileAlloc(std.testing.io, "src/sm.sexp", arena, .limited(1 << 20));
    try testing.expect(std.mem.indexOf(u8, main_after, "stackup") == null);
    const layout_after = try tmp.dir.readFileAlloc(std.testing.io, "src/sm.layout.sexp", arena, .limited(1 << 20));
    try testing.expect(std.mem.indexOf(u8, layout_after, "(stackup 4 (thickness 1.6))") != null);
    _ = try tmp.dir.readFileAlloc(std.testing.io, "src/sm.diagram.sexp", arena, .limited(1 << 20));

    // The split design evaluates to the same thing it did inline — the very
    // property the write was gated on, re-proved from the files on disk.
    var eval = Evaluator.init(arena, project);
    const path = try std.fmt.allocPrint(arena, "{s}/src/sm.sexp", .{project});
    const value = try eval.evalFile(path);
    const b = value.design_block;
    try testing.expectApproxEqAbs(@as(f64, 1.6), b.stackup.thickness, 1e-9);
    try testing.expectEqual(@as(usize, 1), b.net_classes.len);
    try testing.expectEqual(@as(usize, 1), b.groups.len);

    // Re-running finds nothing left to move.
    const again = try runTool(arena, project, "{\"design\":\"sm\"}");
    try testing.expectEqual(@as(i64, 0), again.object.get("moved").?.integer);
}

// spec: split-design - an existing sidecar is appended to rather than overwritten, and an unreadable design or a missing name is refused with ok false
test "split-design appends to an existing sidecar and refuses what it cannot split" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try splitFixture(arena, &tmp, &.{
        .{ "sm.layout.sexp", "; hand-written already\n(pdn \"V_3V3\" (current 0.5))\n" },
    });

    const wrote = try runTool(arena, project, "{\"design\":\"sm\",\"write\":true}");
    try testing.expect(wrote.object.get("written").?.bool);
    const layout_after = try tmp.dir.readFileAlloc(std.testing.io, "src/sm.layout.sexp", arena, .limited(1 << 20));
    try testing.expect(std.mem.startsWith(u8, layout_after, "; hand-written already\n"));
    try testing.expect(std.mem.indexOf(u8, layout_after, "(pdn \"V_3V3\" (current 0.5))") != null);
    try testing.expect(std.mem.indexOf(u8, layout_after, "(stackup 4 (thickness 1.6))") != null);

    const no_name = try runTool(arena, project, "{}");
    try testing.expect(!no_name.object.get("ok").?.bool);
    const missing = try runTool(arena, project, "{\"design\":\"nope\"}");
    try testing.expect(!missing.object.get("ok").?.bool);
    const traversal = try runTool(arena, project, "{\"design\":\"../escape\"}");
    try testing.expect(!traversal.object.get("ok").?.bool);
}

// spec: split-design - the split-design tool is registered as a mutation and its declared schema round-trips through netlisp tool list
test "split-design is a registered mutation with a round-tripping schema" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(mcp_tools.isKnownTool("split-design"));
    try testing.expect(mcp_tools.isMutationTool("split-design"));

    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, mcp_tools.tools_list_result, .{});
    var schema: ?std.json.ObjectMap = null;
    for (root.object.get("tools").?.array.items) |t| {
        if (std.mem.eql(u8, t.object.get("name").?.string, "split-design"))
            schema = t.object.get("inputSchema").?.object;
    }
    const props = schema.?.get("properties").?.object;
    try testing.expect(props.get("design") != null);
    try testing.expect(props.get("write") != null);
    try testing.expectEqualStrings("design", schema.?.get("required").?.array.items[0].string);
}
