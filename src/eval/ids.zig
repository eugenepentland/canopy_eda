const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const log = @import("../infra/log.zig");
const ast = @import("../sexpr/ast.zig");
const parser_mod = @import("../sexpr/parser.zig");
const env_mod = @import("env.zig");
const evaluator_mod = @import("evaluator.zig");
const Evaluator = evaluator_mod.Evaluator;
const EvalError = evaluator_mod.EvalError;
const AltFunc = evaluator_mod.AltFunc;
const infra_random = @import("../infra/random.zig");

// ── Constants ─────────────────────────────────────────────────────
/// Number of letters (a-f) we map the leading hex byte into so the first
/// character of an ID is always alphabetic.
const ID_FIRST_LETTER_RANGE: u8 = 6;

const Node = ast.Node;
const Instance = env_mod.Instance;
const DesignBlock = env_mod.DesignBlock;

/// Get the next auto ref-des for a given prefix (e.g., 'C' -> "C1", "C2", ...).
pub fn nextRefDes(self: *Evaluator, prefix: u8) EvalError![]const u8 {
    const gop = self.auto_refdes.getOrPut(self.allocator, prefix) catch return EvalError.OutOfMemory;
    if (!gop.found_existing) gop.value_ptr.* = 0;
    gop.value_ptr.* += 1;
    return std.fmt.allocPrint(self.allocator, "{c}{d}", .{ prefix, gop.value_ptr.* }) catch return EvalError.OutOfMemory;
}

/// Bump auto ref-des counter to avoid conflicts with explicit ref-des.
pub fn registerRefDes(self: *Evaluator, ref_des: []const u8) void {
    if (ref_des.len < 2) return;
    const prefix = ref_des[0];
    const num = std.fmt.parseInt(u32, ref_des[1..], 10) catch return;
    const gop = self.auto_refdes.getOrPut(self.allocator, prefix) catch return;
    if (!gop.found_existing) gop.value_ptr.* = 0;
    if (num > gop.value_ptr.*) gop.value_ptr.* = num;
}

