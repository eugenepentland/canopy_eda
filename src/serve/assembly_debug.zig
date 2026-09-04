//! Read-only assembly workspace with board-search and bring-up interactions.
//!
//! The handler evaluates a design, builds one compact JSON index, and leaves
//! all interaction to `assembly_debug.js`. The PCB itself stays in the normal
//! read-only PCB embed; selections cross the iframe boundary through the
//! `netlisp-pcb-focus` postMessage protocol.

const std = @import("std");
const escape = @import("../escape.zig");
const json_writer = @import("../json_writer.zig");
const datasheet_ref = @import("datasheet_ref.zig");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const log = @import("../infra/log.zig");
const paths = @import("../paths.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const env_mod = @import("../eval/env.zig");
const bom = @import("../bom.zig");
const export_kicad = @import("../export_kicad.zig");
const rework_guide = @import("rework_guide.zig");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;

const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

const Part = struct {
    ref: []const u8,
    uuid: []const u8 = "",
    component: []const u8,
    value: []const u8,
    footprint: []const u8,
    mpn: []const u8 = "",
    manufacturer: []const u8 = "",
    dnp: bool = false,
    testpoint: bool = false,
    /// PDF filenames under `lib/datasheets/` that this part's component
    /// declares AND that exist on disk, so a rendered link never 404s.
    datasheets: []const []const u8 = &.{},
};

const BomGroup = struct {
    key: []const u8,
    mpn: []const u8,
    manufacturer: []const u8,
    component: []const u8,
    value: []const u8,
    footprint: []const u8,
    refs: []const []const u8,
    dnp_refs: []const []const u8,
    dnp_count: usize,
    conflict: bool,
    datasheets: []const []const u8,
};

const GroupDraft = struct {
    key: []const u8,
    mpn: []const u8,
    manufacturer: []const u8,
    component: []const u8,
    value: []const u8,
    footprint: []const u8,
    refs: std.ArrayList([]const u8) = .empty,
    dnp_refs: std.ArrayList([]const u8) = .empty,
    datasheets: std.ArrayList([]const u8) = .empty,
    dnp_count: usize = 0,
    conflict: bool = false,
};

const Entity = struct {
    kind: []const u8,
    label: []const u8,
    detail: []const u8,
    refs: []const []const u8,
    nets: []const []const u8,
    keywords: []const u8,
};

const EntityDraft = struct {
    kind: []const u8,
    label: []const u8,
    detail: []const u8,
    refs: std.ArrayList([]const u8) = .empty,
    nets: std.ArrayList([]const u8) = .empty,
    keywords: std.ArrayList(u8) = .empty,
};

const Index = struct {
    parts: []const Part,
    bom_groups: []const BomGroup,
    entities: []const Entity,
    nets: []const export_kicad.FlatNet,
    guides: []const rework_guide.Guide = &.{},
};

/// Immutable identity shown by the self-contained Assembly artifact packaged
/// with one fabrication release.
pub const ReleaseIdentity = struct {
    part_number: []const u8,
    revision: []const u8,
    fab_id: []const u8,
    release_token: []const u8,
};

const PageMeta = struct {
    name: []const u8,
    part_number: []const u8 = "",
    revision: []const u8 = "",
    fab_id: []const u8 = "",
    release_token: []const u8 = "",
    standalone: bool = false,
};

const PageOptions = struct {
    layout: ?[]const u8 = null,
    browser_benchmark: bool = false,
    meta: PageMeta,
    /// Complete read-only PCB review document. Present only in the release
    /// artifact; it is installed into the iframe as `srcdoc` after the shell's
    /// listeners are ready.
    board_html: ?[]const u8 = null,
};

fn isSafeName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
        if (!ok) return false;
    }
    return true;
}

fn testDesignBlock(value: env_mod.Value) error{TestExpectedDesignBlock}!*env_mod.DesignBlock {
    return switch (value) {
        .design_block => |block| block,
        else => error.TestExpectedDesignBlock,
    };
}

fn property(properties: []const env_mod.Property, wanted: []const u8) []const u8 {
    for (properties) |p| {
        if (std.ascii.eqlIgnoreCase(p.key, wanted)) return std.mem.trim(u8, p.value, " \t\r\n");
    }
    return "";
}

fn overlayProperty(
    entries: []const bom.BomEntry,
    info: bom.FlatInfo,
    wanted: []const u8,
) []const u8 {
    for (entries) |entry| {
        if (!bom.entryMatchesSource(entry, info)) continue;
        for (entry.properties) |entry_property| {
            if (std.ascii.eqlIgnoreCase(entry_property.key, wanted)) {
                return std.mem.trim(u8, entry_property.value, " \t\r\n");
            }
        }
        break;
    }
    return property(info.properties, wanted);
}

fn uuidForPart(
    allocator: std.mem.Allocator,
    entries: []const bom.BomEntry,
    info: bom.FlatInfo,
) ![]const u8 {
    for (entries) |entry| {
        if (entry.uuid.len > 0 and bom.entryMatchesSource(entry, info)) return entry.uuid;
    }
    if (info.id.len > 0) return export_kicad.uuidFromId(allocator, info.id);
    return "";
}

fn normalized(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const out = try allocator.alloc(u8, trimmed.len);
    for (trimmed, out) |c, *dst| dst.* = std.ascii.toLower(c);
    return out;
}

fn groupKey(allocator: std.mem.Allocator, part: Part) ![]const u8 {
    if (part.mpn.len > 0) {
        return std.fmt.allocPrint(allocator, "mpn:{s}", .{try normalized(allocator, part.mpn)});
    }
    return std.fmt.allocPrint(
        allocator,
        "fallback:{s}|{s}|{s}",
        .{
            try normalized(allocator, part.component),
            try normalized(allocator, part.value),
            try normalized(allocator, part.footprint),
        },
    );
}

/// Group sourceable parts by normalized MPN. Parts without one use a stable
/// component/value/footprint fallback; test points never enter the assembly BOM.
fn buildBomGroups(allocator: std.mem.Allocator, parts: []const Part) ![]const BomGroup {
    var drafts: std.ArrayList(GroupDraft) = .empty;
    for (parts) |part| {
        if (part.testpoint) continue;
        const key = try groupKey(allocator, part);
        var found: ?*GroupDraft = null;
        for (drafts.items) |*candidate| {
            if (std.mem.eql(u8, candidate.key, key)) {
                found = candidate;
                break;
            }
        }
        if (found) |g| {
            try g.refs.append(allocator, part.ref);
            for (part.datasheets) |sheet| try appendUnique(allocator, &g.datasheets, sheet);
            if (part.dnp) {
                g.dnp_count += 1;
                try g.dnp_refs.append(allocator, part.ref);
            }
            const identity_conflict = !std.mem.eql(u8, g.value, part.value) or
                !std.mem.eql(u8, g.footprint, part.footprint) or
                !std.mem.eql(u8, g.component, part.component);
            if (identity_conflict) g.conflict = true;
            if (g.manufacturer.len == 0 and part.manufacturer.len > 0) {
                g.manufacturer = part.manufacturer;
            } else {
                const manufacturer_conflict = part.manufacturer.len > 0 and
                    !std.ascii.eqlIgnoreCase(g.manufacturer, part.manufacturer);
                if (manufacturer_conflict) g.conflict = true;
            }
        } else {
            var refs: std.ArrayList([]const u8) = .empty;
            try refs.append(allocator, part.ref);
            var dnp_refs: std.ArrayList([]const u8) = .empty;
            if (part.dnp) try dnp_refs.append(allocator, part.ref);
            var datasheets: std.ArrayList([]const u8) = .empty;
            for (part.datasheets) |sheet| try appendUnique(allocator, &datasheets, sheet);
            try drafts.append(allocator, .{
                .key = key,
                .mpn = part.mpn,
                .manufacturer = part.manufacturer,
                .component = part.component,
                .value = part.value,
                .footprint = part.footprint,
                .refs = refs,
                .dnp_refs = dnp_refs,
                .datasheets = datasheets,
                .dnp_count = @intFromBool(part.dnp),
            });
        }
    }

    std.mem.sort(GroupDraft, drafts.items, {}, struct {
        fn less(_: void, a: GroupDraft, b: GroupDraft) bool {
            const a_name = if (a.mpn.len > 0) a.mpn else a.value;
            const b_name = if (b.mpn.len > 0) b.mpn else b.value;
            return std.ascii.lessThanIgnoreCase(a_name, b_name);
        }
    }.less);

    const out = try allocator.alloc(BomGroup, drafts.items.len);
    for (drafts.items, out) |*draft, *group| {
        group.* = .{
            .key = draft.key,
            .mpn = draft.mpn,
            .manufacturer = draft.manufacturer,
            .component = draft.component,
            .value = draft.value,
            .footprint = draft.footprint,
            .refs = try draft.refs.toOwnedSlice(allocator),
            .dnp_refs = try draft.dnp_refs.toOwnedSlice(allocator),
            .dnp_count = draft.dnp_count,
            .conflict = draft.conflict,
            .datasheets = try draft.datasheets.toOwnedSlice(allocator),
        };
    }
    return out;
}

fn appendUnique(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    value: []const u8,
) !void {
    if (value.len == 0) return;
    for (list.items) |old| if (std.mem.eql(u8, old, value)) return;
    try list.append(allocator, value);
}

fn qualify(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]const u8 {
    if (prefix.len == 0) return name;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });
}

fn collectBlockRefs(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    prefix: []const u8,
    refs: *std.ArrayList([]const u8),
) !void {
    for (block.instances) |inst| try appendUnique(allocator, refs, try qualify(allocator, prefix, inst.ref_des));
    for (block.sub_blocks) |sb| {
        const child_prefix = try qualify(allocator, prefix, sb.name);
        try collectBlockRefs(allocator, sb.block, child_prefix, refs);
    }
}

