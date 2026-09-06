//! Sibling sidecar files, autoloaded next to a design source and spliced into
//! its `(design-block …)` body.
//!
//! A board's `.sexp` accumulates two kinds of content that are not the
//! circuit: verification sign-offs, and the physical/diagram declarations
//! (`pcb-plan`, `net-class`, `net-envelope`, `stackup`, `diagram-layout`, …).
//! Measured on `boards/board-a`, those were 39% of a 1867-line file against
//! 7.6% for the actual `(section …)` bodies. `<name>.checks.sexp` already
//! carried the first kind; this module generalises that one-off into a named
//! set of three sidecars:
//!
//!   `<name>.checks.sexp`   verification forms (historical; unrestricted)
//!   `<name>.layout.sexp`   board / stackup / net-class / pcb-plan / …
//!   `<name>.diagram.sexp`  diagram-layout / group / function
//!
//! Every sidecar is optional, is spliced onto the END of the design-block
//! body, and is part of the design's input closure (page cache, fabrication
//! read-set, design archive, release source set).
//!
//! Two rules keep the split honest rather than merely possible:
//!
//!   * a form of the wrong kind is an ERROR that names the file which should
//!     hold it, so a `(section …)` cannot hide in the layout sidecar; and
//!   * a singleton form (`stackup`, `board`, `pcb-plan`, `design-rules`,
//!     `diagram-layout`) declared in two of the files is an error naming both
//!     locations, because the splice order — not the author — would otherwise
//!     decide which one wins.
//!
//! `board-role` and `hierarchical-ids` deliberately stay in the design file:
//! they change what the design IS (its identity and its role in a system),
//! not how it is laid out.
//!
//! Diagnostics and `(id …)` write-back both follow the form back to its own
//! file. See `originIndex` for how a spliced form is recognised after the
//! merge, and `kindOfPath` for the write-back side.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const Node = ast.Node;
const evaluator_mod = @import("evaluator.zig");
const Evaluator = evaluator_mod.Evaluator;
const EvalError = evaluator_mod.EvalError;

/// One autoloaded sibling of a design source.
pub const Kind = enum {
    checks,
    layout,
    diagram,

    /// The sibling extension, including the leading dot.
    pub fn ext(self: Kind) []const u8 {
        return switch (self) {
            .checks => ".checks.sexp",
            .layout => ".layout.sexp",
            .diagram => ".diagram.sexp",
        };
    }
};

/// Every sidecar kind, in splice order.
pub const kinds = [_]Kind{ .checks, .layout, .diagram };

/// The sibling extensions, for the consumers that enumerate a design's input
/// closure by suffix (`serve/page_cache.zig`, `design_archive.zig`,
/// `fab_gate.zig`, `fab_release.zig`). Derived from `Kind.ext` so a fourth
/// sidecar cannot be added without every read-set picking it up.
pub const exts = blk: {
    var out: [kinds.len][]const u8 = undefined;
    for (kinds, 0..) |k, i| out[i] = k.ext();
    break :blk out;
};

/// Top-level forms the `.layout.sexp` sidecar accepts: everything that
/// describes the physical board rather than the circuit. `kicad-pcb` is here
/// too — it names an imported board file, which is a layout input.
const layout_forms = std.StaticStringMap(void).initComptime(.{
    .{"board"},
    .{"stackup"},
    .{"net-class"},
    .{"pcb-plan"},
    .{"design-rules"},
    .{"pdn"},
    .{"module-policy"},
    .{"net-envelope"},
    .{"power-plane"},
    .{"rough"},
    .{"fabrication-layer"},
    .{"kicad-pcb"},
});

/// Top-level forms the `.diagram.sexp` sidecar accepts: the block-diagram
/// arrangement and the design-scope naming that only the diagram consumes.
const diagram_forms = std.StaticStringMap(void).initComptime(.{
    .{"diagram-layout"},
    .{"group"},
    .{"function"},
});

/// Forms that may be declared at most once per design. Splicing appends, so
/// the same form in two files would be resolved by file order rather than by
/// the author — an error instead.
const singleton_forms = std.StaticStringMap(void).initComptime(.{
    .{"stackup"},
    .{"board"},
    .{"pcb-plan"},
    .{"design-rules"},
    .{"diagram-layout"},
});

