//! Surgical board-rule and stackup-plane editing for the PCB Design Settings
//! drawer. The endpoints change only the source forms they own, preserving
//! comments, ordering, construction details, and forms the GUI does not know.
//!
//! Both forms are eligible to live in the design's `<name>.layout.sexp`
//! sidecar, so neither endpoint assumes `src/<name>.sexp`:
//! `design_settings_target.resolve` names the file that actually holds the
//! form (and the shape that file stores it in — a `(design-block …)` child, or
//! a top-level form), and the patch is applied to THAT file at THAT file's byte
//! spans. A form nobody has authored yet is created in the layout sidecar when
//! the design has one, and in the design file when it does not.

const std = @import("std");
const httpz = @import("httpz");
const rule_fields = @import("../design_rule_fields.zig");
const infra_fs = @import("../infra/fs.zig");
const serve_root = @import("../serve.zig");
const edit = @import("edit.zig");
const target = @import("design_settings_target.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;

const Server = serve_root.Server;
const max_source_bytes: usize = 10 * 1024 * 1024;

const PlaneAssignment = struct {
    index: u8,
    net: []const u8,
};

const Rule = rule_fields.Rule;
const scalar_rules = rule_fields.scalar;

fn ruleForKey(key: []const u8) ?Rule {
    for (scalar_rules) |rule| if (std.mem.eql(u8, key, rule.key)) return rule;
    return null;
}

fn jsonNumber(value: std.json.Value) ?f64 {
    const n: f64 = switch (value) {
        .integer => |v| @floatFromInt(v),
        .float => |v| v,
        .number_string => |v| std.fmt.parseFloat(f64, v) catch return null,
        else => return null,
    };
    return if (std.math.isFinite(n) and n >= 0 and n <= 1000) n else null;
}

const Span = target.Span;
const Container = target.Container;

const skipStringOrComment = target.skipStringOrComment;
const formEnd = target.formEnd;
const formHead = target.formHead;
const replaceSpan = target.replaceSpan;

/// The `(design-rules …)` form as `container` stores it: a `(design-block …)`
/// child in the design file, a top-level form in a sidecar.
fn designRulesSpan(source: []const u8, container: Container) ?Span {
    return target.formSpan(source, container, "design-rules");
}

/// Author an empty `(design-rules)` into a file that has none, in that file's
/// own shape — before the design-block's closing paren, or appended to the
/// sidecar.
fn addDesignRules(allocator: std.mem.Allocator, source: []const u8, container: Container) ![]u8 {
    if (container == .top_level) return target.appendTopLevel(allocator, source, "(design-rules)");
    const open = std.mem.indexOf(u8, source, "(design-block") orelse return error.MalformedSource;
    const end = formEnd(source, open) orelse return error.MalformedSource;
    return replaceSpan(allocator, source, .{ .start = end - 1, .end = end - 1 }, "\n\n  (design-rules)\n");
}

fn patchForm(
    allocator: std.mem.Allocator,
    source: []const u8,
    container: Container,
    head: []const u8,
    args: []const u8,
) ![]u8 {
    var owned_source: ?[]u8 = null;
    defer if (owned_source) |owned| allocator.free(owned);
    const rules = designRulesSpan(source, container) orelse blk: {
        owned_source = try addDesignRules(allocator, source, container);
        break :blk designRulesSpan(owned_source.?, container) orelse return error.MalformedSource;
    };
    const working = owned_source orelse source;
    const replacement = try std.fmt.allocPrint(allocator, "({s} {s})", .{ head, args });
    defer allocator.free(replacement);
    if (target.directChild(working, rules, head)) |child|
        return replaceSpan(allocator, working, child, replacement);

    const own_indent = target.formIndent(working, rules, container.indent());
    const insertion = try std.fmt.allocPrint(allocator, "\n{s}  {s}", .{ own_indent, replacement });
    defer allocator.free(insertion);
    return replaceSpan(allocator, working, .{ .start = rules.end - 1, .end = rules.end - 1 }, insertion);
}

fn patchScalar(allocator: std.mem.Allocator, source: []const u8, container: Container, rule: Rule, value: f64) ![]u8 {
    const args = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(args);
    return patchForm(allocator, source, container, rule.head, args);
}

fn patchVia(allocator: std.mem.Allocator, source: []const u8, container: Container, dia: f64, drill: f64) ![]u8 {
    const args = try std.fmt.allocPrint(allocator, "{d} {d}", .{ dia, drill });
    defer allocator.free(args);
    return patchForm(allocator, source, container, "via", args);
}

fn patchRules(allocator: std.mem.Allocator, source: []const u8, container: Container, rules: std.json.ObjectMap) ![]u8 {
    var current = try allocator.dupe(u8, source);
    errdefer allocator.free(current);
    var changed = false;
    var via_dia: ?f64 = null;
    var via_drill: ?f64 = null;
    var it = rules.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = jsonNumber(entry.value_ptr.*) orelse return error.InvalidValue;
        if (std.mem.eql(u8, key, "via_dia")) {
            via_dia = value;
            continue;
        }
        if (std.mem.eql(u8, key, "via_drill")) {
            via_drill = value;
            continue;
        }
        const rule = ruleForKey(key) orelse return error.UnknownRule;
        const next = try patchScalar(allocator, current, container, rule, value);
        allocator.free(current);
        current = next;
        changed = true;
    }
    if (via_dia != null or via_drill != null) {
        if (via_dia == null or via_drill == null or via_drill.? > via_dia.?) return error.InvalidVia;
        const next = try patchVia(allocator, current, container, via_dia.?, via_drill.?);
        allocator.free(current);
        current = next;
        changed = true;
    }
    if (!changed) return error.NoRules;
    return current;
}