fn collectSectionRefs(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    section: env_mod.Section,
    prefix: []const u8,
    refs: *std.ArrayList([]const u8),
) !void {
    for (section.instances) |inst| {
        try appendUnique(allocator, refs, try qualify(allocator, prefix, inst.ref_des));
    }
    for (section.pin_groups) |pins| {
        try appendUnique(allocator, refs, try qualify(allocator, prefix, pins.ref_des));
    }
    for (section.sub_sections) |sub| {
        try collectSectionRefs(allocator, block, sub, prefix, refs);
    }
    for (section.hosts) |host| {
        for (block.sub_blocks) |sb| {
            if (!std.mem.eql(u8, sb.name, host)) continue;
            const child_prefix = try qualify(allocator, prefix, sb.name);
            try collectBlockRefs(allocator, sb.block, child_prefix, refs);
        }
    }
}

fn refsForNet(
    allocator: std.mem.Allocator,
    flat_net: export_kicad.FlatNet,
) ![]const []const u8 {
    var refs: std.ArrayList([]const u8) = .empty;
    for (flat_net.pins) |pin| try appendUnique(allocator, &refs, pin.ref_des);
    return refs.toOwnedSlice(allocator);
}

fn netsForRef(
    allocator: std.mem.Allocator,
    flat_nets: []const export_kicad.FlatNet,
    ref: []const u8,
) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (flat_nets) |net| {
        for (net.pins) |pin| {
            if (std.mem.eql(u8, pin.ref_des, ref)) {
                try appendUnique(allocator, &names, net.name);
                break;
            }
        }
    }
    return names.toOwnedSlice(allocator);
}

fn partForRef(parts: []const Part, ref: []const u8) ?Part {
    for (parts) |part| if (std.mem.eql(u8, part.ref, ref)) return part;
    return null;
}

fn appendKeywords(allocator: std.mem.Allocator, entity: *EntityDraft, text: []const u8) !void {
    if (text.len == 0) return;
    if (entity.keywords.items.len > 0) try entity.keywords.append(allocator, ' ');
    try entity.keywords.appendSlice(allocator, text);
}

const EntitySpec = struct {
    kind: []const u8,
    label: []const u8,
    detail: []const u8,
    refs: []const []const u8,
    nets: []const []const u8,
    keywords: []const []const u8,
};

fn addEntity(
    allocator: std.mem.Allocator,
    drafts: *std.ArrayList(EntityDraft),
    spec: EntitySpec,
) !void {
    var entity: ?*EntityDraft = null;
    for (drafts.items) |*candidate| {
        if (std.mem.eql(u8, candidate.kind, spec.kind) and
            std.ascii.eqlIgnoreCase(candidate.label, spec.label))
        {
            entity = candidate;
            break;
        }
    }
    if (entity == null) {
        try drafts.append(allocator, .{
            .kind = spec.kind,
            .label = spec.label,
            .detail = spec.detail,
        });
        entity = &drafts.items[drafts.items.len - 1];
    }
    for (spec.refs) |ref| try appendUnique(allocator, &entity.?.refs, ref);
    for (spec.nets) |net| try appendUnique(allocator, &entity.?.nets, net);
    try appendKeywords(allocator, entity.?, spec.label);
    try appendKeywords(allocator, entity.?, spec.detail);
    for (spec.keywords) |word| try appendKeywords(allocator, entity.?, word);
}

fn addSectionEntities(
    allocator: std.mem.Allocator,
    drafts: *std.ArrayList(EntityDraft),
    block: *const env_mod.DesignBlock,
    prefix: []const u8,
    parent_label: []const u8,
    sections: []const env_mod.Section,
) !void {
    for (sections) |section| {
        const label = if (parent_label.len > 0)
            try std.fmt.allocPrint(allocator, "{s} / {s}", .{ parent_label, section.name })
        else if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s} / {s}", .{ prefix, section.name })
        else
            section.name;
        var refs: std.ArrayList([]const u8) = .empty;
        try collectSectionRefs(allocator, block, section, prefix, &refs);
        try addEntity(
            allocator,
            drafts,
            .{
                .kind = "section",
                .label = label,
                .detail = section.description,
                .refs = refs.items,
                .nets = &.{},
                .keywords = section.hosts,
            },
        );
        try addSectionEntities(
            allocator,
            drafts,
            block,
            prefix,
            label,
            section.sub_sections,
        );
    }
}

fn addHierarchyEntities(
    allocator: std.mem.Allocator,
    drafts: *std.ArrayList(EntityDraft),
    block: *const env_mod.DesignBlock,
    prefix: []const u8,
) !void {
    try addSectionEntities(allocator, drafts, block, prefix, "", block.sections);
    for (block.test_points) |tp| {
        const ref = try qualify(allocator, prefix, tp.ref_des);
        const net = try qualify(allocator, prefix, tp.net);
        try addEntity(
            allocator,
            drafts,
            .{
                .kind = "testpoint",
                .label = ref,
                .detail = tp.purpose,
                .refs = &.{ref},
                .nets = &.{net},
                .keywords = &.{tp.net},
            },
        );
    }
    for (block.sub_blocks) |sb| {
        const child_prefix = try qualify(allocator, prefix, sb.name);
        var refs: std.ArrayList([]const u8) = .empty;
        try collectBlockRefs(allocator, sb.block, child_prefix, &refs);
        try addEntity(
            allocator,
            drafts,
            .{
                .kind = "subcircuit",
                .label = child_prefix,
                .detail = sb.block.name,
                .refs = refs.items,
                .nets = &.{},
                .keywords = &.{sb.source},
            },
        );
        try addHierarchyEntities(allocator, drafts, sb.block, child_prefix);
    }
}

fn finishEntities(allocator: std.mem.Allocator, drafts: *std.ArrayList(EntityDraft)) ![]const Entity {
    std.mem.sort(EntityDraft, drafts.items, {}, struct {
        fn less(_: void, a: EntityDraft, b: EntityDraft) bool {
            const kind_order = std.mem.order(u8, a.kind, b.kind);
            if (kind_order != .eq) return kind_order == .lt;
            return std.ascii.lessThanIgnoreCase(a.label, b.label);
        }
    }.less);
    const out = try allocator.alloc(Entity, drafts.items.len);
    for (drafts.items, out) |*draft, *entity| {
        entity.* = .{
            .kind = draft.kind,
            .label = draft.label,
            .detail = draft.detail,
            .refs = try draft.refs.toOwnedSlice(allocator),
            .nets = try draft.nets.toOwnedSlice(allocator),
            .keywords = try draft.keywords.toOwnedSlice(allocator),
        };
    }
    return out;
}

/// Component name -> available component datasheets: uploaded local PDFs and
/// HTTP(S) URLs.
const DatasheetMap = std.StringHashMapUnmanaged([]const []const u8);

/// True when `lib/datasheets/<name>` is really on disk. A component may name a
/// PDF nobody uploaded, and the assembly page links what it lists — so a
/// missing file is dropped here rather than rendered as a link that 404s.
fn datasheetPresent(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) bool {
    if (datasheet_ref.isRemote(name)) return true;
    if (!datasheet_ref.isLocal(name)) return false;
    const path = std.fmt.allocPrint(allocator, "{s}/lib/datasheets/{s}", .{ project_dir, name }) catch return false;
    defer allocator.free(path);
    _ = infra_fs.cwd().statFile(path) catch return false;
    return true;
}

/// Map every component instantiated in `block` (recursing sub-blocks) to its
/// present datasheets. Datasheets are declared once per library component, so
/// the component name — not the ref-des — is the identity that carries them,
/// and the first instance of a component settles the entry for all of them.
fn collectComponentDatasheets(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    block: *const env_mod.DesignBlock,
    map: *DatasheetMap,
) !void {
    for (block.instances) |inst| {
        if (inst.docs.datasheets.len == 0 or inst.component.len == 0) continue;
        const gop = try map.getOrPut(allocator, inst.component);
        if (gop.found_existing) continue;
        var present: std.ArrayList([]const u8) = .empty;
        for (inst.docs.datasheets) |sheet| {
            if (datasheetPresent(allocator, project_dir, sheet)) try present.append(allocator, sheet);
        }
        gop.value_ptr.* = try present.toOwnedSlice(allocator);
    }
    for (block.sub_blocks) |sb| try collectComponentDatasheets(allocator, project_dir, sb.block, map);
}

fn partsFromFlat(
    allocator: std.mem.Allocator,
    flat: []const bom.FlatInfo,
    entries: []const bom.BomEntry,
    datasheets: DatasheetMap,
) ![]const Part {
    const parts = try allocator.alloc(Part, flat.len);
    for (flat, parts) |info, *part| {
        part.* = .{
            .ref = info.ref_des,
            .uuid = try uuidForPart(allocator, entries, info),
            .component = info.component,
            .value = info.value,
            .footprint = info.footprint,
            .mpn = overlayProperty(entries, info, "mpn"),
            .manufacturer = overlayProperty(entries, info, "manufacturer"),
            .dnp = info.dnp,
            .testpoint = env_mod.isTestPoint(info.component),
            .datasheets = datasheets.get(info.component) orelse &.{},
        };
    }
    return parts;
}

