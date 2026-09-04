//! KiCad schematic (`.kicad_sch`) exporter — the drawing half of the KiCad
//! handoff, next to `export_kicad`'s netlist.
//!
//! It consumes exactly the flat view the netlist exporter does
//! (`collectInstances` + `flattenAndMergeNets`), so ref-des and net spellings
//! are character-for-character identical and a symbol's `(uuid …)` is the same
//! identity the netlist's `(tstamp …)` and the board's footprint carry.
//!
//! The schematic is label-connected: every symbol pin gets a short wire stub
//! ending in a global label naming its net (or, for a ground rail, a power
//! symbol), and every unconnected pad gets a no-connect flag. Connectivity is
//! therefore correct by construction and placement is free to be merely tidy.
//!
//! The short connections are then **drawn**, the way a hand-drawn sheet does
//! it: a bypass cap's power leg reaching the exact IC pad its `(decouples …)`
//! declares, and any net whose entire design-wide membership is two or three
//! pins that landed in one cluster. Such a run keeps exactly one global label —
//! drop them all and KiCad would name the net `Net-(U1-Pad3)` and the identity
//! contract with the netlist would be gone — and its spokes lose theirs. A
//! connection with no clean orthogonal route simply keeps today's label pair,
//! so the drawing is always a strict improvement on it and never a risk to it.
//!
//! A design of any size comes out **hierarchical**: one child sheet per
//! `(section …)` — drawing the section's own parts plus the `(sub-block …)`
//! modules it adopts, per the same membership authority the review PDF and the
//! web viewer use — one sheet per module no section adopted, and a trailing
//! sheet for parts belonging to neither. Global labels join across sheets with
//! no path prefix, so the split costs nothing electrically. Small designs stay
//! on one flat sheet (see `flat_max_parts`), and `--flat` forces that anywhere.
//!
//! One caveat inherited from KiCad itself: a netlist *KiCad* generates from
//! this schematic escapes `/` in net names (`usb/DP` -> `usb{slash}DP`), so the
//! exported schematic must not drive "Update PCB from Schematic" against a
//! netlisp-synced board. netlisp's own netlist and file-based sync stay the
//! board authority.

const std = @import("std");
const env_mod = @import("eval/env.zig");
const na = @import("eval/net_analysis.zig");
const infra_fs = @import("infra/fs.zig");
const log = @import("infra/log.zig");
const membership = @import("diagram/membership.zig");
const decouple_key = @import("decouple_key.zig");
const export_kicad = @import("export_kicad.zig");
const netlist = @import("export_kicad_netlist.zig");
const compose = @import("kicad_sch/compose.zig");
const emit = @import("kicad_sch/emit.zig");
const glyph = @import("kicad_sch/glyph.zig");
const plan = @import("kicad_sch/plan.zig");
const project = @import("kicad_sch/project.zig");
const shape_mod = @import("kicad_sch/shape.zig");
const stagger = @import("kicad_sch/stagger.zig");
const stub = @import("kicad_sch/stub.zig");
const textbox = @import("kicad_sch/textbox.zig");
const vendor = @import("kicad_sch/vendor.zig");
const verify = @import("kicad_sch/verify.zig");
const sym_library = @import("kicad_sym/library.zig");
const lib_limits = @import("lib_limits.zig");
const net_name = @import("net_name.zig");

const DesignBlock = env_mod.DesignBlock;
const Section = env_mod.Section;
const FlatInstance = export_kicad.FlatInstance;
const FlatNet = export_kicad.FlatNet;
const Shape = shape_mod.Shape;

const footprint_path_template = "{s}/lib/footprints/{s}.sexp";
const unnamed_component = "unnamed-part";
const sheet_suffix = ".kicad_sch";

/// A design with at most this many placed parts stays on one flat sheet: a
/// hierarchy of near-empty pages is harder to read than a single tidy one, and
/// the split only pays for itself once a sheet would be crowded.
pub const flat_max_parts: usize = 24;

/// Errors the schematic exporter can raise: allocation, the writer's own
/// failure mode, every way the emitted bytes can fail their self-check, and
/// `PinNotDrawn` — a flattened connection that never reached a sheet.
pub const SchError = emit.EmitError || verify.VerifyError || error{PinNotDrawn};

/// How to render the design.
pub const Options = struct {
    /// Force one flat sheet regardless of size.
    flat: bool = false,
    /// Draw a part from its original `lib/sources/*.kicad_sym` when the
    /// project has one. Off means every symbol is a synthesised box.
    vendor: bool = true,
};

/// One emitted document. `name` is a bare filename; the caller writes it beside
/// the root, which is what the root's `Sheetfile` properties point at.
pub const SchFile = struct {
    name: []const u8,
    bytes: []const u8,
};

/// What the export drew, for a caller reporting on it rather than reading the
/// log line — the CLI tool's summary is built from exactly these counters.
pub const Stats = struct {
    /// Distinct library symbols synthesised: one per component, per `(part …)`
    /// breakdown.
    components: u32 = 0,
    /// How many of those were drawn from a real `lib/sources/*.kicad_sym`
    /// instead of a synthesised box.
    vendor_bodies: u32 = 0,
    /// Flattened instances the export placed.
    instances: u32 = 0,
};

/// The exported schematic: the root sheet first, then its children in page
/// order. Owned by the allocator passed to `exportSch`.
pub const Output = struct {
    files: []const SchFile,
    /// The KiCad project sidecars (`sym-lib-table`, `fp-lib-table`,
    /// `<design>.kicad_pro`, `netlisp.kicad_sym`) that make the sheets' library
    /// references resolve. Bare sibling filenames like `files`, so the whole
    /// export still lands in one directory. See `kicad_sch/project.zig`.
    sidecars: []const SchFile,
    stats: Stats = .{},

    pub fn deinit(self: Output, gpa: std.mem.Allocator) void {
        freeFiles(gpa, self.files);
        freeFiles(gpa, self.sidecars);
    }
};

fn freeFiles(gpa: std.mem.Allocator, files: []const SchFile) void {
    for (files) |f| {
        gpa.free(f.name);
        gpa.free(f.bytes);
    }
    gpa.free(files);
}

/// Render `block` as a `.kicad_sch` hierarchy. The returned files are owned by
/// `gpa`; everything else is scratch in an internal arena. Every file is
/// re-parsed and checked before it is returned, so a caller that gets a result
/// got a structurally sound schematic.
pub fn exportSch(
    gpa: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    design_name: []const u8,
    opts: Options,
) SchError!Output {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var instances: std.ArrayList(FlatInstance) = .empty;
    var nets: std.ArrayList(FlatNet) = .empty;
    try netlist.collectInstances(a, block, "", &instances);
    try export_kicad.flattenAndMergeNets(a, block, &nets);

    // Read once per export, before anything asks for a symbol: the index is
    // shared by every component and never rebuilt.
    var sym_lib = if (opts.vendor) try sym_library.load(a, project_dir) else sym_library.Library{};

    var builder = Builder{
        .a = a,
        .block = block,
        .project_dir = project_dir,
        .design = design_name,
        .opts = opts,
        .instances = instances.items,
        .nets = nets.items,
        .sym_lib = if (opts.vendor) &sym_lib else null,
    };
    const files = try builder.build();
    const side = try builder.projectSidecars();
    const owned_files = try own(gpa, files);
    errdefer freeFiles(gpa, owned_files);
    return .{
        .files = owned_files,
        .sidecars = try own(gpa, side),
        .stats = builder.stats,
    };
}

/// Copy the arena-built documents onto the caller's allocator, unwinding
/// cleanly if a later copy runs out of memory.
fn own(gpa: std.mem.Allocator, files: []const SchFile) std.mem.Allocator.Error![]const SchFile {
    var out: std.ArrayList(SchFile) = .empty;
    errdefer {
        for (out.items) |f| {
            gpa.free(f.name);
            gpa.free(f.bytes);
        }
        out.deinit(gpa);
    }
    for (files) |f| {
        const name = try gpa.dupe(u8, f.name);
        errdefer gpa.free(name);
        const bytes = try gpa.dupe(u8, f.bytes);
        try out.append(gpa, .{ .name = name, .bytes = bytes });
    }
    return out.toOwnedSlice(gpa);
}

/// A footprint's KiCad-side name plus its pad inventory, read once per
/// footprint. The pads widen each symbol so a pad that carries no net still
/// appears (and gets a no-connect flag) rather than vanishing.
const FpInfo = struct {
    kicad_name: []const u8,
    pads: []const []const u8,
};

/// What one component's pads carry on the FIRST instance that uses it. A
/// symbol's edges are ordered — and so its same-net gangs decided — against
/// that one instance, because the library entry is shared: a second instance
/// wired differently keeps the same drawing and simply gangs less of it.
const PadNets = struct {
    ref: []const u8 = "",
    net: std.StringHashMapUnmanaged([]const u8) = .empty,
};

/// Accumulator for one library component: everything needed to synthesise its
/// shape, unioned across every instance that uses it.
const Comp = struct {
    /// The names the library symbol is looked up and named by (the component
    /// key also encodes the part breakdown, which must not leak into either).
    names: shape_mod.Names,
    footprint: []const u8,
    glyph: glyph.Class,
    parts: []const shape_mod.PartSpec,
    pins: PadNets = .{},
    used: std.ArrayList([]const u8) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    shape: u32 = 0,
};

/// Which document one flattened instance is drawn on, and in what order the
/// documents come out. Sections first, in declaration order; then the modules
/// no section adopted; then everything belonging to neither.
const SheetKind = enum(u2) { section = 0, module = 1, unsectioned = 2 };

/// One sheet's placeables plus the library subset they index into.
const SheetItems = struct {
    items: []compose.Placeable,
    shapes: []const Shape,
};

/// One child document: its title, filename, and the instances it draws.
const SheetPlan = struct {
    title: []const u8,
    file: []const u8,
    uuid: []const u8,
    members: []const u32,
};