fn planeForm(head: []const u8) bool {
    return std.mem.eql(u8, head, "plane") or std.mem.eql(u8, head, "pour");
}

/// All direct `(plane …)` / `(pour …)` children of one stackup. A whole-line
/// form takes its indentation and newline with it, so deleting a row from the
/// settings panel does not leave a staircase of blank source lines. Inline
/// forms retain their surrounding whitespace and remain valid after removal.
fn electricalRoleSpans(allocator: std.mem.Allocator, source: []const u8, stackup: Span) ![]Span {
    var found: std.ArrayList(Span) = .empty;
    errdefer found.deinit(allocator);
    var cursor = stackup.start + 1;
    while (cursor + 1 < stackup.end) {
        const ch = source[cursor];
        if (ch == '"' or ch == ';') {
            skipStringOrComment(source, &cursor, stackup.end);
            continue;
        }
        if (ch != '(') {
            cursor += 1;
            continue;
        }
        const end = formEnd(source, cursor) orelse return error.MalformedSource;
        if (end > stackup.end) return error.MalformedSource;
        if (planeForm(formHead(source, cursor, end))) {
            var span = Span{ .start = cursor, .end = end };
            var line_start = cursor;
            while (line_start > stackup.start and source[line_start - 1] != '\n') line_start -= 1;
            var before_only_space = true;
            for (source[line_start..cursor]) |c| if (!std.ascii.isWhitespace(c)) {
                before_only_space = false;
                break;
            };
            var line_end = end;
            while (line_end < stackup.end and source[line_end] != '\n') : (line_end += 1) {}
            var after_only_space = true;
            for (source[end..line_end]) |c| if (!std.ascii.isWhitespace(c)) {
                after_only_space = false;
                break;
            };
            if (before_only_space and after_only_space) {
                span.start = line_start;
                if (line_end < stackup.end) line_end += 1;
                span.end = line_end;
            }
            try found.append(allocator, span);
        }
        cursor = end;
    }
    return found.toOwnedSlice(allocator);
}

