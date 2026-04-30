//! Component introspection for the MCP `describe_component` tool. Parses a
//! `lib/components/<name>.sexp` plus its referenced `lib/pinouts/<ref>.sexp`
//! and emits a single JSON document covering: kind (component vs family),
//! footprint, datasheets, pins (with optional alt-functions), and every
//! `(requirement ...)` form (text + datasheet ref + machine-check kind).
//!
//! Why this exists: agents reaching for "what pins does U1 have, and what
//! datasheet rules govern its placement" previously had to chain
//! read_file calls (component → pinout) and then guess the parser shape.
//! `describe_component` collapses that into one call and uses the same
//! `parseCheck` machinery the evaluator runs at build time, so the
//! check-kind labels stay in sync with what the review actually verifies.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const sexpr_parser = @import("../sexpr/parser.zig");
const ast = @import("../sexpr/ast.zig");
const env_mod = @import("../eval/env.zig");

const MAX_COMPONENT_BYTES: usize = 1 * 1024 * 1024;

const ERR_COMPONENT_NOT_FOUND = "component not found";
const ERR_COMPONENT_PARSE = "component parse failed";

/// Error set for `describeComponent`. Combines allocator/JSON-writer errors
/// (we synthesize JSON ourselves) with file I/O — a real I/O failure bubbles
/// up to the caller, while user-facing errors (component missing, malformed
/// component file) get JSON-encoded into `out` and the function returns false.
pub const DescribeError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    std.fs.File.OpenError || std.fs.File.ReadError ||
    std.fs.Dir.StatFileError || error{ FileTooBig, StreamTooLong };

/// Read `lib/components/<name>.sexp`, parse it, follow its `(pinout ...)`
/// reference into `lib/pinouts/<ref>.sexp`, and emit the combined view as
/// JSON to `out`. Returns `true` on success; on user-facing errors writes
/// `{"ok":false,"error":"..."}` and returns `false`.
pub fn describeComponent(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    out: *std.ArrayListUnmanaged(u8),
) DescribeError!bool {
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\\") != null or std.mem.indexOf(u8, name, "..") != null) {
        return writeJsonError(allocator, out, "invalid component name");
    }

    const comp_path = try std.fmt.allocPrint(allocator, "{s}/lib/components/{s}.sexp", .{ project_dir, name });
    defer allocator.free(comp_path);
    const comp_src = infra_fs.cwd().readFileAlloc(allocator, comp_path, MAX_COMPONENT_BYTES) catch |e| switch (e) {
        error.FileNotFound => return writeJsonError(allocator, out, ERR_COMPONENT_NOT_FOUND),
        else => return e,
    };
    defer allocator.free(comp_src);

    const comp_nodes = sexpr_parser.parse(allocator, comp_src) catch {
        return writeJsonError(allocator, out, ERR_COMPONENT_PARSE);
    };
    defer sexpr_parser.freeNodes(allocator, comp_nodes);

    if (comp_nodes.len == 0) return writeJsonError(allocator, out, ERR_COMPONENT_PARSE);
    const root = comp_nodes[0];
    const root_children = root.asList() orelse return writeJsonError(allocator, out, ERR_COMPONENT_PARSE);
    if (root_children.len < 2) return writeJsonError(allocator, out, ERR_COMPONENT_PARSE);

    const head = root_children[0].asAtom() orelse return writeJsonError(allocator, out, ERR_COMPONENT_PARSE);
    const is_family = std.mem.eql(u8, head, "component-family");
    if (!is_family and !std.mem.eql(u8, head, "component")) {
        return writeJsonError(allocator, out, "not a component or component-family");
    }

    const declared_name = root_children[1].asString() orelse root_children[1].asAtom() orelse name;

    var info = ComponentInfo{ .name = declared_name, .is_family = is_family };
    var datasheets: std.ArrayListUnmanaged([]const u8) = .empty;
    defer datasheets.deinit(allocator);

    for (root_children[2..]) |child| {
        try collectComponentField(allocator, child, &info, &datasheets);
    }

    // Resolve pinout: prefer explicit `(pinout "ref")`, fall back to component name.
    const pinout_ref: []const u8 = if (info.pinout_ref.len > 0) info.pinout_ref else name;
    const loaded = loadPinoutWithSource(allocator, project_dir, pinout_ref) catch |e| switch (e) {
        error.FileNotFound => LoadedPinout{ .pins = null, .source = null },
        else => return e,
    };
    defer freeLoadedPinout(allocator, loaded);

    const w = out.writer(allocator);
    try writeComponentJson(w, name, info, datasheets.items, loaded, root_children[2..]);
    return true;
}

