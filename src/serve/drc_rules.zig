//! Per-design DRC rule severities — the user's "what counts as an error"
//! settings. Each design may carry a `<design>.drc-rules.json` sidecar mapping
//! violation kinds to an overriding action (`err` / `warn` / `ignore`); the
//! overrides are applied at every violation producer (page blob, /api/pcb-drc,
//! /api/pcb-route, /api/pcb-describe, the fab-readiness gate), so the viewer,
//! the APIs, and the Gerber gate always agree on what is an error. Edited from
//! the viewer's DRC panel via GET/POST `/api/pcb-drc-rules/:name`.

const std = @import("std");
const httpz = @import("httpz");
const drc_compose = @import("../placement/drc_compose.zig");
const font = @import("../font5x7.zig");
const drc = @import("../placement/drc.zig");
const net_open = @import("../placement/net_open.zig");
const optimizer = @import("../placement/optimizer.zig");
const router = @import("../placement/router.zig");
const pour = @import("../placement/pour.zig");
const drc_json = @import("drc_json.zig");
const paths = @import("../paths.zig");
const infra_fs = @import("../infra/fs.zig");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;
const HandlerError = @import("pcb_layout_page.zig").HandlerError;

/// Serve-layer adapter for the placement compositor's fabricated-fill topology
/// pass. Route cleanup stays within the serve dependency boundary while using
/// the same component-honest oracle as full DRC.
pub const checkTopologyFilled = drc_compose.checkTopologyFilled;

/// The same adapter for the FULL geometry + topology check against that fill —
/// what a route gate must use once it has already credited the fill elsewhere
/// in its own chain (see `drc_compose.checkFilled`).
pub const checkFilled = drc_compose.checkFilled;

const rules_ext = ".drc-rules.json";
const kind_count = @typeInfo(drc.Kind).@"enum".field_names.len;

/// What a violation kind becomes under an override. `ignore` drops it
/// entirely; `err`/`warn` retag its severity.
pub const Action = enum { err, warn, ignore };

/// The per-design override map: one optional action per `drc.Kind`, `null`
/// meaning "keep the checker's built-in severity".
pub const Rules = struct {
    ov: [kind_count]?Action = @splat(null),

    fn isDefault(self: Rules) bool {
        for (self.ov) |o| if (o != null) return false;
        return true;
    }
};

/// The checker's built-in severity per kind — the `def` field the viewer's DRC
/// policy drawer shows beside each override.
///
/// This DELEGATES rather than tabulating. It used to be a hand-kept mirror of
/// the `severity = .warn` sites in `drc.zig`, and it drifted the moment
/// `diff_uncoupled` / `diff_skew` moved out into `drc_diffpair.zig`: the drawer
/// advertised them as fab errors while the checker emitted warnings. One table
/// (`drc.defaultSeverity`), which every producer also stamps its violations
/// from, is the fix — and the parity test below proves the two sides still
/// agree for every kind a fixture can trip.
fn defaultSeverity(k: drc.Kind) drc.Severity {
    return drc.defaultSeverity(k);
}

/// Apply `rules` to a violation list: drop `ignore`d kinds, retag the rest.
/// Returns the input slice untouched when no override is set (the common
/// case) or on allocation failure (reporting unfiltered beats reporting
/// nothing).
pub fn apply(alloc: std.mem.Allocator, rules: Rules, list: []const drc.Violation) []const drc.Violation {
    if (rules.isDefault()) return list;
    var out: std.ArrayList(drc.Violation) = .empty;
    for (list) |v| {
        const a = rules.ov[@backingInt(v.kind)] orelse {
            out.append(alloc, v) catch return list;
            continue;
        };
        if (a == .ignore) continue;
        var m = v;
        m.severity = if (a == .warn) .warn else .err;
        out.append(alloc, m) catch return list;
    }
    return out.items;
}

/// Load the design's override sidecar (default rules when absent/malformed).
pub fn load(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) Rules {
    var rules = Rules{};
    const path = paths.designSiblingPath(alloc, project_dir, name, rules_ext) catch return rules;
    defer alloc.free(path);
    const data = infra_fs.cwd().readFileAlloc(alloc, path, 1 << 16) catch return rules;
    _ = parseInto(&rules, alloc, data);
    return rules;
}

/// Run DRC and apply the design's overrides in one step — the wrapper every
/// serve-layer violation producer calls. This seam (NOT `drc.check`) is where
/// the `net_open` connectivity check joins the geometric rules: the router's
/// candidate loop and the client WASM engine call `drc.check` directly, so its
/// per-net pour raster only runs for the reporting surfaces, never in a hot path.
pub fn checkFiltered(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    placement: optimizer.Placement,
    r: router.RouteResult,
    clearance: f64,
) []const drc.Violation {
    return checkFilteredZones(alloc, project_dir, name, .{ .placement = placement, .routed = r, .clearance = clearance });
}

/// `checkFiltered` with hand-drawn user copper pours credited toward
/// connectivity: the `net_open` check counts a same-net pad/via inside a filled
/// user zone as connected copper, so the pour clears an airwire it electrically
/// closes. An empty `in.zones` is byte-identical to `checkFiltered`.
pub fn checkFilteredZones(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    in: CopperCheck,
) []const drc.Violation {
    const raw = drc_compose.checkDefaultRules(alloc, in);
    return apply(alloc, load(alloc, project_dir, name), raw);
}

/// The copper context one connectivity/geometry DRC pass measures, and the
/// composition that turns it into a violation list. Both DECLARED in
/// `placement/drc_compose.zig` — every input they read is a placement type, and
/// `kicad_pcb/route_command.zig` scores a board with them without wanting the
/// server — and re-exported here so the serve-layer callers are unchanged.
pub const CopperCheck = drc_compose.CopperCheck;
pub const checkDefaultRules = drc_compose.checkDefaultRules;

/// Parse a flat `{"<kind>":"<action>", …}` object into `rules`. Unknown kind
/// keys are skipped (forward compatibility); a non-object body or an invalid
/// action value fails the whole parse so a typo can't silently no-op.
fn parseInto(rules: *Rules, alloc: std.mem.Allocator, data: []const u8) bool {
    const root = std.json.parseFromSliceLeaky(std.json.Value, alloc, data, .{}) catch return false;
    if (root != .object) return false;
    var it = root.object.iterator();
    while (it.next()) |e| {
        const k = std.meta.stringToEnum(drc.Kind, e.key_ptr.*) orelse continue;
        if (e.value_ptr.* != .string) return false;
        const a = std.meta.stringToEnum(Action, e.value_ptr.*.string) orelse return false;
        rules.ov[@backingInt(k)] = a;
    }
    return true;
}

/// Serialize only the overrides — the sidecar file body.
fn writeRulesJson(w: *std.Io.Writer, rules: Rules) std.Io.Writer.Error!void {
    try w.writeByte('{');
    var first = true;
    inline for (@typeInfo(drc.Kind).@"enum".field_names, 0..) |f, i| {
        if (rules.ov[i]) |a| {
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("\"{s}\":\"{s}\"", .{ f, @tagName(a) });
        }
    }
    try w.writeByte('}');
}

/// The kinds table the viewer's settings menu renders: every kind with its
/// wire key, human label, built-in severity, and current override (or null).
pub fn writeKindsJson(w: *std.Io.Writer, rules: Rules) std.Io.Writer.Error!void {
    try w.writeByte('[');
    inline for (@typeInfo(drc.Kind).@"enum".field_names, @typeInfo(drc.Kind).@"enum".field_values, 0..) |fname, fval, i| {
        const k: drc.Kind = @fromBackingInt(@intCast(fval));
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"k\":\"{s}\",\"label\":\"{s}\",\"def\":\"{s}\",\"ov\":", .{
            fname, drc_json.kindStr(k), if (defaultSeverity(k) == .warn) "warn" else "err",
        });
        if (rules.ov[i]) |a| try w.print("\"{s}\"}}", .{@tagName(a)}) else try w.writeAll("null}");
    }
    try w.writeByte(']');
}

