//! Server-side diff endpoint for the local Go IPC sync agent.
//!
//!   POST /api/sync-plan/:name — client posts the current state of
//!   footprints on the open KiCad PCB; server compares against the
//!   design's flattened netlist and returns ops to apply (set_field /
//!   set_pad_net / add / swap_footprint / remove / flag_stale).
//!   `add` / `swap_footprint` carry their `.kicad_mod` text inline.
//!
//! Companion to `tools/kicad-sync-go/`.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const log = @import("../infra/log.zig");
const paths = @import("../paths.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const export_kicad = @import("../export_kicad.zig");
const netlist_mod = @import("../export_kicad_netlist.zig");
const fp_mod = @import("../export_kicad_footprint.zig");
const model_mod = @import("../export_kicad_model.zig");
const bom = @import("../bom.zig");
const parser_mod = @import("../sexpr/parser.zig");
const env_mod_node = @import("../sexpr/ast.zig");
const env_mod = @import("../eval/env.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

// ── Constants ─────────────────────────────────────────────────────
const HTTP_NOT_FOUND: u16 = 404;
const HTTP_BAD_REQUEST: u16 = 400;
const HTTP_INTERNAL_ERROR: u16 = 500;
const MAX_FOOTPRINT_BYTES: usize = 1024 * 1024;
const HEADER_CORS_ALLOW_ORIGIN = "access-control-allow-origin";
const ERR_BUILD_ERROR = "Build error";
const ERR_NOT_A_DESIGN = "Not a design";
const PATH_FMT_FP_SEXP = "{s}/lib/footprints/{s}.sexp";
const OP_SET_FIELD = "set_field";
const FIELD_CANOPY_UUID = "canopy_uuid";

/// Error set for HTTP handlers in this module.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    std.fs.File.WriteError || std.fs.File.OpenError || std.fs.File.ReadError ||
    std.fs.Dir.MakeError || std.fs.Dir.StatFileError ||
    error{ FileTooBig, StreamTooLong, EndOfStream, InvalidEscapeSequence, NotOpenForReading, ReadOnlyFileSystem, LinkQuotaExceeded };

fn warnResolveIdentities(name: []const u8, err: anyerror) void {
    log.warn("resolveIdentities {s} failed: {s}", .{ name, @errorName(err) });
}

// ── /api/sync-plan ──────────────────────────────────────────────────────

const PadAssign = struct { number: []const u8, net: []const u8 };

const BoardFp = struct {
    /// Project-stable canopy_uuid custom field. Empty when the footprint
    /// has never been synced (or was placed manually in KiCad).
    uuid: []const u8,
    /// KiCad-internal handle. Always populated. Echoed back in emitted ops
    /// so the agent's apply path can target the right footprint regardless
    /// of whether canopy_uuid is set yet.
    kicad_uuid: []const u8,
    ref: []const u8,
    value: []const u8,
    footprint_name: []const u8,
    /// Every custom Field on the KiCad footprint, keyed by name. The agent
    /// posts the full map per sync so the server can diff arbitrary design
    /// properties (mpn, manufacturer, datasheet, …) without the client
    /// knowing which fields exist — adding a new BOM column is a pure
    /// server-side change.
    fields: std.StringHashMapUnmanaged([]const u8),
    pads: []const PadAssign,
};

/// Pick the UUID the agent should use to find this footprint in its cache.
/// Prefer kicad_uuid when present (always wired by the modern agent); fall
/// back to canopy uuid for older agents that don't ship it yet.
fn opTargetUuid(m: BoardFp) []const u8 {
    if (m.kicad_uuid.len > 0) return m.kicad_uuid;
    return m.uuid;
}

const ParsedSyncPlan = struct {
    board: []const BoardFp,
    prune_stale: bool,
    /// When true, after canopy_uuid + ref_des matching, try a third tier
    /// keyed on (parent_path, footprint_name, value). Used by the agent's
    /// `--migrate` mode to recover board footprints whose ref_des drifted
    /// from the design's auto-numbering. Only applied when the (key, side)
    /// pair is unique on BOTH the design and the board so we never silently
    /// remap the wrong footprint.
    migrate_heuristic: bool,
};

fn parsePadList(arena: std.mem.Allocator, pv: std.json.Value) std.mem.Allocator.Error![]const PadAssign {
    var pads_list: std.ArrayListUnmanaged(PadAssign) = .empty;
    if (pv != .array) return pads_list.items;
    for (pv.array.items) |p| {
        if (p != .object) continue;
        const num = jsonStr(p.object.get("number"));
        if (num.len == 0) continue;
        try pads_list.append(arena, .{ .number = num, .net = jsonStr(p.object.get("net")) });
    }
    return pads_list.items;
}

fn parseFieldsMap(arena: std.mem.Allocator, fv: std.json.Value) std.mem.Allocator.Error!std.StringHashMapUnmanaged([]const u8) {
    var fields: std.StringHashMapUnmanaged([]const u8) = .empty;
    if (fv != .object) return fields;
    var it = fv.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = jsonStr(entry.value_ptr.*);
        try fields.put(arena, key, val);
    }
    return fields;
}

fn parseBoardEntry(arena: std.mem.Allocator, entry: std.json.Value) std.mem.Allocator.Error!?BoardFp {
    if (entry != .object) return null;
    const o = entry.object;
    const pads = if (o.get("pads")) |pv| try parsePadList(arena, pv) else &[_]PadAssign{};
    const fields = if (o.get("fields")) |fv| try parseFieldsMap(arena, fv) else std.StringHashMapUnmanaged([]const u8){};
    return BoardFp{
        .uuid = jsonStr(o.get("uuid")),
        .kicad_uuid = jsonStr(o.get("kicad_uuid")),
        .ref = jsonStr(o.get("ref")),
        .value = jsonStr(o.get("value")),
        .footprint_name = jsonStr(o.get("footprint_name")),
        .fields = fields,
        .pads = pads,
    };
}

fn parseSyncPlanBody(arena: std.mem.Allocator, body: []const u8) !ParsedSyncPlan {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
    if (parsed.value != .object) return error.NotObject;

    const prune_stale = jsonBool(parsed.value.object.get("prune_stale"));
    const migrate_heuristic = jsonBool(parsed.value.object.get("migrate_heuristic"));

    var board_list: std.ArrayListUnmanaged(BoardFp) = .empty;
    const bv = parsed.value.object.get("board") orelse {
        return .{ .board = board_list.items, .prune_stale = prune_stale, .migrate_heuristic = migrate_heuristic };
    };
    if (bv != .array) return .{ .board = board_list.items, .prune_stale = prune_stale, .migrate_heuristic = migrate_heuristic };

    for (bv.array.items) |entry| {
        const fp = (try parseBoardEntry(arena, entry)) orelse continue;
        try board_list.append(arena, fp);
    }
    return .{ .board = board_list.items, .prune_stale = prune_stale, .migrate_heuristic = migrate_heuristic };
}

fn jsonBool(v: ?std.json.Value) bool {
    const val = v orelse return false;
    return val == .bool and val.bool;
}

fn jsonStr(v: ?std.json.Value) []const u8 {
    const val = v orelse return "";
    return if (val == .string) val.string else "";
}

/// Strip the `lib:` prefix that netlist footprint specs carry (`"lib:R_0402"`
/// → `"R_0402"`). Inputs without a prefix pass through unchanged.
fn stripLibPrefix(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, ':')) |idx| return s[idx + 1 ..];
    return s;
}

/// Return the last `/`-delimited segment of a net name. Used to ask
/// "what would this net be called if I dropped the sub-block prefix?"
/// before deciding whether the bare form is safe to use.
fn bareNetName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| return name[i + 1 ..];
    return name;
}

/// Collapse a `(decouple …)`-generated per-pin sub-net (`VDD.U18.IN`) to
/// its rail (`VDD`). Sub-nets are an EDA routing-organisation aid and the
/// design author's intent is that they share the rail's electrical net.
/// Names without a `.` pass through unchanged.
fn collapseDotSubNet(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, '.')) |i| return name[0..i];
    return name;
}

const SyncPlanContext = struct {
    arena: std.mem.Allocator,
    project_dir: []const u8,
    model_cfg: *export_kicad.ModelConfigMap,
};