fn buildIndex(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    block: *const env_mod.DesignBlock,
    entries: []const bom.BomEntry,
) !Index {
    var flat: std.ArrayList(bom.FlatInfo) = .empty;
    try bom.collectFlatInstances(allocator, block, "", &flat);
    var datasheets: DatasheetMap = .empty;
    try collectComponentDatasheets(allocator, project_dir, block, &datasheets);
    const parts = try partsFromFlat(allocator, flat.items, entries, datasheets);

    var nets: std.ArrayList(export_kicad.FlatNet) = .empty;
    try export_kicad.flattenAndMergeNets(allocator, block, &nets);
    const groups = try buildBomGroups(allocator, parts);
    var entity_drafts: std.ArrayList(EntityDraft) = .empty;

    for (parts) |part| {
        const part_nets = try netsForRef(allocator, nets.items, part.ref);
        const detail = try std.fmt.allocPrint(
            allocator,
            "{s}{s}{s}",
            .{ part.component, if (part.value.len > 0) " · " else "", part.value },
        );
        try addEntity(
            allocator,
            &entity_drafts,
            .{
                .kind = if (part.testpoint) "testpoint" else "ref",
                .label = part.ref,
                .detail = detail,
                .refs = &.{part.ref},
                .nets = part_nets,
                .keywords = &.{
                    part.component,
                    part.value,
                    part.footprint,
                    part.mpn,
                    part.manufacturer,
                },
            },
        );
        if (part.component.len > 0) try addEntity(
            allocator,
            &entity_drafts,
            .{
                .kind = "component",
                .label = part.component,
                .detail = "Component family",
                .refs = &.{part.ref},
                .nets = part_nets,
                .keywords = &.{ part.value, part.mpn },
            },
        );
        if (part.value.len > 0) try addEntity(
            allocator,
            &entity_drafts,
            .{
                .kind = "value",
                .label = part.value,
                .detail = part.component,
                .refs = &.{part.ref},
                .nets = part_nets,
                .keywords = &.{ part.footprint, part.mpn },
            },
        );
        if (part.mpn.len > 0) try addEntity(
            allocator,
            &entity_drafts,
            .{
                .kind = "mpn",
                .label = part.mpn,
                .detail = part.manufacturer,
                .refs = &.{part.ref},
                .nets = part_nets,
                .keywords = &.{ part.component, part.value, part.footprint },
            },
        );
    }

    for (nets.items) |net| {
        const refs = try refsForNet(allocator, net);
        const detail = try std.fmt.allocPrint(allocator, "{d} connected pad{s}", .{
            net.pins.len,
            if (net.pins.len == 1) "" else "s",
        });
        try addEntity(
            allocator,
            &entity_drafts,
            .{
                .kind = "net",
                .label = net.name,
                .detail = detail,
                .refs = refs,
                .nets = &.{net.name},
                .keywords = &.{},
            },
        );
    }
    try addHierarchyEntities(allocator, &entity_drafts, block, "");

    return .{
        .parts = parts,
        .bom_groups = groups,
        .entities = try finishEntities(allocator, &entity_drafts),
        .nets = try nets.toOwnedSlice(allocator),
    };
}

fn writeStringArray(w: *std.Io.Writer, values: []const []const u8) !void {
    try w.writeByte('[');
    for (values, 0..) |value, i| {
        if (i > 0) try w.writeByte(',');
        try json_writer.writeScriptString(w, value);
    }
    try w.writeByte(']');
}

fn writeIndexJson(w: *std.Io.Writer, index: Index, meta: PageMeta) !void {
    try w.writeAll("{\"name\":");
    try json_writer.writeScriptString(w, meta.name);
    try w.writeAll(",\"part_number\":");
    try json_writer.writeScriptString(w, meta.part_number);
    try w.writeAll(",\"revision\":");
    try json_writer.writeScriptString(w, meta.revision);
    try w.writeAll(",\"fab_id\":");
    try json_writer.writeScriptString(w, meta.fab_id);
    try w.writeAll(",\"release_token\":");
    try json_writer.writeScriptString(w, meta.release_token);
    try w.print(",\"standalone\":{s},\"parts\":[", .{if (meta.standalone) "true" else "false"});
    for (index.parts, 0..) |part, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"uuid\":");
        try json_writer.writeScriptString(w, part.uuid);
        try w.writeAll(",\"ref\":");
        try json_writer.writeScriptString(w, part.ref);
        try w.writeByte('}');
    }
    try w.writeAll("],\"bom\":[");
    for (index.bom_groups, 0..) |group, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"key\":");
        try json_writer.writeScriptString(w, group.key);
        try w.writeAll(",\"mpn\":");
        try json_writer.writeScriptString(w, group.mpn);
        try w.writeAll(",\"manufacturer\":");
        try json_writer.writeScriptString(w, group.manufacturer);
        try w.writeAll(",\"component\":");
        try json_writer.writeScriptString(w, group.component);
        try w.writeAll(",\"value\":");
        try json_writer.writeScriptString(w, group.value);
        try w.writeAll(",\"footprint\":");
        try json_writer.writeScriptString(w, group.footprint);
        try w.print(",\"qty\":{d},\"dnp_count\":{d},\"conflict\":{s},\"refs\":", .{
            group.refs.len,
            group.dnp_count,
            if (group.conflict) "true" else "false",
        });
        try writeStringArray(w, group.refs);
        try w.writeAll(",\"dnp_refs\":");
        try writeStringArray(w, group.dnp_refs);
        try w.writeAll(",\"datasheets\":");
        try writeStringArray(w, group.datasheets);
        try w.writeByte('}');
    }
    try w.writeAll("],\"entities\":[");
    for (index.entities, 0..) |entity, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"type\":");
        try json_writer.writeScriptString(w, entity.kind);
        try w.writeAll(",\"label\":");
        try json_writer.writeScriptString(w, entity.label);
        try w.writeAll(",\"detail\":");
        try json_writer.writeScriptString(w, entity.detail);
        try w.writeAll(",\"refs\":");
        try writeStringArray(w, entity.refs);
        try w.writeAll(",\"nets\":");
        try writeStringArray(w, entity.nets);
        try w.writeAll(",\"keywords\":");
        try json_writer.writeScriptString(w, entity.keywords);
        try w.writeByte('}');
    }
    try w.writeAll("],\"nets\":[");
    for (index.nets, 0..) |net, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try json_writer.writeScriptString(w, net.name);
        try w.writeAll(",\"endpoints\":[");
        for (net.pins, 0..) |pin, pi| {
            if (pi > 0) try w.writeByte(',');
            const part = partForRef(index.parts, pin.ref_des);
            try w.writeAll("{\"ref\":");
            try json_writer.writeScriptString(w, pin.ref_des);
            try w.writeAll(",\"pin\":");
            try json_writer.writeScriptString(w, pin.pin);
            try w.writeAll(",\"component\":");
            try json_writer.writeScriptString(w, if (part) |p| p.component else "");
            try w.writeAll(",\"value\":");
            try json_writer.writeScriptString(w, if (part) |p| p.value else "");
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }
    try w.writeAll("],\"guides\":[");
    for (index.guides, 0..) |guide, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"slug\":");
        try json_writer.writeScriptString(w, guide.slug);
        try w.writeAll(",\"title\":");
        try json_writer.writeScriptString(w, guide.title);
        try w.writeAll(",\"body\":");
        try json_writer.writeScriptString(w, guide.body);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

