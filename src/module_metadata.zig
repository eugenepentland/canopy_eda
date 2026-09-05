//! Source-derived metadata for reusable `(defmodule …)` / atom-named
//! `(block …)` definitions.  Kept outside `serve/` so the library browser,
//! component introspection, and ERC all consume exactly the same declaration.
//!
//! A module opts into component implementation discovery with a direct body
//! form:
//!
//!   (implements tpsm84338rcjr
//!     (policy canonical)
//!     (role regulator))
//!
//! `role` is optional.  `policy` defaults to `recommended` when omitted;
//! malformed/unknown policies leave the module discoverable as `example`
//! rather than accidentally creating a hard validation gate.

const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const parser = @import("sexpr/parser.zig");
const ast = @import("sexpr/ast.zig");
const env = @import("eval/env.zig");

const max_module_bytes: usize = 1024 * 1024;

/// How strongly authoring/checking should prefer an implementation module.
pub const ImplementationPolicy = enum {
    canonical,
    recommended,
    example,

    /// Parse the source spelling of an implementation policy.
    pub fn parse(text: []const u8) ?ImplementationPolicy {
        if (std.mem.eql(u8, text, "canonical")) return .canonical;
        if (std.mem.eql(u8, text, "recommended")) return .recommended;
        if (std.mem.eql(u8, text, "example")) return .example;
        return null;
    }

    /// Relative enforcement strength used when several modules implement one
    /// component (`canonical` wins over `recommended`, then `example`).
    pub fn strength(self: ImplementationPolicy) u8 {
        return switch (self) {
            .canonical => 2,
            .recommended => 1,
            .example => 0,
        };
    }
};

/// A module's primary component, enforcement policy, and optional semantic role.
pub const Implementation = struct {
    component: []const u8,
    policy: ImplementationPolicy = .recommended,
    role: []const u8 = "",
};

/// Borrowed source metadata. All string fields point into `source`.
pub const Definition = struct {
    name: []const u8 = "",
    doc: []const u8 = "",
    implementation: ?Implementation = null,
    source_sha256: [64]u8 = @splat('0'),
};

fn sourceDefinition(source: []const u8) Definition {
    var result: Definition = .{};
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    result.source_sha256 = std.fmt.bytesToHex(digest, .lower);
    return result;
}

fn definitionFromNodes(source: []const u8, nodes: []const ast.Node) Definition {
    var result = sourceDefinition(source);
    for (nodes) |node| {
        const children = node.asList() orelse continue;
        if (children.len < 3) continue;
        const head = children[0].asAtom() orelse continue;
        const module_form = std.mem.eql(u8, head, "defmodule") or
            (std.mem.eql(u8, head, "block") and children[1].asAtom() != null);
        if (!module_form) continue;

        result.name = children[1].asAtom() orelse "";
        var body_start: usize = 3;
        if (children.len > 3) {
            if (children[3].asString()) |doc| {
                result.doc = doc;
                body_start = 4;
            }
        }
        for (children[body_start..]) |body| {
            if (!body.isForm("implements")) continue;
            result.implementation = parseImplementation(body);
            break;
        }
        return result;
    }
    return result;
}

fn implementationFormsValid(nodes: []const ast.Node) bool {
    for (nodes) |node| {
        const children = node.asList() orelse continue;
        if (children.len < 3) continue;
        const head = children[0].asAtom() orelse continue;
        if (!std.mem.eql(u8, head, "defmodule") and !std.mem.eql(u8, head, "block")) continue;
        for (children[3..]) |body| {
            if (!body.isForm("implements")) continue;
            if (parseImplementation(body) == null) return false;
            const implementation = body.asList() orelse return false;
            for (implementation[2..]) |option| {
                const fields = option.asList() orelse continue;
                if (fields.len < 2) continue;
                const key = fields[0].asAtom() orelse continue;
                if (!std.mem.eql(u8, key, "policy")) continue;
                const value = fields[1].asText() orelse return false;
                if (ImplementationPolicy.parse(value) == null) return false;
            }
        }
    }
    return true;
}

/// Parse the first module definition in `source`. The `(implements …)` form
/// must be a direct child of the definition, which prevents an implementation
/// nested inside a conditional/sub-block from becoming library policy.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) Definition {
    const nodes = parser.parse(allocator, source) catch return sourceDefinition(source);
    defer parser.freeNodes(allocator, nodes);
    return definitionFromNodes(source, nodes);
}

