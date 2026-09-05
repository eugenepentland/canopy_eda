//! System-level thermal/mechanical workspace and enclosure exports.
//!
//! System manifests select the same saved PCB layouts used for fabrication;
//! an optional assembly sidecar repeats their board definitions as physical
//! instances. The page imports exact outlines, components and saved cooling,
//! while the browser couples board thermal ladders and the native Zig
//! prismatic kernel remains the authority for enclosure STEP/STL geometry.

const std = @import("std");
const httpz = @import("httpz");
const cad_document = @import("../mechanical/cad_document.zig");
const prismatic = @import("../mechanical/prismatic.zig");
const shape_sketch = @import("../shape_sketch.zig");
const json_writer = @import("../json_writer.zig");
const system_review = @import("../system_review.zig");
const system_review_assets = @import("../system_review_assets.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const pcb_step_export = @import("pcb_step_export.zig");
const navbar = @import("navbar.zig");

/// Allocation and response-write failures escaping CAD handlers.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

const max_assembly_bytes: usize = 256 * 1024;
const max_assembly_instances: usize = 256;
const assembly_schema = "netlisp-system-assembly-v1";

/// One physical occurrence of a reviewed board. The review manifest keeps one
/// immutable definition per board design; this sidecar is deliberately the
/// repeatable mechanical layer above it, so a sixteen-channel product does not
/// have to lie to the release manifest by cloning one PCB sixteen times.
const AssemblyInstance = struct {
    id: []const u8,
    board: []const u8,
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 5,
    rotation: f64 = 0,
    enabled: bool = true,
};

/// Optional `src/systems/<name>/assembly.json`. It supplies the authored seed
/// for the browser workspace; browser drags remain a local draft until the
/// user downloads or commits the sidecar, matching the existing CAD editor's
/// local-draft contract.
const AssemblySpec = struct {
    schema: []const u8,
    pitch_mm: f64 = 22,
    ambient_c: f64 = 25,
    instances: []const AssemblyInstance,
};

const ParsedAssembly = std.json.Parsed(AssemblySpec);

fn safeInstanceId(value: []const u8) bool {
    if (value.len == 0 or value.len > 128 or !std.ascii.isAlphanumeric(value[0])) return false;
    for (value[1..]) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-') continue;
        if (c != '_' and c != '.') return false;
    }
    return true;
}

fn hasBoard(spec: system_review.SystemSpec, name: []const u8) bool {
    for (spec.boards) |board| if (std.mem.eql(u8, board.name, name)) return true;
    return false;
}

fn validAssemblyHeader(assembly: AssemblySpec) bool {
    if (!std.mem.eql(u8, assembly.schema, assembly_schema)) return false;
    if (assembly.instances.len == 0 or assembly.instances.len > max_assembly_instances) return false;
    if (!std.math.isFinite(assembly.pitch_mm) or assembly.pitch_mm <= 0 or assembly.pitch_mm > 1000) return false;
    if (!std.math.isFinite(assembly.ambient_c) or assembly.ambient_c < -55 or assembly.ambient_c > 125) return false;
    return true;
}

fn validInstance(spec: system_review.SystemSpec, instance: AssemblyInstance) bool {
    if (!safeInstanceId(instance.id) or !hasBoard(spec, instance.board)) return false;
    if (!std.math.isFinite(instance.x) or !std.math.isFinite(instance.y)) return false;
    if (!std.math.isFinite(instance.z) or !std.math.isFinite(instance.rotation)) return false;
    if (@abs(instance.x) > 10_000 or @abs(instance.y) > 10_000) return false;
    if (@abs(instance.z) > 10_000) return false;
    return true;
}

fn validAssembly(spec: system_review.SystemSpec, assembly: AssemblySpec) bool {
    if (!validAssemblyHeader(assembly)) return false;
    for (assembly.instances, 0..) |instance, index| {
        if (!validInstance(spec, instance)) return false;
        for (assembly.instances[0..index]) |earlier| if (std.mem.eql(u8, earlier.id, instance.id)) return false;
    }
    return true;
}

