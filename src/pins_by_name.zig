//! `rewrite-pins-by-name` — rewrite a design/module source's numeric pad tokens
//! into the pinout FUNCTION NAME the evaluator already resolves them through.
//!
//! The language has always accepted `(pin ILIM "GND")`, yet the corpus writes
//! pads by number an order of magnitude more often and then repeats the pinout
//! in a trailing comment — `(pin 5 "GND") ;; ILIM` beside
//! `(strap-ok 5 "ILIM->GND …")`. Spelling the function name makes the strap and
//! no-connect sign-offs self-documenting, and makes a pad renumber a build
//! error instead of a silent re-point.
//!
//! ## How the rewrite stays safe
//!
//! Two independent proofs, both required:
//!
//!   1. **Per token.** A pad is rewritten only when the evaluator's OWN
//!      resolver, re-run on the proposed spelling, returns the very pad the
//!      original token resolved to (`resolveToken` below mirrors
//!      `eval/instance.resolvePinName` and `eval/builders.resolveTargetPin`,
//!      the two rules the language actually has), the function name is unique
//!      in the pinout, and the replacement text re-tokenizes to itself.
//!   2. **Per file.** The ORIGINAL and the REWRITTEN source are both evaluated
//!      and flattened, and their netlists — plus the resolved placement/sign-off
//!      bindings, which no net carries — must match line for line. A file that
//!      does not evaluate, or whose netlist moves, is refused rather than
//!      written.
//!
//! Text is spliced at the AST byte spans (the `id_insert.zig` pattern), so
//! every comment, blank line and column of alignment outside the replaced
//! token survives byte for byte.

const std = @import("std");
const ast = @import("sexpr/ast.zig");
const parser_mod = @import("sexpr/parser.zig");
const infra_fs = @import("infra/fs.zig");
const json_writer = @import("json_writer.zig");
const flat_netlist = @import("flat_netlist.zig");
const netlist_dump = @import("netlist_dump.zig");
const env_mod = @import("eval/env.zig");
const evaluator_mod = @import("eval/evaluator.zig");
const eval_modules = @import("eval/modules.zig");
const eval_builders = @import("eval/builders.zig");
const sidecars = @import("eval/sidecars.zig");
const instance_mod = @import("eval/instance.zig");
const eval_ids = @import("eval/ids.zig");

const Node = ast.Node;
const Evaluator = evaluator_mod.Evaluator;
const Env = env_mod.Env;

/// Pad id → function name, the shape `lib/pinouts` loads into and the shape
/// `eval/instance.matchPinName` resolves against.
const PinMap = std.StringHashMapUnmanaged([]const u8);

const max_source_bytes: usize = 10 * 1024 * 1024;
/// Reported skips are capped so one board cannot answer with thousands of
/// lines; the count that did not fit is reported alongside.
const max_reported_skips: usize = 200;
const diff_context_lines: usize = 3;

/// Everything the rewrite half can fail with: parsing the source, building the
/// plan, rendering the diff, and (only on `write:true`) replacing the file.
pub const ToolError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    infra_fs.AtomicFile.InitError || infra_fs.AtomicFile.FinishError;

/// Diff rendering. `DiffShapeChanged` is a hard invariant failure, not user
/// error: every splice replaces a token WITHIN a line, so the two texts must
/// have the same line count.
const DiffError = std.mem.Allocator.Error || std.Io.Writer.Error || error{DiffShapeChanged};

// ── Decisions ──────────────────────────────────────────────────────────

/// One reported reason a pad token was left alone.
const Skip = struct {
    ref: []const u8,
    pad: []const u8,
    reason: []const u8,
};

/// How the evaluator turns an authored token into a physical pad.
///
///  * `own` — `(pin …)`, `(strap-ok …)`, `(nc-ok …)` and `(near … (own PAD))`
///    resolve against the DECLARING part's pinout, function name first
///    (`eval/instance.resolvePinName`).
///  * `target` — `(near "REF" PAD)` and `(decouples "REF" PAD)` resolve against
///    the NAMED part's pinout, and a token that is already a pad id wins
///    BEFORE any function-name lookup (`eval/builders.resolveTargetPin`).
const Resolver = enum { own, target };

/// The pad `token` binds to under `kind`. This is the language's rule, not a
/// re-derivation: the function-name half is `matchPinName`, the shared helper
/// both evaluator paths call.
fn resolveToken(pinout: *const PinMap, kind: Resolver, token: []const u8) []const u8 {
    if (kind == .target and pinout.contains(token)) return token;
    const m = instance_mod.matchPinName(pinout, token) orelse return token;
    return m.pad;
}

/// What to do with one authored pad token.
const Decision = union(enum) {
    /// Replace the token's source text with this exact spelling.
    rewrite: []const u8,
    /// Already a function name (or nothing would change) — not a finding.
    unchanged,
    /// Left alone, with the reason a caller should see.
    skip: []const u8,
};

/// Decide one token. Every rejection is named, and the acceptance is gated on
/// re-resolving the PROPOSED spelling back to the pad the ORIGINAL bound to —
/// so a rewrite can never move a pin, whatever the pinout looks like.
fn decide(arena: std.mem.Allocator, pinout: *const PinMap, kind: Resolver, raw: []const u8) Decision {
    const pad = resolveToken(pinout, kind, raw);
    const fn_name = pinout.get(pad) orelse return .{ .skip = "pad is not in the part's pinout" };
    if (fn_name.len == 0) return .{ .skip = "pad has no function name" };
    if (std.mem.eql(u8, fn_name, raw)) return .unchanged;
    if (isSelfNamed(pad, fn_name)) return .{ .skip = "positional pad: the pinout names it after its own number" };
    const m = instance_mod.matchPinName(pinout, fn_name) orelse return .{ .skip = "function name resolves to no pad" };
    if (m.matches != 1) return .{ .skip = "function name repeats on other pads" };
    if (!std.mem.eql(u8, resolveToken(pinout, kind, fn_name), pad))
        return .{ .skip = "the function name would resolve to a different pad" };
    const spelled = spellToken(arena, fn_name) orelse return .{ .skip = "function name has no round-tripping token spelling" };
    return .{ .rewrite = spelled };
}