fn writeRulesResponse(w: *std.Io.Writer, rules: Rules) std.Io.Writer.Error!void {
    try w.writeAll("{\"ok\":true,\"kinds\":");
    try writeKindsJson(w, rules);
    try w.writeByte('}');
}

/// Write (or, when all-default, remove) the design's rules sidecar.
fn persist(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8, rules: Rules) !void {
    const path = try paths.designSiblingPath(alloc, project_dir, name, rules_ext);
    defer alloc.free(path);
    if (rules.isDefault()) {
        infra_fs.cwd().deleteFile(path) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
        return;
    }
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try writeRulesJson(&aw.writer, rules);
    try infra_fs.cwd().writeFile(.{ .sub_path = path, .data = aw.written() });
}

/// GET /api/pcb-drc-rules/:name — the current per-kind table.
pub fn getApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    var aw: std.Io.Writer.Allocating = .init(req.arena);
    try writeRulesResponse(&aw.writer, load(req.arena, ctx.project_dir, name));
    res.content_type = .JSON;
    res.body = aw.written();
}

/// POST /api/pcb-drc-rules/:name — replace the override map. Body is the flat
/// `{"<kind>":"err|warn|ignore", …}` object (empty object = back to defaults,
/// which deletes the sidecar).
pub fn setApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return;
    };
    var rules = Rules{};
    if (!parseInto(&rules, req.arena, body)) {
        res.status = 400;
        res.body = "malformed rules JSON";
        return;
    }
    persist(req.arena, ctx.project_dir, name, rules) catch {
        res.status = 500;
        res.body = "rules write failed";
        return;
    };
    var aw: std.Io.Writer.Allocating = .init(req.arena);
    try writeRulesResponse(&aw.writer, rules);
    res.content_type = .JSON;
    res.body = aw.written();
}

// spec: Web Server - Per-design DRC rule overrides retag or drop violations before every reporting surface
test "rules apply: ignore drops, warn retags, unset kinds keep built-in severity" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();
    var rules = Rules{};
    const vs = [_]drc.Violation{
        .{ .x = 0, .y = 0, .gap = 0, .clearance = 0, .kind = .silk_over_pad, .severity = .warn },
        .{ .x = 1, .y = 1, .gap = 0, .clearance = 0.25, .kind = .hole_hole },
        .{ .x = 2, .y = 2, .gap = 0, .clearance = 0.25, .kind = .track_pad },
    };
    // No overrides: the input slice comes back untouched (same pointer).
    try std.testing.expectEqual(@as(usize, 3), apply(alloc, rules, &vs).len);
    try std.testing.expect(parseInto(&rules, alloc, "{\"silk_over_pad\":\"ignore\",\"hole_hole\":\"warn\"}"));
    const out = apply(alloc, rules, &vs);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqual(drc.Kind.hole_hole, out[0].kind);
    try std.testing.expectEqual(drc.Severity.warn, out[0].severity);
    try std.testing.expectEqual(drc.Severity.err, out[1].severity); // untouched built-in
    // Bad action values fail the parse; unknown kinds are skipped.
    try std.testing.expect(!parseInto(&rules, alloc, "{\"silk_over_pad\":\"nope\"}"));
    try std.testing.expect(parseInto(&rules, alloc, "{\"not_a_kind\":\"err\"}"));
}

test "rules sidecar JSON round-trips and the kinds table carries defaults + overrides" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();
    var rules = Rules{};
    rules.ov[@backingInt(drc.Kind.silk_over_pad)] = .ignore;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try writeRulesJson(&aw.writer, rules);
    try std.testing.expectEqualStrings("{\"silk_over_pad\":\"ignore\"}", aw.written());
    var back = Rules{};
    try std.testing.expect(parseInto(&back, alloc, aw.written()));
    try std.testing.expectEqual(Action.ignore, back.ov[@backingInt(drc.Kind.silk_over_pad)].?);
    var kw: std.Io.Writer.Allocating = .init(alloc);
    defer kw.deinit();
    try writeKindsJson(&kw.writer, rules);
    const kinds = kw.written();
    const silk_row = "{\"k\":\"silk_over_pad\",\"label\":\"silkscreen overlap\",\"def\":\"warn\",\"ov\":\"ignore\"}";
    try std.testing.expect(std.mem.indexOf(u8, kinds, silk_row) != null);
    const hole_row = "{\"k\":\"hole_hole\",\"label\":\"hole↔hole\",\"def\":\"err\",\"ov\":null}";
    try std.testing.expect(std.mem.indexOf(u8, kinds, hole_row) != null);
}

// spec: placement/drc - flags board-level silkscreen text crossing a same-side component courtyard, as a warning
test "board text crossing a same-side component courtyard warns" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();
    var parts = [_]optimizer.Part{.{
        .ref_des = "U1",
        .kind = .hub,
        .x = 5,
        .y = 5,
        .hw = 1,
        .hh = 1,
        .pads = &.{},
        .fallback = false,
    }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = true,
    };
    const empty = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
    const texts = [_]font.BoardText{
        .{ .x = 5, .y = 5, .rot = 45, .size = 1, .text = "PART" },
        .{ .x = 5, .y = 5, .bottom = true, .size = 1, .text = "BOTTOM" },
        .{ .x = 9, .y = 9, .size = 1, .text = "CLEAR" },
    };
    const found = checkDefaultRules(alloc, .{ .placement = placement, .routed = empty, .clearance = 0.127, .texts = &texts });
    try std.testing.expectEqual(@as(usize, 1), drc.countKind(found, .silk_over_pad));
    try std.testing.expectEqual(drc.Severity.warn, found[0].severity);
    try std.testing.expectEqual(@as(i32, 0), found[0].who.part_a);
}

// spec: Web Server - The /pcb-layout viewer runs the WASM DRC in a worker with a server fallback
test "viewer JS wires the WASM DRC worker, server reconciliation, and the override mirror" {
    const js = @embedFile("assets/pcb_board.js");
    // The board script spins up the worker, coalesces fast local checks, and
    // reverts to the 800 ms server debounce when wasm can't init.
    try std.testing.expect(std.mem.indexOf(u8, js, "/static/drc_worker.js") != null);
    // The marshaling lives in its own asset, not inlined into the board script.
    try std.testing.expect(std.mem.indexOf(u8, js, "function buildDrcInput") == null);
    try std.testing.expect(std.mem.indexOf(u8, js, "buildDrcInput(PCB,") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "wasmDrc.failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function applyDrcOverrides") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "wasm/server mismatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "scheduleServerReconcile") != null);
    // The two new static assets carry their contract surface.
    const marshal = @embedFile("assets/drc_marshal.js");
    try std.testing.expect(std.mem.indexOf(u8, marshal, "function buildDrcInput") != null);
    try std.testing.expect(std.mem.indexOf(u8, marshal, "module.exports") != null);
    // Both generic perimeter regions and net-class keepout inputs must cross
    // the bridge or the client under-reports `keepout_violation` forever.
    try std.testing.expect(std.mem.indexOf(u8, marshal, "PCB.keepouts") != null);
    try std.testing.expect(std.mem.indexOf(u8, marshal, "keepout_mm") != null);
    try std.testing.expect(std.mem.indexOf(u8, marshal, "keepout_escape_mm") != null);
    try std.testing.expect(std.mem.indexOf(u8, marshal, "pad_neck_width") != null);
    try std.testing.expect(std.mem.indexOf(u8, marshal, "pad_neck_max_length") != null);
    try std.testing.expect(std.mem.indexOf(u8, marshal, "pad_neck_taper_length") != null);
    try std.testing.expect(std.mem.indexOf(u8, marshal, "impedance_ohms") != null);
    try std.testing.expect(std.mem.indexOf(u8, marshal, "PCB.plane_nets") != null);
    const worker = @embedFile("assets/drc_worker.js");
    try std.testing.expect(std.mem.indexOf(u8, worker, "drc_check") != null);
    try std.testing.expect(std.mem.indexOf(u8, worker, "drc_output_ptr") != null);
}

