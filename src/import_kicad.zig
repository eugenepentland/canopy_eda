//! Migrate an existing KiCad board into a netlisp project.
//!
//! `netlisp import-kicad <board.kicad_pcb>` reads the `.kicad_pcb` alone —
//! modern KiCad embeds everything a schematic capture needs right in the
//! board file: per-pad net assignments (the flattened netlist), per-pad
//! `(pinfunction …)` names copied from the schematic symbols, full footprint
//! geometry, and the BOM properties (Value / Description / MPN / DNP).
//! No schematic wire-tracing is required.
//!
//! The importer:
//!  1. Maps standard SMD passives (`C_0402_*`, `R_0805_*`, …) onto the
//!     project's existing component families (`cap-0402`, `res-0805`, …),
//!     choosing the electrical kind from the ref-des prefix (an `FB` ref on
//!     an `L_0402` footprint becomes `ferrite-0402`, an `L` ref on a
//!     `C_0402` footprint becomes `ind-0402`).
//!  2. Generates `lib/components/<part>.sexp` + `lib/pinouts/<part>.sexp`
//!     + `lib/footprints/<fp>.sexp` for every other part, from the board's
//!     embedded footprints. Existing library files are never overwritten.
//!  3. Emits `src/<name>.sexp`: one `(instance …)` per footprint, keeping
//!     KiCad's reference designators, with `(pin … "NET")` connections
//!     grouped by net. KiCad auto-nets (`Net-(R1-Pad2)`) keep a sanitized
//!     traceable name; `unconnected-*` stubs and empty nets drop the pin.
//!
//! Pad geometry note: in a `.kicad_pcb`, pad positions are footprint-local
//! but pad *angles* include the footprint's board rotation — the emitter
//! subtracts the footprint rotation to recover canonical geometry.

const std = @import("std");
const ast = @import("sexpr/ast.zig");
const parser_mod = @import("sexpr/parser.zig");
const footprint_conv = @import("convert/footprint.zig");
const kicad_fmt = @import("kicad_pcb/format.zig");
const infra_fs = @import("infra/fs.zig");
const import_fold = @import("import_fold.zig");

const Node = ast.Node;

/// KiCad's single-pad stub prefix — pads on these nets are unconnected.
pub const unconnected_prefix = "unconnected-";

// ── Data model ────────────────────────────────────────────────────────

/// One board pad: number, raw KiCad net ("" = unconnected), and the
/// schematic pin name KiCad copies onto the pad as `(pinfunction …)`.
pub const Pad = struct {
    number: []const u8,
    net: []const u8, // raw KiCad net name; "" = unconnected
    func: []const u8, // (pinfunction …) or ""
};

/// One footprint lifted off the board, with its BOM properties, pads, and
/// the classification fields the import pipeline fills in.
pub const Part = struct {
    ref: []const u8,
    value: []const u8,
    lib_id: []const u8, // "Lib:Footprint" as placed on the board
    descr: []const u8, // Description property (fallback: footprint descr)
    mpn: []const u8,
    manufacturer: []const u8,
    dnp: bool,
    rot: f64, // footprint board rotation (deg)
    pads: []Pad,
    node: Node, // the (footprint …) subtree, for geometry emission
    // Filled by classification:
    family: ?[]const u8 = null, // e.g. "cap-0402" — null ⇒ custom part
    comp_name: ?[]const u8 = null, // custom component name (sanitized)
};

/// One custom (non-family) component to materialize in lib/.
const CustomComp = struct {
    name: []const u8, // component + pinout name
    fp_file: []const u8, // lib/footprints/<fp_file>.sexp
    part_idx: usize, // exemplar part (pinout + geometry source)
};

/// Caller-supplied import parameters (board path, target project, design
/// name/title, and whether to write anything).
pub const ImportOptions = struct {
    board_path: []const u8,
    project_dir: []const u8,
    name: []const u8, // design name → src/<name>.sexp
    title: []const u8, // (design-block "<title>" …)
    dry_run: bool = false,
    /// Fold repeated channel structure (CH1_*/CH2_*/… net families) into a
    /// generated defmodule + per-channel sub-blocks. See import_fold.zig.
    fold_channels: bool = false,
    /// Explicit channel-prefix override (e.g. "CH"); null = auto-detect.
    fold_prefix: ?[]const u8 = null,
};

/// Counts reported back to the CLI after an import run.
pub const ImportSummary = struct {
    parts: usize = 0,
    family_mapped: usize = 0,
    custom_parts: usize = 0,
    lib_written: usize = 0,
    lib_existing: usize = 0,
    nets: usize = 0,
    dropped_pins: usize = 0, // unconnected/empty-net pads
    design_path: []const u8 = "",
    folded_channels: usize = 0, // sub-blocks emitted by --fold-channels
    folded_parts_each: usize = 0, // parts per folded channel
    fold_module: []const u8 = "", // generated module name ("" = no fold)
    fold_skipped: usize = 0, // channels that deviated and stayed flat
};

pub const ImportError = error{ InvalidBoard, OutOfMemory, WriteFailed } || std.fs.File.OpenError || std.fs.File.ReadError || parser_mod.ParseError;

// ── Entry point ───────────────────────────────────────────────────────