/// Build the `.kicad_mod` text the client needs to instantiate `fp_name`.
/// Returned slice is owned by `arena`; caller does not free explicitly.
fn loadKicadMod(
    spc: *SyncPlanContext,
    fp_name: []const u8,
    component: []const u8,
) ?[]const u8 {
    const fp_path = std.fmt.allocPrint(spc.arena, PATH_FMT_FP_SEXP, .{ spc.project_dir, fp_name }) catch return null;
    const fp_source = infra_fs.cwd().readFileAlloc(spc.arena, fp_path, MAX_FOOTPRINT_BYTES) catch return null;
    const mcfg = spc.model_cfg.get(fp_name);
    const model_name = if (mcfg) |c|
        (c.model orelse fp_mod.findModelFile(spc.arena, spc.project_dir, fp_name, component))
    else
        fp_mod.findModelFile(spc.arena, spc.project_dir, fp_name, component);
    return model_mod.buildKicadMod(
        spc.arena,
        spc.project_dir,
        fp_name,
        fp_source,
        model_name,
        if (mcfg) |c| c.offset else null,
        if (mcfg) |c| c.rotation else null,
    ) catch null;
}

/// Build a proto-canonical JSON description of `fp_name` matching the
/// shape that Go's protojson.Unmarshal expects for a
/// `kiapi.board.types.Footprint` message. The agent feeds this directly
/// into `*board_types.Footprint` without any geometry-aware code on its
/// side — adding a new pad shape, type, or layer is a server-only
/// change.
///
/// Returns the JSON text or null when no `.sexp` source exists. Pad nets
/// are NOT baked in here; the surrounding op carries `pad_nets` so the
/// per-instance assignment travels separately from the (shared) geometry.
fn loadFootprintDef(
    spc: *SyncPlanContext,
    fp_name: []const u8,
) ?[]const u8 {
    return loadFootprintDefImpl(spc, fp_name, null) catch null;
}

/// Like loadFootprintDef but also bakes per-instance Field items
/// (canopy_uuid + design properties like MPN / Manufacturer) into the
/// proto-canonical JSON. Used by `add` ops so KiCad records the custom
/// fields on the first CreateItems — without this the agent would
/// need a follow-up sync to land set_field ops on every freshly-added
/// fp, and the user sees the "press sync twice" bug.
fn loadFootprintDefForInstance(
    spc: *SyncPlanContext,
    fp_name: []const u8,
    inst: export_kicad.FlatInstance,
) ?[]const u8 {
    return loadFootprintDefImpl(spc, fp_name, inst) catch null;
}

fn loadFootprintDefImpl(
    spc: *SyncPlanContext,
    fp_name: []const u8,
    inst_opt: ?export_kicad.FlatInstance,
) !?[]const u8 {
    const fp_path = try std.fmt.allocPrint(spc.arena, PATH_FMT_FP_SEXP, .{ spc.project_dir, fp_name });
    const fp_source = infra_fs.cwd().readFileAlloc(spc.arena, fp_path, MAX_FOOTPRINT_BYTES) catch return null;

    const nodes = parser_mod.parse(spc.arena, fp_source) catch return null;
    if (nodes.len == 0 or !nodes[0].isForm("footprint")) return null;
    const children = nodes[0].asList() orelse return null;
    if (children.len < 2) return null;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(spc.arena);
    try w.writeAll("{\"id\":{\"libraryNickname\":\"eda-sync\",\"entryName\":");
    try writeJsonString(w, fp_name);
    try w.writeAll("},\"items\":[");
    var first_item = true;
    for (children[2..]) |child| {
        if (!child.isForm("pad")) continue;
        try writePadProtoJson(spc.arena, w, child, &first_item);
    }
    // Courtyard / silkscreen graphics ship inline alongside Pads. Without
    // these the wurth WA-SMSI mounting spacer renders without its F.CrtYd
    // boundary because KiCad treats our partial Definition.Items as
    // authoritative and never reads the staged library. RunAction "Update
    // Footprint From Library" was the intended escape hatch but every
    // candidate name returned RAS_INVALID, so we ship the geometry directly.
    for (children[2..]) |child| {
        if (child.isForm("courtyard")) {
            try writeCourtyardProtoJson(w, child, &first_item);
        } else if (child.isForm("silkscreen")) {
            try writeSilkscreenProtoJson(w, child, &first_item);
        }
    }
    if (inst_opt) |inst| {
        try writeFieldProtoJson(w, FIELD_CANOPY_UUID, inst.uuid, &first_item);
        for (inst.properties) |p| {
            if (skipDesignProperty(p.key)) continue;
            if (p.value.len == 0) continue;
            try writeFieldProtoJson(w, canonicalFieldName(p.key), p.value, &first_item);
        }
    }
    try w.writeAll("]}");
    return buf.items;
}

/// Emit one custom Field as an Any-wrapped proto-canonical JSON object.
/// Used to bake canopy_uuid + design properties (MPN / Manufacturer / …)
/// into the FootprintInstance.Definition.Items list on `add` ops, so the
/// agent's first CreateItems already carries them and we don't need a
/// second sync round trip to land set_field ops.
fn writeFieldProtoJson(w: anytype, name: []const u8, value: []const u8, first: *bool) !void {
    if (!first.*) try w.writeAll(",");
    first.* = false;
    try w.writeAll("{\"@type\":\"type.googleapis.com/kiapi.board.types.Field\",\"name\":");
    try writeJsonString(w, name);
    try w.writeAll(",\"text\":{\"text\":{\"text\":");
    try writeJsonString(w, value);
    try w.writeAll("}}}");
}

// Proto enum string names — these must match the `protobuf:"...,enum=..."`
// values the generated Go .pb.go expects for protojson decoding. Adding a
// new shape/type/layer is one line here on the server, with NO agent change.
const PROTO_TYPE_URL_PAD = "type.googleapis.com/kiapi.board.types.Pad";
const PROTO_TYPE_URL_BOARDSHAPE = "type.googleapis.com/kiapi.board.types.BoardGraphicShape";
const PROTO_PADTYPE_SMD = "PT_SMD";
const PROTO_PADTYPE_PTH = "PT_PTH";
const PROTO_PADTYPE_NPTH = "PT_NPTH";
const PROTO_PADSTACK_NORMAL = "PST_NORMAL";
const PROTO_LAYER_F_CRTYD = "BL_F_CrtYd";
const PROTO_LAYER_F_SILK = "BL_F_SilkS";
const COURTYARD_STROKE_MM: f64 = 0.05;
const SILK_STROKE_MM: f64 = 0.12;
const RECT_NODE_MIN_CHILDREN: usize = 5;
const DEFAULT_ROUNDRECT_RRATIO: f64 = 0.25;

fn protoPadType(short: []const u8) []const u8 {
    if (std.mem.eql(u8, short, "smd")) return PROTO_PADTYPE_SMD;
    if (std.mem.eql(u8, short, "thru_hole") or std.mem.eql(u8, short, "thru")) return PROTO_PADTYPE_PTH;
    if (std.mem.eql(u8, short, "np_thru_hole") or std.mem.eql(u8, short, "np_thru") or std.mem.eql(u8, short, "npth")) return PROTO_PADTYPE_NPTH;
    return PROTO_PADTYPE_SMD;
}

/// True when `s` is an EDA pad-type keyword. Used to distinguish the two
/// `(pad …)` syntactic forms: numbered pads start `(pad "1" smd …)` while
/// unnumbered NPTH mounting holes are `(pad npth circle …)` — the parser
/// has to decide whether nodes[1] is a number or the type.
fn isPadTypeKeyword(s: []const u8) bool {
    return std.mem.eql(u8, s, "smd") or
        std.mem.eql(u8, s, "thru") or
        std.mem.eql(u8, s, "thru_hole") or
        std.mem.eql(u8, s, "np_thru") or
        std.mem.eql(u8, s, "np_thru_hole") or
        std.mem.eql(u8, s, "npth");
}

fn protoPadShape(short: []const u8) []const u8 {
    if (std.mem.eql(u8, short, "rect")) return "PSS_RECTANGLE";
    if (std.mem.eql(u8, short, "circle")) return "PSS_CIRCLE";
    if (std.mem.eql(u8, short, "oval")) return "PSS_OVAL";
    if (std.mem.eql(u8, short, "roundrect")) return "PSS_ROUNDRECT";
    return "PSS_RECTANGLE";
}

