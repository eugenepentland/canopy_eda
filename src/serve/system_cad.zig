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
const enclosure = @import("../mechanical/enclosure.zig");
const prismatic = @import("../mechanical/prismatic.zig");
const json_writer = @import("../json_writer.zig");
const system_review = @import("../system_review.zig");
const system_review_assets = @import("../system_review_assets.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const pcb_step_export = @import("pcb_step_export.zig");

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
    try writer.print(",\"width\":{d},\"depth\":{d},\"thickness\":{d},\"outline\":", .{ rect.w, rect.h, thickness });
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
            "<title>System Thermal</title><link rel=\"stylesheet\" href=\"/static/system_cad.css\"></head><body>" ++
            "<header><a class=\"back\" id=\"back\">← System</a><div><h1 id=\"title\">System Thermal</h1><p id=\"identity\"></p></div>" ++
            "<span class=\"kernel\">Coupled screening</span><span id=\"save-status\"></span><button id=\"save\">Save design</button><button id=\"fit\">Fit view</button>" ++
            "<button id=\"assembly-json\">Download assembly.json</button><button id=\"step\">Download STEP</button><button id=\"stl\">Download STL</button></header>" ++
            "<main><aside><section><h2>System screening</h2><div class=\"fields\">" ++
            "<label>Ambient <input id=\"ambient\" type=\"number\" min=\"-55\" max=\"125\" step=\"1\"><span>°C</span></label>" ++
            "<label>Board pitch <input id=\"pitch\" type=\"number\" min=\"1\" max=\"200\" step=\"0.5\"><span>mm</span></label></div>" ++
            "<label class=\"check\"><input id=\"snap\" type=\"checkbox\" checked> Snap board centres to pitch while dragging</label>" ++
            "<div id=\"thermal-summary\" class=\"thermal-summary\">Loading board thermal models…</div>" ++
            "<p class=\"hint\">Drag a PCB in the viewport or enter its exact pose. Temperatures combine each saved board's placement-aware solve, projected fan coverage, and mixed-air rise. This is a system screening model, not CFD.</p></section>" ++
            "<section><h2>Board instances</h2><p class=\"hint\">The review manifest defines board types; assembly.json may repeat them as physical instances.</p><div id=\"boards\"></div></section>" ++
            "<section><h2>Enclosure</h2><div class=\"fields\">" ++
            "<label>PCB clearance <input id=\"clearance\" type=\"number\" min=\"0.2\" max=\"50\" step=\"0.1\"><span>mm</span></label>" ++
            "<label>Wall <input id=\"wall\" type=\"number\" min=\"0.6\" max=\"30\" step=\"0.1\"><span>mm</span></label>" ++
            "<label>Floor <input id=\"floor\" type=\"number\" min=\"0.6\" max=\"30\" step=\"0.1\"><span>mm</span></label>" ++
            "<label>Base height <input id=\"height\" type=\"number\" min=\"3\" max=\"300\" step=\"0.5\"><span>mm</span></label>" ++
            "<label>Lid thickness <input id=\"lid\" type=\"number\" min=\"0.6\" max=\"30\" step=\"0.1\"><span>mm</span></label>" ++
            "<label>Lid explode <input id=\"explode\" type=\"range\" min=\"0\" max=\"80\" step=\"1\"></label>" ++
            "</div><div class=\"dimensions\" id=\"dimensions\"></div><button id=\"reset\">Reset draft</button></section>" ++
            "<section><div class=\"section-head\"><h2>PCB mounting bosses</h2><button id=\"auto-bosses\">From PCB holes</button></div><p class=\"hint\">Blind screw bosses rise from the case floor to support the board.</p><div id=\"bosses\"></div><button id=\"add-boss\">Add boss</button></section>" ++
            "<section><div class=\"section-head\"><h2>Wall cutouts</h2><button id=\"add-cutout\">Add cutout</button></div><p class=\"hint\">Rectangular connector openings are cut through the selected wall by the Zig kernel.</p><div id=\"cutouts\"></div></section>" ++
            "<section><h2>Model boundary</h2><ul><li>Exact saved PCB outlines, mounting holes and component heat ledgers</li><li>Attached saved fan and heatsink geometry</li><li>Persisted enclosure, bosses and wall cutouts through the Zig kernel</li><li>Fan-footprint coverage and enclosure bulk-air rise</li><li>No wake, recirculation, buoyant plume, or pressure-network CFD</li></ul></section></aside>" ++
            "<div id=\"viewport\"><canvas id=\"canvas\"></canvas><div id=\"empty\"></div><div id=\"drag-help\">Drag boards · orbit empty space · scroll to zoom</div><div id=\"legend\"><span><i class=\"cool\"></i>Cool</span><span><i class=\"warm\"></i>Warm</span><span><i class=\"hot\"></i>Hot</span><span><i class=\"sink\"></i>Heatsink</span><span><i class=\"fan\"></i>Fan</span></div></div></main>" ++
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
    try writer.writeAll("};</script><script src=\"/static/three.min.js\"></script><script src=\"/static/OrbitControls.js\"></script><script src=\"/static/system_cad.js\"></script></body></html>");
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

fn parameter(req: *httpz.Request, key: []const u8, minimum: f64, maximum: f64) ?f64 {
    const raw = queryValue(req, key) orelse return null;
    const value = std.fmt.parseFloat(f64, raw) catch return null;
    if (!std.math.isFinite(value) or value < minimum or value > maximum) return null;
    return value;
}

fn sendError(res: *httpz.Response, status: u16, message: []const u8) void {
    res.status = status;
    res.content_type = .TEXT;
    res.body = message;
}

fn parametersFromRequest(req: *httpz.Request) ?enclosure.Parameters {
    return .{
        .occupied_width = parameter(req, "width", 1, 2000) orelse return null,
        .occupied_depth = parameter(req, "depth", 1, 2000) orelse return null,
        .clearance = parameter(req, "clearance", 0.1, 100) orelse return null,
        .wall = parameter(req, "wall", 0.2, 100) orelse return null,
        .floor = parameter(req, "floor", 0.2, 100) orelse return null,
        .height = parameter(req, "height", 0.5, 500) orelse return null,
        .lid_thickness = parameter(req, "lid", 0.2, 100) orelse return null,
    };
}

const ModelRequestError = std.mem.Allocator.Error || error{InvalidMechanicalDocument};

fn modelFromRequest(allocator: std.mem.Allocator, req: *httpz.Request) ModelRequestError!enclosure.Model {
    if (req.body()) |body| {
        var parsed = cad_document.parse(allocator, body) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidDocument => return error.InvalidMechanicalDocument,
        };
        defer parsed.deinit();
        return enclosure.generateWithFeatures(allocator, cad_document.parameters(parsed.value), cad_document.features(parsed.value)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidMechanicalDocument,
        };
    }
    const parameters = parametersFromRequest(req) orelse return error.InvalidMechanicalDocument;
    return enclosure.generate(allocator, parameters) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidMechanicalDocument,
    };
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

