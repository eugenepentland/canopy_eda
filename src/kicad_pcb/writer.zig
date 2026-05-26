//! Apply a sync-plan ops list to a parsed `.kicad_pcb` AST and re-serialise
//! the result. The on-disk write itself is a separate concern handled by
//! the HTTP layer (fsync + atomic rename); this module only owns the AST
//! mutation and pretty-print.
//!
//! Op vocabulary mirrors what `serve/sync.zig` emits for the Go IPC
//! agent: add, swap_footprint, remove, set_field, set_pad_net, set_locked.
//! `flag_stale` is informational only — KiCad's UI shows the marker
//! through IPC, but with file-based sync there's nothing to write; the
//! op is silently skipped.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const parser = @import("../sexpr/parser.zig");
const printer = @import("../sexpr/printer.zig");
const fmt_const = @import("format.zig");

const Node = ast.Node;
const Span = ast.Span;

const PROP_REFERENCE = fmt_const.PROP_REFERENCE;
const PROP_VALUE = fmt_const.PROP_VALUE;
const PROP_CANOPY_UUID = fmt_const.PROP_CANOPY_UUID;

// S-expression head atoms used in multiple builder helpers.
const FORM_FOOTPRINT = "footprint";
const FORM_PROPERTY = "property";
const FORM_AT = "at";
const FORM_UUID = "uuid";
const FORM_LAYER = "layer";
const FORM_LOCKED = "locked";
const FORM_NET = "net";
const FORM_PAD = "pad";

// Section-staging board-graphic conversion (proto nm → .kicad_pcb mm).
const NM_PER_MM: f64 = 1_000_000.0;
const DEFAULT_STROKE_MM: f64 = 0.15;
const DEFAULT_TEXT_SIZE_MM: f64 = 2.0;
const TEXT_THICKNESS_RATIO: f64 = 0.15;
// UUID 8-4-4-4-12 hex-segment boundaries within the 32-char digest.
const UUID_SEG_A = 8;
const UUID_SEG_B = 12;
const UUID_SEG_C = 16;
const UUID_SEG_D = 20;
const UUID_HEX_LEN = 32;

pub const WriteError = error{ InvalidPcbRoot, InvalidOps, InvalidAdd } ||
    std.mem.Allocator.Error ||
    parser.ParseError ||
    std.json.ParseError(std.json.Scanner);

/// Apply the op list in `ops_json` to the `.kicad_pcb` text in `source`
/// and return the new file text. All allocations come from `arena`.
pub fn applyOpsToSource(arena: std.mem.Allocator, source: []const u8, ops_json: []const u8) WriteError![]const u8 {
    const nodes = try parser.parse(arena, source);
    if (nodes.len == 0 or !nodes[0].isForm("kicad_pcb")) return error.InvalidPcbRoot;

    const parsed_ops = try std.json.parseFromSlice(std.json.Value, arena, ops_json, .{});
    const ops_val = parsed_ops.value;
    if (ops_val != .array) return error.InvalidOps;

    const root_children = nodes[0].asList() orelse return error.InvalidPcbRoot;
    const new_root = try applyOps(arena, root_children, ops_val.array.items);

    var out_nodes = try arena.alloc(Node, 1);
    out_nodes[0] = new_root;
    return try printer.print(arena, out_nodes);
}

/// Stats returned alongside the rewritten file — Phase 4's UI surfaces
/// these in the success message so the user sees "added 2, removed 1,
/// pad-nets updated 14" instead of just "ok".
pub const ApplyStats = struct {
    added: u32 = 0,
    removed: u32 = 0,
    swapped: u32 = 0,
    fields_set: u32 = 0,
    pad_nets_set: u32 = 0,
    locked_changed: u32 = 0,
    /// Standalone board graphics written (section staging boxes + labels).
    board_items: u32 = 0,
    /// Metadata properties hidden this sync — Datasheet, Description, and the
    /// canopy_* tags get `(hide yes)` so F.Fab/F.SilkS stay clean.
    fields_hidden: u32 = 0,
    /// Properties un-hidden this sync — Value stays visible so parts are
    /// identifiable, so any `(hide yes)` a prior sync added to it is stripped
    /// back off. (Reference/refdes is hidden by default — see propertyStaysVisible.)
    fields_shown: u32 = 0,
};

/// Same as `applyOpsToSource` but also returns per-category counts.
pub fn applyOpsToSourceWithStats(
    arena: std.mem.Allocator,
    source: []const u8,
    ops_json: []const u8,
    stats: *ApplyStats,
) WriteError![]const u8 {
    const nodes = try parser.parse(arena, source);
    if (nodes.len == 0 or !nodes[0].isForm("kicad_pcb")) return error.InvalidPcbRoot;

    const parsed_ops = try std.json.parseFromSlice(std.json.Value, arena, ops_json, .{});
    const ops_val = parsed_ops.value;
    if (ops_val != .array) return error.InvalidOps;

    const root_children = nodes[0].asList() orelse return error.InvalidPcbRoot;
    const new_root = try applyOpsCounted(arena, root_children, ops_val.array.items, stats);

    var out_nodes = try arena.alloc(Node, 1);
    out_nodes[0] = new_root;
    return try printer.print(arena, out_nodes);
}

fn applyOps(arena: std.mem.Allocator, root_children: []const Node, ops: []const std.json.Value) WriteError!Node {
    var stats: ApplyStats = .{};
    return applyOpsCounted(arena, root_children, ops, &stats);
}