// spec: Web Server - Net-open DRC findings remain in the sidebar and counts but do not draw or hit-test as PCB markers
test "viewer keeps net-open findings off the board while retaining the DRC list" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "function drcOnBoard(d){return !!d&&d.k!==\"net open\";}") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "forEach(function(d){if(!drcOnBoard(d))return;var cx=X(d.x)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function renderDrcList(){drcTabBadge();var lst=ensureDrcList();if(!lst)return;") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "var v=PCB.drc||[];") != null);
}

// spec: Web Server - PCB drag/drop keeps full-board work and retained-overlay rebuilds off the interactive path
test "viewer scopes commit DRC and retains drag-time work across frames" {
    const js = @embedFile("assets/pcb_board.js");
    // The synchronous commit gate compares the same base/after result
    // multisets, but each engine call receives only the changed neighbourhood.
    try std.testing.expect(std.mem.indexOf(u8, js, "function drcGateScope(") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "drcGateRun(scope.bt,scope.bv,scope.parts)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "drcGateRun(scope.at,scope.av,scope.parts)") != null);
    // Worker/session consumers share one full-board serialization generation,
    // while session refill waits for idle or an explicit copper gesture.
    try std.testing.expect(std.mem.indexOf(u8, js, "function drcInputJson()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "requestIdleCallback(run,{timeout:1000})") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function drcGateSessionEnsure()") != null);
    // Server-only connectivity rows survive the local geometry refresh, which
    // lets unchanged id sets suppress both marker/list DOM rebuilds.
    try std.testing.expect(std.mem.indexOf(u8, js, "if(d.k===\"net open\")list.push(d)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(changed)drawDrc()") != null);
    // Connectivity, loop overlays, and the GPU adornment layer are retained
    // incrementally instead of being rebuilt on every drag frame/drop.
    try std.testing.expect(std.mem.indexOf(u8, js, "linkConnCache[net].sig!==sig") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function loopViaPatch(") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "gpuDragCache={cv:oc,key:key}") != null);
}

// spec: Web Server - Board text and generated annotations live on their physical F./B.Silkscreen layers without an extra Appearance row or per-hover geometry rebuild
test "viewer puts board text and annotations on side-specific silk layers" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "refdes:0") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "TECH.forEach(function(_T){viewSt.vis[_T.key]=1;});") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "{key:LN.f_silks,name:LN.f_silks") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "{key:\"board_silk\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, js, "Text & annotations") == null);
    try std.testing.expect(std.mem.indexOf(u8, js, "Reference designators") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "viewSt.vis.refdes&&") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "viewSt.vis.board_silk") == null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function silkVisible(side){return !!viewSt.vis[side===\"bottom\"?LN.b_silks:LN.f_silks];}") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(!silkVisible(q.side))continue;") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(!silkVisible(tp.side))continue;") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(!silkVisible(t.side))continue;") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "boardSilkHitRev===ovsRev&&boardSilkHitOutline===outlineGeomRev") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "var all=txDrag?boardSilkAllGeom():((!movG&&!mov)?boardSilkCurrentGeom():boardSilkDragGeom(movG,mov));") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function boardSilkDragGeom") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "var movOb=subSilkObstaclesRange(o.movSet);") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function paintSubcircuitSilk") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function subSilkBoardFit") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function subSilkClear") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function subSilkClipSeg") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "q.segs=q.segs.concat(subSilkClipSeg") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "q.label=overrides[q.g]?null:subSilkPlace(q,used,pads,keepouts)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function subSilkAssignArt") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function subSilkSnapEdges") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function subSilkShiftClearKeepouts") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "segs=q.labelArt||subSilkRawSegments(q)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "var b=wrect(i,pp[pi])") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "rot:0,size:SUB_SILK_MAX,text:q.g") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function subSilkPlaceInside") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function subSilkPlaceNearby") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "SUB_SILK_LABEL_OFFSET=1") != null);
    // The four L-shaped corner brackets sit 0.2 mm inside the annotation box
    // (matching the fabrication writer's corner inset), and inline names keep
    // their 0.15 mm air gap from the inset arms.
    try std.testing.expect(std.mem.indexOf(u8, js, "SUB_SILK_CORNER_INSET=0.2") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function subSilkRawSegments(q){var d=SUB_SILK_CORNER_INSET") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "SUB_SILK_GAP+SUB_SILK_CORNER_INSET+extent/2") != null);
    // Hit boxes and generated-label placement mirror the fabricated stroke
    // font's cap and per-glyph proportional advances, from the same table.
    try std.testing.expect(std.mem.indexOf(u8, js, "SILK_CAP=21,SILK_EM=SILK_CAP/0.9") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "/*silk-font-table*/") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function silkTextWidth(text,size)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function silkStrokeText(ctx,text,size,col)") != null);
    // Rounded outlines are tessellated once per outline revision. Generated
    // silk then performs threshold-only squared edge checks instead of a sqrt
    // against every tessellated chord for every sampled ink point.
    try std.testing.expect(std.mem.indexOf(u8, js, "function outlineGeomDrop()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "outlineFilletCache&&outlineFilletCache.o===o") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function polyEdgeWithin(") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "polyEdgeWithin(shape.pts") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "subSilkNearby") == null);
}

// spec: Web Server - PCB edits autosave after idle and retain crash drafts until that save succeeds
test "viewer autosaves dirty PCB layouts without clearing newer crash drafts" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "function scheduleAutosave(ms)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(draftGestureLive()){scheduleAutosave(500);return;}") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "requestIdleCallback(run,{timeout:1000})") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "persistLayout(nm,\"autosaving\",true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(dirtyGeneration===saveGeneration)clearDirty()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "setActiveLayout(nm);syncLayoutUrl(nm);clearDirty()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "saveQueue=task.then") != null);
}

// Autosave removes the manual Save click that used to defocus dock fields.
// A board gesture must reclaim keyboard focus, and undo must be captured before
// a nested panel can consume Ctrl+Z, while text fields retain native undo.
test "viewer keeps PCB undo reachable after autosave" {
    const js = @embedFile("assets/pcb_board.js");
    const capture_undo =
        "window.addEventListener(\"keydown\",function(ev){if(!(ev.ctrlKey||ev.metaKey)||kbTyping(ev.target))return;";
    try std.testing.expect(std.mem.indexOf(u8, js, "function focusBoardShortcuts()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "focusBoardShortcuts();ev.preventDefault()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, capture_undo) != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "doRedo();}},true);") != null);
}

// spec: Web Server - PCB Layers shows plane-only rows and B toggles the persisted focused outer layer
test "viewer exposes the physical stack and a persistent B-key active side" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "var STACK=LT.map(function(r){") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "'<div class=\"ap-h\">Layers · '+STACK.length+' copper</div>'") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "viewSt.active=activeLayer;viewSt.stack=activeStack;viewSave()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "data-ap-stack") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "add(PCB.plane_fills,\"plane\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "ev.key===\"b\"||ev.key===\"B\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "layer!==focus") != null);
}

// spec: Web Server - the /pcb-layout action toolbar carries a first-class pour-refill button gated to designs that declare outer-layer copper pours
test "toolbar exposes a pour-refill button gated on declared pours" {
    const js = @embedFile("assets/pcb_board.js");
    const page = @embedFile("pcb_layout_page.zig");
    // The button ships in the action toolbar, and the blob emits the declared
    // flag the client reads to hide it when no outer pour is declared.
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\\\"pcb-pour\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, page, "pours_declared") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "PCB.pours_declared") != null);
}

