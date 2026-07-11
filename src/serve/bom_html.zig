const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const env_mod = @import("../eval/env.zig");
const parser_mod = @import("../sexpr/parser.zig");
const json_writer = @import("../json_writer.zig");
const escape = @import("../escape.zig");
const numeric = @import("../numeric.zig");
/// A datasheet href is safe to emit as a link only if it is a same-origin
/// path or an http(s) URL. Anything else (`javascript:`, `data:`, …) is
/// rendered as inert text by the caller.
fn safeHref(url: []const u8) bool {
    if (url.len > 0 and url[0] == '/') return true;
    const sep = std.mem.indexOf(u8, url, "://") orelse return false;
    const scheme = url[0..sep];
    return std.mem.eql(u8, scheme, "http") or std.mem.eql(u8, scheme, "https");
}

// ── Constants ─────────────────────────────────────────────────────
const STEP_EXT_LEN: usize = ".step".len;

/// Error set for the BOM rendering helpers — a writer-or-allocator union
/// because the `anytype` writer parameters are called with both
/// `ArrayListUnmanaged.writer()` (Allocator.Error) and `*std.Io.Writer`
/// (Writer.Error) depending on the call site. Also covers directory
/// iteration errors surfaced by helpers that scan `lib/`.
pub const BomError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    std.fs.Dir.Iterator.Error;

/// Check if a ref-des is a standard format (1-2 uppercase letters + digits), e.g. U10, R5.
fn isStdRefDes(ref: []const u8) bool {
    if (ref.len < 2) return false;
    var i: usize = 0;
    while (i < ref.len and i < 2 and ref[i] >= 'A' and ref[i] <= 'Z') : (i += 1) {}
    if (i == 0) return false;
    const digit_start = i;
    while (i < ref.len and ref[i] >= '0' and ref[i] <= '9') : (i += 1) {}
    return i == ref.len and i > digit_start;
}

// ── Symbol pin cache ──────────────────────────────────────────────────

/// One row from a `lib/pinouts/*.sexp` file: a single pin's number and its
/// human-readable name (e.g. `{ .num = "27", .name = "GND" }`).
pub const SymbolPin = struct {
    num: []const u8,
    name: []const u8,
};

pub const SymbolPinCache = std.StringHashMapUnmanaged([]const SymbolPin);

/// Walk the design and append component names whose footprint .sexp or
/// 3D `.step` model can't be found under `lib/`. The two `checked_*` sets
/// dedupe so each missing asset is reported once across deep hierarchies.
pub fn collectMissing(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    project_dir: []const u8,
    missing_fp: *std.ArrayListUnmanaged([]const u8),
    missing_model: *std.ArrayListUnmanaged([]const u8),
    checked_fp: *std.StringHashMap(void),
    checked_model: *std.StringHashMap(void),
) BomError!void {
    for (block.instances) |inst| {
        // Check footprint
        if (inst.footprint.len > 0 and !checked_fp.contains(inst.footprint)) {
            try checked_fp.put(inst.footprint, {});
            const fp_path = try std.fmt.allocPrint(allocator, "{s}/lib/footprints/{s}.sexp", .{ project_dir, inst.footprint });
            defer allocator.free(fp_path);
            infra_fs.cwd().access(fp_path, .{}) catch {
                try missing_fp.append(allocator, inst.footprint);
            };
        }
        // Check 3D model
        if (inst.component.len > 0 and !checked_model.contains(inst.component)) {
            try checked_model.put(inst.component, {});
            var found = false;
            // Try exact footprint name, then component name
            const names_to_try = [_][]const u8{ inst.footprint, inst.component };
            for (names_to_try) |try_name| {
                if (try_name.len == 0) continue;
                const m = try std.fmt.allocPrint(allocator, "{s}/lib/models/{s}.step", .{ project_dir, try_name });
                defer allocator.free(m);
                if (infra_fs.cwd().access(m, .{})) |_| {
                    found = true;
                    break;
                } else |_| {}
            }
            // Fuzzy scan: check if any model filename contains/is contained by footprint or component name
            if (!found) {
                const models_path = try std.fmt.allocPrint(allocator, "{s}/lib/models", .{project_dir});
                defer allocator.free(models_path);
                var dir = infra_fs.cwd().openDir(models_path, .{ .iterate = true }) catch null;
                if (dir) |*d| {
                    defer d.close();
                    var iter = d.iterate();
                    while (iter.next() catch null) |entry| {
                        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".step")) continue;
                        const basename = entry.name[0 .. entry.name.len - STEP_EXT_LEN];
                        if ((inst.footprint.len > 0 and
                            (std.mem.indexOf(u8, inst.footprint, basename) != null or
                                std.mem.indexOf(u8, basename, inst.footprint) != null)) or
                            (std.mem.indexOf(u8, inst.component, basename) != null or std.mem.indexOf(u8, basename, inst.component) != null))
                        {
                            found = true;
                            break;
                        }
                    }
                }
            }
            if (!found) {
                try missing_model.append(allocator, inst.component);
            }
        }
    }
    for (block.sub_blocks) |sb| {
        try collectMissing(allocator, sb.block, project_dir, missing_fp, missing_model, checked_fp, checked_model);
    }
}