fn applyOpsCounted(arena: std.mem.Allocator, root_children: []const Node, ops: []const std.json.Value, stats: *ApplyStats) WriteError!Node {
    // First: walk the top-level once to:
    //  - record max net-ID for allocating new nets
    //  - build (kicad_uuid → index-of-footprint-in-root) lookup
    //  - build a set of canopy_uuids already on the board so `add` ops
    //    targeting an existing canopy can be detected and skipped
    //    (the diff brain emits `add` whenever its by_uuid lookup misses;
    //    duplicate canopy_uuids in the design's .bom make it miss
    //    forever and we'd otherwise grow the board by one fp per push).
    var max_net_id: i64 = -1;
    var fp_by_uuid = std.StringHashMap(usize).init(arena);
    var net_id_by_name = std.StringHashMap(i64).init(arena);
    var existing_canopy_uuids = std.StringHashMap(void).init(arena);
    for (root_children, 0..) |child, i| {
        if (child.isForm("net")) {
            const cl = child.asList() orelse continue;
            if (cl.len < 3) continue;
            const id_num = cl[1].asNumber() orelse continue;
            const id_i64: i64 = @intFromFloat(id_num);
            if (id_i64 > max_net_id) max_net_id = id_i64;
            if (cl[2].asString()) |name| try net_id_by_name.put(name, id_i64);
        } else if (child.isForm(FORM_FOOTPRINT)) {
            if (footprintKicadUuid(child)) |u| try fp_by_uuid.put(u, i);
            if (footprintCanopyUuid(child)) |c| try existing_canopy_uuids.put(c, {});
        }
    }

    // Apply each op, accumulating:
    //  - mutated_fp[index] = replacement node for the footprint at that index
    //  - removed_fp_indices[] = footprints to drop from output
    //  - extra_footprints[] = new footprints (add ops)
    //  - extra_nets[] = new (net N "name") top-level declarations to insert
    //    after the last existing top-level (net …) form. Only populated
    //    when the input file already carries top-level declarations; for
    //    pcbnew-saved boards (KiCad 10 v20260206 onward) the declarations
    //    are omitted and we keep that property by leaving extra_nets empty.
    var mutated_fp = std.AutoHashMap(usize, Node).init(arena);
    var removed_fp_indices = std.AutoHashMap(usize, void).init(arena);
    var extra_footprints: std.ArrayListUnmanaged(Node) = .empty;
    var extra_graphics: std.ArrayListUnmanaged(Node) = .empty;
    var extra_nets: std.ArrayListUnmanaged(Node) = .empty;
    const had_top_level_nets = max_net_id >= 0;

    for (ops) |op_val| {
        if (op_val != .object) continue;
        const op_obj = op_val.object;
        const op_name_v = op_obj.get("op") orelse continue;
        if (op_name_v != .string) continue;
        const op_name = op_name_v.string;
        const target = jsonStr(op_obj.get("uuid"));

        if (std.mem.eql(u8, op_name, "flag_stale")) continue; // informational

        if (std.mem.eql(u8, op_name, "remove")) {
            if (fp_by_uuid.get(target)) |idx| {
                try removed_fp_indices.put(idx, {});
                stats.removed += 1;
            }
            continue;
        }

        if (std.mem.eql(u8, op_name, "add")) {
            // Idempotency: if the board already carries a footprint with
            // this canopy_uuid, drop the add. The diff brain's by_uuid
            // map only registers one fp per canopy when duplicates
            // exist, so it re-emits the same add forever; without this
            // check every click adds another duplicate fp.
            if (existing_canopy_uuids.contains(target)) continue;
            const new_fp = try buildAddFootprint(arena, op_obj, &max_net_id, &net_id_by_name, &extra_nets);
            try extra_footprints.append(arena, new_fp);
            try existing_canopy_uuids.put(target, {});
            stats.added += 1;
            continue;
        }

        if (std.mem.eql(u8, op_name, "create_board_item")) {
            // Standalone board graphic (section staging box / label). The
            // `item` is the proto-canonical JSON the IPC agent feeds to KiCad;
            // here we translate it into a top-level `(gr_rect …)` / `(gr_text …)`.
            const item_v = op_obj.get("item") orelse continue;
            if (item_v != .object) continue;
            if (try buildBoardGraphic(arena, item_v.object)) |node| {
                try extra_graphics.append(arena, node);
                stats.board_items += 1;
            }
            continue;
        }

        // Remaining ops target an existing footprint.
        const idx = fp_by_uuid.get(target) orelse continue;
        const current = mutated_fp.get(idx) orelse root_children[idx];

        if (std.mem.eql(u8, op_name, "set_pad_net")) {
            const pad = jsonStr(op_obj.get("pad"));
            const net = jsonStr(op_obj.get("net"));
            if (pad.len == 0) continue;
            // An empty net clears the pad: drop its `(net …)` form so the pad
            // becomes unconnected. Used when a signal moves off a pad (the
            // design no longer assigns it) so the stale net doesn't linger.
            const updated = if (net.len == 0)
                (try clearPadNet(arena, current, pad)) orelse continue
            else blk: {
                const id = try resolveNetId(arena, net, &max_net_id, &net_id_by_name, &extra_nets);
                break :blk (try setPadNet(arena, current, pad, id, net)) orelse continue;
            };
            try mutated_fp.put(idx, updated);
            stats.pad_nets_set += 1;
            continue;
        }

        if (std.mem.eql(u8, op_name, "set_field")) {
            const field = jsonStr(op_obj.get("field"));
            const value = jsonStr(op_obj.get("value"));
            if (field.len == 0) continue;
            const updated = try setProperty(arena, current, field, value) orelse continue;
            try mutated_fp.put(idx, updated);
            stats.fields_set += 1;
            continue;
        }

        if (std.mem.eql(u8, op_name, "set_locked")) {
            const locked = jsonBool(op_obj.get("locked"));
            const updated = try setLocked(arena, current, locked) orelse continue;
            try mutated_fp.put(idx, updated);
            stats.locked_changed += 1;
            continue;
        }

        if (std.mem.eql(u8, op_name, "swap_footprint")) {
            const new_name = jsonStr(op_obj.get("new_footprint_name"));
            const kmod = jsonStr(op_obj.get("kicad_mod"));
            const pad_nets = op_obj.get("pad_nets");
            if (new_name.len == 0 or kmod.len == 0) continue;
            const updated = try swapFootprint(arena, current, new_name, kmod, pad_nets, &max_net_id, &net_id_by_name, &extra_nets);
            try mutated_fp.put(idx, updated);
            stats.swapped += 1;
            continue;
        }
    }

    // No canonicalisation pass — KiCad 10 v20260206 saves in-element net
    // references as `(net "name")` (name only). pcbnew's parser rejects
    // `(net <id> "name")` inside segments/vias/zones, so rewriting forms
    // is actively harmful: an earlier version of this writer did exactly
    // that and corrupted boards on every push (parser error: "Expecting
    // ')'" at the first segment's net reference). Set_pad_net replaces
    // its target pad's net form via makeNetForm (also name-only); every
    // untouched form passes through unchanged.

    // Build the new root child list: skip removed footprints, swap in
    // mutated ones, append any new top-level (net …) declarations after
    // the last existing one (only when the input had them), and append
    // new footprints at the end.
    var new_children: std.ArrayListUnmanaged(Node) = .empty;
    var inserted_extra_nets = false;
    var last_net_idx: ?usize = null;
    if (had_top_level_nets) {
        for (root_children, 0..) |child, i| {
            if (child.isForm(FORM_NET)) last_net_idx = i;
        }
    }
    for (root_children, 0..) |child, i| {
        if (removed_fp_indices.contains(i)) continue;
        var out_child = mutated_fp.get(i) orelse child;
        // Normalise property visibility on every board footprint: hide the
        // refdes (Reference) and metadata (Datasheet, Description, bare canopy_*
        // tags from older syncs); keep Value visible so parts stay identifiable.
        if (out_child.isForm(FORM_FOOTPRINT)) {
            if (try normalizePropertyVisibility(arena, out_child, &stats.fields_hidden, &stats.fields_shown)) |fixed| out_child = fixed;
        }
        try new_children.append(arena, out_child);
        if (last_net_idx) |lni| {
            if (i == lni and !inserted_extra_nets) {
                for (extra_nets.items) |n| try new_children.append(arena, n);
                inserted_extra_nets = true;
            }
        }
    }
    // had_top_level_nets == false: leave extra_nets unused. pcbnew accepts
    // a file with no top-level declarations and infers nets from
    // in-element references; inserting `(net N "name")` declarations into
    // a header-only file would land them at the wrong position (before
    // (version …)) and break the parse.
    // New footprints carry library Datasheet/Description props plus the
    // canopy_* fields makeProperty already hides; normalise them too so a
    // freshly-added part lands with a clean fab/silk and a visible refdes+value.
    for (extra_footprints.items) |fp| {
        var out_fp = fp;
        if (try normalizePropertyVisibility(arena, fp, &stats.fields_hidden, &stats.fields_shown)) |fixed| out_fp = fixed;
        try new_children.append(arena, out_fp);
    }
    // Section staging boxes / labels (Dwgs.User graphics) go last.
    for (extra_graphics.items) |g| try new_children.append(arena, g);

    return Node.list(Span.zero, try new_children.toOwnedSlice(arena));
}

// ── AST helpers ────────────────────────────────────────────────────────

fn jsonStr(v: ?std.json.Value) []const u8 {
    const val = v orelse return "";
    return if (val == .string) val.string else "";
}

fn jsonBool(v: ?std.json.Value) bool {
    const val = v orelse return false;
    return val == .bool and val.bool;
}

/// Read a JSON number (proto nanometre value) as f64; missing/non-number → 0.
fn jsonNumNm(v: ?std.json.Value) f64 {
    const val = v orelse return 0;
    return switch (val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => 0,
    };
}

const Vec2Mm = struct { x: f64, y: f64 };

/// A proto Vector2 ({xNm,yNm}) converted to mm. proto omits zero fields, so
/// a missing component reads as 0.
fn jsonVec2Mm(v: ?std.json.Value) ?Vec2Mm {
    const val = v orelse return null;
    if (val != .object) return null;
    return .{
        .x = jsonNumNm(val.object.get("xNm")) / NM_PER_MM,
        .y = jsonNumNm(val.object.get("yNm")) / NM_PER_MM,
    };
}

/// Map a proto BoardLayer enum string (e.g. "BL_Dwgs_User") to the
/// `.kicad_pcb` canonical layer name. Section staging graphics only ever
/// use Dwgs.User; the others are here for completeness.
fn protoLayerToKicad(proto: []const u8) []const u8 {
    if (std.mem.eql(u8, proto, "BL_Cmts_User")) return "Cmts.User";
    if (std.mem.eql(u8, proto, "BL_F_SilkS")) return "F.SilkS";
    if (std.mem.eql(u8, proto, "BL_B_SilkS")) return "B.SilkS";
    return "Dwgs.User";
}

/// Stroke width (mm) from a proto shape's attributes.stroke.width.valueNm,
/// defaulting to 0.15 mm. Flat to stay under the nesting cap.
fn jsonStrokeWidthMm(shape: std.json.ObjectMap) f64 {
    const a = shape.get("attributes") orelse return DEFAULT_STROKE_MM;
    if (a != .object) return DEFAULT_STROKE_MM;
    const s = a.object.get("stroke") orelse return DEFAULT_STROKE_MM;
    if (s != .object) return DEFAULT_STROKE_MM;
    const wv = s.object.get("width") orelse return DEFAULT_STROKE_MM;
    if (wv != .object) return DEFAULT_STROKE_MM;
    const nm = jsonNumNm(wv.object.get("valueNm"));
    return if (nm > 0) nm / NM_PER_MM else DEFAULT_STROKE_MM;
}

/// Text size (mm) from a proto text's attributes.size.xNm, default 2.0 mm.
fn jsonTextSizeMm(text_obj: std.json.ObjectMap) f64 {
    const a = text_obj.get("attributes") orelse return DEFAULT_TEXT_SIZE_MM;
    if (a != .object) return DEFAULT_TEXT_SIZE_MM;
    const sz = jsonVec2Mm(a.object.get("size")) orelse return DEFAULT_TEXT_SIZE_MM;
    return if (sz.x > 0) sz.x else DEFAULT_TEXT_SIZE_MM;
}

/// Derive a stable UUID (8-4-4-4-12) from a seed string so re-emitting the
/// same graphic is deterministic.
fn boardItemUuid(arena: std.mem.Allocator, seed: []const u8) ![]const u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(seed, &h, .{});
    const hex = std.fmt.bytesToHex(h[0 .. UUID_HEX_LEN / 2].*, .lower);
    return std.fmt.allocPrint(arena, "{s}-{s}-{s}-{s}-{s}", .{
        hex[0..UUID_SEG_A],
        hex[UUID_SEG_A..UUID_SEG_B],
        hex[UUID_SEG_B..UUID_SEG_C],
        hex[UUID_SEG_C..UUID_SEG_D],
        hex[UUID_SEG_D..UUID_HEX_LEN],
    });
}