// spec: Web Server - the toolbar pour button flags a stale indicator after board edits and disables during replay
test "toolbar pour button tracks staleness and gates under replay" {
    const js = @embedFile("assets/pcb_board.js");
    const replay = @embedFile("assets/pcb_replay.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "function markPoursStale") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "PCB.poursStale") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function poursFresh") != null);
    try std.testing.expect(std.mem.indexOf(u8, replay, "pcb-pour") != null);
}

// spec: Web Server - the /pcb-layout toolbar carries a custom copper-pour tool that draws a polygon zone, picks its net and layer, persists it with the layout, and refills its fill
test "toolbar exposes a custom copper-pour drawing tool wired to zones" {
    const js = @embedFile("assets/pcb_board.js");
    const page = @embedFile("pcb_layout_page.zig");
    // The pour-draw button ships in BOTH toolbars (distinct id from the ⟳ refill
    // button #pcb-pour) and the viewer wires the polygon tool, the net/layer
    // dialog, deletion, and zone persistence.
    try std.testing.expect(std.mem.indexOf(u8, page, "id=\\\"pcb-pour-zone\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function pourArm") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function openPourDialog") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function createZone") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function pourDeleteAt") != null);
    // The refill body and the save payload both carry the live zones, and the
    // refill response's zone_fills replaces the client's carved-fill cache.
    try std.testing.expect(std.mem.indexOf(u8, js, "PCB.zone_fills=j.zone_fills") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "zones:PCB.zones") != null);
}

// spec: Web Server - A new copper pour defaults to the active copper layer and its picker lists every routable layer
test "pour dialog defaults to the active layer and offers the whole stack" {
    const js = @embedFile("assets/pcb_board.js");
    // A new pour takes the ACTIVE layer's real name; the old outer-face guess
    // silently dropped a pour drawn while an inner layer was active onto F.Cu.
    try std.testing.expect(std.mem.indexOf(u8, js, "var defLayer=existing?(existing.layer||LN.f_cu):layerName(activeLayer);") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "activeLayer===1)?\"B.Cu\"") == null);
    // The picker is built from the board's own layer table, and still keeps any
    // extra layer an existing zone names (an imported In3.Cu / F&B.Cu pour).
    try std.testing.expect(std.mem.indexOf(u8, js, "var lopts=LYR.map(function(L){return L.name;});") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(z.layer&&lopts.indexOf(z.layer)<0)lopts.push(z.layer);") != null);
}

// spec: Web Server - selecting a routable copper layer reveals it and gives custom pour fills on that active layer a clear baseline highlight
test "active custom copper pours remain visible on selected inner layers" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "viewSt.vis[visKey(nl)]=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "activeUserFill=reviewAreaFocused(q)&&typeof q.zone===\"number\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "activeUserFill?0.36") != null);
}

// spec: Web Server - The PCB Route request always carries the current custom copper pours so the autorouter can terminate pour nets through vias
test "viewer sends custom copper pours with the whole-board route" {
    const js = @embedFile("assets/pcb_board.js");
    const payload_start = std.mem.indexOf(u8, js, "var payload={parts:") orelse
        return error.TestRoutePayloadMissing;
    const payload_tail = js[payload_start..];
    const payload_end = std.mem.indexOf(u8, payload_tail, "var applyOpts=") orelse
        return error.TestRoutePayloadEndMissing;
    const payload = payload_tail[0..payload_end];

    // `zones` belongs to the unconditional whole-board payload, so the routine
    // Route-board action always seeds the maze from custom/inner-layer pours.
    try std.testing.expect(std.mem.indexOf(u8, payload, "zones:PCB.zones||[]") != null);
}

// spec: Web Server - The route_pcb CLI tool counts DRC against the shown custom pours through the direct pour-aware checker result
test "route_pcb uses the direct pour-aware DRC result" {
    const page = @embedFile("pcb_layout_page.zig");
    const fn_start = std.mem.indexOf(u8, page, "pub fn mcpRoutePcb(") orelse
        return error.TestRoutePcbMissing;
    const tail = page[fn_start..];
    const fn_end = std.mem.indexOf(u8, tail, "pub fn mcpSavePcbLayout(") orelse
        return error.TestRoutePcbEndMissing;
    const body = tail[0..fn_end];
    const check_start = std.mem.indexOf(u8, body, "const v = drc_rules.checkFilteredZones(") orelse
        return error.TestPourAwareDrcMissing;
    const check_tail = body[check_start..];
    const assignment = std.mem.indexOf(u8, check_tail, "route_findings = v;") orelse
        return error.TestDrcCountMissing;
    const check = check_tail[0..assignment];
    try std.testing.expect(std.mem.indexOf(u8, check, ".zones = solved.shown_zones.user") != null);
    // `checkFilteredZones` returns a slice directly. Reintroducing an
    // error-union `catch` here breaks the ReleaseSafe server build.
    try std.testing.expect(std.mem.indexOf(u8, check, "catch") == null);
}

// spec: Web Server - The /pcb-layout Properties dock hosts the inspector with segment editing and DRC rule settings
test "viewer JS wires the docked inspector, segment editing, and the DRC rules menu" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "function renderInspProps") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "segdrag") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "/api/pcb-drc-rules/") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "drc-cog") != null);
}

/// Substrings that prove the settings drawer's DRC policy section can edit
/// every check: the three action labels plus a `DRC_HELP` entry per
/// `drc.Kind`. Built from the enum itself, so adding a kind fails the test
/// until the drawer can explain it.
///
/// The per-kind needle is the help entry (`<kind>:"`), not a quoted id, because
/// the drawer's SECTIONING is no longer spelled in that file at all: it arrives
/// as `PCB.drc_groups` from `drc_json.drawer_groups`, whose comptime block
/// already refuses to build a kind that belongs to no section. What is left
/// worth asserting on the client side is that every kind still ships prose.
const drc_policy_required = blk: {
    const actions = [_][]const u8{ "\"err\",\"Error\"", "\"warn\",\"Warning\"", "\"ignore\",\"Ignored\"" };
    var list: [actions.len + kind_count][]const u8 = undefined;
    for (actions, 0..) |a, i| list[i] = a;
    for (@typeInfo(drc.Kind).@"enum".field_names, 0..) |f, i| list[actions.len + i] = f ++ ":\"";
    break :blk list;
};

// spec: Web Server - The DRC policy settings section edits each check's error, warning, or ignored action in grouped rows and resets them to defaults
test "settings drawer DRC policy edits every kind and syncs the board view" {
    const js = @embedFile("assets/pcb_settings.js");
    // The section is editable: a three-way action control per kind that POSTs
    // the override map, plus the reset-to-defaults escape hatch.
    try std.testing.expect(std.mem.indexOf(u8, js, "data-ds-drc=") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "/api/pcb-drc-rules/") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function wireDrcPolicy") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "ds-drc-reset") != null);
    // A read-only layout cannot edit the policy from here.
    try std.testing.expect(std.mem.indexOf(u8, js, "PCB.ro?\" disabled\":\"\"") != null);
    // The ungrouped catch-all keeps a newly added kind editable even before it
    // has been sorted into a group.
    try std.testing.expect(std.mem.indexOf(u8, js, "Other checks") != null);
    // Saving hands the server's table back to the board so the Route panel cog
    // menu and the on-board markers re-judge without a reload.
    try std.testing.expect(std.mem.indexOf(u8, js, "window.PCBDrcRulesApply") != null);
    const board = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, board, "window.PCBDrcRulesApply=function") != null);
    try std.testing.expect(std.mem.indexOf(u8, board, "drcRefreshNow();};") != null);
    for (drc_policy_required) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, js, needle) != null);
    }
}

