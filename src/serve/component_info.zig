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
const json_writer = @import("../json_writer.zig");
const infra_fs = @import("../infra/fs.zig");
const sexpr_parser = @import("../sexpr/parser.zig");
const ast = @import("../sexpr/ast.zig");
const env_mod = @import("../eval/env.zig");
const check_grammar = @import("../eval/check_grammar.zig");

const max_component_bytes: usize = 1 * 1024 * 1024;

const err_component_not_found = "component not found";
const err_component_parse = "component parse failed";
const err_invalid_name = "invalid component name";
const form_component = "component";
const form_component_family = "component-family";
const form_requirement = "requirement";

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
    out: *std.ArrayList(u8),
) DescribeError!bool {
    if (!validComponentName(name)) {
        return writeJsonError(allocator, out, err_invalid_name);
    }

    const comp_path = try componentPath(allocator, project_dir, name);
    defer allocator.free(comp_path);
    const comp_src = infra_fs.cwd().readFileAlloc(allocator, comp_path, max_component_bytes) catch |e| switch (e) {
        error.FileNotFound => return writeJsonError(allocator, out, err_component_not_found),
        else => return e,
    };
    defer allocator.free(comp_src);

    const comp_nodes = sexpr_parser.parse(allocator, comp_src) catch {
        return writeJsonError(allocator, out, err_component_parse);
    };
    defer sexpr_parser.freeNodes(allocator, comp_nodes);

    if (comp_nodes.len == 0) return writeJsonError(allocator, out, err_component_parse);
    const root = comp_nodes[0];
    const root_children = root.asList() orelse return writeJsonError(allocator, out, err_component_parse);
    if (root_children.len < 2) return writeJsonError(allocator, out, err_component_parse);

    const head = root_children[0].asAtom() orelse return writeJsonError(allocator, out, err_component_parse);
    const is_family = std.mem.eql(u8, head, form_component_family);
    if (!is_family and !std.mem.eql(u8, head, form_component)) {
        return writeJsonError(allocator, out, "not a component or component-family");
    }

    const declared_name = root_children[1].asString() orelse root_children[1].asAtom() orelse name;

    var info = ComponentInfo{ .name = declared_name, .is_family = is_family };
    var datasheets: std.ArrayList([]const u8) = .empty;
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
    try writeComponentJson(allocator, w, name, info, datasheets.items, loaded, root_children[2..]);
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
    const src = try infra_fs.cwd().readFileAlloc(allocator, path, max_component_bytes);
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
    datasheets: *std.ArrayList([]const u8),
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

    var pins: std.ArrayList(PinEntry) = .empty;
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

        var alts: std.ArrayList(PinAlt) = .empty;
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
    allocator: std.mem.Allocator,
    w: anytype,
    requested_name: []const u8,
    info: ComponentInfo,
    datasheets: []const []const u8,
    loaded: LoadedPinout,
    root_body: []const ast.Node,
) !void {
    const pin_entries: ?[]const PinEntry = loaded.pins;
    try w.writeAll("{\"ok\":true,\"name\":");
    try json_writer.writeString(w, info.name);
    try w.writeAll(",\"requested_name\":");
    try json_writer.writeString(w, requested_name);
    try w.writeAll(",\"kind\":\"");
    try w.writeAll(if (info.is_family) form_component_family else form_component);
    try w.writeAll("\",\"is_family\":");
    try w.writeAll(if (info.is_family) "true" else "false");
    try w.writeAll(",\"description\":");
    try json_writer.writeString(w, info.description);
    try w.writeAll(",\"footprint\":");
    try json_writer.writeString(w, info.footprint);
    try w.writeAll(",\"pinout_ref\":");
    try json_writer.writeString(w, info.pinout_ref);
    try w.writeAll(",\"pinout_source\":");
    if (loaded.source) |s| try json_writer.writeString(w, s) else try w.writeAll("null");
    try w.writeAll(",\"symbol_ref\":");
    try json_writer.writeString(w, info.symbol_ref);
    try w.writeAll(",\"manufacturer\":");
    try json_writer.writeString(w, info.manufacturer);
    try w.writeAll(",\"mpn\":");
    try json_writer.writeString(w, info.mpn);

    try w.writeAll(",\"datasheets\":[");
    for (datasheets, 0..) |d, i| {
        if (i > 0) try w.writeAll(",");
        try json_writer.writeString(w, d);
    }
    try w.writeAll("]");

    try w.writeAll(",\"pins\":");
    if (pin_entries) |pe| {
        try w.writeAll("[");
        for (pe, 0..) |p, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"id\":");
            try json_writer.writeString(w, p.id);
            try w.writeAll(",\"function\":");
            try json_writer.writeString(w, p.function);
            try w.writeAll(",\"alts\":[");
            for (p.alts, 0..) |a, ai| {
                if (ai > 0) try w.writeAll(",");
                try w.writeAll("{\"name\":");
                try json_writer.writeString(w, a.name);
                try w.writeAll(",\"kind\":");
                try json_writer.writeString(w, a.kind);
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
        if (!child.isForm(form_requirement)) continue;
        const cl = child.asList() orelse continue;
        if (cl.len < 2) continue;
        if (!req_first) try w.writeAll(",");
        req_first = false;
        try writeRequirementJson(allocator, w, cl);
    }
    try w.writeAll("]}");
}