fn protoBoardLayer(short: []const u8) []const u8 {
    if (std.mem.eql(u8, short, "F.Cu")) return "BL_F_Cu";
    if (std.mem.eql(u8, short, "B.Cu")) return "BL_B_Cu";
    if (std.mem.eql(u8, short, "F.Paste")) return "BL_F_Paste";
    if (std.mem.eql(u8, short, "F.Mask")) return "BL_F_Mask";
    if (std.mem.eql(u8, short, "B.Mask")) return "BL_B_Mask";
    if (std.mem.eql(u8, short, "F.SilkS")) return "BL_F_SilkS";
    if (std.mem.eql(u8, short, "B.SilkS")) return "BL_B_SilkS";
    if (std.mem.eql(u8, short, "F.CrtYd")) return "BL_F_CrtYd";
    if (std.mem.eql(u8, short, "B.CrtYd")) return "BL_B_CrtYd";
    return "BL_F_Cu";
}

/// Emit a `{xNm, yNm}` Vector2 in proto-canonical JSON form.
fn writeProtoVec2(w: anytype, x_mm: f64, y_mm: f64) !void {
    try w.print("{{\"xNm\":{d},\"yNm\":{d}}}", .{ mmToNm(x_mm), mmToNm(y_mm) });
}

/// Write the BoardGraphicShape header (Any tag, GraphicAttributes, layer)
/// up to the geometry oneof. Caller writes the geometry field
/// (`segment` / `circle` / `rectangle`) and closes the outer JSON object.
fn writeBoardShapeOpen(w: anytype, layer: []const u8, stroke_mm: f64, first: *bool) !void {
    if (!first.*) try w.writeAll(",");
    first.* = false;
    const stroke_nm = mmToNm(stroke_mm);
    try w.writeAll("{\"@type\":\"" ++ PROTO_TYPE_URL_BOARDSHAPE ++ "\",");
    try w.print("\"layer\":\"{s}\",", .{layer});
    try w.writeAll("\"shape\":{\"attributes\":{\"stroke\":{\"width\":");
    try w.print("{{\"valueNm\":{d}}},\"style\":\"SLS_DEFAULT\"}},", .{stroke_nm});
    try w.writeAll("\"fill\":{\"fillType\":\"GFT_UNFILLED\"}},");
}

fn writeCircleGeom(w: anytype, cx: f64, cy: f64, r: f64) !void {
    try w.writeAll("\"circle\":{\"center\":");
    try writeProtoVec2(w, cx, cy);
    try w.writeAll(",\"radiusPoint\":");
    try writeProtoVec2(w, cx + r, cy);
    try w.writeAll("}");
}

fn writeRectGeom(w: anytype, x1: f64, y1: f64, x2: f64, y2: f64) !void {
    try w.writeAll("\"rectangle\":{\"topLeft\":");
    try writeProtoVec2(w, x1, y1);
    try w.writeAll(",\"bottomRight\":");
    try writeProtoVec2(w, x2, y2);
    try w.writeAll("}");
}

fn writeSegmentGeom(w: anytype, sx: f64, sy: f64, ex: f64, ey: f64) !void {
    try w.writeAll("\"segment\":{\"start\":");
    try writeProtoVec2(w, sx, sy);
    try w.writeAll(",\"end\":");
    try writeProtoVec2(w, ex, ey);
    try w.writeAll("}");
}

fn parseCirclePoints(node: env_mod_node.Node) ?struct { cx: f64, cy: f64, r: f64 } {
    const cl = node.asList() orelse return null;
    if (cl.len < 3) return null;
    const center = cl[1].asList() orelse return null;
    if (center.len < 2) return null;
    const cx = center[0].asNumber() orelse return null;
    const cy = center[1].asNumber() orelse return null;
    const r = cl[2].asNumber() orelse return null;
    return .{ .cx = cx, .cy = cy, .r = r };
}

fn parseSegmentPoints(node: env_mod_node.Node) ?struct { sx: f64, sy: f64, ex: f64, ey: f64 } {
    const cl = node.asList() orelse return null;
    if (cl.len < 3) return null;
    const start = cl[1].asList() orelse return null;
    const end = cl[2].asList() orelse return null;
    if (start.len < 2 or end.len < 2) return null;
    return .{
        .sx = start[0].asNumber() orelse return null,
        .sy = start[1].asNumber() orelse return null,
        .ex = end[0].asNumber() orelse return null,
        .ey = end[1].asNumber() orelse return null,
    };
}

/// Emit a `(courtyard …)` form as one or more BoardGraphicShape Any-wrapped
/// items on F.CrtYd. Supports `(rect X1 Y1 X2 Y2)` and
/// `(circle (CX CY) R)` — the latter is what mounting-spacer footprints use.
fn writeCourtyardProtoJson(w: anytype, node: env_mod_node.Node, first: *bool) !void {
    const children = node.asList() orelse return;
    for (children[1..]) |child| {
        if (child.isForm("rect")) {
            const cl = child.asList() orelse continue;
            if (cl.len < RECT_NODE_MIN_CHILDREN) continue;
            const x1 = cl[1].asNumber() orelse continue;
            const y1 = cl[2].asNumber() orelse continue;
            const x2 = cl[3].asNumber() orelse continue;
            const y2 = cl[4].asNumber() orelse continue;
            try writeBoardShapeOpen(w, PROTO_LAYER_F_CRTYD, COURTYARD_STROKE_MM, first);
            try writeRectGeom(w, x1, y1, x2, y2);
            try w.writeAll("}}");
        } else if (child.isForm("circle")) {
            const c = parseCirclePoints(child) orelse continue;
            try writeBoardShapeOpen(w, PROTO_LAYER_F_CRTYD, COURTYARD_STROKE_MM, first);
            try writeCircleGeom(w, c.cx, c.cy, c.r);
            try w.writeAll("}}");
        }
    }
}

/// Emit a `(silkscreen …)` form as BoardGraphicShape items on F.SilkS.
fn writeSilkscreenProtoJson(w: anytype, node: env_mod_node.Node, first: *bool) !void {
    const children = node.asList() orelse return;
    for (children[1..]) |child| {
        if (child.isForm("line")) {
            const seg = parseSegmentPoints(child) orelse continue;
            try writeBoardShapeOpen(w, PROTO_LAYER_F_SILK, SILK_STROKE_MM, first);
            try writeSegmentGeom(w, seg.sx, seg.sy, seg.ex, seg.ey);
            try w.writeAll("}}");
        } else if (child.isForm("circle")) {
            const c = parseCirclePoints(child) orelse continue;
            try writeBoardShapeOpen(w, PROTO_LAYER_F_SILK, SILK_STROKE_MM, first);
            try writeCircleGeom(w, c.cx, c.cy, c.r);
            try w.writeAll("}}");
        }
    }
}