/// The source text that reads back as exactly `name`: the bare atom when the
/// tokenizer returns it unchanged, else a quoted string, else nothing. A name
/// the parser would re-read as something else (`5V` becomes an SI value) is
/// never spliced.
fn spellToken(arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
    if (tokenReadsBack(arena, name, name)) return name;
    const quoted = std.fmt.allocPrint(arena, "\"{s}\"", .{name}) catch return null;
    if (tokenReadsBack(arena, quoted, name)) return quoted;
    return null;
}

/// True when parsing `text` yields exactly one token whose pad spelling is `want`.
fn tokenReadsBack(arena: std.mem.Allocator, text: []const u8, want: []const u8) bool {
    const nodes = parser_mod.parse(arena, text) catch return false;
    if (nodes.len != 1) return false;
    const got = nodes[0].tokenText(arena) orelse return false;
    return std.mem.eql(u8, got, want);
}

// ── Source spans ───────────────────────────────────────────────────────

/// The half-open byte range a token occupies in `source`, starting at the span
/// offset the parser recorded. A quoted string covers both quotes; every other
/// token runs to the next delimiter.
fn tokenExtent(source: []const u8, offset: usize) ?[2]usize {
    if (offset >= source.len) return null;
    if (source[offset] == '"') return stringExtent(source, offset);
    var end = offset;
    while (end < source.len and !isDelimiter(source[end])) end += 1;
    if (end == offset) return null;
    return .{ offset, end };
}

fn stringExtent(source: []const u8, offset: usize) ?[2]usize {
    var i = offset + 1;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\\') {
            i += 1;
            continue;
        }
        if (source[i] == '"') return .{ offset, i + 1 };
    }
    return null;
}

fn isDelimiter(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or
        c == '(' or c == ')' or c == '"' or c == ';';
}

// ── Planning ───────────────────────────────────────────────────────────

const Edit = struct { start: usize, end: usize, text: []const u8 };

/// The computed rewrite of one file: the new bytes, how many tokens moved, and
/// why the rest did not.
const Plan = struct {
    rewritten: []const u8,
    rewrites: usize = 0,
    skips: []const Skip = &.{},
    skips_omitted: usize = 0,
    /// Instances whose component resolves to no `lib/pinouts` file at all.
    parts_without_pinout: usize = 0,
    /// Instances whose pinout names every pad after itself (a positional
    /// connector / generic passive) — nothing there is a function name.
    positional_parts: usize = 0,
};

/// Mutable planning state, threaded through the per-form walkers so each stays
/// short enough to read in one screen.
const Planner = struct {
    arena: std.mem.Allocator,
    eval: *Evaluator,
    source: []const u8,
    refs: ?[]const []const u8,
    /// Ref-des → component family for every instance in the file, so a
    /// `(near "U1" …)` on a capacitor can reach U1's pinout.
    families: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Family → owned pinout snapshot. Owned because `ids.getSymbolPins`
    /// returns a pointer into a cache that rehashes as further pinouts load.
    pinouts: std.StringHashMapUnmanaged(?*PinMap) = .empty,
    edits: std.ArrayList(Edit) = .empty,
    skips: std.ArrayList(Skip) = .empty,
    skips_omitted: usize = 0,
    parts_without_pinout: usize = 0,
    positional_parts: usize = 0,

    /// Record one reason a pad was left alone. An allocation failure counts the
    /// skip as omitted rather than losing it: the reported total must never
    /// read as "nothing was skipped".
    fn note(self: *Planner, ref: []const u8, pad: []const u8, reason: []const u8) void {
        if (self.skips.items.len >= max_reported_skips) {
            self.skips_omitted += 1;
            return;
        }
        self.skips.append(self.arena, .{ .ref = ref, .pad = pad, .reason = reason }) catch {
            self.skips_omitted += 1;
            return;
        };
    }

    fn wanted(self: *const Planner, ref: []const u8) bool {
        const list = self.refs orelse return true;
        for (list) |r| if (std.mem.eql(u8, r, ref)) return true;
        return false;
    }
};

/// The component family an `(instance "REF" X …)` names: a bare atom, or the
/// head of a `(family "value" …)` call.
fn componentFamily(node: Node) ?[]const u8 {
    if (node.asAtom()) |a| return a;
    const children = node.asList() orelse return null;
    if (children.len == 0) return null;
    return children[0].asAtom();
}

/// Load a component's reverse pinout the way `eval/instance.buildInstance`
/// does — resolve the import, prefer the declared `(pinout …)` over the
/// `(symbol …)`, then read `lib/pinouts/<name>.sexp` — and snapshot it into
/// arena memory the caller owns.
fn loadPinout(self: *Planner, family: []const u8) ?*PinMap {
    if (self.pinouts.get(family)) |cached| return cached;
    const loaded = readPinout(self, family);
    // A failed memo only costs a re-read; the answer itself still stands.
    self.pinouts.put(self.arena, family, loaded) catch return loaded;
    return loaded;
}

fn readPinout(self: *Planner, family: []const u8) ?*PinMap {
    var env = Env.init(self.eval.allocator, null);
    defer env.deinit();
    eval_modules.resolveImport(self.eval, family, &env) catch return null;
    const cd = self.eval.component_cache.get(family) orelse return null;
    const lookup = if (cd.pinout_name.len > 0) cd.pinout_name else cd.symbol_name;
    if (lookup.len == 0) return null;
    const live = eval_ids.getSymbolPins(self.eval, lookup) orelse return null;
    return snapshot(self.arena, live);
}