fn readAssembly(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    spec: system_review.SystemSpec,
) ?ParsedAssembly {
    const relative = std.fmt.allocPrint(allocator, "src/systems/{s}/assembly.json", .{spec.name}) catch return null;
    defer allocator.free(relative);
    const source = system_review_assets.readContainedFile(allocator, project_dir, relative, max_assembly_bytes) catch return null;
    defer allocator.free(source);
    var parsed = std.json.parseFromSlice(AssemblySpec, allocator, source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch return null;
    if (!validAssembly(spec, parsed.value)) {
        parsed.deinit();
        return null;
    }
    return parsed;
}

fn selectedLayout(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    board: system_review.BoardMember,
) ?pcb_layout_page.SavedLayout {
    const layouts = pcb_layout_page.readLayouts(allocator, project_dir, board.name);
    if (!std.mem.eql(u8, board.layout, "blessed")) {
        for (layouts) |layout| if (std.mem.eql(u8, layout.name, board.layout)) return layout;
        return null;
    }
    for (layouts) |layout| if (layout.default) return layout;
    return if (layouts.len > 0) layouts[0] else null;
}

fn writeCooling(
    writer: *std.Io.Writer,
    layout: ?pcb_layout_page.SavedLayout,
    center: [2]f64,
) HandlerError!void {
    try writer.writeAll(",\"cooling\":{");
    if (layout) |saved| if (saved.heatsink) |sink| {
        try writer.print("\"heatsink\":{{\"x\":{d},\"y\":{d},\"w\":{d},\"d\":{d},\"side\":", .{
            sink.x + sink.w / 2 - center[0], sink.y + sink.h / 2 - center[1], sink.w, sink.h,
        });
        try json_writer.writeScriptString(writer, sink.side);
        try writer.writeAll(",\"material\":");
        try json_writer.writeScriptString(writer, sink.material);
        try writer.print(",\"base_mm\":{d},\"pad_mm\":{d},\"pad_k\":{d}", .{ sink.base_mm, sink.pad_thickness_mm, sink.pad_k_w_mk });
        switch (sink.profile) {
            .finned => |fins| try writer.print(",\"shape\":\"finned\",\"fin_height_mm\":{d},\"fin_thickness_mm\":{d},\"fin_gap_mm\":{d}", .{ fins.height_mm, fins.thickness_mm, fins.gap_mm }),
            .stepped => |lower| try writer.print(",\"shape\":\"stepped\",\"lower_w\":{d},\"lower_d\":{d},\"lower_h\":{d}", .{ lower.width_mm, lower.length_mm, lower.height_mm }),
        }
        try writer.writeByte('}');
    } else try writer.writeAll("\"heatsink\":null") else try writer.writeAll("\"heatsink\":null");
    try writer.writeByte(',');
    if (layout) |saved| if (saved.fan) |fan| {
        try writer.writeAll("\"fan\":{");
        try writer.writeAll("\"model\":");
        try json_writer.writeScriptString(writer, fan.model);
        try writer.print(",\"x\":{d},\"y\":{d},\"w\":{d},\"d\":{d},\"side\":", .{
            fan.rect.x + fan.rect.w / 2 - center[0], fan.rect.y + fan.rect.h / 2 - center[1], fan.rect.w, fan.rect.h,
        });
        try json_writer.writeScriptString(writer, fan.side);
        try writer.print(",\"distance_mm\":{d},\"flow_m3_s\":{d},\"pressure_pa\":{d},\"operating_fraction\":{d}}}", .{
            fan.distance_mm, fan.curve.free_air_flow_m3_s, fan.curve.max_static_pressure_pa, fan.operating_flow_fraction,
        });
    } else try writer.writeAll("\"fan\":null") else try writer.writeAll("\"fan\":null");
    try writer.writeByte('}');
}

fn writeAssembly(writer: *std.Io.Writer, assembly: ?AssemblySpec) HandlerError!void {
    if (assembly == null) return writer.writeAll("null");
    const value = assembly.?;
    try writer.print("{{\"pitch_mm\":{d},\"ambient_c\":{d},\"instances\":[", .{ value.pitch_mm, value.ambient_c });
    for (value.instances, 0..) |instance, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"id\":");
        try json_writer.writeScriptString(writer, instance.id);
        try writer.writeAll(",\"board\":");
        try json_writer.writeScriptString(writer, instance.board);
        try writer.print(",\"x\":{d},\"y\":{d},\"z\":{d},\"rot\":{d},\"on\":{s}}}", .{
            instance.x, instance.y, instance.z, instance.rotation, if (instance.enabled) "true" else "false",
        });
    }
    try writer.writeAll("]}");
}

fn writeBoardOutline(
    writer: *std.Io.Writer,
    poly: ?[]const [2]f64,
    rect: [4]f64,
    center: [2]f64,
) HandlerError!void {
    try writer.writeByte('[');
    if (poly) |points| {
        for (points, 0..) |point, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print("[{d},{d}]", .{ point[0] - center[0], point[1] - center[1] });
        }
    } else {
        const x0 = rect[0] - center[0];
        const y0 = rect[1] - center[1];
        const x1 = x0 + rect[2];
        const y1 = y0 + rect[3];
        try writer.print("[[{d},{d}],[{d},{d}],[{d},{d}],[{d},{d}]]", .{
            x0, y0, x1, y0, x1, y1, x0, y1,
        });
    }
    try writer.writeByte(']');
}

fn padWorld(part: anytype, x: f64, y: f64) [2]f64 {
    const local_x = if (part.side == .bottom) -x else x;
    if (part.rot == 0) return .{ part.x + local_x, part.y + y };
    const radians = part.rot * std.math.pi / 180;
    return .{
        part.x + local_x * @cos(radians) - y * @sin(radians),
        part.y + local_x * @sin(radians) + y * @cos(radians),
    };
}

fn writeBoard(
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    board: system_review.BoardMember,
    index: usize,
) HandlerError!void {
    if (index > 0) try writer.writeByte(',');
    try writer.writeAll("{");
    try writer.writeAll("\"name\":");
    try json_writer.writeScriptString(writer, board.name);
    try writer.writeAll(",\"role\":");
    try json_writer.writeScriptString(writer, board.role);
    try writer.writeAll(",\"part_number\":");
    try json_writer.writeScriptString(writer, board.part_number);
    try writer.writeAll(",\"revision\":");
    try json_writer.writeScriptString(writer, board.revision);
    try writer.writeAll(",\"layout\":");
    try json_writer.writeScriptString(writer, board.layout);

    const layout = if (std.mem.eql(u8, board.layout, "blessed")) null else board.layout;
    const view = pcb_layout_page.fabViewFor(allocator, project_dir, board.name, layout) catch |err| {
        try writer.writeAll(",\"error\":");
        try json_writer.writeScriptString(writer, @errorName(err));
        try writer.writeAll("}");
        return;
    };
    const placement = view.placement;
    const rect = placement.board_rect orelse {
        try writer.writeAll(",\"error\":\"NoBoardOutline\"}");
        return;
    };
    const cx = rect.minx + rect.w / 2;
    const cy = rect.miny + rect.h / 2;
    const thickness = if (placement.rules.physical.board_thickness > 0)
        placement.rules.physical.board_thickness
    else
        1.6;
    try writer.print(",\"width\":{d},\"depth\":{d},\"thickness\":{d},\"source_center\":[{d},{d}],\"outline\":", .{ rect.w, rect.h, thickness, cx, cy });
    try writeBoardOutline(writer, placement.board_poly, .{ rect.minx, rect.miny, rect.w, rect.h }, .{ cx, cy });
    try writer.writeAll(",\"parts\":[");
    for (placement.parts, 0..) |part, part_index| {
        if (part_index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"ref\":");
        try json_writer.writeScriptString(writer, part.ref_des);
        try writer.print(",\"x\":{d},\"y\":{d},\"w\":{d},\"d\":{d},\"rot\":{d},\"bottom\":{s}}}", .{
            part.x - cx,
            part.y - cy,
            @max(part.hw * 2, 0.4),
            @max(part.hh * 2, 0.4),
            part.rot,
            if (part.side == .bottom) "true" else "false",
        });
    }
    try writer.writeAll("],\"holes\":[");
    var hole_index: usize = 0;
    for (placement.parts) |part| for (part.pads) |pad| {
        if (!pad.npth or pad.drill <= 0) continue;
        if (hole_index > 0) try writer.writeByte(',');
        const point = padWorld(part, pad.x, pad.y);
        try writer.print("{{\"x\":{d},\"y\":{d},\"diameter\":{d}}}", .{ point[0] - cx, point[1] - cy, pad.drill });
        hole_index += 1;
    };
    try writer.writeByte(']');
    try writeCooling(writer, selectedLayout(allocator, project_dir, board), .{ cx, cy });
    try writer.writeByte('}');
}