fn writeRequirementJson(allocator: std.mem.Allocator, w: anytype, cl: []const ast.Node) !void {
    const text = if (cl.len >= 2) (cl[1].asString() orelse cl[1].asAtom() orelse "") else "";
    try w.writeAll("{\"id\":");
    var id_buf: [8]u8 = undefined;
    try json_writer.writeString(w, requirementId(cl, &id_buf));
    try w.writeAll(",\"text\":");
    try json_writer.writeString(w, text);

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
            if (check_grammar.parseCheck(allocator, sub)) |c| check = c;
        }
    }

    try w.writeAll(",\"ref\":");
    if (ref_pdf.len == 0) {
        try w.writeAll("null");
    } else {
        try w.writeAll("{\"pdf\":");
        try json_writer.writeString(w, ref_pdf);
        try w.print(",\"page\":{d}", .{ref_page});
        try w.writeAll(",\"quote\":");
        if (ref_quote.len == 0) try w.writeAll("null") else try json_writer.writeString(w, ref_quote);
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

fn writeJsonError(allocator: std.mem.Allocator, out: *std.ArrayList(u8), msg: []const u8) !bool {
    out.clearRetainingCapacity();
    const w = out.writer(allocator);
    try w.writeAll("{\"ok\":false,\"error\":");
    try json_writer.writeString(w, msg);
    try w.writeAll("}");
    return false;
}

// ── Requirement editing (list / add / remove) ─────────────────────────
//
// `(requirement ...)` forms live on the library component, not the design,
// so a rule added here is inherited by every design that instantiates the
// part. These three functions back the MCP tools of the same name. Writes
// splice the source text directly — rather than re-emitting the AST — so the
// hand-authored formatting and comments in the component file survive.

/// Error set for the requirement editors. Superset of the read-only
/// `DescribeError` plus the file-write errors the mutators incur. Kept
/// unexported — callers (mcp_tools) only ever propagate it via `!bool`.
const ReqError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    std.fs.File.OpenError || std.fs.File.ReadError || std.fs.File.WriteError ||
    std.fs.Dir.StatFileError || error{ FileTooBig, StreamTooLong };

fn validComponentName(name: []const u8) bool {
    return name.len > 0 and
        std.mem.indexOfAny(u8, name, "/\\") == null and
        std.mem.indexOf(u8, name, "..") == null;
}

fn componentPath(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/lib/components/{s}.sexp", .{ project_dir, name });
}

/// Validate `nodes` is a single `(component ...)` / `(component-family ...)`
/// form and return its body (children after the declared name). On any
/// structural problem, writes a JSON error into `out` and returns null.
fn componentRootBody(nodes: []const ast.Node, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !?[]const ast.Node {
    if (nodes.len == 0) {
        _ = try writeJsonError(allocator, out, err_component_parse);
        return null;
    }
    const rc = nodes[0].asList() orelse {
        _ = try writeJsonError(allocator, out, err_component_parse);
        return null;
    };
    if (rc.len < 2) {
        _ = try writeJsonError(allocator, out, err_component_parse);
        return null;
    }
    const head = rc[0].asAtom() orelse {
        _ = try writeJsonError(allocator, out, err_component_parse);
        return null;
    };
    if (!std.mem.eql(u8, head, form_component) and !std.mem.eql(u8, head, form_component_family)) {
        _ = try writeJsonError(allocator, out, "not a component or component-family");
        return null;
    }
    return rc[2..];
}

/// The requirement's id: an explicit `(id ...)` sub-form if present, else the
/// Crc32 of the requirement text — matching `env.requirementIdForText` so the
/// value is the same one a `(verifies (req ...))` form references. An explicit
/// id is returned as a slice into the AST; the derived id is written into
/// `buf` and returned as a slice of it.
fn requirementId(cl: []const ast.Node, buf: *[8]u8) []const u8 {
    for (cl[2..]) |sub| {
        if (!sub.isForm("id")) continue;
        const sl = sub.asList() orelse continue;
        if (sl.len < 2) continue;
        const explicit = sl[1].asAtom() orelse sl[1].asString() orelse continue;
        if (explicit.len > 0) return explicit;
    }
    const text = if (cl.len >= 2) (cl[1].asString() orelse cl[1].asAtom() orelse "") else "";
    var hasher = std.hash.Crc32.init();
    hasher.update(text);
    return std.fmt.bufPrint(buf, "{x:0>8}", .{hasher.final()}) catch buf[0..0];
}

fn requirementIdMatches(cl: []const ast.Node, target: []const u8) bool {
    var buf: [8]u8 = undefined;
    return std.mem.eql(u8, requirementId(cl, &buf), target);
}

/// True if requirement `cl`'s stored text equals `plain` once `plain` is
/// escaped the same way the stored value is (the AST keeps source escapes).
fn requirementTextMatches(allocator: std.mem.Allocator, cl: []const ast.Node, plain: []const u8) bool {
    const stored = if (cl.len >= 2) (cl[1].asString() orelse cl[1].asAtom() orelse "") else "";
    var esc: std.ArrayList(u8) = .empty;
    defer esc.deinit(allocator);
    writeSexprEscaped(esc.writer(allocator), plain) catch return false;
    return std.mem.eql(u8, stored, esc.items);
}

/// Write `s` escaped for an S-expression string literal (only `"` and `\`
/// need escaping; the tokenizer treats everything else verbatim).
fn writeSexprEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
}

/// Parse-and-validate a `(check ...)` clause with the same machinery the
/// build uses, so an unrecognized check is rejected before it reaches a file.
fn checkClauseValid(allocator: std.mem.Allocator, cs: []const u8) bool {
    const nodes = sexpr_parser.parse(allocator, cs) catch return false;
    defer sexpr_parser.freeNodes(allocator, nodes);
    if (nodes.len != 1) return false;
    if (!nodes[0].isForm("check")) return false;
    return check_grammar.parseCheck(allocator, nodes[0]) != null;
}

/// Byte index of the `)` that closes the top-level form — the last `)` in
/// `src`, since a component file holds one form. Returns null if the last
/// non-whitespace byte isn't `)`.
fn lastParenIndex(src: []const u8) ?usize {
    var i = src.len;
    while (i > 0) {
        i -= 1;
        switch (src[i]) {
            ' ', '\t', '\r', '\n' => continue,
            ')' => return i,
            else => return null,
        }
    }
    return null;
}

/// Byte index one past the `)` closing the list that begins at `start` (where
/// `src[start] == '('`). Respects string literals and `\` escapes so parens
/// inside requirement text don't skew the count. Returns null if unbalanced.
fn formEnd(src: []const u8, start: usize) ?usize {
    var depth: i32 = 0;
    var in_str = false;
    var i = start;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (in_str) {
            if (c == '\\') {
                i += 1;
                continue;
            }
            if (c == '"') in_str = false;
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return null;
}

/// Insert `form` as the final child of the component, just before its closing
/// paren, preserving existing formatting. Returns null if there is no `)`.
/// Caller owns the result.
fn spliceRequirement(allocator: std.mem.Allocator, src: []const u8, form: []const u8) !?[]u8 {
    const close = lastParenIndex(src) orelse return null;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, src[0..close]);
    try buf.appendSlice(allocator, "\n  ");
    try buf.appendSlice(allocator, form);
    try buf.appendSlice(allocator, src[close..]);
    return try buf.toOwnedSlice(allocator);
}

/// Delete the requirement form beginning at byte `start`, along with the
/// preceding newline + indentation so no blank line is left behind. When the
/// removed form was the last child, the component's trailing `)` (on the same
/// line) is preserved and reattaches to the prior line. Returns null if the
/// form is unbalanced. Caller owns the result.
fn removeFormSrc(allocator: std.mem.Allocator, src: []const u8, start: usize) !?[]u8 {
    const end = formEnd(src, start) orelse return null;
    const del_start = std.mem.lastIndexOfScalar(u8, src[0..start], '\n') orelse start;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, src[0..del_start]);
    try buf.appendSlice(allocator, src[end..]);
    return try buf.toOwnedSlice(allocator);
}