/// Emit one pad as a proto-canonical Any-wrapped Pad message. The shape is
/// what `protojson.Unmarshal` expects for `kiapi.board.types.Pad`:
/// camelCase field names, string enum values, and a `@type` field that
/// makes the decode resolve into `*board_types.Pad` on the agent side.
///
/// Two `(pad …)` forms in the EDA DSL:
///   (pad "1" smd roundrect (pos …) (size …))   — numbered electrical pad
///   (pad npth circle (pos …) (size …) (drill …))   — unnumbered NPTH mounting hole
/// We detect the second form by checking whether nodes[1] is a known
/// pad-type keyword; otherwise nodes[1] is the pad number string.
fn writePadProtoJson(arena: std.mem.Allocator, w: anytype, pad: env_mod_node.Node, first: *bool) !void {
    const nodes = pad.asList() orelse return;
    if (nodes.len < 3) return;
    const unnumbered = if (nodes[1].asAtom()) |a| isPadTypeKeyword(a) else false;
    const type_idx: usize = if (unnumbered) 1 else 2;
    const shape_idx: usize = if (unnumbered) 2 else 3;
    if (nodes.len <= shape_idx) return;

    const num: []const u8 = if (unnumbered) "" else (padNumberText(arena, nodes[1]) orelse return);
    const ptype = nodes[type_idx].asAtom() orelse return;
    const shape = nodes[shape_idx].asAtom() orelse return;

    var pos_x: f64 = 0;
    var pos_y: f64 = 0;
    var pos_rot: f64 = 0;
    var size_w: f64 = 0;
    var size_h: f64 = 0;
    var drill_d: f64 = 0;
    // Default rratio matches KiCad's library default. Override via
    // `(roundrect_rratio R)` — 0.5 turns a square pad into a circle, used
    // by mounting-spacer footprints (e.g. wurth WA-SMSI).
    var rratio: f64 = DEFAULT_ROUNDRECT_RRATIO;

    for (nodes[shape_idx + 1 ..]) |n| {
        if (n.isForm("pos")) {
            const pl = n.asList().?;
            if (pl.len >= 3) {
                pos_x = pl[1].asNumber() orelse 0;
                pos_y = pl[2].asNumber() orelse 0;
            }
            if (pl.len >= 4) pos_rot = pl[3].asNumber() orelse 0;
        } else if (n.isForm("size")) {
            const sl = n.asList().?;
            if (sl.len >= 3) {
                size_w = sl[1].asNumber() orelse 0;
                size_h = sl[2].asNumber() orelse 0;
            }
        } else if (n.isForm("drill")) {
            const dl = n.asList().?;
            if (dl.len >= 2) drill_d = dl[1].asNumber() orelse 0;
        } else if (n.isForm("roundrect_rratio")) {
            const rl = n.asList().?;
            if (rl.len >= 2) rratio = rl[1].asNumber() orelse DEFAULT_ROUNDRECT_RRATIO;
        }
    }

    if (!first.*) try w.writeAll(",");
    first.* = false;
    const proto_type = protoPadType(ptype);
    const proto_shape = protoPadShape(shape);

    try w.writeAll("{\"@type\":\"" ++ PROTO_TYPE_URL_PAD ++ "\",\"id\":{},\"number\":");
    try writeJsonString(w, num);
    try w.print(",\"type\":\"{s}\"", .{proto_type});
    try w.print(",\"position\":{{\"xNm\":{d},\"yNm\":{d}}}", .{ mmToNm(pos_x), mmToNm(pos_y) });
    try w.writeAll(",\"padStack\":{");
    try w.writeAll("\"type\":\"" ++ PROTO_PADSTACK_NORMAL ++ "\",");
    // Standard layer sets per pad type — KiCad's IPC needs both the
    // top-level `layers` array (which physical layers the pad lives on)
    // and a `copperLayers[]` describing the shape on each copper layer.
    if (std.mem.eql(u8, proto_type, PROTO_PADTYPE_SMD)) {
        try w.writeAll("\"layers\":[\"BL_F_Cu\",\"BL_F_Paste\",\"BL_F_Mask\"],");
    } else {
        try w.writeAll("\"layers\":[\"BL_F_Cu\",\"BL_B_Cu\",\"BL_F_Mask\",\"BL_B_Mask\"],");
    }
    try w.writeAll("\"copperLayers\":[{");
    try w.print("\"layer\":\"{s}\",\"shape\":\"{s}\"", .{ protoBoardLayer("F.Cu"), proto_shape });
    try w.print(",\"size\":{{\"xNm\":{d},\"yNm\":{d}}}", .{ mmToNm(size_w), mmToNm(size_h) });
    if (std.mem.eql(u8, proto_shape, "PSS_ROUNDRECT")) {
        try w.print(",\"cornerRoundingRatio\":{d}", .{rratio});
    }
    try w.writeAll("}]");
    try w.print(",\"angle\":{{\"valueDegrees\":{d}}}", .{pos_rot});
    if (drill_d > 0) {
        const d_nm = mmToNm(drill_d);
        try w.writeAll(",\"drill\":{\"startLayer\":\"BL_F_Cu\",\"endLayer\":\"BL_B_Cu\",");
        try w.print("\"diameter\":{{\"xNm\":{d},\"yNm\":{d}}}}}", .{ d_nm, d_nm });
    }
    try w.writeAll("}}");
}

/// KiCad's IPC measures distances in nanometres (1 mm = 1e6 nm). Used
/// when emitting Vector2 messages in proto-canonical JSON.
const NM_PER_MM: f64 = 1_000_000.0;

/// Convert a millimetre value to nanometres (KiCad's wire unit). Returns
/// signed i64 because pad positions are negative on the left half of a
/// footprint.
fn mmToNm(mm: f64) i64 {
    return @intFromFloat(mm * NM_PER_MM);
}

/// Pad numbers in EDA `.sexp` come in three flavors:
///   - bare digit token  (1, 2, …) — parsed as `int` by the sexpr parser
///   - bare alphanumeric (MP1, A1) — parsed as `atom`
///   - quoted             ("1A")    — parsed as `string`
/// Normalise all three to a heap-allocated text slice.
fn padNumberText(arena: std.mem.Allocator, n: env_mod_node.Node) ?[]const u8 {
    if (n.asAtom()) |a| return a;
    if (n.asString()) |s| return s;
    switch (n.tag) {
        .int => |i| return std.fmt.allocPrint(arena, "{d}", .{i}) catch null,
        else => return null,
    }
}

const SyncSummary = struct {
    updated: u32 = 0,
    added: u32 = 0,
    removed: u32 = 0,
    swapped: u32 = 0,
    flagged_stale: u32 = 0,
};