/// Render an interactive enclosure workspace from one parsed system manifest.
pub fn page(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    spec: system_review.SystemSpec,
    can_write: bool,
    res: *httpz.Response,
) HandlerError!void {
    var parsed_assembly = readAssembly(allocator, project_dir, spec);
    defer if (parsed_assembly) |*parsed| parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(res.arena);
    const writer = &out.writer;
    try writer.writeAll(
        "<!doctype html><html><head><meta charset=\"utf-8\">" ++
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
            "<title>System Thermal</title>",
    );
    try writer.writeAll("<style>");
    try writer.writeAll(navbar.css);
    try writer.writeAll("</style>");
    try writer.print("<link rel=\"stylesheet\" href=\"/static/system_cad.css?v={x}\"></head><body>", .{std.hash.Wyhash.hash(0, @embedFile("assets/system_cad.css"))});
    try navbar.write(writer, .none);
    try writer.writeAll(
        "<header><a class=\"back\" id=\"back\">← System</a><div><h1 id=\"title\">System Thermal</h1><p id=\"identity\"></p></div>" ++
            "<span class=\"kernel\">Sketch + extrude · Zig</span><div class=\"view-switch\" role=\"group\" aria-label=\"Workspace view\"><button id=\"view-2d\" class=\"on\" aria-pressed=\"true\">2D thermal</button><button id=\"view-3d\" aria-pressed=\"false\">3D assembly</button></div><span id=\"save-status\"></span><button id=\"save\">Save design</button><button id=\"top\">Edit sketch</button><button id=\"fit\">Fit view</button>" ++
            "<button id=\"assembly-json\">Download assembly.json</button><button id=\"step\">Download STEP</button><button id=\"stl\">Download STL</button></header>" ++
            "<main><aside><section><h2>System screening</h2><div class=\"fields\">" ++
            "<label>Ambient <input id=\"ambient\" type=\"number\" min=\"-55\" max=\"125\" step=\"1\"><span>°C</span></label>" ++
            "<label>Board pitch <input id=\"pitch\" type=\"number\" min=\"1\" max=\"200\" step=\"0.5\"><span>mm</span></label>" ++
            "<label>Scale minimum <input id=\"scale-min\" type=\"number\" min=\"-55\" max=\"200\" step=\"1\"><span>°C</span></label>" ++
            "<label>Scale maximum <input id=\"scale-max\" type=\"number\" min=\"-54\" max=\"300\" step=\"1\"><span>°C</span></label></div>" ++
            "<label class=\"check\"><input id=\"snap\" type=\"checkbox\" checked> Snap board centres to pitch while dragging</label>" ++
            "<div id=\"thermal-summary\" class=\"thermal-summary\">Loading board thermal models…</div>" ++
            "<p class=\"hint\">The 2D view paints the same solved board fields as Thermal, shifted by projected fan coverage and mixed-air rise. Drag a PCB or enter its exact pose. This is a system screening model, not CFD.</p></section>" ++
            "<section><h2>Board instances</h2><p class=\"hint\">The review manifest defines board types; assembly.json may repeat them as physical instances.</p><div id=\"boards\"></div></section>" ++
            "<section><div class=\"section-head\"><h2>Fans</h2><button id=\"add-fan\">Add fan</button></div><p class=\"hint\">The blue rectangle is the fan outlet. Drag it in 2D or enter an exact pose; Z is the frame centre and the airflow footprint widens with distance.</p><div id=\"fans\"></div></section>" ++
            "<section><h2>Origin planes</h2><div id=\"plane-choices\" class=\"plane-choices\"><button data-plane=\"xy\">XY</button><button data-plane=\"xz\">XZ</button><button data-plane=\"yz\">YZ</button></div>" ++
            "<p id=\"plane-status\" class=\"hint\">XY plane selected. Click a datum plane in the viewport or choose one here.</p></section>" ++
            "<section><div class=\"section-head\"><h2>Sketches</h2><button id=\"new-sketch\">New sketch on plane</button></div>" ++
            "<p class=\"hint\">Nothing is generated from the PCBs. Pick an origin plane, create a sketch, and use the same constraint-aware tools as the PCB outline editor.</p>" ++
            "<div id=\"sketches\"></div></section>" ++
            "<section><div class=\"section-head\"><h2>Extrusions</h2><button id=\"add-extrusion\">Extrude selected</button></div><div id=\"model-status\" class=\"dimensions\">Blank workspace · 0 solids</div><div id=\"extrusions\"></div><button id=\"reset\">Reset local draft</button></section>" ++
            "<section><h2>Model boundary</h2><ul><li>PCBs, components, fans and heatsinks are reference geometry only</li><li>Only closed sketches with an explicit enabled extrusion become solids</li><li>Each extrusion remains a separate STEP/STL body</li><li>Current extrusion profiles must be convex; use separate bodies for floors and walls</li><li>No automatic enclosure, lid, boss, cutout, or boolean operation</li></ul></section></aside>" ++
            "<div id=\"viewport\"><canvas id=\"thermal-canvas\" aria-label=\"System thermal heatmap\"></canvas><canvas id=\"canvas\" hidden></canvas><div id=\"sketch-palette\" class=\"sketch-palette\" hidden>" ++
            "<div class=\"sp-head\"><b id=\"sketch-title\">Sketch</b><span id=\"sketch-dof\">0 DOF</span></div>" ++
            "<div class=\"sp-group\"><span>Create</span><button data-action=\"select\">Select</button><button data-action=\"rectangle\">Rectangle</button><button data-action=\"line-tool\">Line</button><button data-action=\"dimension\">Dimension (D)</button><button data-action=\"undo\">Undo</button><button data-action=\"redo\">Redo</button></div>" ++
            "<div class=\"sp-group\"><span>Constrain</span><button data-action=\"horizontal\">H</button><button data-action=\"vertical\">V</button><button data-action=\"coincident\">Coincident</button><button data-action=\"collinear\">Co-linear</button><button data-action=\"parallel\">∥</button><button data-action=\"perpendicular\">⟂</button><button data-action=\"tangent\">Tangent</button><button data-action=\"equal\">Equal</button><button data-action=\"midpoint\">Midpoint</button><button data-action=\"symmetric\">Symmetry</button><button data-action=\"fixed\">Fix</button></div>" ++
            "<div class=\"sp-group\"><span>Modify</span><button data-action=\"arc\">Arc</button><button data-action=\"line\">Line</button><button data-action=\"fillet\">Fillet</button><button data-action=\"remove-fillet\">Remove fillet</button><button data-action=\"chamfer\">Chamfer</button><button data-action=\"offset\">Offset</button><button data-action=\"mirror-x\">Mirror X</button><button data-action=\"mirror-y\">Mirror Y</button><button data-action=\"delete\">Delete</button></div>" ++
            "<button class=\"sp-finish sp-repair\" data-action=\"close-profile\">Close profile</button><button class=\"sp-finish sp-extrude\" data-action=\"extrude\">Extrude sketch…</button><button class=\"sp-finish\" data-action=\"finish\">Finish sketch</button></div>" ++
            "<div id=\"sketch-dimensions\" class=\"sketch-dimensions\" aria-live=\"polite\"></div>" ++
            "<form id=\"sketch-dimension-popover\" class=\"sketch-dimension-popover\" role=\"dialog\" aria-labelledby=\"sketch-dimension-title\" hidden><strong id=\"sketch-dimension-title\">Dimension</strong><label id=\"sketch-dimension-type-row\" hidden><span>Type</span><select id=\"sketch-dimension-type\"></select></label><label><span>Value</span><span class=\"dimension-value-field\"><input id=\"sketch-dimension-value\" type=\"number\" min=\"0\" step=\"any\" required><i id=\"sketch-dimension-unit\">mm</i></span></label><p id=\"sketch-dimension-error\" hidden></p><div><button type=\"button\" data-dimension-cancel>Cancel</button><button type=\"submit\" class=\"primary\">Apply</button></div></form>" ++
            "<div id=\"thermal-probe\" hidden></div><div id=\"empty\"></div><div id=\"drag-help\">Drag boards or fans · drag empty space to pan · scroll to zoom</div><div id=\"legend\"><span class=\"thermal-key\" id=\"legend-min\">25 °C</span><i class=\"thermal-key ramp\"></i><span class=\"thermal-key\" id=\"legend-max\">125 °C</span><span class=\"thermal-key\"><i class=\"sink\"></i>Bottom sink</span><span class=\"thermal-key\"><i class=\"fan\"></i>Fan outlet</span><span class=\"cad-key\" hidden><i class=\"solid\"></i>Authored solid</span><span class=\"cad-key\" hidden><i class=\"sketch\"></i>Sketch</span><span class=\"cad-key\" hidden><i class=\"cool\"></i>PCB reference</span></div></div></main>" ++
            "<script>window.CAD_DATA={\"system\":",
    );
    try json_writer.writeScriptString(writer, spec.name);
    try writer.writeAll(",\"title\":");
    try json_writer.writeScriptString(writer, spec.title);
    try writer.writeAll(",\"part_number\":");
    try json_writer.writeScriptString(writer, spec.part_number);
    try writer.writeAll(",\"revision\":");
    try json_writer.writeScriptString(writer, spec.revision);
    try writer.writeAll(",\"can_write\":");
    try writer.writeAll(if (can_write) "true" else "false");
    try writer.writeAll(",\"boards\":[");
    for (spec.boards, 0..) |board, index| try writeBoard(writer, allocator, project_dir, board, index);
    try writer.writeAll("],\"assembly\":");
    try writeAssembly(writer, if (parsed_assembly) |parsed| parsed.value else null);
    try writer.writeAll("};</script><script src=\"/static/three.min.js\"></script><script src=\"/static/OrbitControls.js\"></script>");
    try writer.print("<script src=\"/static/shape_sketch.js?v={x}\"></script>", .{std.hash.Wyhash.hash(0, @embedFile("assets/shape_sketch.js"))});
    try writer.print("<script src=\"/static/system_cad.js?v={x}\"></script></body></html>", .{std.hash.Wyhash.hash(0, @embedFile("assets/system_cad.js"))});
    res.content_type = .HTML;
    res.header("cache-control", "private, no-store");
    res.header("content-security-policy", "frame-ancestors 'none'");
    res.header("x-frame-options", "DENY");
    res.body = out.written();
}