fn writeComponentFile(path: []const u8, contents: []const u8) !void {
    const file = try infra_fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(contents);
}

/// List the `(requirement ...)` forms on `lib/components/<name>.sexp`. Emits
/// `{ok:true, name, requirements:[{id, text, ref, check_kind}]}`.
pub fn listRequirements(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    out: *std.ArrayList(u8),
) ReqError!bool {
    if (!validComponentName(name)) return writeJsonError(allocator, out, err_invalid_name);
    const path = try componentPath(allocator, project_dir, name);
    defer allocator.free(path);
    const src = infra_fs.cwd().readFileAlloc(allocator, path, max_component_bytes) catch |e| switch (e) {
        error.FileNotFound => return writeJsonError(allocator, out, err_component_not_found),
        else => return e,
    };
    defer allocator.free(src);
    const nodes = sexpr_parser.parse(allocator, src) catch return writeJsonError(allocator, out, err_component_parse);
    defer sexpr_parser.freeNodes(allocator, nodes);
    const body = (try componentRootBody(nodes, allocator, out)) orelse return false;

    const w = out.writer(allocator);
    try w.writeAll("{\"ok\":true,\"name\":");
    try json_writer.writeString(w, name);
    try w.writeAll(",\"requirements\":[");
    var first = true;
    for (body) |child| {
        if (!child.isForm(form_requirement)) continue;
        const cl = child.asList() orelse continue;
        if (cl.len < 2) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try writeRequirementJson(allocator, w, cl);
    }
    try w.writeAll("]}");
    return true;
}

