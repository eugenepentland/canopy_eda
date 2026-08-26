//! Surgical board-rule and stackup-plane editing for the PCB Design Settings
//! drawer. The endpoints change only the source forms they own, preserving
//! comments, ordering, construction details, and forms the GUI does not know.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const paths = @import("../paths.zig");
const serve_root = @import("../serve.zig");
const edit = @import("edit.zig");

const Server = serve_root.Server;
const max_source_bytes: usize = 10 * 1024 * 1024;

const PlaneAssignment = struct {
    index: u8,
    net: []const u8,
};

const Rule = struct {
    key: []const u8,
    head: []const u8,
};

const scalar_rules = [_]Rule{
    .{ .key = "clearance", .head = "clearance" },
    .{ .key = "track_width", .head = "track-width" },
    .{ .key = "min_width", .head = "min-width" },
    .{ .key = "min_drill", .head = "min-drill" },
    .{ .key = "min_annular", .head = "min-annular" },
    .{ .key = "hole_to_hole", .head = "hole-to-hole" },
    .{ .key = "via_to_via", .head = "via-to-via" },
    .{ .key = "via_plating", .head = "via-plating" },
    .{ .key = "copper_edge", .head = "copper-edge" },
    .{ .key = "component_edge", .head = "component-edge" },
    .{ .key = "pour_clearance", .head = "pour-clearance" },
    .{ .key = "pour_min_width", .head = "pour-min-width" },
    .{ .key = "pour_corner_radius", .head = "pour-corner-radius" },
    .{ .key = "ground_via_max", .head = "ground-via-max" },
    .{ .key = "mask_margin", .head = "mask-margin" },
    .{ .key = "mask_relief_corner_radius", .head = "mask-relief-corner-radius" },
    .{ .key = "mask_web", .head = "mask-web" },
};

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

fn skipStringOrComment(source: []const u8, cursor: *usize, limit: usize) void {
    if (source[cursor.*] == ';') {
        while (cursor.* < limit and source[cursor.*] != '\n') cursor.* += 1;
        return;
    }
    cursor.* += 1;
    while (cursor.* < limit and source[cursor.*] != '"') : (cursor.* += 1) {
        if (source[cursor.*] == '\\' and cursor.* + 1 < limit) cursor.* += 1;
    }
    if (cursor.* < limit) cursor.* += 1;
}

fn formEnd(source: []const u8, open: usize) ?usize {
    var cursor = open;
    var depth: usize = 0;
    while (cursor < source.len) {
        const ch = source[cursor];
        if (ch == '"' or ch == ';') {
            skipStringOrComment(source, &cursor, source.len);
            continue;
        }
        if (ch == '(') depth += 1;
        if (ch == ')') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return cursor + 1;
        }
        cursor += 1;
    }
    return null;
}

