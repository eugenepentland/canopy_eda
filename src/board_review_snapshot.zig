//! Read-only board evidence assembly for system review packages.
//!
//! This is the shared seam the old review endpoints were missing: one
//! evaluator instance produces the Markdown, PDF, JSON, BOM and physical PCB
//! preview, and the requested saved layout is threaded into both the thermal
//! scenarios and the physical render. The function never persists generated
//! IDs or rewrites a BOM sidecar, so draft review exports stay read-only.

const std = @import("std");
const build_id = @import("build_id.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;
const erc = @import("erc.zig");
const export_pdf = @import("export_pdf.zig");
const fab_release = @import("fab_release.zig");
const flat_netlist = @import("flat_netlist.zig");
const infra_fs = @import("infra/fs.zig");
const net_name = @import("net_name.zig");
const paths = @import("paths.zig");
const pdf = @import("pdf.zig");
const render_pcb_png = @import("render_pcb_png.zig");
const req_checks = @import("req_checks.zig");
const review = @import("review.zig");
const review_json = @import("review_json.zig");
const review_md = @import("review_md.zig");
const review_assets = @import("system_review_assets.zig");
const zipfile = @import("zipfile.zig");
const bom_html = @import("serve/bom_html.zig");
const mcp_tools = @import("serve/mcp_tools.zig");
const notes = @import("serve/notes.zig");
const pcb = @import("serve/pcb_layout_page.zig");
const thermal_api = @import("serve/thermal_api.zig");

/// mirror-of: serve/api.zig.max_source_bytes
const max_source_bytes = 10 * 1024 * 1024;
const max_source_closure_bytes = 64 * 1024 * 1024;
const max_source_closure_entries = 4096;

/// Physical-view and output choices for one board snapshot.
pub const Options = struct {
    /// Exact saved layout named by the system manifest. Null retains the
    /// board-level blessed-layout fallback for backward-compatible manifests.
    layout: ?[]const u8 = null,
    pdf_theme: @import("svg2pdf.zig").Theme = .print,
    pcb_width: u32 = 1400,
    /// Stable connector handles whose evaluated pin/net observations must be
    /// retained for system-level interface validation.
    connectors: []const []const u8 = &.{},
};

/// One evaluated connector contact, retained independently of the evaluator.
pub const Connection = struct {
    connector: []const u8,
    pin: []const u8,
    net: []const u8,
};

/// Fully rendered, immutable evidence for one board member. Every byte slice
/// belongs to the caller's allocator.
pub const Snapshot = struct {
    identity: struct {
        name: []const u8,
        /// Exact project-relative root source selected by the design resolver.
        source: []const u8,
        title: []const u8,
        part_number: []const u8,
        revision: []const u8,
        layout: []const u8,
        generated_at: []const u8,
    },
    review: struct {
        status: review.Status,
        open_notes: usize,
        /// Expected project-relative notes sidecar path, retained even when
        /// absent so a later stability check can prove it stayed absent.
        notes_path: []const u8,
        /// Exact optional notes sidecar bytes that contributed to the gate.
        notes_source: ?zipfile.Entry,
        markdown: []const u8,
        pdf: []const u8,
        json: []const u8,
        bom_csv: []const u8,
    },
    physical: struct {
        pcb_png: []const u8,
        /// Canonical digest of every exact filesystem byte consumed while
        /// producing this snapshot, verified again before returning.
        consumed_sha256: [64]u8,
        /// Retained full read-set so the surrounding system gate can replay
        /// every direct and transitive dependency after its second fab read.
        consumed_trace: infra_fs.ReadTrace,
        /// Source/layout/BOM identities computed with the same trace contract
        /// as the fabrication release service.
        fab_inputs: fab_release.TracedInputs,
        /// Complete evaluated source closure under project-relative names.
        sources: []const zipfile.Entry,
        connections: []const Connection,
    },
};

const BuildError = @typeInfo(@typeInfo(@TypeOf(buildImpl)).@"fn".return_type.?).error_union.error_set;

/// Build all non-CAM evidence for a board from one evaluated source snapshot.
pub fn build(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    options: Options,
) BuildError!Snapshot {
    return buildImpl(allocator, project_dir, name, options);
}

fn buildImpl(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    options: Options,
) !Snapshot {
    var read_trace = infra_fs.ReadTrace.init(allocator);
    errdefer read_trace.deinit();
    read_trace.begin();

    const root_source_path = try paths.designSourcePathUnique(allocator, project_dir, name);
    defer allocator.free(root_source_path);
    const root_source = try projectRelativeSource(allocator, project_dir, root_source_path);

    var evaluator = Evaluator.init(allocator, project_dir);
    defer evaluator.deinit();

    const named = try mcp_tools.evalNamedBlock(allocator, project_dir, name, &evaluator);
    const violations = try erc.runErc(allocator, named.block, project_dir);
    var checks = try req_checks.runChecks(allocator, &evaluator, named.block);
    req_checks.applyVerifications(&checks, named.block, named.block.instances);

    var doc = try review.buildReview(
        allocator,
        name,
        named.block,
        evaluator.assertions.items,
        violations,
        &checks,
    );
    doc.power.scenarios = try thermal_api.scenariosFor(
        allocator,
        project_dir,
        name,
        doc.power.thermal,
        doc.power.thermal.ambient_c,
        options.layout,
    );

    const md = try review_md.renderToMarkdown(
        allocator,
        named.block,
        project_dir,
        name,
        doc,
        build_id.current(),
    );
    const json = try review_json.renderToJson(allocator, doc);
    const note_evidence = try loadNotesEvidence(allocator, project_dir, name, root_source);
    const open_notes = note_evidence.open;
    const pdf_bytes = try export_pdf.compose(
        allocator,
        named.block,
        project_dir,
        name,
        doc,
        .{
            .theme = options.pdf_theme,
            .generated_at = doc.generated_at,
            .build_id = build_id.current(),
            .open_notes = open_notes,
        },
    );
    try pdf.validate(pdf_bytes);

    var bom_out: std.Io.Writer.Allocating = .init(allocator);
    try bom_html.writeBomCsv(allocator, &bom_out.writer, named.block);

    const fv = try pcb.fabViewForResolved(allocator, project_dir, name, options.layout, named.block);
    const pcb_png = try render_pcb_png.render(allocator, fv.placement, .{
        .width = std.math.clamp(options.pcb_width, 400, 2200),
        .title = name,
        .routed = fv.routed,
        .texts = fv.texts,
        .silk_keepouts = fv.silk_keepouts,
        .user_zones = fv.zones,
        .grid = true,
    });

    const source_entries = try collectSources(allocator, project_dir, root_source_path, &evaluator);
    const connections = try collectConnections(allocator, named.block, options.connectors);
    read_trace.end();
    if (!read_trace.verify()) return error.InputsChanged;
    const consumed_sha256 = read_trace.digest();
    const traced_fab_inputs = try fab_release.tracedInputs(allocator, &read_trace, project_dir, name);
    return .{
        .identity = .{
            .name = try allocator.dupe(u8, name),
            .source = root_source,
            .title = try allocator.dupe(u8, named.block.name),
            .part_number = try allocator.dupe(u8, named.block.board.part_number),
            .revision = try allocator.dupe(u8, named.block.revision.id),
            .layout = try allocator.dupe(u8, fv.selection.name),
            .generated_at = try allocator.dupe(u8, doc.generated_at),
        },
        .review = .{
            .status = doc.summary.status,
            .open_notes = open_notes,
            .notes_path = note_evidence.path,
            .notes_source = note_evidence.source,
            .markdown = md,
            .pdf = pdf_bytes,
            .json = json,
            .bom_csv = bom_out.written(),
        },
        .physical = .{
            .pcb_png = pcb_png,
            .consumed_sha256 = consumed_sha256,
            .consumed_trace = read_trace,
            .fab_inputs = traced_fab_inputs,
            .sources = source_entries,
            .connections = connections,
        },
    };
}

/// Re-read every archived source and the optional notes sidecar after the
/// surrounding fabrication snapshot. This rejects A/B/A changes that could
/// otherwise pair review evidence from B with fabrication evidence from A.
pub fn verifySnapshot(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    snapshot: Snapshot,
) bool {
    if (!snapshot.physical.consumed_trace.verify()) return false;
    for (snapshot.physical.sources) |source| {
        const current = review_assets.readContainedFile(
            allocator,
            project_dir,
            source.name,
            max_source_bytes,
        ) catch return false;
        defer allocator.free(current);
        if (!std.mem.eql(u8, current, source.data)) return false;
    }
    if (snapshot.review.notes_source) |notes_source| {
        const current = review_assets.readContainedFile(
            allocator,
            project_dir,
            snapshot.review.notes_path,
            1024 * 1024,
        ) catch return false;
        defer allocator.free(current);
        return std.mem.eql(u8, current, notes_source.data);
    }
    const unexpected = review_assets.readContainedFile(
        allocator,
        project_dir,
        snapshot.review.notes_path,
        1024 * 1024,
    ) catch |err| return err == error.FileNotFound;
    allocator.free(unexpected);
    return false;
}

fn collectConnections(
    allocator: std.mem.Allocator,
    block: *const @import("eval/env.zig").DesignBlock,
    connectors: []const []const u8,
) ![]const Connection {
    const ConnectorTarget = struct {
        declared: []const u8,
        evaluated: []const u8,
    };

    var targets: std.ArrayList(ConnectorTarget) = .empty;
    for (connectors) |connector| try targets.append(allocator, .{
        .declared = connector,
        .evaluated = try evaluatedConnectorHandle(allocator, block, connector),
    });

    var out: std.ArrayList(Connection) = .empty;
    var nets: std.ArrayList(flat_netlist.FlatNet) = .empty;
    try flat_netlist.flattenAndMergeNets(allocator, block, &nets);
    for (nets.items) |net| for (net.pins) |pin| {
        const target = for (targets.items) |target| {
            if (std.mem.eql(u8, target.evaluated, pin.ref_des)) break target;
        } else continue;
        try out.append(allocator, .{
            .connector = try allocator.dupe(u8, target.declared),
            .pin = try allocator.dupe(u8, pin.pin),
            .net = try allocator.dupe(u8, net.name),
        });
    };
    std.mem.sort(Connection, out.items, {}, struct {
        fn lessThan(_: void, a: Connection, b: Connection) bool {
            const connector_order = std.mem.order(u8, a.connector, b.connector);
            if (connector_order != .eq) return connector_order == .lt;
            return std.mem.lessThan(u8, a.pin, b.pin);
        }
    }.lessThan);
    return out.items;
}

/// Resolve a stable source handle such as `base-interface/J1` to the current
/// evaluated ref-des while preserving the sub-block path. Evaluator-wide
/// numbering may turn that module-local `J1` into `U19`; `origin_key` and
/// `label` retain the authored identity specifically so contracts do not drift
/// when unrelated parts are inserted or removed.
fn evaluatedConnectorHandle(
    allocator: std.mem.Allocator,
    root: *const @import("eval/env.zig").DesignBlock,
    connector: []const u8,
) ![]const u8 {
    const prefix = net_name.parent(connector) orelse "";
    const source_name = net_name.leaf(connector);

    var block = root;
    if (prefix.len > 0) {
        var segments = std.mem.splitScalar(u8, prefix, '/');
        while (segments.next()) |segment| {
            block = for (block.sub_blocks) |sub_block| {
                if (std.mem.eql(u8, sub_block.name, segment)) break sub_block.block;
            } else return allocator.dupe(u8, connector);
        }
    }

    const evaluated = for (block.instances) |instance| {
        if (std.mem.eql(u8, instance.ref_des, source_name) or
            std.mem.eql(u8, instance.label, source_name) or
            std.mem.eql(u8, instance.origin_key, source_name)) break instance.ref_des;
    } else return allocator.dupe(u8, connector);

    if (prefix.len == 0) return allocator.dupe(u8, evaluated);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, evaluated });
}

