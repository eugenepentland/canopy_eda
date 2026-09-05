//! Bill-of-materials rendering off a resolved `DesignBlock`: the schematic BOM
//! HTML table and CSV, plus the components/nets JSON the viewer reads. Also
//! builds the library symbol-pin cache and augments instances with their
//! declared-but-unconnected pins so the BOM and schematic show every pad.
//! Reads lib/ for pin names; output buffers are owned by the caller's arena.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const env_mod = @import("../eval/env.zig");
const parser_mod = @import("../sexpr/parser.zig");
const json_writer = @import("../json_writer.zig");
const escape = @import("../escape.zig");
const numeric = @import("../numeric.zig");
const lib_limits = @import("../lib_limits.zig");
const stdlib = @import("../stdlib.zig");

/// Project-relative sub-path of one footprint; resolved through `stdlib`.
const footprint_path_fmt = "lib/footprints/{s}.sexp";
const log = @import("../infra/log.zig");
const na = @import("../eval/net_analysis.zig");
const net_name = @import("../net_name.zig");
const variants = @import("../eval/variants.zig");

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
const step_ext_len: usize = ".step".len;

/// Error set for the BOM rendering helpers — a writer-or-allocator union
/// because the `anytype` writer parameters are called with both
/// `ArrayListUnmanaged.writer()` (Allocator.Error) and `*std.Io.Writer`
/// (Writer.Error) depending on the call site. Also covers directory
/// iteration errors surfaced by helpers that scan `lib/`.
pub const BomError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    infra_fs.Iterator.Error;

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
/// True when either name contains the other — the fuzzy match the 3D-model scan
/// uses to pair a `lib/models/*.step` basename with a footprint or component.
fn eitherContains(a: []const u8, b: []const u8) bool {
    return std.mem.indexOf(u8, a, b) != null or std.mem.indexOf(u8, b, a) != null;
}