const Builder = struct {
    a: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    design: []const u8,
    opts: Options,
    instances: []const FlatInstance,
    nets: []const FlatNet,
    /// "REF\x00PAD" -> flattened net name.
    pin_net: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Decoupling cap ref -> the IC pad it declares it serves, and net name ->
    /// how many pins it has design-wide. Both are what lets a sheet decide
    /// which connections it may draw as real wire rather than a label pair.
    binds: std.StringHashMapUnmanaged(compose.Bind) = .empty,
    net_pins: std.StringHashMapUnmanaged(u32) = .empty,
    /// Per-pin bypass-stub net -> the base rail its LABEL is spelled as.
    /// Display only: every other use of a net name keeps netlisp's spelling.
    labels: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// ref-des -> flat instance index.
    ref_inst: std.StringHashMapUnmanaged(u32) = .empty,
    /// internal footprint id -> KiCad name + pads.
    fp: std.StringHashMapUnmanaged(FpInfo) = .empty,
    /// component key -> accumulated symbol requirements, in first-use order.
    comps: std.StringArrayHashMapUnmanaged(Comp) = .empty,
    shapes: std.ArrayList(Shape) = .empty,
    /// flat index -> the source instance it was flattened from.
    src: std.ArrayList(*const env_mod.Instance) = .empty,
    /// flat index -> its component key.
    keys: std.ArrayList([]const u8) = .empty,
    /// ref-des -> index of the `(section …)` declaring it.
    sec_of_ref: std.StringHashMapUnmanaged(u32) = .empty,
    /// flat instance index -> owning top-level sub-block index (null = the
    /// design's own instances).
    owners: std.ArrayList(?u32) = .empty,
    /// sub-block index -> section index it attaches to.
    attach: []?usize = &.{},
    captions: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    /// Running `#PWR…` / `#FLG…` sequence across every sheet.
    seq: u32 = 0,
    /// The project's vendor `.kicad_sym` index; null when `--no-vendor-symbols`
    /// switched the passthrough off.
    sym_lib: ?*const sym_library.Library = null,
    /// Coverage counters, filled in once the symbols are synthesised.
    stats: Stats = .{},
    /// Colliding text pairs across every sheet — a readability warning, never a
    /// failure. See `noteOverlaps`.
    overlaps: usize = 0,

    fn build(self: *Builder) SchError![]const SchFile {
        try self.indexNets();
        try self.loadFootprints();
        try self.indexGroups();
        try self.indexWiring();
        try self.buildComponents();

        const sheets = try self.partition();
        const files = if (self.opts.flat or sheets.len < 2 or self.instances.len <= flat_max_parts)
            try self.buildFlat()
        else
            try self.buildHierarchy(sheets);
        if (self.overlaps > 0) {
            log.progress(
                "export-kicad-sch: {s}: {d} overlapping text pairs across {d} sheets",
                .{ self.design, self.overlaps, files.len },
            );
        }
        return files;
    }

    /// Build the pin -> net index and the ref -> instance index. First net
    /// wins for a pad listed twice, which keeps the emitted label stable.
    fn indexNets(self: *Builder) std.mem.Allocator.Error!void {
        for (self.instances, 0..) |inst, i| {
            const gop = try self.ref_inst.getOrPut(self.a, inst.ref_des);
            if (!gop.found_existing) gop.value_ptr.* = @intCast(i);
        }
        for (self.nets) |net| {
            for (net.pins) |pin| {
                const key = try pinKey(self.a, pin.ref_des, pin.pin);
                const gop = try self.pin_net.getOrPut(self.a, key);
                if (!gop.found_existing) gop.value_ptr.* = net.name;
            }
        }
        try self.indexStubLabels();
    }

    /// Which nets are per-pin bypass stubs, and so get their base rail's name
    /// on the label instead of their own. Reported, because it is the one place
    /// the drawn sheet says less than netlisp's netlist: the split survives in
    /// the netlist and on the board, only the schematic merges it.
    fn indexStubLabels(self: *Builder) std.mem.Allocator.Error!void {
        const n = try stub.collapse(self.a, self.nets, &self.ref_inst, &self.labels);
        if (n == 0) return;
        log.progress(
            "export-kicad-sch: {s}: {d} per-pin bypass-stub nets labelled as their base rail",
            .{ self.design, n },
        );
    }

    /// How one net name is spelled on this design's labels and rail symbols.
    fn labelOf(self: *Builder, net: []const u8) []const u8 {
        return self.labels.get(net) orelse net;
    }

    /// What a sheet needs before it can draw a connection instead of labelling
    /// it: which IC pad each decoupling cap declares (re-qualified into the
    /// cap's own sub-block, so a module's `(decouples "U1" 24)` means that
    /// module's U1), and how many pins every net has across the WHOLE design.
    /// The design-wide count is the guard that keeps a wire honest — a net with
    /// a pin on another sheet is never drawn as a closed run.
    fn indexWiring(self: *Builder) std.mem.Allocator.Error!void {
        for (self.instances, 0..) |inst, i| {
            if (try self.bindOf(inst, self.src.items[i])) |bind| {
                try self.binds.put(self.a, inst.ref_des, bind);
            }
        }
        for (self.nets) |net| {
            const gop = try self.net_pins.getOrPut(self.a, net.name);
            gop.value_ptr.* = @intCast(net.pins.len);
        }
    }

    /// The IC pad one bypass cap serves. An explicit `(decouples "IC" PIN)`
    /// names both, and only needs its module-local IC re-qualified into the
    /// cap's own sub-block. A `(decouple … per-pin …)` child names only the pad,
    /// in its structural key — its IC is whichever hub carries that pad on the
    /// cap's own supply net.
    fn bindOf(
        self: *Builder,
        inst: FlatInstance,
        src: *const env_mod.Instance,
    ) std.mem.Allocator.Error!?compose.Bind {
        if (src.bind.decouple.pin.len > 0 and src.bind.decouple.ic.len > 0) {
            return .{
                .ref = try qualify(self.a, inst.ref_des, src.bind.decouple.ic),
                .pad = src.bind.decouple.pin,
            };
        }
        const pad = decouplePinFromOrigin(inst.origin_key) orelse return null;
        return self.hubOnSupplyNet(inst.ref_des, pad);
    }

    /// The hub carrying `pad` on the non-ground net `ref` also sits on. A
    /// per-pin bypass cap and the pad it serves share that net by construction,
    /// so this recovers the IC the shorthand never spelled out.
    fn hubOnSupplyNet(self: *Builder, ref: []const u8, pad: []const u8) ?compose.Bind {
        for (self.nets) |net| {
            if (compose.isRailNet(net.name)) continue;
            if (!netTouches(net, ref)) continue;
            for (net.pins) |pin| {
                if (plan.isPassiveRef(pin.ref_des)) continue;
                if (!std.mem.eql(u8, pin.pin, pad)) continue;
                return .{ .ref = pin.ref_des, .pad = pad };
            }
        }
        return null;
    }

    fn netFacts(self: *Builder) compose.NetFacts {
        return .{ .binds = &self.binds, .net_pins = &self.net_pins, .labels = &self.labels };
    }

    /// Read every distinct footprint once for its declared KiCad name (the
    /// spelling the netlist uses) and its pad list.
    fn loadFootprints(self: *Builder) std.mem.Allocator.Error!void {
        for (self.instances) |inst| {
            if (inst.footprint.len == 0 or self.fp.contains(inst.footprint)) continue;
            var info = FpInfo{ .kicad_name = inst.footprint, .pads = &.{} };
            const path = try std.fmt.allocPrint(self.a, footprint_path_template, .{ self.project_dir, inst.footprint });
            if (infra_fs.cwd().readFileAlloc(self.a, path, lib_limits.max_footprint_bytes)) |src| {
                if (netlist.extractFootprintName(self.a, src)) |name| {
                    info.kicad_name = name;
                } else |_| {}
                if (netlist.extractPadNames(self.a, src)) |pads| {
                    info.pads = pads;
                } else |_| {}
            } else |_| {}
            try self.fp.put(self.a, inst.footprint, info);
        }
    }

    /// Group instances by library component and synthesise one shape each. Two
    /// instances of the same component with different `(part …)` breakdowns
    /// need different symbols, so the key carries the breakdown too.
    fn buildComponents(self: *Builder) std.mem.Allocator.Error!void {
        for (self.instances, 0..) |inst, i| {
            const src = self.src.items[i];
            const key = try self.componentKey(inst, src);
            try self.keys.append(self.a, key);
            const gop = try self.comps.getOrPut(self.a, key);
            if (!gop.found_existing) gop.value_ptr.* = .{
                .names = .{
                    .component = baseName(inst),
                    .symbol = inst.symbol,
                    .pinout = inst.pinout,
                },
                .footprint = inst.footprint,
                .glyph = glyph.classify(baseName(inst), inst.symbol, inst.ref_des),
                .parts = try self.partSpecs(src),
                .pins = .{ .ref = inst.ref_des },
            };
        }
        for (self.nets) |net| {
            for (net.pins) |pin| {
                const inst_i = self.ref_inst.get(pin.ref_des) orelse continue;
                const comp = self.comps.getPtr(self.keys.items[inst_i]).?;
                try self.notePadNet(comp, pin, net.name);
                if ((try comp.seen.fetchPut(self.a, pin.pin, {})) != null) continue;
                try comp.used.append(self.a, pin.pin);
            }
        }
        try self.synthShapes();
    }

    /// Record what one pad of a component's FIRST instance carries, under the
    /// name the sheet will LABEL it with — a per-pin bypass stub gangs with the
    /// rest of its rail because that is what the drawing already merged them
    /// into. First net wins, matching the pin -> net index.
    fn notePadNet(
        self: *Builder,
        comp: *Comp,
        pin: export_kicad.FlatPin,
        net: []const u8,
    ) std.mem.Allocator.Error!void {
        if (!std.mem.eql(u8, comp.pins.ref, pin.ref_des)) return;
        const gop = try comp.pins.net.getOrPut(self.a, pin.pin);
        if (!gop.found_existing) gop.value_ptr.* = self.labelOf(net);
    }

    /// Symbol-sharing key: the library component, plus the `(part …)`
    /// breakdown when the instance declares one.
    fn componentKey(
        self: *Builder,
        inst: FlatInstance,
        src: *const env_mod.Instance,
    ) std.mem.Allocator.Error![]const u8 {
        const base = baseName(inst);
        if (src.parts.len == 0) return base;
        var sig: std.ArrayList(u8) = .empty;
        try sig.appendSlice(self.a, base);
        for (src.parts) |part| {
            try sig.append(self.a, '#');
            try sig.appendSlice(self.a, part.name);
            for (part.pins) |p| {
                try sig.append(self.a, ',');
                try sig.appendSlice(self.a, p.pin);
            }
        }
        return sig.items;
    }

    fn partSpecs(self: *Builder, src: *const env_mod.Instance) std.mem.Allocator.Error![]const shape_mod.PartSpec {
        if (src.parts.len == 0) return &.{};
        const out = try self.a.alloc(shape_mod.PartSpec, src.parts.len);
        for (src.parts, 0..) |part, i| {
            const pads = try self.a.alloc([]const u8, part.pins.len);
            for (part.pins, 0..) |p, k| pads[k] = p.pin;
            out[i] = .{ .title = part.name, .pads = pads };
        }
        return out;
    }

    /// Build a shape per component — its vendor `.kicad_sym` body when the
    /// project has one, otherwise a synthesised box — and give each a unique
    /// library name: two components whose names sanitize to the same token
    /// would otherwise share (and corrupt) one `lib_symbols` entry.
    fn synthShapes(self: *Builder) std.mem.Allocator.Error!void {
        var names: std.StringHashMapUnmanaged(void) = .empty;
        defer names.deinit(self.a);
        var drawn: usize = 0;
        for (self.comps.values(), 0..) |*comp, i| {
            const fp = self.fp.get(comp.footprint);
            const body = try vendor.synth(self.a, self.sym_lib, .{
                .names = comp.names,
                .project_dir = self.project_dir,
                .fp_pads = if (fp) |f| f.pads else &.{},
                .used = comp.used.items,
                .parts = comp.parts,
                .glyph = comp.glyph,
                .nets = &comp.pins.net,
            });
            // A vendor body may put its pins closer together than the labels
            // beside them fit; the pins are its own and stay put, so the space
            // is made outside the body by dealing the labels into two columns.
            var s = try stagger.spread(self.a, body, &comp.pins.net);
            if (s.vendor) drawn += 1;
            var suffix: u32 = 1;
            while (names.contains(s.lib_name)) : (suffix += 1) {
                s.lib_name = try std.fmt.allocPrint(self.a, "{s}_{d}", .{ s.lib_name, suffix });
            }
            try names.put(self.a, s.lib_name, {});
            comp.shape = @intCast(i);
            try self.shapes.append(self.a, s);
        }
        self.stats = .{
            .components = @intCast(self.comps.count()),
            .vendor_bodies = @intCast(drawn),
            .instances = @intCast(self.instances.len),
        };
        self.reportVendorCoverage(drawn);
    }

    /// One line naming how much of the design is drawn from real vendor
    /// symbols. It is the only way to see the passthrough's reach on a board,
    /// and the number a reviewer compares across revisions.
    fn reportVendorCoverage(self: *Builder, drawn: usize) void {
        const lib = self.sym_lib orelse return;
        if (lib.files == 0) return;
        log.progress(
            "export-kicad-sch: {s}: {d}/{d} components drawn from vendor symbols ({d} libraries indexed)",
            .{ self.design, drawn, self.comps.count(), lib.files },
        );
    }

    fn shapeOf(self: *Builder, idx: usize) u32 {
        return (self.comps.get(self.keys.items[idx]) orelse return 0).shape;
    }

    /// Index which `(section …)` declares each top-level ref, which sub-block
    /// owns each flattened instance, and which section adopts each sub-block.
    fn indexGroups(self: *Builder) std.mem.Allocator.Error!void {
        for (self.block.sections, 0..) |sec, i| try self.indexSection(sec, @intCast(i));
        try walkTree(self.a, self.block, null, &self.owners, &self.src);
        self.attach = try membership.computeSubBlockAttachments(self.a, self.block);
    }

    fn indexSection(self: *Builder, sec: Section, index: u32) std.mem.Allocator.Error!void {
        for (sec.instances) |inst| {
            const gop = try self.sec_of_ref.getOrPut(self.a, inst.ref_des);
            if (!gop.found_existing) gop.value_ptr.* = index;
        }
        for (sec.pin_groups) |pg| {
            const gop = try self.sec_of_ref.getOrPut(self.a, pg.ref_des);
            if (!gop.found_existing) gop.value_ptr.* = index;
        }
        for (sec.sub_sections) |sub| try self.indexSection(sub, index);
    }

    /// Which document draws one flattened instance. A sub-block follows the
    /// section that adopts it (per the membership authority the schematic page
    /// and the review PDF use); an unadopted module gets a sheet of its own,
    /// which is what makes a section-less board readable instead of one wall.
    fn sheetKeyOf(self: *Builder, idx: usize) u64 {
        const owner = if (idx < self.owners.items.len) self.owners.items[idx] else null;
        if (owner) |sb| {
            const sec: ?usize = if (sb < self.attach.len) self.attach[sb] else null;
            if (sec) |s| return sheetKey(.section, s);
            return sheetKey(.module, sb);
        }
        if (self.sec_of_ref.get(self.instances[idx].ref_des)) |s| return sheetKey(.section, s);
        return sheetKey(.unsectioned, 0);
    }

    /// Placement group inside a document: a section's own parts, or one
    /// `(sub-block …)` module. A change starts a new shelf under a caption.
    fn groupOf(self: *Builder, idx: usize) std.mem.Allocator.Error!u64 {
        const n_sec: u64 = self.block.sections.len;
        const owner = if (idx < self.owners.items.len) self.owners.items[idx] else null;
        if (owner) |sb| {
            const sec: ?usize = if (sb < self.attach.len) self.attach[sb] else null;
            return (@as(u64, if (sec) |s| s else n_sec) << 32) | (@as(u64, sb) + 1);
        }
        const sec = self.sec_of_ref.get(self.instances[idx].ref_des);
        return @as(u64, if (sec) |s| s else n_sec + 1) << 32;
    }

    /// Human-readable band title for a placement group, memoised so the same
    /// group always renders one caption string.
    fn captionFor(self: *Builder, key: u64) std.mem.Allocator.Error![]const u8 {
        const gop = try self.captions.getOrPut(self.a, key);
        if (gop.found_existing) return gop.value_ptr.*;
        const n_sec: u64 = self.block.sections.len;
        const sec = key >> 32;
        const sub = key & 0xffff_ffff;
        const sec_name = if (sec < n_sec) self.block.sections[@intCast(sec)].name else "";
        gop.value_ptr.* = if (sub > 0) blk: {
            const sb_name = self.block.sub_blocks[@intCast(sub - 1)].name;
            break :blk if (sec_name.len > 0)
                try std.fmt.allocPrint(self.a, "{s} / {s}", .{ sec_name, sb_name })
            else
                try std.fmt.allocPrint(self.a, "sub-block {s}", .{sb_name});
        } else if (sec_name.len > 0) sec_name else "Unsectioned";
        return gop.value_ptr.*;
    }

    /// Partition the flattened instances into documents, in sheet-key order.
    fn partition(self: *Builder) std.mem.Allocator.Error![]SheetPlan {
        var order: std.ArrayList(u64) = .empty;
        var members: std.AutoArrayHashMapUnmanaged(u64, std.ArrayList(u32)) = .empty;
        for (self.instances, 0..) |_, i| {
            const key = self.sheetKeyOf(i);
            const gop = try members.getOrPut(self.a, key);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
                try order.append(self.a, key);
            }
            try gop.value_ptr.append(self.a, @intCast(i));
        }
        std.mem.sort(u64, order.items, {}, lessU64);

        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(self.a);
        const out = try self.a.alloc(SheetPlan, order.items.len);
        for (order.items, 0..) |key, i| {
            const title = try self.sheetTitle(key);
            const stem = try plan.uniqueName(self.a, try plan.slugify(self.a, title, "sheet"), &seen);
            out[i] = .{
                .title = title,
                .file = try std.fmt.allocPrint(self.a, "{s}-{s}" ++ sheet_suffix, .{ self.design, stem }),
                .uuid = try emit.elementUuid(self.a, self.design, "sheet", stem),
                .members = members.get(key).?.items,
            };
        }
        return out;
    }

    fn sheetTitle(self: *Builder, key: u64) std.mem.Allocator.Error![]const u8 {
        const idx: usize = @intCast(key & 0xffff_ffff);
        return switch (@as(SheetKind, @fromBackingInt(@intCast(key >> 32)))) {
            .section => if (idx < self.block.sections.len and self.block.sections[idx].name.len > 0)
                self.block.sections[idx].name
            else
                try std.fmt.allocPrint(self.a, "Section {d}", .{idx + 1}),
            .module => try std.fmt.allocPrint(self.a, "sub-block {s}", .{self.block.sub_blocks[idx].name}),
            .unsectioned => "Unsectioned",
        };
    }

    /// Every ground rail on the design, in first-seen order. Each needs one
    /// `power_out` driver or KiCad's ERC reports `power_pin_not_driven` for
    /// every ground symbol the sheets place.
    fn railNets(self: *Builder) std.mem.Allocator.Error![]const []const u8 {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(self.a);
        var out: std.ArrayList([]const u8) = .empty;
        for (self.nets) |net| {
            // Rails are named as they are LABELLED, so a rail symbol placed on
            // a collapsed stub still finds its entry in the shipped library.
            const name = self.labelOf(net.name);
            if (!compose.isRailNet(name)) continue;
            if (!self.drawsAnyPin(net)) continue;
            if ((try seen.fetchPut(self.a, name, {})) != null) continue;
            try out.append(self.a, name);
        }
        return out.items;
    }

    /// The KiCad project sidecars for this export. Built after the sheets, so
    /// `self.shapes` already holds the union of every symbol any sheet placed
    /// — the symbol library has to carry all of them or KiCad reports the
    /// missing ones exactly as it reported the missing library.
    fn projectSidecars(self: *Builder) SchError![]const SchFile {
        const nets = try self.railNets();
        const rails = try self.a.alloc(emit.Rail, nets.len);
        for (nets, rails) |net, *r| r.* = try compose.railFor(self.a, net);
        const side = try project.sidecars(self.a, self.design, self.shapes.items, rails);
        const out = try self.a.alloc(SchFile, side.len);
        for (side, out) |s, *f| f.* = .{ .name = s.name, .bytes = s.bytes };
        return out;
    }

    fn drawsAnyPin(self: *Builder, net: FlatNet) bool {
        for (net.pins) |pin| {
            if (self.ref_inst.contains(pin.ref_des)) return true;
        }
        return false;
    }

    /// Everything on one flat sheet — the small-design and `--flat` path.
    fn buildFlat(self: *Builder) SchError![]const SchFile {
        const all = try self.a.alloc(u32, self.instances.len);
        for (all, 0..) |*m, i| m.* = @intCast(i);
        const root_uuid = try emit.elementUuid(self.a, self.design, "root", "");
        const flat_items = try self.sheetItems(all);
        const bytes = try self.renderSheet(.{
            .sheet = .{
                .design = self.design,
                .root_uuid = root_uuid,
                .sheet_uuid = root_uuid,
                .page_w = 0,
                .page_h = 0,
                .is_root = true,
            },
            .shapes = flat_items.shapes,
            .items = flat_items.items,
            .flag_nets = try self.railNets(),
            .seq = &self.seq,
            .facts = self.netFacts(),
        });
        try self.checkCoverage(all);
        return self.oneFile(bytes);
    }

    fn oneFile(self: *Builder, bytes: []const u8) std.mem.Allocator.Error![]const SchFile {
        const out = try self.a.alloc(SchFile, 1);
        out[0] = .{
            .name = try std.fmt.allocPrint(self.a, "{s}" ++ sheet_suffix, .{self.design}),
            .bytes = bytes,
        };
        return out;
    }

    /// A root sheet of `(sheet …)` links plus one child document per section,
    /// unadopted module, and the trailing unsectioned bucket.
    fn buildHierarchy(self: *Builder, sheets: []const SheetPlan) SchError![]const SchFile {
        const root_uuid = try emit.elementUuid(self.a, self.design, "root", "");
        var files: std.ArrayList(SchFile) = .empty;
        try files.append(self.a, .{ .name = "", .bytes = "" }); // placeholder for the root

        const children = try self.a.alloc(emit.SheetRef, sheets.len);
        for (sheets, 0..) |s, i| {
            const drawn = try self.sheetItems(s.members);
            children[i] = .{
                .name = s.title,
                .file = s.file,
                .uuid = s.uuid,
                .page = @intCast(i + 2),
                .at = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            };
            const bytes = try self.renderSheet(.{
                .sheet = .{
                    .design = self.design,
                    .title = s.title,
                    .root_uuid = root_uuid,
                    .sheet_uuid = s.uuid,
                    .page_w = 0,
                    .page_h = 0,
                    .is_root = false,
                },
                .shapes = drawn.shapes,
                .items = drawn.items,
                .seq = &self.seq,
                .facts = self.netFacts(),
            });
            try files.append(self.a, .{ .name = s.file, .bytes = bytes });
        }

        const root = try self.renderSheet(.{
            .sheet = .{
                .design = self.design,
                .title = self.block.name,
                .root_uuid = root_uuid,
                .sheet_uuid = root_uuid,
                .page_w = 0,
                .page_h = 0,
                .is_root = true,
            },
            .shapes = &.{},
            .items = &.{},
            .children = children,
            .flag_nets = try self.railNets(),
            .seq = &self.seq,
        });
        files.items[0] = .{
            .name = try std.fmt.allocPrint(self.a, "{s}" ++ sheet_suffix, .{self.design}),
            .bytes = root,
        };

        const all = try self.a.alloc(u32, self.instances.len);
        for (all, 0..) |*m, i| m.* = @intCast(i);
        try self.checkCoverage(all);
        return files.items;
    }

    fn renderSheet(self: *Builder, req: compose.Request) SchError![]const u8 {
        const result = try compose.compose(self.a, req);
        const bytes = try emit.render(self.a, result.doc);
        self.noteOverlaps(req.sheet.title, try verify.check(self.a, bytes, result.expect));
        return bytes;
    }

    /// Report one sheet's colliding text. This is a WARNING and never a
    /// failure: the extents behind it are estimates (`kicad_sch/textbox.zig`)
    /// and KiCad loads and netlists the sheet either way — but the count is the
    /// only measure of whether a placement change made the drawing more or less
    /// readable, so it is printed per sheet and totalled at the end.
    fn noteOverlaps(self: *Builder, title: []const u8, report: textbox.Report) void {
        self.overlaps += report.overlaps;
        const pair = report.first orelse return;
        log.progress(
            "export-kicad-sch: {s}: {s}: {d} overlapping text pairs of {d} drawn texts" ++
                " (e.g. {s} \"{s}\" over {s} \"{s}\" at {d},{d})",
            .{
                self.design,
                if (title.len > 0) title else "root",
                report.overlaps,
                report.texts,
                @tagName(pair.kind_a),
                pair.a,
                @tagName(pair.kind_b),
                pair.b,
                @divTrunc(pair.x, 100),
                @divTrunc(pair.y, 100),
            },
        );
    }

    /// Build one sheet's placeables: one per unit of every member instance,
    /// bucketed by placement group, clustered inside each group, and ordered so
    /// a cluster's members are contiguous.
    fn placeables(self: *Builder, members: []const u32) std.mem.Allocator.Error![]compose.Placeable {
        var raw: std.ArrayList(compose.Placeable) = .empty;
        for (members) |m| try self.unitsOf(m, &raw);

        var buckets: std.AutoArrayHashMapUnmanaged(u64, std.ArrayList(compose.Placeable)) = .empty;
        var order: std.ArrayList(u64) = .empty;
        for (raw.items) |it| {
            const gop = try buckets.getOrPut(self.a, it.group);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
                try order.append(self.a, it.group);
            }
            try gop.value_ptr.append(self.a, it);
        }
        std.mem.sort(u64, order.items, {}, lessU64);

        var out: std.ArrayList(compose.Placeable) = .empty;
        for (order.items) |g| try self.clusterGroup(buckets.getPtr(g).?.items, &out);
        return out.items;
    }

    /// One sheet's drawable content: its placeables and the narrowed library
    /// they index into.
    fn sheetItems(self: *Builder, members: []const u32) std.mem.Allocator.Error!SheetItems {
        const items = try self.placeables(members);
        return .{ .items = items, .shapes = try self.subsetShapes(items) };
    }

    /// Narrow the library to the shapes one sheet actually places, and re-index
    /// its placeables onto that subset. Emitting every component's symbol into
    /// every sheet would multiply the whole library by the sheet count.
    fn subsetShapes(
        self: *Builder,
        items: []compose.Placeable,
    ) std.mem.Allocator.Error![]const Shape {
        var index: std.AutoHashMapUnmanaged(u32, u32) = .empty;
        defer index.deinit(self.a);
        var used: std.ArrayList(Shape) = .empty;
        for (items) |*it| {
            const gop = try index.getOrPut(self.a, it.shape);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(used.items.len);
                try used.append(self.a, self.shapes.items[it.shape]);
            }
            it.shape = gop.value_ptr.*;
        }
        return used.items;
    }

    /// Cluster one placement group and append it in draw order.
    fn clusterGroup(
        self: *Builder,
        group: []compose.Placeable,
        out: *std.ArrayList(compose.Placeable),
    ) std.mem.Allocator.Error!void {
        const members = try self.a.alloc(plan.Member, group.len);
        for (group, 0..) |it, i| members[i] = try self.memberOf(it);
        const placement = try plan.cluster(self.a, members);
        for (placement.order, placement.cluster) |i, c| {
            var it = group[i];
            it.cluster = c;
            try out.append(self.a, it);
        }
    }

    /// One placeable's clustering record: is it a hub, which IC does it declare
    /// itself against, and which non-ground nets does it touch.
    fn memberOf(self: *Builder, it: compose.Placeable) std.mem.Allocator.Error!plan.Member {
        const idx = self.ref_inst.get(it.id.ref) orelse 0;
        const src = if (idx < self.src.items.len) self.src.items[idx] else null;
        var nets: std.ArrayList([]const u8) = .empty;
        for (it.nets) |n| {
            if (n.len == 0 or compose.isRailNet(n)) continue;
            try nets.append(self.a, n);
        }
        return .{
            .hub = !plan.isPassiveRef(it.id.ref),
            .ref = it.id.ref,
            .bound_ref = if (src) |s| try qualify(self.a, it.id.ref, s.bind.decouple.ic) else "",
            .order = if (src) |s| s.bind.decouple.pin else "",
            .nets = nets.items,
        };
    }

    /// One placeable per unit of a flattened instance, sharing the reference
    /// but each with its own UUID — KiCad merges them back into one component.
    fn unitsOf(
        self: *Builder,
        idx: u32,
        out: *std.ArrayList(compose.Placeable),
    ) std.mem.Allocator.Error!void {
        const inst = self.instances[idx];
        const shape_idx = self.shapeOf(idx);
        const group = try self.groupOf(idx);
        const caption = try self.captionFor(group);
        const id = try self.identityOf(inst);
        for (self.shapes.items[shape_idx].units, 0..) |u, ui| {
            const nets = try self.a.alloc([]const u8, u.pins.len);
            for (u.pins, 0..) |pin, pi| nets[pi] = self.netOf(inst.ref_des, pin.pad);
            var unit_id = id;
            if (ui > 0) unit_id.uuid = try self.unitUuid(inst.ref_des, u.number);
            try out.append(self.a, .{
                .id = unit_id,
                .shape = shape_idx,
                .unit = @intCast(ui),
                .group = group,
                .caption = caption,
                .nets = nets,
                .cluster = 0,
            });
        }
    }

    fn identityOf(self: *Builder, inst: FlatInstance) std.mem.Allocator.Error!emit.Identity {
        return .{
            .ref = inst.ref_des,
            .value = inst.value,
            .footprint = try self.footprintField(inst),
            .properties = inst.properties,
            .uuid = if (inst.uuid.len > 0)
                inst.uuid
            else
                try emit.elementUuid(self.a, self.design, "sym", inst.ref_des),
            .dnp = inst.dnp,
        };
    }

    /// Unit 1 keeps the instance's own UUID — the identity the netlist and the
    /// board share. Later units need distinct ones, derived from the same ref.
    fn unitUuid(self: *Builder, ref: []const u8, number: u32) std.mem.Allocator.Error![]const u8 {
        const path = try std.fmt.allocPrint(self.a, "{s}:{d}", .{ ref, number });
        return emit.elementUuid(self.a, self.design, "unit", path);
    }

    fn netOf(self: *Builder, ref: []const u8, pad: []const u8) []const u8 {
        const key = pinKey(self.a, ref, pad) catch return "";
        return self.pin_net.get(key) orelse "";
    }

    /// The KiCad library spelling of an instance's footprint, matching the
    /// netlist exporter's `footprints:<declared name>` exactly.
    fn footprintField(self: *Builder, inst: FlatInstance) std.mem.Allocator.Error![]const u8 {
        if (inst.footprint.len == 0) return "";
        const info = self.fp.get(inst.footprint);
        const name = if (info) |f| f.kicad_name else inst.footprint;
        return std.fmt.allocPrint(self.a, "footprints:{s}", .{name});
    }

    /// Every flattened pin on a part the export placed must have become a
    /// symbol pin — otherwise the netlist carries a connection the schematic
    /// silently lost. Checked against the flattener itself, not against the
    /// exporter's own bookkeeping.
    fn checkCoverage(self: *Builder, members: []const u32) SchError!void {
        var drawn: std.StringHashMapUnmanaged(void) = .empty;
        defer drawn.deinit(self.a);
        for (members) |m| {
            const inst = self.instances[m];
            for (self.shapes.items[self.shapeOf(m)].units) |u| {
                for (u.pins) |pin| try drawn.put(self.a, try pinKey(self.a, inst.ref_des, pin.pad), {});
            }
        }
        try self.warnOrphanPins();
        if (try firstUndrawn(self.a, self.nets, &self.ref_inst, &drawn)) |pin| {
            log.warn(
                "export-kicad-sch: pin {s}.{s} is on a net but has no symbol pin",
                .{ pin.ref_des, pin.pin },
            );
            return error.PinNotDrawn;
        }
    }

    /// A net pin naming a ref-des with no instance cannot be drawn — the
    /// netlist would carry it but the schematic cannot. Report it rather than
    /// silently dropping the connection.
    fn warnOrphanPins(self: *Builder) std.mem.Allocator.Error!void {
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(self.a);
        for (self.nets) |net| {
            for (net.pins) |pin| {
                if (self.ref_inst.contains(pin.ref_des)) continue;
                if ((try seen.fetchPut(self.a, pin.ref_des, {})) != null) continue;
                log.warn(
                    "export-kicad-sch: net '{s}' references '{s}' which has no instance — pin not drawn",
                    .{ net.name, pin.ref_des },
                );
            }
        }
    }
};

