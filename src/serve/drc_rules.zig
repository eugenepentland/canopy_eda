//! Per-design DRC rule severities — the user's "what counts as an error"
//! settings. Each design may carry a `<design>.drc-rules.json` sidecar mapping
//! violation kinds to an overriding action (`err` / `warn` / `ignore`); the
//! overrides are applied at every violation producer (page blob, /api/pcb-drc,
//! /api/pcb-route, /api/pcb-describe, the fab-readiness gate), so the viewer,
//! the APIs, and the Gerber gate always agree on what is an error. Edited from
//! the viewer's DRC panel via GET/POST `/api/pcb-drc-rules/:name`.

const std = @import("std");
const httpz = @import("httpz");
const drc = @import("../placement/drc.zig");
const optimizer = @import("../placement/optimizer.zig");
const router = @import("../placement/router.zig");
const drc_json = @import("drc_json.zig");
const paths = @import("../paths.zig");
const infra_fs = @import("../infra/fs.zig");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;
const HandlerError = @import("pcb_layout_page.zig").HandlerError;

const rules_ext = ".drc-rules.json";
const kind_count = @typeInfo(drc.Kind).@"enum".fields.len;

/// What a violation kind becomes under an override. `ignore` drops it
/// entirely; `err`/`warn` retag its severity.
pub const Action = enum { err, warn, ignore };

/// The per-design override map: one optional action per `drc.Kind`, `null`
/// meaning "keep the checker's built-in severity".
pub const Rules = struct {
    ov: [kind_count]?Action = [_]?Action{null} ** kind_count,

    fn isDefault(self: Rules) bool {
        for (self.ov) |o| if (o != null) return false;
        return true;
    }
};

/// The checker's built-in severity per kind — only the assembly-hygiene
/// checks are warnings (mirrors the `severity = .warn` sites in drc.zig).
fn defaultSeverity(k: drc.Kind) drc.Severity {
    return switch (k) {
        .courtyard, .mask_sliver, .silk_over_pad => .warn,
        else => .err,
    };
}

/// Apply `rules` to a violation list: drop `ignore`d kinds, retag the rest.
/// Returns the input slice untouched when no override is set (the common
/// case) or on allocation failure (reporting unfiltered beats reporting
/// nothing).
pub fn apply(alloc: std.mem.Allocator, rules: Rules, list: []const drc.Violation) []const drc.Violation {
    if (rules.isDefault()) return list;
    var out: std.ArrayList(drc.Violation) = .empty;
    for (list) |v| {
        const a = rules.ov[@intFromEnum(v.kind)] orelse {
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
/// serve-layer violation producer calls.
pub fn checkFiltered(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    placement: optimizer.Placement,
    r: router.RouteResult,
    clearance: f64,
) []const drc.Violation {
    const raw = drc.check(alloc, placement, r, clearance) catch &.{};
    return apply(alloc, load(alloc, project_dir, name), raw);
}

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
        rules.ov[@intFromEnum(k)] = a;
    }
    return true;
}

/// Serialize only the overrides — the sidecar file body.
fn writeRulesJson(w: *std.Io.Writer, rules: Rules) std.Io.Writer.Error!void {
    try w.writeByte('{');
    var first = true;
    inline for (@typeInfo(drc.Kind).@"enum".fields, 0..) |f, i| {
        if (rules.ov[i]) |a| {
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("\"{s}\":\"{s}\"", .{ f.name, @tagName(a) });
        }
    }
    try w.writeByte('}');
}

/// The kinds table the viewer's settings menu renders: every kind with its
/// wire key, human label, built-in severity, and current override (or null).
pub fn writeKindsJson(w: *std.Io.Writer, rules: Rules) std.Io.Writer.Error!void {
    try w.writeByte('[');
    inline for (@typeInfo(drc.Kind).@"enum".fields, 0..) |f, i| {
        const k: drc.Kind = @enumFromInt(f.value);
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"k\":\"{s}\",\"label\":\"{s}\",\"def\":\"{s}\",\"ov\":", .{
            f.name, drc_json.kindStr(k), if (defaultSeverity(k) == .warn) "warn" else "err",
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
    rules.ov[@intFromEnum(drc.Kind.silk_over_pad)] = .ignore;
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try writeRulesJson(&aw.writer, rules);
    try std.testing.expectEqualStrings("{\"silk_over_pad\":\"ignore\"}", aw.written());
    var back = Rules{};
    try std.testing.expect(parseInto(&back, alloc, aw.written()));
    try std.testing.expectEqual(Action.ignore, back.ov[@intFromEnum(drc.Kind.silk_over_pad)].?);
    var kw: std.Io.Writer.Allocating = .init(alloc);
    defer kw.deinit();
    try writeKindsJson(&kw.writer, rules);
    const kinds = kw.written();
    const silk_row = "{\"k\":\"silk_over_pad\",\"label\":\"silk over pad\",\"def\":\"warn\",\"ov\":\"ignore\"}";
    try std.testing.expect(std.mem.indexOf(u8, kinds, silk_row) != null);
    const hole_row = "{\"k\":\"hole_hole\",\"label\":\"hole↔hole\",\"def\":\"err\",\"ov\":null}";
    try std.testing.expect(std.mem.indexOf(u8, kinds, hole_row) != null);
}

// spec: Web Server - The /pcb-layout Properties dock hosts the inspector with segment editing and DRC rule settings
test "viewer JS wires the docked inspector, segment editing, and the DRC rules menu" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "function renderInspProps") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "segdrag") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "/api/pcb-drc-rules/") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "drc-cog") != null);
}

// spec: Web Server - Segment drags preserve neighbour track angles and insert perpendicular jogs on collinear runs
test "viewer JS drags segments KiCad-style: corner intersections and collinear jogs" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "function segPlan") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"corner\"") != null);
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

// spec: Web Server - The decoupling-loop overlay has its own visibility toggle, hidden by default
test "viewer JS gates the decoupling-loop overlay on a default-off `loops` flag" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "netcol:0,loops:0") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(!viewSt.vis.loops)return") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "Decoupling loops") != null);
}

// spec: Web Server - The Objects tab offers a selection filter that skips unchecked object types when clicking
test "viewer wires a selection filter that gates the hit-testers" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "filt:{fp:1,pad:1,track:1,via:1,drc:1}") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(!viewSt.filt.track)return null") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "viewSt.filt.fp?partAt(m.x,m.y):-1") != null);
}

// spec: Web Server - Routing toward a same-net pad snaps the whole approach onto the pad centreline
test "viewer JS centre-line snaps a route toward a same-net pad" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "Centre-line snap") != null);
    // the along-axis stays on grid while the cross-axis locks to the pad centre
    try std.testing.expect(std.mem.indexOf(u8, js, "cbest={x:Math.round(m.x/dg)*dg,y:c.y,mag:true}") != null);
}