/// Run the full import: parse the board, classify parts, write library
/// files for unknown parts, and write the design source. Returns counts
/// for the CLI report. All allocations live in `arena` (caller-owned).
pub fn importBoard(arena: std.mem.Allocator, opts: ImportOptions) ImportError!ImportSummary {
    const source = infra_fs.cwd().readFileAlloc(arena, opts.board_path, 64 * 1024 * 1024) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return error.FileNotFound,
        else => return error.InvalidBoard,
    };
    const nodes = try parser_mod.parse(arena, source);
    if (nodes.len == 0 or !nodes[0].isForm("kicad_pcb")) return error.InvalidBoard;

    const parts = try parseParts(arena, nodes[0]);
    if (parts.len == 0) return error.InvalidBoard;

    var summary = ImportSummary{ .parts = parts.len };

    for (parts) |*part| {
        if (try familyFor(arena, opts.project_dir, part.*)) |fam| {
            part.family = fam;
            summary.family_mapped += 1;
        }
    }

    const comps = try collectCustomComps(arena, opts.project_dir, parts);
    summary.custom_parts = comps.len;

    try ensureLibFiles(arena, opts, parts, comps, &summary);

    var fold_res: import_fold.FoldResult = .{};
    if (opts.fold_channels) {
        fold_res = try import_fold.foldChannels(arena, parts, opts.name, opts.fold_prefix);
        if (fold_res.active) {
            summary.folded_channels = fold_res.channels.len;
            summary.folded_parts_each = fold_res.parts_per_channel;
            summary.fold_module = fold_res.module_name;
            summary.fold_skipped = fold_res.skipped_indices.len;
            const mod_path = try std.fmt.allocPrint(arena, "{s}/lib/modules/{s}.sexp", .{ opts.project_dir, fold_res.module_name });
            if (!fileExists(mod_path)) {
                try writeLibFile(opts, mod_path, fold_res.module_text, &summary);
            } else {
                summary.lib_existing += 1;
            }
        }
    }

    const design_text = try buildDesignText(arena, opts, parts, comps, &fold_res, &summary);
    const design_path = try std.fmt.allocPrint(arena, "{s}/src/{s}.sexp", .{ opts.project_dir, opts.name });
    summary.design_path = design_path;
    if (!opts.dry_run) {
        writeFileMakePath(opts.project_dir, design_path, design_text) catch return error.WriteFailed;
    }
    return summary;
}

// ── Board parsing ─────────────────────────────────────────────────────

/// Walk every `(footprint …)` child of the board root into a Part. Builds
/// the `(net N "name")` ID table first so both the KiCad-10 by-name pad
/// form and the older ID-reference form resolve.
fn parseParts(arena: std.mem.Allocator, root: Node) ImportError![]Part {
    const children = root.asList() orelse return error.InvalidBoard;

    var net_table = std.AutoHashMapUnmanaged(i64, []const u8).empty;
    for (children[1..]) |child| {
        if (!child.isForm("net")) continue;
        const cl = child.asList() orelse continue;
        if (cl.len < 3) continue;
        const id_num = cl[1].asNumber() orelse continue;
        const name = cl[2].asString() orelse continue;
        try net_table.put(arena, @intFromFloat(id_num), name);
    }

    var parts: std.ArrayList(Part) = .empty;
    for (children[1..]) |child| {
        if (!child.isForm("footprint")) continue;
        if (try parseFootprint(arena, child, &net_table)) |part| {
            try parts.append(arena, part);
        }
    }
    return parts.items;
}

fn parseFootprint(
    arena: std.mem.Allocator,
    node: Node,
    net_table: *const std.AutoHashMapUnmanaged(i64, []const u8),
) ImportError!?Part {
    const cl = node.asList() orelse return null;
    if (cl.len < 2) return null;

    var part = Part{
        .ref = "",
        .value = "",
        .lib_id = cl[1].asString() orelse return null,
        .descr = "",
        .mpn = "",
        .manufacturer = "",
        .dnp = false,
        .rot = 0,
        .pads = &[_]Pad{},
        .node = node,
    };

    var pads: std.ArrayList(Pad) = .empty;
    for (cl[2..]) |sub| {
        if (sub.isForm("at")) {
            const al = sub.asList().?;
            if (al.len >= 4) part.rot = al[3].asNumber() orelse 0;
        } else if (sub.isForm("attr")) {
            const al = sub.asList().?;
            for (al[1..]) |a| {
                const word = a.asAtom() orelse continue;
                if (std.mem.eql(u8, word, "dnp")) part.dnp = true;
            }
        } else if (sub.isForm("descr")) {
            const dl = sub.asList().?;
            if (dl.len >= 2 and part.descr.len == 0)
                part.descr = dl[1].asString() orelse dl[1].asAtom() orelse "";
        } else if (sub.isForm("property")) {
            readPartProperty(sub, &part);
        } else if (sub.isForm("pad")) {
            try readPartPad(arena, sub, net_table, &pads);
        }
    }
    part.pads = pads.items;

    // Skip unannotated stamps and KiCad-internal power symbols.
    if (part.ref.len == 0 or part.ref[0] == '#') return null;
    if (std.mem.indexOfScalar(u8, part.ref, '*') != null) return null;
    return part;
}

fn readPartProperty(node: Node, part: *Part) void {
    const cl = node.asList() orelse return;
    if (cl.len < 3) return;
    const key = cl[1].asString() orelse return;
    const val = cl[2].asString() orelse return;
    if (std.mem.eql(u8, key, "Reference")) {
        part.ref = val;
    } else if (std.mem.eql(u8, key, "Value")) {
        part.value = val;
    } else if (std.mem.eql(u8, key, "Description")) {
        if (val.len > 0) part.descr = val;
    } else if (std.mem.eql(u8, key, "MPN") or std.mem.eql(u8, key, "Manufacturer_Part_Number")) {
        if (part.mpn.len == 0) part.mpn = val;
    } else if (std.mem.eql(u8, key, "Manufacturer") or std.mem.eql(u8, key, "Manufacturer_Name")) {
        if (part.manufacturer.len == 0) part.manufacturer = val;
    }
}

fn readPartPad(
    arena: std.mem.Allocator,
    node: Node,
    net_table: *const std.AutoHashMapUnmanaged(i64, []const u8),
    pads: *std.ArrayList(Pad),
) ImportError!void {
    const cl = node.asList() orelse return;
    if (cl.len < 2) return;
    const num = kicad_fmt.padNumberText(arena, cl[1]) orelse return;
    if (num.len == 0) return; // mask-only / paste-only aperture pads

    var net_name: []const u8 = "";
    var func: []const u8 = "";
    for (cl[2..]) |sub| {
        if (sub.isForm("net")) {
            const nl = sub.asList() orelse continue;
            if (nl.len < 2) continue;
            if (nl[1].asNumber()) |id_num| {
                if (net_table.get(@intFromFloat(id_num))) |name| net_name = name;
            } else if (nl[1].asString()) |name| {
                net_name = name;
            }
        } else if (sub.isForm("pinfunction")) {
            const fl = sub.asList() orelse continue;
            if (fl.len >= 2) func = fl[1].asString() orelse "";
        }
    }
    try pads.append(arena, .{ .number = num, .net = net_name, .func = func });
}