fn queryValue(req: *httpz.Request, key: []const u8) ?[]const u8 {
    const query = req.query() catch return null;
    return query.get(key);
}

fn sendError(res: *httpz.Response, status: u16, message: []const u8) void {
    res.status = status;
    res.content_type = .TEXT;
    res.body = message;
}

const ModelRequestError = std.mem.Allocator.Error || error{InvalidMechanicalDocument};

const SolidBody = struct {
    id: []const u8,
    name: []const u8,
    mesh: prismatic.Mesh,
};

const SolidModel = struct {
    bodies: []const SolidBody,

    fn deinit(self: SolidModel, allocator: std.mem.Allocator) void {
        for (self.bodies) |body| {
            allocator.free(body.id);
            allocator.free(body.name);
            body.mesh.deinit(allocator);
        }
        allocator.free(self.bodies);
    }
};

fn polygonArea(profile: []const [2]f64) f64 {
    var area: f64 = 0;
    for (profile, 0..) |point, index| {
        const next = profile[(index + 1) % profile.len];
        area += point[0] * next[1] - next[0] * point[1];
    }
    return area / 2;
}

fn convexCounterClockwise(profile: []const [2]f64) bool {
    var has_corner = false;
    for (profile, 0..) |point, index| {
        const next = profile[(index + 1) % profile.len];
        const after = profile[(index + 2) % profile.len];
        const cross = (next[0] - point[0]) * (after[1] - next[1]) - (next[1] - point[1]) * (after[0] - next[0]);
        if (cross < -1e-9) return false;
        if (cross > 1e-9) has_corner = true;
    }
    return has_corner;
}