fn renderPageWithOptions(allocator: std.mem.Allocator, name: []const u8, index: Index, opts: PageOptions) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    const w = &aw.writer;
    try w.writeAll("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">");
    try w.writeAll("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,viewport-fit=cover\">");
    try w.writeAll("<title>");
    try escape.writeXml(w, name);
    try w.writeAll(" — Assembly</title>");
    if (opts.meta.standalone) {
        try w.writeAll("<style>");
        try w.writeAll(@embedFile("assets/assembly_debug.css"));
        try w.writeAll("</style>");
    } else try w.print("<link rel=\"stylesheet\" href=\"/static/assembly_debug.css?v={x}\">", .{std.hash.Wyhash.hash(0, @embedFile("assets/assembly_debug.css"))});
    try w.writeAll("</head><body><header class=\"topbar\">");
    if (opts.meta.standalone)
        try w.writeAll("<span class=\"brand\">Released assembly</span>")
    else
        try w.writeAll("<a class=\"brand\" href=\"/\">netlisp</a>");
    try w.writeAll("<strong>");
    try escape.writeXml(w, name);
    try w.writeAll("</strong>");
    if (opts.meta.standalone) {
        try w.writeAll("<div class=\"release-identity\">");
        if (opts.meta.part_number.len > 0) {
            try w.writeAll("<span><b>PN</b> ");
            try escape.writeXml(w, opts.meta.part_number);
            try w.writeAll("</span>");
        }
        if (opts.meta.revision.len > 0) {
            try w.writeAll("<span><b>Rev</b> ");
            try escape.writeXml(w, opts.meta.revision);
            try w.writeAll("</span>");
        }
        try w.writeAll("<span class=\"release-fab-id\"><b>ID</b> ");
        try escape.writeXml(w, opts.meta.fab_id);
        try w.writeAll("</span></div>");
    } else {
        try w.writeAll("<nav aria-label=\"Design views\"><a href=\"/schematics/");
        try escape.writeXml(w, name);
        try w.writeAll("\">Schematic</a><a href=\"/pcb-layout/");
        try escape.writeXml(w, name);
        if (opts.layout) |selected| {
            try w.writeAll("?layout=");
            try writeUrlEncoded(w, selected);
        }
        try w.writeAll("\">PCB Layout</a><a href=\"/pcb-layout/");
        try escape.writeXml(w, name);
        try w.writeAll("?view=3d");
        if (opts.layout) |selected| {
            try w.writeAll("&amp;layout=");
            try writeUrlEncoded(w, selected);
        }
        try w.writeAll("\">3D</a><a class=\"active\" aria-current=\"page\">Assembly</a>");
        try w.writeAll("<a href=\"/thermal/");
        try writeUrlEncoded(w, name);
        try w.writeAll("\">Thermal</a><a href=\"/review/");
        try writeUrlEncoded(w, name);
        if (opts.layout) |selected| {
            try w.writeAll("?layout=");
            try writeUrlEncoded(w, selected);
        }
        try w.writeAll("\">Review</a></nav>");
    }
    try w.writeAll("</header><main class=\"workspace\"><aside class=\"panel\">");
    if (index.guides.len > 0) {
        try w.writeAll("<nav class=\"panel-tabs\" aria-label=\"Assembly workspace\">");
        try w.writeAll("<button id=\"parts-tab\" class=\"panel-tab active\" type=\"button\"");
        try w.writeAll(" aria-controls=\"assembly-panel\" aria-selected=\"true\">Parts</button>");
        try w.writeAll("<button id=\"guide-tab\" class=\"panel-tab\" type=\"button\"");
        try w.writeAll(" aria-controls=\"guide-workspace\" aria-selected=\"false\">Guide</button></nav>");
        // The workspace holds both guide states: the index of every discovered
        // guide, and the one opened guide with its way back to that index.
        try w.writeAll("<div id=\"guide-workspace\" class=\"guide-workspace\" hidden>");
        try w.writeAll("<nav id=\"guide-list\" class=\"guide-list\" aria-label=\"Rework guides\"></nav>");
        try w.writeAll("<div id=\"guide-view\" class=\"guide-view\" hidden>");
        try w.writeAll("<button id=\"guide-back\" class=\"guide-back\" type=\"button\">← All guides</button>");
        try w.writeAll("<article id=\"rework-guide\" class=\"rework-guide\"></article></div></div>");
    }
    try w.writeAll("<section id=\"assembly-panel\">");
    try w.writeAll("<label class=\"search-label\" for=\"assembly-search\">");
    try w.writeAll("Find anything on this board</label><input id=\"assembly-search\" type=\"search\"");
    try w.writeAll(" autocomplete=\"off\"");
    try w.writeAll(" placeholder=\"Part, refdes, net, test point…\" role=\"combobox\"");
    try w.writeAll(" aria-controls=\"search-results bom-list\" aria-autocomplete=\"list\"><div class=\"type-filters\"");
    try w.writeAll(" id=\"type-filters\"></div><div id=\"search-results\" class=\"result-list\" hidden></div>");
    try w.writeAll("<div class=\"parts-heading\"><h2>Parts</h2>");
    try w.writeAll("<label><input id=\"show-dnp\" type=\"checkbox\"> Show DNP</label></div>");
    try w.writeAll("<div id=\"bom-summary\" class=\"summary\"></div>");
    try w.writeAll("<div id=\"bom-list\" class=\"result-list\"></div></section>");
    try w.writeAll("<section id=\"selection\" class=\"selection\" hidden><div class=\"selection-head\"><div>");
    try w.writeAll("<span id=\"selection-kind\"></span><h2 id=\"selection-title\"></h2></div>");
    try w.writeAll("<button id=\"clear-selection\" type=\"button\">Clear</button></div>");
    try w.writeAll("<p id=\"selection-detail\"></p>");
    try w.writeAll("<p id=\"selection-net\" hidden></p>");
    try w.writeAll("<div id=\"selection-datasheets\" hidden></div>");
    try w.writeAll("<div id=\"endpoint-list\"></div></section></aside><section class=\"board-pane\">");
    try w.writeAll("<div class=\"board-area\">");
    try w.writeAll("<div class=\"board-controls\" aria-label=\"Board controls\">");
    if (!opts.meta.standalone) {
        try w.writeAll("<label class=\"model-toggle\" title=\"Load cached component model pictures\">");
        try w.writeAll("<input id=\"load-3d-models\" type=\"checkbox\"> 3D models</label>");
    }
    try w.writeAll("<button id=\"cam-review\" type=\"button\" aria-pressed=\"false\" aria-describedby=\"cam-review-status\"");
    try w.writeAll(" title=\"Load and inspect the exact generated Gerber and Excellon files\">CAM Review</button>");
    try w.writeAll("<span id=\"cam-review-status\" class=\"cam-review-status\" role=\"status\" aria-live=\"polite\" data-state=\"semantic\">Fast board</span>");
    try w.writeAll("<button id=\"measure-tool\" type=\"button\" aria-pressed=\"false\" aria-describedby=\"measure-status\"");
    try w.writeAll(" title=\"Measure exact Gerber geometry: drag from one copper edge to another\">📏 Measure</button>");
    try w.writeAll("<span id=\"measure-status\" class=\"measure-status\" role=\"status\" aria-live=\"polite\">Edge-to-edge</span>");
    try w.writeAll("<details id=\"cam-layer-menu\" class=\"layer-menu\" hidden><summary>CAM Layers</summary><div class=\"layer-menu-pop\">");
    try w.writeAll("<label><input type=\"checkbox\" data-cam-layer=\"copper\" checked> Face copper</label>");
    // The iframe fills this from its shared physical layer table. Keeping the
    // stack in one place means a 4-layer board gets In1/In2 while a 6-layer
    // board gets In1..In4, with no second layer-name table in this shell.
    try w.writeAll("<div id=\"inner-copper-layers\"></div>");
    try w.writeAll("<label><input type=\"checkbox\" data-cam-layer=\"mask\" checked> Solder mask</label>");
    try w.writeAll("<label><input type=\"checkbox\" data-cam-layer=\"paste\"> Paste stencil</label>");
    try w.writeAll("<label><input type=\"checkbox\" data-cam-layer=\"silk\" checked> Silkscreen</label>");
    try w.writeAll("<label><input type=\"checkbox\" data-cam-layer=\"drills\" checked> Drills</label>");
    try w.writeAll("<label><input type=\"checkbox\" data-cam-layer=\"outline\" checked> Board outline</label>");
    try w.writeAll("<label><input type=\"checkbox\" data-cam-layer=\"components\" checked> Components</label>");
    try w.writeAll("</div></details>");
    try w.writeAll("<button id=\"board-side\" type=\"button\">Top side</button>");
    try w.writeAll("<button id=\"board-rotate-left\" type=\"button\" title=\"Rotate left 90 degrees\">↶ 90°</button>");
    try w.writeAll("<button id=\"board-rotate-right\" type=\"button\"");
    try w.writeAll(" title=\"Rotate right 90 degrees\">↷ 90°</button>");
    try w.writeAll("<span id=\"board-orientation\">Top · 0°</span></div>");
    try w.writeAll("<div id=\"board-stage\" class=\"board-stage\">");
    try w.writeAll("<iframe id=\"pcb-frame\" title=\"Read-only PCB layout\"");
    if (!opts.meta.standalone) {
        try w.writeAll(" src=\"/pcb-layout/");
        try escape.writeXml(w, name);
        try w.writeAll("?embed=1&amp;review=1&amp;drc=0");
        if (opts.layout) |selected| {
            try w.writeAll("&amp;layout=");
            try writeUrlEncoded(w, selected);
        }
        if (opts.browser_benchmark) try w.writeAll("&amp;fbench=quick&amp;gpu=1");
        try w.writeAll("\"");
    }
    try w.writeAll("></iframe></div></div>");
    try w.writeAll("</section></main>");
    try w.writeAll("<script id=\"assembly-debug-data\" type=\"application/json\">");
    try writeIndexJson(w, index, opts.meta);
    try w.writeAll("</script>");
    if (opts.meta.standalone) {
        try w.writeAll("<script>");
        try w.writeAll(@embedFile("assets/assembly_debug.js"));
        try w.writeAll("</script><script id=\"assembly-board-document\" type=\"application/json\">");
        try json_writer.writeScriptString(w, opts.board_html orelse "");
        try w.writeAll("</script><script>(function(){var f=document.getElementById('pcb-frame'),d=document.getElementById('assembly-board-document');if(f&&d)f.srcdoc=JSON.parse(d.textContent||'\"\"');})();</script>");
    } else try w.print("<script src=\"/static/assembly_debug.js?v={x}\"></script>", .{std.hash.Wyhash.hash(0, @embedFile("assets/assembly_debug.js"))});
    try w.writeAll("</body></html>");
    return aw.written();
}

fn renderPage(allocator: std.mem.Allocator, name: []const u8, index: Index, layout: ?[]const u8, browser_benchmark: bool) ![]const u8 {
    return renderPageWithOptions(allocator, name, index, .{
        .layout = layout,
        .browser_benchmark = browser_benchmark,
        .meta = .{ .name = name },
    });
}

/// Build one offline, immutable Assembly workspace for a fabrication release.
/// All operator data, guides, UI assets and the exact board review document are
/// embedded in the returned HTML; opening it performs no server lookup.
pub fn renderReleasePage(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    block: *const env_mod.DesignBlock,
    board_html: []const u8,
    identity: ReleaseIdentity,
) HandlerError![]const u8 {
    const index = try buildPageIndex(allocator, project_dir, name, block);
    return renderPageWithOptions(allocator, name, index, .{
        .meta = .{
            .name = name,
            .part_number = identity.part_number,
            .revision = identity.revision,
            .fab_id = identity.fab_id,
            .release_token = identity.release_token,
            .standalone = true,
        },
        .board_html = board_html,
    });
}

/// Build the exact index embedded into both live and benchmark page renders.
fn buildPageIndex(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    block: *const env_mod.DesignBlock,
) !Index {
    const bom_path = paths.designSiblingPath(allocator, project_dir, name, ".bom") catch null;
    if (bom_path) |path| {
        defer allocator.free(path);
        // The BOM is the annotation ledger for allocator-owned refdes. Apply
        // it through the identity-validating read-only path before flattening;
        // joining raw rows to a fresh source-order evaluation by refdes alone
        // can attach nearly every MPN to the wrong part after an insertion.
        bom.applyExisting(allocator, block, path, project_dir) catch |err| {
            log.warn("assembly: could not apply existing BOM for {s}: {s}", .{ name, @errorName(err) });
        };
        const entries = bom.loadBom(allocator, path) catch &.{};
        var index = try buildIndex(allocator, project_dir, block, entries);
        index.guides = rework_guide.loadAll(allocator, project_dir, name);
        return index;
    }
    var index = try buildIndex(allocator, project_dir, block, &.{});
    index.guides = rework_guide.loadAll(allocator, project_dir, name);
    return index;
}

