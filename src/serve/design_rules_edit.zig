//! Surgical board design-rule editing for the PCB Design Settings drawer.
//! The endpoint changes only named children of `(design-rules …)`, preserving
//! comments, ordering, and any forms this GUI does not understand.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const paths = @import("../paths.zig");
const serve_root = @import("../serve.zig");
const edit = @import("edit.zig");

const Server = serve_root.Server;
const max_source_bytes: usize = 10 * 1024 * 1024;

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

fn designRulesSpan(source: []const u8) ?Span {
    const open = std.mem.indexOf(u8, source, "(design-block") orelse return null;
    const block = Span{ .start = open, .end = formEnd(source, open) orelse return null };
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