/// A `(gr_rect …)` node from the proto rectangle. Built as text + reparsed.
fn buildGrRect(arena: std.mem.Allocator, shape: std.json.ObjectMap, layer: []const u8) WriteError!?Node {
    const rect_v = shape.get("rectangle") orelse return null;
    if (rect_v != .object) return null;
    const tl = jsonVec2Mm(rect_v.object.get("topLeft")) orelse return null;
    const br = jsonVec2Mm(rect_v.object.get("bottomRight")) orelse return null;
    const stroke_mm = jsonStrokeWidthMm(shape);
    const seed = try std.fmt.allocPrint(arena, "rect:{d}:{d}:{d}:{d}", .{ tl.x, tl.y, br.x, br.y });
    const text = try std.fmt.allocPrint(
        arena,
        "(gr_rect (start {d} {d}) (end {d} {d}) (stroke (width {d}) (type default)) (fill no) (layer \"{s}\") (uuid \"{s}\"))",
        .{ tl.x, tl.y, br.x, br.y, stroke_mm, layer, try boardItemUuid(arena, seed) },
    );
    const nodes = try parser.parse(arena, text);
    return if (nodes.len == 0) null else nodes[0];
}

/// A `(gr_text …)` node from the proto BoardText. Built as text + reparsed.
fn buildGrText(arena: std.mem.Allocator, text_obj: std.json.ObjectMap, layer: []const u8) WriteError!?Node {
    const pos = jsonVec2Mm(text_obj.get("position")) orelse return null;
    const label = jsonStr(text_obj.get("text"));
    if (label.len == 0) return null;
    const size_mm = jsonTextSizeMm(text_obj);
    const seed = try std.fmt.allocPrint(arena, "text:{s}:{d}:{d}", .{ label, pos.x, pos.y });
    const text = try std.fmt.allocPrint(
        arena,
        "(gr_text \"{s}\" (at {d} {d} 0) (layer \"{s}\") (uuid \"{s}\") (effects (font (size {d} {d}) (thickness {d}))))",
        .{ label, pos.x, pos.y, layer, try boardItemUuid(arena, seed), size_mm, size_mm, size_mm * TEXT_THICKNESS_RATIO },
    );
    const nodes = try parser.parse(arena, text);
    return if (nodes.len == 0) null else nodes[0];
}

/// Translate a `create_board_item` proto object into a top-level
/// `(gr_rect …)` / `(gr_text …)` node. Returns null for shapes not drawn on disk.
fn buildBoardGraphic(arena: std.mem.Allocator, item: std.json.ObjectMap) WriteError!?Node {
    const type_url = jsonStr(item.get("@type"));
    const layer = protoLayerToKicad(jsonStr(item.get("layer")));
    if (std.mem.endsWith(u8, type_url, "BoardGraphicShape")) {
        const shape_v = item.get("shape") orelse return null;
        if (shape_v != .object) return null;
        return buildGrRect(arena, shape_v.object, layer);
    }
    if (std.mem.endsWith(u8, type_url, "BoardText")) {
        const text_v = item.get("text") orelse return null;
        if (text_v != .object) return null;
        return buildGrText(arena, text_v.object, layer);
    }
    return null;
}

fn footprintKicadUuid(fp: Node) ?[]const u8 {
    const cl = fp.asList() orelse return null;
    for (cl[1..]) |sub| {
        if (!sub.isForm("uuid")) continue;
        const ul = sub.asList() orelse continue;
        if (ul.len < 2) continue;
        return ul[1].asString();
    }
    return null;
}

/// Returns the value of the footprint's `(property "canopy_uuid" "…")`
/// — the cross-sync identity tag the diff brain matches design
/// instances against. Null when the fp hasn't been synced yet (manually
/// placed in pcbnew or pre-Canopy).
fn footprintCanopyUuid(fp: Node) ?[]const u8 {
    const cl = fp.asList() orelse return null;
    for (cl[1..]) |sub| {
        if (!sub.isForm(FORM_PROPERTY)) continue;
        const pl = sub.asList() orelse continue;
        if (pl.len < 3) continue;
        const k = pl[1].asString() orelse continue;
        if (!std.mem.eql(u8, k, PROP_CANOPY_UUID)) continue;
        return pl[2].asString();
    }
    return null;
}

fn resolveNetId(
    arena: std.mem.Allocator,
    name: []const u8,
    max_net_id: *i64,
    net_id_by_name: *std.StringHashMap(i64),
    extra_nets: *std.ArrayListUnmanaged(Node),
) std.mem.Allocator.Error!i64 {
    if (net_id_by_name.get(name)) |id| return id;
    max_net_id.* += 1;
    const id = max_net_id.*;
    try net_id_by_name.put(name, id);
    // Build a `(net <id> "<name>")` form.
    var children = try arena.alloc(Node, 3);
    children[0] = Node.atom(Span.zero, "net");
    children[1] = Node.int(Span.zero, id);
    children[2] = Node.string(Span.zero, name);
    try extra_nets.append(arena, Node.list(Span.zero, children));
    return id;
}

/// Walk `fp`'s children, replacing the first `(pad "<num>" …)` whose
/// inner `(net …)` we want to retarget. Other pads pass through unchanged.
/// Returns null when the targeted pad already references `net_name` —
/// idempotency for repeated pushes against an already-synced board.
/// Drop the `(net …)` form from the named pad, leaving it unconnected.
/// Returns null (no-op) if the pad is absent or already has no net.
fn clearPadNet(arena: std.mem.Allocator, fp: Node, pad_num: []const u8) std.mem.Allocator.Error!?Node {
    const cl = fp.asList() orelse return fp;
    var new_children = try arena.alloc(Node, cl.len);
    var changed = false;
    for (cl, 0..) |sub, i| {
        new_children[i] = sub;
        if (!sub.isForm("pad")) continue;
        const pl = sub.asList() orelse continue;
        if (pl.len < 2) continue;
        const num = fmt_const.padNumberText(arena, pl[1]) orelse continue;
        if (!std.mem.eql(u8, num, pad_num)) continue;
        var has_net = false;
        for (pl) |p| {
            if (p.isForm(FORM_NET)) {
                has_net = true;
                break;
            }
        }
        if (!has_net) continue; // already cleared
        var kept: std.ArrayListUnmanaged(Node) = .empty;
        for (pl) |p| {
            if (p.isForm(FORM_NET)) continue;
            try kept.append(arena, p);
        }
        new_children[i] = Node.list(Span.zero, try kept.toOwnedSlice(arena));
        changed = true;
    }
    if (!changed) return null;
    return Node.list(Span.zero, new_children);
}

fn setPadNet(arena: std.mem.Allocator, fp: Node, pad_num: []const u8, net_id: i64, net_name: []const u8) std.mem.Allocator.Error!?Node {
    const cl = fp.asList() orelse return fp;
    var new_children = try arena.alloc(Node, cl.len);
    var changed = false;
    for (cl, 0..) |sub, i| {
        new_children[i] = sub;
        if (!sub.isForm("pad")) continue;
        const pl = sub.asList() orelse continue;
        if (pl.len < 2) continue;
        // Modern .sexp-generated footprints quote the pad name (`(pad "1" …)`);
        // legacy `(module …)` sources leave it bare (`(pad A1 …)`); KiCad
        // re-saves numeric pads as a bare integer (`(pad 1 …)`). padNumberText
        // matches all three, or those pads never get their nets attached.
        const num = fmt_const.padNumberText(arena, pl[1]) orelse continue;
        if (!std.mem.eql(u8, num, pad_num)) continue;
        const replaced = try replacePadNet(arena, sub, net_id, net_name);
        if (replaced) |r| {
            new_children[i] = r;
            changed = true;
        }
    }
    if (!changed) return null;
    return Node.list(Span.zero, new_children);
}

/// Returns the pad with its `(net …)` form swapped to the requested net,
/// or null when the pad already references that net (no change needed).
fn replacePadNet(arena: std.mem.Allocator, pad: Node, net_id: i64, net_name: []const u8) std.mem.Allocator.Error!?Node {
    const pl = pad.asList() orelse return pad;
    // Probe the current net reference first so a redundant retarget
    // (the pad already points at `net_name`) reports as a no-op. Pads
    // without any `(net …)` form fall through to the append path below.
    for (pl) |sub| {
        if (!sub.isForm(FORM_NET)) continue;
        const nl = sub.asList() orelse continue;
        if (nl.len < 2) continue;
        const existing = nl[1].asString() orelse continue;
        if (std.mem.eql(u8, existing, net_name)) return null;
        break;
    }

    var new_children: std.ArrayListUnmanaged(Node) = .empty;
    var found = false;
    for (pl) |sub| {
        if (sub.isForm("net")) {
            try new_children.append(arena, try makeNetForm(arena, net_id, net_name));
            found = true;
        } else {
            try new_children.append(arena, sub);
        }
    }
    if (!found) try new_children.append(arena, try makeNetForm(arena, net_id, net_name));
    return Node.list(Span.zero, try new_children.toOwnedSlice(arena));
}