fn extrudeSketch(
    allocator: std.mem.Allocator,
    sketch: anytype,
    distance: f64,
) ModelRequestError!prismatic.Mesh {
    const compiled = shape_sketch.compile(allocator, sketch.geometry, shape_sketch.default_sagitta_mm) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidMechanicalDocument,
    };
    defer allocator.free(compiled.pts);
    defer allocator.free(compiled.poly);
    defer allocator.free(compiled.arcs);
    var profile = compiled.poly;
    var reversed: ?[][2]f64 = null;
    defer if (reversed) |points| allocator.free(points);
    if (polygonArea(profile) < 0) {
        const points = try allocator.alloc([2]f64, profile.len);
        for (profile, 0..) |_, index| points[index] = profile[profile.len - index - 1];
        reversed = points;
        profile = points;
    }
    if (!convexCounterClockwise(profile)) return error.InvalidMechanicalDocument;
    const local_mesh = prismatic.extrudeConvex(allocator, profile, 0, distance) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidMechanicalDocument,
    };
    errdefer local_mesh.deinit(allocator);
    const points = try allocator.alloc(prismatic.Point3, local_mesh.points.len);
    for (local_mesh.points, 0..) |point, index| points[index] = switch (sketch.plane) {
        .xy => .{ point[0], point[1], sketch.plane_z + point[2] },
        .xz => .{ point[0], sketch.plane_z - point[2], point[1] },
        .yz => .{ sketch.plane_z + point[2], point[0], point[1] },
    };
    allocator.free(local_mesh.points);
    return .{ .points = points, .triangles = local_mesh.triangles };
}

fn modelFromRequest(allocator: std.mem.Allocator, req: *httpz.Request) ModelRequestError!SolidModel {
    const source = req.body() orelse return error.InvalidMechanicalDocument;
    var parsed = cad_document.parse(allocator, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidMechanicalDocument,
    };
    defer parsed.deinit();
    var bodies: std.ArrayList(SolidBody) = .empty;
    errdefer {
        for (bodies.items) |body| {
            allocator.free(body.id);
            allocator.free(body.name);
            body.mesh.deinit(allocator);
        }
        bodies.deinit(allocator);
    }
    for (parsed.value.extrusions) |extrusion| {
        if (!extrusion.enabled) continue;
        const profile = for (parsed.value.sketches) |sketch| {
            if (std.mem.eql(u8, sketch.id, extrusion.sketch)) break sketch;
        } else return error.InvalidMechanicalDocument;
        const mesh = try extrudeSketch(allocator, profile, extrusion.distance);
        errdefer mesh.deinit(allocator);
        const id = try allocator.dupe(u8, extrusion.id);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, extrusion.name);
        errdefer allocator.free(name);
        try bodies.append(allocator, .{
            .id = id,
            .name = name,
            .mesh = mesh,
        });
    }
    return .{ .bodies = try bodies.toOwnedSlice(allocator) };
}

fn writeMeshJson(writer: *std.Io.Writer, mesh: prismatic.Mesh) HandlerError!void {
    try writer.writeAll("{\"points\":[");
    for (mesh.points, 0..) |point, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("[{d},{d},{d}]", .{ point[0], point[1], point[2] });
    }
    try writer.writeAll("],\"triangles\":[");
    for (mesh.triangles, 0..) |triangle, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("[{d},{d},{d}]", .{ triangle[0], triangle[1], triangle[2] });
    }
    try writer.writeAll("]}");
}

/// Return only explicitly authored extrusion bodies for browser display.
pub fn meshApi(allocator: std.mem.Allocator, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const model = modelFromRequest(allocator, req) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidMechanicalDocument => return sendError(res, 400, "invalid mechanical sketch or extrusion document"),
    };
    defer model.deinit(allocator);
    var out: std.Io.Writer.Allocating = .init(allocator);
    try out.writer.writeAll("{\"bodies\":[");
    for (model.bodies, 0..) |body, index| {
        if (index > 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"id\":");
        try json_writer.writeString(&out.writer, body.id);
        try out.writer.writeAll(",\"name\":");
        try json_writer.writeString(&out.writer, body.name);
        try out.writer.writeAll(",\"mesh\":");
        try writeMeshJson(&out.writer, body.mesh);
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("]}");
    res.content_type = .JSON;
    res.header("cache-control", "private, no-store");
    res.body = out.written();
}