/// True when `head` may be declared only once across the design and its
/// sidecars.
pub fn isSingleton(head: []const u8) bool {
    return singleton_forms.has(head);
}

/// True when a sidecar of `kind` accepts a top-level `head`.
///
/// `.checks.sexp` predates the kind restriction and stays unrestricted: it
/// shipped as "splice whatever is in here", and narrowing it now would reject
/// files that evaluate today.
pub fn accepts(kind: Kind, head: []const u8) bool {
    return switch (kind) {
        .checks => true,
        .layout => layout_forms.has(head),
        .diagram => diagram_forms.has(head),
    };
}

/// The sidecar `head` belongs in, or null when it belongs in the design file
/// itself. Used for the "move it to …" half of a rejection message and by
/// `split-design` to decide what to move.
pub fn homeOf(head: []const u8) ?Kind {
    if (layout_forms.has(head)) return .layout;
    if (diagram_forms.has(head)) return .diagram;
    return null;
}

/// The sidecar kind `path` names, or null for any other file. A pure function
/// of the path, so `(id …)` write-back can route a minted id back to the file
/// its byte offset actually indexes without the evaluator carrying extra
/// state (see `id_insert.persistMintedIds`).
pub fn kindOfPath(path: []const u8) ?Kind {
    for (kinds) |k| {
        if (std.mem.endsWith(u8, path, k.ext())) return k;
    }
    return null;
}

/// The sidecar file an `(id …)` minted right now must be written back into,
/// or "" when the form lives in the design source. Derived from the
/// evaluator's `current_file` alone, so a module file — whose pending ids the
/// sub-block pass discards — never looks like a sidecar.
pub fn pendingIdFile(self: *const Evaluator) []const u8 {
    if (kindOfPath(self.current_file) == null) return "";
    return self.current_file;
}

/// `<design stem><ext>` for a design source path, or null when `path` is not
/// a `.sexp` (the caller frees the result).
pub fn siblingPath(allocator: std.mem.Allocator, design_path: []const u8, kind: Kind) ?[]u8 {
    if (!std.mem.endsWith(u8, design_path, ".sexp")) return null;
    if (kindOfPath(design_path) != null) return null; // never a sidecar of a sidecar
    const stem = design_path[0 .. design_path.len - ".sexp".len];
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, kind.ext() }) catch null;
}

/// One sidecar that was found on disk (or supplied from bytes) and parsed.
pub const Loaded = struct {
    kind: Kind,
    /// The sidecar's own path — reported by diagnostics raised from its forms.
    path: []const u8,
    nodes: []const Node,
};

fn headName(node: Node) []const u8 {
    const children = node.asList() orelse return "";
    if (children.len == 0) return "";
    return children[0].asAtom() orelse "";
}

/// Record a diagnostic against `file` rather than against the design being
/// evaluated, so a rejected sidecar form renders `foo.layout.sexp:12:1`.
fn rejectIn(self: *Evaluator, file: []const u8, span: ast.Span, comptime fmt: []const u8, args: anytype) void {
    const saved = self.current_file;
    self.current_file = file;
    defer self.current_file = saved;
    self.setErrorFmt(span, fmt, args);
}

/// Append every sidecar's forms to the design-block body.
///
/// Returns null when `nodes` has no `(design-block …)` to splice into (a
/// `(board …)` source, say) — the caller keeps the original node list. Returns
/// an error, with a diagnostic already located in the offending sidecar, when
/// a sidecar holds a form of the wrong kind or duplicates a singleton.
pub fn splice(
    self: *Evaluator,
    design_path: []const u8,
    nodes: []const Node,
    loaded: []const Loaded,
) EvalError!?[]const Node {
    if (loaded.len == 0) return null;

    var design_idx: ?usize = null;
    for (nodes, 0..) |n, i| if (n.isForm("design-block")) {
        design_idx = i;
        break;
    };
    const di = design_idx orelse return null;
    const original_children = nodes[di].asList() orelse return null;

    try checkKinds(self, loaded);
    try checkSingletons(self, design_path, original_children, loaded);

    var total = original_children.len;
    for (loaded) |l| total += l.nodes.len;
    const merged_children = self.allocator.alloc(Node, total) catch return EvalError.OutOfMemory;
    @memcpy(merged_children[0..original_children.len], original_children);
    var at = original_children.len;
    for (loaded) |l| {
        @memcpy(merged_children[at .. at + l.nodes.len], l.nodes);
        at += l.nodes.len;
    }

    const merged_top = self.allocator.alloc(Node, nodes.len) catch return EvalError.OutOfMemory;
    @memcpy(merged_top, nodes);
    merged_top[di] = Node.list(nodes[di].span, merged_children);
    return merged_top;
}