fn makeNetForm(arena: std.mem.Allocator, id: i64, name: []const u8) std.mem.Allocator.Error!Node {
    // `id` is retained in the signature for callers that still thread it
    // through (set_pad_net's resolveNetId, swapFootprint's pad-net
    // remapping). It's unused here: KiCad 10 v20260206 writes pad /
    // segment / via / zone net references as `(net "name")` — name only.
    // The `(net <id> "name")` form is reserved for top-level declarations
    // and is emitted directly by resolveNetId, never via this helper.
    _ = id;
    var children = try arena.alloc(Node, 2);
    children[0] = Node.atom(Span.zero, FORM_NET);
    children[1] = Node.string(Span.zero, name);
    return Node.list(Span.zero, children);
}

/// Replace the value-string of the first `(property "<key>" …)` matching
/// `key`, or append a fresh `(property "<key>" "<value>")` when none
/// exists. Keeps any KiCad-style `(at …)` / `(layer …)` / `(effects …)`
/// sub-forms on the matched property — only the value slot changes.
/// Returns null when the existing value already equals `value` (idempotent
/// no-op) so the caller skips both stats counting and a redundant write.
fn setProperty(arena: std.mem.Allocator, fp: Node, key: []const u8, value: []const u8) std.mem.Allocator.Error!?Node {
    // The diff emits the lowercase IPC field names ("reference",
    // "value") for the well-known KiCad property slots. KiCad's
    // .kicad_pcb stores those as the capitalised "Reference" /
    // "Value" properties. Translate before lookup so a `set_field` op
    // updates the existing property in place instead of appending a
    // bogus second copy.
    const canonical_key = canonicalPropertyKey(key);
    const cl = fp.asList() orelse return fp;
    var new_children: std.ArrayListUnmanaged(Node) = .empty;
    var found = false;
    for (cl) |sub| {
        if (sub.isForm(FORM_PROPERTY)) {
            const pl = sub.asList() orelse {
                try new_children.append(arena, sub);
                continue;
            };
            if (pl.len < 3) {
                try new_children.append(arena, sub);
                continue;
            }
            const k = pl[1].asString() orelse {
                try new_children.append(arena, sub);
                continue;
            };
            if (std.mem.eql(u8, k, canonical_key)) {
                // Idempotency: if the slot already holds the requested
                // value, return null so the caller leaves the AST and
                // stats alone. Without this the file-based sync rewrites
                // the same set_field on every push, making every click
                // report "X fields_set" forever.
                if (pl[2].asString()) |existing| {
                    if (std.mem.eql(u8, existing, value)) return null;
                }
                var pchildren = try arena.alloc(Node, pl.len);
                pchildren[0] = pl[0];
                pchildren[1] = pl[1];
                pchildren[2] = Node.string(Span.zero, value);
                for (pl[3..], 3..) |x, i| pchildren[i] = x;
                try new_children.append(arena, Node.list(Span.zero, pchildren));
                found = true;
                continue;
            }
        }
        try new_children.append(arena, sub);
    }
    if (!found) try new_children.append(arena, try makeProperty(arena, canonical_key, value));
    return Node.list(Span.zero, try new_children.toOwnedSlice(arena));
}

/// Translate the lowercase IPC-style field names the diff emits to the
/// canonical KiCad property keys stored in the .kicad_pcb. Unknown keys
/// pass through so user-defined fields (canopy_uuid, custom design
/// properties) still work.
fn canonicalPropertyKey(key: []const u8) []const u8 {
    if (std.mem.eql(u8, key, "reference")) return PROP_REFERENCE;
    if (std.mem.eql(u8, key, "value")) return PROP_VALUE;
    if (std.mem.eql(u8, key, "footprint")) return "Footprint";
    if (std.mem.eql(u8, key, "datasheet")) return "Datasheet";
    if (std.mem.eql(u8, key, "description")) return "Description";
    if (std.mem.eql(u8, key, "mpn")) return "MPN";
    if (std.mem.eql(u8, key, "manufacturer")) return "Manufacturer";
    return key;
}

fn makeProperty(arena: std.mem.Allocator, key: []const u8, value: []const u8) std.mem.Allocator.Error!Node {
    // Value stays visible so parts are identifiable on the board; the Reference
    // (refdes) and every other synced property (metadata, not board graphics)
    // are emitted hidden so KiCad doesn't draw them as text on F.Fab/F.SilkS.
    const n: usize = if (propertyStaysVisible(key)) 3 else 4;
    var children = try arena.alloc(Node, n);
    children[0] = Node.atom(Span.zero, FORM_PROPERTY);
    children[1] = Node.string(Span.zero, key);
    children[2] = Node.string(Span.zero, value);
    if (n == 4) children[3] = try makeHideForm(arena);
    return Node.list(Span.zero, children);
}

/// Value is kept visible on the board so each part is identifiable by its
/// value text; the Reference (refdes) is hidden by default on sync (it clutters
/// the silk/fab and is recoverable from the BOM / canopy_uuid), and every other
/// property (Datasheet, Description, canopy_* metadata, custom BOM fields) is
/// hidden to keep the fab/silk layers clean.
fn propertyStaysVisible(key: []const u8) bool {
    return std.mem.eql(u8, key, PROP_VALUE);
}

/// `(hide yes)` — mirrors `makeLockedForm`'s `(locked yes)` idiom.
fn makeHideForm(arena: std.mem.Allocator) std.mem.Allocator.Error!Node {
    var children = try arena.alloc(Node, 2);
    children[0] = Node.atom(Span.zero, "hide");
    children[1] = Node.atom(Span.zero, "yes");
    return Node.list(Span.zero, children);
}

/// True when a `(property …)` child list already carries a `(hide yes)` form.
fn propertyHidden(pl: []const Node) bool {
    if (pl.len < 4) return false;
    for (pl[3..]) |sub| {
        if (sub.isForm("hide") and formAtomChildEqualsLocal(sub, "yes")) return true;
    }
    return false;
}

/// Copy a `(property key value …)` list, inserting `(hide yes)` right after
/// the value slot (KiCad parses property sub-forms order-independently).
fn withHideForm(arena: std.mem.Allocator, pl: []const Node) std.mem.Allocator.Error!Node {
    var children = try arena.alloc(Node, pl.len + 1);
    children[0] = pl[0];
    children[1] = pl[1];
    children[2] = pl[2];
    children[3] = try makeHideForm(arena);
    for (pl[3..], 4..) |x, i| children[i] = x;
    return Node.list(Span.zero, children);
}

/// Copy a `(property …)` list with every `(hide yes)` sub-form removed, so a
/// previously-hidden Reference/Value renders again. Other sub-forms (at,
/// layer, uuid, effects) are preserved in their original order.
fn withoutHideForm(arena: std.mem.Allocator, pl: []const Node) std.mem.Allocator.Error!Node {
    var children: std.ArrayListUnmanaged(Node) = .empty;
    for (pl) |sub| {
        if (sub.isForm("hide") and formAtomChildEqualsLocal(sub, "yes")) continue;
        try children.append(arena, sub);
    }
    return Node.list(Span.zero, try children.toOwnedSlice(arena));
}

/// Normalise property visibility on `fp`: hide the refdes (Reference) and
/// metadata still showing (Datasheet, Description, canopy_* …), and un-hide
/// Value so parts stay identifiable. Bumps `hidden` per field newly hidden
/// and `shown` per field un-hidden; returns the rewritten footprint, or null
/// when nothing changed so the caller keeps the original node and skips a
/// redundant rewrite.
fn normalizePropertyVisibility(arena: std.mem.Allocator, fp: Node, hidden: *u32, shown: *u32) std.mem.Allocator.Error!?Node {
    const cl = fp.asList() orelse return null;
    var changed = false;
    var new_children: std.ArrayListUnmanaged(Node) = .empty;
    for (cl) |sub| {
        if (propertyNeedsHide(sub)) |pl| {
            try new_children.append(arena, try withHideForm(arena, pl));
            hidden.* += 1;
            changed = true;
        } else if (propertyNeedsUnhide(sub)) |pl| {
            try new_children.append(arena, try withoutHideForm(arena, pl));
            shown.* += 1;
            changed = true;
        } else {
            try new_children.append(arena, sub);
        }
    }
    if (!changed) return null;
    return Node.list(Span.zero, try new_children.toOwnedSlice(arena));
}

/// Shared guard: the child list of `sub` when it is a `(property key value …)`
/// with a string key, else null.
fn propertyChildList(sub: Node) ?[]const Node {
    if (!sub.isForm(FORM_PROPERTY)) return null;
    const pl = sub.asList() orelse return null;
    if (pl.len < 3) return null;
    if (pl[1].asString() == null) return null;
    return pl;
}