fn writeStlMesh(writer: *std.Io.Writer, name: []const u8, mesh: prismatic.Mesh) HandlerError!void {
    try writer.print("solid {s}\n", .{name});
    for (mesh.triangles) |triangle| {
        const a = mesh.points[triangle[0]];
        const b = mesh.points[triangle[1]];
        const c = mesh.points[triangle[2]];
        const ux = b[0] - a[0];
        const uy = b[1] - a[1];
        const uz = b[2] - a[2];
        const vx = c[0] - a[0];
        const vy = c[1] - a[1];
        const vz = c[2] - a[2];
        var nx = uy * vz - uz * vy;
        var ny = uz * vx - ux * vz;
        var nz = ux * vy - uy * vx;
        const length = @sqrt(nx * nx + ny * ny + nz * nz);
        if (length > 0) {
            nx /= length;
            ny /= length;
            nz /= length;
        }
        try writer.print("  facet normal {d} {d} {d}\n    outer loop\n", .{ nx, ny, nz });
        try writer.print("      vertex {d} {d} {d}\n", .{ a[0], a[1], a[2] });
        try writer.print("      vertex {d} {d} {d}\n", .{ b[0], b[1], b[2] });
        try writer.print("      vertex {d} {d} {d}\n", .{ c[0], c[1], c[2] });
        try writer.writeAll("    endloop\n  endfacet\n");
    }
    try writer.print("endsolid {s}\n", .{name});
}

/// Generate a STEP or STL containing only explicitly authored extrusions.
pub fn exportFile(
    allocator: std.mem.Allocator,
    system_name: []const u8,
    req: *httpz.Request,
    res: *httpz.Response,
) HandlerError!void {
    const model = modelFromRequest(allocator, req) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidMechanicalDocument => return sendError(res, 400, "invalid mechanical sketch or extrusion document"),
    };
    defer model.deinit(allocator);
    if (model.bodies.len == 0) return sendError(res, 400, "there are no enabled extrusions to export");
    const format = queryValue(req, "format") orelse "step";
    const filename_stem = try std.fmt.allocPrint(allocator, "{s}-mechanical", .{system_name});

    if (std.mem.eql(u8, format, "stl")) {
        var out: std.Io.Writer.Allocating = .init(allocator);
        for (model.bodies) |body| try writeStlMesh(&out.writer, body.id, body.mesh);
        const disposition = try std.fmt.allocPrint(allocator, "attachment; filename=\"{s}.stl\"", .{filename_stem});
        res.header("content-type", "model/stl");
        res.header("content-disposition", disposition);
        res.header("cache-control", "no-store");
        res.body = out.written();
        return;
    }
    if (!std.mem.eql(u8, format, "step")) return sendError(res, 400, "format must be step or stl");
    var bodies: std.ArrayList(pcb_step_export.Body) = .empty;
    defer bodies.deinit(allocator);
    for (model.bodies) |body| try bodies.append(allocator, .{
        .name = body.name,
        .points = body.mesh.points,
        .triangles = body.mesh.triangles,
        .color = .{ 0.12, 0.35, 0.60 },
    });
    const output = pcb_step_export.buildBodies(allocator, filename_stem, bodies.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.WriteFailed,
        else => return sendError(res, 400, "cannot build mechanical STEP"),
    };
    const disposition = try std.fmt.allocPrint(allocator, "attachment; filename=\"{s}.step\"", .{filename_stem});
    res.header("content-type", "model/step");
    res.header("content-disposition", disposition);
    res.header("cache-control", "no-store");
    res.body = output;
}

const extrusion_document =
    "{\"schema\":\"netlisp-mechanical-v2\",\"boards\":[],\"sketches\":[{\"id\":\"floor-profile\",\"name\":\"Floor profile\",\"plane_z\":0,\"geometry\":{" ++
    "\"version\":1,\"points\":[{\"id\":1,\"x\":-20,\"y\":-15},{\"id\":2,\"x\":20,\"y\":-15},{\"id\":3,\"x\":20,\"y\":15},{\"id\":4,\"x\":-20,\"y\":15}]," ++
    "\"curves\":[{\"id\":11,\"kind\":\"line\",\"a\":1,\"b\":2},{\"id\":12,\"kind\":\"line\",\"a\":2,\"b\":3},{\"id\":13,\"kind\":\"line\",\"a\":3,\"b\":4},{\"id\":14,\"kind\":\"line\",\"a\":4,\"b\":1}],\"constraints\":[]}}]," ++
    "\"extrusions\":[{\"id\":\"floor\",\"name\":\"Authored floor\",\"sketch\":\"floor-profile\",\"distance\":2}]}";

const xz_extrusion_document =
    "{\"schema\":\"netlisp-mechanical-v2\",\"boards\":[],\"sketches\":[{\"id\":\"wall-profile\",\"name\":\"Wall profile\",\"plane\":\"xz\",\"plane_z\":4,\"geometry\":{" ++
    "\"version\":1,\"points\":[{\"id\":1,\"x\":-20,\"y\":-15},{\"id\":2,\"x\":20,\"y\":-15},{\"id\":3,\"x\":20,\"y\":15},{\"id\":4,\"x\":-20,\"y\":15}]," ++
    "\"curves\":[{\"id\":11,\"kind\":\"line\",\"a\":1,\"b\":2},{\"id\":12,\"kind\":\"line\",\"a\":2,\"b\":3},{\"id\":13,\"kind\":\"line\",\"a\":3,\"b\":4},{\"id\":14,\"kind\":\"line\",\"a\":4,\"b\":1}],\"constraints\":[]}}]," ++
    "\"extrusions\":[{\"id\":\"wall\",\"name\":\"Authored wall\",\"sketch\":\"wall-profile\",\"distance\":2}]}";