const LoadedPinout = struct {
    pins: ?[]PinEntry,
    source: ?[]u8,
};

fn freeLoadedPinout(allocator: std.mem.Allocator, lp: LoadedPinout) void {
    if (lp.pins) |pe| {
        for (pe) |p| {
            allocator.free(p.id);
            allocator.free(p.function);
            for (p.alts) |a| {
                allocator.free(a.name);
                allocator.free(a.kind);
            }
            allocator.free(p.alts);
        }
        allocator.free(pe);
    }
    if (lp.source) |s| allocator.free(s);
}

/// Read the pinout file, parse pin entries, AND scan for the optional
/// `;; source: <path>` header line that `regenerate_pinout` injects. The
/// source path lets `describe_component` callers fix wrong pin names by
/// editing the upstream `.kicad_sym` and re-running `regenerate_pinout`.
fn loadPinoutWithSource(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    ref: []const u8,
) !LoadedPinout {
    const path = try std.fmt.allocPrint(allocator, "{s}/lib/pinouts/{s}.sexp", .{ project_dir, ref });
    defer allocator.free(path);
    const src = try infra_fs.cwd().readFileAlloc(allocator, path, MAX_COMPONENT_BYTES);
    defer allocator.free(src);

    const source = try findSourceComment(allocator, src);
    const pins = try parsePinoutBody(allocator, src);
    return .{ .pins = pins, .source = source };
}

const ComponentInfo = struct {
    name: []const u8,
    is_family: bool,
    description: []const u8 = "",
    footprint: []const u8 = "",
    pinout_ref: []const u8 = "",
    symbol_ref: []const u8 = "",
    manufacturer: []const u8 = "",
    mpn: []const u8 = "",
};

fn collectComponentField(
    allocator: std.mem.Allocator,
    child: ast.Node,
    info: *ComponentInfo,
    datasheets: *std.ArrayListUnmanaged([]const u8),
) !void {
    const cl = child.asList() orelse return;
    if (cl.len < 2) return;
    const tag = cl[0].asAtom() orelse return;
    if (std.mem.eql(u8, tag, "description")) {
        info.description = cl[1].asString() orelse cl[1].asAtom() orelse "";
    } else if (std.mem.eql(u8, tag, "footprint")) {
        info.footprint = cl[1].asString() orelse cl[1].asAtom() orelse "";
    } else if (std.mem.eql(u8, tag, "pinout")) {
        info.pinout_ref = cl[1].asString() orelse cl[1].asAtom() orelse "";
    } else if (std.mem.eql(u8, tag, "symbol")) {
        info.symbol_ref = cl[1].asString() orelse cl[1].asAtom() orelse "";
    } else if (std.mem.eql(u8, tag, "manufacturer")) {
        info.manufacturer = cl[1].asString() orelse cl[1].asAtom() orelse "";
    } else if (std.mem.eql(u8, tag, "mpn")) {
        info.mpn = cl[1].asString() orelse cl[1].asAtom() orelse "";
    } else if (std.mem.eql(u8, tag, "datasheet")) {
        const v = cl[1].asString() orelse cl[1].asAtom() orelse return;
        try datasheets.append(allocator, v);
    }
}

const PinAlt = struct {
    name: []u8,
    kind: []u8,
};

const PinEntry = struct {
    id: []u8,
    function: []u8,
    alts: []PinAlt,
};