/// Render the design's BOM as a grouped HTML table with editable MPN /
/// manufacturer cells. Tuned for the always-visible card on the schematic
/// page: groups instances by `(component, value, footprint, attrs)`,
/// surfaces every `Property` key as a badge, and emits no embedded JS —
/// the schematic page's own scripts own the click handlers.
pub fn writeSchematicBomHtml(allocator: std.mem.Allocator, wr: anytype, block: *const env_mod.DesignBlock) BomError!void {
    const Instance = env_mod.Instance;
    var all: std.ArrayListUnmanaged(Instance) = .empty;
    try bomCollectInstancesHierarchical(allocator, block, "", &all);
    if (all.items.len == 0) return;

    const BomLine = struct {
        component: []const u8,
        value: []const u8,
        footprint: []const u8,
        attrs: []const []const u8,
        properties: []const env_mod.Property,
        dnp: bool,
        count: u32,
        refs: std.ArrayListUnmanaged([]const u8),
    };

    var lines: std.ArrayListUnmanaged(BomLine) = .empty;
    for (all.items) |inst| {
        // Test points are probe pads, not parts a fab sources. They
        // surface in the dedicated TestPoints table on the review
        // embed; suppress them from the parts BOM in every renderer.
        if (env_mod.isTestPoint(inst.component)) continue;
        var found = false;
        for (lines.items) |*line| {
            if (line.dnp == inst.dnp and
                std.mem.eql(u8, line.component, inst.component) and
                std.mem.eql(u8, line.value, inst.value) and
                std.mem.eql(u8, line.footprint, inst.footprint) and
                attrsEqual(line.attrs, inst.attrs))
            {
                line.count += 1;
                try line.refs.append(allocator, inst.ref_des);
                found = true;
                break;
            }
        }
        if (!found) {
            var refs: std.ArrayListUnmanaged([]const u8) = .empty;
            try refs.append(allocator, inst.ref_des);
            try lines.append(allocator, .{
                .component = inst.component,
                .value = inst.value,
                .footprint = inst.footprint,
                .attrs = inst.attrs,
                .properties = inst.properties,
                .dnp = inst.dnp,
                .count = 1,
                .refs = refs,
            });
        }
    }

    std.mem.sortUnstable(BomLine, lines.items, {}, struct {
        fn lt(_: void, a: BomLine, b: BomLine) bool {
            if (a.count != b.count) return a.count > b.count;
            const c = std.mem.order(u8, a.component, b.component);
            if (c == .lt) return true;
            if (c == .gt) return false;
            return std.mem.order(u8, a.value, b.value) == .lt;
        }
    }.lt);

    try wr.writeAll("<div class=\"sch-bom-wrap\"><table class=\"sch-bom-table\"><thead><tr>");
    try wr.writeAll("<th>Qty</th><th>Refs</th><th>Component</th><th>Value</th>" ++
        "<th>Footprint</th><th>Attrs</th><th>MPN</th><th>Manufacturer</th><th>Other</th>");
    try wr.writeAll("</tr></thead><tbody>");

    for (lines.items) |line| {
        // Pull mpn / manufacturer (and stash everything else for the "Other" cell).
        var mpn: []const u8 = "";
        var manufacturer: []const u8 = "";
        for (line.properties) |p| {
            if (std.mem.eql(u8, p.key, "mpn")) mpn = p.value;
            if (std.mem.eql(u8, p.key, "manufacturer")) manufacturer = p.value;
        }

        if (line.dnp) try wr.writeAll("<tr class=\"sch-bom-dnp-row\">") else try wr.writeAll("<tr>");
        try wr.print("<td class=\"sch-bom-qty\">{d}</td>", .{line.count});

        // Refs cell — full list with title for hover.
        try wr.writeAll("<td class=\"sch-bom-refs\" title=\"");
        for (line.refs.items, 0..) |r, i| {
            if (i > 0) try wr.writeAll(", ");
            try escape.writeXml(wr, r);
        }
        try wr.writeAll("\">");
        for (line.refs.items, 0..) |r, i| {
            if (i > 0) try wr.writeAll(", ");
            try escape.writeXml(wr, r);
        }
        try wr.writeAll("</td>");

        try wr.writeAll("<td class=\"sch-bom-comp\">");
        try escape.writeXml(wr, line.component);
        try wr.writeAll("</td><td>");
        try escape.writeXml(wr, line.value);
        try wr.writeAll("</td><td>");
        try escape.writeXml(wr, line.footprint);
        try wr.writeAll("</td>");

        // Attrs — schematic-time annotations like "x7r", "np0"; DNP first.
        try wr.writeAll("<td class=\"sch-bom-attrs\">");
        if (line.dnp) try wr.writeAll("<span class=\"sch-bom-tag sch-bom-dnp\">DNP</span>");
        for (line.attrs) |attr| {
            try wr.writeAll("<span class=\"sch-bom-tag\">");
            try escape.writeXml(wr, attr);
            try wr.writeAll("</span>");
        }
        try wr.writeAll("</td>");

        // refs joined for the data-ref payload.
        const refs_csv = try joinRefs(allocator, line.refs.items);
        defer allocator.free(refs_csv);

        // MPN — editable. data-ref carries every ref-des in the group; the
        // JS save handler iterates and POSTs once per ref.
        try wr.writeAll("<td class=\"sch-bom-mpn\"><input class=\"sch-bom-mpn-edit\" data-ref=\"");
        try escape.writeXml(wr, refs_csv);
        try wr.writeAll("\" value=\"");
        try escape.writeXml(wr, mpn);
        try wr.writeAll("\" placeholder=\"set MPN\"><button class=\"sch-bom-mpn-save\" data-ref=\"");
        try escape.writeXml(wr, refs_csv);
        try wr.writeAll("\" type=\"button\">Save</button></td>");

        // Manufacturer — editable.
        try wr.writeAll("<td class=\"sch-bom-mfr\"><input class=\"sch-bom-mfr-edit\" data-ref=\"");
        try escape.writeXml(wr, refs_csv);
        try wr.writeAll("\" value=\"");
        try escape.writeXml(wr, manufacturer);
        try wr.writeAll("\" placeholder=\"set manufacturer\"><button class=\"sch-bom-mfr-save\" data-ref=\"");
        try escape.writeXml(wr, refs_csv);
        try wr.writeAll("\" type=\"button\">Save</button></td>");

        // Other properties (datasheet, wattage, custom keys) as read-only badges.
        try wr.writeAll("<td class=\"sch-bom-other\">");
        for (line.properties) |p| {
            if (std.mem.eql(u8, p.key, "mpn") or std.mem.eql(u8, p.key, "manufacturer")) continue;
            if (std.mem.eql(u8, p.key, "datasheet")) {
                if (safeHref(p.value)) {
                    try wr.writeAll("<a class=\"sch-bom-tag sch-bom-tag-link\" href=\"");
                    try escape.writeXml(wr, p.value);
                    try wr.writeAll("\" target=\"_blank\" rel=\"noopener noreferrer\">datasheet</a>");
                } else {
                    // Unsafe scheme (javascript:/data:/…) — render inert, not a link.
                    try wr.writeAll("<span class=\"sch-bom-tag sch-bom-tag-prop\">datasheet: ");
                    try escape.writeXml(wr, p.value);
                    try wr.writeAll("</span>");
                }
            } else {
                try wr.writeAll("<span class=\"sch-bom-tag sch-bom-tag-prop\">");
                try escape.writeXml(wr, p.key);
                try wr.writeAll(": ");
                try escape.writeXml(wr, p.value);
                try wr.writeAll("</span>");
            }
        }
        try wr.writeAll("</td>");

        try wr.writeAll("</tr>");
    }

    try wr.writeAll("</tbody></table></div>");
}