test "STL writer emits outward facets for an authored extrusion" {
    const profile = [_][2]f64{ .{ -20, -15 }, .{ 20, -15 }, .{ 20, 15 }, .{ -20, 15 } };
    const mesh = try prismatic.extrudeConvex(std.testing.allocator, &profile, 0, 2);
    defer mesh.deinit(std.testing.allocator);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeStlMesh(&out.writer, "floor", mesh);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "solid floor\n"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "facet normal") != null);
    try std.testing.expect(std.mem.endsWith(u8, out.written(), "endsolid floor\n"));
}

test "CAD export endpoint returns only explicitly authored extrusion solids" {
    var step_request = httpz.testing.init(.{});
    defer step_request.deinit();
    step_request.body(extrusion_document);
    step_request.query("format", "step");
    try exportFile(step_request.res.arena, "board-a", step_request.req, step_request.res);
    try std.testing.expect(std.mem.startsWith(u8, step_request.res.body, "ISO-10303-21;"));
    try std.testing.expect(std.mem.indexOf(u8, step_request.res.body, "FACETED_BREP('Authored floor'") != null);
    try std.testing.expect(std.mem.indexOf(u8, step_request.res.body, "FACETED_BREP('Base'") == null);
    try std.testing.expect(std.mem.indexOf(u8, step_request.res.body, "FACETED_BREP('Lid'") == null);

    var stl_request = httpz.testing.init(.{});
    defer stl_request.deinit();
    stl_request.body(extrusion_document);
    stl_request.query("format", "stl");
    try exportFile(stl_request.res.arena, "board-a", stl_request.req, stl_request.res);
    try std.testing.expect(std.mem.startsWith(u8, stl_request.res.body, "solid floor\n"));
}

// spec: Web Server - the system CAD workspace opens as a solved 2D heat-field map with a separate 3D assembly/CAD view, shows imported PCBs as reference geometry without inferring an enclosure, imports legacy board-attached fans as independently persisted system fans that can be added, removed, positioned and configured, provides clickable XY/XZ/YZ origin datum planes, locks active sketch editing to a flat orthographic plane with the PCB outline editor's selection/constraint/modify palette, creates preview or STEP/STL solids only from explicit enabled extrusions while ignoring legacy generated-enclosure documents, and content-hashes its first-party asset URLs so fresh HTML cannot execute a stale control schema
test "CAD mesh endpoint is empty for a blank document and extrudes on request" {
    const blank = "{\"schema\":\"netlisp-mechanical-v2\",\"boards\":[],\"sketches\":[],\"extrusions\":[]}";
    var request = httpz.testing.init(.{});
    defer request.deinit();
    request.body(blank);
    try meshApi(request.res.arena, request.req, request.res);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, request.res.arena, request.res.body, .{});
    try std.testing.expectEqual(@as(usize, 0), parsed.object.get("bodies").?.array.items.len);

    var authored = httpz.testing.init(.{});
    defer authored.deinit();
    authored.body(extrusion_document);
    try meshApi(authored.res.arena, authored.req, authored.res);
    const generated = try std.json.parseFromSliceLeaky(std.json.Value, authored.res.arena, authored.res.body, .{});
    const bodies = generated.object.get("bodies").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), bodies.len);
    try std.testing.expectEqualStrings("floor", bodies[0].object.get("id").?.string);
    try std.testing.expectEqual(@as(usize, 8), bodies[0].object.get("mesh").?.object.get("points").?.array.items.len);

    var vertical = httpz.testing.init(.{});
    defer vertical.deinit();
    vertical.body(xz_extrusion_document);
    const vertical_model = try modelFromRequest(vertical.res.arena, vertical.req);
    defer vertical_model.deinit(vertical.res.arena);
    const points = vertical_model.bodies[0].mesh.points;
    try std.testing.expectEqual(prismatic.Point3{ -20, 4, -15 }, points[0]);
    try std.testing.expectEqual(@as(f64, 2), points[4][1]);

    const yz_document = try std.mem.replaceOwned(u8, std.testing.allocator, xz_extrusion_document, "\"xz\"", "\"yz\"");
    defer std.testing.allocator.free(yz_document);
    var side = httpz.testing.init(.{});
    defer side.deinit();
    side.body(yz_document);
    const side_model = try modelFromRequest(side.res.arena, side.req);
    defer side_model.deinit(side.res.arena);
    const side_points = side_model.bodies[0].mesh.points;
    try std.testing.expectEqual(prismatic.Point3{ 4, -20, -15 }, side_points[0]);
    try std.testing.expectEqual(@as(f64, 6), side_points[4][0]);
}