const NotesEvidence = struct {
    open: usize,
    path: []const u8,
    source: ?zipfile.Entry,
};

fn loadNotesEvidence(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    root_source: []const u8,
) !NotesEvidence {
    const parent = std.fs.path.dirname(root_source) orelse return error.SourceOutsideProject;
    const relative = try std.fmt.allocPrint(allocator, "{s}/{s}.notes.md", .{ parent, name });
    const raw = review_assets.readContainedFile(allocator, project_dir, relative, 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) return .{ .open = 0, .path = relative, .source = null };
        allocator.free(relative);
        return err;
    };
    const parsed = notes.parseNotes(allocator, raw) catch |err| {
        allocator.free(relative);
        allocator.free(raw);
        return err;
    };
    defer {
        allocator.free(parsed.tasks);
        allocator.free(parsed.scratchpad);
    }
    var count: usize = 0;
    for (parsed.tasks) |task| if (task.completed == null) {
        count += 1;
    };
    return .{ .open = count, .path = relative, .source = .{ .name = relative, .data = raw } };
}

fn projectRelativeSource(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    source_path: []const u8,
) ![]const u8 {
    const project = try infra_fs.canonicalPathAlloc(allocator, project_dir);
    defer allocator.free(project);
    const source = try infra_fs.canonicalPathAlloc(allocator, source_path);
    defer allocator.free(source);
    if (source.len <= project.len) return error.SourceOutsideProject;
    if (!std.mem.startsWith(u8, source, project)) return error.SourceOutsideProject;
    if (project.len > 1 and source[project.len] != '/') return error.SourceOutsideProject;
    const relative_start = if (project.len == 1) project.len else project.len + 1;
    const relative = source[relative_start..];
    if (!sourceRelativeAllowed(relative)) return error.SourceOutsideProject;
    return allocator.dupe(u8, relative);
}