/// Copy a live pinout into arena memory. The evaluator hands back a pointer
/// into `symbol_pin_cache`, which rehashes when the next part's pinout loads —
/// and this planner holds two pinouts at once for `(near "REF" PAD)`.
fn snapshot(arena: std.mem.Allocator, live: *const PinMap) ?*PinMap {
    const out = arena.create(PinMap) catch return null;
    out.* = .empty;
    var it = live.iterator();
    while (it.next()) |e| out.put(arena, e.key_ptr.*, e.value_ptr.*) catch return null;
    return out;
}

/// True when a pad's "function name" is only its own number again — either
/// literally (`(pin 4 "4")`) or in the importer's zero-padded spelling
/// (`(pin 09 "09")`, whose pad id reads back as `9`). `eval/instance`'s own
/// `summarisePinout` calls the same shape positional. Such a name documents
/// nothing, so writing it would trade a readable number for an unreadable one.
fn isSelfNamed(pad: []const u8, fn_name: []const u8) bool {
    return std.mem.eql(u8, fn_name, pad) or isAllDigits(fn_name);
}

fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// True when EVERY pad of a part is self-named — a positional connector or a
/// generic two-terminal passive. Nothing in such a part is a name worth
/// writing, and reporting each of a 40-way connector's pads would bury the
/// real findings, so the whole part is counted once instead.
fn isPositional(pinout: *const PinMap) bool {
    var it = pinout.iterator();
    while (it.next()) |e| {
        if (!isSelfNamed(e.key_ptr.*, e.value_ptr.*)) return false;
    }
    return true;
}

/// Compute the rewrite for `source`. Nothing is written and nothing is
/// evaluated here: this is the pure text half, so it is directly testable.
fn planRewrite(
    arena: std.mem.Allocator,
    eval: *Evaluator,
    source: []const u8,
    refs: ?[]const []const u8,
) parser_mod.ParseError!Plan {
    const nodes = try parser_mod.parse(arena, source);
    var p = Planner{ .arena = arena, .eval = eval, .source = source, .refs = refs };
    collectFamilies(&p, nodes);
    walkNodes(&p, nodes);
    return .{
        .rewritten = try applyEdits(arena, source, p.edits.items),
        .rewrites = p.edits.items.len,
        .skips = p.skips.items,
        .skips_omitted = p.skips_omitted,
        .parts_without_pinout = p.parts_without_pinout,
        .positional_parts = p.positional_parts,
    };
}

/// Record every `(instance "REF" family …)` in the file. A ref declared twice
/// with different families is left unmapped, so a `(near …)` naming it resolves
/// nothing rather than guessing the wrong part's pinout.
fn collectFamilies(p: *Planner, nodes: []const Node) void {
    for (nodes) |node| {
        if (node.isForm("instance")) {
            const c = node.asList().?;
            if (c.len >= 3) rememberFamily(p, c);
        }
        if (node.asList()) |children| collectFamilies(p, children);
    }
}

fn rememberFamily(p: *Planner, children: []const Node) void {
    const ref = children[1].asText() orelse return;
    const family = componentFamily(children[2]) orelse return;
    const gop = p.families.getOrPut(p.arena, ref) catch return;
    if (gop.found_existing and !std.mem.eql(u8, gop.value_ptr.*, family)) {
        gop.value_ptr.* = "";
        return;
    }
    gop.value_ptr.* = family;
}

fn walkNodes(p: *Planner, nodes: []const Node) void {
    for (nodes) |node| {
        if (node.isForm("instance")) {
            planInstance(p, node.asList().?);
            continue;
        }
        if (node.asList()) |children| walkNodes(p, children);
    }
}

/// Plan every pad token in one `(instance "REF" family …)` body.
fn planInstance(p: *Planner, children: []const Node) void {
    if (children.len < 3) return;
    const ref = children[1].asText() orelse return;
    if (!p.wanted(ref)) return;
    const family = componentFamily(children[2]) orelse return;
    const own = ownPinout(p, family);
    for (children[3..]) |form| planBodyForm(p, ref, own, form);
}

/// The declaring part's own pinout, or null when it has none worth reading —
/// counted so the summary can say why. Null is NOT the end of the instance: a
/// `(decouples "U1" 1)` on a generic capacitor resolves through U1's pinout,
/// and that is exactly the binding this rewrite most wants to spell out.
fn ownPinout(p: *Planner, family: []const u8) ?*PinMap {
    const map = loadPinout(p, family) orelse {
        p.parts_without_pinout += 1;
        return null;
    };
    if (isPositional(map)) {
        p.positional_parts += 1;
        return null;
    }
    return map;
}

/// One sub-form of an instance body. `(part …)` recurses because its inner
/// `(pin …)` forms wire exactly like top-level ones.
fn planBodyForm(p: *Planner, ref: []const u8, pinout: ?*PinMap, form: Node) void {
    if (form.isForm("near")) return planNearForm(p, ref, pinout, form);
    if (form.isForm("decouples")) return planTargetForm(p, ref, form, 2);
    const own = pinout orelse return;
    if (form.isForm("pin")) return planPinForm(p, ref, own, form);
    if (form.isForm("part")) {
        for (form.asList().?[2..]) |child| {
            if (child.isForm("pin")) planPinForm(p, ref, own, child);
        }
        return;
    }
    if (form.isForm("strap-ok") or form.isForm("nc-ok")) {
        const c = form.asList().?;
        if (c.len >= 3) planToken(p, ref, own, .own, c[1]);
    }
}

/// `(pin PAD… "NET" [(as "FN")] [(i-typ …) (i-max …) (load …)])` — every pad
/// token before the net name, multi-pad shorthand included.
fn planPinForm(p: *Planner, ref: []const u8, pinout: *PinMap, form: Node) void {
    const children = form.asList().?;
    if (children.len < 3) return;
    var env = Env.init(p.eval.allocator, null);
    defer env.deinit();
    const t = instance_mod.parsePinTail(p.eval, children, &env) catch return;
    if (t.tail < 3) return;
    for (children[1 .. t.tail - 1]) |token| {
        if (token.isForm("as")) continue;
        planToken(p, ref, pinout, .own, token);
    }
}

