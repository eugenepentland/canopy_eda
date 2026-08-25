//! Server-side PCB STEP assembly composer.
//!
//! Generated board/heatsink bodies arrive as the small faceted geometry the
//! browser already owns. Component geometry never does: each unique library
//! STEP is parsed here, copied into the AP242 exchange structure without
//! tessellation, then instanced with an assembly transform. Repeated packages
//! therefore share one exact B-rep definition instead of expanding the
//! preview triangles once per placement.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const export_kicad = @import("../export_kicad.zig");
const footprint_mod = @import("../export_kicad_footprint.zig");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;

const max_request_bytes: usize = 32 * 1024 * 1024;
const max_model_bytes: usize = 64 * 1024 * 1024;
const max_total_model_bytes: usize = 192 * 1024 * 1024;
const max_bodies: usize = 4096;
const max_instances: usize = 8192;
const max_points_per_body: usize = 250_000;
const max_triangles_per_body: usize = 250_000;

pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

const Body = struct {
    name: []const u8,
    points: []const [3]f64,
    triangles: []const [3]usize,
    color: ?[3]f64 = null,
    triangleColors: ?[]const ?[3]f64 = null,
};

const Instance = struct {
    name: []const u8,
    footprint: []const u8,
    /// Three.js column-major Matrix4 mapping untouched model coordinates into
    /// the PCB viewer's millimetre world frame.
    matrix: [16]f64,
};

const Request = struct {
    bodies: []const Body = &.{},
    instances: []const Instance = &.{},
};

const Entity = struct {
    old_id: u64,
    new_id: u64 = 0,
    rhs: []const u8,
};

const RootShape = struct {
    product_definition: u64,
    representation: u64,
};

const ImportedModel = struct {
    filename: []const u8,
    entities: []Entity,
    roots: []RootShape,
};

const ExportError = error{
    BadRequest,
    InvalidGeometry,
    InvalidMatrix,
    InvalidStep,
    MissingModel,
    ModelLimit,
};

fn safeFootprint(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or std.mem.indexOf(u8, name, "..") != null) return false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_' or c == ',' or c == '#';
        if (!ok) return false;
    }
    return true;
}

fn safeDesignName(name: []const u8) bool {
    if (name.len == 0 or name.len > 256) return false;
    for (name) |c| {
        const punctuation = c == '.' or c == '-' or c == '_';
        if (!std.ascii.isAlphanumeric(c) and !punctuation) return false;
    }
    return true;
}

fn stepText(w: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('\'');
    for (value) |c| {
        if (c == '\'') try w.writeByte('\'');
        try w.writeByte(if (c < 0x20 or c == 0x7f) ' ' else c);
    }
    try w.writeByte('\'');
}

fn stepReal(w: *std.Io.Writer, value: f64) std.Io.Writer.Error!void {
    if (!std.math.isFinite(value)) return error.WriteFailed;
    const zeroed = if (@abs(value) < 0.0000000005) @as(f64, 0) else value;
    try w.print("{d:.9}", .{zeroed});
}

fn writePoint(w: *std.Io.Writer, p: [3]f64) std.Io.Writer.Error!void {
    try stepReal(w, p[0]);
    try w.writeByte(',');
    try stepReal(w, p[1]);
    try w.writeByte(',');
    try stepReal(w, p[2]);
}

fn finitePoint(p: [3]f64) bool {
    return std.math.isFinite(p[0]) and std.math.isFinite(p[1]) and std.math.isFinite(p[2]) and
        @abs(p[0]) <= 1_000_000 and @abs(p[1]) <= 1_000_000 and @abs(p[2]) <= 1_000_000;
}

fn vectorLength(v: [3]f64) f64 {
    return @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
}

fn normalized(v: [3]f64) ?[3]f64 {
    const len = vectorLength(v);
    if (!(len > 1e-12) or !std.math.isFinite(len)) return null;
    return .{ v[0] / len, v[1] / len, v[2] / len };
}

fn cross(a: [3]f64, b: [3]f64) [3]f64 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn dot(a: [3]f64, b: [3]f64) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn matrixAxes(matrix: [16]f64) ExportError!struct { origin: [3]f64, x: [3]f64, z: [3]f64 } {
    const origin = [3]f64{ matrix[12], matrix[13], matrix[14] };
    const raw_x = [3]f64{ matrix[0], matrix[1], matrix[2] };
    const raw_y = [3]f64{ matrix[4], matrix[5], matrix[6] };
    const raw_z = [3]f64{ matrix[8], matrix[9], matrix[10] };
    if (@abs(vectorLength(raw_x) - 1) > 1e-5 or @abs(vectorLength(raw_y) - 1) > 1e-5 or @abs(vectorLength(raw_z) - 1) > 1e-5) return error.InvalidMatrix;
    const x = normalized(raw_x) orelse return error.InvalidMatrix;
    const y = normalized(raw_y) orelse return error.InvalidMatrix;
    const z = normalized(raw_z) orelse return error.InvalidMatrix;
    if (!finitePoint(origin)) return error.InvalidMatrix;
    if (@abs(dot(x, y)) > 1e-5 or @abs(dot(x, z)) > 1e-5 or @abs(dot(y, z)) > 1e-5) return error.InvalidMatrix;
    if (dot(cross(x, y), z) < 0.9999) return error.InvalidMatrix;
    if (@abs(matrix[3]) > 1e-8 or @abs(matrix[7]) > 1e-8 or @abs(matrix[11]) > 1e-8 or @abs(matrix[15] - 1) > 1e-8) return error.InvalidMatrix;
    return .{ .origin = origin, .x = x, .z = z };
}