/// Comma-join a list of ref-des strings for embedding in `data-ref`. Caller
/// owns the returned slice. Used by `writeSchematicBomHtml` so the
/// client-side save handler can iterate group members in one click.
fn joinRefs(allocator: std.mem.Allocator, refs: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (refs, 0..) |r, i| total += r.len + (if (i > 0) @as(usize, 1) else 0);
    var buf = try allocator.alloc(u8, total);
    var pos: usize = 0;
    for (refs, 0..) |r, i| {
        if (i > 0) {
            buf[pos] = ',';
            pos += 1;
        }
        @memcpy(buf[pos .. pos + r.len], r);
        pos += r.len;
    }
    return buf;
}

/// Emit the parts list as CSV (component, value, footprint, count, refs,
/// then any extra `attrs` columns). Used by `exportBomCsvApi` and the
/// review-package zip exporter.
pub fn writeBomCsv(allocator: std.mem.Allocator, w: anytype, block: *const env_mod.DesignBlock) BomError!void {
    const Instance = env_mod.Instance;
    var all: std.ArrayListUnmanaged(Instance) = .empty;
    try bomCollectInstances(allocator, block, &all);
    if (all.items.len == 0) return;

    const BomLine = struct {
        component: []const u8,
        value: []const u8,
        footprint: []const u8,
        properties: []const env_mod.Property,
        attrs: []const []const u8,
        dnp: bool,
        count: u32,
        refs: std.ArrayListUnmanaged([]const u8),
    };

    var lines: std.ArrayListUnmanaged(BomLine) = .empty;
    for (all.items) |inst| {
        // Test points are probe pads, not parts a fab sources. They
        // surface in the dedicated TestPoints table on the review
        // embed; suppress them from the parts BOM in every renderer.
        if (env_mod.isTestPoint(inst.component)) continue;
        var found = false;
        for (lines.items) |*line| {
            if (line.dnp == inst.dnp and
                std.mem.eql(u8, line.component, inst.component) and
                std.mem.eql(u8, line.value, inst.value) and
                std.mem.eql(u8, line.footprint, inst.footprint) and
                attrsEqual(line.attrs, inst.attrs))
            {
                line.count += 1;
                try line.refs.append(allocator, inst.ref_des);
                found = true;
                break;
            }
        }
        if (!found) {
            var refs: std.ArrayListUnmanaged([]const u8) = .empty;
            try refs.append(allocator, inst.ref_des);
            try lines.append(allocator, .{
                .component = inst.component,
                .value = inst.value,
                .footprint = inst.footprint,
                .properties = inst.properties,
                .attrs = inst.attrs,
                .dnp = inst.dnp,
                .count = 1,
                .refs = refs,
            });
        }
    }

    // Sort by count desc, then component name
    std.mem.sortUnstable(BomLine, lines.items, {}, struct {
        fn lt(_: void, a: BomLine, b: BomLine) bool {
            if (a.count != b.count) return a.count > b.count;
            return std.mem.order(u8, a.component, b.component) == .lt;
        }
    }.lt);

    // CSV header
    try w.writeAll("Qty,References,Component,Value,Footprint,MPN,Manufacturer,Datasheet,DNP\r\n");

    for (lines.items) |line| {
        // Qty
        try w.print("{d},", .{line.count});

        // References (quoted, comma-separated)
        try w.writeAll("\"");
        for (line.refs.items, 0..) |r, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(r);
        }
        try w.writeAll("\",");

        // Component, Value, Footprint
        try writeCsvField(w, line.component);
        try w.writeAll(",");
        try writeCsvField(w, line.value);
        try w.writeAll(",");
        try writeCsvField(w, line.footprint);
        try w.writeAll(",");

        // MPN, Manufacturer, Datasheet from properties
        var mpn: []const u8 = "";
        var manufacturer: []const u8 = "";
        var datasheet: []const u8 = "";
        for (line.properties) |prop| {
            if (std.mem.eql(u8, prop.key, "mpn")) mpn = prop.value;
            if (std.mem.eql(u8, prop.key, "manufacturer")) manufacturer = prop.value;
            if (std.mem.eql(u8, prop.key, "datasheet")) datasheet = prop.value;
        }
        try writeCsvField(w, mpn);
        try w.writeAll(",");
        try writeCsvField(w, manufacturer);
        try w.writeAll(",");
        try writeCsvField(w, datasheet);
        try w.writeAll(",");
        try w.writeAll(if (line.dnp) "DNP" else "");
        try w.writeAll("\r\n");
    }
}