/// `(near "REF" PAD [(own PAD)])` — the target pad resolves through the NAMED
/// part's pinout, the `(own …)` pad through this part's own.
fn planNearForm(p: *Planner, ref: []const u8, pinout: ?*PinMap, form: Node) void {
    const c = form.asList().?;
    if (c.len < 3) return;
    planTargetForm(p, ref, form, 2);
    const own = pinout orelse return;
    for (c[3..]) |extra| {
        const oc = extra.asList() orelse continue;
        if (oc.len == 2 and std.mem.eql(u8, oc[0].asAtom() orelse "", "own"))
            planToken(p, ref, own, .own, oc[1]);
    }
}

/// `(near "REF" PAD)` / `(decouples "REF" PAD)` — resolve `PAD` against the
/// pinout of the part the form NAMES, which the declaring passive does not have.
fn planTargetForm(p: *Planner, ref: []const u8, form: Node, pad_index: usize) void {
    const c = form.asList().?;
    if (c.len <= pad_index) return;
    const target = c[1].asText() orelse return;
    const family = p.families.get(target) orelse return;
    if (family.len == 0) return;
    const pinout = loadPinout(p, family) orelse return;
    if (isPositional(pinout)) return;
    planToken(p, ref, pinout, .target, c[pad_index]);
}

/// Decide one token and, on a rewrite, queue the span splice.
fn planToken(p: *Planner, ref: []const u8, pinout: *PinMap, kind: Resolver, token: Node) void {
    const raw = token.tokenText(p.arena) orelse return;
    const extent = tokenExtent(p.source, token.span.offset) orelse return;
    // The span must actually cover the token the AST reported. Splicing at an
    // offset whose bytes read back as something else would corrupt the file, so
    // a disagreement is refused rather than trusted.
    if (!tokenReadsBack(p.arena, p.source[extent[0]..extent[1]], raw))
        return p.note(ref, raw, "the source span does not read back as this pad token");
    switch (decide(p.arena, pinout, kind, raw)) {
        .unchanged => {},
        .skip => |reason| p.note(ref, raw, reason),
        // A dropped edit would be an unreported rewrite, so it is recorded as
        // a skip rather than silently vanishing from both counts.
        .rewrite => |text| p.edits.append(p.arena, .{
            .start = extent[0],
            .end = extent[1],
            .text = text,
        }) catch p.note(ref, raw, "out of memory while queueing the splice"),
    }
}

/// Splice every edit into the original bytes, highest offset first so the
/// earlier offsets stay valid — the `id_insert.applyInserts` discipline, with
/// a replaced range rather than an insertion point.
fn applyEdits(arena: std.mem.Allocator, source: []const u8, edits: []Edit) std.mem.Allocator.Error![]const u8 {
    if (edits.len == 0) return source;
    std.mem.sort(Edit, edits, {}, editAfter);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, source);
    for (edits) |e| {
        if (e.end > out.items.len) continue;
        out.replaceRange(arena, e.start, e.end - e.start, e.text) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice(arena);
}

fn editAfter(_: void, a: Edit, b: Edit) bool {
    return a.start > b.start;
}

// ── Unified diff ───────────────────────────────────────────────────────

/// A unified diff of `before` vs `after`. Every splice replaces a token WITHIN
/// one line, so the two texts always have the same line count and the diff is
/// exactly the changed lines with their context — no alignment search, and no
/// way for a hunk header to disagree with the bytes.
fn unifiedDiff(
    arena: std.mem.Allocator,
    path: []const u8,
    before: []const u8,
    after: []const u8,
) DiffError![]const u8 {
    const old_lines = try splitLines(arena, before);
    const new_lines = try splitLines(arena, after);
    if (old_lines.len != new_lines.len) return error.DiffShapeChanged;

    var aw: std.Io.Writer.Allocating = .init(arena);
    var i: usize = 0;
    while (i < old_lines.len) {
        if (std.mem.eql(u8, old_lines[i], new_lines[i])) {
            i += 1;
            continue;
        }
        if (aw.written().len == 0) try aw.writer.print("--- a/{s}\n+++ b/{s}\n", .{ path, path });
        i = try writeHunk(&aw.writer, old_lines, new_lines, i);
    }
    return aw.written();
}

/// Emit the hunk that starts at the changed line `first`, absorbing any further
/// change that falls within twice the context window, and return the index just
/// past it.
fn writeHunk(
    w: *std.Io.Writer,
    old_lines: []const []const u8,
    new_lines: []const []const u8,
    first: usize,
) !usize {
    var last = first;
    var probe = first + 1;
    while (probe < old_lines.len and probe <= last + 2 * diff_context_lines + 1) : (probe += 1) {
        if (!std.mem.eql(u8, old_lines[probe], new_lines[probe])) last = probe;
    }
    const start = first -| diff_context_lines;
    const stop = @min(old_lines.len, last + diff_context_lines + 1);
    try w.print("@@ -{d},{d} +{d},{d} @@\n", .{ start + 1, stop - start, start + 1, stop - start });
    for (start..stop) |n| {
        if (std.mem.eql(u8, old_lines[n], new_lines[n])) {
            try w.print(" {s}\n", .{old_lines[n]});
        } else {
            try w.print("-{s}\n+{s}\n", .{ old_lines[n], new_lines[n] });
        }
    }
    return stop;
}

fn splitLines(arena: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try out.append(arena, line);
    return out.toOwnedSlice(arena);
}

// ── Netlist-equivalence proof ──────────────────────────────────────────