fn skipSpaceAndComments(source: []const u8, at: *usize) ExportError!void {
    while (at.* < source.len) {
        if (std.ascii.isWhitespace(source[at.*])) {
            at.* += 1;
            continue;
        }
        if (at.* + 1 < source.len and source[at.*] == '/' and source[at.* + 1] == '*') {
            const end = std.mem.indexOfPos(u8, source, at.* + 2, "*/") orelse return error.InvalidStep;
            at.* = end + 2;
            continue;
        }
        break;
    }
}

fn dataSection(source: []const u8) ExportError![]const u8 {
    const data_pos = std.mem.indexOf(u8, source, "DATA;") orelse return error.InvalidStep;
    const start = data_pos + "DATA;".len;
    const end = std.mem.indexOfPos(u8, source, start, "ENDSEC;") orelse return error.InvalidStep;
    return source[start..end];
}

fn entityEnd(data: []const u8, start: usize) ExportError!usize {
    var at = start;
    var in_string = false;
    var in_comment = false;
    while (at < data.len) {
        if (in_comment) {
            if (at + 1 < data.len and data[at] == '*' and data[at + 1] == '/') {
                in_comment = false;
                at += 2;
            } else at += 1;
            continue;
        }
        if (in_string) {
            if (data[at] == '\'') {
                if (at + 1 < data.len and data[at + 1] == '\'') {
                    at += 2;
                    continue;
                }
                in_string = false;
            }
            at += 1;
            continue;
        }
        if (at + 1 < data.len and data[at] == '/' and data[at + 1] == '*') {
            in_comment = true;
            at += 2;
        } else if (data[at] == '\'') {
            in_string = true;
            at += 1;
        } else if (data[at] == ';') {
            return at;
        } else at += 1;
    }
    return error.InvalidStep;
}

fn parseEntities(allocator: std.mem.Allocator, source: []const u8) (ExportError || std.mem.Allocator.Error)![]Entity {
    const data = try dataSection(source);
    var entities: std.ArrayList(Entity) = .empty;
    errdefer entities.deinit(allocator);
    var at: usize = 0;
    while (true) {
        try skipSpaceAndComments(data, &at);
        if (at == data.len) break;
        if (data[at] != '#') return error.InvalidStep;
        at += 1;
        const id_start = at;
        while (at < data.len and std.ascii.isDigit(data[at])) at += 1;
        if (id_start == at) return error.InvalidStep;
        const old_id = std.fmt.parseInt(u64, data[id_start..at], 10) catch return error.InvalidStep;
        try skipSpaceAndComments(data, &at);
        if (at >= data.len or data[at] != '=') return error.InvalidStep;
        at += 1;
        const rhs_start = at;
        at = try entityEnd(data, at);
        const rhs = std.mem.trim(u8, data[rhs_start..at], " \t\r\n");
        if (rhs.len == 0) return error.InvalidStep;
        try entities.append(allocator, .{ .old_id = old_id, .rhs = rhs });
        at += 1;
    }
    if (entities.items.len == 0) return error.InvalidStep;
    std.mem.sort(Entity, entities.items, {}, struct {
        fn lessThan(_: void, a: Entity, b: Entity) bool {
            return a.old_id < b.old_id;
        }
    }.lessThan);
    for (entities.items, 0..) |entity, i| {
        if (i > 0 and entities.items[i - 1].old_id == entity.old_id) return error.InvalidStep;
    }
    return entities.toOwnedSlice(allocator);
}

fn entityType(rhs: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, rhs, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] == '(') return "";
    var end: usize = 0;
    while (end < trimmed.len and (std.ascii.isAlphanumeric(trimmed[end]) or trimmed[end] == '_')) end += 1;
    return trimmed[0..end];
}