/// POST /api/sync-plan/:name — compare client board state against the
/// design's flattened netlist and return ops to apply. Auth-gated by
/// the same OAuth/plugin-token check used for the manifest endpoints.
pub fn syncPlanApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };
    const body = req.body() orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "missing body";
        return;
    };

    const parsed = parseSyncPlanBody(req.arena, body) catch {
        res.status = HTTP_BAD_REQUEST;
        res.body = "invalid request body";
        return;
    };

    const board_path = try paths.designSourcePath(req.arena, ctx.project_dir, name);
    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    const result = eval.evalFile(board_path) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = ERR_BUILD_ERROR;
        return;
    };
    const block = switch (result) {
        .design_block => |b| b,
        else => {
            res.status = HTTP_INTERNAL_ERROR;
            res.body = ERR_NOT_A_DESIGN;
            return;
        },
    };

    const bom_path = try paths.designSiblingPath(req.arena, ctx.project_dir, name, ".bom");
    bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir) catch |e| warnResolveIdentities(name, e);

    var instances: std.ArrayListUnmanaged(export_kicad.FlatInstance) = .empty;
    try netlist_mod.collectInstances(req.arena, block, "", &instances);
    var nets: std.ArrayListUnmanaged(export_kicad.FlatNet) = .empty;
    try export_kicad.flattenAndMergeNets(req.arena, block, &nets);

    // (ref, pin) -> net_name. Empty net names are excluded (NC pads).
    //
    // Two-stage name normalisation runs before we map pins → nets:
    //
    //  1. Dot-collapse: `(decouple …)` generates per-pin sub-nets of the
    //     form `<rail>.<refdes>.<pin>` (e.g. `VDD.U18.IN`) as a routing
    //     organisation aid. The design author's intent is that they
    //     share the rail's electrical net; collapse unconditionally to
    //     the part before the first `.`.
    //  2. Slash-strip: sub-block path prefixes (e.g. `adc1/REGCAP`)
    //     come from `collectNets` walking sub_blocks. Strip when the
    //     bare name is globally unique across the post-dot-collapse
    //     netlist, keep when it would collide. `adc1/REGCAP`,
    //     `adc2/REGCAP`, `adc3/REGCAP` are three physically distinct
    //     decoupling rails that must NOT merge, so all three keep
    //     their prefix.
    var bare_counts = std.StringHashMap(u32).init(req.arena);
    for (nets.items) |net| {
        if (net.name.len == 0) continue;
        const post_dot = collapseDotSubNet(net.name);
        const bare = bareNetName(post_dot);
        const e = try bare_counts.getOrPut(bare);
        if (!e.found_existing) e.value_ptr.* = 0;
        e.value_ptr.* += 1;
    }
    var pad_net_map = std.StringHashMap([]const u8).init(req.arena);
    for (nets.items) |net| {
        if (net.name.len == 0) continue;
        const post_dot = collapseDotSubNet(net.name);
        const bare = bareNetName(post_dot);
        const display = if ((bare_counts.get(bare) orelse 0) == 1) bare else post_dot;
        for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(req.arena, "{s}|{s}", .{ pin.ref_des, pin.pin });
            try pad_net_map.put(key, display);
        }
    }

    var by_uuid = std.StringHashMap(BoardFp).init(req.arena);
    var by_ref = std.StringHashMap(BoardFp).init(req.arena);
    for (parsed.board) |bfp| {
        if (bfp.uuid.len > 0) try by_uuid.put(bfp.uuid, bfp);
        if (bfp.ref.len > 0) try by_ref.put(bfp.ref, bfp);
    }

    // Heuristic index for --migrate mode. Maps each design instance's
    // canopy uuid → the board footprint it should adopt placement from,
    // when both sides have the same count of footprints with the same
    // (parent_path, footprint_name, value) signature. Pairing within a
    // group is deterministic-by-ref so the user gets a reproducible
    // shuffle even when individual identities can't be recovered.
    var by_migration = std.StringHashMap(BoardFp).init(req.arena);
    var by_netsig = std.StringHashMap(BoardFp).init(req.arena);
    if (parsed.migrate_heuristic) {
        try buildMigrationIndex(req.arena, parsed.board, instances.items, &by_migration);
        // Net-signature relink runs after (parent_path, value) migration so
        // it only considers the orphans that group-size matching couldn't
        // pair — typically board fps the design author moved across the
        // hierarchy (top-level `Q1` → `disp/Q3`). Both tiers are gated on
        // --migrate so the agent's default sync stays conservative.
        try buildNetSignatureRelinkIndex(
            req.arena,
            ctx.project_dir,
            parsed.board,
            instances.items,
            &by_uuid,
            &by_ref,
            &by_migration,
            &pad_net_map,
            &by_netsig,
        );
    }

    var model_cfg = export_kicad.loadModelConfig(req.arena, ctx.project_dir);
    defer model_cfg.deinit();
    var spc = SyncPlanContext{ .arena = req.arena, .project_dir = ctx.project_dir, .model_cfg = &model_cfg };

    var ops_buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = ops_buf.writer(req.arena);
    var first_op = true;
    var summary = SyncSummary{};
    var matched_uuids = std.StringHashMap(void).init(req.arena);
    var canonical_fp_name = std.StringHashMap([]const u8).init(req.arena);

    try w.writeAll("[");

    var diff_ctx = DiffContext{
        .by_uuid = &by_uuid,
        .by_ref = &by_ref,
        .by_migration = &by_migration,
        .by_netsig = &by_netsig,
        .pad_net_map = &pad_net_map,
        .matched_uuids = &matched_uuids,
        .canonical_fp_name = &canonical_fp_name,
        .spc = &spc,
        .summary = &summary,
        .migrate_heuristic = parsed.migrate_heuristic,
    };
    for (instances.items) |inst| try handleInstance(&diff_ctx, inst, &w, &first_op);

    // Stale = a board footprint that didn't match any design instance.
    // We only flag/prune footprints the sync has ever managed (i.e. those
    // with a canopy_uuid set). Footprints without canopy_uuid are
    // typically user-placed mechanicals (mounting holes, fiducials,
    // logos) that we leave alone. Ops target by KiCad-internal UUID so
    // the agent's apply path resolves regardless of canopy_uuid state.
    for (parsed.board) |bfp| {
        if (bfp.uuid.len == 0) continue;
        if (matched_uuids.contains(bfp.kicad_uuid)) continue;
        const target = opTargetUuid(bfp);
        if (target.len == 0) continue;
        if (parsed.prune_stale) {
            try emitOp(&w, &first_op, "remove", .{.{ "uuid", target }});
            summary.removed += 1;
        } else {
            try emitOp(&w, &first_op, "flag_stale", .{ .{ "uuid", target }, .{ "ref", bfp.ref } });
            summary.flagged_stale += 1;
        }
    }

    try w.writeAll("]");

    // Final response envelope.
    var resp_buf: std.ArrayListUnmanaged(u8) = .empty;
    const rw = resp_buf.writer(ctx.allocator);
    const version = serve_root.getLiveVersion(name);
    try rw.print(
        "{{\"design_version\":{d},\"summary\":{{\"updated\":{d},\"added\":{d},\"removed\":{d},\"swapped\":{d},\"flagged_stale\":{d}}},\"ops\":",
        .{ version, summary.updated, summary.added, summary.removed, summary.swapped, summary.flagged_stale },
    );
    try rw.writeAll(ops_buf.items);
    try rw.writeAll("}");

    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.body = resp_buf.items;
}

const DiffContext = struct {
    by_uuid: *std.StringHashMap(BoardFp),
    by_ref: *std.StringHashMap(BoardFp),
    /// Migration mode: design instance uuid → BoardFp it should adopt
    /// placement from. Populated by `buildMigrationIndex`; empty when
    /// --migrate is off.
    by_migration: *std.StringHashMap(BoardFp),
    /// Net-signature relink: design instance uuid → BoardFp it should
    /// adopt. Populated by `buildNetSignatureRelinkIndex` for orphans the
    /// (parent_path, value) migration tier couldn't pair — typically
    /// cross-hierarchy moves like top-level `Q1` → `disp/Q3`. Gated on
    /// --migrate alongside the migration index.
    by_netsig: *std.StringHashMap(BoardFp),
    pad_net_map: *std.StringHashMap([]const u8),
    matched_uuids: *std.StringHashMap(void),
    /// short EDA footprint name ("c-0201") → canonical KiCad name inside
    /// the lib/footprints/<short>.sexp file ("C_0201_0603Metric"). Used to
    /// skip swap_footprint ops when a manually-placed board fp carries the
    /// KiCad-canonical name but resolves to the same physical footprint as
    /// the design's short name. Populated lazily on first lookup.
    canonical_fp_name: *std.StringHashMap([]const u8),
    spc: *SyncPlanContext,
    summary: *SyncSummary,
    migrate_heuristic: bool,
};

/// Treat a board footprint's name as matching the design's short name when
/// it equals either the short name itself or the canonical KiCad name
/// declared inside `lib/footprints/<short>.sexp`. Legacy boards routinely
/// carry the KiCad-canonical name (`C_0201_0603Metric`) because they were
/// laid out from a `kicad-cli`-exported netlist — without this aliasing
/// every such fp would emit a spurious swap_footprint on the first sync.
fn footprintNameMatches(d: *DiffContext, board_name: []const u8, short: []const u8) bool {
    if (std.mem.eql(u8, board_name, short)) return true;
    const canonical = canonicalFootprintName(d, short) orelse return false;
    return std.mem.eql(u8, board_name, canonical);
}

/// Resolve the KiCad-canonical name for `short` ("c-0201" → "C_0201_0603Metric"),
/// cached per-request. Returns null when the .sexp file is missing or
/// doesn't parse as a footprint form.
fn canonicalFootprintName(d: *DiffContext, short: []const u8) ?[]const u8 {
    return canonicalFootprintNameImpl(d, short) catch null;
}

fn canonicalFootprintNameImpl(d: *DiffContext, short: []const u8) !?[]const u8 {
    if (d.canonical_fp_name.get(short)) |cached| {
        if (cached.len == 0) return null;
        return cached;
    }
    const fp_path = try std.fmt.allocPrint(d.spc.arena, PATH_FMT_FP_SEXP, .{ d.spc.project_dir, short });
    const fp_source = infra_fs.cwd().readFileAlloc(d.spc.arena, fp_path, MAX_FOOTPRINT_BYTES) catch {
        try d.canonical_fp_name.put(short, "");
        return null;
    };
    const name = netlist_mod.extractFootprintName(d.spc.arena, fp_source) catch {
        try d.canonical_fp_name.put(short, "");
        return null;
    };
    try d.canonical_fp_name.put(short, name);
    return name;
}

/// Extract the parent-path prefix of a hierarchical ref-des. Returns the
/// empty string for a top-level ref. e.g. `"adc1/C146"` → `"adc1/"`,
/// `"C18"` → `""`.
fn parentPathOf(ref: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, ref, '/')) |i| return ref[0 .. i + 1];
    return "";
}

/// Build the (parent_path, value) key used for migration-mode heuristic
/// matching. We deliberately omit footprint_name: legacy boards routinely
/// carry KiCad-canonical names (`C_0201_0603Metric`) while the design
/// emits EDA-short names (`c-0201`). The swap_footprint op the diff loop
/// emits afterwards handles the rename, and value is specific enough to
/// keep different cap sizes apart within a sub-section.
fn heuristicKey(arena: std.mem.Allocator, parent: []const u8, _: []const u8, value: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}|{s}", .{ parent, value });
}