pub fn collectMissing(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    project_dir: []const u8,
    missing_fp: *std.ArrayList([]const u8),
    missing_model: *std.ArrayList([]const u8),
    checked_fp: *std.StringHashMapUnmanaged(void),
    checked_model: *std.StringHashMapUnmanaged(void),
) BomError!void {
    for (block.instances) |inst| {
        // Check footprint
        if (inst.footprint.len > 0 and !checked_fp.contains(inst.footprint)) {
            try checked_fp.put(inst.footprint, {});
            const fp_sub = try std.fmt.allocPrint(allocator, footprint_path_fmt, .{inst.footprint});
            defer allocator.free(fp_sub);
            if (!stdlib.exists(allocator, project_dir, fp_sub)) {
                try missing_fp.append(allocator, inst.footprint);
            }
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
                        const basename = entry.name[0 .. entry.name.len - step_ext_len];
                        // A STEP file's basename and the footprint/component
                        // name it belongs to routinely differ by a suffix at
                        // either end, so either containing the other counts.
                        const footprint_match = inst.footprint.len > 0 and
                            eitherContains(inst.footprint, basename);
                        if (footprint_match or eitherContains(inst.component, basename)) {
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
/// One rolled-up BOM line: the instances a fab would buy as a single part
/// number, and the refs they were rolled up from. Declared ONCE, at file scope,
/// because the CSV writer and the schematic-embed HTML writer both roll the same
/// board up and a private copy each is how one surface's parts list comes to
/// disagree with the other's.
const BomLine = struct {
    component: []const u8,
    value: []const u8,
    footprint: []const u8,
    attrs: []const []const u8,
    properties: []const env_mod.Property,
    dnp: bool,
    /// The part's assembly-variant clauses. Part of the line identity for the
    /// same reason `dnp` is: two same-value parts populated in DIFFERENT
    /// variants are two purchase decisions, and rolling them together would
    /// make the per-variant population column answer for neither.
    variants: env_mod.InstanceVariants,
    count: u32,
    refs: std.ArrayList([]const u8),

    /// True when `inst` belongs on this line — the identity a purchase order is
    /// placed on. DNP is part of it: a do-not-populate part is a different line
    /// from the populated part it shadows, however identical the rest reads.
    fn groups(self: BomLine, inst: env_mod.Instance) bool {
        if (self.dnp != inst.dnp) return false;
        if (!variants.rulesEqual(self.variants.rules, inst.variants.rules)) return false;
        if (!std.mem.eql(u8, self.component, inst.component)) return false;
        if (!std.mem.eql(u8, self.value, inst.value)) return false;
        if (!std.mem.eql(u8, self.footprint, inst.footprint)) return false;
        return attrsEqual(self.attrs, inst.attrs);
    }

    /// The line `inst` opens when nothing already on the BOM groups it.
    fn first(inst: env_mod.Instance, refs: std.ArrayList([]const u8)) BomLine {
        return .{
            .component = inst.component,
            .value = inst.value,
            .footprint = inst.footprint,
            .attrs = inst.attrs,
            .properties = inst.properties,
            .dnp = inst.dnp,
            .variants = inst.variants,
            .count = 1,
            .refs = refs,
        };
    }
};

pub fn writeSchematicBomHtml(allocator: std.mem.Allocator, wr: anytype, block: *const env_mod.DesignBlock) BomError!void {
    const Instance = env_mod.Instance;
    var all: std.ArrayList(Instance) = .empty;
    try bomCollectInstancesHierarchical(allocator, block, "", &all);
    if (all.items.len == 0) return;

    var lines: std.ArrayList(BomLine) = .empty;
    for (all.items) |inst| {
        // Test points are probe pads, not parts a fab sources. They
        // surface in the dedicated TestPoints table on the review
        // embed; suppress them from the parts BOM in every renderer.
        if (env_mod.isTestPoint(inst.component)) continue;
        var found = false;
        for (lines.items) |*line| {
            if (line.groups(inst)) {
                line.count += 1;
                try line.refs.append(allocator, inst.ref_des);
                found = true;
                break;
            }
        }
        if (!found) {
            var refs: std.ArrayList([]const u8) = .empty;
            try refs.append(allocator, inst.ref_des);
            try lines.append(allocator, BomLine.first(inst, refs));
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
    var all: std.ArrayList(Instance) = .empty;
    try bomCollectInstances(allocator, block, &all);
    if (all.items.len == 0) return;

    var lines: std.ArrayList(BomLine) = .empty;
    for (all.items) |inst| {
        // Test points are probe pads, not parts a fab sources. They
        // surface in the dedicated TestPoints table on the review
        // embed; suppress them from the parts BOM in every renderer.
        if (env_mod.isTestPoint(inst.component)) continue;
        var found = false;
        for (lines.items) |*line| {
            if (line.groups(inst)) {
                line.count += 1;
                try line.refs.append(allocator, inst.ref_des);
                found = true;
                break;
            }
        }
        if (!found) {
            var refs: std.ArrayList([]const u8) = .empty;
            try refs.append(allocator, inst.ref_des);
            try lines.append(allocator, BomLine.first(inst, refs));
        }
    }

    // Sort by count desc, then component name
    std.mem.sortUnstable(BomLine, lines.items, {}, struct {
        fn lt(_: void, a: BomLine, b: BomLine) bool {
            if (a.count != b.count) return a.count > b.count;
            return std.mem.order(u8, a.component, b.component) == .lt;
        }
    }.lt);

    // CSV header. The per-variant population column exists only for a design
    // that declares variants, so every single-assembly BOM keeps the exact nine
    // columns it has always had.
    const declares_variants = block.variants.decls.len > 0;
    try w.writeAll("Qty,References,Component,Value,Footprint,MPN,Manufacturer,Datasheet,DNP");
    if (declares_variants) try w.writeAll(",Populated In");
    try w.writeAll("\r\n");

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
        if (declares_variants) {
            try w.writeAll(",");
            try writeCsvField(w, try populatedInText(allocator, block, line));
        }
        try w.writeAll("\r\n");
    }
}

/// The `Populated In` cell: every declared variant this line's parts are
/// stuffed in, semicolon-separated. Empty means "no variant populates it" — a
/// part that only exists as a footprint option on the board.
fn populatedInText(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    line: BomLine,
) std.mem.Allocator.Error![]const u8 {
    const base_dnp = variants.unconditionalDnp(line.dnp, line.variants.rules);
    var out: std.Io.Writer.Allocating = .init(allocator);
    var written: usize = 0;
    for (block.variants.decls) |decl| {
        if (!variants.populatedIn(line.variants.rules, base_dnp, decl.name)) continue;
        if (written > 0) out.writer.writeAll("; ") catch return error.OutOfMemory;
        out.writer.writeAll(decl.name) catch return error.OutOfMemory;
        written += 1;
    }
    return out.written();
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

fn bomCollectInstances(allocator: std.mem.Allocator, block: *const env_mod.DesignBlock, out: *std.ArrayList(env_mod.Instance)) !void {
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
    out: *std.ArrayList(env_mod.Instance),
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
                const content = dir.readFileAlloc(allocator, entry.name, lib_limits.max_lib_file_bytes) catch |err| {
                    // Unlike the by-name pinout readers, `entry` came from this
                    // directory's own iterator: there is no ordinary "absent"
                    // case to stay quiet about. Every failure here drops a real
                    // pinout out of the pin cache, so the BOM and the schematic
                    // show that part with fewer pads than it has. Warn on all
                    // of them and keep building the rest of the cache.
                    log.warn("bom: pinout '{s}/{s}' not loaded ({s}) — its pins are missing from the BOM and pin cache", .{ d.path, entry.name, @errorName(err) });
                    continue;
                };
                const nodes = parser_mod.parse(allocator, content) catch continue;
                if (nodes.len == 0) continue;
                const top = nodes[0].asList() orelse continue;
                if (top.len < 2) continue;
                const head = top[0].asAtom() orelse continue;
                if (!std.mem.eql(u8, head, d.form)) continue;
                const item_name = top[1].asString() orelse (top[1].asAtom() orelse continue);
                if (cache.contains(item_name)) continue; // package takes priority

                var pins: std.ArrayList(SymbolPin) = .empty;
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

        var nc_pins: std.ArrayList(env_mod.PartPin) = .empty;
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
    const fp_sub = std.fmt.allocPrint(allocator, footprint_path_fmt, .{footprint}) catch return false;
    defer allocator.free(fp_sub);
    const content = stdlib.read(allocator, project_dir, fp_sub, lib_limits.max_footprint_bytes) orelse return false;
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
        if (prefix.len > 0 and !isStdRefDes(inst.ref_des)) {
            try writeJsonEscaped(w, prefix);
            try w.writeAll("/");
        }
        const fp_ok = footprintHasPads(allocator, project_dir, inst.footprint);
        // Every design-derived string (ref-des, symbol, footprint, value,
        // component) routes through writeJsonEscaped so a `"` or `\` in a part
        // value/name (inch marks, Windows paths) can't corrupt the JSON payload.
        try writeJsonEscaped(w, inst.ref_des);
        try w.writeAll("\":{\"symbol\":\"");
        try writeJsonEscaped(w, inst.symbol);
        try w.writeAll("\",\"footprint\":\"");
        try writeJsonEscaped(w, inst.footprint);
        try w.print("\",\"fpOk\":{s},\"value\":\"", .{if (fp_ok) "true" else "false"});
        try writeJsonEscaped(w, inst.value);
        try w.writeAll("\",\"component\":\"");
        try writeJsonEscaped(w, inst.component);
        try w.print("\",\"srcOff\":{d},\"note\":\"", .{inst.source_offset});
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
                try w.writeAll("{\"num\":\"");
                try writeJsonEscaped(w, pp.pin);
                try w.writeAll("\",\"net\":\"");
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
                try w.writeAll("{\"num\":\"");
                try writeJsonEscaped(w, sp.num);
                try w.writeAll("\",\"name\":\"");
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
    return na.baseNetName(net_name.leaf(name));
}

/// Emit a `{ "<net>": [{ref_des, pin}, …], … }` object grouping every pin
/// reference by its base net name, applying `net_ties` to merge sub-block
/// nets into the parent's name (so `ldo/VIN` collapses into `VDD`).
pub fn writeNetsJson(allocator: std.mem.Allocator, w: anytype, block: *const env_mod.DesignBlock, prefix: []const u8) BomError!bool {
    // Build rename map from net_ties: "sb_name/port" → "parent_net"
    var rename = std.StringHashMapUnmanaged([]const u8).empty;
    for (block.net_ties) |nt| {
        // A tie like (a="VDD", b="ldo/VIN") means rename "ldo/VIN" → "VDD"
        const has_slash_a = std.mem.indexOfScalar(u8, nt.a, '/') != null;
        const has_slash_b = std.mem.indexOfScalar(u8, nt.b, '/') != null;
        if (!has_slash_a and has_slash_b) {
            try rename.put(allocator, nt.b, nt.a);
        } else if (has_slash_a and !has_slash_b) {
            try rename.put(allocator, nt.a, nt.b);
        }
    }

    // Collect pins grouped by resolved base net name, preserving order
    const PinRef = struct { ref_des: []const u8, pin: []const u8 };
    var grouped = std.array_hash_map.String(std.ArrayList(PinRef)).empty;

    // Helper to resolve and group a net
    const addNet = struct {
        fn add(
            g: *std.array_hash_map.String(std.ArrayList(PinRef)),
            alloc: std.mem.Allocator,
            name: []const u8,
            pfx: []const u8,
            pins: []const env_mod.PinRef,
        ) !void {
            const base = baseNetName(name);
            const gop = try g.getOrPut(alloc, base);
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
        if (prefix.len > 0) {
            try writeJsonEscaped(w, prefix);
            try w.writeAll("/");
        }
        try writeJsonEscaped(w, entry.key_ptr.*);
        try w.writeAll("\":[");
        for (entry.value_ptr.items, 0..) |pin, pi| {
            if (pi > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try writeJsonEscaped(w, pin.ref_des);
            try w.writeAll(".");
            try writeJsonEscaped(w, pin.pin);
            try w.writeAll("\"");
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

/// Headline numbers for the exact parts list `writeBomCsv` emits: how many
/// parts get placed, how many distinct purchasing lines they group into, and
/// how much of each is do-not-populate.
pub const BomRollup = struct {
    placements: usize = 0,
    lines: usize = 0,
    dnp_placements: usize = 0,
    dnp_lines: usize = 0,
};

/// Roll up the BOM without rendering it. This deliberately mirrors
/// `writeBomCsv`'s collection walk and grouping key — including its
/// do-not-populate split and its test-point exclusion — so a document that
/// quotes these numbers can never disagree with the archived `bom.csv` beside
/// it. `countBom` answers a different question (the schematic card's
/// hierarchical, DNP-blind card count) and is not interchangeable.
pub fn rollupBom(allocator: std.mem.Allocator, block: *const env_mod.DesignBlock) BomError!BomRollup {
    var all: std.ArrayList(env_mod.Instance) = .empty;
    try bomCollectInstances(allocator, block, &all);

    const Key = struct {
        component: []const u8,
        value: []const u8,
        footprint: []const u8,
        attrs: []const []const u8,
        dnp: bool,
    };
    var keys: std.ArrayList(Key) = .empty;
    var rollup: BomRollup = .{};
    for (all.items) |inst| {
        if (env_mod.isTestPoint(inst.component)) continue;
        rollup.placements += 1;
        if (inst.dnp) rollup.dnp_placements += 1;
        var found = false;
        for (keys.items) |k| {
            if (k.dnp != inst.dnp) continue;
            if (!std.mem.eql(u8, k.component, inst.component)) continue;
            if (!std.mem.eql(u8, k.value, inst.value)) continue;
            if (!std.mem.eql(u8, k.footprint, inst.footprint)) continue;
            if (!attrsEqual(k.attrs, inst.attrs)) continue;
            found = true;
            break;
        }
        if (found) continue;
        try keys.append(allocator, .{
            .component = inst.component,
            .value = inst.value,
            .footprint = inst.footprint,
            .attrs = inst.attrs,
            .dnp = inst.dnp,
        });
        rollup.lines += 1;
        if (inst.dnp) rollup.dnp_lines += 1;
    }
    return rollup;
}

/// Count BOM lines + total parts without rendering the table — used for the
/// collapsed BOM card's `<summary>` count. Mirrors `writeSchematicBomHtml`'s
/// dedup keys exactly so the headline numbers match the expanded table.
pub fn countBom(allocator: std.mem.Allocator, block: *const env_mod.DesignBlock) BomError!BomCounts {
    var all: std.ArrayList(env_mod.Instance) = .empty;
    try bomCollectInstancesHierarchical(allocator, block, "", &all);

    const Key = struct {
        component: []const u8,
        value: []const u8,
        footprint: []const u8,
        attrs: []const []const u8,
    };
    var keys: std.ArrayList(Key) = .empty;
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

test "BomLine.groups rolls up identical parts and never merges across DNP" {
    // One predicate serves the CSV writer and the schematic-embed HTML writer, so
    // a change here moves both together. Each field below is an independent
    // reason NOT to roll two instances onto one purchase line.
    const base = env_mod.Instance{
        .ref_des = "R1",
        .component = "res-0402",
        .value = "10k",
        .footprint = "R_0402",
        .symbol = "R",
        .dnp = false,
    };
    const line = BomLine.first(base, .empty);
    try std.testing.expect(line.groups(base));

    var other_ref = base;
    other_ref.ref_des = "R2"; // the ONE field a roll-up is allowed to differ on
    try std.testing.expect(line.groups(other_ref));

    var dnp = base;
    dnp.dnp = true;
    try std.testing.expect(!line.groups(dnp));

    var other_value = base;
    other_value.value = "10k5";
    try std.testing.expect(!line.groups(other_value));

    var other_component = base;
    other_component.component = "res-0603";
    try std.testing.expect(!line.groups(other_component));

    var other_footprint = base;
    other_footprint.footprint = "R_0603";
    try std.testing.expect(!line.groups(other_footprint));

    const attrs = [_][]const u8{"tolerance=1%"};
    var other_attrs = base;
    other_attrs.attrs = &attrs;
    try std.testing.expect(!line.groups(other_attrs));
}

test "eitherContains pairs a model basename with a longer footprint name" {
    // The 3D-model scan must match in BOTH directions: a `lib/models` basename is
    // as often a prefix of the footprint name as the other way round.
    try std.testing.expect(eitherContains("C_0402_1005Metric", "C_0402"));
    try std.testing.expect(eitherContains("C_0402", "C_0402_1005Metric"));
    try std.testing.expect(!eitherContains("C_0402", "R_0603"));
}

test "footprintHasPads reports false when the path allocation fails" {
    // The `catch return false` on the path allocPrint must stay false on
    // failure; a `false`->`true` flip would claim pads exist on OOM.
    var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expect(!footprintHasPads(fa.allocator(), "/proj", "some_fp"));
}

// spec: Web Server - The BOM symbol-pin cache reads library pinouts at the class-owned lib_limits cap, so a pinout past the retired 256 KiB figure still contributes its pads
test "buildSymbolPinCache loads a pinout past the retired 256 KiB cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The cap is `lib_limits`', not a literal here: a pinout in the
    // 256 KiB..1 MiB band used to be skipped by `catch continue`, so the BOM
    // and the schematic showed that part with fewer pads than it has.
    const data = try lib_limits.synthPinoutSource(alloc, "big", lib_limits.retired_lib_file_cap_bytes + 4096);
    try std.testing.expect(data.len > lib_limits.retired_lib_file_cap_bytes);
    try std.testing.expect(data.len < lib_limits.max_lib_file_bytes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/pinouts");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/pinouts/big.sexp", .data = data });
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const cache = try buildSymbolPinCache(alloc, project_dir);
    const pins = cache.get("big") orelse return error.TestUnexpectedResult;
    // Last row in the file: present only if the whole file was read.
    try std.testing.expectEqualStrings("LAST", pins[pins.len - 1].num);
    try std.testing.expectEqualStrings("LASTFN", pins[pins.len - 1].name);
}

// spec: Web Server - The schematic BOM card escapes every attacker-writable field it renders — component, value, footprint, attrs, MPN, manufacturer and property keys — and refuses to make a link out of a non-http datasheet URL
test "the schematic BOM card escapes every field a user can write into it" {
    // JUL-S5. The fix routes all of these through escape.writeXml, and the
    // escaper has its own test — but nothing asserted that THIS module still
    // calls it, which is exactly the shape JUL-S4 reopened in: a correct
    // central escaper and an unchecked call site. MPN and manufacturer are
    // directly attacker-writable through editMpnApi, and they land in an
    // ATTRIBUTE (`value="…"`), where an unescaped quote is a breakout with no
    // angle bracket required.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const props = [_]env_mod.Property{
        .{ .key = "mpn", .value = "\"><script>alert('mpn')</script>" },
        .{ .key = "manufacturer", .value = "\"><img src=x onerror=alert('mfr')>" },
        // A non-http scheme must render inert rather than becoming an href.
        .{ .key = "datasheet", .value = "javascript:alert('ds')" },
        // Both halves of an arbitrary property are written; both are escaped.
        .{ .key = "<key>", .value = "<val>" },
    };
    const attrs = [_][]const u8{"<attr>"};
    const instances = [_]env_mod.Instance{.{
        .ref_des = "U<1>",
        .component = "<script>alert('comp')</script>",
        .value = "\"><b>v</b>",
        .footprint = "<fp>",
        .symbol = "generic",
        .properties = &props,
        .attrs = &attrs,
    }};
    const block = env_mod.DesignBlock{
        .name = "Board",
        .instances = &instances,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };

    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeSchematicBomHtml(alloc, &aw.writer, &block);
    const html = aw.written();

    // Nothing the design supplied may reach the page as live markup. `<` is
    // the only character that can open a tag, and the card writes no `<` of
    // its own that is followed by one of these payloads.
    try std.testing.expect(std.mem.indexOf(u8, html, "<script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<img src=x") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<b>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<fp>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<attr>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<key>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<val>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "U<1>") == null);

    // And each one is present in escaped form, so the assertions above are
    // passing because the field was escaped, not because it was dropped.
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;script&gt;alert(&#39;comp&#39;)&lt;/script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&quot;&gt;&lt;b&gt;v&lt;/b&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;fp&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;attr&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&lt;key&gt;: &lt;val&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "U&lt;1&gt;") != null);

    // The editable MPN/manufacturer inputs are the attribute-context sinks: an
    // unescaped `"` here closes `value="` and the rest is markup.
    try std.testing.expect(std.mem.indexOf(u8, html, "&quot;&gt;&lt;script&gt;alert(&#39;mpn&#39;)&lt;/script&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "&quot;&gt;&lt;img src=x onerror=alert(&#39;mfr&#39;)&gt;") != null);

    // The datasheet is a scheme decision, not an escaping one: a javascript:
    // URL is rendered as inert text, never as an href.
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"javascript:") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "datasheet: javascript:alert(&#39;ds&#39;)") != null);
}

// spec: Web Server - The BOM card links a datasheet only for an http(s) or site-absolute URL, and that link is emitted with rel="noopener noreferrer"
test "the BOM card links an http datasheet and leaves a data: URL inert" {
    // The companion to the test above: prove the safe path still produces a
    // real link, so "no href" is not passing for the trivial reason that the
    // card stopped linking datasheets at all.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = [_]struct { url: []const u8, linked: bool }{
        .{ .url = "https://example.com/ds.pdf", .linked = true },
        .{ .url = "http://example.com/ds.pdf", .linked = true },
        .{ .url = "/lib/datasheets/ds.pdf", .linked = true },
        .{ .url = "data:text/html,<script>alert(1)</script>", .linked = false },
        .{ .url = "javascript:alert(1)", .linked = false },
        .{ .url = "vbscript:msgbox(1)", .linked = false },
        .{ .url = "ds.pdf", .linked = false },
    };
    for (cases) |case| {
        const props = [_]env_mod.Property{.{ .key = "datasheet", .value = case.url }};
        const instances = [_]env_mod.Instance{.{
            .ref_des = "U1",
            .component = "part",
            .value = "",
            .footprint = "fp",
            .symbol = "generic",
            .properties = &props,
        }};
        const block = env_mod.DesignBlock{
            .name = "Board",
            .instances = &instances,
            .nets = &.{},
            .ports = &.{},
            .notes = &.{},
            .groups = &.{},
            .sub_blocks = &.{},
        };
        var aw: std.Io.Writer.Allocating = .init(alloc);
        try writeSchematicBomHtml(alloc, &aw.writer, &block);
        const html = aw.written();
        const has_link = std.mem.indexOf(u8, html, "sch-bom-tag-link") != null;
        try std.testing.expectEqual(case.linked, has_link);
        if (case.linked) {
            try std.testing.expect(std.mem.indexOf(u8, html, "rel=\"noopener noreferrer\"") != null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, html, "href=\"") == null);
        }
    }
}