fn collectRefs(allocator: std.mem.Allocator, rhs: []const u8) std.mem.Allocator.Error![]u64 {
    var refs: std.ArrayList(u64) = .empty;
    errdefer refs.deinit(allocator);
    var at: usize = 0;
    var in_string = false;
    var in_comment = false;
    while (at < rhs.len) {
        if (in_comment) {
            if (at + 1 < rhs.len and rhs[at] == '*' and rhs[at + 1] == '/') {
                in_comment = false;
                at += 2;
            } else at += 1;
            continue;
        }
        if (in_string) {
            if (rhs[at] == '\'') {
                if (at + 1 < rhs.len and rhs[at + 1] == '\'') {
                    at += 2;
                    continue;
                }
                in_string = false;
            }
            at += 1;
            continue;
        }
        if (at + 1 < rhs.len and rhs[at] == '/' and rhs[at + 1] == '*') {
            in_comment = true;
            at += 2;
        } else if (rhs[at] == '\'') {
            in_string = true;
            at += 1;
        } else if (rhs[at] == '#') {
            at += 1;
            const start = at;
            while (at < rhs.len and std.ascii.isDigit(rhs[at])) at += 1;
            if (start < at) try refs.append(allocator, std.fmt.parseInt(u64, rhs[start..at], 10) catch continue);
        } else at += 1;
    }
    return refs.toOwnedSlice(allocator);
}

fn findEntity(entities: []const Entity, old_id: u64) ?*const Entity {
    var lo: usize = 0;
    var hi = entities.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (entities[mid].old_id < old_id) lo = mid + 1 else hi = mid;
    }
    return if (lo < entities.len and entities[lo].old_id == old_id) &entities[lo] else null;
}

fn remappedId(entities: []const Entity, old_id: u64) ?u64 {
    return if (findEntity(entities, old_id)) |entity| entity.new_id else null;
}

fn discoverRoots(allocator: std.mem.Allocator, entities: []const Entity) (ExportError || std.mem.Allocator.Error)![]RootShape {
    var product_defs = std.AutoHashMapUnmanaged(u64, void).empty;
    var children = std.AutoHashMapUnmanaged(u64, void).empty;
    var shape_to_product = std.AutoHashMapUnmanaged(u64, u64).empty;
    defer product_defs.deinit(allocator);
    defer children.deinit(allocator);
    defer shape_to_product.deinit(allocator);

    for (entities) |entity| {
        const typ = entityType(entity.rhs);
        if (std.mem.eql(u8, typ, "PRODUCT_DEFINITION")) {
            try product_defs.put(allocator, entity.old_id, {});
        } else if (std.mem.eql(u8, typ, "NEXT_ASSEMBLY_USAGE_OCCURRENCE")) {
            const refs = try collectRefs(allocator, entity.rhs);
            defer allocator.free(refs);
            if (refs.len >= 2) try children.put(allocator, refs[refs.len - 1], {});
        } else if (std.mem.eql(u8, typ, "PRODUCT_DEFINITION_SHAPE")) {
            const refs = try collectRefs(allocator, entity.rhs);
            defer allocator.free(refs);
            if (refs.len >= 1) try shape_to_product.put(allocator, entity.old_id, refs[refs.len - 1]);
        }
    }

    var roots: std.ArrayList(RootShape) = .empty;
    errdefer roots.deinit(allocator);
    for (entities) |entity| {
        if (!std.mem.eql(u8, entityType(entity.rhs), "SHAPE_DEFINITION_REPRESENTATION")) continue;
        const refs = try collectRefs(allocator, entity.rhs);
        defer allocator.free(refs);
        if (refs.len < 2) continue;
        const product = shape_to_product.get(refs[0]) orelse continue;
        if (!product_defs.contains(product) or children.contains(product)) continue;
        const pd = remappedId(entities, product) orelse return error.InvalidStep;
        const rep = remappedId(entities, refs[1]) orelse return error.InvalidStep;
        var duplicate = false;
        for (roots.items) |root| if (root.product_definition == pd and root.representation == rep) {
            duplicate = true;
            break;
        };
        if (!duplicate) try roots.append(allocator, .{ .product_definition = pd, .representation = rep });
    }
    if (roots.items.len == 0) return error.InvalidStep;
    return roots.toOwnedSlice(allocator);
}