/// Append a `(requirement ...)` form to `lib/components/<name>.sexp`. The
/// optional `check_src` is a full `(check ...)` S-expression, validated before
/// writing. Rejects a duplicate (same derived id). Emits `{ok:true,id,text}`.
pub fn addRequirement(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    text: []const u8,
    ref_pdf: ?[]const u8,
    ref_page: ?u32,
    ref_quote: ?[]const u8,
    check_src: ?[]const u8,
    out: *std.ArrayList(u8),
) ReqError!bool {
    if (!validComponentName(name)) return writeJsonError(allocator, out, err_invalid_name);
    if (text.len == 0) return writeJsonError(allocator, out, "text must be a non-empty string");
    if (check_src) |cs| {
        if (cs.len > 0 and !checkClauseValid(allocator, cs)) {
            // Teach the vocabulary: list the accepted primitives (drawn from the
            // checker's own dispatch table, never a hardcoded copy) and point at
            // the language-reference section that documents each form's grammar.
            const msg = try std.fmt.allocPrint(
                allocator,
                "check must be a single (check …) form using one of the recognized primitives: {s}. " ++
                    "See the \"Requirement checks\" section of the language reference " ++
                    "(MCP get_language_reference, section \"Requirement checks\") for each form's syntax.",
                .{check_grammar.check_keyword_list},
            );
            defer allocator.free(msg);
            return writeJsonError(allocator, out, msg);
        }
    }

    const path = try componentPath(allocator, project_dir, name);
    defer allocator.free(path);
    const src = infra_fs.cwd().readFileAlloc(allocator, path, max_component_bytes) catch |e| switch (e) {
        error.FileNotFound => return writeJsonError(allocator, out, err_component_not_found),
        else => return e,
    };
    defer allocator.free(src);
    const nodes = sexpr_parser.parse(allocator, src) catch return writeJsonError(allocator, out, err_component_parse);
    defer sexpr_parser.freeNodes(allocator, nodes);
    const body = (try componentRootBody(nodes, allocator, out)) orelse return false;

    // Escaped inner text — what is stored between the quotes, and what the id
    // derives from (so it matches env.requirementIdForText downstream).
    var esc: std.ArrayList(u8) = .empty;
    defer esc.deinit(allocator);
    try writeSexprEscaped(esc.writer(allocator), text);
    var hasher = std.hash.Crc32.init();
    hasher.update(esc.items);
    const id_hex = try std.fmt.allocPrint(allocator, "{x:0>8}", .{hasher.final()});
    defer allocator.free(id_hex);

    for (body) |child| {
        if (!child.isForm(form_requirement)) continue;
        const cl = child.asList() orelse continue;
        if (cl.len < 2) continue;
        if (!requirementIdMatches(cl, id_hex)) continue;
        const msg = try std.fmt.allocPrint(allocator, "requirement already exists (id {s})", .{id_hex});
        defer allocator.free(msg);
        return writeJsonError(allocator, out, msg);
    }

    var form: std.ArrayList(u8) = .empty;
    defer form.deinit(allocator);
    const fw = form.writer(allocator);
    try fw.print("(requirement \"{s}\"", .{esc.items});
    if (ref_pdf) |pdf| {
        if (pdf.len > 0) {
            try fw.writeAll(" (ref \"");
            try writeSexprEscaped(fw, pdf);
            try fw.writeAll("\"");
            if (ref_page) |pg| try fw.print(" (page {d})", .{pg});
            if (ref_quote) |q| {
                if (q.len > 0) {
                    try fw.writeAll(" (quote \"");
                    try writeSexprEscaped(fw, q);
                    try fw.writeAll("\")");
                }
            }
            try fw.writeAll(")");
        }
    }
    if (check_src) |cs| {
        if (cs.len > 0) {
            try fw.writeByte(' ');
            try fw.writeAll(std.mem.trim(u8, cs, " \t\r\n"));
        }
    }
    try fw.writeAll(")");

    const new_src = (try spliceRequirement(allocator, src, form.items)) orelse
        return writeJsonError(allocator, out, "component file has no closing paren");
    defer allocator.free(new_src);
    try writeComponentFile(path, new_src);

    const w = out.writer(allocator);
    try w.writeAll("{\"ok\":true,\"id\":");
    try json_writer.writeString(w, id_hex);
    try w.writeAll(",\"text\":");
    try json_writer.writeString(w, text);
    try w.writeAll("}");
    return true;
}

