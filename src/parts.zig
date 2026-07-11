//! Parts database: a lazy on-disk index of `lib/parts/<family>.sexp` tables.
//! Resolves a parameterised component request (e.g. `cap-0402` + `"100nF"` +
//! `"x7r"`) into a concrete manufacturer part for the BOM, caching each family
//! after its first parse. Read-only lookup keyed by family + value + attrs.

const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const parser_mod = @import("sexpr/parser.zig");
const env_mod = @import("eval/env.zig");
const Property = env_mod.Property;

/// One row in a `lib/parts/<family>.sexp` table: the value string a design
/// would request (e.g. `"100nF"`), the manufacturer/MPN to ship in the
/// BOM, any extra `(key "val")` attributes used to disambiguate variants
/// (dielectric, tolerance, …), and a `preferred` flag for tie-breaking.
pub const PartEntry = struct {
    value: []const u8,
    manufacturer: []const u8,
    mpn: []const u8,
    attrs: []const Property,
    preferred: bool,
};

/// Lazy on-disk index of `lib/parts/<family>.sexp` tables. Components ask
/// `lookup(family, value, attrs)` to resolve a parameterised request
/// (e.g. `cap-0402` + `"100nF"` + `"x7r"`) into a real manufacturer
/// part for the BOM; each family is parsed once and cached.
pub const PartsDb = struct {
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    /// family_name -> []PartEntry
    entries: std.StringHashMapUnmanaged([]const PartEntry),

    pub fn init(allocator: std.mem.Allocator, project_dir: []const u8) PartsDb {
        return .{
            .allocator = allocator,
            .project_dir = project_dir,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *PartsDb) void {
        self.entries.deinit(self.allocator);
    }

    /// Look up a part by family name, value, and optional attrs.
    /// Returns the best matching PartEntry, or null if no match.
    pub fn lookup(self: *PartsDb, family: []const u8, value: []const u8, attrs: []const []const u8) ?*const PartEntry {
        // Lazy-load the parts file for this family
        if (!self.entries.contains(family)) {
            self.loadFamily(family) catch return null;
        }

        const parts = self.entries.get(family) orelse return null;

        // Filter by value
        var value_matches: std.ArrayList(*const PartEntry) = .empty;
        defer value_matches.deinit(self.allocator);
        for (parts) |*entry| {
            if (std.mem.eql(u8, entry.value, value)) {
                value_matches.append(self.allocator, entry) catch continue;
            }
        }
        if (value_matches.items.len == 0) return null;

        // If attrs provided, try to narrow by matching part attrs
        if (attrs.len > 0) {
            var attr_matches: std.ArrayList(*const PartEntry) = .empty;
            defer attr_matches.deinit(self.allocator);
            for (value_matches.items) |entry| {
                if (attrsMatch(entry.attrs, attrs)) {
                    attr_matches.append(self.allocator, entry) catch continue;
                }
            }
            // Use attr-filtered results if any matched; otherwise fall back to all value matches
            if (attr_matches.items.len > 0) {
                return pickPreferred(attr_matches.items);
            }
        }

        return pickPreferred(value_matches.items);
    }

    fn pickPreferred(candidates: []*const PartEntry) ?*const PartEntry {
        if (candidates.len == 0) return null;
        for (candidates) |entry| {
            if (entry.preferred) return entry;
        }
        return candidates[0];
    }

    /// Check if a part's attrs contain all the instance attrs.
    fn attrsMatch(part_attrs: []const Property, instance_attrs: []const []const u8) bool {
        // Each instance attr (e.g. "x7r") must appear as a value in part_attrs
        for (instance_attrs) |attr| {
            var found = false;
            for (part_attrs) |pa| {
                if (std.mem.eql(u8, pa.value, attr)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }

    fn loadFamily(self: *PartsDb, family: []const u8) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/lib/parts/{s}.sexp", .{ self.project_dir, family });
        defer self.allocator.free(path);

        const source = infra_fs.cwd().readFileAlloc(self.allocator, path, 1 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => {
                // Cache empty so we don't retry
                try self.entries.put(self.allocator, try self.allocator.dupe(u8, family), &.{});
                return;
            },
            else => return err,
        };
        defer self.allocator.free(source);

        const nodes = try parser_mod.parse(self.allocator, source);
        defer parser_mod.freeNodes(self.allocator, nodes);

        var parts: std.ArrayList(PartEntry) = .empty;

        for (nodes) |node| {
            if (!node.isForm("parts")) continue;
            const children = node.asList() orelse continue;

            // (parts "family-name" (part ...) (part ...) ...)
            for (children[1..]) |child| {
                if (!child.isForm("part")) continue;
                const part_children = child.asList() orelse continue;
                if (part_children.len < 2) continue;

                const value = part_children[1].asString() orelse continue;

                var manufacturer: []const u8 = "";
                var mpn: []const u8 = "";
                var preferred = false;
                var attrs: std.ArrayList(Property) = .empty;

                for (part_children[2..]) |prop| {
                    if (prop.isForm("manufacturer")) {
                        const pc = prop.asList() orelse continue;
                        if (pc.len >= 2) manufacturer = try self.allocator.dupe(u8, pc[1].asString() orelse continue);
                    } else if (prop.isForm("mpn")) {
                        const pc = prop.asList() orelse continue;
                        if (pc.len >= 2) mpn = try self.allocator.dupe(u8, pc[1].asString() orelse continue);
                    } else if (prop.asAtom()) |a| {
                        if (std.mem.eql(u8, a, "preferred")) preferred = true;
                    } else if (prop.asList()) |pc| {
                        // Generic attr like (dielectric "x7r")
                        if (pc.len >= 2) {
                            const key = pc[0].asAtom() orelse continue;
                            const val = pc[1].asString() orelse continue;
                            if (!std.mem.eql(u8, key, "manufacturer") and !std.mem.eql(u8, key, "mpn")) {
                                try attrs.append(self.allocator, .{
                                    .key = try self.allocator.dupe(u8, key),
                                    .value = try self.allocator.dupe(u8, val),
                                });
                            }
                        }
                    }
                }

                try parts.append(self.allocator, .{
                    .value = try self.allocator.dupe(u8, value),
                    .manufacturer = manufacturer,
                    .mpn = mpn,
                    .attrs = attrs.toOwnedSlice(self.allocator) catch &.{},
                    .preferred = preferred,
                });
            }
        }

        const family_key = try self.allocator.dupe(u8, family);
        const owned_parts = parts.toOwnedSlice(self.allocator) catch &.{};
        try self.entries.put(self.allocator, family_key, owned_parts);
    }
};

// spec: parts - Returns null when looking up a missing component family
test "parts db returns null for missing family" {
    const alloc = std.testing.allocator;
    var db = PartsDb.init(alloc, "/nonexistent");
    defer db.deinit();
    const result = db.lookup("cap-0402", "100nF", &.{});
    try std.testing.expect(result == null);
}

// spec: parts - Matches component attributes against filter criteria
test "attrs match" {
    const attrs = [_]Property{
        .{ .key = "dielectric", .value = "x7r" },
    };
    try std.testing.expect(PartsDb.attrsMatch(&attrs, &[_][]const u8{"x7r"}));
    try std.testing.expect(!PartsDb.attrsMatch(&attrs, &[_][]const u8{"np0"}));
    try std.testing.expect(PartsDb.attrsMatch(&attrs, &[_][]const u8{}));
}

// spec: parts - Picks the preferred component from matching candidates
test "pick preferred" {
    var a = PartEntry{ .value = "100nF", .manufacturer = "A", .mpn = "A1", .attrs = &.{}, .preferred = false };
    var b = PartEntry{ .value = "100nF", .manufacturer = "B", .mpn = "B1", .attrs = &.{}, .preferred = true };
    var candidates = [_]*const PartEntry{ &a, &b };
    const result = PartsDb.pickPreferred(&candidates);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("B1", result.?.mpn);
}