// ── Classification ────────────────────────────────────────────────────

const sizes = [_][]const u8{ "0201", "0402", "0603", "0805" };

/// Map a part onto an existing passive component family, or null when the
/// part needs a generated library component. Kind comes from the ref-des
/// prefix (electrically authoritative), size from the standard-footprint
/// leaf name; the family is only used when its lib/components file exists.
fn familyFor(arena: std.mem.Allocator, project_dir: []const u8, part: Part) ImportError!?[]const u8 {
    const leaf = stripLibPrefix(part.lib_id);

    // Standard-passive leaf: C_/R_/L_/LED_ followed by a known size token.
    const us = std.mem.indexOfScalar(u8, leaf, '_') orelse return null;
    var size: ?[]const u8 = null;
    for (sizes) |s| {
        if (std.mem.startsWith(u8, leaf[us + 1 ..], s)) size = s;
    }
    if (size == null) return null;

    const prefix = refPrefix(part.ref);
    const kind: []const u8 = if (std.mem.eql(u8, prefix, "C"))
        "cap"
    else if (std.mem.eql(u8, prefix, "R"))
        "res"
    else if (std.mem.eql(u8, prefix, "L"))
        "ind"
    else if (std.mem.eql(u8, prefix, "FB"))
        "ferrite"
    else if (std.mem.eql(u8, prefix, "D") and std.mem.startsWith(u8, leaf, "LED_"))
        "led"
    else
        return null;

    // Families are strictly two-terminal (pads 1 and 2).
    if (!hasExactPads12(part.pads)) return null;

    const fam = try std.fmt.allocPrint(arena, "{s}-{s}", .{ kind, size.? });
    const fam_path = try std.fmt.allocPrint(arena, "{s}/lib/components/{s}.sexp", .{ project_dir, fam });
    infra_fs.cwd().access(fam_path, .{}) catch return null;
    return fam;
}

fn hasExactPads12(pads: []const Pad) bool {
    var saw1 = false;
    var saw2 = false;
    for (pads) |p| {
        if (std.mem.eql(u8, p.number, "1")) {
            saw1 = true;
        } else if (std.mem.eql(u8, p.number, "2")) {
            saw2 = true;
        } else {
            return false;
        }
    }
    return saw1 and saw2;
}

/// Group custom parts into unique library components. The component name
/// prefers the MPN property, then a part-number-looking Value, then the
/// footprint leaf. Two parts sharing a name but differing in footprint get
/// the footprint leaf appended so they don't collide in lib/.
fn collectCustomComps(arena: std.mem.Allocator, project_dir: []const u8, parts: []Part) ImportError![]CustomComp {
    var comps: std.ArrayList(CustomComp) = .empty;
    var by_name = std.StringHashMapUnmanaged(usize).empty;

    for (parts, 0..) |*part, idx| {
        if (part.family != null) continue;
        const leaf = stripLibPrefix(part.lib_id);
        const fp_file = try sanitizeName(arena, leaf);

        const base = if (part.mpn.len > 0)
            part.mpn
        else if (part.value.len > 0 and !std.mem.eql(u8, part.value, "~"))
            part.value
        else
            leaf;
        var name = try sanitizeName(arena, base);

        // A purely numeric name tokenizes as a number, not an atom, so it
        // can't be referenced by `(import …)` or an instance. Prefix the
        // manufacturer slug (or `p`) until the name leads with a letter.
        if (std.ascii.isDigit(name[0]) and isAllDigits(name)) {
            if (part.manufacturer.len > 0) {
                name = try std.fmt.allocPrint(arena, "{s}-{s}", .{ try sanitizeName(arena, part.manufacturer), name });
            }
            if (std.ascii.isDigit(name[0]) and isAllDigits(name)) {
                name = try std.fmt.allocPrint(arena, "p{s}", .{name});
            }
        }

        // If the name lands on an existing component-*family* (e.g. a bare
        // "LED" value vs the led family), an atom reference would break —
        // fall back to a footprint-derived name and generate a fresh part.
        if (try clashesWithFamily(arena, project_dir, name)) {
            name = if (std.mem.startsWith(u8, fp_file, name))
                fp_file
            else
                try std.fmt.allocPrint(arena, "{s}-{s}", .{ name, fp_file });
        }

        if (by_name.get(name)) |existing_idx| {
            const existing = comps.items[existing_idx];
            if (!std.mem.eql(u8, existing.fp_file, fp_file)) {
                // Same name, different package — disambiguate by footprint.
                name = try std.fmt.allocPrint(arena, "{s}-{s}", .{ name, fp_file });
            }
        }
        if (by_name.get(name)) |existing_idx| {
            part.comp_name = comps.items[existing_idx].name;
            continue;
        }
        try comps.append(arena, .{ .name = name, .fp_file = fp_file, .part_idx = idx });
        try by_name.put(arena, name, comps.items.len - 1);
        part.comp_name = name;
    }
    return comps.items;
}

fn isAllDigits(s: []const u8) bool {
    for (s) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return s.len > 0;
}

/// True when `lib/components/<name>.sexp` exists and declares a
/// component-family rather than a fixed component.
fn clashesWithFamily(arena: std.mem.Allocator, project_dir: []const u8, name: []const u8) ImportError!bool {
    const path = try std.fmt.allocPrint(arena, "{s}/lib/components/{s}.sexp", .{ project_dir, name });
    const head = infra_fs.cwd().readFileAlloc(arena, path, 4096) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    return std.mem.indexOf(u8, head, "(component-family") != null;
}

// ── Library file generation ───────────────────────────────────────────