/// Remove a `(requirement ...)` form from `lib/components/<name>.sexp`,
/// matched by `target_id` (preferred) or exact `target_text`. Emits
/// `{ok:true,removed_id}`.
pub fn removeRequirement(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    target_id: ?[]const u8,
    target_text: ?[]const u8,
    out: *std.ArrayList(u8),
) ReqError!bool {
    if (!validComponentName(name)) return writeJsonError(allocator, out, err_invalid_name);
    const has_id = target_id != null and target_id.?.len > 0;
    const has_text = target_text != null and target_text.?.len > 0;
    if (!has_id and !has_text) return writeJsonError(allocator, out, "must supply id or text");

    const path = try componentPath(allocator, project_dir, name);
    defer allocator.free(path);
    const src = infra_fs.cwd().readFileAlloc(allocator, path, max_component_bytes) catch |e| switch (e) {
        error.FileNotFound => return writeJsonError(allocator, out, err_component_not_found),
        else => return e,
    };
    defer allocator.free(src);
    const nodes = sexpr_parser.parse(allocator, src) catch return writeJsonError(allocator, out, err_component_parse);
    defer sexpr_parser.freeNodes(allocator, nodes);
    const body = (try componentRootBody(nodes, allocator, out)) orelse return false;

    var found = false;
    var matched_start: usize = 0;
    var id_buf: [8]u8 = undefined;
    var removed_id: []const u8 = "";
    for (body) |child| {
        if (!child.isForm(form_requirement)) continue;
        const cl = child.asList() orelse continue;
        if (cl.len < 2) continue;
        const is_match = (has_id and requirementIdMatches(cl, target_id.?)) or
            (has_text and requirementTextMatches(allocator, cl, target_text.?));
        if (!is_match) continue;
        found = true;
        matched_start = child.span.offset;
        removed_id = requirementId(cl, &id_buf);
        break;
    }
    if (!found) return writeJsonError(allocator, out, "no requirement matches the given id or text");

    const new_src = (try removeFormSrc(allocator, src, matched_start)) orelse
        return writeJsonError(allocator, out, "requirement form is unbalanced");
    defer allocator.free(new_src);
    try writeComponentFile(path, new_src);

    const w = out.writer(allocator);
    try w.writeAll("{\"ok\":true,\"removed_id\":");
    try json_writer.writeString(w, removed_id);
    try w.writeAll("}");
    return true;
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
    var buf: std.ArrayList(u8) = .empty;
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

test "requirementId derives the Crc32 id and honors an explicit id" {
    // spec: serve/component_info - listRequirements returns each requirement with its derived id
    const alloc = std.testing.allocator;

    const derived = try sexpr_parser.parse(alloc, "(requirement \"VBAT must connect to VDD\")");
    defer sexpr_parser.freeNodes(alloc, derived);
    var buf: [8]u8 = undefined;
    const want = try env_mod.requirementIdForText(alloc, "VBAT must connect to VDD");
    defer alloc.free(want);
    try std.testing.expectEqualStrings(want, requirementId(derived[0].asList().?, &buf));

    const explicit = try sexpr_parser.parse(alloc, "(requirement \"x\" (id deadbeef))");
    defer sexpr_parser.freeNodes(alloc, explicit);
    try std.testing.expectEqualStrings("deadbeef", requirementId(explicit[0].asList().?, &buf));
}

test "spliceRequirement inserts a new form before the component close" {
    // spec: serve/component_info - addRequirement appends a requirement form before the component close
    const alloc = std.testing.allocator;
    const src = "(component \"x\"\n  (footprint y)\n  (requirement \"first\"))\n";
    const out = (try spliceRequirement(alloc, src, "(requirement \"second\")")).?;
    defer alloc.free(out);
    const expected = "(component \"x\"\n  (footprint y)\n  (requirement \"first\")\n  (requirement \"second\"))\n";
    try std.testing.expectEqualStrings(expected, out);
}

test "checkClauseValid accepts a known check and rejects others" {
    // spec: serve/component_info - addRequirement rejects a check clause the checker does not recognize
    const alloc = std.testing.allocator;
    try std.testing.expect(checkClauseValid(alloc, "(check (connected (pin \"A\") (pin \"B\")))"));
    // Missing the (check ...) wrapper.
    try std.testing.expect(!checkClauseValid(alloc, "(connected (pin \"A\") (pin \"B\"))"));
    // Unknown primitive inside an otherwise well-formed check.
    try std.testing.expect(!checkClauseValid(alloc, "(check (no-such-rule (pin \"A\")))"));
    // Not even parseable.
    try std.testing.expect(!checkClauseValid(alloc, "(check (connected"));
}

test "addRequirement rejection lists the accepted checks and names the reference section" {
    // spec: serve/component_info - addRequirement rejection names the accepted check primitives and reference section
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    // An unrecognized check is rejected before any file is read, so the
    // project dir need not exist. The error must teach the vocabulary.
    const ok = try addRequirement(
        alloc,
        "/nonexistent-project",
        "somepart",
        "some requirement text",
        null,
        null,
        null,
        "(check (no-such-rule (pin \"A\")))",
        &out,
    );
    try std.testing.expect(!ok);
    // Every recognized keyword is enumerated (spot-check first and last), the
    // list is drawn from the checker's table, and the reference section is named.
    try std.testing.expect(std.mem.indexOf(u8, out.items, check_grammar.check_keyword_list) != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "connected") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "series-element") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Requirement checks") != null);
}