/// The first flattened pin that belongs to a placed part yet never became a
/// symbol pin, or null when the sheets cover them all. Pins on a ref-des with
/// no instance are excluded — they are reported separately and are undrawable
/// by nature.
fn firstUndrawn(
    a: std.mem.Allocator,
    nets: []const FlatNet,
    known: *const std.StringHashMapUnmanaged(u32),
    drawn: *const std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!?export_kicad.FlatPin {
    for (nets) |net| {
        for (net.pins) |pin| {
            if (!known.contains(pin.ref_des)) continue;
            if (drawn.contains(try pinKey(a, pin.ref_des, pin.pin))) continue;
            return pin;
        }
    }
    return null;
}

fn sheetKey(kind: SheetKind, index: usize) u64 {
    return (@as(u64, @backingInt(kind)) << 32) | @as(u64, index);
}

fn lessU64(_: void, x: u64, y: u64) bool {
    return x < y;
}

fn pinKey(a: std.mem.Allocator, ref: []const u8, pad: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "{s}\x00{s}", .{ ref, pad });
}

/// Library name of an instance's component, falling back to its symbol name and
/// finally to a shared placeholder.
fn baseName(inst: FlatInstance) []const u8 {
    if (inst.component.len > 0) return inst.component;
    if (inst.symbol.len > 0) return inst.symbol;
    return unnamed_component;
}