fn writeCsvField(w: anytype, field: []const u8) !void {
    // Quote if field contains comma, quote, or newline
    var needs_quote = false;
    for (field) |c| {
        if (c == ',' or c == '"' or c == '\n' or c == '\r') {
            needs_quote = true;
            break;
        }
    }
    if (needs_quote) {
        try w.writeAll("\"");
        for (field) |c| {
            if (c == '"') try w.writeAll("\"\"") else try w.writeByte(c);
        }
        try w.writeAll("\"");
    } else {
        try w.writeAll(field);
    }
}

fn bomCollectInstances(allocator: std.mem.Allocator, block: *const env_mod.DesignBlock, out: *std.ArrayListUnmanaged(env_mod.Instance)) !void {
    for (block.instances) |inst| {
        try out.append(allocator, inst);
    }
    for (block.sub_blocks) |sb| {
        try bomCollectInstances(allocator, sb.block, out);
    }
}

/// Same walk as `bomCollectInstances` but rewrites each sub-block instance's
/// `ref_des` to its hierarchical form (e.g. `buck/L2`), which is the key the
/// `.bom` sidecar uses. The schematic BOM card needs this so the `data-ref`
/// it emits round-trips through `editMpnCore` → `setBomProperty` and lands
/// on the correct `BomEntry`. Top-level instances pass through unchanged.
fn bomCollectInstancesHierarchical(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    prefix: []const u8,
    out: *std.ArrayListUnmanaged(env_mod.Instance),
) !void {
    for (block.instances) |inst| {
        var copy = inst;
        if (prefix.len > 0) copy.ref_des = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, inst.ref_des });
        try out.append(allocator, copy);
    }
    for (block.sub_blocks) |sb| {
        const child_prefix = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, sb.name })
        else
            sb.name;
        try bomCollectInstancesHierarchical(allocator, sb.block, child_prefix, out);
    }
}