fn matchInstance(d: *DiffContext, inst: export_kicad.FlatInstance, w: anytype, first: *bool, ops_emitted: *u32) !?BoardFp {
    // Net-signature relink wins over canopy uuid: the relink builder
    // only populates a pairing when there's an orphan board fp with the
    // same wiring + footprint AND no other claimant. When that fires
    // for a design instance whose canopy uuid happens to also point at
    // a (likely agent-created duplicate at origin) by_uuid entry, the
    // netsig pair wins and the duplicate falls into stale — exactly
    // what the user wants when running --migrate to recover a board
    // where a hierarchy move (top-level `Q1` → `disp/Q3`) caused the
    // sync to create a clone instead of relinking the existing fp.
    if (d.migrate_heuristic) {
        if (d.by_netsig.get(inst.uuid)) |m| return m;
    }
    if (d.by_uuid.get(inst.uuid)) |m| return m;
    if (inst.ref_des.len > 0) {
        if (d.by_ref.get(inst.ref_des)) |m| {
            if (m.uuid.len == 0) {
                // Backfill the canopy_uuid custom field on this footprint
                // so the next sync UUID-matches without falling back to
                // ref_des. Target by KiCad-internal UUID so the agent's
                // cache resolves even before canopy_uuid is set.
                try emitOp(w, first, OP_SET_FIELD, .{
                    .{ "uuid", opTargetUuid(m) },
                    .{ "field", FIELD_CANOPY_UUID },
                    .{ "value", inst.uuid },
                });
                ops_emitted.* += 1;
            }
            return m;
        }
    }
    if (heuristicMatch(d, inst)) |m| {
        // Migration tier: rename the matched board footprint to the
        // design's ref_des and stamp the design's canopy_uuid. The normal
        // handleMatched path emits the reference + canopy_uuid set_field
        // ops as part of its diff (since m.ref != inst.ref_des and
        // m.uuid != inst.uuid), so no extra emission needed here.
        return m;
    }
    return null;
}

/// Migration-mode lookup for (parent_path, value) pairings. Gated on
/// --migrate. Net-signature relink is checked separately in
/// `matchInstance` (it must beat by_uuid to recover from agent-created
/// duplicates) so it lives outside this helper.
fn heuristicMatch(d: *DiffContext, inst: export_kicad.FlatInstance) ?BoardFp {
    if (!d.migrate_heuristic) return null;
    return d.by_migration.get(inst.uuid);
}

/// Build a sortable signature string of a design instance's pad-net
/// assignments, derived from the diff loop's `pad_net_map`. Format is
/// `<pad1>=<net1>;<pad2>=<net2>;…` with pads sorted lexicographically so
/// two instances with identical wiring produce identical strings.
/// Returns "" when the instance has no pads on named nets (NC-only),
/// signalling the caller to skip it for relinking.
fn designInstanceNetSig(
    arena: std.mem.Allocator,
    inst_ref_des: []const u8,
    pad_net_map: *std.StringHashMap([]const u8),
) ![]const u8 {
    var pairs: std.ArrayListUnmanaged(struct { pad: []const u8, net: []const u8 }) = .empty;
    var it = pad_net_map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const sep = std.mem.indexOfScalar(u8, key, '|') orelse continue;
        if (!std.mem.eql(u8, key[0..sep], inst_ref_des)) continue;
        try pairs.append(arena, .{ .pad = key[sep + 1 ..], .net = entry.value_ptr.* });
    }
    if (pairs.items.len == 0) return "";
    std.mem.sort(@TypeOf(pairs.items[0]), pairs.items, {}, struct {
        fn lessThan(_: void, a: @TypeOf(pairs.items[0]), b: @TypeOf(pairs.items[0])) bool {
            return std.mem.lessThan(u8, a.pad, b.pad);
        }
    }.lessThan);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(arena);
    for (pairs.items) |p| try w.print("{s}={s};", .{ p.pad, p.net });
    return buf.items;
}

/// Same signature format as `designInstanceNetSig`, computed from the
/// pad list the agent reported for a board fp. Empty when the fp has no
/// pads on named nets.
fn boardFpNetSig(arena: std.mem.Allocator, bfp: BoardFp) ![]const u8 {
    var pairs: std.ArrayListUnmanaged(struct { pad: []const u8, net: []const u8 }) = .empty;
    for (bfp.pads) |p| {
        if (p.net.len == 0) continue;
        try pairs.append(arena, .{ .pad = p.number, .net = p.net });
    }
    if (pairs.items.len == 0) return "";
    std.mem.sort(@TypeOf(pairs.items[0]), pairs.items, {}, struct {
        fn lessThan(_: void, a: @TypeOf(pairs.items[0]), b: @TypeOf(pairs.items[0])) bool {
            return std.mem.lessThan(u8, a.pad, b.pad);
        }
    }.lessThan);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(arena);
    for (pairs.items) |p| try w.print("{s}={s};", .{ p.pad, p.net });
    return buf.items;
}

/// Pair orphan board fps with orphan design instances by exact net
/// signature. "Orphan" = won't pair via canopy_uuid match, ref-des
/// match, or the (parent_path, value) migration tier. Only emits a pair
/// when the signature is unique on BOTH sides — if two board fps have
/// the same signature, or two design instances do, we skip both rather
/// than guess. The footprint name must also match (canonical or short).
///
/// Output keyed by design instance uuid so heuristicMatch resolves in O(1).
fn buildNetSignatureRelinkIndex(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    board: []const BoardFp,
    instances: []const export_kicad.FlatInstance,
    by_uuid: *std.StringHashMap(BoardFp),
    _: *std.StringHashMap(BoardFp), // by_ref — unused since the netsig tier
    // deliberately considers insts that already match by_ref so it can
    // pair them with an orphan instead of an agent-created duplicate.
    by_migration: *std.StringHashMap(BoardFp),
    pad_net_map: *std.StringHashMap([]const u8),
    out: *std.StringHashMap(BoardFp),
) !void {
    // The migration index is keyed by design uuid → BoardFp; mark which
    // board fps it already claimed so we don't double-pair them.
    var migration_claimed_kids = std.StringHashMap(void).init(arena);
    var mit = by_migration.iterator();
    while (mit.next()) |entry| {
        const m = entry.value_ptr.*;
        if (m.kicad_uuid.len > 0) try migration_claimed_kids.put(m.kicad_uuid, {});
    }

    // Bucket orphan board fps by netsig (with footprint name appended so
    // a stray `c-0201`-vs-`r-0201` collision on pads can't pair).
    var board_by_sig = std.StringHashMap(std.ArrayListUnmanaged(BoardFp)).init(arena);
    for (board) |bfp| {
        if (bfp.uuid.len == 0) continue;
        if (migration_claimed_kids.contains(bfp.kicad_uuid)) continue;
        // Skip board fps whose canopy uuid already pairs with a design
        // instance directly — those are reachable via by_uuid and not
        // orphans at all.
        if (by_uuid.contains(bfp.uuid) and matchesUuidExactlyInDesign(bfp.uuid, instances)) continue;
        const sig = try boardFpNetSig(arena, bfp);
        if (sig.len == 0) continue;
        const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ bfp.footprint_name, sig });
        const e = try board_by_sig.getOrPut(key);
        if (!e.found_existing) e.value_ptr.* = .empty;
        try e.value_ptr.append(arena, bfp);
    }

    // Bucket design instances by netsig. We don't skip insts that match
    // by_uuid or by_ref — those matches may be to an agent-created
    // duplicate at the origin (same canopy_uuid AND same ref-des as the
    // design instance because the previous sync created it from the
    // design state, but at the wrong physical location). Letting netsig
    // consider this instance lets it pair with the genuine orphan
    // board fp instead, dropping the duplicate into stale.
    //
    // Migration-tier matches are already a deterministic pairing so we
    // skip those — netsig overriding them would just churn.
    var design_by_sig = std.StringHashMap(std.ArrayListUnmanaged(export_kicad.FlatInstance)).init(arena);
    // We don't skip ANY insts (not by_uuid, by_ref, or by_migration) so
    // netsig can override every other tier when it finds a unique
    // matching orphan. The pair only fires when the signature is unique
    // on both sides — if migration's pair is a legit physical match
    // they'd share the signature with the orphan and the resulting
    // ambiguity (2 board fps, 1 design inst) skips the pair.
    for (instances) |inst| {
        const sig = try designInstanceNetSig(arena, inst.ref_des, pad_net_map);
        if (sig.len == 0) continue;
        const fp_short = stripLibPrefix(inst.footprint);
        const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ fp_short, sig });
        const e = try design_by_sig.getOrPut(key);
        if (!e.found_existing) e.value_ptr.* = .empty;
        try e.value_ptr.append(arena, inst);
    }

    // For each design signature with exactly one orphan instance AND
    // exactly one orphan board fp on the same signature, pair them.
    // Footprint-name in the key uses the EDA short name for the design
    // side and the KiCad-canonical name for the board side. We compare
    // by trying both forms when looking up — if the board's canonical
    // form maps back to the same short name, the signatures match.
    var dit = design_by_sig.iterator();
    while (dit.next()) |entry| {
        if (entry.value_ptr.items.len != 1) continue;
        const inst = entry.value_ptr.items[0];
        const sig_after_pipe = std.mem.indexOfScalar(u8, entry.key_ptr.*, '|') orelse continue;
        const sig = entry.key_ptr.*[sig_after_pipe + 1 ..];

        // Try matching the board side first by EDA short name (same key),
        // then by walking all board buckets whose sig matches and whose
        // footprint name canonicalises to the same short form.
        var found_board: ?BoardFp = null;
        var ambiguous = false;
        if (board_by_sig.get(entry.key_ptr.*)) |bucket| {
            if (bucket.items.len == 1) found_board = bucket.items[0];
            if (bucket.items.len > 1) ambiguous = true;
        }
        if (found_board == null and !ambiguous) {
            // Fall back: scan all board buckets, accepting any whose
            // signature suffix matches and whose footprint name is the
            // KiCad-canonical alias of the design's short name.
            const fp_short = stripLibPrefix(inst.footprint);
            var bit = board_by_sig.iterator();
            while (bit.next()) |bentry| {
                const bkey = bentry.key_ptr.*;
                const bsep = std.mem.indexOfScalar(u8, bkey, '|') orelse continue;
                if (!std.mem.eql(u8, bkey[bsep + 1 ..], sig)) continue;
                const board_fp_name = bkey[0..bsep];
                if (!std.mem.eql(u8, board_fp_name, fp_short) and
                    !boardFpNameAliasesShort(arena, project_dir, board_fp_name, fp_short))
                    continue;
                if (bentry.value_ptr.items.len != 1) {
                    ambiguous = true;
                    break;
                }
                if (found_board != null) {
                    ambiguous = true;
                    break;
                }
                found_board = bentry.value_ptr.items[0];
            }
        }
        if (ambiguous) continue;
        const board_fp = found_board orelse continue;
        try out.put(inst.uuid, board_fp);
    }
}