/// Write component + pinout + footprint files for every custom part whose
/// files don't already exist. Existing files are left untouched so a
/// curated library always wins over the auto-generated one.
fn ensureLibFiles(
    arena: std.mem.Allocator,
    opts: ImportOptions,
    parts: []const Part,
    comps: []const CustomComp,
    summary: *ImportSummary,
) ImportError!void {
    var fp_written = std.StringHashMapUnmanaged(void).empty;
    for (comps) |comp| {
        const part = parts[comp.part_idx];

        const comp_path = try std.fmt.allocPrint(arena, "{s}/lib/components/{s}.sexp", .{ opts.project_dir, comp.name });
        if (fileExists(comp_path)) {
            summary.lib_existing += 1;
        } else {
            try writeLibFile(opts, comp_path, try renderComponent(arena, comp, part), summary);
            const pinout_path = try std.fmt.allocPrint(arena, "{s}/lib/pinouts/{s}.sexp", .{ opts.project_dir, comp.name });
            if (!fileExists(pinout_path)) {
                try writeLibFile(opts, pinout_path, try renderPinout(arena, comp.name, part.pads), summary);
            }
        }

        const fp_path = try std.fmt.allocPrint(arena, "{s}/lib/footprints/{s}.sexp", .{ opts.project_dir, comp.fp_file });
        if (!fileExists(fp_path) and !fp_written.contains(comp.fp_file)) {
            try writeLibFile(opts, fp_path, try renderFootprint(arena, part), summary);
            try fp_written.put(arena, comp.fp_file, {});
        }
    }
}

fn writeLibFile(opts: ImportOptions, path: []const u8, text: []const u8, summary: *ImportSummary) ImportError!void {
    summary.lib_written += 1;
    if (opts.dry_run) return;
    writeFileMakePath(opts.project_dir, path, text) catch return error.WriteFailed;
}

fn renderComponent(arena: std.mem.Allocator, comp: CustomComp, part: Part) ImportError![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(arena);
    try w.writeAll(";; Auto-generated by `netlisp import-kicad` — edit freely, re-import never overwrites\n");
    try w.print("(component \"{s}\"\n", .{comp.name});
    if (part.descr.len > 0) {
        try w.print("  (description \"{s}\")\n", .{try escapeQuotes(arena, part.descr)});
    }
    try w.print("  (pinout \"{s}\")\n", .{comp.name});
    try w.print("  (footprint \"{s}\")", .{comp.fp_file});
    if (part.manufacturer.len > 0) {
        try w.print("\n  (manufacturer \"{s}\")", .{try escapeQuotes(arena, part.manufacturer)});
    }
    if (part.mpn.len > 0) {
        try w.print("\n  (mpn \"{s}\")", .{try escapeQuotes(arena, part.mpn)});
    }
    try w.writeAll(")\n");
    return buf.items;
}

/// Pinout from the board pads' `(pinfunction …)` names — KiCad copies the
/// schematic symbol's pin names onto every pad, so the board carries the
/// full pin map. Pads sharing a number (thermal-pad splits) dedup to one
/// entry, preferring the first with a non-empty function name.
fn renderPinout(arena: std.mem.Allocator, name: []const u8, pads: []const Pad) ImportError![]const u8 {
    var seen = std.StringHashMapUnmanaged(usize).empty;
    var uniq: std.ArrayList(Pad) = .empty;
    for (pads) |p| {
        if (seen.get(p.number)) |i| {
            if (uniq.items[i].func.len == 0 and p.func.len > 0) uniq.items[i].func = p.func;
            continue;
        }
        try seen.put(arena, p.number, uniq.items.len);
        try uniq.append(arena, p);
    }
    std.mem.sort(Pad, uniq.items, {}, padNumberLessThan);

    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(arena);
    try w.writeAll(";; Auto-generated pinout — DO NOT EDIT\n");
    try w.writeAll(";; Source of truth for pin ID → function name mapping\n");
    try w.print("(pinout \"{s}\"\n", .{name});
    for (uniq.items) |p| {
        const func = if (p.func.len > 0) try escapeQuotes(arena, p.func) else "~";
        try w.print("  (pin {s} \"{s}\")\n", .{ p.number, func });
    }
    try w.writeAll(")\n");
    return buf.items;
}

fn padNumberLessThan(_: void, a: Pad, b: Pad) bool {
    const na = std.fmt.parseInt(u32, a.number, 10) catch null;
    const nb = std.fmt.parseInt(u32, b.number, 10) catch null;
    if (na != null and nb != null) return na.? < nb.?;
    if (na != null) return true; // numeric pads before alpha pads
    if (nb != null) return false;
    return std.mem.lessThan(u8, a.number, b.number);
}

/// Emit lib/footprints geometry from the board's embedded footprint.
/// Pad positions are already footprint-local; pad angles include the
/// footprint's board rotation, so subtract it before deciding whether a
/// 90°/270° pad swaps width and height.
fn renderFootprint(arena: std.mem.Allocator, part: Part) ImportError![]const u8 {
    const leaf = stripLibPrefix(part.lib_id);
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(arena);
    try w.print("(footprint \"{s}\"\n", .{leaf});
    if (part.descr.len > 0) {
        try w.print("  (description \"{s}\")\n", .{try escapeQuotes(arena, part.descr)});
    }
    try w.writeByte('\n');

    var min_x: f64 = std.math.inf(f64);
    var min_y: f64 = std.math.inf(f64);
    var max_x: f64 = -std.math.inf(f64);
    var max_y: f64 = -std.math.inf(f64);

    const cl = part.node.asList() orelse return error.InvalidBoard;
    for (cl[2..]) |sub| {
        if (!sub.isForm("pad")) continue;
        emitBoardPad(w, sub, part.rot, &min_x, &min_y, &max_x, &max_y) catch return error.OutOfMemory;
    }

    if (min_x < max_x) {
        const m = 0.25; // courtyard margin around the pad envelope
        try w.print("  (courtyard (rect {d:.3} {d:.3} {d:.3} {d:.3}))\n", .{ min_x - m, min_y - m, max_x + m, max_y + m });
    }
    try w.writeAll(")\n");
    return buf.items;
}