/// Render the default assembly workspace without consulting or populating the
/// long-lived HTML cache. The page-latency gate uses this request-less seam so
/// every repetition measures the same cold evaluation, BOM/search indexing,
/// guide discovery and HTML serialization as `/assembly-debug/:name`.
pub fn benchColdPage(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?usize {
    if (!isSafeName(name)) return null;
    const source_path = paths.designSourcePath(allocator, project_dir, name) catch return null;

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const value = eval.evalFile(source_path) catch return null;
    const block: *env_mod.DesignBlock = switch (value) {
        .design_block => |design| design,
        else => return null,
    };

    const index = buildPageIndex(allocator, project_dir, name, block) catch return null;
    const html = renderPage(allocator, name, index, null, false) catch return null;
    return html.len;
}

/// GET /assembly-debug/:name — evaluate and render the read-only workspace.
pub fn assemblyDebugPage(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const allocator = req.arena;
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    if (!isSafeName(name)) {
        res.status = 404;
        return;
    }
    res.header("Cache-Control", "no-store");
    var cache_version: ?u32 = null;
    if (ctx.state.caches.assembly_pages.serve(
        .{ .scratch = allocator, .name = name, .live_version = serve_root.getLiveVersion(name) },
        req,
        res,
        &cache_version,
    )) return;
    const layout = queryOpt(req, "layout");
    const browser_benchmark = if (queryOpt(req, "fbench")) |value| std.mem.eql(u8, value, "quick") else false;
    const source_path = paths.designSourcePath(allocator, ctx.project_dir, name) catch {
        res.status = 404;
        return;
    };

    var eval = Evaluator.init(allocator, ctx.project_dir);
    defer eval.deinit();
    defer ctx.state.caches.assembly_pages.store(.{
        .scratch = allocator,
        .project_dir = ctx.project_dir,
        .name = name,
        .req = req,
        .eval = &eval,
        .res = res,
        .live_version = cache_version,
        .current_version = serve_root.getLiveVersion(name),
    });
    const value = eval.evalFile(source_path) catch |err| {
        res.status = 500;
        res.content_type = .HTML;
        res.body = try std.fmt.allocPrint(allocator, "Could not evaluate design: {s}", .{@errorName(err)});
        return;
    };
    const block: *env_mod.DesignBlock = switch (value) {
        .design_block => |design| design,
        else => {
            res.status = 404;
            return;
        },
    };

    const index = buildPageIndex(allocator, ctx.project_dir, name, block) catch |err| {
        res.status = 500;
        res.body = try std.fmt.allocPrint(allocator, "Could not index design: {s}", .{@errorName(err)});
        return;
    };
    res.content_type = .HTML;
    res.body = try renderPage(allocator, name, index, layout, browser_benchmark);
}

fn queryOpt(req: *httpz.Request, key: []const u8) ?[]const u8 {
    const q = req.query() catch return null;
    const value = q.get(key) orelse return null;
    return if (value.len == 0) null else value;
}

fn writeUrlEncoded(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| {
        const safe = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~';
        if (safe) try w.writeByte(c) else try w.print("%{X:0>2}", .{c});
    }
}

test "safe design names reject traversal and markup" {
    try std.testing.expect(isSafeName("motor-control_r2.1"));
    try std.testing.expect(!isSafeName("../secret"));
    try std.testing.expect(!isSafeName("board<script>"));
    try std.testing.expect(!isSafeName("nested/board"));
}

// spec: Web Server - assembly review groups sourceable parts by normalized MPN and records DNP placements
test "BOM groups normalized MPNs and records mixed assembly data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const groups = try buildBomGroups(arena.allocator(), &.{
        .{ .ref = "R1", .component = "res", .value = "10k", .footprint = "0402", .mpn = " RC0402-10K " },
        .{
            .ref = "R2",
            .component = "res",
            .value = "10k",
            .footprint = "0402",
            .mpn = "rc0402-10k",
            .manufacturer = "Yageo",
            .dnp = true,
        },
        .{ .ref = "R3", .component = "res", .value = "12k", .footprint = "0402", .mpn = "RC0402-10K" },
    });
    try std.testing.expectEqual(@as(usize, 1), groups.len);
    try std.testing.expectEqual(@as(usize, 3), groups[0].refs.len);
    try std.testing.expectEqual(@as(usize, 1), groups[0].dnp_count);
    try std.testing.expectEqualStrings("Yageo", groups[0].manufacturer);
    try std.testing.expect(groups[0].conflict);
}

test "BOM fallback does not collapse unrelated missing MPN parts and excludes test points" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const groups = try buildBomGroups(arena.allocator(), &.{
        .{ .ref = "C1", .component = "cap", .value = "100n", .footprint = "0402" },
        .{ .ref = "C2", .component = "cap", .value = "100n", .footprint = "0402" },
        .{ .ref = "C3", .component = "cap", .value = "1u", .footprint = "0603" },
        .{ .ref = "TP1", .component = "testpoint-smd", .value = "", .footprint = "tp", .testpoint = true },
    });
    try std.testing.expectEqual(@as(usize, 2), groups.len);
    try std.testing.expectEqual(@as(usize, 3), groups[0].refs.len + groups[1].refs.len);
    try std.testing.expect(!std.mem.eql(u8, groups[0].refs[0], "TP1"));
    try std.testing.expect(!std.mem.eql(u8, groups[1].refs[0], "TP1"));
}

test "evaluated BOM properties group exact hierarchical refs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const first_props = [_]env_mod.Property{
        .{ .key = "mpn", .value = "RC-SHARED" },
        .{ .key = "manufacturer", .value = "Yageo" },
    };
    const second_props = [_]env_mod.Property{
        .{ .key = "mpn", .value = "rc-shared" },
    };
    const flat = [_]bom.FlatInfo{
        .{
            .ref_des = "reg/R1",
            .component = "res",
            .footprint = "0402",
            .value = "10k",
            .attrs = &.{},
            .nets = &.{},
            .properties = &first_props,
        },
        .{
            .ref_des = "sense/R1",
            .component = "res",
            .footprint = "0603",
            .value = "12k",
            .attrs = &.{},
            .nets = &.{},
            .properties = &second_props,
        },
    };
    const parts = try partsFromFlat(arena.allocator(), &flat, &.{}, .empty);
    const groups = try buildBomGroups(arena.allocator(), parts);
    try std.testing.expectEqual(@as(usize, 1), groups.len);
    try std.testing.expectEqual(@as(usize, 2), groups[0].refs.len);
    try std.testing.expectEqualStrings("Yageo", groups[0].manufacturer);
}

// spec: Web Server - assembly applies the persisted BOM through stable source identity before grouping, so inserting a newly auto-numbered part cannot shift MPNs onto unrelated refdes
test "assembly BOM keeps MPNs on stable identities after refdes insertion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.createDirPath(std.testing.io, "src/demo");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/indicator.sexp",
        .data =
        \\(component indicator
        \\  (footprint "indicator-fp")
        \\  (manufacturer "Acme")
        \\  (mpn "LED-1"))
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/pushbutton.sexp",
        .data =
        \\(component pushbutton
        \\  (footprint "button-fp")
        \\  (manufacturer "Acme")
        \\  (mpn "SW-1"))
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/connector.sexp",
        .data =
        \\(component connector
        \\  (footprint "connector-fp")
        \\  (manufacturer "Acme")
        \\  (mpn "CONN-1"))
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/demo/demo.sexp",
        .data =
        \\(import indicator pushbutton)
        \\(design-block "Demo"
        \\  (instance "status" indicator (id a1000001) (pin 1 "A"))
        \\  (instance "reset" pushbutton (id a1000002) (pin 1 "B")))
        ,
    });
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    const design_path = try std.fmt.allocPrint(alloc, "{s}/src/demo/demo.sexp", .{project_dir});
    const bom_path = try std.fmt.allocPrint(alloc, "{s}/src/demo/demo.bom", .{project_dir});
    {
        var evaluator = Evaluator.init(alloc, project_dir);
        defer evaluator.deinit();
        const evaluated = try evaluator.evalFile(design_path);
        const block = try testDesignBlock(evaluated);
        try bom.resolveIdentities(alloc, block, bom_path, project_dir);
    }

    // A fresh evaluation initially calls the inserted connector U1 and shifts
    // both existing parts. The persisted IDs must restore LED-1 to U1 and SW-1
    // to U2 before the assembly page reads their properties.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/demo/demo.sexp",
        .data =
        \\(import connector indicator pushbutton)
        \\(design-block "Demo"
        \\  (instance "io" connector (id a1000003) (pin 1 "C"))
        \\  (instance "status" indicator (id a1000001) (pin 1 "A"))
        \\  (instance "reset" pushbutton (id a1000002) (pin 1 "B")))
        ,
    });
    var evaluator = Evaluator.init(alloc, project_dir);
    defer evaluator.deinit();
    const evaluated = try evaluator.evalFile(design_path);
    const block = try testDesignBlock(evaluated);
    const index = try buildPageIndex(alloc, project_dir, "demo", block);
    try std.testing.expectEqual(@as(usize, 3), index.bom_groups.len);
    for (index.bom_groups) |group| {
        try std.testing.expect(group.mpn.len > 0);
        try std.testing.expect(!group.conflict);
        try std.testing.expectEqual(@as(usize, 1), group.refs.len);
        if (std.mem.eql(u8, group.mpn, "LED-1"))
            try std.testing.expectEqualStrings("U1", group.refs[0])
        else if (std.mem.eql(u8, group.mpn, "SW-1"))
            try std.testing.expectEqualStrings("U2", group.refs[0])
        else if (std.mem.eql(u8, group.mpn, "CONN-1"))
            try std.testing.expectEqualStrings("J1", group.refs[0])
        else
            return error.TestUnexpectedResult;
    }
}

