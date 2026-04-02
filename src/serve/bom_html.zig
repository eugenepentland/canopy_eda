const std = @import("std");
const env_mod = @import("../eval/env.zig");
const parser_mod = @import("../sexpr/parser.zig");

// ── Symbol pin cache ──────────────────────────────────────────────────

pub const SymbolPin = struct {
    num: []const u8,
    name: []const u8,
};

pub const SymbolPinCache = std.StringHashMapUnmanaged([]const SymbolPin);

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
                line.refs.append(std.heap.page_allocator, inst.ref_des) catch {};
                line.source_offsets.append(std.heap.page_allocator, inst.source_offset) catch {};
                found = true;
                break;
            }
        }
        if (!found) {
            var refs: std.ArrayListUnmanaged([]const u8) = .empty;
            refs.append(std.heap.page_allocator, inst.ref_des) catch {};
            var offsets: std.ArrayListUnmanaged(u32) = .empty;
            offsets.append(std.heap.page_allocator, inst.source_offset) catch {};
            lines.append(std.heap.page_allocator, .{
                .component = inst.component,
                .value = inst.value,
                .footprint = inst.footprint,
                .attrs = inst.attrs,
                .properties = inst.properties,
                .count = 1,
                .refs = refs,
                .source_offsets = offsets,
            }) catch {};
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
    try wr.writeAll("<th>Qty</th><th>Ref Des</th><th>Component</th><th>Value</th><th>Package</th><th>Attributes</th>");
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

pub fn getPassivePrefix(component: []const u8) []const u8 {
    const prefixes = [_][]const u8{ "cap", "res", "ind", "led" };
    for (prefixes) |pfx| {
        if (std.mem.startsWith(u8, component, pfx) and component.len > pfx.len and component[pfx.len] == '-') return pfx;
    }
    return "";
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

pub fn footprintHasPads(allocator: std.mem.Allocator, project_dir: []const u8, footprint: []const u8) bool {
    if (footprint.len == 0) return false;
    const fp_path = std.fmt.allocPrint(allocator, "{s}/lib/footprints/{s}.sexp", .{ project_dir, footprint }) catch return false;
    defer allocator.free(fp_path);
    const content = std.fs.cwd().readFileAlloc(allocator, fp_path, 256 * 1024) catch return false;
    defer allocator.free(content);
    return std.mem.indexOf(u8, content, "(pad ") != null;
}

pub fn writeComponentsJson(w: anytype, block: *const env_mod.DesignBlock, prefix: []const u8, sym_cache: *const SymbolPinCache, allocator: std.mem.Allocator, project_dir: []const u8) !bool {
    var written = false;
    for (block.instances) |inst| {
        if (written) try w.writeAll(",");
        try w.writeAll("\"");
        if (prefix.len > 0) try w.print("{s}/", .{prefix});
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

pub fn writeNetsJson(w: anytype, block: *const env_mod.DesignBlock, prefix: []const u8) !bool {
    var written = false;
    for (block.nets) |net| {
        if (written) try w.writeAll(",");
        try w.writeAll("\"");
        if (prefix.len > 0) try w.print("{s}/", .{prefix});
        try w.print("{s}\":[", .{net.name});
        for (net.pins, 0..) |pin, pi| {
            if (pi > 0) try w.writeAll(",");
            try w.writeAll("\"");
            if (prefix.len > 0) try w.print("{s}/", .{prefix});
            try w.print("{s}.{s}\"", .{ pin.ref_des, pin.pin });
        }
        try w.writeAll("]");
        written = true;
    }
    for (block.sub_blocks) |sb| {
        if (written) try w.writeAll(",");
        const sub_written = try writeNetsJson(w, sb.block, sb.name);
        if (sub_written) written = true;
    }
    return written;
}

pub fn writeJsonEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
}
