//! Server-side PCB STEP assembly composer.
//!
//! The browser sends an outline/thickness/hole recipe for the green PCB, which
//! is authored here as an analytic advanced B-rep rather than copying display
//! triangles. Generated heatsinks remain small faceted bodies. Component
//! geometry never crosses the wire: each unique library STEP is parsed here,
//! copied into the AP242 exchange structure without tessellation, then instanced
//! with an assembly transform. Repeated packages therefore share one exact
//! B-rep definition instead of expanding the preview triangles per placement.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const export_kicad = @import("../export_kicad.zig");
const board_shape = @import("../board_shape.zig");
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
const max_board_outline_points: usize = 2048;
const max_board_outline_arcs: usize = 512;
const max_board_holes: usize = 1024;

pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// Reusable faceted solid input. Mechanical CAD uses this seam so enclosure
/// geometry generated in Zig reaches STEP without a browser JSON round trip.
pub const Body = struct {
    name: []const u8,
    points: []const [3]f64,
    triangles: []const [3]usize,
    color: ?[3]f64 = null,
    triangleColors: ?[]const ?[3]f64 = null,
    /// Legacy browser payloads used zero-thickness surface bodies for artwork.
    /// They are deliberately ignored: Fusion exposes their raster-derived
    /// triangle topology instead of treating them as an image/decal.
    surface: bool = false,
};

const BoardHole = struct {
    x: f64,
    y: f64,
    r: f64,
    /// A second centre turns the round hole into a capsule slot. Both values
    /// must either be present or absent.
    x2: ?f64 = null,
    y2: ?f64 = null,
};

const BoardArc = struct {
    p1: [2]f64,
    pm: [2]f64,
    p2: [2]f64,
};

const Board = struct {
    name: []const u8 = "PCB",
    /// Viewer-world millimetres (X right, Y north), without a repeated closing
    /// point. The server still tolerates that common repeated endpoint.
    outline: []const [2]f64,
    /// Exact three-point circular pieces within `outline`. The polygon remains
    /// the validation/containment fallback; these replace their owned chord
    /// runs with STEP CIRCLE edges and cylindrical side faces.
    arcs: []const BoardArc = &.{},
    holes: []const BoardHole = &.{},
    thickness: f64,
    color: ?[3]f64 = .{ 0.047, 0.404, 0.204 },
};

const Instance = struct {
    name: []const u8,
    footprint: []const u8,
    /// Three.js column-major Matrix4 mapping untouched model coordinates into
    /// the PCB viewer's millimetre world frame.
    matrix: [16]f64,
};

const Request = struct {
    board: ?Board = null,
    bodies: []const Body = &.{},
    instances: []const Instance = &.{},
};