/// Return true when at least one design instance carries `uuid` as its
/// canopy uuid — used by net-signature relink to skip board fps that
/// already pair through the by_uuid index.
fn matchesUuidExactlyInDesign(uuid: []const u8, instances: []const export_kicad.FlatInstance) bool {
    for (instances) |inst| {
        if (std.mem.eql(u8, inst.uuid, uuid)) return true;
    }
    return false;
}

/// True when `board_name` is the KiCad-canonical alias of EDA short name
/// `short` (e.g. `C_0201_0603Metric` ↔ `c-0201`). Reads
/// `lib/footprints/<short>.sexp` on demand; failures degrade to false so
/// a missing library doesn't pair the wrong fp.
fn boardFpNameAliasesShort(arena: std.mem.Allocator, project_dir: []const u8, board_name: []const u8, short: []const u8) bool {
    if (std.mem.eql(u8, board_name, short)) return true;
    // Re-read the .sexp on demand — this is called during relink-index
    // construction (once per sync), not per-instance in the diff loop,
    // so the cost is fine.
    const fp_path = std.fmt.allocPrint(arena, PATH_FMT_FP_SEXP, .{ project_dir, short }) catch return false;
    const fp_source = infra_fs.cwd().readFileAlloc(arena, fp_path, MAX_FOOTPRINT_BYTES) catch return false;
    const canonical = netlist_mod.extractFootprintName(arena, fp_source) catch return false;
    return std.mem.eql(u8, board_name, canonical);
}

/// Pair board footprints with design instances by (parent_path,
/// footprint_name, value). When a key has the same count N on both sides,
/// pair them deterministically — sort each side by ref-des and match
/// element-i to element-i. The N==M skip rule prevents a 12-cap section
/// from silently absorbing 8 caps and dropping 4 on the floor.
///
/// The pairings populate `out` keyed by design instance uuid so the diff
/// loop can resolve each `inst.uuid` → adopted `BoardFp` in O(1).
fn buildMigrationIndex(
    arena: std.mem.Allocator,
    board: []const BoardFp,
    instances: []const export_kicad.FlatInstance,
    out: *std.StringHashMap(BoardFp),
) !void {
    // Index design + board by heuristic key. Hash → list of refs; we sort
    // the lists later for deterministic pairing.
    var board_groups = std.StringHashMap(std.ArrayListUnmanaged(BoardFp)).init(arena);
    var design_groups = std.StringHashMap(std.ArrayListUnmanaged(export_kicad.FlatInstance)).init(arena);

    for (board) |bfp| {
        const key = try heuristicKey(arena, parentPathOf(bfp.ref), bfp.footprint_name, bfp.value);
        const e = try board_groups.getOrPut(key);
        if (!e.found_existing) e.value_ptr.* = .empty;
        try e.value_ptr.append(arena, bfp);
    }
    for (instances) |inst| {
        const fp_name = stripLibPrefix(inst.footprint);
        const key = try heuristicKey(arena, parentPathOf(inst.ref_des), fp_name, inst.value);
        const e = try design_groups.getOrPut(key);
        if (!e.found_existing) e.value_ptr.* = .empty;
        try e.value_ptr.append(arena, inst);
    }

    var it = design_groups.iterator();
    while (it.next()) |entry| {
        const dgroup = entry.value_ptr.*;
        const bgroup = board_groups.get(entry.key_ptr.*) orelse continue;
        if (dgroup.items.len != bgroup.items.len) continue;
        // Sort both sides by ref-des so the pairing is stable across
        // re-runs and across rebuilds. Different runs of --migrate against
        // the same inputs MUST produce the same plan.
        std.mem.sort(BoardFp, bgroup.items, {}, lessByRef);
        std.mem.sort(export_kicad.FlatInstance, dgroup.items, {}, lessByDesignRef);
        for (dgroup.items, bgroup.items) |inst, bfp| {
            try out.put(inst.uuid, bfp);
        }
    }
}

fn lessByRef(_: void, a: BoardFp, b: BoardFp) bool {
    return std.mem.lessThan(u8, a.ref, b.ref);
}

fn lessByDesignRef(_: void, a: export_kicad.FlatInstance, b: export_kicad.FlatInstance) bool {
    return std.mem.lessThan(u8, a.ref_des, b.ref_des);
}

fn handleMatched(d: *DiffContext, inst: export_kicad.FlatInstance, m: BoardFp, fp_name_short: []const u8, w: anytype, first: *bool, ops_emitted: *u32) !void {
    // Track matches by KiCad-internal UUID — that field is always
    // populated, whereas canopy_uuid is empty for ref-des-fallback
    // matches until the backfill op lands on a future sync.
    if (m.kicad_uuid.len > 0) try d.matched_uuids.put(m.kicad_uuid, {});
    const target = opTargetUuid(m);
    if (!footprintNameMatches(d, m.footprint_name, fp_name_short)) {
        if (loadKicadMod(d.spc, fp_name_short, inst.component)) |kmod| {
            const fp_def = loadFootprintDef(d.spc, fp_name_short);
            try emitSwapOp(w, first, target, fp_name_short, kmod, fp_def, inst.ref_des, d.pad_net_map);
            d.summary.swapped += 1;
            ops_emitted.* += 1;
        }
    }
    if (!std.mem.eql(u8, m.ref, inst.ref_des)) {
        try emitOp(w, first, OP_SET_FIELD, .{
            .{ "uuid", target },
            .{ "field", "reference" },
            .{ "value", inst.ref_des },
        });
        ops_emitted.* += 1;
    }
    if (!std.mem.eql(u8, m.value, inst.value)) {
        try emitOp(w, first, OP_SET_FIELD, .{
            .{ "uuid", target },
            .{ "field", "value" },
            .{ "value", inst.value },
        });
        ops_emitted.* += 1;
    }
    // Align canopy_uuid whenever it drifted (legacy long-form, --migrate
    // pairing, etc.). After this op lands, the next sync UUID-matches
    // without falling through to ref-des or migration tiers.
    if (m.uuid.len > 0 and !std.mem.eql(u8, m.uuid, inst.uuid)) {
        try emitOp(w, first, OP_SET_FIELD, .{
            .{ "uuid", target },
            .{ "field", FIELD_CANOPY_UUID },
            .{ "value", inst.uuid },
        });
        ops_emitted.* += 1;
    }
    // Push every design property to KiCad as a custom Field, so adding a
    // new BOM column (manufacturer, datasheet, supplier_pn, …) is a pure
    // server-side change with no agent update. Skip property keys that
    // collide with KiCad's built-in ref/value/footprint handling — those
    // travel through dedicated set_field ops above. The canonical-name map
    // upper-cases well-known KiCad field names (mpn → MPN) so manually-
    // placed footprints with the standard column name match cleanly.
    for (inst.properties) |p| {
        if (skipDesignProperty(p.key)) continue;
        if (p.value.len == 0) continue;
        const field_name = canonicalFieldName(p.key);
        const board_value = m.fields.get(field_name) orelse "";
        if (std.mem.eql(u8, board_value, p.value)) continue;
        try emitOp(w, first, OP_SET_FIELD, .{
            .{ "uuid", target },
            .{ "field", field_name },
            .{ "value", p.value },
        });
        ops_emitted.* += 1;
    }
    ops_emitted.* += try emitPadNetOps(w, first, target, inst.ref_des, d.pad_net_map, m.pads);
}