/// When `sub` is a *visible* property that should be hidden (anything but
/// Value — i.e. the refdes and all metadata) return its child list so the
/// caller can add `(hide yes)`. Null otherwise.
fn propertyNeedsHide(sub: Node) ?[]const Node {
    const pl = propertyChildList(sub) orelse return null;
    if (propertyStaysVisible(pl[1].asString().?)) return null;
    if (propertyHidden(pl)) return null;
    return pl;
}

/// When `sub` is a *hidden* Value property return its child list so the caller
/// can strip the `(hide yes)` and make it render. Null otherwise.
fn propertyNeedsUnhide(sub: Node) ?[]const Node {
    const pl = propertyChildList(sub) orelse return null;
    if (!propertyStaysVisible(pl[1].asString().?)) return null;
    if (!propertyHidden(pl)) return null;
    return pl;
}

/// Toggle a footprint's lock state. KiCad 7+ stores the bit as a
/// `(locked yes)` sibling of `(at …)` — present when locked, absent
/// when unlocked. Matches the reader's view of the same form. Returns
/// null when the existing state already matches `locked` so repeated
/// pushes don't redundantly rewrite an unchanged footprint.
fn setLocked(arena: std.mem.Allocator, fp: Node, locked: bool) std.mem.Allocator.Error!?Node {
    const cl = fp.asList() orelse return fp;
    // Probe the current state first: an existing `(locked yes)` form
    // means locked=true; its absence (or `(locked no)`) means false.
    var current_locked = false;
    for (cl) |sub| {
        if (sub.isForm("locked")) {
            current_locked = formAtomChildEqualsLocal(sub, "yes");
            break;
        }
    }
    if (current_locked == locked) return null;

    var new_children: std.ArrayListUnmanaged(Node) = .empty;
    var saw_existing = false;
    for (cl) |sub| {
        if (sub.isForm("locked")) {
            saw_existing = true;
            if (!locked) continue; // drop the form to "unlock"
            try new_children.append(arena, try makeLockedForm(arena));
            continue;
        }
        try new_children.append(arena, sub);
    }
    if (!saw_existing and locked) try new_children.append(arena, try makeLockedForm(arena));
    return Node.list(Span.zero, try new_children.toOwnedSlice(arena));
}

/// Mirror of the reader's `formAtomChildEquals` — true when a form like
/// `(locked yes)` matches `expected` in its second slot. Inlined here to
/// keep the writer free of a reader-module dependency cycle.
fn formAtomChildEqualsLocal(node: Node, expected: []const u8) bool {
    const cl = node.asList() orelse return false;
    if (cl.len < 2) return false;
    const atom = cl[1].asAtom() orelse return false;
    return std.mem.eql(u8, atom, expected);
}

fn makeLockedForm(arena: std.mem.Allocator) std.mem.Allocator.Error!Node {
    var children = try arena.alloc(Node, 2);
    children[0] = Node.atom(Span.zero, "locked");
    children[1] = Node.atom(Span.zero, "yes");
    return Node.list(Span.zero, children);
}

/// Swap/add geometry arrives either as a modern `(footprint …)` form
/// (generated from the .sexp) or, when a footprint has an imported
/// `lib/sources/*.kicad_mod`, as a legacy KiCad-5 `(module …)` form
/// passed through verbatim. Accept both as the kmod root.
fn isFootprintRootForm(node: Node) bool {
    return node.isForm(FORM_FOOTPRINT) or node.isForm("module");
}

/// Children of a swap/add kmod the writer must NOT copy into the board
/// footprint: placement/identity the board already owns (at, uuid, layer)
/// and every `(fp_text …)` form. Modern boards carry ref/value as
/// `(property …)` and the swap/add reissues them via follow-on set_field
/// ops, so the legacy reference/value text is redundant. The `user` fab
/// text is dropped too because its unquoted `%R`/`%V` field tokens don't
/// survive the s-expr round-trip (they split into `%` + `R`), producing a
/// .kicad_pcb KiCad refuses to parse. The proven .sexp-generated path
/// emits no fp_text at all, so dropping all of it matches that shape.
fn skipKmodChild(sub: Node) bool {
    const subl = sub.asList() orelse return false;
    if (subl.len == 0) return false;
    const head = subl[0].asAtom() orelse return false;
    if (std.mem.eql(u8, head, "at") or std.mem.eql(u8, head, "uuid") or std.mem.eql(u8, head, "layer")) return true;
    if (std.mem.eql(u8, head, "fp_text")) return true;
    // Drop legacy KiCad-5 arcs that carry an `(angle …)` child: that is the
    // deprecated (start=center)(end)(angle) form, and the modern board parser
    // rejects it with "Expecting 'mid'" (it requires the (start)(mid)(end)
    // three-point form). These arcs are silkscreen/fab decoration only — no
    // electrical or mechanical role — and our `.sexp` footprint model never
    // carried arcs in the first place, so dropping a legacy arc keeps the
    // embedded footprint parseable without changing the board's behaviour.
    // Modern (start)(mid)(end) arcs have no `(angle …)` child and pass through.
    if (std.mem.eql(u8, head, "fp_arc") or std.mem.eql(u8, head, "gr_arc")) {
        for (subl[1..]) |c| {
            const cl = c.asList() orelse continue;
            if (cl.len == 0) continue;
            const ch = cl[0].asAtom() orelse continue;
            if (std.mem.eql(u8, ch, "angle")) return true;
        }
    }
    return false;
}

/// Replace a footprint's library reference and pad geometry while
/// preserving every piece of user state KiCad needs to keep the part on
/// the board: `(at X Y rot)`, `(uuid …)`, `(layer …)`, `(locked …)`,
/// and any custom `(property …)` not in the standard set. The replacement
/// body comes from the swap op's `kicad_mod`, the same way the agent
/// would CreateItems a new footprint with the new geometry.
fn swapFootprint(
    arena: std.mem.Allocator,
    fp: Node,
    new_lib_id: []const u8,
    kmod_text: []const u8,
    pad_nets: ?std.json.Value,
    max_net_id: *i64,
    net_id_by_name: *std.StringHashMap(i64),
    extra_nets: *std.ArrayListUnmanaged(Node),
) WriteError!Node {
    const cl = fp.asList() orelse return fp;
    // Preserve user state from the existing footprint.
    var preserved: std.ArrayListUnmanaged(Node) = .empty;
    const preserve_keys = [_][]const u8{ "at", "uuid", "layer", "locked", "tstamp" };
    for (cl[2..]) |sub| {
        const subl = sub.asList() orelse continue;
        if (subl.len == 0) continue;
        const head = subl[0].asAtom() orelse continue;
        for (preserve_keys) |k| {
            if (std.mem.eql(u8, head, k)) {
                try preserved.append(arena, sub);
                break;
            }
        }
        // Custom properties (not Reference/Value/Footprint/Datasheet/Description/
        // canopy_uuid) also stay — they're user annotations the swap shouldn't
        // erase. Reference/Value/canopy_uuid will be reissued by follow-on
        // set_field ops if the new netlist needs them, so dropping them here
        // is fine.
        if (std.mem.eql(u8, head, FORM_PROPERTY) and subl.len >= 2) {
            const pk = subl[1].asString() orelse continue;
            if (!isStandardPropertyKey(pk)) try preserved.append(arena, sub);
        }
    }

    // Parse the new geometry from kmod_text. The .kicad_mod top-level is
    // `(footprint "name" (descr …) (tags …) (fp_*) (pad …))`; we want
    // everything inside except the (at…)/(uuid…)/(layer…) the .kicad_mod
    // doesn't carry but the board does.
    const kmod_nodes = try parser.parse(arena, kmod_text);
    if (kmod_nodes.len == 0 or !isFootprintRootForm(kmod_nodes[0])) return error.InvalidAdd;
    const kmod_children = kmod_nodes[0].asList() orelse return error.InvalidAdd;
    if (kmod_children.len < 2) return error.InvalidAdd;

    var new_fp_children: std.ArrayListUnmanaged(Node) = .empty;
    try new_fp_children.append(arena, Node.atom(Span.zero, FORM_FOOTPRINT));
    try new_fp_children.append(arena, Node.string(Span.zero, new_lib_id));
    // Preserved user state first.
    for (preserved.items) |p| try new_fp_children.append(arena, p);
    // Then the geometry from the .kicad_mod, dropping the placement/identity
    // and legacy ref/value text the board supplies separately.
    for (kmod_children[2..]) |sub| {
        if (skipKmodChild(sub)) continue;
        try new_fp_children.append(arena, sub);
    }
    var swapped = Node.list(Span.zero, try new_fp_children.toOwnedSlice(arena));
    // Apply pad_nets so the new pads point at the right nets.
    if (pad_nets) |pn| {
        if (pn == .array) {
            swapped = try applyPadNetsFromJson(arena, swapped, pn.array.items, max_net_id, net_id_by_name, extra_nets);
        }
    }
    return swapped;
}