/// Check if a ref_des looks like a standard one (uppercase letter + digits, e.g., "U1", "C23").
pub fn isStandardRefDes(ref_des: []const u8) bool {
    if (ref_des.len < 2) return false;
    if (!std.ascii.isUpper(ref_des[0])) return false;
    // Allow multi-letter prefixes like "SW" -- check if remaining chars after letters are all digits
    var digit_start: usize = 1;
    while (digit_start < ref_des.len and std.ascii.isUpper(ref_des[digit_start])) : (digit_start += 1) {}
    if (digit_start >= ref_des.len) return false;
    for (ref_des[digit_start..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Auto-assign ref_des for instances that have descriptive labels (not standard ref_des).
/// Updates all references (nets, notes, pin groups, sections) to use the new ref_des.
pub fn autoAssignRefDes(self: *Evaluator, block: *DesignBlock) EvalError!void {
    // Build rename map: old_ref_des (label) -> new_ref_des
    var rename_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer rename_map.deinit(self.allocator);

    // First pass: register all standard ref_des to avoid conflicts
    const insts: []Instance = @constCast(block.instances);
    for (insts) |inst| {
        if (isStandardRefDes(inst.ref_des)) {
            registerRefDes(self, inst.ref_des);
        }
    }

    // Phase C.1: walk the instances in a stable (source_offset, insertion_index)
    // order before assigning auto-refs. The slice itself is already source-
    // ordered today, but pinning the iteration through `stableRefAssignOrder`
    // means a future hash-map-iterated builder can't perturb numbering.
    const order = try stableRefAssignOrder(self.allocator, insts);
    defer self.allocator.free(order);

    // Second pass: assign new ref_des for non-standard labels
    for (order) |i| {
        const inst = &insts[i];
        if (!isStandardRefDes(inst.ref_des)) {
            const prefix = componentPrefix(inst.component);
            const new_ref = nextRefDes(self, prefix) catch continue;
            try rename_map.put(self.allocator, inst.ref_des, new_ref);
            inst.ref_des = new_ref;
        }
    }

    if (rename_map.count() == 0) return;

    // Update all references: nets (pin refs + net names), notes, pin groups, sections
    const net_slice: []env_mod.Net = @constCast(block.nets);
    for (net_slice) |*net| {
        // Rename pin ref_des
        const pins: []env_mod.PinRef = @constCast(net.pins);
        for (pins) |*pin| {
            if (rename_map.get(pin.ref_des)) |new_ref| {
                pin.ref_des = new_ref;
            }
        }
        // Rename net names containing old labels (e.g., "VDD.stm32.J14" -> "VDD.U1.J14")
        var ren_iter = rename_map.iterator();
        while (ren_iter.next()) |entry| {
            const old_label = entry.key_ptr.*;
            const new_ref = entry.value_ptr.*;
            const dot_old = std.fmt.allocPrint(self.allocator, ".{s}.", .{old_label}) catch continue;
            if (std.mem.indexOf(u8, net.name, dot_old)) |pos| {
                const dot_new = std.fmt.allocPrint(self.allocator, ".{s}.", .{new_ref}) catch continue;
                const new_name = std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ net.name[0..pos], dot_new, net.name[pos + dot_old.len ..] }) catch continue;
                net.name = new_name;
                break; // Only one label per net name
            }
        }
    }
    const note_slice: []env_mod.Note = @constCast(block.notes);
    for (note_slice) |*note| {
        if (rename_map.get(note.ref_des)) |new_ref| {
            note.ref_des = new_ref;
        }
    }
    renameSectionRefs(@constCast(block.sections), &rename_map);
}

/// Assign global ref-des to sub-block instances, replacing local names (U1, R1, etc.)
/// with globally unique ones. Also renames net pin references to match.
pub fn autoAssignSubBlockRefDes(self: *Evaluator, block: *DesignBlock) EvalError!void {
    for (@as([]env_mod.SubBlock, @constCast(block.sub_blocks))) |*sb| {
        try assignSubBlockRefDes(self, sb.block);
    }
}

fn assignSubBlockRefDes(self: *Evaluator, block: *DesignBlock) !void {
    var rename_map = std.StringHashMapUnmanaged([]const u8).empty;
    defer rename_map.deinit(self.allocator);

    const insts: []Instance = @constCast(block.instances);

    // Phase C.1: assign in stable (source_offset, insertion_index) order so a
    // sub-block's global ref-des numbering can't drift run-to-run if a builder
    // ever appends instances out of source order.
    const order = try stableRefAssignOrder(self.allocator, insts);
    defer self.allocator.free(order);

    // Assign new global ref_des for all instances
    for (order) |i| {
        const inst = &insts[i];
        const prefix = componentPrefix(inst.component);
        const new_ref = nextRefDes(self, prefix) catch continue;
        if (!std.mem.eql(u8, inst.ref_des, new_ref)) {
            try rename_map.put(self.allocator, inst.ref_des, new_ref);
            inst.ref_des = new_ref;
        }
    }

    if (rename_map.count() == 0) return;

    // Update net pin references and net names
    const net_slice: []env_mod.Net = @constCast(block.nets);
    for (net_slice) |*net| {
        const pins: []env_mod.PinRef = @constCast(net.pins);
        for (pins) |*pin| {
            if (rename_map.get(pin.ref_des)) |new_ref| {
                pin.ref_des = new_ref;
            }
        }
        var ren_iter = rename_map.iterator();
        while (ren_iter.next()) |entry| {
            const old_label = entry.key_ptr.*;
            const new_ref = entry.value_ptr.*;
            const dot_old = std.fmt.allocPrint(self.allocator, ".{s}.", .{old_label}) catch continue;
            if (std.mem.indexOf(u8, net.name, dot_old)) |pos| {
                const dot_new = std.fmt.allocPrint(self.allocator, ".{s}.", .{new_ref}) catch continue;
                const new_name = std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ net.name[0..pos], dot_new, net.name[pos + dot_old.len ..] }) catch continue;
                net.name = new_name;
                break;
            }
        }
    }

    // Update notes
    const note_slice: []env_mod.Note = @constCast(block.notes);
    for (note_slice) |*note| {
        if (rename_map.get(note.ref_des)) |new_ref| {
            note.ref_des = new_ref;
        }
    }

    // Recurse into nested sub-blocks
    for (@as([]env_mod.SubBlock, @constCast(block.sub_blocks))) |*sb| {
        try assignSubBlockRefDes(self, sb.block);
    }
}

/// Recursively rename ref_des in sections and sub-sections.
pub fn renameSectionRefs(sections: []env_mod.Section, rename_map: *std.StringHashMapUnmanaged([]const u8)) void {
    for (sections) |*sec| {
        for (@as([]Instance, @constCast(sec.instances))) |*inst| {
            if (rename_map.get(inst.ref_des)) |new_ref| {
                inst.ref_des = new_ref;
            }
        }
        for (@as([]env_mod.PinGroup, @constCast(sec.pin_groups))) |*pg| {
            if (rename_map.get(pg.ref_des)) |new_ref| {
                pg.ref_des = new_ref;
            }
        }
        renameSectionRefs(@constCast(sec.sub_sections), rename_map);
    }
}

/// Recursively pre-scan forms to register all explicit ref-des before evaluation.
pub fn prescanRefDes(self: *Evaluator, forms: []const Node) void {
    for (forms) |form| {
        const children = form.asList() orelse continue;
        if (children.len < 2) continue;
        const name = children[0].asAtom() orelse continue;
        if (std.mem.eql(u8, name, "instance") or std.mem.eql(u8, name, "series")) {
            const ref_node = children[1];
            const ref_str = ref_node.asAtom() orelse (ref_node.asString() orelse continue);
            registerRefDes(self, ref_str);
        } else if (std.mem.eql(u8, name, "section")) {
            prescanRefDes(self, children[2..]);
        }
    }
}