// spec: Web Server - Segment drags preserve neighbouring trace support lines: compatible neighbours only stretch or shrink, while collinear runs, arcs, and ambiguous junctions remain anchored behind a connector
test "viewer JS slides segments KiCad-style without repositioning neighbouring traces" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "function segPlan") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"corner\"") != null);
    // A serialized route can have multiple same-line segments at one visual
    // corner. They all receive the resolved intersection; only their joined
    // endpoints move, so their fixed endpoints/supporting lines cannot drift.
    try std.testing.expect(std.mem.indexOf(u8, js, "trs.forEach(function(w)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "segFollow(pl.at,cx,cy); // far ends and every supporting line remain fixed") != null);
    // Branches, arcs, bare ends and collinear runs are not rigid-translated as
    // a fallback. Their existing node stays put and a removable bridge is laid.
    try std.testing.expect(std.mem.indexOf(u8, js, "return {mode:\"anchor\",sx:x,sy:y,jog:null,at:at};") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "return {mode:\"free\",at:at};") == null);
    // Free node movement remains available only as the explicit Shift path.
    try std.testing.expect(std.mem.indexOf(u8, js, "if(free){if(pl.jog)segJogDrop(pl);segFollow(pl.at,ax,ay);") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "segJogClean") != null);
}

// spec: Web Server - The hand-route head dodges or clips at clearance obstacles instead of drawing violating copper
test "viewer JS pushes the route head back: posture dodge then clearance clip" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "function clipLegs") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "dodged:true") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "clipped:true") != null);
}

// spec: Web Server - Moving a placed component leaves its connected traces in place instead of deleting them
test "viewer JS keeps copper on a part move: drag marks connectivity, does not clear the net" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "function anyCopper") != null);
    // The single-part drag path marks connectivity dirty instead of clearing.
    try std.testing.expect(std.mem.indexOf(u8, js, "copperTouched();}ratsUpdate([di])") != null);
}

// spec: Web Server - Dragging or rotating a marquee selection carries the tracks and vias the band caught
test "viewer JS moves marquee-selected copper with the parts it was banded with" {
    const js = @embedFile("assets/pcb_board.js");
    // A marquee drag seeds its carried copper from the band (a rigid-group drag
    // seeds from the group tag); both add the private-net copper below.
    try std.testing.expect(std.mem.indexOf(u8, js, "var cu=carriedCopper(mv,g,!g);") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, " if(g)add(grpCopper(g));\n if(banded)add(selCuCopper());") != null);
    // Pressing a selected part with copper in the band drags the whole set.
    try std.testing.expect(std.mem.indexOf(u8, js, "if(sel.indexOf(hi)>=0&&(sel.length>1||selCuCount())){gdrag=gdragStart(m,hi);") != null);
    // Both are translated by the same grid-snapped delta, gated on the delta
    // itself so a copper-only selection still travels.
    try std.testing.expect(std.mem.indexOf(u8, js, "if(gdx===gdrag.adx&&gdy===gdrag.ady)return;") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "gdrag.ct.forEach(function(o){o.t.x1=o.x1+gdx;") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "gdrag.cv.forEach(function(o){o.v.x=o.x+gdx;") != null);
    // R rotates the same carried copper, mid-drag and from a plain selection.
    try std.testing.expect(std.mem.indexOf(u8, js, "rotateGroup(sel,rsign,null,false,carriedCopper(") != null);
    // The banded objects are alive, not ripped up: a move re-selects them after
    // copperTouched drops the refs, so a second gesture carries them too.
    try std.testing.expect(std.mem.indexOf(u8, js, "function copperMoved(){var band=selCuCopper();copperTouched();") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(band.t.length||band.v.length)selCuTo(band.t,band.v);") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "gdrag.moved=true;copperMoved();") != null);
}

// spec: Web Server - Ctrl/Cmd-click toggles footprints, rigid sub-circuits, tracks, and vias into one multi-selection without a marquee drag
test "viewer JS toggles PCB items into the shared selection with a modifier click" {
    const js = @embedFile("assets/pcb_board.js");
    const markers = [_][]const u8{
        "function selectionMod(ev){return !!(ev&&(ev.ctrlKey||ev.metaKey));}",
        "function selectionToggleParts(idxs)",
        "if(all)next=next.filter(function(i){return idxs.indexOf(i)<0;});",
        "selectionToggleParts(GRPS[cg])",
        "selectionToggleParts(GRPS[gh])",
        "function selectionToggleCopper(hit)",
        "var arr=hit.t===\"track\"?ts:vs,at=arr.indexOf(hit.o);",
        "selectionCommit(seed)",
        "selectionToggleAt(ev,m);return;",
        "Ctrl / Cmd + click",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, js, marker) != null);

    // Modifier dispatch precedes both selected-copper and footprint drag
    // dispatch, so toggling an existing member cannot accidentally move it.
    const modifier = std.mem.indexOf(u8, js, "selectionToggleAt(ev,m);return;").?;
    const copper_drag = std.mem.indexOfPos(u8, js, modifier, "var selectedHit=selectedCopperHit(m);").?;
    const part_drag = std.mem.indexOfPos(u8, js, modifier, "if(sel.indexOf(hi)>=0").?;
    try std.testing.expect(modifier < copper_drag);
    try std.testing.expect(modifier < part_drag);
}

// spec: Web Server - Holding Ctrl/Cmd after an ordinary first click retains that part, sub-circuit, track, or via when the next item joins the multi-selection
test "viewer JS promotes the initial plain selection when modifier clicking another PCB item" {
    const js = @embedFile("assets/pcb_board.js");
    const markers = [_][]const u8{
        "function selectionSeed(){var ps=sel.slice(),ts=selCu.t.slice(),vs=selCu.v.slice();",
        "if(selRef){var pi=P.findIndex(function(p){return p.ref===selRef;});",
        "else if(selGroup&&GRPS[selGroup])GRPS[selGroup].forEach",
        "if(insp&&insp.t===\"track\"&&ts.indexOf(insp.o)<0)ts.push(insp.o);",
        "if(insp&&insp.t===\"via\"&&vs.indexOf(insp.o)<0)vs.push(insp.o);",
        "function selectionToggleParts(idxs){var seed=selectionSeed()",
        "function selectionToggleCopper(hit){var seed=selectionSeed()",
        "function selectionCommit(seed){inspClear();clearSel();selSet(seed.p);selCuTo(seed.t,seed.v);",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, js, marker) != null);
}

// spec: Web Server - Two selected connected trace segments expose a right-click Fillet command that applies an exact native-arc radius through the normal copper edit gates
test "viewer JS fillets two selected trace segments from the context menu" {
    const js = @embedFile("assets/pcb_board.js");
    const markers = [_][]const u8{
        "function traceFilletContext(t1,t2)",
        "function traceFilletPlan(t1,t2,radius)",
        "if(radius>c.maxRadius+1e-9)",
        "xm:cx+radius*Math.cos(am),ym:cy+radius*Math.sin(am)",
        "window.PCBTraceFilletPlan=traceFilletPlan",
        "function traceFilletSelectionReady(){return selCu.t.length===2&&!selCu.v.length&&!sel.length;}",
        "traceFilletMenuOpen(ev);return;",
        "<b>Fillet…</b>",
        "name=\"radius\" type=\"number\"",
        "drcGateDiffBlocks(base,PCB.vias||[],after,PCB.vias||[])",
        "recordUndo(snap);rfDropForTracks(pair);PCB.tracks=after;copperTouched();",
        "fillet applied · R",
        "if(ev.button===2)return; // context-menu commands own secondary clicks",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, js, marker) != null);

    const context_menu = std.mem.indexOf(u8, js, "traceFilletMenuOpen(ev);return;").?;
    const draw_delete = std.mem.indexOfPos(u8, js, context_menu, "if(!drawMode)return;").?;
    try std.testing.expect(context_menu < draw_delete);
}