test "removeFormSrc deletes a middle requirement and reattaches the close on the last" {
    // spec: serve/component_info - removeRequirement deletes a requirement by id or exact text
    const alloc = std.testing.allocator;
    const src = "(component \"x\"\n  (requirement \"a\")\n  (requirement \"b\")\n  (requirement \"c\"))\n";

    // Remove the middle one ("b" at its '(' offset).
    const b_start = std.mem.indexOf(u8, src, "(requirement \"b\")").?;
    const mid = (try removeFormSrc(alloc, src, b_start)).?;
    defer alloc.free(mid);
    try std.testing.expectEqualStrings(
        "(component \"x\"\n  (requirement \"a\")\n  (requirement \"c\"))\n",
        mid,
    );

    // Remove the last one ("c") — the component's trailing ')' must survive
    // and reattach to the prior requirement's line.
    const c_start = std.mem.indexOf(u8, src, "(requirement \"c\")").?;
    const last = (try removeFormSrc(alloc, src, c_start)).?;
    defer alloc.free(last);
    try std.testing.expectEqualStrings(
        "(component \"x\"\n  (requirement \"a\")\n  (requirement \"b\"))\n",
        last,
    );
}

test "formEnd ignores parens inside string literals" {
    // spec: serve/component_info - formEnd skips parens inside string literals
    const src = "(requirement \"text with ) paren\") trailing";
    const end = formEnd(src, 0).?;
    try std.testing.expectEqualStrings("(requirement \"text with ) paren\")", src[0..end]);
}