/// Get the ref-des prefix letter for a component family name.
pub fn componentPrefix(family: []const u8) u8 {
    // Known passive/generic families
    if (std.mem.eql(u8, family, "ind")) return 'L';
    if (std.mem.eql(u8, family, "led") or std.mem.startsWith(u8, family, "led-")) return 'D';
    if (std.mem.startsWith(u8, family, "cap")) return 'C';
    if (std.mem.startsWith(u8, family, "res")) return 'R';
    if (std.mem.startsWith(u8, family, "diode")) return 'D';
    // Coilcraft XFL-series power inductors live as standalone library parts
    // (e.g. xfl4012) rather than being modeled as the generic `ind` family.
    if (std.mem.startsWith(u8, family, "xfl")) return 'L';
    // Known connector patterns
    if (std.mem.startsWith(u8, family, "connector")) return 'J';
    if (std.mem.startsWith(u8, family, "amphenol")) return 'J';
    if (std.mem.startsWith(u8, family, "lsh-")) return 'J';
    if (std.mem.startsWith(u8, family, "usb4")) return 'J';
    // Known ESD/filter patterns
    if (std.mem.startsWith(u8, family, "ecmf")) return 'U';
    // Known ferrite patterns
    if (std.mem.startsWith(u8, family, "ferrite")) return 'L';
    // Known crystal patterns
    if (std.mem.eql(u8, family, "abm8")) return 'Y';
    if (std.mem.startsWith(u8, family, "fc-")) return 'Y';
    // Discrete transistors (MOSFETs + BJTs) — Q prefix
    if (std.mem.startsWith(u8, family, "ao3") or
        std.mem.startsWith(u8, family, "ao4") or
        std.mem.startsWith(u8, family, "bss") or
        std.mem.startsWith(u8, family, "dmn") or
        std.mem.startsWith(u8, family, "dmp") or
        std.mem.startsWith(u8, family, "2n") or
        std.mem.startsWith(u8, family, "irlml")) return 'Q';
    // Everything else is an IC
    if (family.len > 0) return 'U';
    return 'X';
}

/// Phase C.1: produce a stable iteration order for `nextRefDes` assignment.
/// Sort key is `(source_offset, original_index)`: source offset preserves the
/// "instance N appears at line L" intuition for direct `(instance …)` forms,
/// and the original index breaks ties for builder-synthesised siblings
/// (decouple/series) that all share the call site's offset. Today the slice
/// is already source-ordered, so this sort is a no-op for production designs
/// — but pinning it down means a future hash-map-iterated builder can't
/// silently flip the C5/C7 assignment between consecutive evals.
fn stableRefAssignOrder(allocator: std.mem.Allocator, insts: []const Instance) std.mem.Allocator.Error![]usize {
    const order = try allocator.alloc(usize, insts.len);
    for (order, 0..) |*ix, i| ix.* = i;
    const Ctx = struct {
        insts: []const Instance,
        fn lt(ctx: @This(), a: usize, b: usize) bool {
            const ao = ctx.insts[a].source_offset;
            const bo = ctx.insts[b].source_offset;
            if (ao != bo) return ao < bo;
            return a < b;
        }
    };
    std.mem.sortUnstable(usize, order, Ctx{ .insts = insts }, Ctx.lt);
    return order;
}

/// Scan form children for (id xxxxxxxx) and return the 8-char hex string, or null.
pub fn parseId(children: []const Node) ?[]const u8 {
    for (children) |child| {
        if (child.isForm("id")) {
            const id_children = child.asList() orelse continue;
            if (id_children.len >= 2) {
                return id_children[1].asAtom() orelse id_children[1].asString();
            }
        }
    }
    return null;
}

/// Number of re-roll attempts `generateId` makes before giving up. At ~30 bits
/// of entropy and a few hundred components the first draw almost always wins;
/// this bound just guarantees the loop terminates.
const ID_GEN_MAX_ATTEMPTS: usize = 1024;

/// Register an 8-char token in the design-wide uniqueness set. Idempotent —
/// safe to call with a token that is already present. An allocator failure
/// just returns: a missed registration only risks a (vanishingly unlikely)
/// future collision, never a crash.
fn registerId(self: *Evaluator, id: []const u8) void {
    self.design_ids.put(self.allocator, id, {}) catch return;
}

/// Recursively register every `(id …)` and `(ids ("k" t) …)` token in `forms`
/// into the design-wide id set before evaluation, so `generateId` never mints a
/// token that already exists in source but is only reached later in the walk.
/// Tolerates the malformed nested `(id … (id …))` residue by registering every
/// token it finds.
pub fn prescanIds(self: *Evaluator, forms: []const Node) void {
    for (forms) |form| {
        const children = form.asList() orelse continue;
        if (children.len == 0) continue;
        if (children[0].asAtom()) |head| {
            if (std.mem.eql(u8, head, "id")) {
                if (children.len >= 2) {
                    if (children[1].asAtom() orelse children[1].asString()) |tok| registerId(self, tok);
                }
                prescanIds(self, children[1..]); // catch nested-id residue
                continue;
            }
            if (std.mem.eql(u8, head, "ids")) {
                for (children[1..]) |pair_node| {
                    const pair = pair_node.asList() orelse continue;
                    if (pair.len >= 2) {
                        if (pair[1].asAtom() orelse pair[1].asString()) |tok| registerId(self, tok);
                    }
                }
                continue;
            }
            prescanIds(self, children[1..]);
        } else {
            prescanIds(self, children);
        }
    }
}