/// True when a net lists a pin on `ref`.
fn netTouches(net: FlatNet, ref: []const u8) bool {
    for (net.pins) |pin| {
        if (std.mem.eql(u8, pin.ref_des, ref)) return true;
    }
    return false;
}

/// The per-pin pad encoded in a `(decouple … per-pin)` child's structural
/// `origin_key`. Shared with the optimizer and the ERC pass via `decouple_key`,
/// which imports nothing but `std` — so the exporter still pulls in no
/// placement code to read the key.
const decouplePinFromOrigin = decouple_key.pinFromOrigin;

/// Re-attach `ref`'s sub-block path to a module-local reference, so a cap's
/// `(decouples "U1" …)` resolves to the `U1` in its own module.
fn qualify(a: std.mem.Allocator, ref: []const u8, local: []const u8) std.mem.Allocator.Error![]const u8 {
    if (local.len == 0) return "";
    const path = net_name.parent(ref) orelse return local;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ path, local });
}

/// Record which top-level sub-block owns each flattened instance and which
/// source instance it came from, walking the design tree in exactly the order
/// `collectInstances` flattens it.
fn walkTree(
    a: std.mem.Allocator,
    block: *const DesignBlock,
    top: ?u32,
    owners: *std.ArrayList(?u32),
    src: *std.ArrayList(*const env_mod.Instance),
) std.mem.Allocator.Error!void {
    for (block.instances) |*inst| {
        try owners.append(a, top);
        try src.append(a, inst);
    }
    for (block.sub_blocks, 0..) |sb, i| {
        try walkTree(a, sb.block, top orelse @as(u32, @intCast(i)), owners, src);
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const parser = @import("sexpr/parser.zig");

const fixture_instances = [_]env_mod.Instance{
    .{ .ref_des = "U1", .component = "acme-mcu", .value = "ACME-100", .footprint = "", .symbol = "", .uuid = "11111111-1111-5111-8111-111111111111" },
    .{ .ref_des = "C1", .component = "cap-0402", .value = "100nF", .footprint = "", .symbol = "", .uuid = "22222222-2222-5222-8222-222222222222" },
    .{ .ref_des = "R1", .component = "res-0402", .value = "10k", .footprint = "", .symbol = "", .dnp = true, .uuid = "33333333-3333-5333-8333-333333333333" },
};

const fixture_nets = [_]env_mod.Net{
    .{ .name = "VDD3V3", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "C1", .pin = "1" },
    } },
    .{ .name = "GND", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "2" },
        .{ .ref_des = "C1", .pin = "2" },
    } },
    .{ .name = "adc1/AIN.U1.3", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "3" },
        .{ .ref_des = "R1", .pin = "1" },
    } },
};