// spec: Web Server - Align, distribute, and pad-align carry each entity's own copper by that entity's own delta
test "viewer JS panel moves carry per-entity copper and never shift one object twice" {
    const js = @embedFile("assets/pcb_board.js");
    // Align/distribute compute a per-entity delta list, then one mover applies
    // poses + carried copper together — no caller translates copper by hand.
    try std.testing.expect(std.mem.indexOf(u8, js, "function moveEntities(ents,deltas,banded)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "commitMove(moveEntities(ents,deltas));") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "var cu=carriedCopper(e.idxs,e.g,false),t=[],v=[],z=[];") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "shiftCopper({t:t,v:v,z:z},d.dx,d.dy);") != null);
    // An entity knows its group, so its stamped copper rides with it.
    try std.testing.expect(std.mem.indexOf(u8, js, "if(idxs.length)ents.push({idxs:idxs,g:key});") != null);
    // One claim set spans the operation: two entities cannot both shift an
    // object, so nothing ever travels twice in a single align/distribute.
    try std.testing.expect(std.mem.indexOf(u8, js, "var claimed=new Set(),moved=[],ncu=0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "cu.t.forEach(function(o){if(!claimed.has(o)){claimed.add(o);t.push(o);}});") != null);
    // The pad-align tool goes through the same mover instead of its old
    // group-tag-only hand-rolled translation.
    try std.testing.expect(std.mem.indexOf(u8, js, "var moved=moveEntities([{idxs:owner.idxs,g:owner.g}],[{dx:dx,dy:dy}]);") != null);
    const pa_start = std.mem.indexOf(u8, js, "function padAlignApply(axis)") orelse return error.TestPadAlignMissing;
    const pa_tail = js[pa_start..];
    const pa_end = std.mem.indexOf(u8, pa_tail, "var padAlignBtn") orelse return error.TestPadAlignEndMissing;
    try std.testing.expect(std.mem.indexOf(u8, pa_tail[0..pa_end], "t.g===owner.g") == null);
}

// spec: Web Server - Restamping a sub-circuit preserves its anchor's board side and rigidly mirrors its parts and stamped copper onto that side
test "viewer JS restamps a sub-circuit around its live side and rotation" {
    const js = @embedFile("assets/pcb_board.js");
    const start = std.mem.indexOf(u8, js, "function stampGroup(g)") orelse
        return error.TestStampGroupMissing;
    const tail = js[start..];
    const end = std.mem.indexOf(u8, tail, "stampGroupFn=stampGroup;") orelse
        return error.TestStampGroupEndMissing;
    const body = tail[0..end];

    // The live anchor pose composes with the inverse module-anchor pose. This
    // makes that anchor invariant while carrying every other member through
    // the same rotation/mirror transform.
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "stampPoseCompose(stampPoseOf(P[anc.i]),stampPoseInverse(stampPoseOf(anc.sd)))",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "P[i].side=np.back?\"bottom\":\"top\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "P[i].side=h.sd.side||\"top\"") == null);

    // Stamped copper uses the identical transform; a mirror also swaps the two
    // outer copper layers so bottom-side parts do not retain top-side tracks.
    try std.testing.expect(std.mem.indexOf(u8, body, "stampPoseApply(xf,t.x1,t.y1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "stampPoseApply(xf,v.x,v.y)") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "stampPoseApply(xf,+p[0],+p[1])") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "stampLayer(t.l||0,xf.back)") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "stampZoneLayer(z.layer,xf.back)") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "PCB.zones=(PCB.zones||[]).filter(function(z){return z.g!==g;});") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "filled:true,keepout:false,priority:+z.priority||0,g:g") != null);
    // The ownership tag persists and makes later rigid translations/rotations
    // carry the stamped pour with the rest of the module copper.
    try std.testing.expect(std.mem.indexOf(u8, js, "z:(PCB.zones||[]).filter(function(z){return z.g===g;})") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "gdrag.cz.forEach(function(o){o.z.poly=o.poly.map") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "(cop.z||[]).forEach(function(z){z.poly=") != null);
}

// spec: Web Server - Stamp fetches the current module layout when clicked, so a sub-circuit edit in another tab applies without reloading a board and without discarding its unsaved work
test "viewer JS refreshes sub-circuit seeds before every stamp" {
    const js = @embedFile("assets/pcb_board.js");
    const start = std.mem.indexOf(u8, js, "function stampGroup(g)") orelse
        return error.TestStampGroupMissing;
    const tail = js[start..];
    const end = std.mem.indexOf(u8, tail, "stampGroupFn=stampGroup;") orelse
        return error.TestStampGroupEndMissing;
    const body = tail[0..end];
    const refresh = std.mem.indexOf(u8, body, "refreshStampSeeds(g)") orelse
        return error.TestStampRefreshMissing;
    const seeds = std.mem.indexOf(u8, body, "stampSeedFor(g,P[i])") orelse
        return error.TestStampStableSeedsMissing;

    try std.testing.expect(refresh < seeds);
    try std.testing.expect(std.mem.indexOf(u8, js, "fetch(\"/api/pcb-subseeds/\"+encodeURIComponent(PCB.name),{cache:\"no-store\"})") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "PCB.subseeds=j.subseeds||{}") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "PCB.subseedorigins=j.subseedorigins||{}") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "(p.origin&&stableSeeds[p.origin])||(PCB.subseeds||{})[p.ref]") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "PCB.subroutes=j.subroutes||{}") != null);
}

// spec: Web Server - A live Stamp refresh keeps every stampable sub-circuit's palette action visible when the fresh grid placement uses different ref-des assignments from the open board
test "sub-circuit palette tests refreshed seeds through stable origins" {
    const js = @embedFile("assets/pcb_board.js");
    const start = std.mem.indexOf(u8, js, "function subPanelRefresh()") orelse
        return error.TestSubPanelRefreshMissing;
    const tail = js[start..];
    const end = std.mem.indexOf(u8, tail, "subPanelRefresh();})();") orelse
        return error.TestSubPanelRefreshEndMissing;
    const body = tail[0..end];

    try std.testing.expect(std.mem.indexOf(u8, body, "stampSeedFor(g,P[i])") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "seeds[P[i].ref]") == null);
}