fn applyPadNetsFromJson(
    arena: std.mem.Allocator,
    fp: Node,
    items: []const std.json.Value,
    max_net_id: *i64,
    net_id_by_name: *std.StringHashMap(i64),
    extra_nets: *std.ArrayListUnmanaged(Node),
) std.mem.Allocator.Error!Node {
    var current = fp;
    for (items) |item| {
        // The diff emits each pad-net as a 2-element array `[pin, net]`
        // (see sync.zig writePadNetsArray), so read positionally. Without
        // this, add/swap footprints landed on the board with no net
        // assignments on any pad.
        if (item != .array) continue;
        const arr = item.array.items;
        if (arr.len < 2) continue;
        const num = jsonStr(arr[0]);
        const net = jsonStr(arr[1]);
        if (num.len == 0 or net.len == 0) continue;
        const id = try resolveNetId(arena, net, max_net_id, net_id_by_name, extra_nets);
        // setPadNet now returns null on a no-change, so fall back to the
        // previous AST in that case — applyPadNetsFromJson is called from
        // swapFootprint and just walks every pad-net mapping to make
        // sure they're all set; whether a given pad needed a change or
        // not, the swap's net wiring as a whole must converge.
        if (try setPadNet(arena, current, num, id, net)) |updated| {
            current = updated;
        }
    }
    return current;
}

fn isStandardPropertyKey(k: []const u8) bool {
    return std.mem.eql(u8, k, PROP_REFERENCE) or
        std.mem.eql(u8, k, PROP_VALUE) or
        std.mem.eql(u8, k, "Footprint") or
        std.mem.eql(u8, k, "Datasheet") or
        std.mem.eql(u8, k, "Description") or
        std.mem.eql(u8, k, PROP_CANOPY_UUID);
}

/// Build a fresh `(footprint …)` node for an `add` op. Places the part
/// at the origin (user drags it into position in pcbnew), stamps in the
/// canopy_uuid + reference + value as properties, sets pad nets, and
/// embeds the geometry from the op's `kicad_mod` text.
fn buildAddFootprint(
    arena: std.mem.Allocator,
    op_obj: std.json.ObjectMap,
    max_net_id: *i64,
    net_id_by_name: *std.StringHashMap(i64),
    extra_nets: *std.ArrayListUnmanaged(Node),
) WriteError!Node {
    const lib_id = jsonStr(op_obj.get("footprint_name"));
    const kmod = jsonStr(op_obj.get("kicad_mod"));
    const ref = jsonStr(op_obj.get("ref"));
    const value = jsonStr(op_obj.get("value"));
    const canopy_uuid = jsonStr(op_obj.get("uuid"));
    const canopy_net = jsonStr(op_obj.get("canopy_net"));
    const canopy_section = jsonStr(op_obj.get("canopy_section"));
    // Staging position (board nm → mm). Absent / zero leaves the part at
    // the origin (legacy behaviour), so the user just drags it in.
    const x_mm = jsonNumNm(op_obj.get("x")) / NM_PER_MM;
    const y_mm = jsonNumNm(op_obj.get("y")) / NM_PER_MM;
    if (lib_id.len == 0 or kmod.len == 0) return error.InvalidAdd;

    const kmod_nodes = try parser.parse(arena, kmod);
    if (kmod_nodes.len == 0 or !isFootprintRootForm(kmod_nodes[0])) return error.InvalidAdd;
    const kmod_children = kmod_nodes[0].asList() orelse return error.InvalidAdd;
    if (kmod_children.len < 2) return error.InvalidAdd;

    var children: std.ArrayListUnmanaged(Node) = .empty;
    try children.append(arena, Node.atom(Span.zero, FORM_FOOTPRINT));
    try children.append(arena, Node.string(Span.zero, lib_id));
    try children.append(arena, try makeAtForm(arena, x_mm, y_mm));
    try children.append(arena, try makeLayerForm(arena, "F.Cu"));
    // KiCad expects a (uuid …) per footprint; use the canopy_uuid as the
    // KiCad-internal uuid for new adds so the next sync's reader links
    // them up via the same handle without needing a second pass.
    if (canopy_uuid.len > 0) try children.append(arena, try makeStringForm(arena, "uuid", canopy_uuid));
    if (ref.len > 0) try children.append(arena, try makeProperty(arena, PROP_REFERENCE, ref));
    if (value.len > 0) try children.append(arena, try makeProperty(arena, PROP_VALUE, value));
    if (canopy_uuid.len > 0) try children.append(arena, try makeProperty(arena, PROP_CANOPY_UUID, canopy_uuid));
    // Bake the canopy_net / canopy_section fields on the first sync (the IPC
    // path bakes these via footprint_def; the file path reads the top-level
    // op fields the server now also emits).
    if (canopy_net.len > 0) try children.append(arena, try makeProperty(arena, "canopy_net", canopy_net));
    if (canopy_section.len > 0) try children.append(arena, try makeProperty(arena, "canopy_section", canopy_section));
    // Design properties (MPN, Manufacturer, Datasheet, …) baked on the first
    // add so they don't wait for a 2nd sync. The op's "properties" array
    // already carries canonical field names + values (filtered server-side);
    // makeProperty emits them hidden (metadata, not Value). Library .sexp
    // footprints carry no (property …) forms, so there's nothing to collide with.
    if (op_obj.get("properties")) |props_val| {
        if (props_val == .array) {
            for (props_val.array.items) |pv| {
                if (pv != .object) continue;
                const pk = jsonStr(pv.object.get("key"));
                const pvv = jsonStr(pv.object.get("value"));
                if (pk.len == 0 or pvv.len == 0) continue;
                try children.append(arena, try makeProperty(arena, pk, pvv));
            }
        }
    }
    // Inline geometry from .kicad_mod, skipping the placement/identity and
    // legacy ref/value text we inject or reissue separately.
    for (kmod_children[2..]) |sub| {
        if (skipKmodChild(sub)) continue;
        try children.append(arena, sub);
    }

    var fp = Node.list(Span.zero, try children.toOwnedSlice(arena));
    if (op_obj.get("pad_nets")) |pn| {
        if (pn == .array) {
            fp = try applyPadNetsFromJson(arena, fp, pn.array.items, max_net_id, net_id_by_name, extra_nets);
        }
    }
    return fp;
}

fn makeAtForm(arena: std.mem.Allocator, x: f64, y: f64) std.mem.Allocator.Error!Node {
    var children = try arena.alloc(Node, 3);
    children[0] = Node.atom(Span.zero, "at");
    children[1] = Node.float(Span.zero, x);
    children[2] = Node.float(Span.zero, y);
    return Node.list(Span.zero, children);
}

fn makeLayerForm(arena: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!Node {
    var children = try arena.alloc(Node, 2);
    children[0] = Node.atom(Span.zero, "layer");
    children[1] = Node.string(Span.zero, name);
    return Node.list(Span.zero, children);
}

fn makeStringForm(arena: std.mem.Allocator, head: []const u8, value: []const u8) std.mem.Allocator.Error!Node {
    var children = try arena.alloc(Node, 2);
    children[0] = Node.atom(Span.zero, head);
    children[1] = Node.string(Span.zero, value);
    return Node.list(Span.zero, children);
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: kicad_pcb/writer - set_pad_net rewrites the (net …) form on the matching pad
test "applyOpsToSource set_pad_net updates only the targeted pad" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const src =
        \\(kicad_pcb
        \\  (net 0 "")
        \\  (net 1 "OLD")
        \\  (footprint "R_0402"
        \\    (uuid "fp-1")
        \\    (pad "1" smd roundrect
        \\      (at 0 0)
        \\      (net 1 "OLD"))
        \\    (pad "2" smd roundrect
        \\      (at 1 0)
        \\      (net 1 "OLD"))))
    ;
    const ops =
        \\[{"op":"set_pad_net","uuid":"fp-1","pad":"1","net":"NEW"}]
    ;
    const out = try applyOpsToSource(arena.allocator(), src, ops);
    // Pad 1 retargets to NEW. The writer emits the in-pad reference as
    // `(net "NEW")` (name only — pcbnew's canonical form for KiCad 10
    // v20260206; the integer slot is reserved for top-level declarations).
    // Because the input had top-level declarations the writer appends a
    // matching `(net 2 "NEW")` table entry after the last existing one.
    try std.testing.expect(std.mem.indexOf(u8, out, "(net 2 \"NEW\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(net \"NEW\")") != null);
    // Pad 2's `(net 1 "OLD")` reference is preserved unchanged because
    // no op targets it (the writer no longer rewrites in-element net
    // forms wholesale — an earlier pass did and silently corrupted
    // segments in real boards). The substring appears exactly twice:
    // once in the top-level declarations and once on pad 2.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "(net 1 \"OLD\")"));
}

// spec: kicad_pcb/writer - set_pad_net matches a bare-integer pad number
test "applyOpsToSource set_pad_net wires a bare-integer pad" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    // KiCad re-saves numeric pads with a bare integer and the pad is netless
    // until wired — exactly the SW1/B3U case. setPadNet must match `1` and
    // attach the net; before the padNumberText fix it skipped the pad.
    const src =
        \\(kicad_pcb
        \\  (net 0 "")
        \\  (footprint "SW_B3U"
        \\    (uuid "fp-1")
        \\    (pad 1 smd rect (at 1.7 0))))
    ;
    const ops =
        \\[{"op":"set_pad_net","uuid":"fp-1","pad":"1","net":"VDD"}]
    ;
    const out = try applyOpsToSource(arena.allocator(), src, ops);
    try std.testing.expect(std.mem.indexOf(u8, out, "(net \"VDD\")") != null);
}