fn rewriteRhs(w: *std.Io.Writer, entities: []const Entity, rhs: []const u8) (ExportError || std.Io.Writer.Error)!void {
    var at: usize = 0;
    var copied: usize = 0;
    var in_string = false;
    var in_comment = false;
    while (at < rhs.len) {
        if (in_comment) {
            if (at + 1 < rhs.len and rhs[at] == '*' and rhs[at + 1] == '/') {
                at += 2;
                in_comment = false;
            } else at += 1;
            continue;
        }
        if (in_string) {
            if (rhs[at] == '\'') {
                if (at + 1 < rhs.len and rhs[at + 1] == '\'') {
                    at += 2;
                    continue;
                }
                in_string = false;
            }
            at += 1;
            continue;
        }
        if (at + 1 < rhs.len and rhs[at] == '/' and rhs[at + 1] == '*') {
            in_comment = true;
            at += 2;
        } else if (rhs[at] == '\'') {
            in_string = true;
            at += 1;
        } else if (rhs[at] == '#') {
            try w.writeAll(rhs[copied..at]);
            at += 1;
            const start = at;
            while (at < rhs.len and std.ascii.isDigit(rhs[at])) at += 1;
            if (start == at) return error.InvalidStep;
            const old_id = std.fmt.parseInt(u64, rhs[start..at], 10) catch return error.InvalidStep;
            const new_id = remappedId(entities, old_id) orelse return error.InvalidStep;
            try w.print("#{d}", .{new_id});
            copied = at;
        } else at += 1;
    }
    try w.writeAll(rhs[copied..]);
}

fn resolveModelName(allocator: std.mem.Allocator, project_dir: []const u8, footprint: []const u8) ?[]const u8 {
    var cfg = export_kicad.loadModelConfig(allocator, project_dir);
    defer cfg.deinit(allocator);
    if (cfg.get(footprint)) |entry| {
        if (entry.model) |model| return allocator.dupe(u8, model) catch null;
    }
    return footprint_mod.findModelFile(allocator, project_dir, footprint, footprint);
}

fn addImportedModel(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    filename: []const u8,
    next_id: *u64,
    total_bytes: *usize,
) (ExportError || std.mem.Allocator.Error)!ImportedModel {
    const path = try std.fmt.allocPrint(allocator, "{s}/lib/models/{s}", .{ project_dir, filename });
    const source = infra_fs.cwd().readFileAlloc(allocator, path, max_model_bytes) catch return error.MissingModel;
    total_bytes.* = std.math.add(usize, total_bytes.*, source.len) catch return error.ModelLimit;
    if (total_bytes.* > max_total_model_bytes) return error.ModelLimit;
    const entities = try parseEntities(allocator, source);
    for (entities) |*entity| {
        entity.new_id = next_id.*;
        next_id.* += 1;
    }
    const roots = try discoverRoots(allocator, entities);
    return .{ .filename = filename, .entities = entities, .roots = roots };
}

fn writeDirection(w: *std.Io.Writer, id: u64, v: [3]f64) std.Io.Writer.Error!void {
    try w.print("#{d}=DIRECTION('',(", .{id});
    try writePoint(w, v);
    try w.writeAll("));\n");
}

const StyleState = struct {
    assignments: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    styled_items: std.ArrayList(u64) = .empty,

    fn colorKey(color: [3]f64) ?u64 {
        var key: u64 = 0;
        for (color, 0..) |channel, i| {
            if (!std.math.isFinite(channel) or channel < 0 or channel > 1) return null;
            const quantized: u64 = @intFromFloat(@round(channel * 65535));
            key |= quantized << @intCast(i * 16);
        }
        return key;
    }

    fn assignment(self: *StyleState, allocator: std.mem.Allocator, w: *std.Io.Writer, next_id: *u64, color: [3]f64) (std.mem.Allocator.Error || std.Io.Writer.Error)!?u64 {
        const key = colorKey(color) orelse return null;
        if (self.assignments.get(key)) |existing| return existing;
        const rgb = next_id.*;
        const fill_color = rgb + 1;
        const fill = rgb + 2;
        const surface_fill = rgb + 3;
        const side = rgb + 4;
        const usage = rgb + 5;
        const assignment_id = rgb + 6;
        next_id.* += 7;
        try w.print("#{d}=COLOUR_RGB('',", .{rgb});
        try stepReal(w, color[0]);
        try w.writeByte(',');
        try stepReal(w, color[1]);
        try w.writeByte(',');
        try stepReal(w, color[2]);
        try w.writeAll(");\n");
        try w.print("#{d}=FILL_AREA_STYLE_COLOUR('',#{d});\n", .{ fill_color, rgb });
        try w.print("#{d}=FILL_AREA_STYLE('',(#{d}));\n", .{ fill, fill_color });
        try w.print("#{d}=SURFACE_STYLE_FILL_AREA(#{d});\n", .{ surface_fill, fill });
        try w.print("#{d}=SURFACE_SIDE_STYLE('',(#{d}));\n", .{ side, surface_fill });
        try w.print("#{d}=SURFACE_STYLE_USAGE(.BOTH.,#{d});\n", .{ usage, side });
        try w.print("#{d}=PRESENTATION_STYLE_ASSIGNMENT((#{d}));\n", .{ assignment_id, usage });
        try self.assignments.put(allocator, key, assignment_id);
        return assignment_id;
    }

    fn item(self: *StyleState, allocator: std.mem.Allocator, w: *std.Io.Writer, next_id: *u64, item_id: u64, color: ?[3]f64) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
        const value = color orelse return;
        const assignment_id = (try self.assignment(allocator, w, next_id, value)) orelse return;
        const styled = next_id.*;
        next_id.* += 1;
        try w.print("#{d}=STYLED_ITEM('',(#{d}),#{d});\n", .{ styled, assignment_id, item_id });
        try self.styled_items.append(allocator, styled);
    }
};