/// Which resolver the file's own kind needs. A board under `src/` evaluates as
/// a design; a `lib/modules/` file has to be instantiated.
const FileKind = enum { design, module };

/// A file the tool accepts: its kind, its block name, and its path.
const Target = struct {
    kind: FileKind,
    name: []const u8,
    path: []const u8,
};

/// Classify a project-relative `.sexp` path. Rejects anything outside
/// `lib/modules/` and `src/`, any traversal, and any non-source file.
fn classify(arena: std.mem.Allocator, project_dir: []const u8, file: []const u8) ?Target {
    if (!std.mem.endsWith(u8, file, ".sexp")) return null;
    if (std.mem.indexOf(u8, file, "..") != null) return null;
    if (file.len == 0 or file[0] == '/' or std.mem.indexOfScalar(u8, file, '\\') != null) return null;
    const kind: FileKind = if (std.mem.startsWith(u8, file, "lib/modules/"))
        .module
    else if (std.mem.startsWith(u8, file, "src/"))
        .design
    else
        return null;
    const base = std.fs.path.basename(file);
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ project_dir, file }) catch return null;
    return .{ .kind = kind, .name = base[0 .. base.len - ".sexp".len], .path = path };
}

/// Evaluate `source` AS the file at `target` and render the comparison lines:
/// the flattened netlist (`netlist_dump`'s own renderer, so this cannot drift
/// from `netlisp netlist-dump`) followed by every resolved binding — the
/// `(decouples …)`, `(near …)`, `(strap-ok …)` and `(nc-ok …)` pads, which no
/// net carries and which this rewrite touches. Null when it does not evaluate.
fn signature(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    target: Target,
    source: []const u8,
) ?[]const []const u8 {
    var eval = Evaluator.init(arena, project_dir);
    const block = evalBlock(&eval, target, source) orelse return null;
    var nets: std.ArrayList(flat_netlist.FlatNet) = .empty;
    flat_netlist.flattenAndMergeNets(arena, block, &nets) catch return null;
    var out: std.ArrayList([]const u8) = .empty;
    const rendered = netlist_dump.lines(arena, target.name, nets.items) catch return null;
    out.appendSlice(arena, rendered) catch return null;
    appendBindingLines(arena, block, "", &out) catch return null;
    std.mem.sort([]const u8, out.items, {}, lessLine);
    return out.items;
}

fn lessLine(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn evalBlock(eval: *Evaluator, target: Target, source: []const u8) ?*env_mod.DesignBlock {
    const value = switch (target.kind) {
        .design => evalDesignSource(eval, target.path, source) orelse return null,
        .module => instantiateModuleSource(eval, target.name, source) orelse return null,
    };
    return switch (value) {
        .design_block => |b| b,
        else => null,
    };
}

/// Evaluate a design source exactly as `Evaluator.evalFile` would, including
/// the sibling sidecar splice, but from bytes rather than disk.
fn evalDesignSource(eval: *Evaluator, path: []const u8, source: []const u8) ?env_mod.Value {
    const parsed = parser_mod.parse(eval.allocator, source) catch return null;
    const nodes = spliceSiblingSidecars(eval, path, parsed);
    var env = Env.init(eval.allocator, null);
    defer env.deinit();
    eval_modules.loadPassivesPrelude(eval, &env);
    return eval.evalNodes(nodes, &env) catch null;
}

fn spliceSiblingSidecars(eval: *Evaluator, path: []const u8, nodes: []const Node) []const Node {
    if (!std.mem.endsWith(u8, path, ".sexp")) return nodes;
    var buf: [sidecars.kinds.len]sidecars.Loaded = undefined;
    const loaded = eval_builders.loadSidecars(eval, path, &buf);
    const merged = sidecars.splice(eval, path, nodes, loaded) catch return nodes;
    return merged orelse nodes;
}

/// Instantiate a `lib/modules/` file's `(defmodule …)` from bytes with zero
/// arguments, the way `eval/modules.instantiateStandalone` does from disk: the
/// module body is evaluated in a heap env that outlives the definition, then
/// called so every `(param default)` supplies its value.
fn instantiateModuleSource(eval: *Evaluator, name: []const u8, source: []const u8) ?env_mod.Value {
    const nodes = parser_mod.parse(eval.allocator, source) catch return null;
    const mod_env = eval.allocator.create(Env) catch return null;
    mod_env.* = Env.init(eval.allocator, null);
    eval_modules.loadPassivesPrelude(eval, mod_env);
    _ = eval.evalNodes(nodes, mod_env) catch return null;
    const bound = mod_env.get(name) orelse return null;
    const def = switch (bound) {
        .block_def => |b| b,
        else => return null,
    };
    var env = Env.init(eval.allocator, null);
    defer env.deinit();
    return eval_modules.callModule(eval, def, &.{}, ast.Span.zero, &env) catch null;
}

/// One line per resolved placement/sign-off binding, prefixed the way
/// `flat_netlist.collectInstances` prefixes a sub-block's refs. These are the
/// pads the netlist cannot show, and exactly the ones `(decouples …)`,
/// `(near …)`, `(strap-ok …)` and `(nc-ok …)` rewrites move.
fn appendBindingLines(
    arena: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    prefix: []const u8,
    out: *std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    for (block.instances) |inst| {
        const ref = if (prefix.len == 0) inst.ref_des else try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, inst.ref_des });
        const bd = inst.bind.decouple;
        if (bd.ic.len > 0 or bd.pin.len > 0 or bd.rail)
            try out.append(arena, try std.fmt.allocPrint(arena, "bind {s} decouples {s} {s} rail={}", .{ ref, bd.ic, bd.pin, bd.rail }));
        const nb = inst.bind.near;
        if (nb.ref.len > 0)
            try out.append(arena, try std.fmt.allocPrint(arena, "bind {s} near {s} {s} own={s}", .{ ref, nb.ref, nb.pin, nb.own }));
        for (inst.strap_oks) |s|
            try out.append(arena, try std.fmt.allocPrint(arena, "bind {s} strap-ok {s}", .{ ref, s.pin }));
        for (inst.nc_oks) |n|
            try out.append(arena, try std.fmt.allocPrint(arena, "bind {s} nc-ok {s}", .{ ref, n.pin }));
    }
    for (block.sub_blocks) |sb| {
        const sub = if (prefix.len == 0) sb.name else try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, sb.name });
        try appendBindingLines(arena, sb.block, sub, out);
    }
}