test "system CAD page starts from sketch tools without enclosure generators" {
    const spec: system_review.SystemSpec = .{
        .schema = system_review.schema_v1,
        .name = "demo",
        .title = "Demo",
        .part_number = "SYS-1",
        .revision = "A",
        .boards = &.{},
    };
    var request = httpz.testing.init(.{});
    defer request.deinit();
    try page(request.res.arena, ".", spec, true, request.res);
    try std.testing.expect(std.mem.indexOf(u8, request.res.body, "<nav class=\"navbar\" aria-label=\"Primary\"><a href=\"/\" class=\"brand\">Netlisp</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.res.body, "id=\"new-sketch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.res.body, "id=\"thermal-canvas\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.res.body, "id=\"add-fan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.res.body, ">2D thermal</button>") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.res.body, "id=\"top\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.res.body, "data-plane=\"xz\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.res.body, "data-action=\"fillet\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.res.body, "data-action=\"perpendicular\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.res.body, "data-action=\"extrude\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.res.body, "Dimension (D)") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.res.body, "id=\"sketch-dimension-popover\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.res.body, "id=\"sketch-dimensions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.res.body, "Extrude selected") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.res.body, "/static/system_cad.css?v=") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.res.body, "/static/shape_sketch.js?v=") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.res.body, "/static/system_cad.js?v=") != null);
    try std.testing.expect(std.mem.indexOf(u8, request.res.body, "auto-bosses") == null);
    try std.testing.expect(std.mem.indexOf(u8, request.res.body, "PCB clearance") == null);
}

// spec: system-review - a strict assembly sidecar repeats reviewed board definitions as uniquely identified physical instances and preserves its authored pitch, and the system workspace opens as a 2D solved heat-field map with a separate 3D assembly view and bounded wheel gestures, a D driving-dimension shortcut, and direct extrusion of a closed active sketch
test "system CAD validates and serializes repeated assembly instances" {
    const browser = @embedFile("assets/system_cad.js");
    try std.testing.expect(std.mem.indexOf(u8, browser, "var viewMode = \"2d\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, browser, "/api/thermal-field/") != null);
    try std.testing.expect(std.mem.indexOf(u8, browser, "fieldTemperatureAt") != null);
    try std.testing.expect(std.mem.indexOf(u8, browser, "state.fans.map") != null);
    try std.testing.expect(std.mem.indexOf(u8, browser, "function drawSystemFan") != null);
    try std.testing.expect(std.mem.indexOf(u8, browser, "function extrudeActiveSketch()") != null);
    try std.testing.expect(std.mem.indexOf(u8, browser, "function renderSketchDimensions()") != null);
    try std.testing.expect(std.mem.indexOf(u8, browser, "OS.annotations(sketch.geometry)") != null);
    try std.testing.expect(std.mem.indexOf(u8, browser, "function applyPendingDimension()") != null);
    try std.testing.expect(std.mem.indexOf(u8, browser, "event.key.toLowerCase() === \"d\"") != null);
    const boards = [_]system_review.BoardMember{
        .{ .name = "board-a", .role = "controller", .source = "src/boards/board-a/board-a.sexp", .part_number = "BAR", .revision = "2" },
        .{ .name = "black-canyon", .role = "channel", .source = "src/boards/black-canyon/black-canyon.sexp", .part_number = "BC", .revision = "1" },
    };
    const spec: system_review.SystemSpec = .{
        .schema = system_review.schema_v1,
        .name = "rds3",
        .title = "RDS3",
        .part_number = "RDS3",
        .revision = "1",
        .boards = &boards,
    };
    const instances = [_]AssemblyInstance{
        .{ .id = "board-a", .board = "board-a", .z = 18.5 },
        .{ .id = "black-canyon-left-1", .board = "black-canyon", .x = -73.95, .y = -77, .z = 18.5 },
        .{ .id = "black-canyon-left-2", .board = "black-canyon", .x = -73.95, .y = -55, .z = 18.5 },
    };
    const assembly: AssemblySpec = .{ .schema = assembly_schema, .pitch_mm = 22, .instances = &instances };
    try std.testing.expect(validAssembly(spec, assembly));

    const duplicate = [_]AssemblyInstance{
        .{ .id = "same", .board = "board-a" },
        .{ .id = "same", .board = "black-canyon" },
    };
    try std.testing.expect(!validAssembly(spec, .{ .schema = assembly_schema, .instances = &duplicate }));
    try std.testing.expect(!validAssembly(spec, .{ .schema = assembly_schema, .instances = &.{.{ .id = "unknown", .board = "not-reviewed" }} }));

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeAssembly(&output.writer, assembly);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"pitch_mm\":22") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"black-canyon-left-2\"") != null);
}

// spec: system-review - the system CAD dimension tool selects geometry before placement, previews the inferred measurement, persists its canvas position, and supports line length, arc radius or diameter, point alignment, line angle or offset, and tangent-aware arc distances for later editing
test "system CAD uses a placed geometry-aware dimension tool" {
    const browser = @embedFile("assets/system_cad.js");
    const kernel = @embedFile("assets/shape_sketch.js");
    try std.testing.expect(std.mem.indexOf(u8, browser, "function dimensionPointerDown(") != null);
    try std.testing.expect(std.mem.indexOf(u8, browser, "function drawDimensionPreview(") != null);
    try std.testing.expect(std.mem.indexOf(u8, browser, "placement: pending.placement") != null);
    try std.testing.expect(std.mem.indexOf(u8, kernel, "angle_between") != null);
    try std.testing.expect(std.mem.indexOf(u8, kernel, "tangent_distance") != null);
    try std.testing.expect(std.mem.indexOf(u8, kernel, "inferDimension:inferDimension") != null);
}

test "system CAD serializes saved top fan and bottom stepped heatsink" {
    const layout: pcb_layout_page.SavedLayout = .{
        .name = "cooled",
        .kind = "manual",
        .ts = 1,
        .score = null,
        .parts = &.{},
        .heatsink = .{
            .x = 3,
            .y = 4,
            .w = 56.6,
            .h = 26.1,
            .side = "bottom",
            .base_mm = 13,
            .profile = .{ .stepped = .{ .width_mm = 250, .length_mm = 250, .height_mm = 2 } },
        },
        .fan = .{
            .model = "RDS3-FAN",
            .rect = .{ .x = 1, .y = 2, .w = 80, .h = 80 },
            .side = "top",
            .distance_mm = 17,
            .curve = .{ .free_air_flow_m3_s = 0.025, .max_static_pressure_pa = 55 },
        },
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeCooling(&output.writer, layout, .{ 10, 20 });
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"shape\":\"stepped\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"lower_w\":250") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"side\":\"bottom\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"model\":\"RDS3-FAN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"side\":\"top\"") != null);
}