/// Every top-level form of every sidecar must be one that sidecar accepts.
fn checkKinds(self: *Evaluator, loaded: []const Loaded) EvalError!void {
    for (loaded) |l| {
        for (l.nodes) |node| {
            const head = headName(node);
            if (accepts(l.kind, head)) continue;
            if (homeOf(head)) |home| {
                rejectIn(self, l.path, node.span, "({s} …) belongs in the {s} sidecar, not {s}", .{
                    head, home.ext(), std.fs.path.basename(l.path),
                });
            } else {
                rejectIn(self, l.path, node.span, "({s} …) is not a {s} form — move it back into the design file", .{
                    head, l.kind.ext(),
                });
            }
            return EvalError.InvalidForm;
        }
    }
}

/// A singleton form declared in two of the files is ambiguous: report both
/// locations rather than letting splice order decide. Two copies inside ONE
/// file keep their historical (last-wins) behaviour — this is about the split,
/// not about re-linting the design file.
fn checkSingletons(
    self: *Evaluator,
    design_path: []const u8,
    design_children: []const Node,
    loaded: []const Loaded,
) EvalError!void {
    for (loaded, 0..) |l, li| {
        for (l.nodes) |node| {
            const head = headName(node);
            if (!isSingleton(head)) continue;
            if (firstIn(design_children, head)) |other| {
                return duplicate(self, l.path, node.span, head, design_path, other.span.line);
            }
            for (loaded[0..li]) |earlier| {
                if (firstIn(earlier.nodes, head)) |other| {
                    return duplicate(self, l.path, node.span, head, earlier.path, other.span.line);
                }
            }
        }
    }
}

fn firstIn(nodes: []const Node, head: []const u8) ?Node {
    for (nodes) |n| {
        if (std.mem.eql(u8, headName(n), head)) return n;
    }
    return null;
}

fn duplicate(
    self: *Evaluator,
    file: []const u8,
    span: ast.Span,
    head: []const u8,
    other_file: []const u8,
    other_line: u32,
) EvalError {
    rejectIn(self, file, span, "({s} …) is declared twice: here and at {s}:{d} — a design may declare it once", .{
        head, std.fs.path.basename(other_file), other_line,
    });
    return EvalError.InvalidForm;
}

// ── Origin attribution ─────────────────────────────────────────────────

/// Which sidecar each design-block body form came from.
///
/// The splice copies sidecar nodes into one contiguous child array, so the
/// merged form is no longer the same `Node` VALUE the sidecar's parse produced
/// — but a `.list` node's copy keeps the identical children slice pointer, and
/// that pointer is unique per parsed form. Matching on it recovers the origin
/// exactly, with no per-evaluator bookkeeping (the `Evaluator` struct is at its
/// Guardian field ceiling) and no reliance on span offsets, which repeat across
/// buffers.
pub const OriginIndex = struct {
    /// Parallel to the body-form slice; null where the form is the design's
    /// own. Empty when nothing was spliced.
    files: []const ?[]const u8 = &.{},

    /// The sidecar path form `i` came from, or null for a design-file form.
    pub fn fileAt(self: OriginIndex, i: usize) ?[]const u8 {
        if (i >= self.files.len) return null;
        return self.files[i];
    }

    /// True when nothing in this body came from a sidecar.
    pub fn isEmpty(self: OriginIndex) bool {
        return self.files.len == 0;
    }
};

fn childrenPtr(node: Node) ?[*]const Node {
    const children = node.asList() orelse return null;
    if (children.len == 0) return null;
    return children.ptr;
}