fn attrsEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

/// Scan `lib/pinouts/*.sexp` once and return a map from symbol name to its
/// full pin list. Cached so per-instance lookups in
/// `augmentUnconnectedPins` and `writeComponentsJson` stay O(1).
pub fn buildSymbolPinCache(allocator: std.mem.Allocator, project_dir: []const u8) BomError!SymbolPinCache {
    var cache: SymbolPinCache = .empty;
    const dirs = [_]struct { path: []const u8, form: []const u8 }{
        .{ .path = "lib/pinouts", .form = "pinout" },
    };
    for (dirs) |d| {
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, d.path });
        defer allocator.free(dir_path);
        var dir = infra_fs.cwd().openDir(dir_path, .{ .iterate = true }) catch continue;
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".sexp")) {
                const content = dir.readFileAlloc(allocator, entry.name, 1024 * 256) catch continue;
                const nodes = parser_mod.parse(allocator, content) catch continue;
                if (nodes.len == 0) continue;
                const top = nodes[0].asList() orelse continue;
                if (top.len < 2) continue;
                const head = top[0].asAtom() orelse continue;
                if (!std.mem.eql(u8, head, d.form)) continue;
                const item_name = top[1].asString() orelse (top[1].asAtom() orelse continue);
                if (cache.contains(item_name)) continue; // package takes priority

                var pins: std.ArrayListUnmanaged(SymbolPin) = .empty;
                for (top[2..]) |child| {
                    const cl = child.asList() orelse continue;
                    if (cl.len < 3) continue;
                    const ch = cl[0].asAtom() orelse continue;
                    if (!std.mem.eql(u8, ch, "pin")) continue;
                    const pin_id = blk: {
                        if (cl[1].asNumber()) |n| {
                            const i: i64 = numeric.checkedInt(i64, n) orelse continue;
                            break :blk std.fmt.allocPrint(allocator, "{d}", .{i}) catch continue;
                        }
                        break :blk cl[1].asAtom() orelse continue;
                    };
                    const pin_name = cl[2].asString() orelse (cl[2].asAtom() orelse continue);
                    try pins.append(allocator, .{ .num = pin_id, .name = pin_name });
                }
                if (pins.items.len > 0) {
                    try cache.put(allocator, item_name, try pins.toOwnedSlice(allocator));
                }
            }
        }
    }
    return cache;
}