/// Return the native Zig base and lid meshes for interactive browser display.
pub fn meshApi(allocator: std.mem.Allocator, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const model = modelFromRequest(allocator, req) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidMechanicalDocument => return sendError(res, 400, "invalid mechanical document or enclosure parameters"),
    };
    defer model.deinit(allocator);
    var out: std.Io.Writer.Allocating = .init(allocator);
    try out.writer.print(
        "{{\"dimensions\":{{\"inner_width\":{d},\"inner_depth\":{d},\"outer_width\":{d},\"outer_depth\":{d}}},\"base\":",
        .{ model.dimensions.inner_width, model.dimensions.inner_depth, model.dimensions.outer_width, model.dimensions.outer_depth },
    );
    try writeMeshJson(&out.writer, model.base);
    try out.writer.writeAll(",\"lid\":");
    try writeMeshJson(&out.writer, model.lid);
    try out.writer.writeAll(",\"bosses\":[");
    for (model.bosses, 0..) |boss, index| {
        if (index > 0) try out.writer.writeByte(',');
        try writeMeshJson(&out.writer, boss);
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

/// Generate and download one enclosure base, lid, or combined assembly.
pub fn exportFile(
    allocator: std.mem.Allocator,
    system_name: []const u8,
    req: *httpz.Request,
    res: *httpz.Response,
) HandlerError!void {
    const model = modelFromRequest(allocator, req) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidMechanicalDocument => return sendError(res, 400, "invalid mechanical document or enclosure parameters"),
    };
    defer model.deinit(allocator);

    const part = queryValue(req, "part") orelse "assembly";
    const include_base = std.mem.eql(u8, part, "base") or std.mem.eql(u8, part, "assembly");
    const include_lid = std.mem.eql(u8, part, "lid") or std.mem.eql(u8, part, "assembly");
    if (!include_base and !include_lid) return sendError(res, 400, "part must be base, lid, or assembly");
    const format = queryValue(req, "format") orelse "step";
    const filename_stem = try std.fmt.allocPrint(allocator, "{s}-enclosure-{s}", .{ system_name, part });

    if (std.mem.eql(u8, format, "stl")) {
        var out: std.Io.Writer.Allocating = .init(allocator);
        if (include_base) {
            try writeStlMesh(&out.writer, "base", model.base);
            for (model.bosses, 0..) |boss, index| {
                const name = try std.fmt.allocPrint(allocator, "boss-{d}", .{index + 1});
                try writeStlMesh(&out.writer, name, boss);
            }
        }
        if (include_lid) try writeStlMesh(&out.writer, "lid", model.lid);
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
    if (include_base) {
        try bodies.append(allocator, .{ .name = "Base", .points = model.base.points, .triangles = model.base.triangles, .color = .{ 0.12, 0.35, 0.60 } });
        for (model.bosses, 0..) |boss, index| {
            const name = try std.fmt.allocPrint(allocator, "Mounting boss {d}", .{index + 1});
            try bodies.append(allocator, .{ .name = name, .points = boss.points, .triangles = boss.triangles, .color = .{ 0.12, 0.35, 0.60 } });
        }
    }
    if (include_lid) {
        try bodies.append(allocator, .{ .name = "Lid", .points = model.lid.points, .triangles = model.lid.triangles, .color = .{ 0.24, 0.54, 0.78 } });
    }
    const output = pcb_step_export.buildBodies(allocator, filename_stem, bodies.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.WriteFailed,
        else => return sendError(res, 400, "cannot build enclosure STEP"),
    };
    const disposition = try std.fmt.allocPrint(allocator, "attachment; filename=\"{s}.step\"", .{filename_stem});
    res.header("content-type", "model/step");
    res.header("content-disposition", disposition);
    res.header("cache-control", "no-store");
    res.body = output;
}

test "STL writer emits outward facets for native enclosure mesh" {
    const model = try enclosure.generate(std.testing.allocator, .{ .occupied_width = 40, .occupied_depth = 30 });
    defer model.deinit(std.testing.allocator);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeStlMesh(&out.writer, "base", model.base);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "solid base\n"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "facet normal") != null);
    try std.testing.expect(std.mem.endsWith(u8, out.written(), "endsolid base\n"));
}