/// Build the origin index for one design-block body from the evaluator's
/// read-set. Cheap and allocation-free unless a sidecar was actually loaded.
pub fn originIndex(self: *Evaluator, body_forms: []const Node) OriginIndex {
    var any = false;
    var it = self.loaded_files.iterator();
    while (it.next()) |entry| {
        if (kindOfPath(entry.key_ptr.*) != null) {
            any = true;
            break;
        }
    }
    if (!any) return .{};

    const files = self.allocator.alloc(?[]const u8, body_forms.len) catch return .{};
    @memset(files, null);
    var found = false;
    var files_it = self.loaded_files.iterator();
    while (files_it.next()) |entry| {
        if (kindOfPath(entry.key_ptr.*) == null) continue;
        for (entry.value_ptr.*) |sidecar_node| {
            const want = childrenPtr(sidecar_node) orelse continue;
            for (body_forms, 0..) |form, i| {
                if (files[i] != null) continue;
                const have = childrenPtr(form) orelse continue;
                if (have != want) continue;
                files[i] = entry.key_ptr.*;
                found = true;
            }
        }
    }
    if (!found) {
        self.allocator.free(files);
        return .{};
    }
    return .{ .files = files };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: eval/sidecars - the layout sidecar accepts physical forms, the diagram sidecar accepts arrangement forms, and each names the other's forms as belonging elsewhere
test "sidecar kinds partition the design-scope forms" {
    try testing.expect(accepts(.layout, "pcb-plan"));
    try testing.expect(accepts(.layout, "net-envelope"));
    try testing.expect(!accepts(.layout, "diagram-layout"));
    try testing.expect(accepts(.diagram, "diagram-layout"));
    try testing.expect(accepts(.diagram, "group"));
    try testing.expect(!accepts(.diagram, "stackup"));
    // The checks sidecar predates the restriction and stays open.
    try testing.expect(accepts(.checks, "verifies"));
    try testing.expect(accepts(.checks, "stackup"));
    // Identity forms stay in the design file.
    try testing.expectEqual(@as(?Kind, null), homeOf("board-role"));
    try testing.expectEqual(@as(?Kind, null), homeOf("section"));
    try testing.expectEqual(Kind.layout, homeOf("stackup").?);
    try testing.expectEqual(Kind.diagram, homeOf("function").?);
}

// spec: eval/sidecars - a path is recognised as a sidecar by its extension so a minted id is written back to the file its byte offset indexes
test "kindOfPath recognises exactly the sidecar extensions" {
    try testing.expectEqual(Kind.checks, kindOfPath("src/boards/x.checks.sexp").?);
    try testing.expectEqual(Kind.layout, kindOfPath("src/boards/x.layout.sexp").?);
    try testing.expectEqual(Kind.diagram, kindOfPath("src/boards/x.diagram.sexp").?);
    try testing.expectEqual(@as(?Kind, null), kindOfPath("src/boards/x.sexp"));
    try testing.expectEqual(@as(?Kind, null), kindOfPath("lib/modules/x.sexp"));

    const alloc = testing.allocator;
    const p = siblingPath(alloc, "src/boards/x.sexp", .layout).?;
    defer alloc.free(p);
    try testing.expectEqualStrings("src/boards/x.layout.sexp", p);
    try testing.expectEqual(@as(?[]u8, null), siblingPath(alloc, "src/boards/x.layout.sexp", .diagram));
}

/// Write a design plus any sidecars into a fresh tmp project and evaluate the
/// design the way `netlisp` does — through `evalFile`, so the autoloader runs.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    design_path: []const u8,
    eval: Evaluator,

    fn init(arena: std.mem.Allocator, files: []const [2][]const u8) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(std.testing.io, "src");
        for (files) |f| {
            const sub = try std.fmt.allocPrint(arena, "src/{s}", .{f[0]});
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub, .data = f[1] });
        }
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
        return .{
            .tmp = tmp,
            .root = root,
            .design_path = try std.fmt.allocPrint(arena, "{s}/src/{s}", .{ root, files[0][0] }),
            .eval = Evaluator.init(arena, root),
        };
    }

    fn deinit(self: *Fixture) void {
        self.eval.deinit();
        self.tmp.cleanup();
    }

    fn block(self: *Fixture) !*const @import("env.zig").DesignBlock {
        const value = try self.eval.evalFile(self.design_path);
        return switch (value) {
            .design_block => |b| b,
            else => error.NotADesign,
        };
    }
};

const design_src =
    \\(design-block "T"
    \\  (board-role main)
    \\  (note "R1" "circuit stays here"))
;