/// Augment instances with an "Unconnected" part for symbol pins not in any part.
pub fn augmentUnconnectedPins(allocator: std.mem.Allocator, block: *env_mod.DesignBlock, sym_cache: *const SymbolPinCache) std.mem.Allocator.Error!void {
    for (block.instances, 0..) |inst, inst_idx| {
        if (inst.parts.len == 0) continue;

        const sym_pins = sym_cache.get(inst.symbol) orelse
            sym_cache.get(inst.component) orelse continue;
        if (sym_pins.len == 0) continue;

        var used: std.StringHashMapUnmanaged(void) = .empty;
        defer used.deinit(allocator);
        for (inst.parts) |part| {
            for (part.pins) |pp| {
                try used.put(allocator, pp.pin, {});
            }
        }

        var nc_pins: std.ArrayListUnmanaged(env_mod.PartPin) = .empty;
        for (sym_pins) |sp| {
            if (!used.contains(sp.num)) {
                try nc_pins.append(allocator, .{ .pin = sp.num, .net = "" });
            }
        }

        if (nc_pins.items.len == 0) continue;

        var new_parts = try allocator.alloc(env_mod.Part, inst.parts.len + 1);
        @memcpy(new_parts[0..inst.parts.len], inst.parts);
        new_parts[inst.parts.len] = .{
            .name = "Unconnected",
            .pins = try nc_pins.toOwnedSlice(allocator),
        };

        var mutable_instances = @constCast(block.instances);
        mutable_instances[inst_idx].parts = new_parts;
    }

    for (block.sub_blocks) |sb| {
        try augmentUnconnectedPins(allocator, sb.block, sym_cache);
    }
}

// ── JSON helpers ───────────────────────────────────────────────────────

/// Cheap probe: open `lib/footprints/<footprint>.sexp` and look for a
/// `(pad ` token. Used to skip rendering rows in the BOM that would have
/// no physical pads (decorative or reference-only entries).
pub fn footprintHasPads(allocator: std.mem.Allocator, project_dir: []const u8, footprint: []const u8) bool {
    if (footprint.len == 0) return false;
    const fp_path = std.fmt.allocPrint(allocator, "{s}/lib/footprints/{s}.sexp", .{ project_dir, footprint }) catch return false;
    defer allocator.free(fp_path);
    const content = infra_fs.cwd().readFileAlloc(allocator, fp_path, 256 * 1024) catch return false;
    defer allocator.free(content);
    return std.mem.indexOf(u8, content, "(pad ") != null;
}