// spec: Web Server - A multi-part drag or rotate carries copper on nets private to the moving parts and leaves shared-net copper in place
test "viewer JS carries private-net copper with a multi-part move and strands nothing shared" {
    const js = @embedFile("assets/pcb_board.js");
    // Private = every pad of the net belongs to the moving set. The tallies are
    // per net over ALL parts vs. the movers, and equality is the test.
    try std.testing.expect(std.mem.indexOf(u8, js, "function privateNets(idxs)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "all[pd.net]=(all[pd.net]||0)+1;if(mv[i])mine[pd.net]=(mine[pd.net]||0)+1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "for(var k in mine)if(mine[k]===all[k])") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "return {t:(PCB.tracks||[]).filter(function(t){return t.net&&priv[t.net];})") != null);
    // Locked members never move, so they are excluded from the moving set —
    // their nets stay shared and their copper stays put.
    try std.testing.expect(std.mem.indexOf(u8, js, "var mv=src.filter(function(k){return !P[k].locked;});") != null);
    // Every multi-part gesture takes the union: group tag, band, private nets.
    try std.testing.expect(std.mem.indexOf(u8, js, "function carriedCopper(idxs,g,banded)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "add(privateCopper(idxs));") != null);
    // …deduped, so one object is never translated twice in a gesture.
    try std.testing.expect(std.mem.indexOf(u8, js, "cu.t.forEach(function(o){if(!seen.has(o)){seen.add(o);t.push(o);}});") != null);
}

// spec: Web Server - The PCB editor rotates components, rigid groups, and their carried copper in 45-degree increments
test "viewer JS offers and applies 45-degree component rotations" {
    const js = @embedFile("assets/pcb_board.js");
    const markers = [_][]const u8{
        "[\"45\",\"45°\"]",
        "[\"135\",\"135°\"]",
        "(sign>0?45:-45)*Math.PI/180",
        "(sign>0?45:-45))%360",
        "var tx=Math.round(rix/G)*G-rix,ty=Math.round(riy/G)*G-riy;",
        "P[i].x=cx+dx*dc-dy*ds+tx;P[i].y=cy+dx*ds+dy*dc+ty;",
        "Rotate selected group / component +45°",
        "Rotate selected group / component −45°",
        "var a=stampPoseNorm(p.rot)*Math.PI/180,c=Math.cos(a),s=Math.sin(a);",
    };
    for (markers) |marker| try std.testing.expect(std.mem.indexOf(u8, js, marker) != null);
    // The stale quarter-turn-only transforms must not return: both group
    // copper and Stamp use the same sin/cos matrix as individual footprints.
    try std.testing.expect(std.mem.indexOf(u8, js, "sign>0?90:-90") == null);
    try std.testing.expect(std.mem.indexOf(u8, js, "switch(stampPoseNorm(p.rot))") == null);
}

// The same explicit-selection priority also applies to an individually
// inspected via or track when a footprint courtyard overlaps it.
// spec: Web Server - A press on marquee-selected copper drags the whole selection instead of sliding that one segment
test "viewer JS gives selected copper drag priority over overlapping footprints" {
    const js = @embedFile("assets/pcb_board.js");
    // The current inspector selection is checked first; a selected via/track
    // must itself be under the press, so selecting copper does not monopolize
    // unrelated clicks elsewhere on the board.
    try std.testing.expect(std.mem.indexOf(u8, js, "function selectedCopperHit(m)") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        js,
        "if(insp&&insp.t===\"via\"&&viaHit(insp.o))return insp;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        js,
        "if(insp&&insp.t===\"track\"&&trackHit(insp.o))return insp;",
    ) != null);
    // Marquee-selected copper keeps press-a-member-move-the-set semantics, and
    // a stationary press still inspects the member rather than swallowing it.
    try std.testing.expect(std.mem.indexOf(
        u8,
        js,
        "if(selCuHas(selectedHit.o)&&(selCuCount()+sel.length)>1){",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        js,
        "gdrag=gdragStart(m,null);gdrag.cuDown=selectedHit;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "else if(gcu)inspShow(gcu,ev);") != null);
    // Crucially, dispatch happens before footprint/courtyard hit-testing.
    const selected_drag = std.mem.indexOf(u8, js, "var selectedHit=selectedCopperHit(m);").?;
    const part_hit = std.mem.indexOfPos(u8, js, selected_drag, "partAt(m.x,m.y)").?;
    try std.testing.expect(selected_drag < part_hit);
    try std.testing.expect(std.mem.indexOfPos(
        u8,
        js,
        selected_drag,
        "segdrag=segStart(selectedHit.o,m);",
    ).? < part_hit);
    try std.testing.expect(std.mem.indexOfPos(
        u8,
        js,
        selected_drag,
        "viadrag=viaStart(selectedHit.o,m);",
    ).? < part_hit);
}

// Regression guard for hierarchical rigid-group selection and non-destructive
// copper handling during group rotation.
test "viewer JS selects rigid sub-circuits before their components and preserves copper on rotate" {
    const js = @embedFile("assets/pcb_board.js");

    // Selection has an explicit group scope. A first click enters it, while an
    // already-active group falls through to selectComp for the drill-in click.
    try std.testing.expect(std.mem.indexOf(u8, js, "var selRef=null,selGroup=null") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(!RO&&viewSt.filt.sub&&cg&&grpRigid(cg))") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(selGroup!==cg)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(selGroup&&!selRef)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(selRef===P[hi].ref){drag=") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function grpAt(wx,wy)") != null);

    // Guard the rotation body itself: stamped group-tagged tracks/vias are
    // transformed, but no net-clearing call may remove untagged board copper.
    const rotate_start = std.mem.indexOf(u8, js, "function rotateGroup(") orelse return error.TestRotateGroupMissing;
    const rotate_tail = js[rotate_start..];
    const rotate_end = std.mem.indexOf(u8, rotate_tail, "function rotatePart(") orelse
        return error.TestRotatePartMissing;
    const rotate_body = rotate_tail[0..rotate_end];
    // The transform runs over the carried-copper list only — group-tagged
    // copper when a group rotates, the caller's explicit set otherwise.
    try std.testing.expect(std.mem.indexOf(u8, rotate_body, "var cop=cu||(keepG?grpCopper(keepG):null)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rotate_body, "cop.t.forEach") != null);
    try std.testing.expect(std.mem.indexOf(u8, rotate_body, "cop.v.forEach") != null);
    try std.testing.expect(std.mem.indexOf(u8, rotate_body, "(cop.z||[]).forEach") != null);
    try std.testing.expect(std.mem.indexOf(u8, rotate_body, "clearRouteFor") == null);
    try std.testing.expect(std.mem.indexOf(u8, rotate_body, "scheduleDrc()") != null);
    // …and that list is tag-filtered, so untagged board routing stays put.
    try std.testing.expect(std.mem.indexOf(u8, js, "function grpCopper(g){return {t:(PCB.tracks||[]).filter(function(t){return t.g===g;})") != null);
}

// Regression guard for pressing R while a component/group pointer drag is
// still active: the rotation and drag must remain one atomic undoable gesture.
test "viewer JS rebases an active drag after live rotation" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "function gdragRebase(d)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "rotateGroup(gidx,rsign,gdrag.g,true,gdragCopper(gdrag))") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "gdragRebase(gdrag)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "rotatePart(drag.i,rsign,true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "gdrag.lx=gm.x;gdrag.ly=gm.y") != null);
    // Live rotation deliberately skips its own undo entry; pointerup commits
    // the original gdrag/drag snapshot once for the combined gesture.
    try std.testing.expect(std.mem.indexOf(u8, js, "if(!live)recordUndo()") != null);
}

// spec: Web Server - Placement guides remain independently controllable from the ratsnest
test "viewer JS keeps placement guides independent with inspection defaults" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "vis:{refdes:0,padnum:1,rats:0,drc:0,netcol:1,guides:0") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "guide?!showGuides:(!showRats||l.done)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(!viewSt.vis.guides)return") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "Placement guides") != null);
}

// spec: Web Server - the /pcb-layout viewer reshapes a drawn outline via vertex drag, edge slide, insert, and delete
test "viewer JS wires freeform outline segment editing" {
    const js = @embedFile("assets/pcb_board.js");
    // The visible authored outline is an editable seed; it materializes only
    // on the first mutation, so opening the tool alone is not a layout edit.
    try std.testing.expect(std.mem.indexOf(u8, js, "function outlineEditable()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(!PCB.outline){var a=outlineEditable()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "outline sketch: click a segment or box-select vertices") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "prop-outline-edit") != null);
    // Edge hit-test + whole-segment slide (the headline capability).
    try std.testing.expect(std.mem.indexOf(u8, js, "function edgeAt(") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function osegStart(") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(osdrag){osegMove(") != null);
    // Insert (double-click an edge) / delete (right-click a vertex) / rect promote.
    try std.testing.expect(std.mem.indexOf(u8, js, "function outlineInsertVertex(") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function outlineVertexDelete(") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function outlinePromote(") != null);
    // Clicking empty space cannot silently clear the outline.
    try std.testing.expect(std.mem.indexOf(u8, js, "activeSketchName()+\" unchanged — drag to draw a new rectangle\"") != null);
    // Live self-intersection validity (red draw + Save refusal) mirrors the server.
    try std.testing.expect(std.mem.indexOf(u8, js, "function polySelfIntersects(") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(outlineBad())") != null);
}

// spec: Web Server - The Objects tab offers a selection filter that skips unchecked object types when clicking
// spec: Web Server - The Objects filter disables sub-circuit hits so overlapping traces remain selectable
// spec: Web Server - The Objects filter picks pour and keepout interiors and offers enable-all and disable-all actions
test "viewer wires a selection filter that gates the hit-testers" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "filt:{fp:1,sub:1,pad:1,track:1,via:1,zone:1,drc:1,outline:1}") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(!viewSt.filt.track)return null") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(RO||!viewSt.filt.zone)return null") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "polyContains(poly,m.x,m.y)||nearPolyEdge") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "[\"zone\",\"Pours / keepouts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "data-ap-filt-all=\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "data-ap-filt-all=\"0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "var ks=PCB.keepouts||[]") != null);
    // The filter gates ordinary PCB-editor picks; physical assembly review is
    // deliberately always pickable even when the editor persisted it off.
    try std.testing.expect(std.mem.indexOf(u8, js, "(PHYSICAL_REVIEW||viewSt.filt.fp)?partAt(m.x,m.y):-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "viewSt.filt.sub)?grpAt") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "viewSt.filt.sub?grpIdxs") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "viewSt.filt.sub&&cg&&grpRigid") != null);
}