fn writeFacetedBodies(w: *std.Io.Writer, bodies: []const Body, next_id: *u64, root_items: *std.ArrayList(u64), styles: *StyleState, allocator: std.mem.Allocator) (ExportError || std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    for (bodies) |body| {
        if (body.points.len < 4 or body.points.len > max_points_per_body or body.triangles.len < 4 or body.triangles.len > max_triangles_per_body) return error.InvalidGeometry;
        const point_ids = try allocator.alloc(u64, body.points.len);
        for (body.points, 0..) |point, i| {
            if (!finitePoint(point)) return error.InvalidGeometry;
            point_ids[i] = next_id.*;
            next_id.* += 1;
            try w.print("#{d}=CARTESIAN_POINT('',(", .{point_ids[i]});
            try writePoint(w, point);
            try w.writeAll("));\n");
        }
        var face_ids: std.ArrayList(u64) = .empty;
        for (body.triangles, 0..) |triangle, triangle_index| {
            if (triangle[0] >= body.points.len or triangle[1] >= body.points.len or triangle[2] >= body.points.len) return error.InvalidGeometry;
            const a = body.points[triangle[0]];
            const b = body.points[triangle[1]];
            const c = body.points[triangle[2]];
            const ab = [3]f64{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
            const ac = [3]f64{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
            const normal = normalized(cross(ab, ac)) orelse return error.InvalidGeometry;
            const reference = normalized(ab) orelse return error.InvalidGeometry;
            const loop = next_id.*;
            const bound = loop + 1;
            const normal_id = loop + 2;
            const reference_id = loop + 3;
            const placement = loop + 4;
            const plane = loop + 5;
            const face = loop + 6;
            next_id.* += 7;
            try w.print("#{d}=POLY_LOOP('',(#{d},#{d},#{d}));\n", .{ loop, point_ids[triangle[0]], point_ids[triangle[1]], point_ids[triangle[2]] });
            try w.print("#{d}=FACE_OUTER_BOUND('',#{d},.T.);\n", .{ bound, loop });
            try writeDirection(w, normal_id, normal);
            try writeDirection(w, reference_id, reference);
            try w.print("#{d}=AXIS2_PLACEMENT_3D('',#{d},#{d},#{d});\n", .{ placement, point_ids[triangle[0]], normal_id, reference_id });
            try w.print("#{d}=PLANE('',#{d});\n", .{ plane, placement });
            try w.print("#{d}=FACE_SURFACE('',(#{d}),#{d},.T.);\n", .{ face, bound, plane });
            const triangle_color = if (body.triangleColors) |colors|
                (if (triangle_index < colors.len) colors[triangle_index] else null)
            else
                null;
            try styles.item(allocator, w, next_id, face, triangle_color);
            try face_ids.append(allocator, face);
        }
        const shell = next_id.*;
        const brep = shell + 1;
        next_id.* += 2;
        try w.print("#{d}=CLOSED_SHELL(", .{shell});
        try stepText(w, body.name);
        try w.writeAll(",(");
        for (face_ids.items, 0..) |face, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("#{d}", .{face});
        }
        try w.writeAll("));\n");
        try w.print("#{d}=FACETED_BREP(", .{brep});
        try stepText(w, body.name);
        try w.print(",#{d});\n", .{shell});
        try root_items.append(allocator, brep);
        try styles.item(allocator, w, next_id, brep, body.color);
    }
}

fn build(allocator: std.mem.Allocator, project_dir: []const u8, design_name: []const u8, request: Request) (ExportError || std.mem.Allocator.Error || std.Io.Writer.Error)![]const u8 {
    if (request.bodies.len == 0 or request.bodies.len > max_bodies or request.instances.len > max_instances) return error.BadRequest;

    var next_id: u64 = 18;
    var models: std.ArrayList(ImportedModel) = .empty;
    var model_refs = std.StringHashMapUnmanaged(usize).empty;
    var instance_model_indexes = try allocator.alloc(usize, request.instances.len);
    var total_model_bytes: usize = 0;

    for (request.instances, 0..) |instance, i| {
        if (!safeFootprint(instance.footprint) or instance.name.len > 256) return error.BadRequest;
        _ = try matrixAxes(instance.matrix);
        const filename = resolveModelName(allocator, project_dir, instance.footprint) orelse return error.MissingModel;
        if (model_refs.get(filename)) |index| {
            instance_model_indexes[i] = index;
            continue;
        }
        const owned_name = try allocator.dupe(u8, filename);
        const model = try addImportedModel(allocator, project_dir, owned_name, &next_id, &total_model_bytes);
        const index = models.items.len;
        try models.append(allocator, model);
        try model_refs.put(allocator, owned_name, index);
        instance_model_indexes[i] = index;
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    const w = &out.writer;
    try w.writeAll("ISO-10303-21;\nHEADER;\n" ++
        "FILE_DESCRIPTION(('Canopy exact PCB assembly'),'2;1');\n" ++
        "FILE_NAME('canopy-pcb.step','',('Canopy'),('Canopy'),'Canopy EDA','','');\n" ++
        "FILE_SCHEMA(('AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF { 1 0 10303 442 1 1 4 }'));\n" ++
        "ENDSEC;\nDATA;\n" ++
        "#1=APPLICATION_CONTEXT('managed model based 3d engineering');\n" ++
        "#2=APPLICATION_PROTOCOL_DEFINITION('international standard','ap242_managed_model_based_3d_engineering',2014,#1);\n" ++
        "#3=PRODUCT_CONTEXT('',#1,'mechanical');\n" ++
        "#4=PRODUCT('");
    for (design_name) |c| {
        if (c == '\'') try w.writeByte('\'');
        try w.writeByte(if (c < 0x20 or c == 0x7f) ' ' else c);
    }
    try w.writeAll("','PCB assembly','',(#3));\n#5=PRODUCT_DEFINITION_FORMATION('','',#4);\n#6=PRODUCT_DEFINITION_CONTEXT('part definition',#1,'design');\n#7=PRODUCT_DEFINITION('design','',#5,#6);\n#8=PRODUCT_DEFINITION_SHAPE('','',#7);\n#9=(LENGTH_UNIT()NAMED_UNIT(*)SI_UNIT(.MILLI.,.METRE.));\n#10=(NAMED_UNIT(*)PLANE_ANGLE_UNIT()SI_UNIT($,.RADIAN.));\n#11=(NAMED_UNIT(*)SI_UNIT($,.STERADIAN.)SOLID_ANGLE_UNIT());\n#12=UNCERTAINTY_MEASURE_WITH_UNIT(LENGTH_MEASURE(1.E-6),#9,'distance_accuracy_value','confusion accuracy');\n#13=(GEOMETRIC_REPRESENTATION_CONTEXT(3)GLOBAL_UNCERTAINTY_ASSIGNED_CONTEXT((#12))GLOBAL_UNIT_ASSIGNED_CONTEXT((#9,#10,#11))REPRESENTATION_CONTEXT('','3D Context'));\n#14=CARTESIAN_POINT('',(0.,0.,0.));\n#15=DIRECTION('',(0.,0.,1.));\n#16=DIRECTION('',(1.,0.,0.));\n#17=AXIS2_PLACEMENT_3D('',#14,#15,#16);\n");

    for (models.items) |model| {
        for (model.entities) |entity| {
            try w.print("#{d}=", .{entity.new_id});
            try rewriteRhs(w, model.entities, entity.rhs);
            try w.writeAll(";\n");
        }
    }

    var root_items: std.ArrayList(u64) = .empty;
    var styles: StyleState = .{};
    try root_items.append(allocator, 17);
    try writeFacetedBodies(w, request.bodies, &next_id, &root_items, &styles, allocator);

    const root_representation = next_id;
    next_id += 1;
    try w.print("#{d}=SHAPE_REPRESENTATION(", .{root_representation});
    try stepText(w, design_name);
    try w.writeAll(",(");
    for (root_items.items, 0..) |item, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("#{d}", .{item});
    }
    try w.writeAll("),#13);\n");
    try w.print("#{d}=SHAPE_DEFINITION_REPRESENTATION(#8,#{d});\n", .{ next_id, root_representation });
    next_id += 1;
    if (styles.styled_items.items.len > 0) {
        try w.print("#{d}=MECHANICAL_DESIGN_GEOMETRIC_PRESENTATION_REPRESENTATION('',(", .{next_id});
        for (styles.styled_items.items, 0..) |styled, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("#{d}", .{styled});
        }
        try w.writeAll("),#13);\n");
        next_id += 1;
    }

    for (request.instances, 0..) |instance, i| {
        const model = models.items[instance_model_indexes[i]];
        const axes = try matrixAxes(instance.matrix);
        const point = next_id;
        const z_direction = point + 1;
        const x_direction = point + 2;
        const placement = point + 3;
        next_id += 4;
        try w.print("#{d}=CARTESIAN_POINT('',(", .{point});
        try writePoint(w, axes.origin);
        try w.writeAll("));\n");
        try writeDirection(w, z_direction, axes.z);
        try writeDirection(w, x_direction, axes.x);
        try w.print("#{d}=AXIS2_PLACEMENT_3D('',#{d},#{d},#{d});\n", .{ placement, point, z_direction, x_direction });

        for (model.roots, 0..) |root, root_index| {
            const nauo = next_id;
            const occurrence_shape = nauo + 1;
            const transform = nauo + 2;
            const relationship = nauo + 3;
            const dependent = nauo + 4;
            next_id += 5;
            try w.print("#{d}=NEXT_ASSEMBLY_USAGE_OCCURRENCE(", .{nauo});
            try stepText(w, instance.name);
            try w.writeByte(',');
            try stepText(w, if (model.roots.len > 1) model.filename else instance.name);
            try w.writeByte(',');
            try stepText(w, "");
            try w.print(",#7,#{d},$);\n", .{root.product_definition});
            try w.print("#{d}=PRODUCT_DEFINITION_SHAPE('','',#{d});\n", .{ occurrence_shape, nauo });
            try w.print("#{d}=ITEM_DEFINED_TRANSFORMATION('','',#17,#{d});\n", .{ transform, placement });
            try w.print("#{d}=(REPRESENTATION_RELATIONSHIP('',", .{relationship});
            if (root_index == 0) try stepText(w, instance.name) else try stepText(w, model.filename);
            try w.print(",#{d},#{d})REPRESENTATION_RELATIONSHIP_WITH_TRANSFORMATION(#{d})SHAPE_REPRESENTATION_RELATIONSHIP());\n", .{ root.representation, root_representation, transform });
            try w.print("#{d}=CONTEXT_DEPENDENT_SHAPE_REPRESENTATION(#{d},#{d});\n", .{ dependent, relationship, occurrence_shape });
        }
    }

    try w.writeAll("ENDSEC;\nEND-ISO-10303-21;\n");
    return out.written();
}