/// Walk the design hierarchy and emit a `{ "<refdes>": {…}, … }` object
/// keyed on hierarchical ref-des, embedding each instance's symbol,
/// footprint, value, source offset, note text, pin-net pairs, and full
/// symbol-pin list. Returns true when at least one entry was written.
pub fn writeComponentsJson(
    w: anytype,
    block: *const env_mod.DesignBlock,
    prefix: []const u8,
    sym_cache: *const SymbolPinCache,
    allocator: std.mem.Allocator,
    project_dir: []const u8,
) BomError!bool {
    var written = false;
    for (block.instances) |inst| {
        if (written) try w.writeAll(",");
        try w.writeAll("\"");
        if (prefix.len > 0 and !isStdRefDes(inst.ref_des)) try w.print("{s}/", .{prefix});
        const fp_ok = footprintHasPads(allocator, project_dir, inst.footprint);
        try w.print("{s}\":{{\"symbol\":\"{s}\",\"footprint\":\"{s}\",\"fpOk\":{s},\"value\":\"{s}\",\"component\":\"{s}\",\"srcOff\":{d},\"note\":\"", .{
            inst.ref_des,
            inst.symbol,
            inst.footprint,
            if (fp_ok) "true" else "false",
            inst.value,
            inst.component,
            inst.source_offset,
        });
        // Find note for this instance
        for (block.notes) |note| {
            if (std.mem.eql(u8, note.ref_des, inst.ref_des)) {
                try writeJsonEscaped(w, note.text);
                break;
            }
        }
        // Include part pin data if available
        try w.writeAll("\",\"pins\":[");
        var pin_written = false;
        for (inst.parts) |part| {
            for (part.pins) |pp| {
                if (pin_written) try w.writeAll(",");
                try w.print("{{\"num\":\"{s}\",\"net\":\"", .{pp.pin});
                try writeJsonEscaped(w, pp.net);
                try w.writeAll("\",\"pinName\":\"");
                try writeJsonEscaped(w, pp.pin_name);
                try w.writeAll("\",\"part\":\"");
                try writeJsonEscaped(w, part.name);
                try w.writeAll("\"}");
                pin_written = true;
            }
        }
        try w.writeAll("],\"symbolPins\":[");
        // Include all pins from the symbol definition
        if (sym_cache.get(inst.symbol) orelse sym_cache.get(inst.component)) |sym_pins| {
            for (sym_pins, 0..) |sp, si| {
                if (si > 0) try w.writeAll(",");
                try w.print("{{\"num\":\"{s}\",\"name\":\"", .{sp.num});
                try writeJsonEscaped(w, sp.name);
                try w.writeAll("\"}");
            }
        }
        try w.writeAll("],\"properties\":{");
        for (inst.properties, 0..) |prop, pi| {
            if (pi > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try writeJsonEscaped(w, prop.key);
            try w.writeAll("\":\"");
            try writeJsonEscaped(w, prop.value);
            try w.writeAll("\"");
        }
        try w.writeAll("}}");
        written = true;
    }
    for (block.sub_blocks) |sb| {
        if (written) try w.writeAll(",");
        const sub_written = try writeComponentsJson(w, sb.block, sb.name, sym_cache, allocator, project_dir);
        if (sub_written) written = true;
    }
    return written;
}

/// Extract the base net name (before first '.'), e.g. "VDD.U3.W6" → "VDD".
fn baseNetName(name: []const u8) []const u8 {
    // Strip scope prefix (after last '/')
    const short = if (std.mem.lastIndexOfScalar(u8, name, '/')) |idx| name[idx + 1 ..] else name;
    if (std.mem.indexOfScalar(u8, short, '.')) |idx| return short[0..idx];
    return short;
}

/// Emit a `{ "<net>": [{ref_des, pin}, …], … }` object grouping every pin
/// reference by its base net name, applying `net_ties` to merge sub-block
/// nets into the parent's name (so `ldo/VIN` collapses into `VDD`).
pub fn writeNetsJson(allocator: std.mem.Allocator, w: anytype, block: *const env_mod.DesignBlock, prefix: []const u8) BomError!bool {
    // Build rename map from net_ties: "sb_name/port" → "parent_net"
    var rename = std.StringHashMap([]const u8).init(allocator);
    for (block.net_ties) |nt| {
        // A tie like (a="VDD", b="ldo/VIN") means rename "ldo/VIN" → "VDD"
        const has_slash_a = std.mem.indexOfScalar(u8, nt.a, '/') != null;
        const has_slash_b = std.mem.indexOfScalar(u8, nt.b, '/') != null;
        if (!has_slash_a and has_slash_b) {
            try rename.put(nt.b, nt.a);
        } else if (has_slash_a and !has_slash_b) {
            try rename.put(nt.a, nt.b);
        }
    }

    // Collect pins grouped by resolved base net name, preserving order
    const PinRef = struct { ref_des: []const u8, pin: []const u8 };
    var grouped = std.StringArrayHashMap(std.ArrayListUnmanaged(PinRef)).init(allocator);

    // Helper to resolve and group a net
    const addNet = struct {
        fn add(
            g: *std.StringArrayHashMap(std.ArrayListUnmanaged(PinRef)),
            alloc: std.mem.Allocator,
            name: []const u8,
            pfx: []const u8,
            pins: []const env_mod.PinRef,
        ) !void {
            const base = baseNetName(name);
            const gop = try g.getOrPut(base);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            for (pins) |pin| {
                const rd = if (pfx.len > 0 and !isStdRefDes(pin.ref_des))
                    try std.fmt.allocPrint(alloc, "{s}/{s}", .{ pfx, pin.ref_des })
                else
                    pin.ref_des;
                try gop.value_ptr.append(alloc, .{ .ref_des = rd, .pin = pin.pin });
            }
        }
    }.add;

    for (block.nets) |net| {
        try addNet(&grouped, allocator, net.name, prefix, net.pins);
    }

    // Flatten sub-block nets into parent net groups using rename map
    for (block.sub_blocks) |sb| {
        for (sb.block.nets) |net| {
            // Build the prefixed net name e.g. "ldo/VIN" or "ldo/VIN.U1.IN"
            const prefixed = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sb.name, net.name });
            const prefixed_base = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sb.name, baseNetName(net.name) });

            // Try to rename to parent net (e.g. "ldo/VIN" → "VDD")
            var resolved: []const u8 = prefixed;
            if (rename.get(prefixed_base)) |parent_net| {
                // Rebuild with parent net name + suffix
                const base_local = baseNetName(net.name);
                if (net.name.len > base_local.len) {
                    // Has suffix like ".U1.IN"
                    resolved = try std.fmt.allocPrint(allocator, "{s}{s}", .{ parent_net, net.name[base_local.len..] });
                } else {
                    resolved = parent_net;
                }
            }
            try addNet(&grouped, allocator, resolved, "", net.pins);
        }
    }

    var written = false;
    var iter = grouped.iterator();
    while (iter.next()) |entry| {
        if (written) try w.writeAll(",");
        try w.writeAll("\"");
        if (prefix.len > 0) try w.print("{s}/", .{prefix});
        try w.print("{s}\":[", .{entry.key_ptr.*});
        for (entry.value_ptr.items, 0..) |pin, pi| {
            if (pi > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try w.print("{s}.{s}\"", .{ pin.ref_des, pin.pin });
        }
        try w.writeAll("]");
        written = true;
    }
    return written;
}