const BoardProduct = struct {
    name: []const u8,
    product_definition: u64,
    representation: u64,
    assembly_offset: [3]f64,
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

pub const ExportError = error{
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

fn finitePoint2(p: [2]f64) bool {
    return std.math.isFinite(p[0]) and std.math.isFinite(p[1]) and
        @abs(p[0]) <= 1_000_000 and @abs(p[1]) <= 1_000_000;
}

const BoardArcCircle = struct {
    center: [2]f64,
    radius: f64,
    start_angle: f64,
    sweep: f64,
};

/// The board outline's own three-point arc recovery (`board_shape.arcCircle`),
/// plus the extra rejections a B-rep needs that a 2-D outline does not: a
/// non-finite input point, a degenerate radius, and a sweep so small or so
/// near a full turn that no CIRCLE edge can be built from it.
fn boardArcCircle(arc: BoardArc) ?BoardArcCircle {
    if (!finitePoint2(arc.p1)) return null;
    if (!finitePoint2(arc.pm)) return null;
    if (!finitePoint2(arc.p2)) return null;
    const circle = board_shape.arcCircle(.{ .p1 = arc.p1, .pm = arc.pm, .p2 = arc.p2 }) orelse return null;
    if (!(circle.radius > 1e-9) or !std.math.isFinite(circle.radius)) return null;
    if (@abs(circle.sweep) < 1e-9 or @abs(circle.sweep) >= std.math.tau - 1e-9) return null;
    return .{
        .center = .{ circle.cx, circle.cy },
        .radius = circle.radius,
        .start_angle = circle.start_angle,
        .sweep = circle.sweep,
    };
}

fn reversedBoardArc(arc: BoardArc) BoardArc {
    return .{ .p1 = arc.p2, .pm = arc.pm, .p2 = arc.p1 };
}

fn arcProgress(circle: BoardArcCircle, point: [2]f64) f64 {
    const angle = std.math.atan2(point[1] - circle.center[1], point[0] - circle.center[0]);
    return if (circle.sweep >= 0)
        @mod(angle - circle.start_angle, std.math.tau)
    else
        @mod(circle.start_angle - angle, std.math.tau);
}

fn arcOwnsDirectedSegment(circle: BoardArcCircle, a: [2]f64, b: [2]f64, tolerance: f64) bool {
    const ra = std.math.hypot(a[0] - circle.center[0], a[1] - circle.center[1]);
    const rb = std.math.hypot(b[0] - circle.center[0], b[1] - circle.center[1]);
    if (@abs(ra - circle.radius) > tolerance or @abs(rb - circle.radius) > tolerance) return false;
    const angular_tolerance = tolerance / @max(circle.radius, tolerance);
    const pa = arcProgress(circle, a);
    const pb = arcProgress(circle, b);
    return pa <= @abs(circle.sweep) + angular_tolerance and
        pb <= @abs(circle.sweep) + angular_tolerance and
        pb + angular_tolerance >= pa;
}

fn pointDistanceSquared2(a: [2]f64, b: [2]f64) f64 {
    const dx = a[0] - b[0];
    const dy = a[1] - b[1];
    return dx * dx + dy * dy;
}

fn signedArea2(points: []const [2]f64) f64 {
    var twice_area: f64 = 0;
    for (points, 0..) |a, i| {
        const b = points[(i + 1) % points.len];
        twice_area += a[0] * b[1] - b[0] * a[1];
    }
    return twice_area / 2;
}

fn orient2(a: [2]f64, b: [2]f64, c: [2]f64) f64 {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

fn pointOnSegment2(p: [2]f64, a: [2]f64, b: [2]f64, tolerance: f64) bool {
    if (@abs(orient2(a, b, p)) > tolerance) return false;
    return p[0] >= @min(a[0], b[0]) - tolerance and p[0] <= @max(a[0], b[0]) + tolerance and
        p[1] >= @min(a[1], b[1]) - tolerance and p[1] <= @max(a[1], b[1]) + tolerance;
}

fn segmentsIntersect2(a: [2]f64, b: [2]f64, c: [2]f64, d: [2]f64) bool {
    const tolerance = 1e-9;
    const ab_c = orient2(a, b, c);
    const ab_d = orient2(a, b, d);
    const cd_a = orient2(c, d, a);
    const cd_b = orient2(c, d, b);
    const c_and_d_opposite = (ab_c > tolerance and ab_d < -tolerance) or (ab_c < -tolerance and ab_d > tolerance);
    const a_and_b_opposite = (cd_a > tolerance and cd_b < -tolerance) or (cd_a < -tolerance and cd_b > tolerance);
    if (c_and_d_opposite and a_and_b_opposite) return true;
    if (pointOnSegment2(c, a, b, tolerance)) return true;
    if (pointOnSegment2(d, a, b, tolerance)) return true;
    if (pointOnSegment2(a, c, d, tolerance)) return true;
    return pointOnSegment2(b, c, d, tolerance);
}

fn simplePolygon2(points: []const [2]f64) bool {
    for (points, 0..) |a, i| {
        const i_next = (i + 1) % points.len;
        const b = points[i_next];
        for (points, 0..) |c, j| {
            if (j <= i) continue;
            const j_next = (j + 1) % points.len;
            // Neighbouring edges share one endpoint by construction.
            if (i == j or i_next == j or j_next == i) continue;
            if (segmentsIntersect2(a, b, c, points[j_next])) return false;
        }
    }
    return true;
}

fn pointInPolygon2(points: []const [2]f64, p: [2]f64) bool {
    var inside = false;
    var j = points.len - 1;
    for (points, 0..) |pi, i| {
        const pj = points[j];
        if (pointOnSegment2(p, pj, pi, 1e-9)) return true;
        if ((pi[1] > p[1]) != (pj[1] > p[1])) {
            const x_cross = (pj[0] - pi[0]) * (p[1] - pi[1]) / (pj[1] - pi[1]) + pi[0];
            if (p[0] < x_cross) inside = !inside;
        }
        j = i;
    }
    return inside;
}

fn pointSegmentDistanceSquared2(p: [2]f64, a: [2]f64, b: [2]f64) f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const length_squared = dx * dx + dy * dy;
    if (!(length_squared > 1e-24)) return pointDistanceSquared2(p, a);
    const raw_t = ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / length_squared;
    const t = @max(0, @min(1, raw_t));
    return pointDistanceSquared2(p, .{ a[0] + t * dx, a[1] + t * dy });
}

fn segmentDistanceSquared2(a: [2]f64, b: [2]f64, c: [2]f64, d: [2]f64) f64 {
    if (segmentsIntersect2(a, b, c, d)) return 0;
    return @min(
        @min(pointSegmentDistanceSquared2(a, c, d), pointSegmentDistanceSquared2(b, c, d)),
        @min(pointSegmentDistanceSquared2(c, a, b), pointSegmentDistanceSquared2(d, a, b)),
    );
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

const PreparedCurve = struct {
    start: [2]f64,
    finish: [2]f64,
    arc: ?BoardArcCircle = null,
};

const PreparedRing = struct {
    curves: []const PreparedCurve,
};

const PreparedBoard = struct {
    name: []const u8,
    rings: []const PreparedRing,
    thickness: f64,
    color: ?[3]f64,
};

fn reversePoints2(points: [][2]f64) void {
    var i: usize = 0;
    while (i < points.len / 2) : (i += 1) {
        const opposite = points.len - 1 - i;
        const tmp = points[i];
        points[i] = points[opposite];
        points[opposite] = tmp;
    }
}

fn pointIndexNear(points: []const [2]f64, wanted: [2]f64) ?usize {
    for (points, 0..) |point, i| {
        if (pointDistanceSquared2(point, wanted) <= 1e-10) return i;
    }
    return null;
}

fn prepareLineRing(allocator: std.mem.Allocator, points: []const [2]f64) std.mem.Allocator.Error!PreparedRing {
    const curves = try allocator.alloc(PreparedCurve, points.len);
    for (curves, 0..) |*curve, i| curve.* = .{
        .start = points[i],
        .finish = points[(i + 1) % points.len],
    };
    return .{ .curves = curves };
}

fn prepareOuterRing(
    allocator: std.mem.Allocator,
    points: []const [2]f64,
    source_arcs: []const BoardArc,
    reversed: bool,
) (ExportError || std.mem.Allocator.Error)!PreparedRing {
    if (source_arcs.len == 0) return prepareLineRing(allocator, points);
    const edge_arcs = try allocator.alloc(?usize, points.len);
    @memset(edge_arcs, null);
    const arc_starts = try allocator.alloc(usize, source_arcs.len);
    const arc_counts = try allocator.alloc(usize, source_arcs.len);
    const circles = try allocator.alloc(BoardArcCircle, source_arcs.len);

    for (source_arcs, 0..) |source_arc, arc_index| {
        const arc = if (reversed) reversedBoardArc(source_arc) else source_arc;
        const circle = boardArcCircle(arc) orelse return error.InvalidGeometry;
        const start = pointIndexNear(points, arc.p1) orelse return error.InvalidGeometry;
        const finish = pointIndexNear(points, arc.p2) orelse return error.InvalidGeometry;
        if (start == finish) return error.InvalidGeometry;
        var edge = start;
        var count: usize = 0;
        while (edge != finish) {
            if (count >= points.len) return error.InvalidGeometry;
            const after = (edge + 1) % points.len;
            if (!arcOwnsDirectedSegment(circle, points[edge], points[after], 0.0001)) return error.InvalidGeometry;
            if (edge_arcs[edge] != null) return error.InvalidGeometry;
            edge_arcs[edge] = arc_index;
            count += 1;
            edge = after;
        }
        if (count == 0) return error.InvalidGeometry;
        arc_starts[arc_index] = start;
        arc_counts[arc_index] = count;
        circles[arc_index] = circle;
    }

    var first_edge: usize = 0;
    var found_line = false;
    for (edge_arcs, 0..) |arc, edge| {
        if (arc == null) {
            first_edge = edge;
            found_line = true;
            break;
        }
    }
    if (!found_line) first_edge = arc_starts[0];

    var curves: std.ArrayList(PreparedCurve) = .empty;
    errdefer curves.deinit(allocator);
    var edge = first_edge;
    var traversed: usize = 0;
    while (traversed < points.len) {
        if (edge_arcs[edge]) |arc_index| {
            if (edge != arc_starts[arc_index]) return error.InvalidGeometry;
            const count = arc_counts[arc_index];
            const after = (edge + count) % points.len;
            try curves.append(allocator, .{
                .start = points[edge],
                .finish = points[after],
                .arc = circles[arc_index],
            });
            traversed += count;
            edge = after;
        } else {
            const after = (edge + 1) % points.len;
            try curves.append(allocator, .{ .start = points[edge], .finish = points[after] });
            traversed += 1;
            edge = after;
        }
    }
    if (edge != first_edge or curves.items.len < 2) return error.InvalidGeometry;
    return .{ .curves = try curves.toOwnedSlice(allocator) };
}

const BoardHoleAxis = struct { start: [2]f64, finish: [2]f64 };

fn validateBoardHole(board: Board, outer: []const [2]f64, hole_index: usize) ExportError!BoardHoleAxis {
    const hole = board.holes[hole_index];
    const start = [2]f64{ hole.x, hole.y };
    const has_x2 = hole.x2 != null;
    const has_y2 = hole.y2 != null;
    if (has_x2 != has_y2) return error.InvalidGeometry;
    if (!finitePoint2(start) or !std.math.isFinite(hole.r)) return error.InvalidGeometry;
    if (!(hole.r > 0.00001) or hole.r > 100_000) return error.InvalidGeometry;
    const finish = if (has_x2) [2]f64{ hole.x2.?, hole.y2.? } else start;
    if (!finitePoint2(finish)) return error.InvalidGeometry;
    if (!pointInPolygon2(outer, start) or !pointInPolygon2(outer, finish)) return error.InvalidGeometry;

    const required_clearance_squared = (hole.r + 1e-7) * (hole.r + 1e-7);
    for (outer, 0..) |a, edge_index| {
        const b = outer[(edge_index + 1) % outer.len];
        if (segmentDistanceSquared2(start, finish, a, b) < required_clearance_squared) return error.InvalidGeometry;
    }
    for (board.holes[0..hole_index]) |other| {
        const other_start = [2]f64{ other.x, other.y };
        const other_finish = if (other.x2 != null and other.y2 != null)
            [2]f64{ other.x2.?, other.y2.? }
        else
            other_start;
        const separation = hole.r + other.r + 1e-7;
        if (segmentDistanceSquared2(start, finish, other_start, other_finish) < separation * separation) return error.InvalidGeometry;
    }
    return .{ .start = start, .finish = finish };
}

/// Build the clockwise inner wire for a mechanical hole without approximating
/// any circular boundary with chords. A round drill is one closed CIRCLE edge;
/// a routed slot is two straight edges joined by exact semicircles.
fn prepareBoardHoleRing(allocator: std.mem.Allocator, axis: BoardHoleAxis, radius: f64) std.mem.Allocator.Error!PreparedRing {
    const axis_dx = axis.finish[0] - axis.start[0];
    const axis_dy = axis.finish[1] - axis.start[1];
    const axis_length = @sqrt(axis_dx * axis_dx + axis_dy * axis_dy);
    if (axis_length <= 1e-7) {
        const curves = try allocator.alloc(PreparedCurve, 1);
        const point = [2]f64{ axis.start[0] + radius, axis.start[1] };
        curves[0] = .{
            .start = point,
            .finish = point,
            .arc = .{
                .center = axis.start,
                .radius = radius,
                .start_angle = 0,
                .sweep = -std.math.tau,
            },
        };
        return .{ .curves = curves };
    }

    const ux = axis_dx / axis_length;
    const uy = axis_dy / axis_length;
    const nx = -uy;
    const ny = ux;
    const a = [2]f64{ axis.start[0] + radius * nx, axis.start[1] + radius * ny };
    const b = [2]f64{ axis.finish[0] + radius * nx, axis.finish[1] + radius * ny };
    const c = [2]f64{ axis.finish[0] - radius * nx, axis.finish[1] - radius * ny };
    const d = [2]f64{ axis.start[0] - radius * nx, axis.start[1] - radius * ny };
    const axis_angle = std.math.atan2(axis_dy, axis_dx);
    const curves = try allocator.alloc(PreparedCurve, 4);
    curves[0] = .{ .start = a, .finish = b };
    curves[1] = .{
        .start = b,
        .finish = c,
        .arc = .{
            .center = axis.finish,
            .radius = radius,
            .start_angle = axis_angle + std.math.pi / 2.0,
            .sweep = -std.math.pi,
        },
    };
    curves[2] = .{ .start = c, .finish = d };
    curves[3] = .{
        .start = d,
        .finish = a,
        .arc = .{
            .center = axis.start,
            .radius = radius,
            .start_angle = axis_angle - std.math.pi / 2.0,
            .sweep = -std.math.pi,
        },
    };
    return .{ .curves = curves };
}

fn prepareBoard(allocator: std.mem.Allocator, board: Board) (ExportError || std.mem.Allocator.Error)!PreparedBoard {
    if (board.name.len == 0 or board.name.len > 256) return error.InvalidGeometry;
    if (!std.math.isFinite(board.thickness)) return error.InvalidGeometry;
    if (!(board.thickness > 0.00001) or board.thickness > 10_000) return error.InvalidGeometry;
    if (board.outline.len < 3 or board.outline.len > max_board_outline_points + 1 or board.arcs.len > max_board_outline_arcs or board.holes.len > max_board_holes) return error.InvalidGeometry;
    if (board.color) |color| if (StyleState.colorKey(color) == null) return error.InvalidGeometry;

    var outline_len = board.outline.len;
    if (outline_len > 3 and pointDistanceSquared2(board.outline[0], board.outline[outline_len - 1]) <= 1e-18) outline_len -= 1;
    if (outline_len < 3 or outline_len > max_board_outline_points) return error.InvalidGeometry;
    const outer = try allocator.alloc([2]f64, outline_len);
    @memcpy(outer, board.outline[0..outline_len]);
    for (outer, 0..) |point, i| {
        if (!finitePoint2(point) or pointDistanceSquared2(point, outer[(i + 1) % outer.len]) <= 1e-18) return error.InvalidGeometry;
    }
    const area = signedArea2(outer);
    if (!std.math.isFinite(area) or @abs(area) <= 1e-9) return error.InvalidGeometry;
    if (!simplePolygon2(outer)) return error.InvalidGeometry;
    // The top face uses a +Z plane. Its outer loop is counter-clockwise;
    // every inner loop is clockwise, giving one untriangulated planar cap.
    const reversed = area < 0;
    if (reversed) reversePoints2(outer);

    const rings = try allocator.alloc(PreparedRing, board.holes.len + 1);
    rings[0] = try prepareOuterRing(allocator, outer, board.arcs, reversed);
    for (board.holes, 0..) |hole, hole_index| {
        const axis = try validateBoardHole(board, outer, hole_index);
        rings[hole_index + 1] = try prepareBoardHoleRing(allocator, axis, hole.r);
    }
    return .{ .name = board.name, .rings = rings, .thickness = board.thickness, .color = board.color };
}

fn boardAssemblyOffset(board: PreparedBoard) [3]f64 {
    const outer = board.rings[0].curves;
    var min = [2]f64{ std.math.inf(f64), std.math.inf(f64) };
    var max = [2]f64{ -std.math.inf(f64), -std.math.inf(f64) };
    for (outer) |curve| {
        for ([2][2]f64{ curve.start, curve.finish }) |point| {
            min[0] = @min(min[0], point[0]);
            min[1] = @min(min[1], point[1]);
            max[0] = @max(max[0], point[0]);
            max[1] = @max(max[1], point[1]);
        }
        if (curve.arc) |arc| for ([4]f64{ 0, std.math.pi / 2.0, std.math.pi, 3.0 * std.math.pi / 2.0 }) |angle| {
            const point = [2]f64{ arc.center[0] + arc.radius * @cos(angle), arc.center[1] + arc.radius * @sin(angle) };
            if (arcProgress(arc, point) > @abs(arc.sweep) + 1e-12) continue;
            min[0] = @min(min[0], point[0]);
            min[1] = @min(min[1], point[1]);
            max[0] = @max(max[0], point[0]);
            max[1] = @max(max[1], point[1]);
        };
    }
    return .{ -(min[0] + max[0]) / 2, -(min[1] + max[1]) / 2, board.thickness / 2 };
}

fn translatedPoint(point: [3]f64, offset: [3]f64) ExportError![3]f64 {
    const translated = [3]f64{ point[0] + offset[0], point[1] + offset[1], point[2] + offset[2] };
    if (!finitePoint(translated)) return error.InvalidGeometry;
    return translated;
}

const BoardVertex = struct { point: u64, vertex: u64 };
const BoardRingTopology = struct {
    curves: []const PreparedCurve,
    top: []BoardVertex,
    bottom: []BoardVertex,
    top_edges: []u64,
    bottom_edges: []u64,
    vertical_edges: []u64,
};

fn takeId(next_id: *u64) u64 {
    const id = next_id.*;
    next_id.* += 1;
    return id;
}

fn writeCartesianPointEntity(w: *std.Io.Writer, next_id: *u64, point: [3]f64) std.Io.Writer.Error!u64 {
    const id = takeId(next_id);
    try w.print("#{d}=CARTESIAN_POINT('',(", .{id});
    try writePoint(w, point);
    try w.writeAll("));\n");
    return id;
}

fn writeBoardVertex(w: *std.Io.Writer, next_id: *u64, point: [3]f64) std.Io.Writer.Error!BoardVertex {
    const point_id = try writeCartesianPointEntity(w, next_id, point);
    const vertex = takeId(next_id);
    try w.print("#{d}=VERTEX_POINT('',#{d});\n", .{ vertex, point_id });
    return .{ .point = point_id, .vertex = vertex };
}

fn writeLineEdge(
    w: *std.Io.Writer,
    next_id: *u64,
    start_point: u64,
    start_vertex: u64,
    end_vertex: u64,
    direction_value: [3]f64,
) (ExportError || std.Io.Writer.Error)!u64 {
    const direction = normalized(direction_value) orelse return error.InvalidGeometry;
    const direction_id = takeId(next_id);
    try writeDirection(w, direction_id, direction);
    const vector = takeId(next_id);
    try w.print("#{d}=VECTOR('',#{d},1.000000000);\n", .{ vector, direction_id });
    const line = takeId(next_id);
    try w.print("#{d}=LINE('',#{d},#{d});\n", .{ line, start_point, vector });
    const edge = takeId(next_id);
    try w.print("#{d}=EDGE_CURVE('',#{d},#{d},#{d},.T.);\n", .{ edge, start_vertex, end_vertex, line });
    return edge;
}

fn writeCircleEdge(
    w: *std.Io.Writer,
    next_id: *u64,
    curve: PreparedCurve,
    z: f64,
    start_vertex: u64,
    end_vertex: u64,
) (ExportError || std.Io.Writer.Error)!u64 {
    const arc = curve.arc orelse return error.InvalidGeometry;
    const radial = normalized(.{ curve.start[0] - arc.center[0], curve.start[1] - arc.center[1], 0 }) orelse return error.InvalidGeometry;
    const center = try writeCartesianPointEntity(w, next_id, .{ arc.center[0], arc.center[1], z });
    const reference = takeId(next_id);
    try writeDirection(w, reference, radial);
    const placement = takeId(next_id);
    try w.print("#{d}=AXIS2_PLACEMENT_3D('',#{d},#15,#{d});\n", .{ placement, center, reference });
    const circle = takeId(next_id);
    try w.print("#{d}=CIRCLE('',#{d},", .{ circle, placement });
    try stepReal(w, arc.radius);
    try w.writeAll(");\n");
    const edge = takeId(next_id);
    try w.print("#{d}=EDGE_CURVE('',#{d},#{d},#{d},{s});\n", .{ edge, start_vertex, end_vertex, circle, if (arc.sweep > 0) ".T." else ".F." });
    return edge;
}

fn writeRingTopology(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    next_id: *u64,
    ring: PreparedRing,
    thickness: f64,
) (ExportError || std.mem.Allocator.Error || std.Io.Writer.Error)!BoardRingTopology {
    const top = try allocator.alloc(BoardVertex, ring.curves.len);
    const bottom = try allocator.alloc(BoardVertex, ring.curves.len);
    for (ring.curves, 0..) |curve, i| {
        const point = curve.start;
        top[i] = try writeBoardVertex(w, next_id, .{ point[0], point[1], 0 });
        bottom[i] = try writeBoardVertex(w, next_id, .{ point[0], point[1], -thickness });
    }
    const top_edges = try allocator.alloc(u64, ring.curves.len);
    const bottom_edges = try allocator.alloc(u64, ring.curves.len);
    const vertical_edges = try allocator.alloc(u64, ring.curves.len);
    for (ring.curves, 0..) |curve, i| {
        const after = (i + 1) % ring.curves.len;
        if (curve.arc != null) {
            top_edges[i] = try writeCircleEdge(w, next_id, curve, 0, top[i].vertex, top[after].vertex);
            bottom_edges[i] = try writeCircleEdge(w, next_id, curve, -thickness, bottom[i].vertex, bottom[after].vertex);
        } else {
            const edge_direction = [3]f64{ curve.finish[0] - curve.start[0], curve.finish[1] - curve.start[1], 0 };
            top_edges[i] = try writeLineEdge(w, next_id, top[i].point, top[i].vertex, top[after].vertex, edge_direction);
            bottom_edges[i] = try writeLineEdge(w, next_id, bottom[i].point, bottom[i].vertex, bottom[after].vertex, edge_direction);
        }
        vertical_edges[i] = try writeLineEdge(w, next_id, top[i].point, top[i].vertex, bottom[i].vertex, .{ 0, 0, -1 });
    }
    return .{
        .curves = ring.curves,
        .top = top,
        .bottom = bottom,
        .top_edges = top_edges,
        .bottom_edges = bottom_edges,
        .vertical_edges = vertical_edges,
    };
}

fn writeOrientedEdge(w: *std.Io.Writer, next_id: *u64, edge: u64, forward: bool) std.Io.Writer.Error!u64 {
    const id = takeId(next_id);
    try w.print("#{d}=ORIENTED_EDGE('',*,*,#{d},{s});\n", .{ id, edge, if (forward) ".T." else ".F." });
    return id;
}

fn writeRingLoop(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    next_id: *u64,
    edges: []const u64,
    forward: bool,
) (std.mem.Allocator.Error || std.Io.Writer.Error)!u64 {
    const oriented = try allocator.alloc(u64, edges.len);
    for (oriented, 0..) |*id, i| {
        const edge_index = if (forward) i else edges.len - 1 - i;
        id.* = try writeOrientedEdge(w, next_id, edges[edge_index], forward);
    }
    const loop = takeId(next_id);
    try w.print("#{d}=EDGE_LOOP('',(", .{loop});
    for (oriented, 0..) |edge, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("#{d}", .{edge});
    }
    try w.writeAll("));\n");
    return loop;
}

fn writePlanarCap(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    next_id: *u64,
    rings: []const BoardRingTopology,
    top: bool,
) (std.mem.Allocator.Error || std.Io.Writer.Error)!u64 {
    const bounds = try allocator.alloc(u64, rings.len);
    for (rings, 0..) |ring, ring_index| {
        const loop = try writeRingLoop(allocator, w, next_id, if (top) ring.top_edges else ring.bottom_edges, top);
        bounds[ring_index] = takeId(next_id);
        if (ring_index == 0) {
            try w.print("#{d}=FACE_OUTER_BOUND('',#{d},.T.);\n", .{ bounds[ring_index], loop });
        } else {
            try w.print("#{d}=FACE_BOUND('',#{d},.T.);\n", .{ bounds[ring_index], loop });
        }
    }
    const placement = takeId(next_id);
    const anchor = if (top) rings[0].top[0].point else rings[0].bottom[0].point;
    try w.print("#{d}=AXIS2_PLACEMENT_3D('',#{d},#15,#16);\n", .{ placement, anchor });
    const plane = takeId(next_id);
    try w.print("#{d}=PLANE('',#{d});\n", .{ plane, placement });
    const face = takeId(next_id);
    try w.print("#{d}=ADVANCED_FACE('',(", .{face});
    for (bounds, 0..) |bound, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("#{d}", .{bound});
    }
    try w.print("),#{d},{s});\n", .{ plane, if (top) ".T." else ".F." });
    return face;
}

fn writeBoardSideFace(
    w: *std.Io.Writer,
    next_id: *u64,
    ring: BoardRingTopology,
    edge_index: usize,
) (ExportError || std.Io.Writer.Error)!u64 {
    const after = (edge_index + 1) % ring.curves.len;
    // Reversing the top edge makes every shared shell edge oppose its cap use:
    // top(j->i), down(i), bottom(i->j), up(j).
    const oriented = [4]u64{
        try writeOrientedEdge(w, next_id, ring.top_edges[edge_index], false),
        try writeOrientedEdge(w, next_id, ring.vertical_edges[edge_index], true),
        try writeOrientedEdge(w, next_id, ring.bottom_edges[edge_index], true),
        try writeOrientedEdge(w, next_id, ring.vertical_edges[after], false),
    };
    const loop = takeId(next_id);
    try w.print("#{d}=EDGE_LOOP('',(#{d},#{d},#{d},#{d}));\n", .{ loop, oriented[0], oriented[1], oriented[2], oriented[3] });
    const bound = takeId(next_id);
    try w.print("#{d}=FACE_OUTER_BOUND('',#{d},.T.);\n", .{ bound, loop });

    const curve = ring.curves[edge_index];
    var surface: u64 = undefined;
    var same_sense = true;
    if (curve.arc) |arc| {
        const radial = normalized(.{ curve.start[0] - arc.center[0], curve.start[1] - arc.center[1], 0 }) orelse return error.InvalidGeometry;
        const center = try writeCartesianPointEntity(w, next_id, .{ arc.center[0], arc.center[1], 0 });
        const reference = takeId(next_id);
        try writeDirection(w, reference, radial);
        const placement = takeId(next_id);
        try w.print("#{d}=AXIS2_PLACEMENT_3D('',#{d},#15,#{d});\n", .{ placement, center, reference });
        surface = takeId(next_id);
        try w.print("#{d}=CYLINDRICAL_SURFACE('',#{d},", .{ surface, placement });
        try stepReal(w, arc.radius);
        try w.writeAll(");\n");
        // With a CCW outer ring, a positive circular sweep has the cylinder's
        // natural radial normal on the material exterior. A negative (concave)
        // sweep needs the inverse face sense. Clockwise hole rings follow the
        // same material-on-the-left boundary convention.
        same_sense = arc.sweep > 0;
    } else {
        const dx = curve.finish[0] - curve.start[0];
        const dy = curve.finish[1] - curve.start[1];
        const length = @sqrt(dx * dx + dy * dy);
        if (!(length > 1e-12)) return error.InvalidGeometry;
        const normal_id = takeId(next_id);
        try writeDirection(w, normal_id, .{ dy / length, -dx / length, 0 });
        const reference_id = takeId(next_id);
        try writeDirection(w, reference_id, .{ -dx / length, -dy / length, 0 });
        const placement = takeId(next_id);
        try w.print("#{d}=AXIS2_PLACEMENT_3D('',#{d},#{d},#{d});\n", .{ placement, ring.top[after].point, normal_id, reference_id });
        surface = takeId(next_id);
        try w.print("#{d}=PLANE('',#{d});\n", .{ surface, placement });
    }
    const face = takeId(next_id);
    try w.print("#{d}=ADVANCED_FACE('',(#{d}),#{d},{s});\n", .{ face, bound, surface, if (same_sense) ".T." else ".F." });
    return face;
}

fn writeAnalyticBoard(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    next_id: *u64,
    board: Board,
    styles: *StyleState,
) (ExportError || std.mem.Allocator.Error || std.Io.Writer.Error)!BoardProduct {
    const prepared = try prepareBoard(allocator, board);
    const topology = try allocator.alloc(BoardRingTopology, prepared.rings.len);
    var side_count: usize = 0;
    for (prepared.rings, 0..) |ring, i| {
        topology[i] = try writeRingTopology(allocator, w, next_id, ring, prepared.thickness);
        side_count += ring.curves.len;
    }
    const faces = try allocator.alloc(u64, side_count + 2);
    faces[0] = try writePlanarCap(allocator, w, next_id, topology, true);
    faces[1] = try writePlanarCap(allocator, w, next_id, topology, false);
    var face_index: usize = 2;
    for (topology) |ring| for (ring.curves, 0..) |_, edge_index| {
        faces[face_index] = try writeBoardSideFace(w, next_id, ring, edge_index);
        face_index += 1;
    };

    const shell = takeId(next_id);
    try w.print("#{d}=CLOSED_SHELL(", .{shell});
    try stepText(w, prepared.name);
    try w.writeAll(",(");
    for (faces, 0..) |face, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("#{d}", .{face});
    }
    try w.writeAll("));\n");
    const solid = takeId(next_id);
    try w.print("#{d}=MANIFOLD_SOLID_BREP(", .{solid});
    try stepText(w, prepared.name);
    try w.print(",#{d});\n", .{shell});
    try styles.item(allocator, w, next_id, solid, prepared.color);

    const product = takeId(next_id);
    try w.print("#{d}=PRODUCT(", .{product});
    try stepText(w, prepared.name);
    try w.writeByte(',');
    try stepText(w, prepared.name);
    try w.writeAll(",'',(#3));\n");
    const formation = takeId(next_id);
    try w.print("#{d}=PRODUCT_DEFINITION_FORMATION('','',#{d});\n", .{ formation, product });
    const definition = takeId(next_id);
    try w.print("#{d}=PRODUCT_DEFINITION('design','',#{d},#6);\n", .{ definition, formation });
    const definition_shape = takeId(next_id);
    try w.print("#{d}=PRODUCT_DEFINITION_SHAPE('','',#{d});\n", .{ definition_shape, definition });
    const representation = takeId(next_id);
    try w.print("#{d}=ADVANCED_BREP_SHAPE_REPRESENTATION(", .{representation});
    try stepText(w, prepared.name);
    try w.print(",(#17,#{d}),#13);\n", .{solid});
    const definition_representation = takeId(next_id);
    try w.print("#{d}=SHAPE_DEFINITION_REPRESENTATION(#{d},#{d});\n", .{ definition_representation, definition_shape, representation });
    return .{
        .name = prepared.name,
        .product_definition = definition,
        .representation = representation,
        .assembly_offset = boardAssemblyOffset(prepared),
    };
}