/// Generate a random 8-char hex ID, re-rolling until it is unique across the
/// whole design (see `Evaluator.design_ids`). First char is always a letter
/// (a-f) so the tokenizer parses it as an atom, not a number. The winning token
/// is registered before it is returned.
pub fn generateId(self: *Evaluator) EvalError![]const u8 {
    var attempt: usize = 0;
    while (attempt < ID_GEN_MAX_ATTEMPTS) : (attempt += 1) {
        var bytes: [4]u8 = undefined;
        infra_random.bytes(&bytes);
        const first: u8 = (bytes[0] % ID_FIRST_LETTER_RANGE) + 'a'; // ensure first char is a-f letter
        const id = std.fmt.allocPrint(
            self.allocator,
            "{c}{x:0>2}{x:0>2}{x:0>2}{x:0>1}",
            .{ first, bytes[1], bytes[2], bytes[3], bytes[0] & 0x0f },
        ) catch return EvalError.OutOfMemory;
        if (!self.design_ids.contains(id)) {
            registerId(self, id);
            return id;
        }
    }
    return EvalError.IdSpaceExhausted;
}

/// Derive a child ID from a parent ID, net context, and index.
pub fn deriveChildId(self: *Evaluator, parent_id: []const u8, context: []const u8, index: usize) EvalError![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(parent_id);
    hasher.update(":");
    hasher.update(context);
    hasher.update(":");
    var idx_buf: [8]u8 = undefined;
    const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{index}) catch "0";
    hasher.update(idx_str);
    const hash = hasher.finalResult();
    // Ensure first char is a letter (so tokenizer parses as atom)
    const first: u8 = (hash[0] % ID_FIRST_LETTER_RANGE) + 'a';
    return std.fmt.allocPrint(self.allocator, "{c}{x:0>2}{x:0>2}{x:0>2}{x:0>1}", .{ first, hash[1], hash[2], hash[3], hash[0] & 0x0f });
}

/// Assign every instance ID inside a sub-block's design-block from a
/// SOURCE-RESIDENT `(ids …)` sidecar on the `(sub-block …)` call site, so a
/// sub-block's part identities live in the design `.sexp` (like the decouple
/// sidecar) rather than only in the .bom. Each part is keyed by its path
/// relative to the sub-block root — the module-source label ("R_FAP", "U1"),
/// or `#<source-index>` for anonymous decouple/series passives, prefixed by
/// the nested sub-block name for descendants. All descendants share the
/// top-level call site's sidecar (a nested `(sub-block …)` lives in the
/// shared module source, where a per-instance id would collide).
///
/// On a sidecar miss the id is SEEDED with the legacy derivation
/// `deriveChildId(sub_name, label/index)` and queued for write-back, so
/// adopting this leaves existing uuids unchanged — the first build merely
/// pins the already-derived ids into source. Reading from source thereafter
/// makes them survive a sub-block rename (the sidecar moves with the form).
pub fn reassignSubBlockIds(
    self: *Evaluator,
    block: *DesignBlock,
    sub_name: []const u8,
    sidecar: *ChildIdSidecar,
    key_prefix: []const u8,
) EvalError!void {
    const insts: []Instance = @constCast(block.instances);
    for (insts, 0..) |*inst, i| {
        // `context` mirrors the legacy derivation exactly (module-source ref_des,
        // which equals the label for named parts and the module-local auto-name
        // for anonymous decouple/series passives) so the seed reproduces the id
        // an unmodified build already produces — adoption is therefore churn-free
        // and the seed merely pins what was already there. A `#index` fallback
        // covers the (unused) case of a part with neither ref_des nor label.
        const context = if (inst.ref_des.len > 0) inst.ref_des else inst.label;
        const local = if (context.len > 0)
            context
        else
            try std.fmt.allocPrint(self.allocator, "#{d}", .{i});
        const key = if (key_prefix.len > 0)
            try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ key_prefix, local })
        else
            local;
        if (sidecar.map.get(key)) |tok| {
            inst.id = tok;
        } else {
            const seed = try deriveChildId(self, sub_name, context, 0);
            try self.pending_child_ids.append(self.allocator, .{
                .parent_form_offset = sidecar.parent_offset,
                .key = key,
                .id = seed,
            });
            try sidecar.map.put(self.allocator, key, seed);
            inst.id = seed;
        }
    }
    for (@as([]env_mod.SubBlock, @constCast(block.sub_blocks))) |*sb| {
        const nested = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ sub_name, sb.name });
        const nested_prefix = if (key_prefix.len > 0)
            try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ key_prefix, sb.name })
        else
            sb.name;
        try reassignSubBlockIds(self, sb.block, nested, sidecar, nested_prefix);
    }
}