test "CAD export endpoint returns native STEP and STL solids" {
    var step_request = httpz.testing.init(.{});
    defer step_request.deinit();
    step_request.query("width", "90");
    step_request.query("depth", "55");
    step_request.query("clearance", "2.5");
    step_request.query("wall", "2.4");
    step_request.query("floor", "2");
    step_request.query("height", "28");
    step_request.query("lid", "2.4");
    step_request.query("part", "assembly");
    step_request.query("format", "step");
    try exportFile(step_request.res.arena, "barracuda", step_request.req, step_request.res);
    try std.testing.expect(std.mem.startsWith(u8, step_request.res.body, "ISO-10303-21;"));
    try std.testing.expect(std.mem.indexOf(u8, step_request.res.body, "FACETED_BREP('Base'") != null);
    try std.testing.expect(std.mem.indexOf(u8, step_request.res.body, "FACETED_BREP('Lid'") != null);

    var stl_request = httpz.testing.init(.{});
    defer stl_request.deinit();
    stl_request.query("width", "90");
    stl_request.query("depth", "55");
    stl_request.query("clearance", "2.5");
    stl_request.query("wall", "2.4");
    stl_request.query("floor", "2");
    stl_request.query("height", "28");
    stl_request.query("lid", "2.4");
    stl_request.query("part", "base");
    stl_request.query("format", "stl");
    try exportFile(stl_request.res.arena, "barracuda", stl_request.req, stl_request.res);
    try std.testing.expect(std.mem.startsWith(u8, stl_request.res.body, "solid base\n"));
    try std.testing.expect(std.mem.indexOf(u8, stl_request.res.body, "solid lid") == null);
}