fn sendError(res: *httpz.Response, status: u16, message: []const u8) void {
    res.status = status;
    res.content_type = .TEXT;
    res.body = message;
}

/// POST /api/pcb-step/:name — compose exact source STEP B-reps with the small
/// generated board/heatsink solids and return one self-contained AP242 file.
pub fn pcbStepApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse return sendError(res, 404, "design not found");
    if (!safeDesignName(name)) return sendError(res, 400, "invalid design name");
    const body = req.body() orelse return sendError(res, 400, "missing export body");
    if (body.len > max_request_bytes) return sendError(res, 413, "STEP export request is too large");
    const request = std.json.parseFromSliceLeaky(Request, req.arena, body, .{ .ignore_unknown_fields = true }) catch
        return sendError(res, 400, "invalid STEP export data");
    const output = build(req.arena, ctx.project_dir, name, request) catch |err| switch (err) {
        error.BadRequest, error.InvalidGeometry, error.InvalidMatrix, error.InvalidStep => return sendError(res, 400, @errorName(err)),
        error.MissingModel => return sendError(res, 404, "component STEP model not found"),
        error.ModelLimit => return sendError(res, 413, "component STEP models exceed the export limit"),
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.WriteFailed,
    };
    const filename = try std.fmt.allocPrint(req.arena, "attachment; filename=\"{s}.step\"", .{name});
    res.header("Content-Type", "model/step");
    res.header("Content-Disposition", filename);
    res.header("Cache-Control", "no-store");
    res.body = output;
}