fn sourceRelativeAllowed(relative: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(relative)) return false;
    if (!std.mem.endsWith(u8, relative, ".sexp")) return false;
    return std.mem.startsWith(u8, relative, "src/") or
        std.mem.startsWith(u8, relative, "lib/");
}

fn appendSource(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    path: []const u8,
    seen: *std.StringHashMapUnmanaged(void),
    out: *std.ArrayList(zipfile.Entry),
    total_bytes: *usize,
) !void {
    const resolved = try infra_fs.canonicalPathAlloc(allocator, path);
    defer allocator.free(resolved);
    const name = try projectRelativeSource(allocator, project_dir, resolved);
    errdefer allocator.free(name);
    if (seen.contains(name)) {
        allocator.free(name);
        return;
    }
    const data = try review_assets.readContainedFile(allocator, project_dir, name, max_source_bytes);
    errdefer allocator.free(data);
    if (out.items.len >= max_source_closure_entries) return error.SourceClosureTooLarge;
    if (data.len > max_source_closure_bytes - total_bytes.*) return error.SourceClosureTooLarge;
    try seen.put(allocator, name, {});
    try out.append(allocator, .{ .name = name, .data = data });
    total_bytes.* += data.len;
}

fn collectSources(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    root_source: []const u8,
    evaluator: *Evaluator,
) ![]const zipfile.Entry {
    var out: std.ArrayList(zipfile.Entry) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var total_bytes: usize = 0;
    try appendSource(allocator, project_dir, root_source, &seen, &out, &total_bytes);
    var it = evaluator.loaded_files.keyIterator();
    while (it.next()) |path| try appendSource(allocator, project_dir, path.*, &seen, &out, &total_bytes);
    std.mem.sort(zipfile.Entry, out.items, {}, struct {
        fn lessThan(_: void, a: zipfile.Entry, b: zipfile.Entry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return out.items;
}

// spec: system-review - interface evidence resolves stable sub-block connector handles through the canonical flattened netlist
test "connector observations retain hierarchy handles and canonical tied nets" {
    const env = @import("eval/env.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const child_pins = [_]env.PinRef{
        .{ .ref_des = "U19", .pin = "1" },
        .{ .ref_des = "U19", .pin = "2" },
    };
    const child_nets = [_]env.Net{.{ .name = "LOCAL", .pins = &child_pins }};
    const child_instances = [_]env.Instance{.{
        .ref_des = "U19",
        .label = "J1",
        .origin_key = "J1",
        .component = "connector",
        .value = "connector",
        .footprint = "connector",
        .symbol = "connector",
    }};
    var child = env.DesignBlock{
        .name = "connector",
        .instances = &child_instances,
        .nets = &child_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var sub_blocks = [_]env.SubBlock{.{ .name = "link", .block = &child }};
    const root_nets = [_]env.Net{.{ .name = "CANONICAL", .pins = &.{} }};
    const ties = [_]env.NetTie{.{ .a = "CANONICAL", .b = "link/LOCAL" }};
    const root = env.DesignBlock{
        .name = "root",
        .instances = &.{},
        .nets = &root_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &sub_blocks,
        .net_ties = &ties,
    };

    const connections = try collectConnections(arena.allocator(), &root, &.{"link/J1"});
    try std.testing.expectEqual(@as(usize, 2), connections.len);
    try std.testing.expectEqualStrings("link/J1", connections[0].connector);
    try std.testing.expectEqualStrings("CANONICAL", connections[0].net);
}

// spec: system-review - evaluated source paths retain the buildable src/lib shape in a review package
test "source closure rejects files outside project source roots" {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(std.testing.allocator);
    var entries: std.ArrayList(zipfile.Entry) = .empty;
    defer entries.deinit(std.testing.allocator);
    var total_bytes: usize = 0;
    try std.testing.expectError(
        error.FileNotFound,
        appendSource(
            std.testing.allocator,
            "demo",
            "/definitely-not-a-netlisp-project/evaluated-source.data",
            &seen,
            &entries,
            &total_bytes,
        ),
    );
}

test "source closure rejects a project-local symlink to external bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "project/lib/modules");
    try tmp.dir.createDirPath(std.testing.io, "outside");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside/secret.sexp", .data = "(secret)" });
    try tmp.dir.symLink(
        std.testing.io,
        "../../../outside/secret.sexp",
        "project/lib/modules/linked.sexp",
        .{},
    );
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, "project", allocator);
    const linked = try std.fmt.allocPrint(allocator, "{s}/lib/modules/linked.sexp", .{project});
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var entries: std.ArrayList(zipfile.Entry) = .empty;
    var total_bytes: usize = 0;
    try std.testing.expectError(
        error.SourceOutsideProject,
        appendSource(allocator, project, linked, &seen, &entries, &total_bytes),
    );
    try std.testing.expectEqual(@as(usize, 0), entries.items.len);
}

test "root source identity is resolved project relative" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "project/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/src/board.sexp", .data = "(design-block board)" });
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, "project", std.testing.allocator);
    defer std.testing.allocator.free(project);
    const absolute_source = try std.fmt.allocPrint(std.testing.allocator, "{s}/src/board.sexp", .{project});
    defer std.testing.allocator.free(absolute_source);
    const source = try projectRelativeSource(
        std.testing.allocator,
        project,
        absolute_source,
    );
    defer std.testing.allocator.free(source);
    try std.testing.expectEqualStrings("src/board.sexp", source);
    try std.testing.expectError(
        error.SourceOutsideProject,
        projectRelativeSource(std.testing.allocator, ".", "/etc/passwd"),
    );
}