fn emitBoardPad(
    w: anytype,
    node: Node,
    fp_rot: f64,
    min_x: *f64,
    min_y: *f64,
    max_x: *f64,
    max_y: *f64,
) !void {
    const cl = node.asList() orelse return;
    if (cl.len < 4) return;
    var num_buf: [32]u8 = undefined;
    const num = padNumText(cl[1], &num_buf) orelse return;
    if (num.len == 0) return;
    const pad_type = cl[2].asAtom() orelse return;
    const shape = cl[3].asAtom() orelse return;

    var x: f64 = 0;
    var y: f64 = 0;
    var rot: f64 = 0;
    var sx: f64 = 0;
    var sy: f64 = 0;
    var drill: f64 = 0;
    var drill_y: f64 = 0;
    var has_drill = false;
    var is_oval_drill = false;
    for (cl[4..]) |sub| {
        if (sub.isForm("at")) {
            const al = sub.asList().?;
            if (al.len >= 3) {
                x = al[1].asNumber() orelse 0;
                y = al[2].asNumber() orelse 0;
                if (al.len >= 4) rot = al[3].asNumber() orelse 0;
            }
        } else if (sub.isForm("size")) {
            const sl = sub.asList().?;
            if (sl.len >= 3) {
                sx = sl[1].asNumber() orelse 0;
                sy = sl[2].asNumber() orelse 0;
            }
        } else if (sub.isForm("drill")) {
            const dl = sub.asList().?;
            // (drill D) or (drill oval DX DY). Oval drills are standard for
            // connector / Micro-USB shield pads; dropping them left the
            // thru-hole pad with no hole at all.
            if (dl.len >= 2) {
                if (dl[1].asAtom()) |a| {
                    if (std.mem.eql(u8, a, "oval") and dl.len >= 4) {
                        is_oval_drill = true;
                        has_drill = true;
                        drill = dl[2].asNumber() orelse 0;
                        drill_y = dl[3].asNumber() orelse 0;
                    }
                } else if (dl[1].asNumber()) |d| {
                    drill = d;
                    drill_y = d;
                    has_drill = true;
                }
            }
        }
    }

    // Recover the pad's footprint-local angle (board files bake the
    // footprint rotation into every pad angle).
    const local = @mod(rot - fp_rot + 720.0, 360.0);
    const swapped = (local > 45.0 and local < 135.0) or (local > 225.0 and local < 315.0);
    const out_sx = if (swapped) sy else sx;
    const out_sy = if (swapped) sx else sy;

    min_x.* = @min(min_x.*, x - out_sx / 2);
    min_y.* = @min(min_y.*, y - out_sy / 2);
    max_x.* = @max(max_x.*, x + out_sx / 2);
    max_y.* = @max(max_y.*, y + out_sy / 2);

    // {d:.4} matches KiCad's own metric precision (0402 pads at ±0.485, fine-
    // pitch BGAs at 0.1625 steps) — quantising to 0.01 mm shifts coordinates by
    // up to 5 µm and compounds across an import→export round-trip.
    try w.print("  (pad {s} {s} {s} (pos {d:.4} {d:.4}) (size {d:.4} {d:.4})", .{
        num,
        footprint_conv.mapPadType(pad_type),
        footprint_conv.mapPadShape(shape),
        x,
        y,
        out_sx,
        out_sy,
    });
    if (has_drill) {
        if (is_oval_drill) {
            try w.print(" (drill oval {d:.4} {d:.4})", .{ drill, drill_y });
        } else {
            try w.print(" (drill {d:.4})", .{drill});
        }
    }
    try w.writeAll(")\n");
}

/// Pad-number text without an allocator (stack buffer for numeric pads).
fn padNumText(node: Node, buf: *[32]u8) ?[]const u8 {
    if (node.asString()) |s| return s;
    if (node.asAtom()) |a| return a;
    if (node.asNumber()) |n| {
        const i: i64 = @intFromFloat(n);
        return std.fmt.bufPrint(buf, "{d}", .{i}) catch null;
    }
    return null;
}

// ── Design emission ───────────────────────────────────────────────────

/// Render the design .sexp: imports for every generated component, then a
/// design-block with folded channel sub-blocks first (when --fold-channels
/// found a repetition), then hubs (ICs/connectors) ahead of passives in
/// natural ref order, pins grouped per net.
fn buildDesignText(
    arena: std.mem.Allocator,
    opts: ImportOptions,
    parts: []Part,
    comps: []const CustomComp,
    fold_res: *const import_fold.FoldResult,
    summary: *ImportSummary,
) ImportError![]const u8 {
    var nets = NetNames.init(arena);

    const order = try arena.alloc(usize, parts.len);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, parts, partOrderLessThan);

    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(arena);
    try w.print(";; Imported from {s} by `netlisp import-kicad`\n", .{std.fs.path.basename(opts.board_path)});
    try w.writeAll(";; Netlist source: board pads (KiCad embeds pinfunction + net per pad).\n\n");

    var import_names: std.ArrayList([]const u8) = .empty;
    for (comps) |c| {
        // Components used only inside the folded module are imported there.
        if (fold_res.active and !compUsedFlat(parts, fold_res, c.name)) continue;
        try import_names.append(arena, c.name);
    }
    if (fold_res.active) try import_names.append(arena, fold_res.module_name);
    std.mem.sort([]const u8, import_names.items, {}, strLessThan);
    for (import_names.items) |n| try w.print("(import {s})\n", .{n});
    if (import_names.items.len > 0) try w.writeByte('\n');

    try w.print("(design-block \"{s}\"\n", .{try escapeQuotes(arena, opts.title)});
    if (fold_res.active) try emitFoldedChannels(w, fold_res, &nets);

    var last_was_hub: ?bool = null;
    for (order) |idx| {
        if (fold_res.active and fold_res.folded[idx]) continue;
        const part = parts[idx];
        const hub = isHubRef(part.ref);
        if (last_was_hub == null or last_was_hub.? != hub) {
            try w.writeAll(if (hub) "\n  ;; ── ICs & connectors ──\n" else "\n  ;; ── Passives ──\n");
            last_was_hub = hub;
        }
        try emitInstance(arena, w, part, &nets, summary);
    }
    try w.writeAll(")\n");
    summary.nets = nets.count();
    return buf.items;
}

/// True when component `name` is used by at least one part that stays in
/// the flat remainder (i.e. not folded into the channel module).
fn compUsedFlat(parts: []const Part, fold_res: *const import_fold.FoldResult, name: []const u8) bool {
    for (parts, 0..) |part, i| {
        if (fold_res.folded[i]) continue;
        const comp = part.comp_name orelse continue;
        if (std.mem.eql(u8, comp, name)) return true;
    }
    return false;
}