/// Option-4 child id derivation. Each part's final id = deriveChildId(subblock_uuid,
/// component_uuid): the sub-block carries one source-resident uuid in the design file,
/// and component_uuid is the part's own (id …) pinned in the *module definition*. Both
/// inputs are source-resident and survive ref-des renumbering, so child ids are stable
/// across sub-block renames and global renumbers — at the cost of one (id …) per module
/// part instead of an enumerated (ids …) sidecar at every call site. Two instantiations
/// of the same module share component_uuids but differ in subblock_uuid, so their parts
/// land on distinct ids. This mirrors KiCad's hierarchical-sheet path identity.
pub fn reassignSubBlockIdsV4(self: *Evaluator, block: *DesignBlock, subblock_uuid: []const u8) EvalError!void {
    const insts: []Instance = @constCast(block.instances);
    for (insts, 0..) |*inst, i| {
        // The child's identity is its stable module-local key (source name for
        // named parts, value@pin#index for decouple/series children), captured
        // at creation in `origin_key` so it survives ref-des renumbering. Fall
        // back to ref_des / index only for the (unexpected) keyless instance.
        const component = if (inst.origin_key.len > 0)
            inst.origin_key
        else if (inst.ref_des.len > 0)
            inst.ref_des
        else
            try std.fmt.allocPrint(self.allocator, "#{d}", .{i});
        inst.id = try deriveChildId(self, subblock_uuid, component, 0);
    }
    // Nested sub-blocks compose hierarchically (KiCad sheet-path style): the
    // nested level's uuid is derived from the parent's + the nested sub-block's
    // name, then its children hash against that. Re-derives deterministically,
    // overriding whatever the inner module evaluation assigned.
    for (@as([]env_mod.SubBlock, @constCast(block.sub_blocks))) |*sb| {
        const nested = try deriveChildId(self, subblock_uuid, sb.name, 0);
        try reassignSubBlockIdsV4(self, sb.block, nested);
    }
}

/// Get the (id ...) from form children, or generate one and track for insertion.
pub fn getOrCreateFormId(self: *Evaluator, form_children: []const Node) EvalError![]const u8 {
    if (parseId(form_children)) |existing| return existing;
    const new_id = try generateId(self);
    try self.pending_ids.append(self.allocator, .{
        .form_offset = form_children[0].span.offset -| 1,
        .id = new_id,
    });
    return new_id;
}

/// A parsed `(ids ("key" token) …)` child sidecar plus the parent form's
/// opening-paren offset. Threaded through one shorthand parent (decouple/series)
/// so its synthesized children get stable, source-resident tokens instead of
/// ids hashed from volatile net names. See `id_insert.insertPendingIds`.
pub const ChildIdSidecar = struct {
    map: std.StringHashMapUnmanaged([]const u8),
    parent_offset: u32,
};

/// Parse the `(ids …)` sidecar (if any) out of a parent form's children into a
/// key→token map, capturing the parent's opening-paren offset for write-back.
pub fn parseChildIdSidecar(self: *Evaluator, parent_children: []const Node) ChildIdSidecar {
    var sidecar = ChildIdSidecar{
        .map = .empty,
        .parent_offset = if (parent_children.len > 0) parent_children[0].span.offset -| 1 else 0,
    };
    for (parent_children) |child| {
        if (!child.isForm("ids")) continue;
        const pairs = child.asList() orelse continue;
        for (pairs[1..]) |pair_node| {
            const pair = pair_node.asList() orelse continue;
            if (pair.len < 2) continue;
            const key = pair[0].asString() orelse (pair[0].asAtom() orelse continue);
            const tok = pair[1].asAtom() orelse (pair[1].asString() orelse continue);
            sidecar.map.put(self.allocator, key, tok) catch continue;
            registerId(self, tok);
        }
    }
    return sidecar;
}

/// Return the stable child token for `key` from the sidecar, minting and queuing
/// a fresh one for write-back on a miss. Mutates the in-memory map so a repeated
/// key in the same eval reuses the just-minted token rather than re-minting.
pub fn getOrCreateChildId(self: *Evaluator, sidecar: *ChildIdSidecar, key: []const u8) EvalError![]const u8 {
    if (sidecar.map.get(key)) |tok| return tok;
    const tok = try generateId(self);
    try self.pending_child_ids.append(self.allocator, .{
        .parent_form_offset = sidecar.parent_offset,
        .key = key,
        .id = tok,
    });
    try sidecar.map.put(self.allocator, key, tok);
    return tok;
}

/// For a list like (cap-0402 "100nF"), returns the offset of the first child atom.
/// For a plain atom, returns the atom's own offset.
pub fn componentSourceOffset(node: Node) u32 {
    switch (node.tag) {
        .list => |children| {
            if (children.len > 0) return children[0].span.offset;
        },
        else => {},
    }
    return node.span.offset;
}