const FacetedBodyWriteCtx = struct {
    allocator: std.mem.Allocator,
    assembly_offset: [3]f64,
};

fn writeFacetedBodies(w: *std.Io.Writer, bodies: []const Body, next_id: *u64, root_items: *std.ArrayList(u64), styles: *StyleState, ctx: FacetedBodyWriteCtx) (ExportError || std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    for (bodies) |body| {
        if (body.surface) continue;
        const minimum_points: usize = 4;
        const minimum_triangles: usize = 4;
        if (body.name.len == 0 or body.name.len > 256) return error.InvalidGeometry;
        if (body.points.len < minimum_points or body.points.len > max_points_per_body) return error.InvalidGeometry;
        if (body.triangles.len < minimum_triangles or body.triangles.len > max_triangles_per_body) return error.InvalidGeometry;
        const point_ids = try ctx.allocator.alloc(u64, body.points.len);
        for (body.points, 0..) |point, i| {
            if (!finitePoint(point)) return error.InvalidGeometry;
            point_ids[i] = next_id.*;
            next_id.* += 1;
            try w.print("#{d}=CARTESIAN_POINT('',(", .{point_ids[i]});
            try writePoint(w, try translatedPoint(point, ctx.assembly_offset));
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
            try styles.item(ctx.allocator, w, next_id, face, triangle_color);
            try face_ids.append(ctx.allocator, face);
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
        try root_items.append(ctx.allocator, brep);
        try styles.item(ctx.allocator, w, next_id, brep, body.color);
    }
}

fn build(allocator: std.mem.Allocator, project_dir: []const u8, design_name: []const u8, request: Request) (ExportError || std.mem.Allocator.Error || std.Io.Writer.Error)![]const u8 {
    if (request.bodies.len > max_bodies or request.instances.len > max_instances) return error.BadRequest;
    var has_faceted_body = false;
    for (request.bodies) |body| if (!body.surface) {
        has_faceted_body = true;
        break;
    };
    if (request.board == null and !has_faceted_body) return error.BadRequest;

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
        "FILE_DESCRIPTION(('Netlisp exact PCB assembly'),'2;1');\n" ++
        "FILE_NAME('netlisp-pcb.step','',('Netlisp'),('Netlisp'),'Netlisp','','');\n" ++
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
    const board_product = if (request.board) |board|
        try writeAnalyticBoard(allocator, w, &next_id, board, &styles)
    else
        null;
    const assembly_offset = if (board_product) |board| board.assembly_offset else [3]f64{ 0, 0, 0 };
    try writeFacetedBodies(w, request.bodies, &next_id, &root_items, &styles, .{
        .allocator = allocator,
        .assembly_offset = assembly_offset,
    });

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

    if (board_product) |board| {
        const point = next_id;
        const z_direction = point + 1;
        const x_direction = point + 2;
        const placement = point + 3;
        next_id += 4;
        try w.print("#{d}=CARTESIAN_POINT('',(", .{point});
        try writePoint(w, board.assembly_offset);
        try w.writeAll("));\n");
        try writeDirection(w, z_direction, .{ 0, 0, 1 });
        try writeDirection(w, x_direction, .{ 1, 0, 0 });
        try w.print("#{d}=AXIS2_PLACEMENT_3D('',#{d},#{d},#{d});\n", .{ placement, point, z_direction, x_direction });
        const nauo = next_id;
        const occurrence_shape = nauo + 1;
        const transform = nauo + 2;
        const relationship = nauo + 3;
        const dependent = nauo + 4;
        next_id += 5;
        try w.print("#{d}=NEXT_ASSEMBLY_USAGE_OCCURRENCE(", .{nauo});
        try stepText(w, board.name);
        try w.writeByte(',');
        try stepText(w, board.name);
        try w.print(",'',#7,#{d},$);\n", .{board.product_definition});
        try w.print("#{d}=PRODUCT_DEFINITION_SHAPE('','',#{d});\n", .{ occurrence_shape, nauo });
        try w.print("#{d}=ITEM_DEFINED_TRANSFORMATION('','',#17,#{d});\n", .{ transform, placement });
        try w.print("#{d}=(REPRESENTATION_RELATIONSHIP('',", .{relationship});
        try stepText(w, board.name);
        try w.print(",#{d},#{d})REPRESENTATION_RELATIONSHIP_WITH_TRANSFORMATION(#{d})SHAPE_REPRESENTATION_RELATIONSHIP());\n", .{ board.representation, root_representation, transform });
        try w.print("#{d}=CONTEXT_DEPENDENT_SHAPE_REPRESENTATION(#{d},#{d});\n", .{ dependent, relationship, occurrence_shape });
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
        try writePoint(w, try translatedPoint(axes.origin, assembly_offset));
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

/// Validate the browser's compact board/assembly recipe and compose the same
/// exact AP242 bytes returned by `/api/pcb-step`. The complete-design archive
/// uses this seam so its full-board model cannot drift from the 3D tab's STEP
/// download.
pub fn buildFromJson(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    design_name: []const u8,
    body: []const u8,
) (ExportError || std.mem.Allocator.Error || std.Io.Writer.Error)![]const u8 {
    if (!safeDesignName(design_name) or body.len == 0 or body.len > max_request_bytes) return error.BadRequest;
    const request = std.json.parseFromSliceLeaky(Request, allocator, body, .{ .ignore_unknown_fields = true }) catch
        return error.BadRequest;
    return build(allocator, project_dir, design_name, request);
}

/// Compose already-validated, locally generated solid meshes into one AP242
/// file. No project assets are consulted unless component instances are added
/// through the browser-oriented path above.
pub fn buildBodies(
    allocator: std.mem.Allocator,
    design_name: []const u8,
    bodies: []const Body,
) (ExportError || std.mem.Allocator.Error || std.Io.Writer.Error)![]const u8 {
    if (!safeDesignName(design_name)) return error.BadRequest;
    return build(allocator, ".", design_name, .{ .bodies = bodies });
}

fn sendError(res: *httpz.Response, status: u16, message: []const u8) void {
    res.status = status;
    res.content_type = .TEXT;
    res.body = message;
}

/// POST /api/pcb-step/:name — compose exact source STEP B-reps with the
/// analytic board and optional generated heatsink solids, returning one
/// self-contained AP242 file. Raster preview artwork is intentionally omitted
/// from STEP rather than approximated with selectable triangle geometry.
pub fn pcbStepApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse return sendError(res, 404, "design not found");
    if (!safeDesignName(name)) return sendError(res, 400, "invalid design name");
    const body = req.body() orelse return sendError(res, 400, "missing export body");
    if (body.len > max_request_bytes) return sendError(res, 413, "STEP export request is too large");
    const output = buildFromJson(req.arena, ctx.project_dir, name, body) catch |err| switch (err) {
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

// spec: Web Server - the PCB STEP assembly places its origin at the PCB outline bounding-box centre in X/Y and the board thickness mid-plane in Z, translating component occurrences and generated solids by the same offset
test "exact assembly embeds one source B-rep and centers board-backed geometry" {
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

    var board_part = identity;
    board_part[12] = 25;
    board_part[13] = 9;
    const centered = try build(aa, project_dir, "centered-fixture", .{
        .board = .{
            .name = "PCB solid",
            .outline = &.{ .{ 10, 4 }, .{ 30, 4 }, .{ 30, 14 }, .{ 10, 14 } },
            .thickness = 2,
        },
        .bodies = &.{.{
            .name = "Heatsink",
            .points = &.{ .{ 20, 9, 0 }, .{ 22, 9, 0 }, .{ 20, 11, 0 }, .{ 20, 9, 3 } },
            .triangles = &.{ .{ 0, 2, 1 }, .{ 0, 1, 3 }, .{ 1, 2, 3 }, .{ 2, 0, 3 } },
        }},
        .instances = &.{.{ .name = "J1", .footprint = "demo", .matrix = board_part }},
    });
    // The complete board spans X=-10..10, Y=-5..5 and Z=-1..1. The
    // component and generated body receive the exact same assembly offset.
    try std.testing.expect(std.mem.indexOf(u8, centered, "CARTESIAN_POINT('',(-20.000000000,-9.000000000,1.000000000))") != null);
    try std.testing.expect(std.mem.indexOf(u8, centered, "CARTESIAN_POINT('',(5.000000000,0.000000000,1.000000000))") != null);
    try std.testing.expect(std.mem.indexOf(u8, centered, "CARTESIAN_POINT('',(2.000000000,0.000000000,1.000000000))") != null);
}

test "PCB recipe exports one analytic manifold solid and ignores legacy artwork triangles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const colors = [_]?[3]f64{ .{ 0.78, 0.57, 0.24 }, .{ 0.78, 0.57, 0.24 } };
    const output = try build(arena.allocator(), ".", "fixture", .{
        .board = .{
            .name = "PCB solid",
            // Repeated endpoint is accepted and stripped before topology is built.
            .outline = &.{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 10 }, .{ 0, 10 }, .{ 0, 0 } },
            .holes = &.{
                .{ .x = 5, .y = 5, .r = 1 },
                .{ .x = 11, .y = 5, .x2 = 14, .y2 = 5, .r = 0.75 },
            },
            .thickness = 1.6,
            .color = .{ 0.047, 0.404, 0.204 },
        },
        .bodies = &.{.{
            .name = "PCB top artwork wrap",
            .points = &.{ .{ 1, 1, 0.002 }, .{ 5, 1, 0.002 }, .{ 5, 2, 0.002 }, .{ 1, 2, 0.002 } },
            .triangles = &.{ .{ 0, 2, 1 }, .{ 0, 3, 2 } },
            .triangleColors = &colors,
            .surface = true,
        }},
    });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "MANIFOLD_SOLID_BREP("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "ADVANCED_BREP_SHAPE_REPRESENTATION("));
    // Four outer walls, one true cylindrical drill wall and four routed-slot
    // walls, plus the two planar caps. No hole perimeter is faceted.
    try std.testing.expectEqual(@as(usize, 11), std.mem.count(u8, output, "ADVANCED_FACE("));
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, output, "=CIRCLE('',"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, output, "=CYLINDRICAL_SURFACE('',"));
    try std.testing.expectEqual(@as(usize, 8), std.mem.count(u8, output, "=PLANE('',"));
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, output, "FACE_BOUND("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "NEXT_ASSEMBLY_USAGE_OCCURRENCE("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, output, "FACETED_BREP("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, output, "FACE_SURFACE("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, output, "POLY_LOOP("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, output, "OPEN_SHELL("));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, output, "SHELL_BASED_SURFACE_MODEL("));
    try std.testing.expect(std.mem.indexOf(u8, output, "COLOUR_RGB('',0.047000000,0.404000000,0.204000000)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "COLOUR_RGB('',0.780000000,0.570000000,0.240000000)") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PCB top artwork wrap") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "CARTESIAN_POINT('',(0.000000000,0.000000000,-1.600000000))") != null);
}