/// The first line at which two signatures disagree, or null when they match.
fn firstDifference(before: []const []const u8, after: []const []const u8) ?[]const u8 {
    const n = @min(before.len, after.len);
    for (before[0..n], after[0..n]) |a, b| {
        if (!std.mem.eql(u8, a, b)) return b;
    }
    if (after.len > n) return after[n];
    if (before.len > n) return before[n];
    return null;
}

// ── Tool handler ───────────────────────────────────────────────────────

/// `rewrite-pins-by-name` — the registered structured tool. Returns false (an
/// `ok:false` envelope) on every refusal: an unusable path, a file that does
/// not parse or evaluate, and a rewrite whose netlist or bindings moved.
pub fn tool(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) ToolError!bool {
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    const file = stringArg(args_val, "file") orelse return refuse(&aw.writer, "file is required");
    const target = classify(allocator, project_dir, file) orelse
        return refuse(&aw.writer, "file must be a .sexp under lib/modules/ or src/");
    const source = infra_fs.cwd().readFileAlloc(allocator, target.path, max_source_bytes) catch
        return refuse(&aw.writer, "cannot read the file");
    const refs = try refList(allocator, args_val);

    var eval = Evaluator.init(allocator, project_dir);
    const plan = planRewrite(allocator, &eval, source, refs) catch
        return refuse(&aw.writer, "the file does not parse");
    const before = signature(allocator, project_dir, target, source) orelse
        return refuse(&aw.writer, "the file does not evaluate — fix it before rewriting");
    if (plan.rewrites > 0) {
        const after = signature(allocator, project_dir, target, plan.rewritten) orelse
            return refuse(&aw.writer, "the rewritten source does not evaluate");
        if (firstDifference(before, after)) |line|
            return refuseAt(&aw.writer, "the rewrite changes the netlist", line);
    }

    const want_write = boolArg(args_val, "write") orelse false;
    const written = want_write and plan.rewrites > 0;
    if (written) try writeSource(target.path, plan.rewritten);
    try writeResult(allocator, &aw.writer, file, plan, source, written);
    return true;
}

/// Replace the source atomically (tmp → rename), the way `id_insert` writes the
/// only other hand-authored file this tool family touches: a crash mid-write
/// must not truncate a design.
fn writeSource(path: []const u8, bytes: []const u8) ToolError!void {
    var buf: [4096]u8 = undefined;
    var atomic = try infra_fs.cwd().atomicFile(path, .{ .write_buffer = &buf });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(bytes);
    try atomic.finish();
}

fn writeResult(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    file: []const u8,
    plan: Plan,
    source: []const u8,
    written: bool,
) json_writer.WriteError!void {
    const diff = unifiedDiff(allocator, file, source, plan.rewritten) catch "";
    try w.writeAll("{\"ok\":true,\"file\":");
    try json_writer.writeString(w, file);
    try w.print(",\"rewritten\":{d},\"written\":{},\"netlist_equivalent\":true", .{ plan.rewrites, written });
    try w.print(",\"parts_without_pinout\":{d},\"positional_parts\":{d},\"skipped_omitted\":{d}", .{
        plan.parts_without_pinout, plan.positional_parts, plan.skips_omitted,
    });
    try w.writeAll(",\"skipped\":[");
    for (plan.skips, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"ref\":");
        try json_writer.writeString(w, s.ref);
        try w.writeAll(",\"pad\":");
        try json_writer.writeString(w, s.pad);
        try w.writeAll(",\"reason\":");
        try json_writer.writeString(w, s.reason);
        try w.writeAll("}");
    }
    try w.writeAll("],\"diff\":");
    try json_writer.writeString(w, diff);
    try w.writeAll("}");
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

/// One named argument, or null when it is absent or the wrong type. Mirrors
/// `serve/mcp_tools.optionalString`'s shape — including its non-object guard,
/// because a caller may hand a bare JSON value straight through.
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