/// Emit the folded-channel block: `(hierarchical-ids)`, one `(sub-block
/// "chK" (<module>))` per channel with its original ref-des as a comment
/// and its indexed-net stitching, then the consolidated shared-net forms.
fn emitFoldedChannels(
    w: anytype,
    fold_res: *const import_fold.FoldResult,
    nets: *NetNames,
) ImportError!void {
    try w.writeAll("  (hierarchical-ids)\n");
    try w.print("\n  ;; ── Channels: {s} ×{d}", .{ fold_res.module_name, fold_res.channels.len });
    if (fold_res.skipped_indices.len > 0) {
        try w.writeAll(" (deviating, left flat:");
        for (fold_res.skipped_indices) |k| try w.print(" {d}", .{k});
        try w.writeAll(")");
    }
    try w.writeAll(" ──\n");

    for (fold_res.channels) |chan| {
        try w.print("  (sub-block \"{s}\" ({s}))  ;; {s}\n", .{ chan.sub_name, fold_res.module_name, chan.ref_map });
        for (chan.wires) |wire| {
            const outer = (try nets.resolve(wire.outer_raw)) orelse continue;
            try w.print("  (net \"{s}\" \"{s}/{s}\")\n", .{ outer, chan.sub_name, wire.port });
        }
    }

    if (fold_res.shared_nets.len > 0) {
        try w.writeAll("\n  ;; shared rails & control into every channel\n");
        for (fold_res.shared_nets) |sn| {
            const outer = (try nets.resolve(sn.raw)) orelse continue;
            try w.print("  (net \"{s}\"", .{outer});
            for (fold_res.channels) |chan| {
                try w.print(" \"{s}/{s}\"", .{ chan.sub_name, sn.port });
            }
            try w.writeAll(")\n");
        }
    }
}

fn emitInstance(arena: std.mem.Allocator, w: anytype, part: Part, nets: *NetNames, summary: *ImportSummary) ImportError!void {
    if (part.dnp) try w.writeAll("  ;; DNP on the source board\n");
    if (part.family) |fam| {
        const value = if (part.value.len > 0 and !std.mem.eql(u8, part.value, "~")) part.value else "?";
        try w.print("  (instance \"{s}\" ({s} \"{s}\")", .{ part.ref, fam, try escapeQuotes(arena, value) });
    } else {
        try w.print("  (instance \"{s}\" {s}", .{ part.ref, part.comp_name.? });
    }

    // Group pads by net, preserving first-seen order; dedup pad numbers
    // inside a group (thermal-pad splits repeat the same number).
    var group_of = std.StringHashMapUnmanaged(usize).empty;
    var groups: std.ArrayList(struct { net: []const u8, pins: std.ArrayList([]const u8) }) = .empty;
    for (part.pads) |pad| {
        const net = try nets.resolve(pad.net) orelse {
            summary.dropped_pins += 1;
            continue;
        };
        const gi = group_of.get(net) orelse blk: {
            try groups.append(arena, .{ .net = net, .pins = .empty });
            try group_of.put(arena, net, groups.items.len - 1);
            break :blk groups.items.len - 1;
        };
        var dup = false;
        for (groups.items[gi].pins.items) |existing| {
            if (std.mem.eql(u8, existing, pad.number)) dup = true;
        }
        if (!dup) try groups.items[gi].pins.append(arena, pad.number);
    }

    for (groups.items) |group| {
        try w.writeAll("\n    (pin");
        for (group.pins.items) |pin| try w.print(" {s}", .{pin});
        try w.print(" \"{s}\")", .{group.net});
    }
    // First-class DNP so the BOM/CSV, populated-qty merges, and KiCad netlist
    // re-export all honour the source board's (attr dnp). The comment above
    // stays for provenance.
    if (part.dnp) try w.writeAll("\n    (dnp)");
    try w.writeAll(")\n");
}

/// Hubs (boxed ICs/connectors) sort ahead of inline passives; within each
/// band, natural ref order (C2 before C10).
fn partOrderLessThan(parts: []Part, a: usize, b: usize) bool {
    const ha = isHubRef(parts[a].ref);
    const hb = isHubRef(parts[b].ref);
    if (ha != hb) return ha;
    return refLessThan(parts[a].ref, parts[b].ref);
}

fn isHubRef(ref: []const u8) bool {
    if (ref.len == 0) return true;
    return switch (ref[0]) {
        'R', 'C', 'L', 'F', 'D' => false,
        else => true,
    };
}

fn refLessThan(a: []const u8, b: []const u8) bool {
    const pa = refPrefix(a);
    const pb = refPrefix(b);
    if (!std.mem.eql(u8, pa, pb)) return std.mem.lessThan(u8, pa, pb);
    const na = std.fmt.parseInt(u32, a[pa.len..], 10) catch return std.mem.lessThan(u8, a, b);
    const nb = std.fmt.parseInt(u32, b[pb.len..], 10) catch return std.mem.lessThan(u8, a, b);
    return na < nb;
}

fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ── Net-name sanitization ─────────────────────────────────────────────

/// Sanitizes raw KiCad net names into netlisp-friendly ones, memoized so
/// every pad on a net agrees, with collision suffixes so two distinct
/// KiCad nets can never silently merge.
const NetNames = struct {
    arena: std.mem.Allocator,
    by_raw: std.StringHashMapUnmanaged(?[]const u8),
    taken: std.StringHashMapUnmanaged([]const u8), // sanitized → raw that owns it

    fn init(arena: std.mem.Allocator) NetNames {
        return .{
            .arena = arena,
            .by_raw = std.StringHashMapUnmanaged(?[]const u8).empty,
            .taken = std.StringHashMapUnmanaged([]const u8).empty,
        };
    }

    /// Returns the sanitized net name, or null for unconnected pads
    /// (empty net or a KiCad `unconnected-*` stub).
    fn resolve(self: *NetNames, raw: []const u8) ImportError!?[]const u8 {
        if (raw.len == 0 or std.mem.startsWith(u8, raw, unconnected_prefix)) return null;
        if (self.by_raw.get(raw)) |cached| return cached;

        var name = try sanitizeNetName(self.arena, raw);
        var suffix: u32 = 2;
        while (self.taken.get(name)) |owner| {
            if (std.mem.eql(u8, owner, raw)) break;
            name = try std.fmt.allocPrint(self.arena, "{s}_{d}", .{ name, suffix });
            suffix += 1;
        }
        try self.taken.put(self.arena, name, raw);
        try self.by_raw.put(self.arena, raw, name);
        return name;
    }

    fn count(self: *NetNames) usize {
        return self.taken.count();
    }
};