const fixture_sections = [_]Section{.{
    .name = "Core System",
    .description = "one MCU and its bypass",
    .instances = &[_]env_mod.Instance{fixture_instances[0]},
}};

/// A synthetic design built in memory — `projects/designs` is a separate repo
/// and is absent from a worktree, so tests never depend on it.
fn fixtureBlock() DesignBlock {
    return .{
        .name = "Fixture Board",
        .instances = &fixture_instances,
        .nets = &fixture_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .sections = &fixture_sections,
    };
}

/// Export helper for tests that only care about the root sheet's text.
fn exportRoot(block: *const DesignBlock, name: []const u8) ![]const u8 {
    const out = try exportSch(testing.allocator, block, "/nonexistent", name, .{});
    defer out.deinit(testing.allocator);
    return testing.allocator.dupe(u8, out.files[0].bytes);
}

// spec: export_kicad_sch - Exporting a design twice produces byte-identical schematic output
test "kicad-sch: export is deterministic across runs" {
    const block = fixtureBlock();
    const first = try exportRoot(&block, "fixture");
    defer testing.allocator.free(first);
    const second = try exportRoot(&block, "fixture");
    defer testing.allocator.free(second);
    try testing.expectEqualStrings(first, second);

    // A design that draws wires is the harder case: routes are chosen against
    // whatever is already on the sheet, so a candidate order or junction order
    // that wobbled would show up here and nowhere else.
    const wired = wireBlock();
    const drawn = try exportRoot(&wired, "wired");
    defer testing.allocator.free(drawn);
    const redrawn = try exportRoot(&wired, "wired");
    defer testing.allocator.free(redrawn);
    try testing.expectEqualStrings(drawn, redrawn);

    // A design whose edges are ganged is the same story one level down: the
    // pads are re-slotted by net and the runs cut where a foreign pin lands, so
    // an unstable ordering anywhere would move a wire here.
    const edged = edgeBlock();
    const first_gang = try exportRoot(&edged, "edged");
    defer testing.allocator.free(first_gang);
    const second_gang = try exportRoot(&edged, "edged");
    defer testing.allocator.free(second_gang);
    try testing.expectEqualStrings(first_gang, second_gang);
}

// spec: export_kicad_sch - The sheet carries the KiCad 10 header, one placed symbol per instance, and the instance UUID verbatim
test "kicad-sch: export emits the pinned header and each instance's own uuid" {
    const block = fixtureBlock();
    const out = try exportRoot(&block, "fixture");
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "(version 20260306)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(generator \"netlisp\")") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(generator_version \"10.0\")") != null);
    for (fixture_instances) |inst| {
        const needle = try std.fmt.allocPrint(testing.allocator, "(uuid \"{s}\")", .{inst.uuid});
        defer testing.allocator.free(needle);
        try testing.expect(std.mem.indexOf(u8, out, needle) != null);
        const ref = try std.fmt.allocPrint(testing.allocator, "(reference \"{s}\")", .{inst.ref_des});
        defer testing.allocator.free(ref);
        try testing.expect(std.mem.indexOf(u8, out, ref) != null);
    }
}

// spec: export_kicad_sch - Net labels carry the flattened net name verbatim, slashes and dots included
test "kicad-sch: export writes hierarchical net names into labels unchanged" {
    const block = fixtureBlock();
    const out = try exportRoot(&block, "fixture");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "(global_label \"adc1/AIN.U1.3\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "{slash}") == null);
    try testing.expect(std.mem.indexOf(u8, out, "(global_label \"VDD3V3\"") != null);
}

// spec: export_kicad_sch - A ground pin is drawn as a power symbol and every ground rail gets one PWR_FLAG driver
test "kicad-sch: export replaces ground labels with rail symbols and drives each rail" {
    const block = fixtureBlock();
    const out = try exportRoot(&block, "fixture");
    defer testing.allocator.free(out);
    // The rail's own library entry names the net through its Value property.
    try testing.expect(std.mem.indexOf(u8, out, "(symbol \"netlisp:PWR_GND\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(lib_id \"netlisp:PWR_GND\")") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(reference \"#PWR01\")") != null);
    // …so no ground PIN carries a label: the only "GND" label on the sheet is
    // the one naming the rail its single PWR_FLAG driver sits on.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "(global_label \"GND\""));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "(lib_id \"netlisp:PWR_FLAG\")"));
    try testing.expect(std.mem.indexOf(u8, out, "(pin power_out line") != null);
}

// spec: export_kicad_sch - A DNP instance is marked dnp and dropped from the BOM while staying on the board
test "kicad-sch: export maps dnp to KiCad's dnp and in_bom flags" {
    const block = fixtureBlock();
    const out = try exportRoot(&block, "fixture");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "(dnp yes)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(in_bom no)") != null);
    // `(on_board no)` would delete a real part from KiCad's netlist entirely;
    // only the `#PWR`/`#FLG` helpers, which must never reach it, carry it.
    try testing.expect(std.mem.indexOf(u8, out, "(on_board yes)") != null);
}

const vendor_sym = @embedFile("kicad_sym/testdata/vendor-flat.kicad_sym");

/// The committed rendering of `fixtureBlock` when its MCU resolves to a vendor
/// `.kicad_sym` — the box golden's twin, and the only place the emitted spelling
/// of a vendor body is pinned. Regenerate deliberately and read the diff.
const golden_vendor = @embedFile("kicad_sch/testdata/fixture-vendor.kicad_sch");

/// Export `fixtureBlock` against a throwaway project whose `lib/sources` holds
/// one vendor library, filed under the fixture MCU's component name.
fn exportWithVendor(
    arena: std.mem.Allocator,
    tmp: *testing.TmpDir,
    opts: Options,
) ![]const u8 {
    try tmp.dir.createDirPath(std.testing.io, "lib/sources");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/sources/acme-mcu.kicad_sym", .data = vendor_sym });
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const block = fixtureBlock();
    const out = try exportSch(testing.allocator, &block, dir, "fixture", opts);
    defer out.deinit(testing.allocator);
    return arena.dupe(u8, out.files[0].bytes);
}

// spec: export_kicad_sch - A fixture design drawn from a vendor symbol exports byte-for-byte to its own committed golden schematic
test "kicad-sch: the vendor fixture export matches its committed golden file" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try exportWithVendor(a, &tmp, .{});
    try testing.expectEqualStrings(golden_vendor, out);
}

// spec: export_kicad_sch - A part with a vendor symbol in lib/sources is drawn from it, and --no-vendor-symbols forces the synthesised box everywhere
test "kicad-sch: a vendor body reaches the emitted sheet and can be switched off" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/sources");
    // The file stem is the component's name, so the index finds it even though
    // the symbol inside is called something else.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/sources/acme-mcu.kicad_sym", .data = vendor_sym });
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);

    const block = fixtureBlock();
    const on = try exportSch(testing.allocator, &block, dir, "fixture", .{});
    defer on.deinit(testing.allocator);
    // The vendor pin names and its own 5.08 mm pin length are what a
    // synthesised box never writes.
    try testing.expect(std.mem.indexOf(u8, on.files[0].bytes, "(name \"D\"") != null);
    try testing.expect(std.mem.indexOf(u8, on.files[0].bytes, "(length 5.08)") != null);
    // The netlist still drives connectivity: pad 3's label is unchanged.
    try testing.expect(std.mem.indexOf(u8, on.files[0].bytes, "(global_label \"adc1/AIN.U1.3\"") != null);

    const off = try exportSch(testing.allocator, &block, dir, "fixture", .{ .vendor = false });
    defer off.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, off.files[0].bytes, "(name \"D\"") == null);
    try testing.expect(std.mem.indexOf(u8, off.files[0].bytes, "(length 2.54)") != null);
}

/// The committed rendering of `fixtureBlock` — regenerate deliberately, and
/// read the diff: a change here is a change to every exported schematic.
const golden_fixture = @embedFile("kicad_sch/testdata/fixture.kicad_sch");

// spec: export_kicad_sch - A fixture design exports byte-for-byte to its committed golden schematic
test "kicad-sch: fixture export matches the committed golden file" {
    const block = fixtureBlock();
    const out = try exportRoot(&block, "fixture");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(golden_fixture, out);
}

/// Offset of a ZIP's central directory, read from the end-of-central-directory
/// record. No archive here carries a trailing comment, so the EOCD is exactly
/// the last 22 bytes and the offset sits 16 bytes into it. Everything before
/// this offset is the local file records — the entries' own bytes, in order.
fn zipCentralDirStart(zip: []const u8) u32 {
    return std.mem.readInt(u32, zip[zip.len - 22 + 16 ..][0..4], .little);
}

// spec: export_kicad_sch - The export-kicad bundle gains the schematic sheets and project sidecars only when asked, leaving every netlist and footprint byte where it was
test "kicad-sch: the export-kicad bundle carries the schematic on request" {
    // `exportKicadZip` builds its entry list on the caller's allocator and
    // hands ownership to the archive, so it is written for an arena / request
    // allocator; give it one rather than leak-checking its intermediates.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const block = fixtureBlock();
    const plain = try export_kicad.exportKicadZip(a, &block, "/nonexistent", "fixture", .{});
    const with_sch = try export_kicad.exportKicadZip(
        a,
        &block,
        "/nonexistent",
        "fixture",
        .{ .schematic = true },
    );

    // Default off: the netlist-only bundle names no schematic file at all.
    try testing.expect(std.mem.indexOf(u8, plain, "fixture.kicad_sch") == null);
    try testing.expect(std.mem.indexOf(u8, plain, "netlisp.kicad_sym") == null);

    // Asked for: the sheets and all four sidecars ride along, at the archive
    // root — the root's Sheetfile links name bare siblings, so a subdirectory
    // would break the hierarchy on unpack.
    try testing.expect(std.mem.indexOf(u8, with_sch, "fixture.kicad_sch") != null);
    try testing.expect(std.mem.indexOf(u8, with_sch, "fixture.kicad_pro") != null);
    try testing.expect(std.mem.indexOf(u8, with_sch, "sym-lib-table") != null);
    try testing.expect(std.mem.indexOf(u8, with_sch, "fp-lib-table") != null);
    try testing.expect(std.mem.indexOf(u8, with_sch, "netlisp.kicad_sym") != null);

    // …and the pre-existing bundle is untouched: the schematic entries are
    // appended, so every netlist/footprint/model byte keeps its exact offset.
    const cd = zipCentralDirStart(plain);
    try testing.expectEqualSlices(u8, plain[0..cd], with_sch[0..cd]);
}