/// Scan the raw pinout source for a `;; source: <path>` comment line and
/// return the trimmed path. Comments are tokenizer-stripped at parse time,
/// so this has to be a byte-level scan over the original text. Returns
/// allocator-owned slice or null if the comment is absent.
fn findSourceComment(allocator: std.mem.Allocator, src: []const u8) !?[]u8 {
    const marker = ";; source:";
    const idx = std.mem.indexOf(u8, src, marker) orelse return null;
    var end = std.mem.indexOfScalarPos(u8, src, idx, '\n') orelse src.len;
    var start = idx + marker.len;
    // Trim leading whitespace and trailing CR/whitespace.
    while (start < end and (src[start] == ' ' or src[start] == '\t')) start += 1;
    while (end > start and (src[end - 1] == ' ' or src[end - 1] == '\t' or src[end - 1] == '\r')) end -= 1;
    if (end <= start) return null;
    return try allocator.dupe(u8, src[start..end]);
}

/// Allocate the canonical string form of a pin id from one of three AST
/// shapes the pinout grammar admits: integer (`(pin 1 ...)`), atom
/// (`(pin K5 ...)`), or quoted string (`(pin "1" ...)`). Returns null when
/// the node isn't any of the three. Caller owns the returned slice.
fn extractPinId(allocator: std.mem.Allocator, node: ast.Node) !?[]u8 {
    if (node.asAtom()) |a| return try allocator.dupe(u8, a);
    if (node.asString()) |s| return try allocator.dupe(u8, s);
    switch (node.tag) {
        .int => |i| return try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| return try std.fmt.allocPrint(allocator, "{d}", .{f}),
        else => return null,
    }
}

/// Parse the body of a pinout file (skipping the comment header) into
/// `PinEntry` records. Caller owns the returned slice. Used by both
/// `describe_component`'s pinout loader and any future tool that wants the
/// machine-readable form rather than the raw `.sexp`.
fn parsePinoutBody(allocator: std.mem.Allocator, src: []const u8) !?[]PinEntry {
    const nodes = sexpr_parser.parse(allocator, src) catch {
        return null;
    };
    defer sexpr_parser.freeNodes(allocator, nodes);
    if (nodes.len == 0) return null;

    const root = nodes[0];
    const root_children = root.asList() orelse return null;
    if (root_children.len < 2) return null;
    const head = root_children[0].asAtom() orelse return null;
    if (!std.mem.eql(u8, head, "pinout")) return null;

    var pins: std.ArrayListUnmanaged(PinEntry) = .empty;
    errdefer {
        for (pins.items) |p| {
            allocator.free(p.id);
            allocator.free(p.function);
            for (p.alts) |a| {
                allocator.free(a.name);
                allocator.free(a.kind);
            }
            allocator.free(p.alts);
        }
        pins.deinit(allocator);
    }

    for (root_children[2..]) |pin_node| {
        const pc = pin_node.asList() orelse continue;
        if (pc.len < 3) continue;
        const ph = pc[0].asAtom() orelse continue;
        if (!std.mem.eql(u8, ph, "pin")) continue;

        // Pin IDs come in as bare integers (`(pin 1 ...)`), bare atoms
        // (`(pin K5 ...)`), or quoted strings — extractPinId normalises
        // all three to an allocator-owned string so the JSON output is
        // type-stable regardless of source encoding.
        const id_owned = (try extractPinId(allocator, pc[1])) orelse continue;
        errdefer allocator.free(id_owned);
        const fn_raw = pc[2].asString() orelse pc[2].asAtom() orelse {
            allocator.free(id_owned);
            continue;
        };

        var alts: std.ArrayListUnmanaged(PinAlt) = .empty;
        errdefer {
            for (alts.items) |a| {
                allocator.free(a.name);
                allocator.free(a.kind);
            }
            alts.deinit(allocator);
        }
        for (pc[3..]) |alt_node| {
            const al = alt_node.asList() orelse continue;
            if (al.len < 2) continue;
            const ah = al[0].asAtom() orelse continue;
            if (!std.mem.eql(u8, ah, "alt")) continue;
            const aname = al[1].asString() orelse al[1].asAtom() orelse continue;
            const akind = if (al.len >= 3) (al[2].asAtom() orelse al[2].asString() orelse "") else "";
            try alts.append(allocator, .{
                .name = try allocator.dupe(u8, aname),
                .kind = try allocator.dupe(u8, akind),
            });
        }

        try pins.append(allocator, .{
            .id = id_owned,
            .function = try allocator.dupe(u8, fn_raw),
            .alts = try alts.toOwnedSlice(allocator),
        });
    }

    return @as(?[]PinEntry, try pins.toOwnedSlice(allocator));
}

