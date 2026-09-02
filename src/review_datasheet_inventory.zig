//! Exact fitted-part datasheet coverage for agent board reviews.
//!
//! The generated `.bom` is the authority because parameterised passive
//! families resolve to an exact manufacturer and MPN there. Component-level
//! declarations fill the fixed-part case. The result tells an agent which PDF
//! it can read now and which acquisition tool it must call before disposition.

const std = @import("std");
const bom = @import("bom.zig");
const infra_fs = @import("infra/fs.zig");
const json_writer = @import("json_writer.zig");
const paths = @import("paths.zig");

const max_component_bytes: usize = 1024 * 1024;

/// Whether the exact fitted part has readable local evidence.
pub const Status = enum { local, remote_only, missing, missing_mpn };

/// One unique fitted MPN/component and every ref-des that uses it.
pub const Row = struct {
    component: []const u8,
    manufacturer: []const u8,
    mpn: []const u8,
    datasheet: []const u8,
    status: Status,
    refs: []const []const u8,
};

/// Aggregate coverage counts emitted before the row list.
pub const Summary = struct {
    parts: usize = 0,
    local: usize = 0,
    remote_only: usize = 0,
    missing: usize = 0,
    missing_mpn: usize = 0,
};

const Builder = struct {
    component: []const u8,
    manufacturer: []const u8,
    mpn: []const u8,
    datasheet: []const u8,
    status: Status,
    refs: std.ArrayList([]const u8) = .empty,
};

fn property(properties: []const @import("eval/env.zig").Property, key: []const u8) []const u8 {
    for (properties) |candidate| if (std.ascii.eqlIgnoreCase(candidate.key, key)) return candidate.value;
    return "";
}

fn safeBasename(name: []const u8) bool {
    return name.len > 0 and name[0] != '.' and std.mem.indexOfAny(u8, name, "/\\") == null and
        std.mem.indexOf(u8, name, "..") == null;
}

fn componentDatasheet(allocator: std.mem.Allocator, project_dir: []const u8, component: []const u8) std.mem.Allocator.Error![]const u8 {
    if (!safeBasename(component)) return "";
    const path = try std.fmt.allocPrint(allocator, "{s}/lib/components/{s}.sexp", .{ project_dir, component });
    defer allocator.free(path);
    const bytes = infra_fs.cwd().readFileAlloc(allocator, path, max_component_bytes) catch return "";
    defer allocator.free(bytes);
    const marker = "(datasheet \"";
    var remaining = bytes;
    var first: []const u8 = "";
    while (std.mem.indexOf(u8, remaining, marker)) |start| {
        const value = remaining[start + marker.len ..];
        const end = std.mem.indexOfScalar(u8, value, '"') orelse break;
        const candidate = value[0..end];
        if (first.len == 0) first = try allocator.dupe(u8, candidate);
        if (try localPdfExists(allocator, project_dir, candidate)) return allocator.dupe(u8, candidate);
        remaining = value[end + 1 ..];
    }
    return first;
}