/// Render the defmodule doc and implementation metadata as one searchable
/// description for `list_library`. Caller owns the returned slice.
pub fn searchDescription(allocator: std.mem.Allocator, source: []const u8) ?[]const u8 {
    const meta = parse(allocator, source);
    const implementation = meta.implementation;
    if (meta.doc.len == 0 and implementation == null) return null;
    if (implementation) |impl| {
        return std.fmt.allocPrint(
            allocator,
            "{s}{s}implements {s}; policy {s}{s}{s}",
            .{
                meta.doc,
                if (meta.doc.len > 0) "; " else "",
                impl.component,
                @tagName(impl.policy),
                if (impl.role.len > 0) "; role " else "",
                impl.role,
            },
        ) catch null;
    }
    return allocator.dupe(u8, meta.doc) catch null;
}

fn parseImplementation(node: ast.Node) ?Implementation {
    const children = node.asList() orelse return null;
    if (children.len < 2) return null;
    const component = children[1].asText() orelse return null;
    if (component.len == 0) return null;
    var implementation: Implementation = .{ .component = component };
    for (children[2..]) |option| {
        const opt = option.asList() orelse continue;
        if (opt.len < 2) continue;
        const key = opt[0].asAtom() orelse continue;
        const value = opt[1].asText() orelse continue;
        if (std.mem.eql(u8, key, "policy")) {
            // Fail safe: an unknown spelling must never become a canonical
            // error merely because canonical was the surrounding default.
            implementation.policy = ImplementationPolicy.parse(value) orelse .example;
        } else if (std.mem.eql(u8, key, "role")) {
            implementation.role = value;
        }
    }
    return implementation;
}

/// Owned row used by discovery/ERC. Caller frees with `freeMatches`.
pub const Match = struct {
    module: []const u8,
    component: []const u8,
    policy: ImplementationPolicy,
    role: []const u8,
    doc: []const u8,
    source_sha256: [64]u8,
};

/// Module metadata plus proof that every candidate source was readable and
/// syntactically valid. Strict release checks consume `complete`; discovery
/// callers may still display the readable subset.
pub const Collection = struct {
    matches: []Match,
    complete: bool,
};

/// Collect every module with explicit implementation metadata, sorted by
/// module name for stable CLI/ERC output, and preserve collection failures.
pub fn collectWithStatus(allocator: std.mem.Allocator, project_dir: []const u8) std.mem.Allocator.Error!Collection {
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/lib/modules", .{project_dir});
    defer allocator.free(dir_path);
    // A project with no `lib/modules/` at all has an EMPTY module policy, not
    // an unverifiable one: there is no canonical module for a design to have
    // diverged from. That is the ordinary state of a new project (and of one
    // that draws every part from the bundled standard library), and reporting
    // it as incomplete made `netlisp check` release-block on a design that
    // uses no modules. Every other reason the directory will not open —
    // permissions, an I/O error, a file where a directory belongs — still
    // means the policy could not be read, and still fails closed.
    var dir = infra_fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| return .{
        .matches = &.{},
        .complete = err == error.FileNotFound,
    };
    defer dir.close();

    var complete = true;
    var matches: std.ArrayList(Match) = .empty;
    errdefer {
        for (matches.items) |match| {
            allocator.free(match.module);
            allocator.free(match.component);
            allocator.free(match.role);
            allocator.free(match.doc);
        }
        matches.deinit(allocator);
    }
    var it = dir.iterate();
    while (true) {
        const entry = it.next() catch {
            complete = false;
            break;
        } orelse break;
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sexp")) continue;
        const source = dir.readFileAlloc(allocator, entry.name, max_module_bytes) catch {
            complete = false;
            continue;
        };
        defer allocator.free(source);
        const nodes = parser.parse(allocator, source) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                complete = false;
                continue;
            },
        };
        defer parser.freeNodes(allocator, nodes);
        const definition = definitionFromNodes(source, nodes);
        if (definition.name.len == 0 or !implementationFormsValid(nodes)) {
            complete = false;
            continue;
        }
        const implementation = definition.implementation orelse continue;
        const fallback_name = entry.name[0 .. entry.name.len - ".sexp".len];
        try appendMatch(
            &matches,
            allocator,
            if (definition.name.len > 0) definition.name else fallback_name,
            implementation,
            definition.doc,
            definition.source_sha256,
        );
    }
    std.mem.sort(Match, matches.items, {}, struct {
        fn lessThan(_: void, a: Match, b: Match) bool {
            return std.mem.lessThan(u8, a.module, b.module);
        }
    }.lessThan);
    return .{ .matches = try matches.toOwnedSlice(allocator), .complete = complete };
}

/// Compatibility collector for library discovery surfaces. Strict checking
/// uses `collectWithStatus` so malformed policy sources cannot disappear.
pub fn collect(allocator: std.mem.Allocator, project_dir: []const u8) std.mem.Allocator.Error![]Match {
    return (try collectWithStatus(allocator, project_dir)).matches;
}