/// Strip the sheet-path slash KiCad prefixes onto local labels, drop the
/// parens from auto-names like `Net-(R1-Pad2)`, and replace anything the
/// s-expr tokenizer or downstream tooling could trip on with `_`.
///
/// Dots are NOT kept: the evaluator canonicalizes dotted nets under the
/// `<rail>.<ic>.<pad>` bypass-stub convention (prefix before the first
/// dot), so importing KiCad's `+5.0V`/`+5.7V` verbatim silently MERGES
/// them into one `+5` rail. They become `+5_0V`/`+5_7V` instead.
pub fn sanitizeNetName(arena: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]const u8 {
    var trimmed = raw;
    if (trimmed.len > 0 and trimmed[0] == '/') trimmed = trimmed[1..];

    var out: std.ArrayList(u8) = .empty;
    for (trimmed) |ch| {
        switch (ch) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '+', '-' => try out.append(arena, ch),
            '(', ')', '"' => {},
            else => try out.append(arena, '_'),
        }
    }
    if (out.items.len == 0) try out.appendSlice(arena, "NET");
    return out.items;
}

// ── Name helpers ──────────────────────────────────────────────────────

fn stripLibPrefix(lib_id: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, lib_id, ':')) |i| return lib_id[i + 1 ..];
    return lib_id;
}

fn refPrefix(ref: []const u8) []const u8 {
    var i: usize = 0;
    while (i < ref.len and std.ascii.isAlphabetic(ref[i])) i += 1;
    return ref[0..i];
}

/// Lowercase library-name slug: [a-z0-9+.-] kept, runs of anything else
/// collapse to a single '-', trimmed at both ends.
pub fn sanitizeName(arena: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pending_dash = false;
    for (raw) |ch| {
        const c = std.ascii.toLower(ch);
        const keep = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '+' or c == '.' or c == '-';
        if (keep) {
            if (pending_dash and out.items.len > 0) try out.append(arena, '-');
            pending_dash = false;
            try out.append(arena, c);
        } else {
            pending_dash = true;
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') _ = out.pop();
    if (out.items.len == 0) try out.appendSlice(arena, "part");
    return out.items;
}

fn escapeQuotes(arena: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '"') == null) return raw;
    const out = try arena.dupe(u8, raw);
    for (out) |*ch| {
        if (ch.* == '"') ch.* = '\'';
    }
    return out;
}

// ── Filesystem helpers ────────────────────────────────────────────────

fn fileExists(path: []const u8) bool {
    infra_fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn writeFileMakePath(project_dir: []const u8, path: []const u8, text: []const u8) !void {
    _ = project_dir;
    if (std.fs.path.dirname(path)) |dir| {
        try infra_fs.cwd().makePath(dir);
    }
    try infra_fs.cwd().writeFile(.{ .sub_path = path, .data = text });
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

const test_board =
    \\(kicad_pcb (version 20260206) (generator "pcbnew")
    \\  (footprint "Capacitor_SMD:C_0402_1005Metric"
    \\    (at 10 20 90)
    \\    (property "Reference" "C1" (at 0 0 0))
    \\    (property "Value" "100nF" (at 0 0 0))
    \\    (pad "1" smd roundrect (at -0.48 0 90) (size 0.56 0.62) (net "VDD") (pintype "passive"))
    \\    (pad "2" smd roundrect (at 0.48 0 90) (size 0.56 0.62) (net "GND") (pintype "passive")))
    \\  (footprint "SamacSys_Parts:QFN50P600X600X100-41N"
    \\    (at 30 40)
    \\    (property "Reference" "IC1" (at 0 0 0))
    \\    (property "Value" "LMX2595RHAR" (at 0 0 0))
    \\    (property "Description" "Wideband synthesizer" (at 0 0 0))
    \\    (property "MPN" "LMX2595RHAR" (at 0 0 0))
    \\    (pad "1" smd roundrect (at -3 -2) (size 0.25 0.5) (net "/CAL_SW") (pinfunction "CE"))
    \\    (pad "2" smd roundrect (at -3 -1) (size 0.25 0.5) (net "Net-(IC1-Pad2)") (pinfunction "OSCIN"))
    \\    (pad "3" smd roundrect (at -3 0) (size 0.25 0.5) (net "unconnected-(IC1-Pad3)") (pinfunction "NC"))
    \\    (pad "42" thru_hole circle (at 0 0) (size 1 1) (drill 0.3) (net "GND") (pinfunction "EP"))
    \\    (pad "42" thru_hole circle (at 1 0) (size 1 1) (drill 0.3) (net "GND") (pinfunction "EP"))))
;

fn testParts(arena: std.mem.Allocator) ![]Part {
    const nodes = try parser_mod.parse(arena, test_board);
    return parseParts(arena, nodes[0]);
}

// spec: import_kicad - Parses board footprints into parts with ref, value, MPN, and per-pad net + pinfunction
test "parseParts reads refs, values, and pad nets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parts = try testParts(arena);
    try testing.expectEqual(@as(usize, 2), parts.len);
    try testing.expectEqualStrings("C1", parts[0].ref);
    try testing.expectEqualStrings("100nF", parts[0].value);
    try testing.expectEqualStrings("VDD", parts[0].pads[0].net);
    try testing.expectEqualStrings("IC1", parts[1].ref);
    try testing.expectEqualStrings("LMX2595RHAR", parts[1].mpn);
    try testing.expectEqualStrings("CE", parts[1].pads[0].func);
}

// spec: import_kicad - Sanitizes KiCad net names (sheet-slash stripped, auto-net parens dropped, unconnected pads null)
test "net name sanitization" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var nets = NetNames.init(arena);
    try testing.expectEqualStrings("CAL_SW", (try nets.resolve("/CAL_SW")).?);
    try testing.expectEqualStrings("Net-IC1-Pad2", (try nets.resolve("Net-(IC1-Pad2)")).?);
    // Dotted rails must stay distinct — the evaluator splits net names at
    // the first dot (bypass-stub convention), which would merge them.
    try testing.expectEqualStrings("+5_0V", (try nets.resolve("/+5.0V")).?);
    try testing.expectEqualStrings("+5_7V", (try nets.resolve("/+5.7V")).?);
    try testing.expect((try nets.resolve("unconnected-(IC1-Pad3)")) == null);
    try testing.expect((try nets.resolve("")) == null);
    // Distinct raw names may never merge after sanitization.
    try testing.expectEqualStrings("AB", (try nets.resolve("A(B")).?);
    try testing.expectEqualStrings("AB_2", (try nets.resolve("A)B")).?);

    // An empty raw name must not index trimmed[0]; it sanitizes to the "NET"
    // fallback. (The `trimmed.len > 0` bound guards the read; a `>=` flip
    // reads trimmed[0] out of bounds.)
    try testing.expectEqualStrings("NET", try sanitizeNetName(arena, ""));
}