fn writeSexprString(w: *std.Io.Writer, value: []const u8) !void {
    try w.writeByte('"');
    for (value) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn writePlaneForms(w: *std.Io.Writer, planes: []const PlaneAssignment, indent: []const u8) !void {
    for (planes) |plane| {
        try w.print("{s}(plane {d} ", .{ indent, plane.index });
        try writeSexprString(w, plane.net);
        try w.writeAll(")\n");
    }
}

/// Replace only a stackup's electrical roles. Physical copper/dielectric
/// construction, preset selection, thickness, comments, and ordering remain
/// byte-for-byte. With no authored stackup, saving the visible implicit model
/// makes it explicit as `(stackup N …)` so add/delete has durable semantics —
/// authored in whichever of the design's files `container` names.
fn patchStackupPlanes(
    allocator: std.mem.Allocator,
    source: []const u8,
    container: Container,
    layers: u8,
    planes: []const PlaneAssignment,
) ![]u8 {
    const stackup = target.formSpan(source, container, "stackup") orelse {
        var replacement: std.Io.Writer.Allocating = .init(allocator);
        errdefer replacement.deinit();
        try replacement.writer.print("(stackup {d}\n", .{layers});
        try writePlaneForms(&replacement.writer, planes, container.childIndent());
        try replacement.writer.print("{s})", .{container.indent()});
        const owned = try replacement.toOwnedSlice();
        defer allocator.free(owned);
        if (container == .top_level) return target.appendTopLevel(allocator, source, owned);
        const block = target.designBlockSpan(source) orelse return error.MalformedSource;
        const framed = try std.fmt.allocPrint(allocator, "\n\n{s}{s}\n", .{ container.indent(), owned });
        defer allocator.free(framed);
        return replaceSpan(allocator, source, .{ .start = block.end - 1, .end = block.end - 1 }, framed);
    };
    // Indent the rewritten rows to match the form as it actually sits in THIS
    // file: a `split-design` move keeps the indentation the design file gave it.
    const own_indent = target.formIndent(source, stackup, container.indent());
    const child_indent = try std.fmt.allocPrint(allocator, "{s}  ", .{own_indent});
    defer allocator.free(child_indent);
    const roles = try electricalRoleSpans(allocator, source, stackup);
    defer allocator.free(roles);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(source[0..stackup.start]);
    var cursor = stackup.start;
    for (roles) |role| {
        try out.writer.writeAll(source[cursor..role.start]);
        cursor = role.end;
    }
    try out.writer.writeAll(source[cursor .. stackup.end - 1]);
    if (out.written().len > 0 and out.written()[out.written().len - 1] != '\n') try out.writer.writeByte('\n');
    try writePlaneForms(&out.writer, planes, child_indent);
    try out.writer.writeAll(own_indent);
    try out.writer.writeAll(source[stackup.end - 1 ..]);
    return out.toOwnedSlice();
}

fn jsonLayerCount(value: std.json.Value) ?u8 {
    const n: i64 = switch (value) {
        .integer => |v| v,
        .number_string => |v| std.fmt.parseInt(i64, v, 10) catch return null,
        else => return null,
    };
    return if (n >= 1 and n <= 32) @intCast(n) else null;
}

fn validNetName(net: []const u8) bool {
    if (net.len == 0 or net.len > 1024) return false;
    for (net) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

fn parsePlaneAssignments(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    layers: u8,
) ![]PlaneAssignment {
    if (value != .array) return error.InvalidPlanes;
    if (value.array.items.len > layers) return error.InvalidPlanes;
    const planes = try allocator.alloc(PlaneAssignment, value.array.items.len);
    errdefer allocator.free(planes);
    for (value.array.items, 0..) |item, i| {
        if (item != .object) return error.InvalidPlanes;
        const index = jsonLayerCount(item.object.get("index") orelse return error.InvalidPlanes) orelse return error.InvalidPlanes;
        const net_value = item.object.get("net") orelse return error.InvalidPlanes;
        if (index > layers or net_value != .string or !validNetName(net_value.string)) return error.InvalidPlanes;
        for (planes[0..i]) |old| if (old.index == index) return error.DuplicateLayer;
        planes[i] = .{ .index = index, .net = net_value.string };
    }
    std.mem.sort(PlaneAssignment, planes, {}, struct {
        fn lessThan(_: void, a: PlaneAssignment, b: PlaneAssignment) bool {
            return a.index < b.index;
        }
    }.lessThan);
    return planes;
}

fn jsonError(res: *httpz.Response, status: u16, message: []const u8) void {
    res.status = status;
    res.content_type = .JSON;
    res.body = message;
}

/// The one state no writer can resolve on its own: the same singleton declared
/// in two of the design's files. The loader refuses that board outright, so the
/// answer names both files rather than picking one to patch.
fn conflictError(
    allocator: std.mem.Allocator,
    res: *httpz.Response,
    head: []const u8,
    conflict: target.Conflict,
) std.mem.Allocator.Error!void {
    res.status = 409;
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(
        allocator,
        "{{\"error\":\"({s} …) is declared in both {s} and {s} — a design may declare it once; delete one copy\"}}",
        .{ head, std.fs.path.basename(conflict.first), std.fs.path.basename(conflict.second) },
    );
}

/// Resolve the file that owns `head`, answering the HTTP error itself when the
/// design cannot be read or declares the form twice.
fn settingsTarget(
    ctx: *Server,
    res: *httpz.Response,
    name: []const u8,
    head: []const u8,
) std.mem.Allocator.Error!?target.Target {
    const resolution = target.resolve(ctx.allocator, ctx.project_dir, name, &.{head}) catch {
        jsonError(res, 404, "{\"error\":\"design source not found\"}");
        return null;
    };
    switch (resolution) {
        .conflict => |c| {
            defer resolution.deinit(ctx.allocator);
            try conflictError(ctx.allocator, res, head, c);
            return null;
        },
        .target => |t| return t,
    }
}

/// POST /api/design-rules/:name — patch the supplied board-level numeric rules,
/// preserving every unrelated source form, then rebuild the design.
pub fn editDesignRulesApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) std.mem.Allocator.Error!void {
    const name = req.param("name") orelse return jsonError(res, 404, "{\"error\":\"missing design\"}");
    const body = req.body() orelse return jsonError(res, 400, "{\"error\":\"missing body\"}");
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch
        return jsonError(res, 400, "{\"error\":\"invalid JSON\"}");
    defer parsed.deinit();
    if (parsed.value != .object) return jsonError(res, 400, "{\"error\":\"body must be an object\"}");
    const values = parsed.value.object.get("rules") orelse return jsonError(res, 400, "{\"error\":\"missing rules\"}");
    if (values != .object) return jsonError(res, 400, "{\"error\":\"rules must be an object\"}");

    const where = try settingsTarget(ctx, res, name, "design-rules") orelse return;
    defer where.deinit(ctx.allocator);
    const source = infra_fs.cwd().readFileAlloc(ctx.allocator, where.path, max_source_bytes) catch
        return jsonError(res, 404, "{\"error\":\"cannot read design source\"}");
    defer ctx.allocator.free(source);
    const updated = patchRules(ctx.allocator, source, where.container, values.object) catch |err| {
        const message = switch (err) {
            error.InvalidValue => "{\"error\":\"rule values must be finite numbers from 0 to 1000 mm\"}",
            error.UnknownRule => "{\"error\":\"unknown design rule\"}",
            error.InvalidVia => "{\"error\":\"via diameter and drill must be supplied together, with drill no larger than diameter\"}",
            error.NoRules => "{\"error\":\"no rules supplied\"}",
            error.MalformedSource => "{\"error\":\"malformed design-block\"}",
            else => "{\"error\":\"could not update design rules\"}",
        };
        return jsonError(res, 400, message);
    };
    defer ctx.allocator.free(updated);
    const result = edit.writeFileAndRebuild(ctx.allocator, ctx.project_dir, name, where.path, updated, "edit design rules from PCB settings") catch
        return jsonError(res, 500, "{\"error\":\"could not save and rebuild design rules\"}");
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":true,\"version\":{d}}}", .{result.version});
}

