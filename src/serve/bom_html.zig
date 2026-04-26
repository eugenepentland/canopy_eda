const std = @import("std");
const env_mod = @import("../eval/env.zig");
const parser_mod = @import("../sexpr/parser.zig");
const json_writer = @import("../json_writer.zig");

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
) !void {
    for (block.instances) |inst| {
        // Check footprint
        if (inst.footprint.len > 0 and !checked_fp.contains(inst.footprint)) {
            try checked_fp.put(inst.footprint, {});
            const fp_path = try std.fmt.allocPrint(allocator, "{s}/lib/footprints/{s}.sexp", .{ project_dir, inst.footprint });
            defer allocator.free(fp_path);
            std.fs.cwd().access(fp_path, .{}) catch {
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
                if (std.fs.cwd().access(m, .{})) |_| {
                    found = true;
                    break;
                } else |_| {}
            }
            // Fuzzy scan: check if any model filename contains/is contained by footprint or component name
            if (!found) {
                const models_path = try std.fmt.allocPrint(allocator, "{s}/lib/models", .{project_dir});
                defer allocator.free(models_path);
                var dir = std.fs.cwd().openDir(models_path, .{ .iterate = true }) catch null;
                if (dir) |*d| {
                    defer d.close();
                    var iter = d.iterate();
                    while (iter.next() catch null) |entry| {
                        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".step")) continue;
                        const basename = entry.name[0 .. entry.name.len - 5];
                        if ((inst.footprint.len > 0 and (std.mem.indexOf(u8, inst.footprint, basename) != null or std.mem.indexOf(u8, basename, inst.footprint) != null)) or
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

/// Render the design's parts list as an HTML BOM table (component, value,
/// footprint, attrs, count, refs) with inline value-edit controls that
/// POST to `/api/edit-value/:name`.
pub fn writeBomHtml(wr: anytype, block: *const env_mod.DesignBlock) !void {
    const Instance = env_mod.Instance;
    var all: std.ArrayListUnmanaged(Instance) = .empty;
    try bomCollectInstances(block, &all);
    if (all.items.len == 0) return;

    const BomLine = struct {
        component: []const u8,
        value: []const u8,
        footprint: []const u8,
        attrs: []const []const u8,
        properties: []const env_mod.Property,
        count: u32,
        refs: std.ArrayListUnmanaged([]const u8),
        source_offsets: std.ArrayListUnmanaged(u32),
    };

    var lines: std.ArrayListUnmanaged(BomLine) = .empty;

    for (all.items) |inst| {
        var found = false;
        for (lines.items) |*line| {
            if (std.mem.eql(u8, line.component, inst.component) and
                std.mem.eql(u8, line.value, inst.value) and
                std.mem.eql(u8, line.footprint, inst.footprint) and
                attrsEqual(line.attrs, inst.attrs))
            {
                line.count += 1;
                try line.refs.append(std.heap.page_allocator, inst.ref_des);
                try line.source_offsets.append(std.heap.page_allocator, inst.source_offset);
                found = true;
                break;
            }
        }
        if (!found) {
            var refs: std.ArrayListUnmanaged([]const u8) = .empty;
            try refs.append(std.heap.page_allocator, inst.ref_des);
            var offsets: std.ArrayListUnmanaged(u32) = .empty;
            try offsets.append(std.heap.page_allocator, inst.source_offset);
            try lines.append(std.heap.page_allocator, .{
                .component = inst.component,
                .value = inst.value,
                .footprint = inst.footprint,
                .attrs = inst.attrs,
                .properties = inst.properties,
                .count = 1,
                .refs = refs,
                .source_offsets = offsets,
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

    try wr.writeAll("<div class=\"bom-section\"><h2>Bill of Materials</h2>");
    try wr.writeAll("<table class=\"bom-table\"><thead><tr>");
    try wr.writeAll("<th>Qty</th><th>Ref Des</th><th>Component</th><th>Value</th><th>Package</th><th>Attributes</th><th>Datasheet</th>");
    try wr.writeAll("</tr></thead><tbody>");

    var total: u32 = 0;
    for (lines.items, 0..) |line, li| {
        total += line.count;
        try wr.writeAll("<tr>");
        try wr.print("<td>{d}</td>", .{line.count});

        // Refs
        try wr.writeAll("<td class=\"bom-refs\" title=\"");
        for (line.refs.items, 0..) |r, i| {
            if (i > 0) try wr.writeAll(", ");
            try wr.writeAll(r);
        }
        try wr.writeAll("\">");
        for (line.refs.items, 0..) |r, i| {
            if (i > 0) try wr.writeAll(", ");
            try wr.writeAll(r);
        }
        try wr.writeAll("</td>");

        // Component
        try wr.print("<td class=\"bom-pkg\">{s}</td>", .{line.component});

        // Value
        try wr.print("<td>{s}</td>", .{line.value});

        // Package — editable dropdown for passive families
        try wr.writeAll("<td class=\"bom-pkg\">");
        const fp_prefix = getPassivePrefix(line.component);
        if (fp_prefix.len > 0) {
            // Editable select
            try wr.print("<select class=\"bom-fp-select\" data-row=\"{d}\" data-component=\"{s}\" data-refs=\"", .{ li, line.component });
            for (line.refs.items, 0..) |r, i| {
                if (i > 0) try wr.writeAll(",");
                try wr.writeAll(r);
            }
            try wr.writeAll("\" data-srcoffs=\"");
            for (line.source_offsets.items, 0..) |off, i| {
                if (i > 0) try wr.writeAll(",");
                try wr.print("{d}", .{off});
            }
            try wr.writeAll("\">");
            // Options will be populated by JS from FAMILIES
            try wr.print("<option value=\"{s}\" selected>{s}</option>", .{ line.component, line.component });
            try wr.writeAll("</select>");
        } else {
            try wr.writeAll(line.footprint);
        }
        try wr.writeAll("</td>");

        // Attributes — combined column: attrs + properties
        try wr.writeAll("<td class=\"bom-attrs\">");
        var attr_written = false;
        for (line.attrs) |attr| {
            if (attr_written) try wr.writeAll(" ");
            try wr.print("<span class=\"bom-tag bom-tag-attr\">{s}</span>", .{attr});
            attr_written = true;
        }
        for (line.properties) |prop| {
            if (attr_written) try wr.writeAll(" ");
            try wr.print("<span class=\"bom-tag bom-tag-prop\">{s}: {s}</span>", .{ prop.key, prop.value });
            attr_written = true;
        }
        try wr.writeAll("</td>");

        // Datasheet link
        try wr.writeAll("<td>");
        for (line.properties) |prop| {
            if (std.mem.eql(u8, prop.key, "datasheet")) {
                try wr.print("<a href=\"{s}\" target=\"_blank\" style=\"color:#58a6ff\">PDF</a>", .{prop.value});
                break;
            }
        }
        try wr.writeAll("</td>");

        try wr.writeAll("</tr>");
    }

    try wr.writeAll("</tbody></table>");
    try wr.print("<div class=\"bom-total\">{d} unique lines, {d} total parts</div>", .{ lines.items.len, total });

    // JS for BOM footprint editing
    try wr.writeAll(
        \\<script>document.addEventListener('DOMContentLoaded',function(){
        \\var selects=document.querySelectorAll('.bom-fp-select');
        \\selects.forEach(function(sel){
        \\  var comp=sel.getAttribute('data-component');
        \\  var prefix=(comp.match(/^(cap|res|ind|led)-/)||[])[1];
        \\  if(prefix&&FAMILIES[prefix]){
        \\    var current=sel.value;
        \\    sel.innerHTML='';
        \\    FAMILIES[prefix].forEach(function(f){
        \\      var opt=document.createElement('option');
        \\      opt.value=f;opt.textContent=f;
        \\      if(f===current)opt.selected=true;
        \\      sel.appendChild(opt);
        \\    });
        \\  }
        \\  sel.addEventListener('change',function(){
        \\    var newComp=sel.value;
        \\    var oldComp=sel.getAttribute('data-component');
        \\    var refs=sel.getAttribute('data-refs').split(',');
        \\    var srcoffs=sel.getAttribute('data-srcoffs').split(',').map(Number);
        \\    function editNext(i){
        \\      if(i>=refs.length){sel.setAttribute('data-component',newComp);location.reload();return;}
        \\      fetch('/api/edit-footprint/'+SCHEMATIC_SLUG,{
        \\        method:'POST',
        \\        headers:{'Content-Type':'application/json'},
        \\        body:JSON.stringify({ref:refs[i],component:newComp,oldComponent:oldComp,srcOff:srcoffs[i]})
        \\      }).then(function(r){return r.json();}).then(function(d){
        \\        if(d.components){for(var k in d.components){var c=d.components[k];if(c.srcOff!==undefined){
        \\          var idx=refs.indexOf(k);if(idx>=0)srcoffs[idx]=c.srcOff;
        \\        }}}
        \\        editNext(i+1);
        \\      });
        \\    }
        \\    editNext(0);
        \\  });
        \\});
        \\});</script>
    );

    try wr.writeAll("</div>");
}

/// Return `"cap"`, `"res"`, `"ind"`, or `"led"` when `component` is a
/// passive part name like `cap-0402`, otherwise the empty string. Used to
/// route value edits through the right `(cap …)` / `(res …)` builder.
pub fn getPassivePrefix(component: []const u8) []const u8 {
    const prefixes = [_][]const u8{ "cap", "res", "ind", "led" };
    for (prefixes) |pfx| {
        if (std.mem.startsWith(u8, component, pfx) and component.len > pfx.len and component[pfx.len] == '-') return pfx;
    }
    return "";
}

/// Emit the parts list as CSV (component, value, footprint, count, refs,
/// then any extra `attrs` columns). Used by `exportBomCsvApi` and the
/// review-package zip exporter.
pub fn writeBomCsv(w: anytype, block: *const env_mod.DesignBlock) !void {
    const Instance = env_mod.Instance;
    var all: std.ArrayListUnmanaged(Instance) = .empty;
    try bomCollectInstances(block, &all);
    if (all.items.len == 0) return;

    const BomLine = struct {
        component: []const u8,
        value: []const u8,
        footprint: []const u8,
        properties: []const env_mod.Property,
        attrs: []const []const u8,
        count: u32,
        refs: std.ArrayListUnmanaged([]const u8),
    };

    var lines: std.ArrayListUnmanaged(BomLine) = .empty;
    for (all.items) |inst| {
        var found = false;
        for (lines.items) |*line| {
            if (std.mem.eql(u8, line.component, inst.component) and
                std.mem.eql(u8, line.value, inst.value) and
                std.mem.eql(u8, line.footprint, inst.footprint) and
                attrsEqual(line.attrs, inst.attrs))
            {
                line.count += 1;
                try line.refs.append(std.heap.page_allocator, inst.ref_des);
                found = true;
                break;
            }
        }
        if (!found) {
            var refs: std.ArrayListUnmanaged([]const u8) = .empty;
            try refs.append(std.heap.page_allocator, inst.ref_des);
            try lines.append(std.heap.page_allocator, .{
                .component = inst.component,
                .value = inst.value,
                .footprint = inst.footprint,
                .properties = inst.properties,
                .attrs = inst.attrs,
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
    try w.writeAll("Qty,References,Component,Value,Footprint,MPN,Manufacturer,Datasheet\r\n");

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

fn bomCollectInstances(block: *const env_mod.DesignBlock, out: *std.ArrayListUnmanaged(env_mod.Instance)) !void {
    for (block.instances) |inst| {
        try out.append(std.heap.page_allocator, inst);
    }
    for (block.sub_blocks) |sb| {
        try bomCollectInstances(sb.block, out);
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
pub fn buildSymbolPinCache(allocator: std.mem.Allocator, project_dir: []const u8) !SymbolPinCache {
    var cache: SymbolPinCache = .empty;
    const dirs = [_]struct { path: []const u8, form: []const u8 }{
        .{ .path = "lib/pinouts", .form = "pinout" },
    };
    for (dirs) |d| {
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, d.path });
        defer allocator.free(dir_path);
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch continue;
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
                            const i: i64 = @intFromFloat(n);
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
pub fn augmentUnconnectedPins(allocator: std.mem.Allocator, block: *env_mod.DesignBlock, sym_cache: *const SymbolPinCache) !void {
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
    const content = std.fs.cwd().readFileAlloc(allocator, fp_path, 256 * 1024) catch return false;
    defer allocator.free(content);
    return std.mem.indexOf(u8, content, "(pad ") != null;
}

/// Walk the design hierarchy and emit a `{ "<refdes>": {…}, … }` object
/// keyed on hierarchical ref-des, embedding each instance's symbol,
/// footprint, value, source offset, note text, pin-net pairs, and full
/// symbol-pin list. Returns true when at least one entry was written.
pub fn writeComponentsJson(w: anytype, block: *const env_mod.DesignBlock, prefix: []const u8, sym_cache: *const SymbolPinCache, allocator: std.mem.Allocator, project_dir: []const u8) !bool {
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
pub fn writeNetsJson(w: anytype, block: *const env_mod.DesignBlock, prefix: []const u8) !bool {
    const allocator = std.heap.page_allocator;

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
        fn add(g: *std.StringArrayHashMap(std.ArrayListUnmanaged(PinRef)), alloc: std.mem.Allocator, name: []const u8, pfx: []const u8, pins: []const env_mod.PinRef) !void {
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