fn formHead(source: []const u8, open: usize, end: usize) []const u8 {
    var cursor = open + 1;
    while (cursor < end and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
    const start = cursor;
    while (cursor < end and !headEnd(source[cursor])) : (cursor += 1) {}
    return source[start..cursor];
}

fn headEnd(ch: u8) bool {
    return std.ascii.isWhitespace(ch) or ch == '(' or ch == ')';
}

const Span = struct { start: usize, end: usize };

fn directChild(source: []const u8, parent: Span, head: []const u8) ?Span {
    var cursor = parent.start + 1;
    var depth: usize = 0;
    while (cursor + 1 < parent.end) {
        const ch = source[cursor];
        if (ch == '"' or ch == ';') {
            skipStringOrComment(source, &cursor, parent.end);
            continue;
        }
        if (ch == '(') {
            if (depth == 0) {
                const end = formEnd(source, cursor) orelse return null;
                if (end > parent.end) return null;
                if (std.mem.eql(u8, formHead(source, cursor, end), head)) return .{ .start = cursor, .end = end };
                cursor = end;
                continue;
            }
            depth += 1;
        } else if (ch == ')') {
            if (depth == 0) break;
            depth -= 1;
        }
        cursor += 1;
    }
    return null;
}

fn replaceSpan(allocator: std.mem.Allocator, source: []const u8, span: Span, replacement: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    try out.writer.writeAll(source[0..span.start]);
    try out.writer.writeAll(replacement);
    try out.writer.writeAll(source[span.end..]);
    return out.toOwnedSlice();
}

fn designBlockSpan(source: []const u8) ?Span {
    const open = std.mem.indexOf(u8, source, "(design-block") orelse return null;
    return .{ .start = open, .end = formEnd(source, open) orelse return null };
}

fn designRulesSpan(source: []const u8) ?Span {
    const block = designBlockSpan(source) orelse return null;
    return directChild(source, block, "design-rules");
}

fn addDesignRules(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const open = std.mem.indexOf(u8, source, "(design-block") orelse return error.MalformedSource;
    const end = formEnd(source, open) orelse return error.MalformedSource;
    return replaceSpan(allocator, source, .{ .start = end - 1, .end = end - 1 }, "\n\n  (design-rules)\n");
}

fn patchForm(allocator: std.mem.Allocator, source: []const u8, head: []const u8, args: []const u8) ![]u8 {
    var owned_source: ?[]u8 = null;
    defer if (owned_source) |owned| allocator.free(owned);
    const rules = designRulesSpan(source) orelse blk: {
        owned_source = try addDesignRules(allocator, source);
        break :blk designRulesSpan(owned_source.?) orelse return error.MalformedSource;
    };
    const working = owned_source orelse source;
    const replacement = try std.fmt.allocPrint(allocator, "({s} {s})", .{ head, args });
    defer allocator.free(replacement);
    if (directChild(working, rules, head)) |child|
        return replaceSpan(allocator, working, child, replacement);

    const insertion = try std.fmt.allocPrint(allocator, "\n    {s}", .{replacement});
    defer allocator.free(insertion);
    return replaceSpan(allocator, working, .{ .start = rules.end - 1, .end = rules.end - 1 }, insertion);
}

fn patchScalar(allocator: std.mem.Allocator, source: []const u8, rule: Rule, value: f64) ![]u8 {
    const args = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(args);
    return patchForm(allocator, source, rule.head, args);
}

fn patchVia(allocator: std.mem.Allocator, source: []const u8, dia: f64, drill: f64) ![]u8 {
    const args = try std.fmt.allocPrint(allocator, "{d} {d}", .{ dia, drill });
    defer allocator.free(args);
    return patchForm(allocator, source, "via", args);
}

fn patchRules(allocator: std.mem.Allocator, source: []const u8, rules: std.json.ObjectMap) ![]u8 {
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
        const next = try patchScalar(allocator, current, rule, value);
        allocator.free(current);
        current = next;
        changed = true;
    }
    if (via_dia != null or via_drill != null) {
        if (via_dia == null or via_drill == null or via_drill.? > via_dia.?) return error.InvalidVia;
        const next = try patchVia(allocator, current, via_dia.?, via_drill.?);
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

fn writePlaneForms(w: *std.Io.Writer, planes: []const PlaneAssignment) !void {
    for (planes) |plane| {
        try w.print("    (plane {d} ", .{plane.index});
        try writeSexprString(w, plane.net);
        try w.writeAll(")\n");
    }
}

/// Replace only a stackup's electrical roles. Physical copper/dielectric
/// construction, preset selection, thickness, comments, and ordering remain
/// byte-for-byte. With no authored stackup, saving the visible implicit model
/// makes it explicit as `(stackup N …)` so add/delete has durable semantics.
fn patchStackupPlanes(
    allocator: std.mem.Allocator,
    source: []const u8,
    layers: u8,
    planes: []const PlaneAssignment,
) ![]u8 {
    const block = designBlockSpan(source) orelse return error.MalformedSource;
    const stackup = directChild(source, block, "stackup") orelse {
        var replacement: std.Io.Writer.Allocating = .init(allocator);
        errdefer replacement.deinit();
        try replacement.writer.print("\n\n  (stackup {d}\n", .{layers});
        try writePlaneForms(&replacement.writer, planes);
        try replacement.writer.writeAll("  )\n");
        const owned = try replacement.toOwnedSlice();
        defer allocator.free(owned);
        return replaceSpan(allocator, source, .{ .start = block.end - 1, .end = block.end - 1 }, owned);
    };
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
    try writePlaneForms(&out.writer, planes);
    try out.writer.writeAll("  ");
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

    const path = paths.designSourcePath(ctx.allocator, ctx.project_dir, name) catch
        return jsonError(res, 404, "{\"error\":\"design source not found\"}");
    defer ctx.allocator.free(path);
    const source = infra_fs.cwd().readFileAlloc(ctx.allocator, path, max_source_bytes) catch
        return jsonError(res, 404, "{\"error\":\"cannot read design source\"}");
    defer ctx.allocator.free(source);
    const updated = patchRules(ctx.allocator, source, values.object) catch |err| {
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
    const result = edit.writeAndRebuild(ctx.allocator, ctx.project_dir, name, updated, "edit design rules from PCB settings") catch
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

    const path = paths.designSourcePath(ctx.allocator, ctx.project_dir, name) catch
        return jsonError(res, 404, "{\"error\":\"design source not found\"}");
    defer ctx.allocator.free(path);
    const source = infra_fs.cwd().readFileAlloc(ctx.allocator, path, max_source_bytes) catch
        return jsonError(res, 404, "{\"error\":\"cannot read design source\"}");
    defer ctx.allocator.free(source);
    const updated = patchStackupPlanes(ctx.allocator, source, layers, planes) catch |err| {
        const message = switch (err) {
            error.MalformedSource => "{\"error\":\"malformed design-block or stackup\"}",
            else => "{\"error\":\"could not update whole-layer planes\"}",
        };
        return jsonError(res, 400, message);
    };
    defer ctx.allocator.free(updated);
    const result = edit.writeAndRebuild(ctx.allocator, ctx.project_dir, name, updated, "edit whole-layer copper planes from PCB settings") catch
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
    const got = try patchRules(a, source, parsed.value.object);
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
    const got = try patchRules(a, "(design-block \"board\"\n  (section \"RF\"))\n", parsed.value.object);
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
    const got = try patchStackupPlanes(a, source, 4, &planes);
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
    const authored = try patchStackupPlanes(a, source, 4, &initial);
    defer a.free(authored);
    try std.testing.expect(std.mem.indexOf(u8, authored, "(stackup 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, authored, "(plane 2 \"GND\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, authored, "(plane 3 \"V_SUPPLY\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, authored, "(section \"Power\")") != null);

    const cleared = try patchStackupPlanes(a, authored, 4, &.{});
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
    const got = try patchStackupPlanes(a, "(design-block \"b\")", 4, &planes);
    defer a.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "(plane 2 \"rail\\\\\\\"name\")") != null);
}