/// The optional `refs` array, or null for "every instance in the file". An
/// empty (or non-string) array is also null: a filter that names nothing is a
/// mistake, and answering "0 rewrites" to it would read as "nothing to do".
fn refList(allocator: std.mem.Allocator, args_val: ?std.json.Value) std.mem.Allocator.Error!?[]const []const u8 {
    const v = namedArg(args_val, "refs") orelse return null;
    const items = switch (v) {
        .array => |a| a.items,
        else => return null,
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (items) |item| switch (item) {
        .string => |s| try out.append(allocator, s),
        else => {},
    };
    if (out.items.len == 0) return null;
    return out.items;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const cap_family =
    \\(component-family "cap-0402" (symbol generic-cap) (parameter "value" capacitance))
;
const ldo_comp =
    \\(component demo-ldo (footprint "DFN-12") (pinout demo-ldo))
;
/// `NC` deliberately repeats on pads 11 and 12: a name that cannot say which
/// pad it means must never be written back.
const ldo_pinout =
    \\(pinout "DEMO-LDO"
    \\  (pin 1 "IN_1")
    \\  (pin 2 "IN_2")
    \\  (pin 3 "EN/UV")
    \\  (pin 5 "ILIM")
    \\  (pin 8 "GND")
    \\  (pin 10 "OUT")
    \\  (pin 11 "NC")
    \\  (pin 12 "NC"))
;
const conn_comp =
    \\(component demo-conn (footprint "HDR-4") (pinout demo-conn))
;
/// The importer's positional spelling: every contact "named" after its own
/// (zero-padded) number, which the pad id itself reads back as `1`…`4`.
const conn_pinout =
    \\(pinout "DEMO-CONN" (pin 01 "01") (pin 02 "02") (pin 03 "03") (pin 04 "04"))
;

const board_src =
    \\;; Demo board — this banner comment must survive byte for byte.
    \\(import demo-ldo demo-conn)
    \\
    \\(design-block "Demo"
    \\  (instance "U1" demo-ldo
    \\    (pin 1 2 "VIN")          ;; IN_1/IN_2 — share the input bypass
    \\    (pin 5 "GND")            ;; ILIM
    \\    (pin 8 "GND")
    \\    (pin 10 "VOUT")
    \\    (pin 11 "OPEN")
    \\    (strap-ok 5 "ILIM->GND selects the default current limit")
    \\    (nc-ok 11 "spare pad, deliberately open"))
    \\
    \\  ;; A connector whose pinout names every contact after itself.
    \\  (instance "J1" demo-conn (pin 01 "VIN") (pin 02 "GND"))
    \\
    \\  (instance "U2" demo-ldo
    \\    (pin 1 "VOUT") (pin 8 "GND") (pin 10 "V2")
    \\    (near "U1" 10 (own 3)))
    \\
    \\  (instance "C1" (cap-0402 "100nF") (pin 1 "VIN") (pin 2 "GND")
    \\    (decouples "U1" 1)))
;

fn writeFixture(dir: std.Io.Dir) !void {
    try dir.createDirPath(std.testing.io, "lib/components");
    try dir.createDirPath(std.testing.io, "lib/pinouts");
    try dir.createDirPath(std.testing.io, "src");
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/cap-0402.sexp", .data = cap_family });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/demo-ldo.sexp", .data = ldo_comp });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/pinouts/demo-ldo.sexp", .data = ldo_pinout });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/demo-conn.sexp", .data = conn_comp });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/pinouts/demo-conn.sexp", .data = conn_pinout });
    try dir.writeFile(std.testing.io, .{ .sub_path = "src/board.sexp", .data = board_src });
}

/// Plan the fixture board's rewrite. The arena stands in for the evaluator's
/// never-freed AST storage, so the whole plan is released in one deinit.
fn planFixture(arena: std.mem.Allocator, project: []const u8) !Plan {
    var eval = Evaluator.init(arena, project);
    return planRewrite(arena, &eval, board_src, null);
}

/// How many lines of `text` are `;;` comments, with their bytes.
fn commentLines(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const at = std.mem.indexOf(u8, line, ";;") orelse continue;
        try out.append(arena, line[at..]);
    }
    return out.toOwnedSlice(arena);
}

// spec: rewrite-pins-by-name - the rewrite splices at AST spans, so every comment and blank line survives byte for byte, the line count is unchanged, and multi-pad shorthand rewrites each pad independently
test "the span splice preserves comments and expands multi-pad shorthand" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    const plan = try planFixture(arena, project);
    const got = plan.rewritten;

    // Multi-pad shorthand: BOTH pads move, and the aligned trailing comment
    // keeps its exact bytes — the whole point of splicing at the span rather
    // than re-printing the form.
    try testing.expect(std.mem.indexOf(u8, got, "(pin IN_1 IN_2 \"VIN\")          ;; IN_1/IN_2 — share the input bypass") != null);
    try testing.expect(std.mem.indexOf(u8, got, "(pin ILIM \"GND\")            ;; ILIM") != null);

    // Every comment in the file is byte-identical, banner included.
    const before = try commentLines(arena, board_src);
    const after = try commentLines(arena, got);
    try testing.expectEqual(before.len, after.len);
    for (before, after) |a, b| try testing.expectEqualStrings(a, b);

    // A token replacement never adds or removes a line.
    try testing.expectEqual(
        std.mem.count(u8, board_src, "\n"),
        std.mem.count(u8, got, "\n"),
    );
}

// spec: rewrite-pins-by-name - a function name repeated on several pads is skipped with its reason, and a connector whose pinout names every contact after its own number is left entirely alone
test "repeated function names and positional connector pads are skipped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    const plan = try planFixture(arena, project);

    // `NC` sits on pads 11 AND 12, so neither the `(pin 11 …)` nor the
    // `(nc-ok 11 …)` may be written — a name that cannot say which pad it
    // means would silently re-point the pin on the next pinout edit.
    try testing.expect(std.mem.indexOf(u8, plan.rewritten, "(pin 11 \"OPEN\")") != null);
    try testing.expect(std.mem.indexOf(u8, plan.rewritten, "(nc-ok 11 \"spare pad") != null);
    var repeats: usize = 0;
    for (plan.skips) |s| {
        if (std.mem.eql(u8, s.reason, "function name repeats on other pads")) {
            try testing.expectEqualStrings("11", s.pad);
            try testing.expectEqualStrings("U1", s.ref);
            repeats += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), repeats);

    // The connector is counted once, not reported pad by pad, and its contacts
    // keep the numbers the author wrote.
    try testing.expect(std.mem.indexOf(u8, plan.rewritten, "(instance \"J1\" demo-conn (pin 01 \"VIN\") (pin 02 \"GND\"))") != null);
    try testing.expectEqual(@as(usize, 1), plan.positional_parts);
    // The capacitor family has no `lib/pinouts` file at all — a different
    // reason, counted separately, and still never touched.
    try testing.expectEqual(@as(usize, 1), plan.parts_without_pinout);
}