test "recursive sections include nested refs and explicitly hosted subcircuits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const child_instances = [_]env_mod.Instance{.{
        .ref_des = "C1",
        .component = "cap",
        .value = "1u",
        .footprint = "0402",
        .symbol = "",
    }};
    var child = env_mod.DesignBlock{
        .name = "LDO",
        .instances = &child_instances,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const nested_instances = [_]env_mod.Instance{.{
        .ref_des = "R1",
        .component = "res",
        .value = "10k",
        .footprint = "0402",
        .symbol = "",
    }};
    const nested = [_]env_mod.Section{.{ .name = "Sense", .instances = &nested_instances }};
    const section = env_mod.Section{
        .name = "Power",
        .sub_sections = &nested,
        .hosts = &.{"reg"},
    };
    const subs = [_]env_mod.SubBlock{.{ .name = "reg", .block = &child }};
    const block = env_mod.DesignBlock{
        .name = "Board",
        .instances = &nested_instances,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &subs,
        .sections = &.{section},
    };
    var refs: std.ArrayList([]const u8) = .empty;
    try collectSectionRefs(alloc, &block, section, "", &refs);
    var saw_r = false;
    var saw_c = false;
    for (refs.items) |ref| {
        saw_r = saw_r or std.mem.eql(u8, ref, "R1");
        saw_c = saw_c or std.mem.eql(u8, ref, "reg/C1");
    }
    try std.testing.expect(saw_r and saw_c);
}

// spec: Web Server - assembly review hides scores, DRC, and clearance, loads 3D models only on request, preserves board appearance when component picks update the sidebar, and retains middle-pan and scene-only orientation
// spec: Web Server - The Assembly CAM Review toggle lazy-loads dependency-cached Gerber/Excellon artwork, can return instantly to the semantic board, and exposes CAM layer controls only while exact files are active
test "page HTML is read-only and carries embed, data, and focus assets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const html = try renderPage(arena.allocator(), "demo", .{
        .parts = &.{},
        .bom_groups = &.{},
        .entities = &.{},
        .nets = &.{},
    }, null, false);
    try std.testing.expect(std.mem.indexOf(u8, html, "/pcb-layout/demo?embed=1&amp;review=1&amp;drc=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "model_sprites=1") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "assembly-debug-data") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "/static/assembly_debug.js?v=") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"board-side\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"board-rotate-right\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"load-3d-models\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"cam-review\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"cam-review-status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"measure-tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"measure-status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"cam-layer-menu\" class=\"layer-menu\" hidden") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"layer-menu\"") != null);
    try std.testing.expectEqual(@as(usize, 7), std.mem.count(u8, html, "data-cam-layer="));
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"inner-copper-layers\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "> Inner copper</label>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"assembly-search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "data-mode=") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "Debug / Bring-up") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "method=\"post\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "contenteditable") == null);
    const selected = try renderPage(arena.allocator(), "demo", .{
        .parts = &.{},
        .bom_groups = &.{},
        .entities = &.{},
        .nets = &.{},
    }, "an2548-div4-post-ldo", false);
    try std.testing.expect(std.mem.indexOf(u8, selected, "/pcb-layout/demo?layout=an2548-div4-post-ldo\">PCB Layout") != null);
    try std.testing.expect(std.mem.indexOf(u8, selected, "/pcb-layout/demo?view=3d&amp;layout=an2548-div4-post-ldo\">3D") != null);
    try std.testing.expect(std.mem.indexOf(u8, selected, "/review/demo?layout=an2548-div4-post-ldo\">Review") != null);
    try std.testing.expect(std.mem.indexOf(u8, selected, "/pcb-layout/demo?embed=1&amp;review=1&amp;drc=0&amp;layout=an2548-div4-post-ldo") != null);
    const benchmark = try renderPage(arena.allocator(), "demo", .{
        .parts = &.{},
        .bom_groups = &.{},
        .entities = &.{},
        .nets = &.{},
    }, null, true);
    try std.testing.expect(std.mem.indexOf(u8, benchmark, "?embed=1&amp;review=1&amp;drc=0&amp;fbench=quick&amp;gpu=1") != null);
    const js = @embedFile("assets/assembly_debug.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "item.type !== 'bom'") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "applyBoardOrientation") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "rotation: boardRotation") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "url.searchParams.set('model_sprites', '1')") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "url.searchParams.delete('model_sprites')") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "netlisp-pcb-cam-visibility") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "netlisp-pcb-cam-mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "netlisp-pcb-cam-state") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "camReviewRequested = new URLSearchParams(window.location.search).get('cam') === '1'") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "assembly-cam-layers:") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "populateInnerCopperLayers(payload.innerLayers)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "frame.contentWindow.PCBReviewInnerLayers") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "frame.style.transform") == null);
}

// spec: Web Server - Assembly exposes a read-only Gerber ruler that snaps both endpoints to visible exact artwork edges, measures in world millimetres, reports fine mm and mil values, uses compact endpoint dots, and remains available in frozen release pages
test "assembly measure tool drives the read-only board ruler" {
    const shell_js = @embedFile("assets/assembly_debug.js");
    const board_js = @embedFile("assets/pcb_board.js");
    const css = @embedFile("assets/assembly_debug.css");
    const layout_css = @embedFile("assets/pcb_layout.css");
    const Check = struct { source: []const u8, marker: []const u8 };
    const checks = [_]Check{
        .{ .source = shell_js, .marker = "frame.contentWindow.PCBReviewMeasureMode" },
        .{ .source = shell_js, .marker = "netlisp-pcb-measure-mode" },
        .{ .source = shell_js, .marker = "netlisp-pcb-measure-state" },
        .{ .source = shell_js, .marker = "formatMeasurement(payload)" },
        .{ .source = board_js, .marker = "window.PCBReviewMeasureMode=rulerArm" },
        .{ .source = board_js, .marker = "type:\"netlisp-pcb-measure-state\"" },
        .{ .source = board_js, .marker = "var m=mm(ev),p=!RO&&selRef&&partByRef(selRef)" },
        .{ .source = board_js, .marker = "function rulerCamSnap(m)" },
        .{ .source = board_js, .marker = "snap=p?null:rulerCamSnap(m)" },
        .{ .source = board_js, .marker = "rulerDraw.b=snap||m" },
        .{ .source = board_js, .marker = "function rulerPointRadius()" },
        .{ .source = layout_css, .marker = ".pcb-ruler-point{fill:#001023;stroke:#ffd33d;stroke-width:1.2;vector-effect:non-scaling-stroke" },
        .{ .source = css, .marker = ".measure-status[data-state=\"active\"]" },
    };
    for (checks) |check| try std.testing.expect(std.mem.indexOf(u8, check.source, check.marker) != null);
}

// spec: Web Server - The Assembly CAM Review control visibly distinguishes fast, loading, exact, and failed states and applies same-document mode changes directly with a message fallback
test "CAM Review exposes durable state and a direct same-document control seam" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const html = try renderPage(arena.allocator(), "demo", .{
        .parts = &.{},
        .bom_groups = &.{},
        .entities = &.{},
        .nets = &.{},
    }, null, false);
    const shell_js = @embedFile("assets/assembly_debug.js");
    const board_js = @embedFile("assets/pcb_board.js");
    const Check = struct { source: []const u8, marker: []const u8 };
    const checks = [_]Check{
        .{ .source = html, .marker = "role=\"status\" aria-live=\"polite\"" },
        .{ .source = shell_js, .marker = "Retry CAM Review" },
        .{ .source = shell_js, .marker = "Exact CAM active" },
        .{ .source = shell_js, .marker = "frame.contentWindow.PCBReviewCamMode" },
        .{ .source = shell_js, .marker = "frame.contentWindow.postMessage" },
        .{ .source = board_js, .marker = "window.PCBReviewCamMode=camReviewSet" },
    };
    for (checks) |check| try std.testing.expect(std.mem.indexOf(u8, check.source, check.marker) != null);
}

// spec: Web Server - assembly copper pours retain even-odd antipad holes around foreign traces, vias, and pads
test "assembly viewer retains copper-pour antipad holes" {
    const js = @embedFile("assets/pcb_board.js");
    const branch_start = std.mem.indexOf(u8, js, "if(PHYSICAL_REVIEW){var netFocus") orelse
        return error.AssemblyPourBranchMissing;
    const branch_end_rel = std.mem.indexOf(u8, js[branch_start..], "paintFocusedPlanes(ctx,k);return;}") orelse
        return error.AssemblyPourBranchMissing;
    const review_branch = js[branch_start .. branch_start + branch_end_rel];

    try std.testing.expect(std.mem.indexOf(u8, review_branch, "ctx.fill(aq.fillPath,\"evenodd\")") != null);
}

// spec: Web Server - assembly review uses a fixed translucent copper wash so the PCB editor's persisted pour-opacity slider cannot obscure soldermask
test "assembly viewer ignores PCB editor copper-pour opacity" {
    const js = @embedFile("assets/pcb_board.js");
    const branch_start = std.mem.indexOf(u8, js, "if(PHYSICAL_REVIEW){var netFocus") orelse
        return error.AssemblyPourBranchMissing;
    const branch_end_rel = std.mem.indexOf(u8, js[branch_start..], "paintFocusedPlanes(ctx,k);return;}") orelse
        return error.AssemblyPourBranchMissing;
    const review_branch = js[branch_start .. branch_start + branch_end_rel];

    try std.testing.expect(std.mem.indexOf(u8, review_branch, "ctx.globalAlpha=netFocus?(hit?0.62:0.05):0.20") != null);
    try std.testing.expect(std.mem.indexOf(u8, review_branch, "viewSt.pourOp") == null);
}

// spec: Web Server - assembly review derives bare via copper only by clipping it through mask-opening geometry, including the exact authored-width board-edge band
test "assembly viewer clips vias through mask opening geometry" {
    const board_js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function paintPerimeterMaskOpening(ctx,L,mw)") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "Number(PCB.rules&&PCB.rules.perimeter_mask_width)") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "ctx.clip();physicalBoardPath(ctx)") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "ctx.lineWidth=2*mw*S") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "perimeterMaskSameNet(t.net,pour)") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function isPerimeterVia(v)") == null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "viaReliefOf") == null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "including via rings, through these polygons") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "mc.globalCompositeOperation=\"source-atop\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function paintMaskRelief(ctx)") != null);
}