/// Property keys we deliberately don't push to KiCad as custom fields:
/// `value`/`footprint` are KiCad-built-in (already handled via dedicated
/// set_field ops on inst.value / inst.footprint), and `description` would
/// collide with the description KiCad reads from the footprint library.
fn skipDesignProperty(key: []const u8) bool {
    if (std.mem.eql(u8, key, "value")) return true;
    if (std.mem.eql(u8, key, "footprint")) return true;
    if (std.mem.eql(u8, key, "description")) return true;
    return false;
}

/// Canonicalise design property keys to KiCad's standard field-column
/// names so users with manually-placed footprints (already carrying
/// "MPN", "Manufacturer", …) don't see a duplicate lower-cased twin land
/// on first sync. Unknown keys pass through unchanged so user-defined
/// property keys still work.
fn canonicalFieldName(key: []const u8) []const u8 {
    if (std.mem.eql(u8, key, "mpn")) return "MPN";
    if (std.mem.eql(u8, key, "manufacturer")) return "Manufacturer";
    if (std.mem.eql(u8, key, "datasheet")) return "Datasheet";
    return key;
}

fn handleInstance(d: *DiffContext, inst: export_kicad.FlatInstance, w: anytype, first: *bool) !void {
    const fp_name_short = stripLibPrefix(inst.footprint);
    var ops_emitted: u32 = 0;
    if (try matchInstance(d, inst, w, first, &ops_emitted)) |m| {
        try handleMatched(d, inst, m, fp_name_short, w, first, &ops_emitted);
        // Only count as "updated" when at least one op was actually
        // emitted — otherwise every no-diff sync would still surface
        // "Updated: N" to the user even though nothing changed.
        if (ops_emitted > 0) d.summary.updated += 1;
        return;
    }
    const kmod = loadKicadMod(d.spc, fp_name_short, inst.component) orelse return;
    // Pass the instance so canopy_uuid + design properties get baked
    // into the inline Items as Field entries on the first add — without
    // this the user sees "press sync twice" because canopy_uuid + MPN
    // would only land via follow-up set_field ops on the second sync.
    const fp_def = loadFootprintDefForInstance(d.spc, fp_name_short, inst);
    try emitAddOp(w, first, inst, fp_name_short, kmod, fp_def, d.pad_net_map);
    d.summary.added += 1;
}

fn emitOp(w: anytype, first: *bool, op: []const u8, fields: anytype) !void {
    if (!first.*) try w.*.writeAll(",");
    first.* = false;
    try w.*.writeAll("{\"op\":\"");
    try w.*.writeAll(op);
    try w.*.writeAll("\"");
    inline for (fields) |kv| {
        try w.*.writeAll(",");
        try w.*.print("\"{s}\":", .{kv[0]});
        try writeJsonString(w.*, kv[1]);
    }
    try w.*.writeAll("}");
}

fn emitAddOp(
    w: anytype,
    first: *bool,
    inst: export_kicad.FlatInstance,
    fp_name: []const u8,
    kmod: []const u8,
    fp_def_json: ?[]const u8,
    pad_net_map: *std.StringHashMap([]const u8),
) !void {
    if (!first.*) try w.*.writeAll(",");
    first.* = false;
    try w.*.writeAll("{\"op\":\"add\",\"uuid\":");
    try writeJsonString(w.*, inst.uuid);
    try w.*.writeAll(",\"ref\":");
    try writeJsonString(w.*, inst.ref_des);
    try w.*.writeAll(",\"value\":");
    try writeJsonString(w.*, inst.value);
    try w.*.writeAll(",\"footprint_name\":");
    try writeJsonString(w.*, fp_name);
    try w.*.writeAll(",\"kicad_mod\":");
    try writeJsonString(w.*, kmod);
    if (fp_def_json) |def| {
        try w.*.writeAll(",\"footprint_def\":");
        try w.*.writeAll(def);
    }
    try w.*.writeAll(",\"pad_nets\":");
    try writePadNetsArray(w.*, inst.ref_des, pad_net_map);
    try w.*.writeAll("}");
}

fn emitSwapOp(
    w: anytype,
    first: *bool,
    uuid: []const u8,
    fp_name: []const u8,
    kmod: []const u8,
    fp_def_json: ?[]const u8,
    ref_des: []const u8,
    pad_net_map: *std.StringHashMap([]const u8),
) !void {
    if (!first.*) try w.*.writeAll(",");
    first.* = false;
    try w.*.writeAll("{\"op\":\"swap_footprint\",\"uuid\":");
    try writeJsonString(w.*, uuid);
    try w.*.writeAll(",\"new_footprint_name\":");
    try writeJsonString(w.*, fp_name);
    try w.*.writeAll(",\"kicad_mod\":");
    try writeJsonString(w.*, kmod);
    if (fp_def_json) |def| {
        try w.*.writeAll(",\"footprint_def\":");
        try w.*.writeAll(def);
    }
    try w.*.writeAll(",\"pad_nets\":");
    try writePadNetsArray(w.*, ref_des, pad_net_map);
    try w.*.writeAll("}");
}

/// Emit one `set_pad_net` op per pad whose net assignment differs from
/// what the client reported. Pads only on one side (e.g. NC pads or pads
/// the client didn't list) are skipped. Returns the number of ops emitted
/// so the caller can decide whether the surrounding instance counts as
/// "updated" — a no-diff sync should be silent in the user-facing toast.
fn emitPadNetOps(
    w: anytype,
    first: *bool,
    uuid: []const u8,
    ref_des: []const u8,
    pad_net_map: *std.StringHashMap([]const u8),
    client_pads: []const PadAssign,
) !u32 {
    var key_buf: [256]u8 = undefined;
    var emitted: u32 = 0;
    for (client_pads) |cp| {
        const key = std.fmt.bufPrint(&key_buf, "{s}|{s}", .{ ref_des, cp.number }) catch continue;
        const want = pad_net_map.get(key) orelse continue;
        if (std.mem.eql(u8, want, cp.net)) continue;
        try emitOp(w, first, "set_pad_net", .{
            .{ "uuid", uuid },
            .{ "pad", cp.number },
            .{ "net", want },
        });
        emitted += 1;
    }
    return emitted;
}

fn writePadNetsArray(
    w: anytype,
    ref_des: []const u8,
    pad_net_map: *std.StringHashMap([]const u8),
) !void {
    try w.writeAll("[");
    var it = pad_net_map.iterator();
    var first = true;
    while (it.next()) |entry| {
        // Keys have shape "ref|pin"; filter to this ref_des.
        const k = entry.key_ptr.*;
        const sep = std.mem.indexOfScalar(u8, k, '|') orelse continue;
        if (!std.mem.eql(u8, k[0..sep], ref_des)) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("[");
        try writeJsonString(w, k[sep + 1 ..]);
        try w.writeAll(",");
        try writeJsonString(w, entry.value_ptr.*);
        try w.writeAll("]");
    }
    try w.writeAll("]");
}

// ── helpers ─────────────────────────────────────────────────────────────

const FootprintEntry = struct {
    kicad_name: []const u8,
    sha: []const u8,
    size: usize,
};

const ModelEntry = struct {
    name: []const u8,
    sha: []const u8,
    size: usize,
};

fn sha256Hex(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(input, &digest, .{});
    const hex = "0123456789abcdef";
    var out = try allocator.alloc(u8, 64);
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out;
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{ch}),
        else => try w.writeByte(ch),
    };
    try w.writeAll("\"");
}