/// Emit the assembled component info as JSON. Pulls requirements straight
/// from the AST so the same `parseCheck` the evaluator uses classifies the
/// check kind — no risk of label drift between describe_component and the
/// build-time review.
fn writeComponentJson(
    w: anytype,
    requested_name: []const u8,
    info: ComponentInfo,
    datasheets: []const []const u8,
    loaded: LoadedPinout,
    root_body: []const ast.Node,
) !void {
    const pin_entries: ?[]const PinEntry = loaded.pins;
    try w.writeAll("{\"ok\":true,\"name\":");
    try writeJsonString(w, info.name);
    try w.writeAll(",\"requested_name\":");
    try writeJsonString(w, requested_name);
    try w.writeAll(",\"kind\":\"");
    try w.writeAll(if (info.is_family) "component-family" else "component");
    try w.writeAll("\",\"is_family\":");
    try w.writeAll(if (info.is_family) "true" else "false");
    try w.writeAll(",\"description\":");
    try writeJsonString(w, info.description);
    try w.writeAll(",\"footprint\":");
    try writeJsonString(w, info.footprint);
    try w.writeAll(",\"pinout_ref\":");
    try writeJsonString(w, info.pinout_ref);
    try w.writeAll(",\"pinout_source\":");
    if (loaded.source) |s| try writeJsonString(w, s) else try w.writeAll("null");
    try w.writeAll(",\"symbol_ref\":");
    try writeJsonString(w, info.symbol_ref);
    try w.writeAll(",\"manufacturer\":");
    try writeJsonString(w, info.manufacturer);
    try w.writeAll(",\"mpn\":");
    try writeJsonString(w, info.mpn);

    try w.writeAll(",\"datasheets\":[");
    for (datasheets, 0..) |d, i| {
        if (i > 0) try w.writeAll(",");
        try writeJsonString(w, d);
    }
    try w.writeAll("]");

    try w.writeAll(",\"pins\":");
    if (pin_entries) |pe| {
        try w.writeAll("[");
        for (pe, 0..) |p, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"id\":");
            try writeJsonString(w, p.id);
            try w.writeAll(",\"function\":");
            try writeJsonString(w, p.function);
            try w.writeAll(",\"alts\":[");
            for (p.alts, 0..) |a, ai| {
                if (ai > 0) try w.writeAll(",");
                try w.writeAll("{\"name\":");
                try writeJsonString(w, a.name);
                try w.writeAll(",\"kind\":");
                try writeJsonString(w, a.kind);
                try w.writeAll("}");
            }
            try w.writeAll("]}");
        }
        try w.writeAll("]");
    } else {
        try w.writeAll("null");
    }

    try w.writeAll(",\"requirements\":[");
    var req_first = true;
    for (root_body) |child| {
        if (!child.isForm("requirement")) continue;
        const cl = child.asList() orelse continue;
        if (cl.len < 2) continue;
        if (!req_first) try w.writeAll(",");
        req_first = false;
        try writeRequirementJson(w, cl);
    }
    try w.writeAll("]}");
}

fn writeRequirementJson(w: anytype, cl: []const ast.Node) !void {
    const text = if (cl.len >= 2) (cl[1].asString() orelse cl[1].asAtom() orelse "") else "";
    try w.writeAll("{\"text\":");
    try writeJsonString(w, text);

    var ref_pdf: []const u8 = "";
    var ref_page: u32 = 0;
    var ref_quote: []const u8 = "";
    var check: ?env_mod.Check = null;

    for (cl[2..]) |sub| {
        if (sub.isForm("ref")) {
            const ref = env_mod.parseNoteRef(sub) orelse continue;
            ref_pdf = ref.pdf;
            ref_page = ref.page;
            if (ref.quote) |q| ref_quote = q;
        } else if (sub.isForm("check")) {
            if (env_mod.parseCheck(sub)) |c| check = c;
        }
    }

    try w.writeAll(",\"ref\":");
    if (ref_pdf.len == 0) {
        try w.writeAll("null");
    } else {
        try w.writeAll("{\"pdf\":");
        try writeJsonString(w, ref_pdf);
        try w.print(",\"page\":{d}", .{ref_page});
        try w.writeAll(",\"quote\":");
        if (ref_quote.len == 0) try w.writeAll("null") else try writeJsonString(w, ref_quote);
        try w.writeAll("}");
    }
    try w.writeAll(",\"check_kind\":");
    if (check) |c| {
        try w.writeAll("\"");
        try writeCheckKindName(w, c);
        try w.writeAll("\"");
    } else {
        try w.writeAll("null");
    }
    try w.writeAll("}");
}