fn appendMatch(
    matches: *std.ArrayList(Match),
    allocator: std.mem.Allocator,
    module_name: []const u8,
    implementation: Implementation,
    doc_text: []const u8,
    source_sha256: [64]u8,
) std.mem.Allocator.Error!void {
    const match = try dupeMatch(allocator, module_name, implementation, doc_text, source_sha256);
    errdefer {
        allocator.free(match.module);
        allocator.free(match.component);
        allocator.free(match.role);
        allocator.free(match.doc);
    }
    try matches.append(allocator, match);
}

fn dupeMatch(
    allocator: std.mem.Allocator,
    module_name: []const u8,
    implementation: Implementation,
    doc_text: []const u8,
    source_sha256: [64]u8,
) std.mem.Allocator.Error!Match {
    const module = try allocator.dupe(u8, module_name);
    errdefer allocator.free(module);
    const component = try allocator.dupe(u8, implementation.component);
    errdefer allocator.free(component);
    const role = try allocator.dupe(u8, implementation.role);
    errdefer allocator.free(role);
    const doc = try allocator.dupe(u8, doc_text);
    errdefer allocator.free(doc);
    return .{
        .module = module,
        .component = component,
        .policy = implementation.policy,
        .role = role,
        .doc = doc,
        .source_sha256 = source_sha256,
    };
}

/// Release a slice returned by `collect`, including all owned string fields.
pub fn freeMatches(allocator: std.mem.Allocator, matches: []const Match) void {
    if (matches.len == 0) return;
    for (matches) |match| {
        allocator.free(match.module);
        allocator.free(match.component);
        allocator.free(match.role);
        allocator.free(match.doc);
    }
    allocator.free(matches);
}

/// One reusable module actually referenced by an evaluated design tree.
pub const Dependency = struct {
    source: []const u8,
    module: []const u8,
    source_sha256: [64]u8,
};

/// Return the unique module sources used by `block`, with deterministic source
/// digests suitable for a review/CI dependency lock. File-backed subcircuits
/// outside `lib/modules` are intentionally excluded from this module inventory.
pub fn collectDependencies(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    block: *const env.DesignBlock,
) std.mem.Allocator.Error![]Dependency {
    var dependencies: std.ArrayList(Dependency) = .empty;
    errdefer {
        for (dependencies.items) |dependency| {
            allocator.free(dependency.source);
            allocator.free(dependency.module);
        }
        dependencies.deinit(allocator);
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    if (block.origin == .embedded and block.module_name.len > 0) {
        try collectRootDependency(allocator, project_dir, block.module_name, &seen, &dependencies);
    }
    try collectBlockDependencies(allocator, project_dir, block, &seen, &dependencies);
    std.mem.sort(Dependency, dependencies.items, {}, struct {
        fn lessThan(_: void, a: Dependency, b: Dependency) bool {
            return std.mem.lessThan(u8, a.source, b.source);
        }
    }.lessThan);
    return dependencies.toOwnedSlice(allocator);
}

fn collectRootDependency(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    module_name: []const u8,
    seen: *std.StringHashMapUnmanaged(void),
    dependencies: *std.ArrayList(Dependency),
) std.mem.Allocator.Error!void {
    const path = try std.fmt.allocPrint(allocator, "{s}/lib/modules/{s}.sexp", .{ project_dir, module_name });
    defer allocator.free(path);
    const source = infra_fs.cwd().readFileAlloc(allocator, path, max_module_bytes) catch return;
    defer allocator.free(source);
    try seen.put(allocator, module_name, {});
    try appendDependency(allocator, dependencies, module_name, parse(allocator, source));
}

fn collectBlockDependencies(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    block: *const env.DesignBlock,
    seen: *std.StringHashMapUnmanaged(void),
    dependencies: *std.ArrayList(Dependency),
) std.mem.Allocator.Error!void {
    for (block.sub_blocks) |sub_block| {
        const path_opt = try moduleSourcePath(allocator, project_dir, sub_block.source);
        if (path_opt) |path| {
            defer allocator.free(path);
            const gop = try seen.getOrPut(allocator, sub_block.source);
            if (!gop.found_existing) {
                const source = infra_fs.cwd().readFileAlloc(allocator, path, max_module_bytes) catch null;
                if (source) |content| {
                    defer allocator.free(content);
                    const definition = parse(allocator, content);
                    try appendDependency(allocator, dependencies, sub_block.source, definition);
                }
            }
        }
        try collectBlockDependencies(allocator, project_dir, sub_block.block, seen, dependencies);
    }
}

fn moduleSourcePath(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    source: []const u8,
) std.mem.Allocator.Error!?[]const u8 {
    if (source.len == 0) return null;
    if (std.mem.indexOfScalar(u8, source, '/')) |_| {
        if (!std.mem.startsWith(u8, source, "lib/modules/") or !std.mem.endsWith(u8, source, ".sexp")) return null;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, source });
        return path;
    }
    const path = try std.fmt.allocPrint(allocator, "{s}/lib/modules/{s}.sexp", .{ project_dir, source });
    return path;
}