// spec: import_kicad - Emits a design with family-mapped passives, custom-part imports, net-grouped pins, and deduped thermal pads
test "design text maps families and groups pins by net" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("lib/components");
    try tmp.dir.writeFile(.{ .sub_path = "lib/components/cap-0402.sexp", .data = "(component-family \"cap-0402\")" });
    const project_dir = try tmp.dir.realpathAlloc(arena, ".");

    const parts = try testParts(arena);
    for (parts) |*part| {
        if (try familyFor(arena, project_dir, part.*)) |fam| part.family = fam;
    }
    try testing.expectEqualStrings("cap-0402", parts[0].family.?);
    try testing.expect(parts[1].family == null);

    const comps = try collectCustomComps(arena, project_dir, parts);
    try testing.expectEqual(@as(usize, 1), comps.len);
    try testing.expectEqualStrings("lmx2595rhar", comps[0].name);

    var summary = ImportSummary{};
    const no_fold = import_fold.FoldResult{};
    const text = try buildDesignText(arena, .{
        .board_path = "test.kicad_pcb",
        .project_dir = project_dir,
        .name = "test",
        .title = "Test Board",
    }, parts, comps, &no_fold, &summary);

    try testing.expect(std.mem.indexOf(u8, text, "(import lmx2595rhar)") != null);
    try testing.expect(std.mem.indexOf(u8, text, "(instance \"C1\" (cap-0402 \"100nF\")") != null);
    try testing.expect(std.mem.indexOf(u8, text, "(instance \"IC1\" lmx2595rhar") != null);
    // Thermal-pad split: pad 42 appears once, on GND.
    try testing.expect(std.mem.indexOf(u8, text, "(pin 42 \"GND\")") != null);
    // Unconnected pad 3 dropped.
    try testing.expect(std.mem.indexOf(u8, text, "NC") == null);
    try testing.expectEqual(@as(usize, 1), summary.dropped_pins);
}

// spec: import_kicad - Generates pinout files from pad pinfunctions with numeric-then-alpha pin ordering
test "pinout generation dedups and sorts pads" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parts = try testParts(arena);
    const text = try renderPinout(arena, "lmx2595rhar", parts[1].pads);
    try testing.expect(std.mem.indexOf(u8, text, "(pinout \"lmx2595rhar\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "(pin 1 \"CE\")") != null);
    // EP split pads dedup to a single pin 42.
    const first = std.mem.indexOf(u8, text, "(pin 42").?;
    try testing.expect(std.mem.indexOfPos(u8, text, first + 1, "(pin 42") == null);
}

// spec: import_kicad - Normalizes pad angles against footprint rotation when emitting footprint geometry
test "footprint geometry subtracts footprint rotation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parts = try testParts(arena);
    // C1's footprint is placed at 90° and its pads carry (at … 90): the
    // local pad angle is 0, so width/height must NOT swap.
    const text = try renderFootprint(arena, parts[0]);
    // Pad geometry now prints at KiCad's own 4-decimal precision.
    try testing.expect(std.mem.indexOf(u8, text, "(size 0.5600 0.6200)") != null);
}

// spec: import_kicad - Renames pure-numeric and family-clashing component names so they stay referenceable atoms
test "component naming avoids numeric atoms and family clashes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("lib/components");
    try tmp.dir.writeFile(.{ .sub_path = "lib/components/led.sexp", .data = "(component-family \"led\")" });
    const project_dir = try tmp.dir.realpathAlloc(arena, ".");

    const board =
        \\(kicad_pcb (version 20260206)
        \\  (footprint "1724480006:MOLEX_1724480006"
        \\    (property "Reference" "J12" (at 0 0 0))
        \\    (property "Value" "1724480006" (at 0 0 0))
        \\    (property "Manufacturer_Name" "Molex" (at 0 0 0))
        \\    (pad "1" smd rect (at 0 0) (size 1 1) (net "GND")))
        \\  (footprint "LED_SMD:LED_0603_1608Metric"
        \\    (property "Reference" "D1" (at 0 0 0))
        \\    (property "Value" "LED" (at 0 0 0))
        \\    (pad "1" smd rect (at 0 0) (size 1 1) (net "LED_A"))
        \\    (pad "2" smd rect (at 1 0) (size 1 1) (net "GND"))))
    ;
    const nodes = try parser_mod.parse(arena, board);
    const parts = try parseParts(arena, nodes[0]);
    const comps = try collectCustomComps(arena, project_dir, parts);
    try testing.expectEqual(@as(usize, 2), comps.len);
    // Pure-numeric MPN gets the manufacturer slug so it parses as an atom.
    try testing.expectEqualStrings("molex-1724480006", comps[0].name);
    // "led" collides with the led component-family → footprint-derived name.
    try testing.expectEqualStrings("led-0603-1608metric", comps[1].name);
}

// spec: import_kicad - Sanitizes library names to lowercase slugs
test "sanitizeName slugs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("lt3045edd-1-trpbf", try sanitizeName(arena, "LT3045EDD-1#TRPBF"));
    try testing.expectEqualStrings("adp-2-20+", try sanitizeName(arena, "ADP-2-20+"));
    try testing.expectEqualStrings("wa-smsi-97730256330", try sanitizeName(arena, "WA-SMSI_97730256330"));
}