test "assembly target UUID falls back to deterministic source identity" {
    const info: bom.FlatInfo = .{
        .ref_des = "synth/R44",
        .component = "res",
        .footprint = "0201",
        .value = "100R",
        .attrs = &.{},
        .nets = &.{},
        .properties = &.{},
        .id = "e49202be",
    };
    const uuid = try uuidForPart(std.testing.allocator, &.{}, info);
    defer std.testing.allocator.free(uuid);
    try std.testing.expectEqualStrings(
        "0b42c42d-94e1-5fa1-a6b5-22bed47f9b63",
        uuid,
    );
}

// spec: Web Server - assembly rework guides bind stable component UUID, footprint-pad, and net targets to exact read-only board focus and retain board context when centering component and pad targets
test "assembly rework guides expose interactive Markdown targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const html = try renderPage(arena.allocator(), "demo", .{
        .parts = &.{.{
            .ref = "synth/R44",
            .uuid = "0b42c42d-94e1-5fa1-a6b5-22bed47f9b63",
            .component = "res",
            .value = "100R",
            .footprint = "0201",
        }},
        .bom_groups = &.{},
        .entities = &.{},
        .nets = &.{},
        .guides = &.{.{
            .slug = "demo",
            .title = "Bodge",
            .body = "# Bodge\nReplace [[uuid:0b42c42d-94e1-5fa1-a6b5-22bed47f9b63|R44]].",
        }},
    }, null, false);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"guide-tab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"parts-tab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"rework-guide\"") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        html,
        "\"parts\":[{\"uuid\":\"0b42c42d-94e1-5fa1-a6b5-22bed47f9b63\",\"ref\":\"synth/R44\"}]",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        html,
        "\"body\":\"# Bodge\\nReplace [[uuid:0b42c42d-94e1-5fa1-a6b5-22bed47f9b63|R44]]",
    ) != null);

    const js = @embedFile("assets/assembly_debug.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "\\[\\[(uuid|ref|pin|net):") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "guideUuidMatches") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "resolveGuideTarget") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "pins: refs.map") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "activeGuideFocus.pins") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "context: context === true") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "target.type !== 'net'") != null);

    const board_js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function reviewResolvePins") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function reviewFocusPad") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "selectedPins:f.pins") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "reviewBoundsBox(b,wrect(i,pd))") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "REVIEW_CONTEXT_FRACTION=0.42") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "reviewFit(!!spec.context)") != null);
}

// spec: Web Server - the assembly guide panel opens as a clickable list of guide titles, renders one guide at a time, and returns to that list from any guide
test "assembly guide panel lists its guides and opens one at a time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const html = try renderPage(arena.allocator(), "demo", .{
        .parts = &.{},
        .bom_groups = &.{},
        .entities = &.{},
        .nets = &.{},
        .guides = &.{
            .{ .slug = "demo", .title = "Rev A rework", .body = "# Rev A rework" },
            .{ .slug = "demo-bypass", .title = "ADF4159 bypass", .body = "# ADF4159 bypass" },
        },
    }, null, false);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"guide-list\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"guide-view\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"guide-back\"") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        html,
        "\"guides\":[{\"slug\":\"demo\",\"title\":\"Rev A rework\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "\"slug\":\"demo-bypass\"") != null);

    const js = @embedFile("assets/assembly_debug.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "function renderGuideList()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function openGuide(index") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function showGuideList()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "guideBack.addEventListener('click', showGuideList)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if (guides.length === 1) openGuide(0, false);") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if (sidebarPanel) sidebarPanel.scrollTop = 0;") != null);
    const css = @embedFile("assets/assembly_debug.css");
    try std.testing.expect(std.mem.indexOf(u8, css, ".guide-list-item") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".guide-back") != null);
    // An author `display` beats the UA `[hidden]` rule, so an opened guide only
    // replaces the list when the list opts back out of its own grid.
    try std.testing.expect(std.mem.indexOf(u8, css, ".guide-list[hidden] { display: none; }") != null);
}

test "assembly client filters DNP refs from mixed groups unless explicitly shown" {
    const js = @embedFile("assets/assembly_debug.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "new Set(group.dnp_refs || [])") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "filter((ref) => !hidden.has(ref))") != null);
}

// spec: Web Server - assembly BOM rows sort by visible quantity and show top, bottom, or both placement badges
test "assembly BOM orders quantity first and labels placement sides" {
    const js = @embedFile("assets/assembly_debug.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "visibleQty(b) - visibleQty(a)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "side-badge side-${side}") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "payload.type === 'netlisp-pcb-parts'") != null);
    const css = @embedFile("assets/assembly_debug.css");
    try std.testing.expect(std.mem.indexOf(u8, css, ".side-top") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".side-bottom") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".side-both") != null);
}

// spec: Web Server - assembly BOM rows expose stable kit indices, allow their text to be copied, and mark the exact refdes picked on the board
test "assembly BOM supports indexed kitting and exact copied refdes feedback" {
    const js = @embedFile("assets/assembly_debug.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "kitIndex.textContent = `#${kitNumber}`") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "const kitNumberByKey = new Map") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "button.setAttribute('role', 'button')") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function hasSelectedText(row)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "exactRef: ref") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "markExactRef(sourceNode, item.exactRef)") != null);
    const css = @embedFile("assets/assembly_debug.css");
    try std.testing.expect(std.mem.indexOf(u8, css, ".bom-row { user-select: text; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".result-ref.exact-selected") != null);
}

// spec: Web Server - assembly and board labels show globally unique leaf refdes without internal sub-block path prefixes
test "assembly and board labels omit internal refdes paths" {
    const assembly_js = @embedFile("assets/assembly_debug.js");
    try std.testing.expect(std.mem.indexOf(u8, assembly_js, "refNode.textContent = leaf(ref)") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembly_js, "function displayLabel(item)") != null);
    const board_js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function refLabel(ref)") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "shownRef=refLabel(p.ref)") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "findCandidate(\"part\",refLabel(p.ref)") != null);
}

// spec: Web Server - assembly/debug board focus covers direct copper picks, refs, tracks, vias, pours, zones, and plane layers while excluding keepouts from connectivity
test "PCB review asset exposes complete ref and net focus coverage" {
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "window.PCBReviewFocus") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "netlisp-pcb-focus-result") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "PCB.tracks") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "PCB.vias") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "reviewCopperAreas") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "reviewPlaneLayers") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "a.q.keepout") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "netlisp-pcb-net-picked") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "netlisp-pcb-ref-picked") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "netlisp-pcb-orientation") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "sceneShell.contains(ev.target)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "if(PHYSICAL_REVIEW)return;") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "PHYSICAL_REVIEW&&!reviewFocusHasNets()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "exactPad=(RO||viewSt.filt.pad)?padHitAt") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "svgScreenInverse") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "window.addEventListener(\"mousemove\"") != null);
}

// spec: Web Server - assembly component and pad picks reveal and highlight the owning component in the active sidebar, while placement selection preserves the board viewport
test "assembly client reveals the BOM row for a board-picked component" {
    const js = @embedFile("assets/assembly_debug.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "payload.type === 'netlisp-pcb-ref-picked'") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "bomGroupForRef(payload.ref)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function revealRow(row)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "revealRow(sourceNode);") != null);
    const board_js = @embedFile("assets/pcb_board.js");
    const focus_helper = std.mem.indexOf(u8, board_js, "function focusBoardShortcuts") orelse return error.TestUnexpectedResult;
    const editor_block = std.mem.indexOf(u8, board_js, "if(!RO){\nvar drag=null") orelse return error.TestUnexpectedResult;
    try std.testing.expect(focus_helper < editor_block);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "!viewSt.filt.pad&&!PHYSICAL_REVIEW") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "PHYSICAL_REVIEW||viewSt.filt.fp") != null);
}

// spec: Web Server - assembly component hit-testing only considers placements on the board face currently being viewed
test "assembly review only picks parts on the shown side" {
    const board_js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function reviewPartOnShownSide(p)") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, board_js, "if(!partOnVisibleFace(p)||!reviewPartOnShownSide(p))continue;"));
    const client_js = @embedFile("assets/assembly_debug.js");
    try std.testing.expect(std.mem.indexOf(u8, client_js, "if (pickedSide && pickedSide !== boardSide) return;") != null);
}

// spec: Web Server - The read-only assembly review opens on an outer board face even when the editor was left on an inner layer
test "assembly review clamps a persisted inner active layer to an outer face" {
    const board_js = @embedFile("assets/pcb_board.js");
    // The clamp runs at startup, before the first paint, and touches only the
    // live variables — no viewSave() on that path, so the editor's own layer
    // choice survives the visit.
    const clamp = "if(PHYSICAL_REVIEW&&activeLayer>1){activeLayer=0;activeStack=(stackForSignal(0)||STACK[0]).i;}";
    const at = std.mem.indexOf(u8, board_js, clamp) orelse return error.TestUnexpectedResult;
    const save_decl = std.mem.indexOf(u8, board_js, "function viewSave()") orelse return error.TestUnexpectedResult;
    try std.testing.expect(save_decl < at);
    const next_save = std.mem.indexOfPos(u8, board_js, at, "viewSave()") orelse return error.TestUnexpectedResult;
    try std.testing.expect(next_save >= at + clamp.len);
    // What the clamp exists for: review's painters gate every part, silk and
    // ref-des on the part's own face matching the active layer.
    try std.testing.expect(std.mem.indexOf(u8, board_js, "(!PHYSICAL_REVIEW||(bot?1:0)===activeLayer)") != null);
}

