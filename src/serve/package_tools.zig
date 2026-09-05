//! One operation surface for HTTP, structured tools, and the package CLI.
const std = @import("std");
const gen = @import("package_generator.zig");
const store = @import("package_store.zig");
const kicad = @import("../export_kicad_footprint.zig");

/// Transport-independent operation failures, including generation and persistence diagnostics.
pub const Error = store.Error || kicad.FootprintError || error{ MissingRecipe, UnknownFamily, MissingName, UnknownFormat, UnknownOperation };
pub const Operation = enum { templates, init, show, preview, check, save, export_asset };
fn string(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}
fn recipe(a: std.mem.Allocator, args: std.json.Value) !gen.Recipe {
    if (args != .object) return error.MissingRecipe;
    const value = args.object.get("recipe") orelse return error.MissingRecipe;
    return gen.parse(a, try std.json.Stringify.valueAlloc(a, value, .{}));
}
fn json(a: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, value, .{ .whitespace = .indent_2 });
}

/// Run an operation without transport-specific behavior; callers supply a request arena.
pub fn execute(a: std.mem.Allocator, project: []const u8, operation: Operation, args: std.json.Value) Error![]const u8 {
    switch (operation) {
        .templates => {
            var list: std.ArrayList(gen.Recipe) = .empty;
            inline for (std.meta.tags(gen.Family)) |family| try list.append(a, gen.template(family));
            return json(a, .{ .ok = true, .units = "mm", .templates = list.items, .description = "Body height includes standoff. Lead span is outside-to-outside. Land span is pad-center to pad-center. Review all example dimensions before saving." });
        },
        .init => {
            const family = std.meta.stringToEnum(gen.Family, string(args, "family") orelse "qfn") orelse return error.UnknownFamily;
            var r = gen.template(family);
            if (string(args, "name")) |name| r.name = name;
            return json(a, r);
        },
        .show => return json(a, try store.load(a, project, string(args, "name") orelse return error.MissingName)),
        .preview, .check => {
            const r = try recipe(a, args);
            const result = try gen.generate(a, r);
            if (operation == .check) return json(a, .{ .ok = !gen.hasErrors(result.diagnostics), .diagnostics = result.diagnostics, .dimensions_verified = r.dimensions_verified, .recipe = r });
            return json(a, .{ .ok = !gen.hasErrors(result.diagnostics), .diagnostics = result.diagnostics, .pads = result.pads, .svg = result.svg, .step = result.step, .footprint = result.footprint, .geometry = if (result.footprint.len > 0) try std.json.parseFromSliceLeaky(std.json.Value, a, try @import("footprint_preview.zig").describeSource(a, result.footprint), .{}) else std.json.Value.null });
        },
        .save => {
            const r = try recipe(a, args);
            const result = try gen.generate(a, r);
            if (gen.hasErrors(result.diagnostics)) return json(a, .{ .ok = false, .diagnostics = result.diagnostics });
            const saved = try store.saveAttached(a, project, r, string(args, "component"));
            return json(a, .{ .ok = true, .recipe = saved, .files = try store.paths(a, project, saved.name) });
        },
        .export_asset => {
            const r = try store.load(a, project, string(args, "name") orelse return error.MissingName);
            const result = try gen.generate(a, r);
            if (gen.hasErrors(result.diagnostics)) return error.InvalidPackage;
            const format = string(args, "format") orelse "step";
            if (std.mem.eql(u8, format, "step")) return json(a, .{ .ok = true, .content = result.step, .extension = "step" });
            if (!std.mem.eql(u8, format, "kicad")) return error.UnknownFormat;
            const model_name = try std.fmt.allocPrint(a, "{s}.step", .{r.name});
            return json(a, .{ .ok = true, .content = try kicad.exportFootprintMod(a, result.footprint, model_name, null, null), .extension = "kicad_mod" });
        },
    }
}

/// Map catalog names to the shared operation enum.
pub fn operationFor(name: []const u8) ?Operation {
    if (!std.mem.startsWith(u8, name, "package_")) return null;
    const suffix = name[8..];
    if (std.mem.eql(u8, suffix, "export")) return .export_asset;
    return std.meta.stringToEnum(Operation, suffix);
}

/// Dispatch a known package tool and emit structured errors on failure.
pub fn dispatch(a: std.mem.Allocator, project: []const u8, name: []const u8, args: ?std.json.Value, out: *std.ArrayList(u8)) Error!bool {
    const operation = operationFor(name) orelse return error.UnknownOperation;
    const value = args orelse std.json.Value{ .object = .empty };
    const bytes = execute(a, project, operation, value) catch |err| {
        try out.appendSlice(a, try json(a, .{ .ok = false, .error_code = @errorName(err), .error_message = message(err) }));
        return false;
    };
    try out.appendSlice(a, bytes);
    const result = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    if (result == .object) if (result.object.get("ok")) |ok| if (ok == .bool) return ok.bool;
    return true;
}

/// Actionable error text shared by terminal and browser callers.
pub fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.RevisionConflict, error.RevisionRequired => "Package changed on disk. Load it again before saving; keep your current recipe to reconcile the changes.",
        error.GeneratedAssetChanged => "Generated footprint or STEP changed outside the builder. Save under a new name or restore the generated asset before regenerating.",
        error.PinoutMismatch => "Component pinout and package pad numbers do not match. Check exposed-pad numbering and pin count before assigning.",
        error.NameAlreadyExists => "That footprint or model already exists. Choose a new package name.",
        error.DimensionsNotVerified => "Review the body, terminal, and land dimensions, then mark dimensions verified before saving.",
        error.RollbackFailed => "Saving failed and rollback was incomplete. Preserve the recipe and inspect the library files before retrying.",
        else => @errorName(err),
    };
}

// spec: IC package builder - Empty inputs and malformed encoding fail explicitly; stencil windows preserve absent versus intentionally empty paste
test "IC package structured operation errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const empty = try std.json.parseFromSliceLeaky(std.json.Value, a, "{}", .{});
    try std.testing.expectError(error.MissingRecipe, execute(a, ".", .preview, empty));
    try std.testing.expectError(error.MissingName, execute(a, ".", .show, empty));
    const bad = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"family\":\"bga\"}", .{});
    try std.testing.expectError(error.UnknownFamily, execute(a, ".", .init, bad));
    var out: std.ArrayList(u8) = .empty;
    try std.testing.expectError(error.UnknownOperation, dispatch(a, ".", "unknown", empty, &out));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var r = gen.template(.dfn);
    r.dimensions_verified = true;
    _ = try store.save(a, root, r);
    const bad_format = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"name\":\"new-package\",\"format\":\"obj\"}", .{});
    try std.testing.expectError(error.UnknownFormat, execute(a, root, .export_asset, bad_format));
}