pub const writeJsonEscaped = json_writer.writeEscaped;

/// Unique BOM lines vs. total placed parts. `unique` counts distinct
/// component/value/footprint/attrs combinations (one BOM row each); `total`
/// counts every placed instance. Test points are excluded from both, matching
/// `writeSchematicBomHtml`.
pub const BomCounts = struct { unique: u32 = 0, total: u32 = 0 };

/// Count BOM lines + total parts without rendering the table — used for the
/// collapsed BOM card's `<summary>` count. Mirrors `writeSchematicBomHtml`'s
/// dedup keys exactly so the headline numbers match the expanded table.
pub fn countBom(allocator: std.mem.Allocator, block: *const env_mod.DesignBlock) BomError!BomCounts {
    var all: std.ArrayListUnmanaged(env_mod.Instance) = .empty;
    try bomCollectInstancesHierarchical(allocator, block, "", &all);

    const Key = struct {
        component: []const u8,
        value: []const u8,
        footprint: []const u8,
        attrs: []const []const u8,
    };
    var keys: std.ArrayListUnmanaged(Key) = .empty;
    var counts: BomCounts = .{};
    for (all.items) |inst| {
        if (env_mod.isTestPoint(inst.component)) continue;
        counts.total += 1;
        var found = false;
        for (keys.items) |k| {
            if (std.mem.eql(u8, k.component, inst.component) and
                std.mem.eql(u8, k.value, inst.value) and
                std.mem.eql(u8, k.footprint, inst.footprint) and
                attrsEqual(k.attrs, inst.attrs))
            {
                found = true;
                break;
            }
        }
        if (!found) {
            try keys.append(allocator, .{
                .component = inst.component,
                .value = inst.value,
                .footprint = inst.footprint,
                .attrs = inst.attrs,
            });
            counts.unique += 1;
        }
    }
    return counts;
}

test "footprintHasPads reports false when the path allocation fails" {
    // The `catch return false` on the path allocPrint must stay false on
    // failure; a `false`->`true` flip would claim pads exist on OOM.
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expect(!footprintHasPads(fa.allocator(), "/proj", "some_fp"));
}