/// POST /api/stackup-planes/:name — replace the board's whole-layer copper
/// assignments, preserving the rest of `(stackup …)`, then rebuild. The list
/// is authoritative: omitting a formerly assigned layer deletes its plane.
pub fn editStackupPlanesApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) std.mem.Allocator.Error!void {
    const name = req.param("name") orelse return jsonError(res, 404, "{\"error\":\"missing design\"}");
    const body = req.body() orelse return jsonError(res, 400, "{\"error\":\"missing body\"}");
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch
        return jsonError(res, 400, "{\"error\":\"invalid JSON\"}");
    defer parsed.deinit();
    if (parsed.value != .object) return jsonError(res, 400, "{\"error\":\"body must be an object\"}");
    const layers = jsonLayerCount(parsed.value.object.get("layers") orelse return jsonError(res, 400, "{\"error\":\"missing layer count\"}")) orelse
        return jsonError(res, 400, "{\"error\":\"layer count must be a whole number from 1 to 32\"}");
    const planes_value = parsed.value.object.get("planes") orelse
        return jsonError(res, 400, "{\"error\":\"missing planes\"}");
    const planes = parsePlaneAssignments(ctx.allocator, planes_value, layers) catch |err| {
        const message = switch (err) {
            error.DuplicateLayer => "{\"error\":\"each copper layer can have only one whole-layer plane\"}",
            else => "{\"error\":\"planes must contain one valid layer index and non-empty net name per assignment\"}",
        };
        return jsonError(res, 400, message);
    };
    defer ctx.allocator.free(planes);

    const where = try settingsTarget(ctx, res, name, "stackup") orelse return;
    defer where.deinit(ctx.allocator);
    const source = infra_fs.cwd().readFileAlloc(ctx.allocator, where.path, max_source_bytes) catch
        return jsonError(res, 404, "{\"error\":\"cannot read design source\"}");
    defer ctx.allocator.free(source);
    const updated = patchStackupPlanes(ctx.allocator, source, where.container, layers, planes) catch |err| {
        const message = switch (err) {
            error.MalformedSource => "{\"error\":\"malformed design-block or stackup\"}",
            else => "{\"error\":\"could not update whole-layer planes\"}",
        };
        return jsonError(res, 400, message);
    };
    defer ctx.allocator.free(updated);
    const result = edit.writeFileAndRebuild(ctx.allocator, ctx.project_dir, name, where.path, updated, "edit whole-layer copper planes from PCB settings") catch
        return jsonError(res, 500, "{\"error\":\"could not save and rebuild stackup planes\"}");
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":true,\"version\":{d}}}", .{result.version});
}