// spec: Web Server - Routing toward a same-net pad snaps the whole approach onto the pad centreline
test "viewer JS centre-line snaps a route toward a same-net pad" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "Centre-line snap") != null);
    // the along-axis stays on grid while the cross-axis locks to the pad centre
    try std.testing.expect(std.mem.indexOf(u8, js, "cbest={x:Math.round(m.x/dg)*dg,y:c.y,mag:true}") != null);
}

// Regression guard for QFN side pads whose orientation differs from their
// footprint: painting, pointer hits, and JS fallback clearance must all consume
// the same per-pad rotation already emitted in the board JSON.
test "viewer JS honors pad-local rotation in rendering and geometry" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "(p.rot||0)+(pad.rot||0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "ctx.rotate((pd.rot||0)*Math.PI/180)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "pa=-(pd.rot||0)*Math.PI/180") != null);
    const js3d_surface = @embedFile("assets/pcb_3d_surface.js");
    try std.testing.expect(std.mem.indexOf(u8, js3d_surface, "ctx.rotate(deg(pad.rot))") != null);
    try std.testing.expect(std.mem.indexOf(u8, js3d_surface, "padPoint(part, pad, +pad.slot_half[0], +pad.slot_half[1])") != null);
}

// spec: Web Server - The hand-route tool lays both legs of a differential pair together with mitered offset corners
test "viewer JS wires the coupled diff-pair hand-draw mode" {
    const js = @embedFile("assets/pcb_board.js");
    // A pad start on a declared pair auto-couples the tool to the partner pad.
    try std.testing.expect(std.mem.indexOf(u8, js, "var dp=diffPairInfo(net)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "tr.pair={net:ns.net") != null);
    // The partner chain is a mitered perpendicular offset of the drawn legs.
    try std.testing.expect(std.mem.indexOf(u8, js, "function dpMiter(") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function dpChainFor(") != null);
    // The commit gate judges BOTH candidate track sets (plus the inside-corner
    // trim of the last partner seg) in ONE engine call — all-or-nothing.
    try std.testing.expect(std.mem.indexOf(u8, js, "after.concat(candP,candN)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "drcGateDiffBlocks(bt,bv,after,bv)") != null);
    // V drops a via pair; Backspace unwinds a coupled click as a unit.
    try std.testing.expect(std.mem.indexOf(u8, js, "function dpViaPair(") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function dpBack(") != null);
}

// spec: Web Server - The DRC policy table advertises the same built-in severity the checker emits, differential-pair rules included
test "the kinds table advertises the checkers' own defaults" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    var aw: std.Io.Writer.Allocating = .init(arena_inst.allocator());
    defer aw.deinit();
    try writeKindsJson(&aw.writer, Rules{});
    const kinds = aw.written();
    // The drift this test exists for: both diff-pair rules emit `.warn` from
    // `drc_diffpair.zig`, but this table used to be a hand-kept copy of the
    // `severity = .warn` sites in `drc.zig` and so still called them errors —
    // the drawer offered to "escalate to error" something already an error.
    try std.testing.expect(std.mem.indexOf(u8, kinds, "\"k\":\"diff_uncoupled\",\"label\":\"diff uncoupled\",\"def\":\"warn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, kinds, "\"k\":\"diff_skew\",\"label\":\"diff skew\",\"def\":\"warn\"") != null);
    // …and it is the ONE table, not a second copy that happens to agree today.
    try std.testing.expectEqual(drc.defaultSeverity(.diff_skew), defaultSeverity(.diff_skew));
    try std.testing.expectEqual(drc.defaultSeverity(.track_pad), defaultSeverity(.track_pad));
}

// spec: Web Server - A DRC check for copper outside any project design still layers the net-open connectivity rule onto the built-in severities
test "checkDefaultRules layers net-open onto a board with no rule sidecar" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();
    const geometry = @import("../placement/geometry.zig");
    // Two pads 3 mm apart on one net, and not a millimetre of copper between
    // them: geometrically spotless, electrically an airwire. Bare `drc.check`
    // reports nothing at all here, which is how an uploaded board could come
    // back "clean" while its nets were open.
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 3, .y = 0 },
    };
    const pins = [_]@import("../export_kicad.zig").FlatPin{
        .{ .ref_des = "R1", .pin = "1" },
        .{ .ref_des = "R2", .pin = "1" },
    };
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 0.5,
        .generated = true,
    };
    const empty = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 1 };
    const bare = drc.check(alloc, placement, empty, 0.127) catch &.{};
    try std.testing.expectEqual(@as(usize, 0), countOpen(bare));
    const layered = checkDefaultRules(alloc, .{ .placement = placement, .routed = empty, .clearance = 0.127 });
    try std.testing.expectEqual(@as(usize, 1), countOpen(layered));
    // Built-in severities stand — there is no design here whose sidecar could
    // retag them — and an open net is never counted as fab-blocking geometry.
    try std.testing.expectEqual(drc.Severity.err, layered[layered.len - 1].severity);
    try std.testing.expectEqual(@as(usize, 0), drc.errorCount(layered));
}

// spec: placement/drc - a persisted solver RF polygon contributes its compact centreline to connectivity DRC without reviving chord-level geometry findings
test "persisted RF polygon closes its net without exposing geometry chords" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();
    const geometry = @import("../placement/geometry.zig");
    const solver = @import("../placement/rf_path_solver.zig");
    const report = @import("../placement/rf_port_report.zig");
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "J2", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 3, .y = 0 },
    };
    const pins = [_]@import("../export_kicad.zig").FlatPin{
        .{ .ref_des = "J1", .pin = "1" },
        .{ .ref_des = "J2", .pin = "1" },
    };
    const nets = [_]optimizer.FlatNet{.{ .name = "RF", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 0.5,
        .generated = true,
    };
    const samples = [_]solver.Sample{
        .{ .at = .{ 0, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 0.4 },
        .{ .at = .{ 3, 0 }, .s_mm = 3, .curvature = 0, .width_mm = 0.4 },
    };
    const outcomes = [_]report.Outcome{.{
        .net = 0,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = samples.len, .samples = &samples, .layer = 0 },
    }};
    // A saved net may also have a separate editable stub; that must not stop
    // the compact RF centreline from participating in connectivity.
    const ordinary = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 0.5, .y2 = 0, .layer = 0, .width = 0.4, .net = 0 }};
    const persisted = router.RouteResult{ .tracks = &ordinary, .vias = &.{}, .rf_port_outcomes = &outcomes, .routed = 1, .total = 1 };
    const checked = checkDefaultRules(alloc, .{ .placement = placement, .routed = persisted, .clearance = 0.127 });
    try std.testing.expectEqual(@as(usize, 0), countOpen(checked));
    try std.testing.expectEqual(@as(usize, 0), drc.countKind(checked, .track_width));
    try std.testing.expectEqual(@as(usize, 0), drc.countKind(checked, .track_pad));
}

/// How many `net_open` findings a violation list carries.
fn countOpen(list: []const drc.Violation) usize {
    var n: usize = 0;
    for (list) |v| {
        if (v.kind == .net_open) n += 1;
    }
    return n;
}