// spec: eval/sidecars - a design's .layout.sexp and .diagram.sexp siblings are autoloaded and spliced into the design body, so their forms take effect exactly as if written inline
test "layout and diagram sidecars are spliced into the design body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try Fixture.init(arena, &.{
        .{ "t.sexp", design_src },
        .{ "t.layout.sexp", "(stackup 4 (thickness 1.6))\n(net-class \"power\" (width 0.4))\n" },
        .{ "t.diagram.sexp", "(group \"Rail\" (\"R1\" \"C1\"))\n" },
    });
    defer fx.deinit();

    const b = try fx.block();
    try testing.expectApproxEqAbs(@as(f64, 1.6), b.stackup.thickness, 1e-9);
    try testing.expectEqual(@as(usize, 1), b.net_classes.len);
    try testing.expectEqualStrings("power", b.net_classes[0].name);
    try testing.expectEqual(@as(usize, 1), b.groups.len);
    try testing.expectEqualStrings("Rail", b.groups[0].name);
    // The design's own forms are untouched by the splice.
    try testing.expectEqual(@as(usize, 1), b.notes.len);
}

// spec: eval/sidecars - a form of the wrong kind in a sidecar is refused with a diagnostic located in that sidecar and naming the file that should hold it
test "a sidecar refuses a form that belongs elsewhere" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try Fixture.init(arena, &.{
        .{ "t.sexp", design_src },
        .{ "t.layout.sexp", "(diagram-layout (row 1))\n" },
    });
    defer fx.deinit();

    try testing.expectError(error.ImportError, fx.eval.evalFile(fx.design_path));
    const diag = fx.eval.last_error.?;
    try testing.expect(std.mem.endsWith(u8, diag.file, "t.layout.sexp"));
    try testing.expect(std.mem.indexOf(u8, diag.message, ".diagram.sexp") != null);

    // A circuit form names the design file rather than another sidecar.
    var circuit = try Fixture.init(arena, &.{
        .{ "t.sexp", design_src },
        .{ "t.diagram.sexp", "(section \"Nope\")\n" },
    });
    defer circuit.deinit();
    try testing.expectError(error.ImportError, circuit.eval.evalFile(circuit.design_path));
    try testing.expect(std.mem.indexOf(u8, circuit.eval.last_error.?.message, "design file") != null);
}

// spec: eval/sidecars - a singleton design-scope form declared in two of a design's files is refused with both locations named, instead of letting splice order pick a winner
test "a singleton form declared in two files names both locations" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = try Fixture.init(arena, &.{
        .{ "t.sexp", "(design-block \"T\"\n  (stackup 4 (thickness 2.0)))" },
        .{ "t.layout.sexp", "(stackup 4 (thickness 1.6))\n" },
    });
    defer fx.deinit();

    try testing.expectError(error.ImportError, fx.eval.evalFile(fx.design_path));
    const diag = fx.eval.last_error.?;
    try testing.expect(std.mem.endsWith(u8, diag.file, "t.layout.sexp"));
    try testing.expect(std.mem.indexOf(u8, diag.message, "t.sexp:2") != null);

    // A non-singleton repeats freely across the split.
    var many = try Fixture.init(arena, &.{
        .{ "t.sexp", "(design-block \"T\"\n  (net-class \"a\" (width 0.2)))" },
        .{ "t.layout.sexp", "(net-class \"b\" (width 0.3))\n" },
    });
    defer many.deinit();
    try testing.expectEqual(@as(usize, 2), (try many.block()).net_classes.len);
}

// spec: eval/sidecars - a diagnostic raised while a spliced sidecar form evaluates reports the sidecar's own path and line, not the design file's
test "a sidecar form's evaluation error is located in the sidecar" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `(group …)` members must be ref-des STRINGS; a bare atom is a located
    // TypeError, and the location has to be the sidecar's own line 3.
    var fx = try Fixture.init(arena, &.{
        .{ "t.sexp", design_src },
        .{ "t.diagram.sexp", "\n\n(group \"Rail\" (R1))\n" },
    });
    defer fx.deinit();

    try testing.expectError(error.TypeError, fx.eval.evalFile(fx.design_path));
    const diag = fx.eval.last_error.?;
    try testing.expect(std.mem.endsWith(u8, diag.file, "t.diagram.sexp"));
    try testing.expectEqual(@as(u32, 3), diag.span.line);
}