test "add/list/remove requirement round-trips through the component file on disk" {
    // spec: serve/component_info - add list and remove requirement round-trip on disk
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("lib/components");
    try tmp.dir.writeFile(.{ .sub_path = "lib/components/foo.sexp", .data = "(component \"foo\"\n  (footprint x))\n" });
    const proj = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(proj);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    // Add — with a datasheet ref and a validated (check ...) clause.
    const check = "(check (connected (pin \"1\") (pin \"GND\")))";
    try std.testing.expect(try addRequirement(alloc, proj, "foo", "Pin 1 must be tied to GND", "ds.pdf", 3, "tie to GND", check, &out));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"ok\":true") != null);
    const want_id = try env_mod.requirementIdForText(alloc, "Pin 1 must be tied to GND");
    defer alloc.free(want_id);
    try std.testing.expect(std.mem.indexOf(u8, out.items, want_id) != null);

    // The file gained the form, ref, and check — and still parses.
    const after = try tmp.dir.readFileAlloc(alloc, "lib/components/foo.sexp", 1 << 20);
    defer alloc.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "(requirement \"Pin 1 must be tied to GND\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "(check (connected (pin \"1\") (pin \"GND\")))") != null);
    const reparsed = try sexpr_parser.parse(alloc, after);
    sexpr_parser.freeNodes(alloc, reparsed);

    // List surfaces it with its id.
    out.clearRetainingCapacity();
    try std.testing.expect(try listRequirements(alloc, proj, "foo", &out));
    try std.testing.expect(std.mem.indexOf(u8, out.items, want_id) != null);

    // A duplicate add (same derived id) is rejected.
    out.clearRetainingCapacity();
    try std.testing.expect(!try addRequirement(alloc, proj, "foo", "Pin 1 must be tied to GND", null, null, null, null, &out));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "already exists") != null);

    // Remove by id, then the list is empty again.
    out.clearRetainingCapacity();
    try std.testing.expect(try removeRequirement(alloc, proj, "foo", want_id, null, &out));
    out.clearRetainingCapacity();
    try std.testing.expect(try listRequirements(alloc, proj, "foo", &out));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"requirements\":[]") != null);
}

test "writeComponentJson emits the first requirement without a leading comma" {
    // `req_first` suppresses the separator before the first requirement; a
    // `true`->`false` flip prefixes it with a stray comma (`[,{`), breaking
    // the JSON.
    const alloc = std.testing.allocator;
    const z = ast.Span.zero;
    const req = [_]ast.Node{ ast.Node.atom(z, "requirement"), ast.Node.string(z, "Tie pin 1 to GND") };
    const root_body = [_]ast.Node{ast.Node.list(z, &req)};
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    const w = out.writer(alloc);
    try writeComponentJson(
        alloc,
        w,
        "foo",
        .{ .name = "foo", .is_family = false },
        &.{},
        .{ .pins = null, .source = null },
        &root_body,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"requirements\":[{") != null);
}