// spec: Web Server - assembly refdes omit connection tables, repeat pad picks select nets, and review copper picks omit reports
test "assembly component picks drill into nets without review popovers" {
    const js = @embedFile("assets/assembly_debug.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "item.type === 'net' ? item.nets : []") != null);
    const board_js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, board_js, "reviewPickedRefCur===reviewText(p.ref)&&pd&&pd.net") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "reviewPickedRefCur=null;selNet(pd.net);return;") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "if(PHYSICAL_REVIEW){") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "insp=null;inspPopClose();paintSoon();return;") != null);
}

// spec: Web Server - assembly selected components render visible pad 1 in red for placement orientation
test "assembly selected components mark pad one" {
    const board_js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, board_js, "pin1:\"#ff3b30\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function reviewPinOne(i,pd)") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "String(pd.num||\"\").trim()===\"1\"") != null);
    // The fill acquired a pad-target case while this test was unreachable from
    // the test root; the pad-1 branch it guards is unchanged.
    try std.testing.expect(std.mem.indexOf(
        u8,
        board_js,
        "ctx.fillStyle=targetPad?\"#ff7b72\":PH.pin1;padPath(ctx,pd);ctx.fill();",
    ) != null);
    const sprite = std.mem.indexOf(u8, board_js, "ctx.drawImage(sprite.image") orelse return error.TestUnexpectedResult;
    const marker = std.mem.indexOf(u8, board_js, "PH.pin1;padPath(ctx,pd);ctx.fill();") orelse return error.TestUnexpectedResult;
    try std.testing.expect(sprite < marker);
}

// spec: Web Server - assembly sidebar selections sit beside their row without scrolling a list the row is already visible in, and omit the copper focus report
test "assembly selection stays beside its row without copper reports" {
    const js = @embedFile("assets/assembly_debug.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "row.after(selection)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "visible.unshift(picked)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "track_length_mm") == null);
    // A row the reader clicked is on screen already, so the reveal returns
    // before touching the scroller; only an off-screen row moves, and then by
    // the shortest distance rather than to the top of the panel.
    try std.testing.expect(std.mem.indexOf(
        u8,
        js,
        "if (rowBox.top >= panelBox.top && rowBox.bottom <= panelBox.bottom) return;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "block: 'start'") == null);
}

// spec: Web Server - assembly parts, BOM lines, and selections link uploaded local datasheets and HTTP(S) component datasheet URLs
test "assembly BOM lines union available local and remote datasheets" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/datasheets");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/datasheets/adc.pdf", .data = "%PDF-1.7" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    try std.testing.expect(datasheetPresent(allocator, root, "adc.pdf"));
    try std.testing.expect(datasheetPresent(allocator, root, "https" ++ "://example.com/adc.pdf"));
    try std.testing.expect(!datasheetPresent(allocator, root, "never-uploaded.pdf"));
    try std.testing.expect(!datasheetPresent(allocator, root, "javascript:alert(1)"));
    try std.testing.expect(!datasheetPresent(allocator, root, "../secret.pdf"));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const groups = try buildBomGroups(arena.allocator(), &.{
        .{
            .ref = "U1",
            .component = "adc",
            .value = "",
            .footprint = "qfn",
            .mpn = "AD7380",
            .datasheets = &.{"adc.pdf"},
        },
        .{
            .ref = "U2",
            .component = "adc",
            .value = "",
            .footprint = "qfn",
            .mpn = "AD7380",
            .datasheets = &.{ "adc.pdf", "adc-errata.pdf" },
        },
    });
    try std.testing.expectEqual(@as(usize, 1), groups.len);
    try std.testing.expectEqual(@as(usize, 2), groups[0].datasheets.len);
    try std.testing.expectEqualStrings("adc.pdf", groups[0].datasheets[0]);
    try std.testing.expectEqualStrings("adc-errata.pdf", groups[0].datasheets[1]);

    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try writeIndexJson(&aw.writer, .{
        .parts = &.{},
        .bom_groups = groups,
        .entities = &.{},
        .nets = &.{},
    }, .{ .name = "demo" });
    try std.testing.expect(std.mem.indexOf(
        u8,
        aw.written(),
        "\"datasheets\":[\"adc.pdf\",\"adc-errata.pdf\"]",
    ) != null);

    const js = @embedFile("assets/assembly_debug.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "function datasheetsForRefs(refs)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "datasheetHref(sheet)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "button.appendChild(datasheetLinks(group.datasheets))") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "selectionDatasheets.appendChild(datasheetLinks(sheets))") != null);
    // Opening a PDF must not double as a selection change on the row it sits in.
    try std.testing.expect(std.mem.indexOf(u8, js, "event.stopPropagation()") != null);
    const css = @embedFile("assets/assembly_debug.css");
    try std.testing.expect(std.mem.indexOf(u8, css, ".datasheet-link") != null);
}

// spec: Web Server - the assembly workspace opens on its parts list, leaving the guide panel one tab click or a deep link away
test "assembly opens on its parts list with the guide one tab away" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const html = try renderPage(arena.allocator(), "demo", .{
        .parts = &.{},
        .bom_groups = &.{},
        .entities = &.{},
        .nets = &.{},
        .guides = &.{.{ .slug = "demo", .title = "Bodge", .body = "# Bodge" }},
    }, null, false);
    // Served in the opened state, so the page never flashes the guide first.
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"parts-tab\" class=\"panel-tab active\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"guide-tab\" class=\"panel-tab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"guide-workspace\" hidden") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"assembly-panel\">") != null);

    const js = @embedFile("assets/assembly_debug.js");
    // The bootstrap settles on parts, and the deep-link restore runs after it,
    // so `?guide=`/`?target=` still opens the guide panel.
    const default_panel = std.mem.lastIndexOf(u8, js, "showWorkspacePanel('parts');") orelse
        return error.TestUnexpectedResult;
    const deep_link = std.mem.lastIndexOf(u8, js, "restoreDeepLink();") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(default_panel < deep_link);
    try std.testing.expect(std.mem.indexOf(u8, js, "showWorkspacePanel(guideWorkspace ?") == null);
}

// spec: Web Server - an assembly component click scopes same-ref highlighting to placements on the board face currently being viewed
test "assembly component picks scope same-ref focus to the shown side" {
    const board_js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function reviewPartSide(p)") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function reviewResolveRefs(wants,side)") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "reviewSet({refs:[p.ref],side:side,fit:false})") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "ref:p.ref,side:side") != null);
    const client_js = @embedFile("assets/assembly_debug.js");
    try std.testing.expect(std.mem.indexOf(u8, client_js, "payload.side === 'bottom' || payload.side === 'top'") != null);
}

// spec: Web Server - assembly part and BOM selections highlight only placements on the currently viewed board face and retarget when that face is switched
test "assembly sidebar focus follows the viewed board side" {
    const js = @embedFile("assets/assembly_debug.js");
    const focus_start = std.mem.indexOf(u8, js, "function focusMessage(") orelse return error.TestUnexpectedResult;
    const focus_end = std.mem.indexOfPos(u8, js, focus_start, "function requestBoardParts()") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, js[focus_start..focus_end], "side: boardSide") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function refocusForBoardSide()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "focusMessage(selected.refs, nets, false, selected.type)") != null);
    const side_click = std.mem.indexOf(u8, js, "boardSide = boardSide === 'bottom' ? 'top' : 'bottom';") orelse return error.TestUnexpectedResult;
    const side_click_end = std.mem.indexOfPos(u8, js, side_click, "});") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, js[side_click..side_click_end], "refocusForBoardSide();") != null);
    const board_js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, board_js, "reviewResolveRefs(wantRefs,side)") != null);
}

// spec: Web Server - assembly searches keyboard-highlight the first match, wrap through results with arrow keys, and activate the current row with Enter
test "assembly search supports first-match and arrow-key navigation" {
    const js = @embedFile("assets/assembly_debug.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "state.input.value.trim() ? 0 : -1") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "event.key === 'ArrowDown'") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "event.key === 'ArrowUp'") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "rows[state.index].click()") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "selection.hidden = item.type === 'bom'") != null);
    const css = @embedFile("assets/assembly_debug.css");
    try std.testing.expect(std.mem.indexOf(u8, css, ".result-item.keyboard-active") != null);
}

// spec: Web Server - assembly uses one unified part and board-object search, omits component connection blocks, and reveals board-picked test points with their connected net
test "assembly unifies board search and reveals test-point nets" {
    const js = @embedFile("assets/assembly_debug.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "const assemblySearch = document.getElementById('assembly-search')") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "const testPointNets = item.type === 'testpoint'") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "selectionNet.textContent = testPointNets.length ? `Net:") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "renderEndpoints(item.type === 'net' ? item.nets : [])") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "revealBoardRef(payload.ref, payload.net)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, ".concat(pickedNet || [])") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "candidate.type === 'ref' || candidate.type === 'testpoint'") != null);
}

// spec: Web Server - assembly clears its current selection when Escape is pressed or the physical review is clicked outside the board outline
test "assembly clears selection outside the board and with Escape" {
    const js = @embedFile("assets/assembly_debug.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "if (event.key !== 'Escape') return;") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "clearSelection(true);") != null);
    const board_js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, board_js, "function reviewClearOutside(m)") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "!PHYSICAL_REVIEW||pts.length<3||polyContains(pts,m.x,m.y)") != null);
    try std.testing.expect(std.mem.indexOf(u8, board_js, "if(PHYSICAL_REVIEW){ev.preventDefault();selNet(null);return;}") != null);
}

test "JSON embedded in script cannot close its script element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var aw: std.Io.Writer.Allocating = .init(arena.allocator());
    try writeIndexJson(&aw.writer, .{
        .parts = &.{.{ .ref = "</script><script>alert(1)</script>", .component = "", .value = "", .footprint = "" }},
        .bom_groups = &.{},
        .entities = &.{},
        .nets = &.{},
    }, .{ .name = "demo" });
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "</script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\\u003c/script") != null);
}