/// Render the kebab-case form of a `Check` variant tag, matching the form
/// used in `.sexp` source (`pullup-range`, not `pullup_range`). Uses
/// `@tagName` so adding a new check primitive requires only one edit
/// (in `env.zig`) — this function picks it up automatically.
fn writeCheckKindName(w: anytype, c: env_mod.Check) !void {
    const tag = @tagName(c);
    for (tag) |ch| {
        try w.writeByte(if (ch == '_') '-' else ch);
    }
}

fn writeJsonError(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), msg: []const u8) !bool {
    out.clearRetainingCapacity();
    const w = out.writer(allocator);
    try w.writeAll("{\"ok\":false,\"error\":");
    try writeJsonString(w, msg);
    try w.writeAll("}");
    return false;
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeAll("\"");
}

// ── Tests ─────────────────────────────────────────────────────────────

test "parsePinoutBody handles integer, atom, and string pin IDs" {
    // spec: serve/component_info - parsePinoutBody normalises pin ID shapes
    const alloc = std.testing.allocator;
    const sample =
        "(pinout \"x\"\n" ++
        "  (pin 1 \"VPOS1\")\n" ++
        "  (pin K5 \"VLXSMP\")\n" ++
        "  (pin \"A1\" \"GND\")\n" ++
        ")\n";
    const pins_opt = try parsePinoutBody(alloc, sample);
    const pins = pins_opt.?;
    defer {
        for (pins) |p| {
            alloc.free(p.id);
            alloc.free(p.function);
            for (p.alts) |a| {
                alloc.free(a.name);
                alloc.free(a.kind);
            }
            alloc.free(p.alts);
        }
        alloc.free(pins);
    }
    try std.testing.expectEqual(@as(usize, 3), pins.len);
    try std.testing.expectEqualStrings("1", pins[0].id);
    try std.testing.expectEqualStrings("K5", pins[1].id);
    try std.testing.expectEqualStrings("A1", pins[2].id);
}

test "findSourceComment extracts the regenerate_pinout source line" {
    // spec: serve/component_info - findSourceComment finds the source-of-truth path
    const alloc = std.testing.allocator;
    const sample =
        ";; source: lib/sources/foo.kicad_sym\r\n" ++
        ";; Auto-generated pinout — DO NOT EDIT\n" ++
        "(pinout \"foo\" (pin 1 \"VPOS1\"))\n";
    const result = (try findSourceComment(alloc, sample)).?;
    defer alloc.free(result);
    try std.testing.expectEqualStrings("lib/sources/foo.kicad_sym", result);

    const without = "(pinout \"bar\")";
    try std.testing.expect((try findSourceComment(alloc, without)) == null);
}

test "writeCheckKindName dasherizes underscored variant names" {
    // spec: serve/component_info - kebab-cases every Check variant tag
    const alloc = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    const w = buf.writer(alloc);
    const variants = [_]env_mod.Check{
        .{ .connected = .{ .pin_a = "A", .pin_b = "B" } },
        .{ .pullup_range = .{ .pin = "P", .target_net = "N", .min_ohms = 0, .max_ohms = 1 } },
        .{ .pin_not_floating = .{ .pin = "P" } },
    };
    try writeCheckKindName(w, variants[0]);
    try w.writeByte(',');
    try writeCheckKindName(w, variants[1]);
    try w.writeByte(',');
    try writeCheckKindName(w, variants[2]);
    try std.testing.expectEqualStrings("connected,pullup-range,pin-not-floating", buf.items);
}