fn appendDependency(
    allocator: std.mem.Allocator,
    dependencies: *std.ArrayList(Dependency),
    source: []const u8,
    definition: Definition,
) std.mem.Allocator.Error!void {
    const owned_source = try allocator.dupe(u8, source);
    errdefer allocator.free(owned_source);
    const module = try allocator.dupe(u8, definition.name);
    errdefer allocator.free(module);
    try dependencies.append(allocator, .{
        .source = owned_source,
        .module = module,
        .source_sha256 = definition.source_sha256,
    });
}

/// Release a slice returned by `collectDependencies`.
pub fn freeDependencies(allocator: std.mem.Allocator, dependencies: []const Dependency) void {
    if (dependencies.len == 0) return;
    for (dependencies) |dependency| {
        allocator.free(dependency.source);
        allocator.free(dependency.module);
    }
    allocator.free(dependencies);
}

test "parse reads direct implementation metadata and source digest" {
    const source =
        \\(defmodule buck ((vout 3.3))
        \\  "Quiet supply"
        \\  (implements tpsm84338rcjr (policy canonical) (role regulator))
        \\  (design-block "buck"))
    ;
    const meta = parse(std.testing.allocator, source);
    try std.testing.expectEqualStrings("buck", meta.name);
    try std.testing.expectEqualStrings("Quiet supply", meta.doc);
    try std.testing.expectEqualStrings("tpsm84338rcjr", meta.implementation.?.component);
    try std.testing.expectEqual(ImplementationPolicy.canonical, meta.implementation.?.policy);
    try std.testing.expectEqualStrings("regulator", meta.implementation.?.role);
    try std.testing.expectEqual(@as(usize, 64), meta.source_sha256.len);
    try std.testing.expect(!std.mem.allEqual(u8, &meta.source_sha256, '0'));
}

test "parse defaults omitted policy and ignores nested implementation forms" {
    const direct = parse(std.testing.allocator, "(defmodule m () (implements chip) (design-block \"m\"))");
    try std.testing.expectEqual(ImplementationPolicy.recommended, direct.implementation.?.policy);

    const nested = parse(std.testing.allocator, "(defmodule m () (design-block \"m\" (implements chip)))");
    try std.testing.expect(nested.implementation == null);
}

test "searchDescription includes doc component policy and role" {
    const alloc = std.testing.allocator;
    const source = "(defmodule supply () \"Low-noise RF rail\" " ++
        "(implements lt3045 (policy canonical) (role regulator)) 1)";
    const description = searchDescription(alloc, source).?;
    defer alloc.free(description);
    try std.testing.expect(std.mem.indexOf(u8, description, "Low-noise RF rail") != null);
    try std.testing.expect(std.mem.indexOf(u8, description, "implements lt3045") != null);
    try std.testing.expect(std.mem.indexOf(u8, description, "policy canonical") != null);
    try std.testing.expect(std.mem.indexOf(u8, description, "role regulator") != null);
}

test "collectDependencies reports used module source digest once" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/modules");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/modules/buck.sexp",
        .data = "(defmodule buck () (design-block \"buck\"))",
    });
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(project);
    var child: env.DesignBlock = .{
        .name = "buck",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const subs = [_]env.SubBlock{
        .{ .name = "a", .block = &child, .source = "buck" },
        .{ .name = "b", .block = &child, .source = "buck" },
    };
    const board: env.DesignBlock = .{
        .name = "board",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &subs,
    };
    const dependencies = try collectDependencies(alloc, project, &board);
    defer freeDependencies(alloc, dependencies);
    try std.testing.expectEqual(@as(usize, 1), dependencies.len);
    try std.testing.expectEqualStrings("buck", dependencies[0].source);
    try std.testing.expectEqualStrings("buck", dependencies[0].module);
    try std.testing.expectEqual(@as(usize, 64), dependencies[0].source_sha256.len);

    child.origin = .embedded;
    child.module_name = "buck";
    const root_dependencies = try collectDependencies(alloc, project, &child);
    defer freeDependencies(alloc, root_dependencies);
    try std.testing.expectEqual(@as(usize, 1), root_dependencies.len);
    try std.testing.expectEqualStrings("buck", root_dependencies[0].source);
}