// spec: kicad_pcb/writer - set_pad_net with an empty net clears the pad's (net …) form
test "applyOpsToSource set_pad_net with empty net clears the pad" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const src =
        \\(kicad_pcb
        \\  (net 0 "")
        \\  (net 1 "OLD")
        \\  (footprint "R_0402"
        \\    (uuid "fp-1")
        \\    (pad "1" smd roundrect
        \\      (at 0 0)
        \\      (net 1 "OLD"))
        \\    (pad "2" smd roundrect
        \\      (at 1 0)
        \\      (net 1 "OLD"))))
    ;
    const ops =
        \\[{"op":"set_pad_net","uuid":"fp-1","pad":"1","net":""}]
    ;
    const out = try applyOpsToSource(arena.allocator(), src, ops);
    // Pad 1's (net …) form is dropped; the reference remains only on pad 2 and
    // in the top-level declaration, so the substring count falls 3 → 2.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "(net 1 \"OLD\")"));
}

// spec: kicad_pcb/writer - remove drops the matching footprint from the output
test "applyOpsToSource remove deletes the named footprint" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const src =
        \\(kicad_pcb
        \\  (net 0 "")
        \\  (footprint "R_0402"
        \\    (uuid "fp-keep")
        \\    (property "Reference" "R1"))
        \\  (footprint "C_0402"
        \\    (uuid "fp-drop")
        \\    (property "Reference" "C1")))
    ;
    const ops =
        \\[{"op":"remove","uuid":"fp-drop"}]
    ;
    const out = try applyOpsToSource(arena.allocator(), src, ops);
    try std.testing.expect(std.mem.indexOf(u8, out, "fp-keep") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "fp-drop") == null);
}

// spec: kicad_pcb/writer - set_field upserts a property on the targeted footprint
test "applyOpsToSource set_field adds canopy_uuid when missing" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const src =
        \\(kicad_pcb
        \\  (footprint "R_0402"
        \\    (uuid "fp-1")
        \\    (property "Reference" "R1")))
    ;
    const ops =
        \\[{"op":"set_field","uuid":"fp-1","field":"canopy_uuid","value":"newcanopy"}]
    ;
    const out = try applyOpsToSource(arena.allocator(), src, ops);
    // canopy_* fields are emitted hidden so KiCad doesn't draw them on F.Fab.
    try std.testing.expect(std.mem.indexOf(u8, out, "(property \"canopy_uuid\" \"newcanopy\" (hide yes))") != null);
}

// spec: kicad_pcb/writer - hides the refdes and metadata but keeps Value visible
test "applyOpsToSource hides refdes + metadata but keeps Value visible" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    // A bare canopy_net from an older sync renders as visible text on F.Fab —
    // it must be hidden. The Reference (refdes) is hidden by default too; only
    // Value stays visible to identify the part. No ops: the normalize pass runs.
    const src =
        \\(kicad_pcb
        \\  (footprint "R_0402"
        \\    (uuid "fp-1")
        \\    (property "Reference" "R1")
        \\    (property "Value" "10k")
        \\    (property "canopy_net" "VBAT / GND")))
    ;
    var stats: ApplyStats = .{};
    const out = try applyOpsToSourceWithStats(arena.allocator(), src, "[]", &stats);
    try std.testing.expect(std.mem.indexOf(u8, out, "(property \"canopy_net\" \"VBAT / GND\" (hide yes))") != null);
    // Refdes is now hidden by default; only the value stays visible.
    try std.testing.expect(std.mem.indexOf(u8, out, "(property \"Reference\" \"R1\" (hide yes))") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(property \"Value\" \"10k\")") != null);
    try std.testing.expectEqual(@as(u32, 2), stats.fields_hidden);
    try std.testing.expectEqual(@as(u32, 0), stats.fields_shown);
}

// spec: kicad_pcb/writer - un-hides a previously hidden Reference or Value
test "applyOpsToSource un-hides a previously hidden Value" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    // A Value hidden by an earlier hide-all sync — strip the (hide yes) so the
    // cap's value (100nF) renders on the board again. Sub-forms are preserved.
    const src =
        \\(kicad_pcb
        \\  (footprint "C_0402"
        \\    (uuid "fp-1")
        \\    (property "Value" "100nF" (at 0 0 0) (layer "F.Fab") (hide yes))))
    ;
    var stats: ApplyStats = .{};
    const out = try applyOpsToSourceWithStats(arena.allocator(), src, "[]", &stats);
    try std.testing.expect(std.mem.indexOf(u8, out, "(hide yes)") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(property \"Value\" \"100nF\"") != null);
    try std.testing.expectEqual(@as(u32, 1), stats.fields_shown);
    try std.testing.expectEqual(@as(u32, 0), stats.fields_hidden);
}

// spec: kicad_pcb/writer - leaves already-correct property visibility untouched (idempotent)
test "applyOpsToSource leaves already-correct visibility untouched" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    // Reference already hidden, Value already visible, canopy_uuid already
    // hidden — all correct under the refdes-hidden policy, so the pass changes
    // nothing and the two hide forms are not doubled up.
    const src =
        \\(kicad_pcb
        \\  (footprint "R_0402"
        \\    (uuid "fp-1")
        \\    (property "Reference" "R1" (at 0 0 0) (layer "F.SilkS") (hide yes))
        \\    (property "Value" "10k")
        \\    (property "canopy_uuid" "abc" (at 0 0 0) (layer "F.Fab") (hide yes))))
    ;
    var stats: ApplyStats = .{};
    const out = try applyOpsToSourceWithStats(arena.allocator(), src, "[]", &stats);
    try std.testing.expectEqual(@as(u32, 0), stats.fields_hidden);
    try std.testing.expectEqual(@as(u32, 0), stats.fields_shown);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "(hide yes)"));
}

// spec: kicad_pcb/writer - set_locked toggles (locked yes) on the targeted footprint
test "applyOpsToSource set_locked adds the locked form" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const src =
        \\(kicad_pcb
        \\  (footprint "R_0402"
        \\    (uuid "fp-1")
        \\    (property "Reference" "R1")))
    ;
    const ops =
        \\[{"op":"set_locked","uuid":"fp-1","locked":true}]
    ;
    const out = try applyOpsToSource(arena.allocator(), src, ops);
    try std.testing.expect(std.mem.indexOf(u8, out, "(locked yes)") != null);
}

// spec: kicad_pcb/writer - add wires pad nets from the op's [pin, net] array
test "applyOpsToSource add assigns pad nets to the new footprint" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const src =
        \\(kicad_pcb
        \\  (footprint "R_0402"
        \\    (uuid "fp-1")
        \\    (property "Reference" "R1")))
    ;
    // pad_nets is an array of [pin, net] pairs — the shape sync.zig's
    // writePadNetsArray emits. The kicad_mod carries two unwired pads.
    const ops =
        \\[{"op":"add","uuid":"new-uuid","ref":"C9","value":"100nF",
        \\  "footprint_name":"C_0402",
        \\  "kicad_mod":"(footprint \"C_0402\" (pad \"1\" smd roundrect (at 0 0)) (pad \"2\" smd roundrect (at 1 0)))",
        \\  "pad_nets":[["1","VBAT"],["2","GND"]]}]
    ;
    const out = try applyOpsToSource(arena.allocator(), src, ops);
    // Both pads must reference their nets (name-only, pcbnew v20260206 form).
    try std.testing.expect(std.mem.indexOf(u8, out, "(net \"VBAT\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(net \"GND\")") != null);
}

// spec: kicad_pcb/writer - add drops legacy (angle …) arcs the modern board parser rejects
test "applyOpsToSource add drops legacy angle-form arcs but keeps modern mid-form arcs" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const src =
        \\(kicad_pcb
        \\  (footprint "R_0402"
        \\    (uuid "fp-1")
        \\    (property "Reference" "R1")))
    ;
    // The kmod carries one legacy (start)(end)(angle) arc — what an imported
    // KiCad-5 lib/sources/*.kicad_mod yields, and what makes pcbnew bail with
    // "Expecting 'mid'" — alongside a modern (start)(mid)(end) arc that must
    // survive untouched.
    const ops =
        \\[{"op":"add","uuid":"sw1","ref":"SW1","value":"B3U","footprint_name":"F",
        \\  "kicad_mod":"(footprint \"F\" (fp_arc (start 0 0) (end 1 0) (angle 90)) (fp_arc (start 1 0) (mid 1 1) (end 0 1)) (pad \"1\" smd (at 0 0)))",
        \\  "pad_nets":[["1","BOOT0"]]}]
    ;
    const out = try applyOpsToSource(arena.allocator(), src, ops);
    // Legacy angle-form arc dropped; modern mid-form arc preserved.
    try std.testing.expect(std.mem.indexOf(u8, out, "(angle") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(mid 1 1)") != null);
    // The real pad still lands with its net so the part stays wired.
    try std.testing.expect(std.mem.indexOf(u8, out, "(net \"BOOT0\")") != null);
}