// spec: Web Server - Design Settings edits board-level numeric rules in the GUI, preserves unrelated source forms, rebuilds, and reloads the shown layout
test "design settings patch rules without replacing comments or unrelated forms" {
    const a = std.testing.allocator;
    const source =
        \\(design-block "board"
        \\  (design-rules
        \\    ;; Keep this explanation.
        \\    (clearance 0.1)
        \\    (mask-web 0.2))
        \\  (section "RF"))
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"clearance\":0.125,\"mask_relief_corner_radius\":0.3,\"via_dia\":0.5,\"via_drill\":0.25,\"via_plating\":0.02}", .{});
    defer parsed.deinit();
    const got = try patchRules(a, source, .design_block, parsed.value.object);
    defer a.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, ";; Keep this explanation.") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "(clearance 0.125)") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "(mask-web 0.2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "(mask-relief-corner-radius 0.3)") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "(via 0.5 0.25)") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "(via-plating 0.02)") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "(section \"RF\")") != null);
}

// spec: Web Server - Design Settings creates a design-rules source form when a board previously relied entirely on defaults
test "design settings create a design-rules form when the source has none" {
    const a = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"mask_web\":0.18}", .{});
    defer parsed.deinit();
    const got = try patchRules(a, "(design-block \"board\"\n  (section \"RF\"))\n", .design_block, parsed.value.object);
    defer a.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "(design-rules\n    (mask-web 0.18))") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "(section \"RF\")") != null);
}