// spec: export_kicad_sch - An empty design with no instances and no nets still exports a sheet that parses and self-checks
test "kicad-sch: an empty design still exports a self-checking sheet" {
    const block = DesignBlock{
        .name = "Empty",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .sections = &.{},
    };
    const out = try exportRoot(&block, "empty");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "(kicad_sch") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(lib_symbols") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(symbol (lib_id") == null);
}

const orphan_instances = [_]env_mod.Instance{
    .{ .ref_des = "U1", .component = "acme-mcu", .value = "", .footprint = "", .symbol = "" },
};

const orphan_nets = [_]env_mod.Net{
    .{ .name = "ORPHAN", .pins = &[_]env_mod.PinRef{.{ .ref_des = "U9", .pin = "1" }} },
    .{ .name = "SHARED", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "U9", .pin = "2" },
    } },
};

// spec: export_kicad_sch - A net naming a ref-des with no instance is reported rather than silently dropped
test "kicad-sch: a net on a missing ref-des draws no label and does not fail the export" {
    const block = DesignBlock{
        .name = "Orphan",
        .instances = &orphan_instances,
        .nets = &orphan_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .sections = &.{},
    };
    const out = try exportRoot(&block, "orphan");
    defer testing.allocator.free(out);
    // The drawable half of SHARED still gets its label; ORPHAN has no pin to
    // hang one on, so it cannot (and must not) appear.
    try testing.expect(std.mem.indexOf(u8, out, "(global_label \"SHARED\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(global_label \"ORPHAN\"") == null);
}

// spec: export_kicad_sch - The self-check names the first flattened pin that never reached a symbol
test "kicad-sch: firstUndrawn finds an uncovered pin and passes full coverage" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var known: std.StringHashMapUnmanaged(u32) = .empty;
    try known.put(a, "U1", 0);
    var drawn: std.StringHashMapUnmanaged(void) = .empty;
    try drawn.put(a, try pinKey(a, "U1", "1"), {});

    const nets = [_]FlatNet{.{
        .name = "N",
        .pins = &[_]export_kicad.FlatPin{
            .{ .ref_des = "U1", .pin = "1" },
            // Pad 2 was never drawn — the exporter must refuse to write this.
            .{ .ref_des = "U1", .pin = "2" },
            // A pin on an unknown ref is undrawable by nature and is not the fault
            // this check is looking for.
            .{ .ref_des = "U9", .pin = "1" },
        },
    }};
    const missing = try firstUndrawn(a, &nets, &known, &drawn);
    try testing.expect(missing != null);
    try testing.expectEqualStrings("2", missing.?.pin);

    try drawn.put(a, try pinKey(a, "U1", "2"), {});
    try testing.expect((try firstUndrawn(a, &nets, &known, &drawn)) == null);
}

// spec: export_kicad_sch - A decoupling cap's module-local IC reference is re-qualified with its own sub-block path
test "kicad-sch: qualify re-attaches the sub-block path to a module-local ref" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("adc1/U1", try qualify(a, "adc1/C3", "U1"));
    try testing.expectEqualStrings("U1", try qualify(a, "C3", "U1"));
    try testing.expectEqualStrings("", try qualify(a, "adc1/C3", ""));
}

// ── Bypass-stub fixture ────────────────────────────────────────────────

const stub_instances = [_]env_mod.Instance{
    ic("U1", "acme-mcu"),
    cap("C1"),
    cap("C2"),
    .{ .ref_des = "R1", .component = "res-0402", .value = "0R", .footprint = "", .symbol = "" },
    ic("U2", "acme-io"),
};

const stub_nets = [_]env_mod.Net{
    // The rail's own trunk, in the other section so nothing draws it away.
    .{ .name = "V1P8", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "R1", .pin = "2" },
        .{ .ref_des = "U2", .pin = "1" },
    } },
    // Two per-pin bypass stubs of that rail — the shape `(decouple … per-pin …)`
    // generates, each carrying its own host pad plus the cap that serves it.
    .{ .name = "V1P8.U1.1", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "C1", .pin = "1" },
    } },
    .{ .name = "V1P8.U1.2", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "2" },
        .{ .ref_des = "C2", .pin = "1" },
    } },
    .{ .name = "GND", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "3" },
        .{ .ref_des = "C1", .pin = "2" },
        .{ .ref_des = "C2", .pin = "2" },
    } },
    // A design's own dotted name. It is not `<base>.<REF>.<PAD>`, and it must
    // survive untouched — collapsing it would invent a net called "3".
    .{ .name = "3.3V_SENSE", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "4" },
        .{ .ref_des = "R1", .pin = "1" },
    } },
};

const stub_sections = [_]Section{
    .{ .name = "Core System", .description = "", .instances = stub_instances[0..3] },
    .{ .name = "Rail", .description = "", .instances = stub_instances[3..5] },
};

fn stubBlock() DesignBlock {
    return .{
        .name = "Stub Board",
        .instances = &stub_instances,
        .nets = &stub_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .sections = &stub_sections,
    };
}

// spec: export_kicad_sch - A passive reaches the sheet as its stock KiCad glyph, at the stock pin reach and with its pin text hidden
test "kicad-sch: a passive is emitted as a real Device glyph rather than a box" {
    // The stub fixture's passives carry both their pads, which is what a glyph
    // needs; the main fixture's resistor only ever appears on one net.
    const block = stubBlock();
    const out = try exportRoot(&block, "stubs");
    defer testing.allocator.free(out);

    // Device:R's narrow IEC rectangle and Device:C's two plates, both through
    // the quarter turn that puts their pins on the left and right.
    try testing.expect(std.mem.indexOf(u8, out, "(rectangle (start -2.54 1.016) (end 2.54 -1.016)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(polyline (pts (xy -0.762 -2.032) (xy -0.762 2.032))") != null);
    // Pin numbers and names hidden, as every stock passive hides them.
    try testing.expect(std.mem.indexOf(u8, out, "(pin_numbers (hide yes))") != null);
    // Both pins keep the stock 3.81 mm connection reach; the drawn lead length
    // is each glyph's own (1.27 mm for a resistor, 2.54 mm for a capacitor).
    try testing.expect(std.mem.indexOf(u8, out, "(pin passive line (at -3.81 0 0) (length 1.27)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(pin passive line (at -3.81 0 0) (length 2.54)") != null);
    // The MCU is not a passive and keeps its synthesised box.
    try testing.expect(std.mem.indexOf(u8, out, "(pin_names (offset 0.254))") != null);
    // Every stub, label and no-connect still lands on its pin: the export only
    // returns once `verify` has re-derived them all from these very bytes.
}

// spec: export_kicad_sch - Every per-pin bypass stub of one rail is labelled with the rail name, so KiCad reads them as that one net
test "kicad-sch: bypass stubs of a rail all label as the rail and its own dotted net survives" {
    const block = stubBlock();
    const out = try exportRoot(&block, "stubs");
    defer testing.allocator.free(out);

    // Not one stub spelling reaches the sheet — a reader (and KiCad) sees the
    // rail, which is what the split micro-nets are part of.
    try testing.expect(std.mem.indexOf(u8, out, "V1P8.U1.") == null);
    // Several formerly distinct nets now share one label text. Each keeps its
    // own — label suppression is keyed on the stub end a wire reached, never on
    // the text, so a second run naming the same rail can never delete the first
    // run's only label (and with none of them left KiCad would rename the net).
    try testing.expect(std.mem.count(u8, out, "(global_label \"V1P8\"") >= 3);
    // The design's own dotted net name is untouched.
    try testing.expect(std.mem.indexOf(u8, out, "(global_label \"3.3V_SENSE\"") != null);
}

// spec: export_kicad_sch - Per-pin bypass stubs of one rail gang into that rail's single bank, the same merge their shared label already made
test "kicad-sch: caps on different bypass stubs of one rail join one bank" {
    const block = stubBlock();
    const out = try exportRoot(&block, "stubs");
    defer testing.allocator.free(out);

    // C1 and C2 sit on V1P8.U1.1 and V1P8.U1.2 — two nets to netlisp, one rail
    // on the drawing, because the stub collapse already labels both `V1P8`.
    // Ganging them changes nothing electrically that the shared label had not
    // already done, and it is what puts them side by side under one caption.
    try testing.expect(std.mem.indexOf(u8, out, "Decoupling — U1 · V1P8") != null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, " 270) (unit 1)"));
}

// ── Drawn-wire fixture ─────────────────────────────────────────────────

fn bypass(comptime ref: []const u8, comptime pad: []const u8) env_mod.Instance {
    return .{
        .ref_des = ref,
        .component = "cap-0402",
        .value = "100nF",
        .footprint = "",
        .symbol = "",
        .bind = .{ .decouple = .{ .ic = "U1", .pin = pad } },
    };
}

const wire_instances = [_]env_mod.Instance{
    ic("U1", "acme-mcu"),
    bypass("C1", "1"),
    bypass("C2", "5"),
    .{ .ref_des = "R1", .component = "res-0402", .value = "10k", .footprint = "", .symbol = "" },
    .{ .ref_des = "R2", .component = "res-0402", .value = "10k", .footprint = "", .symbol = "" },
    ic("U2", "acme-io"),
};

const wire_nets = [_]env_mod.Net{
    // Four pins, so the small-net rule cannot claim it: only the caps' own
    // `(decouples "U1" …)` declarations say which pad each one serves.
    .{ .name = "VDD3V3", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "U1", .pin = "5" },
        .{ .ref_des = "C1", .pin = "1" },
        .{ .ref_des = "C2", .pin = "1" },
    } },
    // The two caps return to DIFFERENT grounds, so they are not one decoupling
    // bank — a bank is keyed on the rail AND the ground it gangs between. Each
    // therefore keeps the point-to-point run to the pad it declares, which is
    // what this fixture exists to pin. (C2's return is deliberately the ONLY
    // pin on AGND: adding a second one to U1 would shift its pad order, and
    // with it which edge every other pin of this fixture leaves from.)
    .{ .name = na.analog_ground, .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "C2", .pin = "2" },
    } },
    // A pad takes its side in first-seen order, so the order these nets are
    // declared in is what decides the chain's geometry: the spare leg first
    // puts R1's TAP pin on the far side of its body from R2's, and TAP before
    // GND puts U1's TAP pin on U1's left edge. The chain then reaches R1 from
    // one side and leaves on the other, which is what keeps the two legs off
    // each other (two collinear wires overlapping do not connect in KiCad).
    .{ .name = "SPARE1", .pins = &[_]env_mod.PinRef{.{ .ref_des = "R1", .pin = "1" }} },
    // Three pins, all in the one cluster: drawn as a CHAIN, and the middle
    // pin — reached on one side and left on the other — is where three wire
    // ends meet and a junction dot has to be drawn.
    .{ .name = "TAP", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "3" },
        .{ .ref_des = "R1", .pin = "2" },
        .{ .ref_des = "R2", .pin = "1" },
    } },
    .{ .name = "GND", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "2" },
        .{ .ref_des = "C1", .pin = "2" },
    } },
    // Two pins, but in different sections — and so different clusters, which is
    // the case a label pair still expresses better than a wire across the page.
    .{ .name = "LINK", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "4" },
        .{ .ref_des = "U2", .pin = "1" },
    } },
    .{ .name = "SPARE2", .pins = &[_]env_mod.PinRef{.{ .ref_des = "R2", .pin = "2" }} },
};