test "STEP entity parser renumbers references but leaves hashes in strings and comments" {
    const source =
        "ISO-10303-21;\nHEADER;\nFILE_SCHEMA(('AUTOMOTIVE_DESIGN'));\nENDSEC;\nDATA;\n" ++
        "#20=PRODUCT('hash #10','', '', (#10));\n" ++
        "#10=CARTESIAN_POINT('',(1.,2.,3.)); /* #20 */\n" ++
        "ENDSEC;\nEND-ISO-10303-21;\n";
    const entities = try parseEntities(std.testing.allocator, source);
    defer std.testing.allocator.free(entities);
    entities[0].new_id = 100;
    entities[1].new_id = 101;
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try rewriteRhs(&out.writer, entities, entities[1].rhs);
    try std.testing.expectEqualStrings("PRODUCT('hash #10','', '', (#100))", out.written());
}

test "STEP root discovery keeps only the top product of a source assembly" {
    const source =
        "ISO-10303-21;HEADER;FILE_SCHEMA(('AUTOMOTIVE_DESIGN'));ENDSEC;DATA;" ++
        "#1=PRODUCT_DEFINITION('','',#50,#51);" ++
        "#2=PRODUCT_DEFINITION('','',#50,#51);" ++
        "#3=NEXT_ASSEMBLY_USAGE_OCCURRENCE('','','',#1,#2,$);" ++
        "#4=PRODUCT_DEFINITION_SHAPE('','',#1);" ++
        "#5=PRODUCT_DEFINITION_SHAPE('','',#2);" ++
        "#6=SHAPE_DEFINITION_REPRESENTATION(#4,#8);" ++
        "#7=SHAPE_DEFINITION_REPRESENTATION(#5,#9);" ++
        "#8=SHAPE_REPRESENTATION('',(),#52);" ++
        "#9=ADVANCED_BREP_SHAPE_REPRESENTATION('',(),#52);" ++
        "#50=PRODUCT_DEFINITION_FORMATION('','',#53);" ++
        "#51=PRODUCT_DEFINITION_CONTEXT('',#54,'design');" ++
        "#52=REPRESENTATION_CONTEXT('','');" ++
        "#53=PRODUCT('','','',());" ++
        "#54=APPLICATION_CONTEXT('');ENDSEC;END-ISO-10303-21;";
    const entities = try parseEntities(std.testing.allocator, source);
    defer std.testing.allocator.free(entities);
    for (entities, 0..) |*entity, i| entity.new_id = @intCast(i + 100);
    const roots = try discoverRoots(std.testing.allocator, entities);
    defer std.testing.allocator.free(roots);
    try std.testing.expectEqual(@as(usize, 1), roots.len);
    try std.testing.expectEqual(@as(u64, 100), roots[0].product_definition);
    try std.testing.expectEqual(@as(u64, 107), roots[0].representation);
}