// spec: Web Server - Design Settings adds, edits, and deletes whole-layer copper planes without replacing physical stackup construction or comments
test "design settings surgically replace whole-layer stackup planes" {
    const a = std.testing.allocator;
    const source =
        \\(design-block "board"
        \\  (stackup "JLC04161H-7628"
        \\    ;; Keep the fabrication explanation.
        \\    (copper 1 (thickness 0.035))
        \\    (plane 2 "GND")
        \\    (pour bottom "GND")
        \\    (dielectric 1 prepreg (material "7628") (thickness 0.2))
        \\    (thickness 1.6))
        \\  (section "RF"))
    ;
    const planes = [_]PlaneAssignment{
        .{ .index = 2, .net = "AGND" },
        .{ .index = 3, .net = "V_3V3D" },
    };
    const got = try patchStackupPlanes(a, source, .design_block, 4, &planes);
    defer a.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, ";; Keep the fabrication explanation.") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "(copper 1 (thickness 0.035))") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "(dielectric 1 prepreg (material \"7628\") (thickness 0.2))") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "(thickness 1.6)") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "(plane 2 \"AGND\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "(plane 3 \"V_3V3D\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "(pour bottom") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "(plane 2 \"GND\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "(section \"RF\")") != null);
}

// spec: Web Server - Saving plane controls on an implicit board authors the visible copper count and supports an explicitly plane-free stack
test "design settings materialize implicit planes and can delete every assignment" {
    const a = std.testing.allocator;
    const source = "(design-block \"board\"\n  (section \"Power\"))\n";
    const initial = [_]PlaneAssignment{
        .{ .index = 2, .net = "GND" },
        .{ .index = 3, .net = "V_SUPPLY" },
    };
    const authored = try patchStackupPlanes(a, source, .design_block, 4, &initial);
    defer a.free(authored);
    try std.testing.expect(std.mem.indexOf(u8, authored, "(stackup 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, authored, "(plane 2 \"GND\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, authored, "(plane 3 \"V_SUPPLY\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, authored, "(section \"Power\")") != null);

    const cleared = try patchStackupPlanes(a, authored, .design_block, 4, &.{});
    defer a.free(cleared);
    try std.testing.expect(std.mem.indexOf(u8, cleared, "(stackup 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, cleared, "(plane ") == null);
}

test "whole-layer plane input rejects duplicate layers and escapes source strings" {
    const a = std.testing.allocator;
    var duplicate_json = try std.json.parseFromSlice(std.json.Value, a, "[{\"index\":2,\"net\":\"GND\"},{\"index\":2,\"net\":\"VCC\"}]", .{});
    defer duplicate_json.deinit();
    try std.testing.expectError(error.DuplicateLayer, parsePlaneAssignments(a, duplicate_json.value, 4));

    const planes = [_]PlaneAssignment{.{ .index = 2, .net = "rail\\\"name" }};
    const got = try patchStackupPlanes(a, "(design-block \"b\")", .design_block, 4, &planes);
    defer a.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "(plane 2 \"rail\\\\\\\"name\")") != null);
}

// spec: Web Server - Design Settings patches a rule form that lives in the design's layout sidecar in that sidecar, at that file's own byte spans, leaving the design file untouched
test "design settings patch a split design's layout sidecar in place" {
    const a = std.testing.allocator;
    const sidecar =
        \\; Layout sidecar.
        \\(design-rules
        \\  ;; Keep this explanation.
        \\  (clearance 0.15))
        \\(stackup 4
        \\  (copper 1 (thickness 0.035))
        \\  (plane 2 "GND")
        \\  (thickness 1.6))
        \\
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"clearance\":0.2,\"mask_web\":0.18}", .{});
    defer parsed.deinit();
    const rules = try patchRules(a, sidecar, .top_level, parsed.value.object);
    defer a.free(rules);
    try std.testing.expect(std.mem.indexOf(u8, rules, ";; Keep this explanation.") != null);
    try std.testing.expect(std.mem.indexOf(u8, rules, "(clearance 0.2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rules, "(mask-web 0.18)") != null);
    // Exactly one design-rules form: a sidecar patch never authors a second.
    try std.testing.expect(std.mem.indexOf(u8, rules, "(design-rules") ==
        std.mem.lastIndexOf(u8, rules, "(design-rules"));
    try std.testing.expect(std.mem.indexOf(u8, rules, "(design-block") == null);

    const planes = [_]PlaneAssignment{.{ .index = 3, .net = "V_3V3D" }};
    const stack = try patchStackupPlanes(a, sidecar, .top_level, 4, &planes);
    defer a.free(stack);
    try std.testing.expect(std.mem.indexOf(u8, stack, "(copper 1 (thickness 0.035))") != null);
    try std.testing.expect(std.mem.indexOf(u8, stack, "(plane 3 \"V_3V3D\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, stack, "(plane 2 \"GND\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, stack, "(design-rules") != null);
}

// spec: Web Server - Design Settings authors a missing rule form into the layout sidecar of a design that has one, rather than into the design file
test "design settings author a missing form at the sidecar's top level" {
    const a = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"mask_web\":0.18}", .{});
    defer parsed.deinit();
    const rules = try patchRules(a, "; Layout sidecar.\n(stackup 4)\n", .top_level, parsed.value.object);
    defer a.free(rules);
    try std.testing.expect(std.mem.indexOf(u8, rules, "(design-rules\n  (mask-web 0.18))") != null);
    try std.testing.expect(std.mem.indexOf(u8, rules, "(stackup 4)") != null);

    const planes = [_]PlaneAssignment{.{ .index = 2, .net = "GND" }};
    const stack = try patchStackupPlanes(a, "; Layout sidecar.\n", .top_level, 4, &planes);
    defer a.free(stack);
    try std.testing.expect(std.mem.indexOf(u8, stack, "(stackup 4\n  (plane 2 \"GND\")\n)") != null);
    try std.testing.expect(std.mem.indexOf(u8, stack, "; Layout sidecar.") != null);
}

// ── Endpoint-level: the whole write path against a split design ───────

/// Evaluate `src/<name>.sexp` under `root` the way `netlisp` does, so the
/// autoloaded sidecars are spliced in. Hoisted out of the test bodies because
/// unwrapping the evaluator's `Value` needs a switch.
fn evalDesign(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    root: []const u8,
    name: []const u8,
) !*const @import("../eval/env.zig").DesignBlock {
    const design_path = try std.fmt.allocPrint(allocator, "{s}/src/{s}.sexp", .{ root, name });
    return switch (try eval.evalFile(design_path)) {
        .design_block => |b| b,
        else => error.NotADesign,
    };
}

const split_design_src = "(design-block \"Split\"\n  (board-role board)\n  (section \"RF\"))\n";
/// Exactly the shape `split-design` writes: a banner, then each moved form
/// lifted byte for byte — indentation from the design file included.
const split_layout_src =
    \\; Layout sidecar — autoloaded and spliced into the design body.
    \\; See docs/sexpr-language.md → "Sidecar files".
    \\
    \\  (design-rules
    \\    ;; Keep this explanation.
    \\    (clearance 0.15))
    \\  (stackup 4
    \\    (copper 1 (thickness 0.035))
    \\    (plane 2 "GND")
    \\    (thickness 1.6))
    \\
;

// spec: Web Server - A Design Settings save on a split design rewrites the layout sidecar, leaves the design file byte-identical, and the re-evaluated board reports the new rule
test "design settings endpoint edits the sidecar of a split design end to end" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/split.sexp", .data = split_design_src });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/split.layout.sexp", .data = split_layout_src });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var state = serve_root.ServerState{};
    var srv = Server{ .allocator = a, .project_dir = root, .auth_dir = root, .state = &state };

    var request = httpz.testing.init(.{});
    defer request.deinit();
    request.param("name", "split");
    request.body("{\"rules\":{\"clearance\":0.22,\"mask_web\":0.18}}");
    try editDesignRulesApi(&srv, request.req, request.res);
    try std.testing.expectEqual(@as(u16, 200), request.res.status);

    // The design file is byte-identical: no second (design-rules …) was authored.
    const design_after = try tmp.dir.readFileAlloc(std.testing.io, "src/split.sexp", a, .limited(4096));
    try std.testing.expectEqualStrings(split_design_src, design_after);

    // The sidecar carries the edit, its comment, and still exactly one form.
    const sidecar_after = try tmp.dir.readFileAlloc(std.testing.io, "src/split.layout.sexp", a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, sidecar_after, "(clearance 0.22)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sidecar_after, "(mask-web 0.18)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sidecar_after, ";; Keep this explanation.") != null);
    try std.testing.expectEqual(
        std.mem.indexOf(u8, sidecar_after, "(design-rules"),
        std.mem.lastIndexOf(u8, sidecar_after, "(design-rules"),
    );
    // The new row nests inside the form as it actually sits in THIS file — the
    // indentation `split-design` carried over, not the container's default.
    try std.testing.expect(std.mem.indexOf(u8, sidecar_after, "\n    (mask-web 0.18)") != null);

    // Re-evaluating the design — the splice included — sees the saved rule.
    var eval = Evaluator.init(a, root);
    defer eval.deinit();
    const block = try evalDesign(a, &eval, root, "split");
    try std.testing.expectApproxEqAbs(@as(f64, 0.22), block.design_rules.clearance, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.18), block.design_rules.mask.web, 1e-9);
}

// spec: Web Server - A Design Settings save on a board whose stackup has no authored form yet writes it into the layout sidecar the design already has
test "design settings endpoint authors a stackup into the existing layout sidecar" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/bare.sexp", .data = split_design_src });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/bare.layout.sexp",
        .data = "; Layout sidecar.\n(design-rules (clearance 0.15))\n",
    });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var state = serve_root.ServerState{};
    var srv = Server{ .allocator = a, .project_dir = root, .auth_dir = root, .state = &state };

    var request = httpz.testing.init(.{});
    defer request.deinit();
    request.param("name", "bare");
    request.body("{\"layers\":4,\"planes\":[{\"index\":2,\"net\":\"GND\"}]}");
    try editStackupPlanesApi(&srv, request.req, request.res);
    try std.testing.expectEqual(@as(u16, 200), request.res.status);

    try std.testing.expectEqualStrings(split_design_src, try tmp.dir.readFileAlloc(std.testing.io, "src/bare.sexp", a, .limited(4096)));
    const sidecar_after = try tmp.dir.readFileAlloc(std.testing.io, "src/bare.layout.sexp", a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, sidecar_after, "(stackup 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, sidecar_after, "(plane 2 \"GND\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, sidecar_after, "(design-rules (clearance 0.15))") != null);
}

// spec: Web Server - A Design Settings save is refused with 409 naming both files only when the design really does declare the same singleton twice
test "design settings endpoint refuses the genuinely ambiguous two-file state" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src");
    const both = "(design-block \"Both\"\n  (design-rules (clearance 0.1)))\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/both.sexp", .data = both });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/both.layout.sexp",
        .data = "(design-rules (clearance 0.2))\n",
    });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var state = serve_root.ServerState{};
    var srv = Server{ .allocator = a, .project_dir = root, .auth_dir = root, .state = &state };

    var request = httpz.testing.init(.{});
    defer request.deinit();
    request.param("name", "both");
    request.body("{\"rules\":{\"clearance\":0.3}}");
    try editDesignRulesApi(&srv, request.req, request.res);
    try std.testing.expectEqual(@as(u16, 409), request.res.status);
    try std.testing.expect(std.mem.indexOf(u8, request.res.body, "both.sexp") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.res.body, "both.layout.sexp") != null);
    // Neither file was touched.
    try std.testing.expectEqualStrings(both, try tmp.dir.readFileAlloc(std.testing.io, "src/both.sexp", a, .limited(4096)));
}