const wire_sections = [_]Section{
    .{ .name = "Core System", .description = "", .instances = wire_instances[0..5] },
    .{ .name = "IO Bank", .description = "", .instances = wire_instances[5..6] },
};

fn wireBlock() DesignBlock {
    return .{
        .name = "Wired Board",
        .instances = &wire_instances,
        .nets = &wire_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .sections = &wire_sections,
    };
}

// spec: export_kicad_sch - A declared decoupling cap and a small in-cluster net are drawn as wire, each net keeping exactly one label
test "kicad-sch: a bound bypass cap and a three-pin cluster net become drawn wire" {
    const block = wireBlock();
    const out = try exportRoot(&block, "wired");
    defer testing.allocator.free(out);

    // Both caps reach the pad they declare, and the IC's own two VDD3V3 pads
    // are ganged along its edge — so ONE label names the whole rail here. (The
    // rail is four pins, too many for the small-net rule, so the caps' own
    // `(decouples "U1" …)` declarations are what drew them.)
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "(global_label \"VDD3V3\""));
    // The three-pin tap is drawn end to end and one label names the run.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "(global_label \"TAP\""));
    // The chain's middle pin carries its own stub plus a leg in and a leg
    // out — three wire ends, so a dot.
    try testing.expect(std.mem.indexOf(u8, out, "(junction ") != null);
    // A one-pin net has nothing to be drawn to and keeps its label.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "(global_label \"SPARE1\""));
}

// spec: export_kicad_sch - A net whose pins land in different clusters keeps its label pair instead of a wire
test "kicad-sch: a two-pin net spanning two sections is still label-connected" {
    const block = wireBlock();
    const out = try exportRoot(&block, "wired");
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "(global_label \"LINK\""));
}

// ── Decoupling-bank fixture ────────────────────────────────────────────

/// One MCU, four bypass caps declared against its single supply pad, and a
/// fifth on a rail of its own. The four gang into a bank; the fifth is alone
/// on its pair and keeps today's drawing.
const gang_instances = [_]env_mod.Instance{
    ic("U1", "acme-mcu"),
    bypass("C1", "1"),
    bypass("C2", "1"),
    bypass("C3", "1"),
    .{
        .ref_des = "C4",
        .component = "cap-0402",
        .value = "10uF",
        .footprint = "",
        .symbol = "",
        .bind = .{ .decouple = .{ .ic = "U1", .pin = "1" } },
    },
    cap("C5"),
};

const gang_nets = [_]env_mod.Net{
    .{ .name = "VDD3V3", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "C1", .pin = "1" },
        .{ .ref_des = "C2", .pin = "1" },
        .{ .ref_des = "C3", .pin = "1" },
        .{ .ref_des = "C4", .pin = "1" },
    } },
    .{ .name = "VDDA", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "3" },
        .{ .ref_des = "C5", .pin = "1" },
    } },
    .{ .name = "GND", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "2" },
        .{ .ref_des = "C1", .pin = "2" },
        .{ .ref_des = "C2", .pin = "2" },
        .{ .ref_des = "C3", .pin = "2" },
        .{ .ref_des = "C4", .pin = "2" },
        .{ .ref_des = "C5", .pin = "2" },
    } },
};

const gang_sections = [_]Section{
    .{ .name = "Core System", .description = "", .instances = &gang_instances },
};

fn gangBlock() DesignBlock {
    return .{
        .name = "Ganged Board",
        .instances = &gang_instances,
        .nets = &gang_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .sections = &gang_sections,
    };
}

// spec: export_kicad_sch - Decoupling caps on one rail are ganged between a rail wire and a ground wire under a single label, replacing their own label pairs
test "kicad-sch: a decoupling bank replaces its members' labels with one rail label" {
    const block = gangBlock();
    const out = try exportRoot(&block, "ganged");
    defer testing.allocator.free(out);

    // Four caps' worth of VDD3V3 labels are gone: the IC's own supply pad keeps
    // one, and the bank's rail carries the other.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "(global_label \"VDD3V3\""));
    // One ground symbol for the whole bank, not one per cap: U1's ground pin,
    // the bank's rail, and the lone C5 make three.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "(lib_id \"netlisp:PWR_GND\")"));
    // The bank names itself, its IC and the rail it gangs.
    try testing.expect(std.mem.indexOf(u8, out, "Decoupling — U1 · VDD3V3") != null);
    // Every tap but the last one is a three-way meeting, on both rails.
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, out, "(junction "));
}

// spec: export_kicad_sch - A ganged cap stands on end between the bank's rails, with its ref-des and value read beside it and no stub of its own
test "kicad-sch: a ganged cap is turned upright and drops its per-pin drawing" {
    const block = gangBlock();
    const out = try exportRoot(&block, "ganged");
    defer testing.allocator.free(out);

    // Each member is placed at a quarter turn; the lone C5 and the MCU are not.
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, out, " 270) (unit 1)"));
    // Their Reference and Value read to the right of the standing body.
    try testing.expect(std.mem.indexOf(u8, out, "(justify left))") != null);
    // A member has no stub, so nothing on the sheet claims its pins twice; the
    // export only returns once `verify` has re-derived every wire, pin and dot
    // from these bytes and found no wire touching a pin it does not end on.
    try testing.expect(std.mem.indexOf(u8, out, "\"Reference\" \"C1\"") != null);
}

// ── Same-net gang fixture ──────────────────────────────────────────────

/// One hub whose rails land on several pads each: three grounds, two supplies,
/// one signal. The grounds gang along their edge under a single ground symbol
/// and the supplies under a single label — what fifteen `GND` symbols in a
/// smear and five stacked `VDD` hexagons used to be.
const edge_instances = [_]env_mod.Instance{ic("U1", "acme-mcu")};

const edge_nets = [_]env_mod.Net{
    .{ .name = "GND", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "U1", .pin = "2" },
        .{ .ref_des = "U1", .pin = "3" },
    } },
    .{ .name = "VDD3V3", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "4" },
        .{ .ref_des = "U1", .pin = "5" },
    } },
    .{ .name = "SIG", .pins = &[_]env_mod.PinRef{.{ .ref_des = "U1", .pin = "6" }} },
};

const edge_sections = [_]Section{
    .{ .name = "Core", .description = "", .instances = &edge_instances },
};

fn edgeBlock() DesignBlock {
    return .{
        .name = "Edge Board",
        .instances = &edge_instances,
        .nets = &edge_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .sections = &edge_sections,
    };
}

// spec: export_kicad_sch - Same-net pins on one edge of a symbol are joined by one wire carrying a single label or ground symbol for the whole run
test "kicad-sch: a hub's repeated rail pins are ganged under one adornment" {
    const block = edgeBlock();
    const out = try exportRoot(&block, "edged");
    defer testing.allocator.free(out);

    // Three ground pads, ONE ground symbol — the run along the edge carries the
    // other two.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "(lib_id \"netlisp:PWR_GND\")"));
    // Two supply pads, one label. (The root's PWR_FLAG adds the only other
    // label on the sheet, naming the ground rail it drives.)
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "(global_label \"VDD3V3\""));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "(global_label \"SIG\""));
    // The middle tap of the three-pin run is where three wire ends meet.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "(junction "));
    // No function name is drawn at all: five pads are ganged, and this fixture
    // resolves no pinout, so every name is its own pad number — which the
    // exporter refuses to print twice. (The gang mute on a symbol whose names
    // are real is pinned by `kicad_sch/shape.zig`'s own test.)
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, out, "(font (size 0 0))"));
}

// ── Part-number fixture ────────────────────────────────────────────────

const hub_props = [_]env_mod.Property{
    .{ .key = "mpn", .value = "ACME-100-QFN48" },
    .{ .key = "manufacturer", .value = "Acme" },
};

/// A bypass cap resolved to a real part number. Its value already says what it
/// is, so the number stays a hidden BOM field rather than being printed under
/// every one of them.
const cap_props = [_]env_mod.Property{.{ .key = "mpn", .value = "GRM155R71C104KA88D" }};

const mpn_instances = [_]env_mod.Instance{
    .{ .ref_des = "U1", .component = "acme-mcu", .value = "ACME-100", .footprint = "", .symbol = "", .properties = &hub_props },
    .{ .ref_des = "C1", .component = "cap-0402", .value = "100nF", .footprint = "", .symbol = "", .properties = &cap_props },
    // A hub the BOM never resolved: nothing to show, and no empty field either.
    .{ .ref_des = "U2", .component = "acme-io", .value = "ACME-200", .footprint = "", .symbol = "" },
};

const mpn_nets = [_]env_mod.Net{
    .{ .name = "VDD3V3", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "C1", .pin = "1" },
        .{ .ref_des = "U2", .pin = "1" },
    } },
    .{ .name = "GND", .pins = &[_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "2" },
        .{ .ref_des = "C1", .pin = "2" },
        .{ .ref_des = "U2", .pin = "2" },
    } },
};

const mpn_sections = [_]Section{
    .{ .name = "Core", .description = "", .instances = &mpn_instances },
};

fn mpnBlock() DesignBlock {
    return .{
        .name = "Part Number Board",
        .instances = &mpn_instances,
        .nets = &mpn_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .sections = &mpn_sections,
    };
}

// spec: export_kicad_sch - A hub whose BOM resolved a part number displays it as a visible MPN field, a passive keeps it hidden, and a part without one gains no field
test "kicad-sch: a resolved part number is shown on a hub and hidden on a passive" {
    const block = mpnBlock();
    const out = try exportRoot(&block, "mpn");
    defer testing.allocator.free(out);

    // The hub's number is drawn — a visible field, at the same size as its
    // Reference and Value, and written exactly once.
    try testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, out, "(property \"MPN\" \"ACME-100-QFN48\""),
    );
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "\"ACME-100-QFN48\" (at 40.64 48.26 0) (effects (font (size 1.27 1.27)))",
    ) != null);
    // The cap's is still in the file for a KiCad BOM, and still hidden.
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "(property \"MPN\" \"GRM155R71C104KA88D\"",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "(property \"MPN\" \"GRM155R71C104KA88D\" (at 29.21 64.77 0) (hide yes)",
    ) != null);
    // Two parts carry an mpn property, so exactly two MPN fields exist: U2
    // resolved none and gains neither a visible field nor an empty one.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "(property \"MPN\""));
}