test "PCB outline fillet exports native circular edges and a cylindrical side face" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Clockwise input mirrors the browser's Y-flipped board frame. The server
    // normalizes it to a CCW outer wire without losing the three-point arc.
    const output = try build(arena.allocator(), ".", "rounded-fixture", .{ .board = .{
        .name = "PCB solid",
        .outline = &.{
            .{ 0, 10 },                    .{ 10, 10 }, .{ 10, 2 },
            .{ 9.414213562, 0.585786438 }, .{ 8, 0 },   .{ 0, 0 },
        },
        .arcs = &.{.{
            .p1 = .{ 10, 2 },
            .pm = .{ 9.414213562, 0.585786438 },
            .p2 = .{ 8, 0 },
        }},
        .thickness = 1.6,
    } });
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output, "=CIRCLE('',"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "=CYLINDRICAL_SURFACE('',"));
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, output, "=PLANE('',"));
    try std.testing.expectEqual(@as(usize, 7), std.mem.count(u8, output, "=ADVANCED_FACE('',"));
    try std.testing.expectEqual(@as(usize, 15), std.mem.count(u8, output, "=EDGE_CURVE('',"));
}

test "analytic PCB validation rejects self intersections and invalid mechanical holes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const rectangle = [_][2]f64{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 10 }, .{ 0, 10 } };
    try std.testing.expectError(error.InvalidGeometry, prepareBoard(aa, .{
        .outline = &.{ .{ 0, 0 }, .{ 10, 10 }, .{ 0, 10 }, .{ 10, 0 } },
        .thickness = 1.6,
    }));
    try std.testing.expectError(error.InvalidGeometry, prepareBoard(aa, .{
        .outline = &rectangle,
        .holes = &.{.{ .x = 0.5, .y = 5, .r = 1 }},
        .thickness = 1.6,
    }));
    try std.testing.expectError(error.InvalidGeometry, prepareBoard(aa, .{
        .outline = &rectangle,
        .holes = &.{
            .{ .x = 5, .y = 5, .r = 2 },
            .{ .x = 7, .y = 5, .r = 1 },
        },
        .thickness = 1.6,
    }));
    try std.testing.expectError(error.InvalidGeometry, prepareBoard(aa, .{
        .outline = &rectangle,
        .holes = &.{.{ .x = 5, .y = 5, .x2 = 8, .r = 0.5 }},
        .thickness = 1.6,
    }));
    try std.testing.expectError(error.InvalidGeometry, prepareBoard(aa, .{
        .outline = &rectangle,
        // An arc cannot claim a hidden chord whose endpoints are absent from
        // the validated fallback contour.
        .arcs = &.{.{ .p1 = .{ 5, 0 }, .pm = .{ 6, 1 }, .p2 = .{ 7, 0 } }},
        .thickness = 1.6,
    }));
}