/// Load pin names for a component from lib/pinouts/.
pub fn getSymbolPins(self: *Evaluator, lookup_name: []const u8) ?*const std.StringHashMapUnmanaged([]const u8) {
    if (self.symbol_pin_cache.getPtr(lookup_name)) |cached| return cached;

    const pinout_path = std.fmt.allocPrint(self.allocator, "{s}/lib/pinouts/{s}.sexp", .{ self.project_dir, lookup_name }) catch return null;
    const loaded = loadPinoutFile(self, pinout_path) orelse return null;
    self.symbol_pin_cache.put(self.allocator, lookup_name, loaded.pins) catch return null;
    self.symbol_alt_cache.put(self.allocator, lookup_name, loaded.alts) catch return null;
    return self.symbol_pin_cache.getPtr(lookup_name);
}

/// Look up cached alternate-function map for a symbol (pin_id -> []AltFunc). Returns null
/// if the pinout has not been loaded yet; callers typically invoke `getSymbolPins` first.
pub fn getSymbolAlts(self: *Evaluator, lookup_name: []const u8) ?*const std.StringHashMapUnmanaged([]const AltFunc) {
    if (self.symbol_alt_cache.getPtr(lookup_name)) |cached| return cached;
    // Warm the cache via getSymbolPins; it populates both maps together.
    _ = getSymbolPins(self, lookup_name) orelse return null;
    return self.symbol_alt_cache.getPtr(lookup_name);
}

/// Pinout file load result: the `pin_id → function_name` map plus the
/// `pin_id → []AltFunc` map of declared alternate pin functions. Both maps
/// are indexed identically and cached together because `loadPinoutFile`
/// fills them in one pass.
pub const LoadedPinout = struct {
    pins: std.StringHashMapUnmanaged([]const u8),
    alts: std.StringHashMapUnmanaged([]const AltFunc),
};

/// Load pin names + alternate functions from a pinout file. Missing file returns null.
pub fn loadPinoutFile(self: *Evaluator, path: []const u8) ?LoadedPinout {
    const content = infra_fs.cwd().readFileAlloc(self.allocator, path, 1024 * 256) catch return null;
    const nodes = parser_mod.parse(self.allocator, content) catch return null;
    if (nodes.len == 0) return null;
    const top = nodes[0].asList() orelse return null;
    if (top.len < 2) return null;
    const head = top[0].asAtom() orelse return null;
    if (!std.mem.eql(u8, head, "pinout")) return null;

    var pin_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    var alt_map: std.StringHashMapUnmanaged([]const AltFunc) = .empty;
    for (top[2..]) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len < 3) continue;
        const ch = cl[0].asAtom() orelse continue;
        if (!std.mem.eql(u8, ch, "pin")) continue;
        const pin_id_str = pinId(self, cl[1]) orelse continue;
        const func_name = cl[2].asString() orelse (cl[2].asAtom() orelse continue);
        pin_map.put(self.allocator, pin_id_str, func_name) catch continue;

        if (cl.len > 3) {
            var alts: std.ArrayListUnmanaged(AltFunc) = .empty;
            for (cl[3..]) |alt_node| {
                const al = alt_node.asList() orelse continue;
                if (al.len < 2) continue;
                const hd = al[0].asAtom() orelse continue;
                if (!std.mem.eql(u8, hd, "alt")) continue;
                const alt_name = al[1].asString() orelse (al[1].asAtom() orelse continue);
                const etype = if (al.len >= 3) (al[2].asAtom() orelse al[2].asString() orelse "") else "";
                alts.append(self.allocator, .{ .name = alt_name, .etype = etype }) catch continue;
            }
            if (alts.items.len > 0) {
                const owned = alts.toOwnedSlice(self.allocator) catch continue;
                alt_map.put(self.allocator, pin_id_str, owned) catch continue;
            }
        }
    }
    return .{ .pins = pin_map, .alts = alt_map };
}