// spec: export_kicad_sch - A displayed part number sits under its symbol's Value, inside the cell reserved for it, and collides with nothing on the sheet
test "kicad-sch: a displayed part number clears the Value above it and every neighbour" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const block = mpnBlock();
    const out = try exportRoot(&block, "mpn");
    defer testing.allocator.free(out);

    // It is stacked UNDER the Value, which on this sheet sits at y = 45.72 —
    // one clear line of air above it.
    try testing.expect(std.mem.indexOf(u8, out, "\"ACME-100\" (at 40.64 45.72 0)") != null);
    // And the whole sheet's drawn text still clears itself: the field is
    // reserved for in the packer's cell, so nothing was pushed onto anything.
    const nodes = try parser.parse(a, out);
    const report = try textbox.scan(a, nodes[0]);
    try testing.expectEqual(@as(usize, 0), report.overlaps);
    try testing.expect(report.texts > 0);
}

// ── Hierarchy fixture ──────────────────────────────────────────────────

fn ic(comptime ref: []const u8, comptime component: []const u8) env_mod.Instance {
    return .{ .ref_des = ref, .component = component, .value = "", .footprint = "", .symbol = "" };
}

fn cap(comptime ref: []const u8) env_mod.Instance {
    return .{ .ref_des = ref, .component = "cap-0402", .value = "100nF", .footprint = "", .symbol = "" };
}

/// 26 parts — comfortably over `flat_max_parts`, so this design splits into a
/// hierarchy: `U1` + `C1…C12` in one section, `U2` in another, `C13…C24`
/// declared by no section at all.
const big_instances = blk: {
    var out: [26]env_mod.Instance = undefined;
    out[0] = ic("U1", "acme-mcu");
    for (1..13) |i| out[i] = cap(std.fmt.comptimePrint("C{d}", .{i}));
    out[13] = ic("U2", "acme-io");
    for (14..26) |i| out[i] = cap(std.fmt.comptimePrint("C{d}", .{i - 1}));
    break :blk out;
};

const big_vdd = blk: {
    var out: [25]env_mod.PinRef = undefined;
    out[0] = .{ .ref_des = "U1", .pin = "1" };
    for (1..25) |i| out[i] = .{ .ref_des = big_instances[capIndex(i)].ref_des, .pin = "1" };
    break :blk out;
};

const big_gnd = blk: {
    var out: [25]env_mod.PinRef = undefined;
    out[0] = .{ .ref_des = "U2", .pin = "2" };
    for (1..25) |i| out[i] = .{ .ref_des = big_instances[capIndex(i)].ref_des, .pin = "2" };
    break :blk out;
};

/// Index of the `i`-th capacitor in `big_instances` (the two ICs sit at 0 and 13).
fn capIndex(i: usize) usize {
    return if (i <= 12) i else i + 1;
}

const big_nets = [_]env_mod.Net{
    .{ .name = "VDD", .pins = &big_vdd },
    .{ .name = "GND", .pins = &big_gnd },
};

const big_sections = [_]Section{
    .{ .name = "Core", .description = "", .instances = big_instances[0..13] },
    .{ .name = "IO Bank", .description = "", .instances = big_instances[13..14] },
};

const pwr_instances = [_]env_mod.Instance{ic("U1", "acme-ldo")};
const pwr_nets = [_]env_mod.Net{.{
    .name = "VOUT",
    .pins = &[_]env_mod.PinRef{.{ .ref_des = "U1", .pin = "3" }},
}};

fn pwrBlock() DesignBlock {
    return .{
        .name = "LDO",
        .instances = &pwr_instances,
        .nets = &pwr_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .sections = &.{},
    };
}

fn bigBlock(subs: []const env_mod.SubBlock) DesignBlock {
    return .{
        .name = "Big Board",
        .instances = &big_instances,
        .nets = &big_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = subs,
        .sections = &big_sections,
    };
}

/// The `Sheetfile` of every child the root links, in page order.
fn childFilesOf(root: []const u8, out: *std.ArrayList([]const u8)) !void {
    var rest = root;
    const needle = "(property \"Sheetfile\" \"";
    while (std.mem.indexOf(u8, rest, needle)) |i| {
        rest = rest[i + needle.len ..];
        const end = std.mem.indexOfScalar(u8, rest, '"').?;
        try out.append(testing.allocator, rest[0..end]);
    }
}

// spec: export_kicad_sch - A large design splits into a root plus one child sheet per section, per unadopted module, and one for parts no section declares
test "kicad-sch: a hierarchical export links a sheet per section, module, and leftover" {
    var pwr = pwrBlock();
    var subs = [_]env_mod.SubBlock{.{ .name = "pwr", .block = &pwr }};
    const block = bigBlock(&subs);

    const out = try exportSch(testing.allocator, &block, "/nonexistent", "big", .{});
    defer out.deinit(testing.allocator);

    try testing.expectEqualStrings("big.kicad_sch", out.files[0].name);
    var links: std.ArrayList([]const u8) = .empty;
    defer links.deinit(testing.allocator);
    try childFilesOf(out.files[0].bytes, &links);
    const want = [_][]const u8{
        "big-core.kicad_sch",
        "big-io-bank.kicad_sch",
        "big-sub-block-pwr.kicad_sch",
        "big-unsectioned.kicad_sch",
    };
    // Each expected sheet is linked, in order, and resolves to a file the
    // export actually wrote — a link to nothing is a broken hierarchy.
    try testing.expectEqual(want.len, links.items.len);
    try testing.expectEqual(want.len + 1, out.files.len);
    for (want, links.items, out.files[1..]) |expected, link, f| {
        try testing.expectEqualStrings(expected, link);
        try testing.expectEqualStrings(expected, f.name);
    }

    // A section's own IC is drawn on its sheet and nowhere else.
    try testing.expect(std.mem.indexOf(u8, out.files[1].bytes, "\"Reference\" \"U1\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.files[2].bytes, "\"Reference\" \"U1\"") == null);
    try testing.expect(std.mem.indexOf(u8, out.files[2].bytes, "\"Reference\" \"U2\"") != null);
    // The module's part keeps its sub-block-qualified ref on the module's sheet.
    try testing.expect(std.mem.indexOf(u8, out.files[3].bytes, "\"Reference\" \"pwr/U1\"") != null);
    // Leftover caps land on the trailing sheet.
    try testing.expect(std.mem.indexOf(u8, out.files[4].bytes, "\"Reference\" \"C24\"") != null);
}

// spec: export_kicad_sch - A child sheet's symbols carry the root-then-sheet instance path and only the root carries sheet_instances
test "kicad-sch: child sheets nest their instance path under the root's uuid" {
    var pwr = pwrBlock();
    var subs = [_]env_mod.SubBlock{.{ .name = "pwr", .block = &pwr }};
    const block = bigBlock(&subs);

    const out = try exportSch(testing.allocator, &block, "/nonexistent", "big", .{});
    defer out.deinit(testing.allocator);

    const root = out.files[0].bytes;
    const uuid_at = std.mem.indexOf(u8, root, "(uuid \"").? + 7;
    const root_uuid = root[uuid_at .. uuid_at + std.mem.indexOfScalar(u8, root[uuid_at..], '"').?];
    const nested = try std.fmt.allocPrint(testing.allocator, "(path \"/{s}/", .{root_uuid});
    defer testing.allocator.free(nested);

    try testing.expect(std.mem.indexOf(u8, root, "(sheet_instances") != null);
    for (out.files[1..]) |f| {
        try testing.expect(std.mem.indexOf(u8, f.bytes, nested) != null);
        try testing.expect(std.mem.indexOf(u8, f.bytes, "(sheet_instances") == null);
    }
}

// spec: export_kicad_sch - A multi-file export is byte-identical across runs, filenames included
test "kicad-sch: a hierarchical export is deterministic across runs" {
    var pwr = pwrBlock();
    var subs = [_]env_mod.SubBlock{.{ .name = "pwr", .block = &pwr }};
    const block = bigBlock(&subs);

    const first = try exportSch(testing.allocator, &block, "/nonexistent", "big", .{});
    defer first.deinit(testing.allocator);
    const second = try exportSch(testing.allocator, &block, "/nonexistent", "big", .{});
    defer second.deinit(testing.allocator);

    try testing.expectEqual(first.files.len, second.files.len);
    for (first.files, second.files) |a, b| {
        try testing.expectEqualStrings(a.name, b.name);
        try testing.expectEqualStrings(a.bytes, b.bytes);
    }
}

// spec: export_kicad_sch - A small design stays on one flat sheet, and --flat forces that for any design
test "kicad-sch: the flat threshold and the flat option both collapse the hierarchy" {
    const small = fixtureBlock();
    const one = try exportSch(testing.allocator, &small, "/nonexistent", "fixture", .{});
    defer one.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), one.files.len);
    try testing.expect(std.mem.indexOf(u8, one.files[0].bytes, "(sheet (at") == null);

    var pwr = pwrBlock();
    var subs = [_]env_mod.SubBlock{.{ .name = "pwr", .block = &pwr }};
    const block = bigBlock(&subs);
    const forced = try exportSch(testing.allocator, &block, "/nonexistent", "big", .{ .flat = true });
    defer forced.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), forced.files.len);
    // Everything is still drawn — U1, U2 and the module's part all on one sheet.
    try testing.expect(std.mem.indexOf(u8, forced.files[0].bytes, "\"Reference\" \"U2\"") != null);
    try testing.expect(std.mem.indexOf(u8, forced.files[0].bytes, "\"Reference\" \"pwr/U1\"") != null);
}

const unit_parts = [_]env_mod.Part{
    .{ .name = "Power", .pins = &[_]env_mod.PartPin{
        .{ .pin = "1", .net = "VDD3V3" },
        .{ .pin = "2", .net = "GND" },
    } },
};

const unit_instances = [_]env_mod.Instance{
    .{
        .ref_des = "U1",
        .component = "acme-mcu",
        .value = "ACME-100",
        .footprint = "",
        .symbol = "",
        .uuid = "44444444-4444-5444-8444-444444444444",
        .parts = &unit_parts,
    },
};

const unit_nets = [_]env_mod.Net{
    .{ .name = "VDD3V3", .pins = &[_]env_mod.PinRef{.{ .ref_des = "U1", .pin = "1" }} },
    .{ .name = "GND", .pins = &[_]env_mod.PinRef{.{ .ref_des = "U1", .pin = "2" }} },
    .{ .name = "SPARE", .pins = &[_]env_mod.PinRef{.{ .ref_des = "U1", .pin = "3" }} },
};

// spec: export_kicad_sch - An instance with (part …) groups places one symbol per unit, sharing its reference and keeping every pad drawn once
test "kicad-sch: a multi-part instance emits KiCad units that share one reference" {
    const block = DesignBlock{
        .name = "Units",
        .instances = &unit_instances,
        .nets = &unit_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .sections = &.{},
    };
    const out = try exportRoot(&block, "units");
    defer testing.allocator.free(out);

    // The declared part becomes unit 1; the pad it did not claim forms unit 2.
    try testing.expect(std.mem.indexOf(u8, out, "(symbol \"acme-mcu_1_1\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(symbol \"acme-mcu_2_1\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(unit 1)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "(unit 2)") != null);
    // Both units carry the same reference, so KiCad merges them into one part.
    try testing.expect(std.mem.count(u8, out, "(reference \"U1\") (unit ") == 2);
    // Unit 1 keeps the instance's own identity; unit 2 gets a derived uuid.
    try testing.expect(std.mem.count(u8, out, unit_instances[0].uuid) == 1);
    // Every pad is still drawn exactly once across the units.
    try testing.expect(std.mem.indexOf(u8, out, "(global_label \"SPARE\"") != null);
}