// spec: kicad_pcb/writer - swap_footprint accepts a legacy (module …) kmod
test "applyOpsToSource swap_footprint accepts legacy module-format kmod" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const src =
        \\(kicad_pcb
        \\  (footprint "OLD_FP"
        \\    (uuid "fp-1")
        \\    (at 10 20 90)
        \\    (property "Reference" "U1")
        \\    (pad "1" smd circle (at 0 0) (net "VCC"))))
    ;
    // kmod in legacy KiCad-5 (module …) format (what an imported
    // lib/sources/*.kicad_mod yields) with fp_text reference/value the
    // writer must drop. Before the fix the writer rejected the (module …)
    // root with a writer error.
    const ops =
        \\[{"op":"swap_footprint","uuid":"fp-1","new_footprint_name":"NEW_FP",
        \\  "kicad_mod":"(module \"NEW_FP\" (fp_text reference IC**) (fp_text value V) (pad A1 smd circle (at 0 0) (size 0.2 0.2)))",
        \\  "pad_nets":[["A1","VCC"]]}]
    ;
    const out = try applyOpsToSource(arena.allocator(), src, ops);
    // New geometry embedded, legacy ref/value text dropped, placement kept.
    try std.testing.expect(std.mem.indexOf(u8, out, "(pad A1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(at 10 20 90)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "fp_text") == null);
    // The net must land ON the bare-named pad — not merely appear somewhere
    // in the file. setPadNet has to match the unquoted `A1` atom, otherwise
    // BGA/WCSP footprints swap in with every pad unconnected.
    const pad_idx = std.mem.indexOf(u8, out, "(pad A1").?;
    try std.testing.expect(std.mem.indexOf(u8, out[pad_idx..], "(net \"VCC\")") != null);
}

// spec: kicad_pcb/writer - preserves pcbnew-style boards: in-element net forms
// stay name-only, no top-level declarations invented, header stays first.
test "applyOpsToSource preserves pcbnew v20260206 format (no header corruption)" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    // Mirrors what KiCad 10 v20260206 writes: header first, no top-level
    // (net N "name") table, in-pad / in-segment references use name only.
    // An earlier writer ran a "canonicalisation" pass that rewrote these
    // to (net N "name") and inserted invented declarations before (version
    // …) — pcbnew then refused to parse the file ("Expecting ')'" at the
    // first segment's net reference). This test pins the fixed behaviour.
    const src =
        \\(kicad_pcb
        \\  (version 20260206)
        \\  (generator "pcbnew")
        \\  (footprint "R_0402"
        \\    (uuid "fp-1")
        \\    (property "Reference" "R1")
        \\    (pad "1" smd roundrect
        \\      (at 0 0)
        \\      (net "VBAT")))
        \\  (segment
        \\    (start 1 1)
        \\    (end 2 2)
        \\    (width 0.127)
        \\    (layer "F.Cu")
        \\    (net "VBAT")))
    ;
    const ops =
        \\[{"op":"set_field","uuid":"fp-1","field":"value","value":"10k"}]
    ;
    const out = try applyOpsToSource(arena.allocator(), src, ops);

    // The header must remain the second top-level form (right after the
    // `(kicad_pcb` head atom). An earlier bug inserted invented net
    // declarations between the head and (version …), breaking parses.
    // Pin the order: every `(net …)` in the output must come after
    // (version …). With name-only refs that's two name-only forms (one
    // pad, one segment) and zero top-level declarations — but the
    // assertion below works regardless of how many declarations
    // appear, so adding a future declaration-emitting path won't break it.
    const ver_idx = std.mem.indexOf(u8, out, "(version 20260206)") orelse return error.TestExpectedNotNull;
    const first_net_idx = std.mem.indexOf(u8, out, "(net ") orelse return error.TestExpectedNotNull;
    try std.testing.expect(first_net_idx > ver_idx);

    // In-element references must keep the name-only form (no numeric id
    // slot smuggled in by the canonicalisation pass).
    try std.testing.expect(std.mem.count(u8, out, "(net \"VBAT\")") == 2);
    try std.testing.expect(std.mem.indexOf(u8, out, "(net 0 \"VBAT\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(net 1 \"VBAT\")") == null);
}

// spec: kicad_pcb/writer - add places the new footprint at the op's staging (x, y) and bakes canopy_net / canopy_section properties
test "applyOpsToSource add places at staging position and bakes canopy fields" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const src =
        \\(kicad_pcb
        \\  (footprint "R_0402" (uuid "fp-1") (property "Reference" "R1")))
    ;
    const ops =
        \\[{"op":"add","uuid":"new-uuid","ref":"C84","value":"1uF",
        \\  "footprint_name":"C_0402",
        \\  "kicad_mod":"(footprint \"C_0402\" (pad \"1\" smd roundrect (at 0 0)))",
        \\  "canopy_net":"U8.C3.VDD33USB","canopy_section":"USB Core",
        \\  "x":305500000,"y":35500000,"pad_nets":[["1","VDD"]]}]
    ;
    const out = try applyOpsToSource(arena.allocator(), src, ops);
    // Footprint placed at the staging position (nm → mm), not the origin.
    try std.testing.expect(std.mem.indexOf(u8, out, "(at 305.5 35.5)") != null);
    // canopy_net / canopy_section baked as properties on the first sync,
    // hidden so they don't render as text on the fab layer.
    try std.testing.expect(std.mem.indexOf(u8, out, "(property \"canopy_net\" \"U8.C3.VDD33USB\" (hide yes))") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(property \"canopy_section\" \"USB Core\" (hide yes))") != null);
}

// spec: kicad_pcb/writer - add bakes design properties (MPN, Manufacturer, …) on the first sync
test "applyOpsToSource add bakes design properties from the op's properties array" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const src =
        \\(kicad_pcb
        \\  (footprint "R_0402" (uuid "fp-1") (property "Reference" "R1")))
    ;
    // Without baking these into the add, the MPN/Manufacturer fields wouldn't
    // appear until a 2nd sync emitted set_field ops on the now-existing part.
    const ops =
        \\[{"op":"add","uuid":"new-uuid","ref":"C84","value":"1uF",
        \\  "footprint_name":"C_0402",
        \\  "kicad_mod":"(footprint \"C_0402\" (pad \"1\" smd roundrect (at 0 0)))",
        \\  "properties":[{"key":"MPN","value":"GRM155R71C104"},{"key":"Manufacturer","value":"Murata"}],
        \\  "x":0,"y":0,"pad_nets":[]}]
    ;
    const out = try applyOpsToSource(arena.allocator(), src, ops);
    // Baked on the first sync, hidden so they don't render as fab/silk text.
    try std.testing.expect(std.mem.indexOf(u8, out, "(property \"MPN\" \"GRM155R71C104\" (hide yes))") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(property \"Manufacturer\" \"Murata\" (hide yes))") != null);
}

// spec: kicad_pcb/writer - create_board_item writes a section staging box as a (gr_rect …) on Dwgs.User
test "applyOpsToSource create_board_item draws a section box rectangle" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const src =
        \\(kicad_pcb
        \\  (footprint "R_0402" (uuid "fp-1") (property "Reference" "R1")))
    ;
    // JSON wrapped across lines (Zig joins with \n; JSON ignores whitespace).
    const ops =
        \\[{"op":"create_board_item","item":{
        \\"@type":"type.googleapis.com/kiapi.board.types.BoardGraphicShape",
        \\"layer":"BL_Dwgs_User",
        \\"shape":{"attributes":
        \\{"stroke":{"width":{"valueNm":150000},"style":"SLS_DEFAULT"},
        \\"fill":{"fillType":"GFT_UNFILLED"}},
        \\"rectangle":{"topLeft":{"xNm":300000000,"yNm":25000000},
        \\"bottomRight":{"xNm":321000000,"yNm":46000000}}}}}]
    ;
    const out = try applyOpsToSource(arena.allocator(), src, ops);
    try std.testing.expect(std.mem.indexOf(u8, out, "(gr_rect") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(start 300 25)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(end 321 46)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(layer \"Dwgs.User\")") != null);
}

// spec: kicad_pcb/writer - create_board_item writes a section label as a (gr_text …) on Dwgs.User
test "applyOpsToSource create_board_item draws a section label" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const src =
        \\(kicad_pcb
        \\  (footprint "R_0402" (uuid "fp-1") (property "Reference" "R1")))
    ;
    const ops =
        \\[{"op":"create_board_item","item":{
        \\"@type":"type.googleapis.com/kiapi.board.types.BoardText",
        \\"layer":"BL_Dwgs_User",
        \\"text":{"position":{"xNm":310500000,"yNm":27500000},
        \\"attributes":{"size":{"xNm":2000000,"yNm":2000000}},
        \\"text":"USB"}}}]
    ;
    const out = try applyOpsToSource(arena.allocator(), src, ops);
    // The printer breaks list children onto their own lines (matching KiCad's
    // own gr_text style), so check the tokens, not a single-line shape.
    try std.testing.expect(std.mem.indexOf(u8, out, "gr_text") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"USB\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(at 310.5 27.5 0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(layer \"Dwgs.User\")") != null);
}