test "matrix extraction rejects scaling and preserves rigid component placement" {
    const matrix = [16]f64{
        0,  1,  0, 0,
        -1, 0,  0, 0,
        0,  0,  1, 0,
        12, -4, 3, 1,
    };
    const axes = try matrixAxes(matrix);
    try std.testing.expectEqual([3]f64{ 12, -4, 3 }, axes.origin);
    try std.testing.expectEqual([3]f64{ 0, 1, 0 }, axes.x);
    try std.testing.expectEqual([3]f64{ 0, 0, 1 }, axes.z);
    var scaled = matrix;
    scaled[0] = 2;
    try std.testing.expectError(error.InvalidMatrix, matrixAxes(scaled));
}

test "exact assembly embeds one source B-rep and instances repeated footprints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/models");
    const source =
        "ISO-10303-21;HEADER;FILE_SCHEMA(('AUTOMOTIVE_DESIGN'));ENDSEC;DATA;" ++
        "#1=PRODUCT_DEFINITION('','',#2,#3);" ++
        "#2=PRODUCT_DEFINITION_FORMATION('','',#4);" ++
        "#3=PRODUCT_DEFINITION_CONTEXT('',#5,'design');" ++
        "#4=PRODUCT('demo','demo','',(#6));" ++
        "#5=APPLICATION_CONTEXT('');" ++
        "#6=PRODUCT_CONTEXT('',#5,'mechanical');" ++
        "#7=PRODUCT_DEFINITION_SHAPE('','',#1);" ++
        "#8=ADVANCED_BREP_SHAPE_REPRESENTATION('',(#9),#10);" ++
        "#9=MANIFOLD_SOLID_BREP('exact source',#11);" ++
        "#10=(GEOMETRIC_REPRESENTATION_CONTEXT(3)REPRESENTATION_CONTEXT('',''));" ++
        "#11=CLOSED_SHELL('',());" ++
        "#12=SHAPE_DEFINITION_REPRESENTATION(#7,#8);" ++
        "ENDSEC;END-ISO-10303-21;";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/models/demo.step", .data = source });
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", aa);
    const identity = [16]f64{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };
    var shifted = identity;
    shifted[12] = 25;
    const output = try build(aa, project_dir, "fixture", .{
        .bodies = &.{.{
            .name = "PCB",
            .points = &.{ .{ 0, 0, 0 }, .{ 10, 0, 0 }, .{ 0, 10, 0 }, .{ 0, 0, -1.6 } },
            .triangles = &.{ .{ 0, 2, 1 }, .{ 0, 1, 3 }, .{ 1, 2, 3 }, .{ 2, 0, 3 } },
            .color = .{ 0.1, 0.4, 0.2 },
        }},
        .instances = &.{
            .{ .name = "J1", .footprint = "demo", .matrix = identity },
            .{ .name = "J2", .footprint = "demo", .matrix = shifted },
        },
    });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "ADVANCED_BREP_SHAPE_REPRESENTATION"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output, "NEXT_ASSEMBLY_USAGE_OCCURRENCE"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output, "REPRESENTATION_RELATIONSHIP_WITH_TRANSFORMATION"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "COLOUR_RGB('',0.100000000,0.400000000,0.200000000)"));
    try std.testing.expect(std.mem.indexOf(u8, output, "MECHANICAL_DESIGN_GEOMETRIC_PRESENTATION_REPRESENTATION") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "CARTESIAN_POINT('',(25.000000000,0.000000000,0.000000000))") != null);
}