test "CAD mesh endpoint returns the Zig kernel topology" {
    var request = httpz.testing.init(.{});
    defer request.deinit();
    request.query("width", "90");
    request.query("depth", "55");
    request.query("clearance", "2.5");
    request.query("wall", "2.4");
    request.query("floor", "2");
    request.query("height", "28");
    request.query("lid", "2.4");
    try meshApi(request.res.arena, request.req, request.res);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, request.res.arena, request.res.body, .{});
    try std.testing.expectEqual(@as(usize, 16), parsed.object.get("base").?.object.get("points").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 28), parsed.object.get("base").?.object.get("triangles").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 12), parsed.object.get("lid").?.object.get("triangles").?.array.items.len);
}

test "CAD document drives cutout preview and boss exports through Zig" {
    const document =
        "{\"schema\":\"netlisp-mechanical-v1\",\"occupied\":{\"width\":90,\"depth\":55}," ++
        "\"bosses\":[{\"x\":20,\"y\":10,\"outer_diameter\":6,\"hole_diameter\":2.8,\"height\":3}]," ++
        "\"cutouts\":[{\"wall\":\"front\",\"center\":0,\"width\":12,\"bottom\":5,\"height\":8}]}";
    var mesh_request = httpz.testing.init(.{});
    defer mesh_request.deinit();
    mesh_request.body(document);
    try meshApi(mesh_request.res.arena, mesh_request.req, mesh_request.res);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, mesh_request.res.arena, mesh_request.res.body, .{});
    try std.testing.expect(parsed.object.get("base").?.object.get("triangles").?.array.items.len > 28);
    try std.testing.expectEqual(@as(usize, 1), parsed.object.get("bosses").?.array.items.len);

    var step_request = httpz.testing.init(.{});
    defer step_request.deinit();
    step_request.body(document);
    step_request.query("part", "base");
    step_request.query("format", "step");
    try exportFile(step_request.res.arena, "barracuda", step_request.req, step_request.res);
    try std.testing.expect(std.mem.indexOf(u8, step_request.res.body, "FACETED_BREP('Mounting boss 1'") != null);
}

// spec: system-review - a strict assembly sidecar repeats reviewed board definitions as uniquely identified physical instances and preserves its authored pitch, while bounded wheel gestures prevent trackpad momentum from driving the 3D camera through the assembly
test "system CAD validates and serializes repeated assembly instances" {
    const boards = [_]system_review.BoardMember{
        .{ .name = "barracuda", .role = "controller", .source = "src/boards/barracuda/barracuda.sexp", .part_number = "BAR", .revision = "2" },
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
        .{ .id = "barracuda", .board = "barracuda", .z = 18.5 },
        .{ .id = "black-canyon-left-1", .board = "black-canyon", .x = -73.95, .y = -77, .z = 18.5 },
        .{ .id = "black-canyon-left-2", .board = "black-canyon", .x = -73.95, .y = -55, .z = 18.5 },
    };
    const assembly: AssemblySpec = .{ .schema = assembly_schema, .pitch_mm = 22, .instances = &instances };
    try std.testing.expect(validAssembly(spec, assembly));

    const duplicate = [_]AssemblyInstance{
        .{ .id = "same", .board = "barracuda" },
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