/// Check symbol pins against the pinout (source of truth).
pub fn validateSymbolAgainstPinout(self: *Evaluator, symbol_name: []const u8, sym_pins: *const std.StringHashMapUnmanaged([]const u8)) void {
    const pinout_path = std.fmt.allocPrint(self.allocator, "{s}/lib/pinouts/{s}.sexp", .{ self.project_dir, symbol_name }) catch return;
    const pinout_content = infra_fs.cwd().readFileAlloc(self.allocator, pinout_path, 1024 * 256) catch return;
    const pinout_nodes = parser_mod.parse(self.allocator, pinout_content) catch return;
    if (pinout_nodes.len == 0) return;
    const pinout_top = pinout_nodes[0].asList() orelse return;
    if (pinout_top.len < 2) return;
    const head = pinout_top[0].asAtom() orelse return;
    if (!std.mem.eql(u8, head, "pinout")) return;

    // Build pinout map: pin_id -> function_name
    var pinout_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer pinout_map.deinit(self.allocator);
    for (pinout_top[2..]) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len < 3) continue;
        const ch = cl[0].asAtom() orelse continue;
        if (!std.mem.eql(u8, ch, "pin")) continue;
        const pin_id_str = pinId(self, cl[1]) orelse continue;
        const func_name = cl[2].asString() orelse (cl[2].asAtom() orelse continue);
        pinout_map.put(self.allocator, pin_id_str, func_name) catch continue;
    }

    // Validate: every symbol pin must exist in pinout with matching name
    var sym_it = sym_pins.iterator();
    while (sym_it.next()) |entry| {
        const pin_id_key = entry.key_ptr.*;
        const sym_name = entry.value_ptr.*;
        if (pinout_map.get(pin_id_key)) |pinout_name| {
            if (!std.mem.eql(u8, sym_name, pinout_name)) {
                log.warn(
                    "PINOUT ERROR: symbol '{s}' pin {s}: symbol says \"{s}\" but pinout says \"{s}\"",
                    .{ symbol_name, pin_id_key, sym_name, pinout_name },
                );
            }
        } else {
            log.warn("PINOUT ERROR: symbol '{s}' pin {s} (\"{s}\") does not exist in pinout", .{ symbol_name, pin_id_key, sym_name });
        }
    }
}

