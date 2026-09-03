//! System-level mechanical CAD page and enclosure exports.
//!
//! System manifests select the same saved PCB layouts used for fabrication.
//! This page imports their exact outlines and component courtyards, then sends
//! enclosure parameters through the native Zig prismatic kernel for STEP/STL.

const std = @import("std");
const httpz = @import("httpz");
const enclosure = @import("../mechanical/enclosure.zig");
const prismatic = @import("../mechanical/prismatic.zig");
const json_writer = @import("../json_writer.zig");
const system_review = @import("../system_review.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const pcb_step_export = @import("pcb_step_export.zig");

/// Allocation and response-write failures escaping CAD handlers.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

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
    try writer.writeAll("]}");
}

/// Render an interactive enclosure workspace from one parsed system manifest.
pub fn page(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    spec: system_review.SystemSpec,
    res: *httpz.Response,
) HandlerError!void {
    var out: std.Io.Writer.Allocating = .init(res.arena);
    const writer = &out.writer;
    try writer.writeAll(
        "<!doctype html><html><head><meta charset=\"utf-8\">" ++
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
            "<title>3D CAD</title><link rel=\"stylesheet\" href=\"/static/system_cad.css\"></head><body>" ++
            "<header><a class=\"back\" id=\"back\">← System</a><div><h1 id=\"title\">3D CAD</h1><p id=\"identity\"></p></div>" ++
            "<span class=\"kernel\">Zig prismatic kernel</span><button id=\"fit\">Fit view</button>" ++
            "<a class=\"button\" id=\"step\">Download STEP</a><a class=\"button\" id=\"stl\">Download STL</a></header>" ++
            "<main><aside><section><h2>Imported PCBs</h2><p class=\"hint\">Saved system layouts are loaded as the mechanical authority. Adjust each board's assembly pose here.</p><div id=\"boards\"></div></section>" ++
            "<section><h2>Enclosure</h2><div class=\"fields\">" ++
            "<label>PCB clearance <input id=\"clearance\" type=\"number\" min=\"0.2\" max=\"50\" step=\"0.1\"><span>mm</span></label>" ++
            "<label>Wall <input id=\"wall\" type=\"number\" min=\"0.6\" max=\"30\" step=\"0.1\"><span>mm</span></label>" ++
            "<label>Floor <input id=\"floor\" type=\"number\" min=\"0.6\" max=\"30\" step=\"0.1\"><span>mm</span></label>" ++
            "<label>Base height <input id=\"height\" type=\"number\" min=\"3\" max=\"300\" step=\"0.5\"><span>mm</span></label>" ++
            "<label>Lid thickness <input id=\"lid\" type=\"number\" min=\"0.6\" max=\"30\" step=\"0.1\"><span>mm</span></label>" ++
            "<label>Lid explode <input id=\"explode\" type=\"range\" min=\"0\" max=\"80\" step=\"1\"></label>" ++
            "</div><div class=\"dimensions\" id=\"dimensions\"></div><button id=\"reset\">Reset draft</button></section>" ++
            "<section><h2>Phase 1 + 2</h2><ul><li>Native indexed prism meshes</li><li>Watertight base shell and lid</li><li>Exact saved PCB outlines</li><li>STEP and STL export</li></ul><p class=\"hint\">Next: sketch-driven cutouts, mounting bosses, fillets, and persisted mechanical documents.</p></section></aside>" ++
            "<div id=\"viewport\"><canvas id=\"canvas\"></canvas><div id=\"empty\"></div><div id=\"legend\"><span><i class=\"pcb\"></i>PCB</span><span><i class=\"base\"></i>Base</span><span><i class=\"lid\"></i>Lid</span></div></div></main>" ++
            "<script>window.CAD_DATA={\"system\":",
    );
    try json_writer.writeScriptString(writer, spec.name);
    try writer.writeAll(",\"title\":");
    try json_writer.writeScriptString(writer, spec.title);
    try writer.writeAll(",\"part_number\":");
    try json_writer.writeScriptString(writer, spec.part_number);
    try writer.writeAll(",\"revision\":");
    try json_writer.writeScriptString(writer, spec.revision);
    try writer.writeAll(",\"boards\":[");
    for (spec.boards, 0..) |board, index| try writeBoard(writer, allocator, project_dir, board, index);
    try writer.writeAll("]};</script><script src=\"/static/three.min.js\"></script><script src=\"/static/OrbitControls.js\"></script><script src=\"/static/system_cad.js\"></script></body></html>");
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
    const parameters = parametersFromRequest(req) orelse return sendError(res, 400, "invalid enclosure parameters");
    const model = enclosure.generate(allocator, parameters) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return sendError(res, 400, "invalid enclosure dimensions"),
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
    try out.writer.writeByte('}');
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
    const parameters = parametersFromRequest(req) orelse return sendError(res, 400, "invalid or missing enclosure parameters");
    const model = enclosure.generate(allocator, parameters) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return sendError(res, 400, "invalid enclosure dimensions"),
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
        if (include_base) try writeStlMesh(&out.writer, "base", model.base);
        if (include_lid) try writeStlMesh(&out.writer, "lid", model.lid);
        const disposition = try std.fmt.allocPrint(allocator, "attachment; filename=\"{s}.stl\"", .{filename_stem});
        res.header("content-type", "model/stl");
        res.header("content-disposition", disposition);
        res.header("cache-control", "no-store");
        res.body = out.written();
        return;
    }
    if (!std.mem.eql(u8, format, "step")) return sendError(res, 400, "format must be step or stl");
    var bodies: [2]pcb_step_export.Body = undefined;
    var count: usize = 0;
    if (include_base) {
        bodies[count] = .{ .name = "Base", .points = model.base.points, .triangles = model.base.triangles, .color = .{ 0.12, 0.35, 0.60 } };
        count += 1;
    }
    if (include_lid) {
        bodies[count] = .{ .name = "Lid", .points = model.lid.points, .triangles = model.lid.triangles, .color = .{ 0.24, 0.54, 0.78 } };
        count += 1;
    }
    const output = pcb_step_export.buildBodies(allocator, filename_stem, bodies[0..count]) catch |err| switch (err) {
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