fn localPdfExists(allocator: std.mem.Allocator, project_dir: []const u8, reference: []const u8) std.mem.Allocator.Error!bool {
    if (!safeBasename(reference)) return false;
    const path = try std.fmt.allocPrint(allocator, "{s}/lib/datasheets/{s}", .{ project_dir, reference });
    defer allocator.free(path);
    infra_fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn classify(allocator: std.mem.Allocator, project_dir: []const u8, mpn: []const u8, reference: []const u8) std.mem.Allocator.Error!Status {
    if (mpn.len == 0) return .missing_mpn;
    if (safeBasename(mpn)) {
        const exact_name = try std.fmt.allocPrint(allocator, "{s}.pdf", .{mpn});
        defer allocator.free(exact_name);
        if (try localPdfExists(allocator, project_dir, exact_name)) return .local;
    }
    if (reference.len == 0) return .missing;
    const separator = std.mem.indexOf(u8, reference, "://");
    if (separator) |index| {
        const scheme = reference[0..index];
        if (std.ascii.eqlIgnoreCase(scheme, "http") or std.ascii.eqlIgnoreCase(scheme, "https")) return .remote_only;
    }
    return if (try localPdfExists(allocator, project_dir, reference)) .local else .missing;
}

fn stronger(left: Status, right: Status) Status {
    const rank = struct {
        fn of(status: Status) u8 {
            return switch (status) {
                .missing_mpn => 0,
                .missing => 1,
                .remote_only => 2,
                .local => 3,
            };
        }
    }.of;
    return if (rank(right) > rank(left)) right else left;
}

/// Errors exposed while collecting the generated BOM's datasheet inventory.
pub const CollectError = bom.BomError || error{InvalidName};

/// Inventory every unique exact MPN in the generated BOM and its PDF state.
pub fn collect(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) CollectError![]const Row {
    const bom_path = try paths.designSiblingPath(allocator, project_dir, name, ".bom");
    defer allocator.free(bom_path);
    const entries = try bom.loadBom(allocator, bom_path);
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    var builders: std.ArrayList(Builder) = .empty;

    for (entries) |entry| {
        if (std.mem.eql(u8, entry.component, "testpoint") or std.mem.startsWith(u8, entry.component, "fiducial")) continue;
        const manufacturer = property(entry.properties, "manufacturer");
        const mpn = property(entry.properties, "mpn");
        var reference = property(entry.properties, "datasheet");
        const component_reference = try componentDatasheet(allocator, project_dir, entry.component);
        if (component_reference.len > 0 and try localPdfExists(allocator, project_dir, component_reference)) {
            reference = component_reference;
        } else if (reference.len == 0) {
            reference = component_reference;
        }
        const status = try classify(allocator, project_dir, mpn, reference);
        const key = if (mpn.len > 0) mpn else entry.component;
        const found = try index.getOrPut(allocator, key);
        if (!found.found_existing) {
            found.value_ptr.* = builders.items.len;
            try builders.append(allocator, .{
                .component = entry.component,
                .manufacturer = manufacturer,
                .mpn = mpn,
                .datasheet = reference,
                .status = status,
            });
        } else {
            const row = &builders.items[found.value_ptr.*];
            const best = stronger(row.status, status);
            if (best != row.status) {
                row.status = best;
                row.datasheet = reference;
            }
        }
        try builders.items[found.value_ptr.*].refs.append(allocator, entry.ref_des);
    }

    const rows = try allocator.alloc(Row, builders.items.len);
    for (builders.items, 0..) |*builder, row_index| rows[row_index] = .{
        .component = builder.component,
        .manufacturer = builder.manufacturer,
        .mpn = builder.mpn,
        .datasheet = builder.datasheet,
        .status = builder.status,
        .refs = try builder.refs.toOwnedSlice(allocator),
    };
    return rows;
}

/// Count exact-part PDF coverage states.
pub fn summarize(rows: []const Row) Summary {
    var result: Summary = .{ .parts = rows.len };
    for (rows) |row| switch (row.status) {
        .local => result.local += 1,
        .remote_only => result.remote_only += 1,
        .missing => result.missing += 1,
        .missing_mpn => result.missing_mpn += 1,
    };
    return result;
}

fn action(status: Status) []const u8 {
    return switch (status) {
        .local => "read_datasheet",
        .remote_only => "fetch_datasheet, then read_datasheet",
        .missing => "download_datasheet; if unavailable, find the manufacturer PDF and fetch_datasheet; then read_datasheet",
        .missing_mpn => "identify the exact fitted MPN before datasheet review",
    };
}

/// Serialize coverage plus the mandatory next tool for every fitted part.
pub fn writeInventory(w: *std.Io.Writer, rows: []const Row) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    const summary = summarize(rows);
    try w.print("{{\"summary\":{{\"parts\":{d},\"local\":{d},\"remote_only\":{d},\"missing\":{d},\"missing_mpn\":{d}}},\"parts\":[", .{
        summary.parts, summary.local, summary.remote_only, summary.missing, summary.missing_mpn,
    });
    for (rows, 0..) |row, row_index| {
        if (row_index > 0) try w.writeByte(',');
        try w.writeAll("{\"component\":");
        try json_writer.writeString(w, row.component);
        try w.writeAll(",\"manufacturer\":");
        try json_writer.writeString(w, row.manufacturer);
        try w.writeAll(",\"mpn\":");
        try json_writer.writeString(w, row.mpn);
        try w.writeAll(",\"datasheet\":");
        try json_writer.writeString(w, row.datasheet);
        try w.writeAll(",\"status\":");
        try json_writer.writeString(w, @tagName(row.status));
        try w.writeAll(",\"next_action\":");
        try json_writer.writeString(w, action(row.status));
        try w.writeAll(",\"refs\":[");
        for (row.refs, 0..) |ref, ref_index| {
            if (ref_index > 0) try w.writeByte(',');
            try json_writer.writeString(w, ref);
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}");
}

// spec: serve/board-review - the agent queue inventories datasheet coverage by exact fitted BOM MPN and directs local reads, catalogue downloads, or manufacturer-URL fetches before component decisions
test "datasheet inventory follows exact BOM selections and names acquisition work" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.createDirPath(std.testing.io, "lib/datasheets");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.sexp", .data = "(design-block \"Demo\")" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.bom", .data =
        \\(part "U1" "a" "chip" (manufacturer "Acme") (mpn "X1"))
        \\(part "R1" "b" "res" (manufacturer "Ohms") (mpn "R1") (datasheet "https://example.com/R1.pdf"))
        \\(part "U2" "c" "other" (manufacturer "Acme") (mpn "X2"))
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/chip.sexp", .data = "(component \"chip\" (datasheet \"X1.pdf\"))" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/datasheets/X1.pdf", .data = "%PDF fixture" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/datasheets/R1.pdf", .data = "%PDF fetched fixture" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rows = try collect(arena_state.allocator(), root, "demo");
    const summary = summarize(rows);
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqual(@as(usize, 2), summary.local);
    try std.testing.expectEqual(@as(usize, 0), summary.remote_only);
    try std.testing.expectEqual(@as(usize, 1), summary.missing);
}