// spec: rewrite-pins-by-name - strap-ok, nc-ok and a near form's own pad resolve through the declaring part's pinout while near and decouples resolve their target pad through the named part's
test "sign-off and binding pads resolve through the right part's pinout" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    const plan = try planFixture(arena, project);
    const got = plan.rewritten;

    // The sign-off now reads as its own reason.
    try testing.expect(std.mem.indexOf(u8, got, "(strap-ok ILIM \"ILIM->GND selects") != null);
    // `(near "U1" 10 (own 3))`: the TARGET pad is U1's OUT, the `(own …)` pad is
    // U2's own EN/UV — two different pinouts inside one form.
    try testing.expect(std.mem.indexOf(u8, got, "(near \"U1\" OUT (own EN/UV))") != null);
    // A capacitor has no pinout of its own, yet its binding still names U1's pad.
    try testing.expect(std.mem.indexOf(u8, got, "(decouples \"U1\" IN_1)") != null);

    // `EN/UV` is written bare because the tokenizer reads it back unchanged;
    // a name it would re-read as something else is quoted instead.
    try testing.expectEqualStrings("EN/UV", spellToken(arena, "EN/UV").?);
    try testing.expectEqualStrings("\"~{CS}\"", spellToken(arena, "~{CS}").?);
    try testing.expectEqualStrings("\"09\"", spellToken(arena, "09").?);
}

// spec: rewrite-pins-by-name - the rewritten source is accepted only when it evaluates and its flattened netlist and resolved bindings match the original line for line, so a rewrite that moved a pad is refused
test "a rewrite that moved a pad fails the netlist and binding signature" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const target = classify(arena, project, "src/board.sexp").?;

    const base = signature(arena, project, target, board_src).?;
    const plan = try planFixture(arena, project);
    // The real rewrite is invisible to the flatten: same nets, same bindings.
    try testing.expect(firstDifference(base, signature(arena, project, target, plan.rewritten).?) == null);

    // A hand-moved pad is not. `(pin 10 "VOUT")` → `(pin 3 "VOUT")` keeps the
    // file evaluating, so only the signature can catch it.
    const moved = try std.mem.replaceOwned(u8, arena, board_src, "(pin 10 \"VOUT\")", "(pin 3 \"VOUT\")");
    try testing.expect(firstDifference(base, signature(arena, project, target, moved).?) != null);

    // So is a moved BINDING, which no net carries at all.
    const rebound = try std.mem.replaceOwned(u8, arena, board_src, "(decouples \"U1\" 1)", "(decouples \"U1\" 2)");
    try testing.expect(firstDifference(base, signature(arena, project, target, rebound).?) != null);

    // A source that does not evaluate has no signature to compare, which is
    // what makes the tool refuse it rather than write it.
    try testing.expect(signature(arena, project, target, "(design-block \"X\" (instance \"U9\" nope (pin 1 \"N\")))") == null);
}

// spec: rewrite-pins-by-name - the default run writes nothing and returns the unified diff, and write true replaces the file atomically with the proven bytes
test "the tool writes only on write true and reports the diff either way" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    var out: std.ArrayList(u8) = .empty;
    try testing.expect(try tool(arena, project, try args(arena, "{\"file\":\"src/board.sexp\"}"), &out));
    try testing.expect(std.mem.indexOf(u8, out.items, "\"written\":false") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "--- a/src/board.sexp") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "+    (pin IN_1 IN_2 \\\"VIN\\\")") != null);
    try testing.expectEqualStrings(board_src, try readBoard(arena, tmp.dir));

    // …and only now does the file change, to exactly the proven bytes.
    out.clearRetainingCapacity();
    try testing.expect(try tool(arena, project, try args(arena, "{\"file\":\"src/board.sexp\",\"write\":true}"), &out));
    try testing.expect(std.mem.indexOf(u8, out.items, "\"written\":true") != null);
    const plan = try planFixture(arena, project);
    try testing.expectEqualStrings(plan.rewritten, try readBoard(arena, tmp.dir));

    // A path outside lib/modules and src/ is refused before anything is read.
    out.clearRetainingCapacity();
    try testing.expect(!try tool(arena, project, try args(arena, "{\"file\":\"lib/pinouts/demo-ldo.sexp\"}"), &out));
    try testing.expect(std.mem.indexOf(u8, out.items, "\"ok\":false") != null);
}

fn args(arena: std.mem.Allocator, json: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
}

fn readBoard(arena: std.mem.Allocator, dir: std.Io.Dir) ![]const u8 {
    return dir.readFileAlloc(std.testing.io, "src/board.sexp", arena, .limited64(max_source_bytes));
}

// spec: rewrite-pins-by-name - the tool is registered as a mutation and its declared schema round-trips through netlisp tool list
test "rewrite-pins-by-name is a registered mutation with a round-tripping schema" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const mcp_tools = @import("serve/mcp_tools.zig");

    try testing.expect(mcp_tools.isKnownTool("rewrite-pins-by-name"));
    // It edits a hand-authored source, so the write path is gated like every
    // other design mutation.
    try testing.expect(mcp_tools.isMutationTool("rewrite-pins-by-name"));

    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, mcp_tools.tools_list_result, .{});
    var schema: ?std.json.ObjectMap = null;
    for (root.object.get("tools").?.array.items) |t| {
        if (std.mem.eql(u8, t.object.get("name").?.string, "rewrite-pins-by-name"))
            schema = t.object.get("inputSchema").?.object;
    }
    const props = schema.?.get("properties").?.object;
    // Every argument the handler reads is declared, and the schema is closed —
    // an undeclared argument is one a strict client could not send at all.
    try testing.expectEqualStrings("string", props.get("file").?.object.get("type").?.string);
    try testing.expectEqualStrings("boolean", props.get("write").?.object.get("type").?.string);
    try testing.expectEqualStrings("string", props.get("refs").?.object.get("items").?.object.get("type").?.string);
    try testing.expect(!schema.?.get("additionalProperties").?.bool);
    const required = schema.?.get("required").?.array.items;
    try testing.expectEqual(@as(usize, 1), required.len);
    try testing.expectEqualStrings("file", required[0].string);
}