/// Convert a node to a pin identifier string (number -> "123", atom -> "A1").
pub fn pinId(self: *Evaluator, node: Node) ?[]const u8 {
    if (node.asNumber()) |n| {
        const i: i64 = @intFromFloat(n);
        return std.fmt.allocPrint(self.allocator, "{d}", .{i}) catch return null;
    }
    return node.asAtom() orelse node.asString();
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: eval/evaluator - parseId extracts 8-char ID from form children
test "parseId extracts ID" {
    const alloc = std.testing.allocator;
    const parser_m = @import("../sexpr/parser.zig");
    const nodes = try parser_m.parse(alloc, "(instance \"R1\" comp (id abcd1234))");
    defer parser_m.freeNodes(alloc, nodes);
    const children = nodes[0].asList().?;
    const id = parseId(children);
    try std.testing.expect(id != null);
    try std.testing.expectEqualStrings("abcd1234", id.?);
}

// spec: eval/evaluator - parseId returns null when no ID present
test "parseId returns null when missing" {
    const alloc = std.testing.allocator;
    const parser_m = @import("../sexpr/parser.zig");
    const nodes = try parser_m.parse(alloc, "(instance \"R1\" comp)");
    defer parser_m.freeNodes(alloc, nodes);
    const children = nodes[0].asList().?;
    try std.testing.expect(parseId(children) == null);
}

// spec: eval/evaluator - deriveChildId produces the same child ID when called with identical inputs
test "deriveChildId is deterministic" {
    const alloc = std.testing.allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    const id1 = try deriveChildId(&eval, "abcd1234", "", 0);
    defer alloc.free(id1);
    const id2 = try deriveChildId(&eval, "abcd1234", "", 0);
    defer alloc.free(id2);
    try std.testing.expectEqualStrings(id1, id2);
}

// spec: eval/evaluator - deriveChildId produces unique child IDs across different index values
test "deriveChildId unique per index" {
    const alloc = std.testing.allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    const id0 = try deriveChildId(&eval, "abcd1234", "", 0);
    defer alloc.free(id0);
    const id1 = try deriveChildId(&eval, "abcd1234", "", 1);
    defer alloc.free(id1);
    const id2 = try deriveChildId(&eval, "abcd1234", "", 2);
    defer alloc.free(id2);
    try std.testing.expect(!std.mem.eql(u8, id0, id1));
    try std.testing.expect(!std.mem.eql(u8, id1, id2));
    try std.testing.expect(!std.mem.eql(u8, id0, id2));
}

// spec: eval/evaluator - generateId produces 8-char hex starting with letter
test "generateId format" {
    const alloc = std.testing.allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    const id = try generateId(&eval);
    defer alloc.free(id);
    try std.testing.expectEqual(@as(usize, 8), id.len);
    try std.testing.expect(id[0] >= 'a' and id[0] <= 'f');
}

// spec: eval/evaluator - isStandardRefDes distinguishes standard from descriptive labels
test "isStandardRefDes" {
    try std.testing.expect(isStandardRefDes("U1"));
    try std.testing.expect(isStandardRefDes("C23"));
    try std.testing.expect(isStandardRefDes("SW1"));
    try std.testing.expect(isStandardRefDes("R_FBT") == false);
    try std.testing.expect(isStandardRefDes("stm32") == false);
    try std.testing.expect(isStandardRefDes("flash") == false);
    try std.testing.expect(isStandardRefDes("a") == false);
}

// spec: eval/evaluator - generateId registers each token so a second call cannot collide
test "generateId registers each token" {
    const alloc = std.testing.allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    const a = try generateId(&eval);
    defer alloc.free(a);
    const b = try generateId(&eval);
    defer alloc.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
    try std.testing.expect(eval.design_ids.contains(a));
    try std.testing.expect(eval.design_ids.contains(b));
}

// spec: eval/evaluator - parseChildIdSidecar reads (ids ("k" t)) pairs into a key-to-token map
test "parseChildIdSidecar parses pairs" {
    const alloc = std.testing.allocator;
    const parser_m = @import("../sexpr/parser.zig");
    const nodes = try parser_m.parse(alloc, "(decouple x (ids (\"100nF@P7#0\" a1b2c3d4)))");
    defer parser_m.freeNodes(alloc, nodes);
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    const children = nodes[0].asList().?;
    var sidecar = parseChildIdSidecar(&eval, children);
    defer sidecar.map.deinit(alloc);
    try std.testing.expect(sidecar.map.get("100nF@P7#0") != null);
    try std.testing.expectEqualStrings("a1b2c3d4", sidecar.map.get("100nF@P7#0").?);
}

// spec: eval/evaluator - getOrCreateChildId returns the stored token for a known key
test "getOrCreateChildId returns stored token" {
    const alloc = std.testing.allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var sidecar = ChildIdSidecar{ .map = .empty, .parent_offset = 0 };
    defer sidecar.map.deinit(alloc);
    try sidecar.map.put(alloc, "k", "deadbeef");
    const tok = try getOrCreateChildId(&eval, &sidecar, "k");
    try std.testing.expectEqualStrings("deadbeef", tok);
    try std.testing.expectEqual(@as(usize, 0), eval.pending_child_ids.items.len);
}

// spec: eval/evaluator - getOrCreateChildId mints and queues a token for an unknown key
test "getOrCreateChildId mints for unknown key" {
    const alloc = std.testing.allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var sidecar = ChildIdSidecar{ .map = .empty, .parent_offset = 7 };
    defer sidecar.map.deinit(alloc);
    const tok = try getOrCreateChildId(&eval, &sidecar, "newkey");
    defer alloc.free(tok);
    try std.testing.expectEqual(@as(usize, 8), tok.len);
    try std.testing.expectEqual(@as(usize, 1), eval.pending_child_ids.items.len);
    try std.testing.expectEqual(@as(u32, 7), eval.pending_child_ids.items[0].parent_form_offset);
}

// spec: eval/evaluator - reassignSubBlockIds takes a pinned child id from the (ids …) sidecar and seeds+queues a miss with the legacy derivation
test "reassignSubBlockIds is source-resident" {
    // page_allocator: seeds/keys are intentionally never freed (project convention).
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();

    var sidecar = ChildIdSidecar{ .map = .empty, .parent_offset = 7 };
    try sidecar.map.put(alloc, "R_FAP", "abcdef12"); // pinned in source

    var insts = [_]Instance{
        .{ .ref_des = "R_FAP", .label = "R_FAP", .component = "res", .value = "33R", .footprint = "f", .symbol = "s" },
        .{ .ref_des = "R_FAN", .label = "R_FAN", .component = "res", .value = "33R", .footprint = "f", .symbol = "s" },
    };
    var block = DesignBlock{ .name = "adc", .instances = &insts, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &.{} };

    const before = eval.pending_child_ids.items.len;
    try reassignSubBlockIds(&eval, &block, "adc1", &sidecar, "");

    // a pinned sidecar id is taken verbatim (not re-derived)
    try std.testing.expectEqualStrings("abcdef12", insts[0].id);
    // a miss is seeded with the legacy derivation and queued for write-back
    const seed = try deriveChildId(&eval, "adc1", "R_FAN", 0);
    try std.testing.expectEqualStrings(seed, insts[1].id);
    try std.testing.expectEqual(before + 1, eval.pending_child_ids.items.len);
}

// spec: eval/evaluator - reassignSubBlockIdsV4 derives each child id from the sub-block uuid and the child's stable origin_key
test "reassignSubBlockIdsV4 derives children from sub-block uuid + origin_key" {
    // page_allocator: derived ids are intentionally never freed (project convention).
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();

    var insts = [_]Instance{
        // named part: origin_key is the source name; the renumbered ref_des is ignored
        .{ .ref_des = "C106", .origin_key = "C_VCC", .component = "cap", .value = "1uF", .footprint = "f", .symbol = "s" },
        // decouple-style child: origin_key is the value@pin#index structural key
        .{ .ref_des = "C107", .origin_key = "10uF@4#0", .component = "cap", .value = "10uF", .footprint = "f", .symbol = "s" },
    };
    var block = DesignBlock{ .name = "adc", .instances = &insts, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &.{} };

    try reassignSubBlockIdsV4(&eval, &block, "fade94db");

    // each child id == hash(subblock_uuid, origin_key), independent of ref_des
    try std.testing.expectEqualStrings(try deriveChildId(&eval, "fade94db", "C_VCC", 0), insts[0].id);
    try std.testing.expectEqualStrings(try deriveChildId(&eval, "fade94db", "10uF@4#0", 0), insts[1].id);
}
