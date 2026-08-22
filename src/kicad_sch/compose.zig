//! Turn one sheet's placeables into the document the emitter writes.
//!
//! This is where every coordinate on a sheet is decided, in three packing
//! passes: each cluster (an IC and the passives that serve it) packs into a
//! compact block, a placement group packs its clusters under one caption, and
//! the groups pack side by side across the page. The caller has already ordered
//! the placeables so that a group's — and inside it a cluster's — members are
//! contiguous.
//!
//! It also decides which pins are drawn as power symbols rather than net
//! labels — the canonical ground rails, by the same predicate the schematic
//! viewer uses — which short connections are drawn as **real wire** instead of
//! a label pair, and collects, as it goes, exactly what the self-check will
//! demand back out of the emitted bytes.
//!
//! Wiring runs after placement, because a route can only be judged against
//! coordinates that are already settled. Two kinds of connection qualify: a
//! decoupling cap's power leg reaching the exact IC pad its `(decouples …)`
//! names, and a net whose ENTIRE membership — across the whole design, not just
//! this sheet — is two or three pins that all landed in one cluster. Anything
//! else, or any route the geometry refuses, keeps today's label pair.

const std = @import("std");
const bank = @import("bank.zig");
const emit = @import("emit.zig");
const gang_mod = @import("gang.zig");
const plan_mod = @import("plan.zig");
const sheet_mod = @import("sheet.zig");
const shape_mod = @import("shape.zig");
const verify = @import("verify.zig");
const wire = @import("wire.zig");

const Shape = shape_mod.Shape;

const flag_pitch: i32 = 1270;
const caption_gap: i32 = 762;
const caption_rise: i32 = 254;
const flag_margin: i32 = 1270;
const sheet_box_w: i32 = 6350;
const sheet_box_h: i32 = 2540;
const sheet_box_gap: i32 = 1270;
/// Glyph height of a bank's own caption: a subheading under the group heading
/// above it, and larger than the net labels around it.
const bank_caption_size: i32 = 178;
/// What `export_kicad_sch.captionFor` puts between a section and one of its
/// modules. A band inside that section's own sheet drops the prefix.
const caption_join = " / ";

/// One symbol unit waiting for a home on the sheet.
pub const Placeable = struct {
    id: emit.Identity,
    shape: u32,
    /// Index into `shapes[shape].units`.
    unit: u32,
    /// Placement group — a `(section …)`'s own parts, or one `(sub-block …)`.
    /// A change starts a fresh shelf under a new caption.
    group: u64,
    caption: []const u8,
    /// Net per pin of that unit, in pin order; "" means no connection.
    nets: []const []const u8,
    /// Cluster within the group. Entries sharing one cluster are contiguous.
    cluster: u32,
};

/// A `(decouples "IC" PAD)` target, already qualified with the declaring cap's
/// own sub-block path so it names the IC in the cap's own module.
pub const Bind = struct {
    ref: []const u8,
    pad: []const u8,
};

/// Design-wide facts a sheet cannot derive from its own placeables. All three
/// are shared across every sheet of a hierarchy and none is required: with all
/// absent nothing is wired, nothing is relabelled, and the sheet is the
/// label-only document earlier phases produced.
pub const NetFacts = struct {
    /// ref-des -> the IC pad that ref's decoupling cap serves.
    binds: ?*const std.StringHashMapUnmanaged(Bind) = null,
    /// Net name -> how many pins it has across the WHOLE design. A net is only
    /// drawn as wire when every one of them is on this sheet, in one cluster.
    net_pins: ?*const std.StringHashMapUnmanaged(u32) = null,
    /// Per-pin bypass-stub net -> the base rail it is LABELLED as (see
    /// `kicad_sch/stub.zig`). Only the drawn label changes: net identity for
    /// wiring, clustering and the design-wide census above stays netlisp's own,
    /// so a stub is still recognised as the two-pin net it is.
    labels: ?*const std.StringHashMapUnmanaged([]const u8) = null,
};

/// Everything one sheet needs to be composed.
pub const Request = struct {
    sheet: emit.Sheet,
    shapes: []const Shape,
    items: []const Placeable,
    /// Child sheets this file links to (root only). `compose` fills in each
    /// one's position on the page, so the slice is written through.
    children: []emit.SheetRef = &.{},
    /// Ground rails this file must drive with a PWR_FLAG (root only).
    flag_nets: []const []const u8 = &.{},
    /// Shared `#PWR…` / `#FLG…` sequence, so references stay unique across
    /// every sheet of the hierarchy.
    seq: *u32,
    /// Design-wide netlist facts: what may be drawn as wire, and how a
    /// bypass-stub net is spelled on its label.
    facts: NetFacts = .{},
};

/// The composed document plus the expectations its self-check verifies.
pub const Result = struct {
    doc: emit.Doc,
    expect: verify.Expect,
};

/// The library entry naming one ground rail. Shared with the standalone
/// `netlisp.kicad_sym` writer, which must name its rail entries exactly as the
/// sheets' `lib_id`s do or KiCad reports the symbol as missing from the library.
pub fn railFor(a: std.mem.Allocator, net: []const u8) std.mem.Allocator.Error!emit.Rail {
    const suffix = try shape_mod.sanitizeLibName(a, net);
    return .{
        .lib_name = try std.fmt.allocPrint(a, "PWR_{s}", .{suffix}),
        .net = net,
    };
}

/// True when a net is drawn as a power symbol instead of a net label. Lives in
/// the emitter beside the label-extent rule that depends on it: a rail-carried
/// pin needs the ground symbol's reach reserved, not a label's, and a symbol's
/// own fields are anchored past whichever it is.
pub const isRailNet = emit.isRailNet;

/// Sheet space a net label needs alongside its pin — the same rule the emitter
/// anchors a symbol's Reference and Value past.
const labelSpan = emit.labelSpan;

/// Lay out and assemble one sheet: cluster blocks pack into a group block, the
/// group blocks pack across the page.
pub fn compose(arena: std.mem.Allocator, req: Request) std.mem.Allocator.Error!Result {
    var st = State{ .a = arena, .req = req };
    const groups = try st.groupRuns();

    const packed_groups = try arena.alloc(Packed, groups.len);
    const cells = try arena.alloc(sheet_mod.Cell, groups.len);
    for (groups, 0..) |g, i| {
        packed_groups[i] = try st.packGroup(g);
        cells[i] = .{
            .w = packed_groups[i].block.w,
            .h = packed_groups[i].block.h + caption_gap,
            .ox = 0,
            .oy = caption_gap,
        };
    }

    const layout = try sheet_mod.packSheet(arena, cells);
    for (groups, packed_groups, layout.spots) |g, p, corner| {
        if (st.bandCaption(st.req.items[g.start].caption)) |text| {
            try st.captions.append(arena, .{
                .text = text,
                .x = corner.x,
                .y = corner.y - caption_gap + caption_rise,
            });
        }
        for (p.clusters, p.block.spots) |run, local| {
            try st.place(run, .{ .x = corner.x + local.x, .y = corner.y + local.y }, p.slots[run.index]);
        }
    }
    try st.planGangs();
    try st.drawWires();
    try st.connectPins();
    return st.finish(layout);
}

/// A contiguous span of `items`, plus its position among its siblings.
const Run = struct { start: usize, len: usize, index: usize = 0 };

/// One placement group after its clusters are packed: the cluster runs, each
/// cluster's own slotting, and the block holding them all.
const Packed = struct {
    clusters: []const Run,
    slots: []const Slotting,
    block: sheet_mod.Block,
};

/// One packed cluster: where each of its slots sits, and what each slot holds.
const Slotting = struct {
    block: sheet_mod.Block,
    plan: ClusterPlan,
};

/// One cluster's packing slots. An ordinary placeable gets a cell of its own; a
/// whole decoupling bank shares one, so the shelf packer budgets the bank's
/// full width in a single box instead of scattering its caps through the group.
const ClusterPlan = struct {
    cells: []const sheet_mod.Cell,
    /// Item index inside the cluster run -> the slot holding it.
    slot_of: []const u32,
    /// Slot index -> the bank drawn there, for the slots that hold one.
    banks: []const ?bank.Bank,
};

/// Where each item of one cluster lands and how it is turned. `angle` is null
/// for everything but a bank's ganged members.
const Poses = struct {
    pos: []sheet_mod.Spot,
    angle: []?u32,
};

/// One wireable pin: where its label sits, what net it carries, and which
/// cluster it landed in. Ground pins never become sites — they keep their power
/// symbol, which already draws a ground connection more plainly than a wire
/// would. A site is claimed at most once, as the head of a drawn run or as one
/// of its spokes.
const Site = struct {
    part: u32,
    pin: u32,
    /// The stub end a wire is routed to, and the edge its pin leaves from.
    end: wire.End,
    net: []const u8,
    group: u64,
    cluster: u32,
    role: enum { free, anchor, spoke } = .free,
};

const State = struct {
    a: std.mem.Allocator,
    req: Request,
    parts: std.ArrayList(emit.Part) = .empty,
    rails: std.ArrayList(emit.Rail) = .empty,
    rail_of_net: std.StringHashMapUnmanaged(u32) = .empty,
    pins: std.ArrayList(emit.RailPin) = .empty,
    flags: std.ArrayList(emit.Flag) = .empty,
    uuids: std.ArrayList([]const u8) = .empty,
    lib_ids: std.ArrayList([]const u8) = .empty,
    labels: std.ArrayList([]const u8) = .empty,
    /// The labels that sit on drawn wire rather than on a pin's stub — one per
    /// decoupling bank, naming the rail its members are ganged onto.
    free_labels: std.ArrayList(emit.FreeLabel) = .empty,
    captions: std.ArrayList(emit.Caption) = .empty,
    rail_values: std.ArrayList([]const u8) = .empty,
    no_connects: usize = 0,
    /// Drawn connections, the wire already on the sheet (stubs included), the
    /// stub ends those wires make a label redundant at, and the dots where
    /// three or more wire ends meet.
    paths: std.ArrayList(wire.Path) = .empty,
    segs: std.ArrayList(wire.Seg) = .empty,
    no_label: std.ArrayList(wire.Point) = .empty,
    dots: []const wire.Point = &.{},
    /// What a route must keep clear: every connection point, every body.
    stops: std.ArrayList(wire.Point) = .empty,
    bodies: std.ArrayList(wire.Box) = .empty,
    /// Pins joined into a same-net gang, keyed `part << 32 | pin`. Their
    /// connection is already drawn, so the wiring pass leaves them alone.
    ganged: std.AutoHashMapUnmanaged(u64, void) = .empty,

    fn bandCaption(self: *State, text: []const u8) ?[]const u8 {
        return bandHeading(self.req.sheet.title, text);
    }

    /// Split the placeables into one run per placement group. The caller
    /// guarantees a group's members are contiguous.
    fn groupRuns(self: *State) std.mem.Allocator.Error![]const Run {
        return self.splitRuns(self.req.items, groupChanged);
    }

    /// Pack one group: each of its clusters into a block of its own, then those
    /// blocks into the group's block.
    fn packGroup(self: *State, group: Run) std.mem.Allocator.Error!Packed {
        const members = self.req.items[group.start..][0..group.len];
        const runs = try self.splitRuns(members, clusterChanged);
        const slots = try self.a.alloc(Slotting, runs.len);
        const cells = try self.a.alloc(sheet_mod.Cell, runs.len);
        for (runs, 0..) |*r, i| {
            // Runs are indexed within the group; shift them back onto `items`.
            r.start += group.start;
            r.index = i;
            const cp = try self.planCluster(r.*);
            slots[i] = .{ .block = try sheet_mod.packCells(self.a, cp.cells), .plan = cp };
            cells[i] = .{ .w = slots[i].block.w, .h = slots[i].block.h, .ox = 0, .oy = 0 };
        }
        return .{
            .clusters = runs,
            .slots = slots,
            .block = try sheet_mod.packCells(self.a, cells),
        };
    }

    /// Decide one cluster's slots: which of its caps gang into decoupling
    /// banks, and therefore which cells the shelf packer is given. A bank's
    /// slot is created where its FIRST member appears in the cluster's own
    /// order, so the arrangement stays a function of that order alone.
    fn planCluster(self: *State, run: Run) std.mem.Allocator.Error!ClusterPlan {
        const items = self.req.items[run.start..][0..run.len];
        const banks = try bank.group(self.a, try self.candidates(items));
        const of_item = try self.bankOfItem(items.len, banks);
        const slot_of_bank = try self.a.alloc(?u32, banks.len);
        @memset(slot_of_bank, null);

        const slot_of = try self.a.alloc(u32, items.len);
        var cells: std.ArrayList(sheet_mod.Cell) = .empty;
        var owner: std.ArrayList(?bank.Bank) = .empty;
        for (items, of_item, slot_of) |it, owned, *slot| {
            if (owned) |b| {
                if (slot_of_bank[b] == null) {
                    slot_of_bank[b] = @intCast(cells.items.len);
                    try cells.append(self.a, bank.cellFor(banks[b], labelSpan(banks[b].power)));
                    try owner.append(self.a, banks[b]);
                }
                slot.* = slot_of_bank[b].?;
                continue;
            }
            slot.* = @intCast(cells.items.len);
            try cells.append(self.a, self.cellOf(it));
            try owner.append(self.a, null);
        }
        return .{ .cells = cells.items, .slot_of = slot_of, .banks = owner.items };
    }

    /// Item index -> the bank that claimed it, or null.
    fn bankOfItem(
        self: *State,
        n: usize,
        banks: []const bank.Bank,
    ) std.mem.Allocator.Error![]const ?u32 {
        const out = try self.a.alloc(?u32, n);
        @memset(out, null);
        for (banks, 0..) |b, i| {
            for (b.members) |m| out[m.item] = @intCast(i);
        }
        return out;
    }

    /// Every placeable in one cluster that could be ganged into a bank.
    fn candidates(
        self: *State,
        items: []const Placeable,
    ) std.mem.Allocator.Error![]const bank.Candidate {
        var out: std.ArrayList(bank.Candidate) = .empty;
        for (items, 0..) |it, i| {
            try out.append(self.a, self.candidateOf(it, @intCast(i)) orelse continue);
        }
        return out.items;
    }

    /// One placeable as a bank candidate, or null when it must keep its labels:
    /// it has to be a capacitor (the `C` prefix netlisp's own decoupling ERC
    /// keys on), drawn as a plain two-terminal glyph, with one leg on a
    /// ground-class net and the other on a rail it either declares it decouples
    /// or that reads like a supply. Anything else — a three-pin body, an open
    /// pad, a coupling cap between two signals, a cap across two grounds —
    /// falls back to today's label pair rather than to a drawing that would
    /// misstate what it is.
    fn candidateOf(self: *State, it: Placeable, i: u32) ?bank.Candidate {
        if (!isBypassRef(it.id.ref)) return null;
        const s = self.req.shapes[it.shape];
        if (s.units.len != 1) return null;
        const reach = bank.reachOf(s.units[0]) orelse return null;
        if (it.nets.len < 2) return null;
        const first = self.labelOf(it.nets[0]);
        const second = self.labelOf(it.nets[1]);
        if (first.len == 0 or second.len == 0) return null;
        const power_pin: u32 = if (isRailNet(second)) 0 else if (isRailNet(first)) 1 else return null;
        const power = if (power_pin == 0) first else second;
        if (isRailNet(power)) return null;
        if (!self.gangable(it.id.ref, power)) return null;
        return .{
            .item = i,
            .ref = it.id.ref,
            .value = it.id.value,
            .power = power,
            .gnd = if (power_pin == 0) second else first,
            .power_pin = power_pin,
            .reach = reach,
        };
    }

    /// True when a cap on `power` may be ganged onto it: it declares which pad
    /// it decouples — the strongest signal there is, and the one netlisp's own
    /// ERC already insists on — or the rail's name reads like a supply.
    fn gangable(self: *State, ref: []const u8, power: []const u8) bool {
        if (self.req.facts.binds) |binds| {
            if (binds.contains(ref)) return true;
        }
        return bank.isSupplyNet(power);
    }

    /// Cut `items` into runs wherever `changed` says a new one begins.
    fn splitRuns(
        self: *State,
        items: []const Placeable,
        changed: *const fn (Placeable, Placeable) bool,
    ) std.mem.Allocator.Error![]Run {
        var out: std.ArrayList(Run) = .empty;
        var start: usize = 0;
        for (items, 0..) |it, i| {
            if (i == 0 or !changed(items[i - 1], it)) continue;
            try out.append(self.a, .{ .start = start, .len = i - start });
            start = i;
        }
        if (items.len > start) try out.append(self.a, .{ .start = start, .len = items.len - start });
        return out.items;
    }

    /// The sheet cell one unit needs: its body plus the stubs, net labels and
    /// rail symbols hanging off each edge, and the ref/value text above and
    /// below. An edge spread into two columns reserves both of them, and a part
    /// showing its own MPN reserves the extra line under its Value.
    fn cellOf(self: *State, it: Placeable) sheet_mod.Cell {
        const u = self.req.shapes[it.shape].units[it.unit];
        var span = [4]i32{ 0, 0, 0, 0 };
        for (u.pins, 0..) |pin, i| {
            const net = self.labelOf(if (i < it.nets.len) it.nets[i] else "");
            const side = @backingInt(pin.side);
            span[side] = @max(span[side], shape_mod.stubExtra(u, i) + labelSpan(net));
        }
        const lead = shape_mod.maxReach(u) + emit.stub_len;
        const left = span[@backingInt(shape_mod.Side.left)];
        const right = span[@backingInt(shape_mod.Side.right)];
        // The Reference and Value are anchored the SAME distance above and
        // below the body — past whichever of the two edges reaches further
        // (`emit.fieldReach`) — so the cell has to hold that distance on both
        // sides, not each edge's own labels. Reserving each edge separately let
        // a symbol whose top labels are the longer ones write its Value below
        // the cell, onto the reference of whatever the packer put underneath.
        const field = @max(
            span[@backingInt(shape_mod.Side.top)],
            span[@backingInt(shape_mod.Side.bottom)],
        );
        return withMpn(it, .{
            .w = 2 * u.half_w + 2 * lead + left + right,
            .h = 2 * u.half_h + 2 * lead + 2 * field + 2 * shape_mod.pitch,
            .ox = left + lead + u.half_w,
            .oy = field + lead + u.half_h + shape_mod.pitch,
        });
    }

    /// Emit one packed cluster at its absolute position on the sheet. Parts are
    /// appended in the cluster's own item order whatever their slot, because
    /// the wiring pass indexes `parts` and `items` alike.
    fn place(
        self: *State,
        run: Run,
        corner: sheet_mod.Spot,
        slot: Slotting,
    ) std.mem.Allocator.Error!void {
        const items = self.req.items[run.start..][0..run.len];
        const at = try self.a.alloc(sheet_mod.Spot, slot.block.spots.len);
        for (slot.block.spots, at) |local, *abs| {
            abs.* = .{ .x = corner.x + local.x, .y = corner.y + local.y };
        }
        const poses = try self.poseItems(items, slot, at);
        for (items, poses.pos, poses.angle) |it, p, angle| try self.placePart(it, p, angle);
    }

    /// Resolve where every item of one cluster sits: an ordinary placeable at
    /// its own slot's spot, a ganged cap at its column inside its bank's frame.
    /// Each bank is drawn here too, once, while its frame is in hand.
    fn poseItems(
        self: *State,
        items: []const Placeable,
        slot: Slotting,
        at: []const sheet_mod.Spot,
    ) std.mem.Allocator.Error!Poses {
        const out = Poses{
            .pos = try self.a.alloc(sheet_mod.Spot, items.len),
            .angle = try self.a.alloc(?u32, items.len),
        };
        for (slot.plan.slot_of, out.pos, out.angle) |s, *p, *angle| {
            p.* = at[s];
            angle.* = null;
        }
        const ic = clusterIc(items);
        for (slot.plan.banks, at) |owned, spot| {
            const b = owned orelse continue;
            const f = bank.Frame{ .x = spot.x, .y = spot.y, .reach = b.reach, .pitch = b.pitch };
            for (b.members, 0..) |m, k| {
                out.pos[m.item] = .{ .x = f.memberX(k), .y = f.y };
                out.angle[m.item] = bank.angleFor(self.pinX(items[m.item], m.power_pin));
            }
            try self.drawBank(f, b, ic);
        }
        return out;
    }

    fn pinX(self: *State, it: Placeable, pin: u32) i32 {
        return self.req.shapes[it.shape].units[it.unit].pins[pin].x;
    }

    fn placePart(
        self: *State,
        it: Placeable,
        at: sheet_mod.Spot,
        angle: ?u32,
    ) std.mem.Allocator.Error!void {
        try self.note(it.id.uuid, self.req.shapes[it.shape].lib_name);
        try self.parts.append(self.a, .{
            .id = it.id,
            .shape = it.shape,
            .unit = it.unit,
            .x = at.x,
            .y = at.y,
            .nets = try self.labelNets(it.nets),
            .banked = angle,
        });
    }

    /// Draw one decoupling bank: the two rails, one leg pair per member, and
    /// the label, ground symbol and caption that terminate it. Every member's
    /// own label pair and the wiring pass's own runs to it are replaced by
    /// this, which is the whole point — the rail's name is written once.
    fn drawBank(
        self: *State,
        f: bank.Frame,
        b: bank.Bank,
        ic: []const u8,
    ) std.mem.Allocator.Error!void {
        try self.bankRail(f, b, f.powerY());
        try self.bankRail(f, b, f.gndY());
        for (0..b.members.len) |k| try self.bankLegs(f, b, k);
        try self.bankTerminals(f, b, ic);
    }

    fn bankRail(self: *State, f: bank.Frame, b: bank.Bank, y: i32) std.mem.Allocator.Error!void {
        const kind: []const u8 = if (y < f.y) "railp" else "railg";
        const key = try std.fmt.allocPrint(self.a, "{s}:{s}", .{ b.key, kind });
        try self.addWire(key, try bank.railPts(self.a, f, b.members.len, y));
    }

    /// One member's two legs: up to the rail it taps, down to the ground wire.
    fn bankLegs(self: *State, f: bank.Frame, b: bank.Bank, k: usize) std.mem.Allocator.Error!void {
        const x = f.memberX(k);
        const up = try self.a.dupe(wire.Point, &.{
            .{ .x = x, .y = f.powerPinY() },
            .{ .x = x, .y = f.powerY() },
        });
        const down = try self.a.dupe(wire.Point, &.{
            .{ .x = x, .y = f.gndPinY() },
            .{ .x = x, .y = f.gndY() },
        });
        try self.addWire(try std.fmt.allocPrint(self.a, "{s}:legp{d}", .{ b.key, k }), up);
        try self.addWire(try std.fmt.allocPrint(self.a, "{s}:legg{d}", .{ b.key, k }), down);
    }

    /// What terminates a bank: one global label naming the rail at the left end
    /// of the power wire, one ground symbol at the left end of the other, and
    /// the caption above both.
    fn bankTerminals(
        self: *State,
        f: bank.Frame,
        b: bank.Bank,
        ic: []const u8,
    ) std.mem.Allocator.Error!void {
        try self.free_labels.append(self.a, .{
            .net = b.power,
            .uuid = try emit.elementUuid(self.a, self.req.sheet.design, "banklabel", b.key),
            .x = f.endX(),
            .y = f.powerY(),
            .side = .left,
        });
        try self.labels.append(self.a, b.power);
        try self.railPin(b.gnd, f.endX(), f.gndY(), emit.railAngle(.bottom));
        const spot = bank.captionAt(f);
        try self.captions.append(self.a, .{
            .text = try bank.caption(self.a, ic, b.power),
            .x = spot.x,
            .y = spot.y,
            .size = bank_caption_size,
        });
    }

    /// Record one drawn polyline: the wire itself, its segments (which the
    /// routing pass treats as obstacles and the junction pass counts ends on),
    /// and its corners as connection points nothing may route across.
    fn addWire(
        self: *State,
        key: []const u8,
        pts: []const wire.Point,
    ) std.mem.Allocator.Error!void {
        try self.paths.append(self.a, .{ .key = key, .pts = pts });
        try wire.appendSegs(self.a, &self.segs, pts);
        for (pts) |p| try self.stops.append(self.a, p);
    }

    /// A placed part carries the net names as they will be WRITTEN — a
    /// bypass-stub net spelled as its base rail. The placeable keeps netlisp's
    /// own names, which is what the wiring pass reasons about, so the two must
    /// never be confused: `Part.nets` is label text, `Placeable.nets` is
    /// identity. Untouched (and unallocated) when nothing collapses.
    fn labelNets(self: *State, nets: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
        const map = self.req.facts.labels orelse return nets;
        if (map.count() == 0) return nets;
        const out = try self.a.alloc([]const u8, nets.len);
        for (nets, out) |net, *slot| slot.* = map.get(net) orelse net;
        return out;
    }

    /// How one net name is spelled on a label.
    fn labelOf(self: *State, net: []const u8) []const u8 {
        const map = self.req.facts.labels orelse return net;
        return map.get(net) orelse net;
    }

    /// Record what each placed pin carries: a net label, a ground rail symbol,
    /// or a no-connect flag — skipping every label a drawn wire replaced.
    fn connectPins(self: *State) std.mem.Allocator.Error!void {
        for (self.parts.items) |p| try self.wirePins(p);
    }

    /// A ganged cap is connected by its bank's rails, under one label for the
    /// whole bank, so it contributes nothing here — no label, no rail symbol,
    /// no no-connect.
    fn wirePins(self: *State, p: emit.Part) std.mem.Allocator.Error!void {
        if (p.banked != null) return;
        const u = self.req.shapes[p.shape].units[p.unit];
        for (u.pins, 0..) |pin, i| {
            const net = netAt(p, i);
            if (net.len == 0) {
                self.no_connects += 1;
                continue;
            }
            const at = stubEnd(p, u, i);
            // Checked before the rail branch: a same-net gang drops every
            // member's adornment but the first, ground rails included, which is
            // what turns fifteen `GND` symbols in a smear into one.
            if (self.wired(at)) continue;
            if (isRailNet(net)) {
                try self.railPin(net, at.x, at.y, emit.railAngle(pin.side));
                continue;
            }
            try self.labels.append(self.a, net);
        }
    }

    /// True when a drawn wire already carries this stub end's net, so its own
    /// label would only repeat what the run's anchor label already says.
    fn wired(self: *State, pt: wire.Point) bool {
        for (self.no_label.items) |p| {
            if (wire.samePoint(p, pt)) return true;
        }
        return false;
    }

    /// Join each symbol's same-net pins into one short run along their own
    /// edge, so a rail that lands on fifteen pads is drawn — and named — once
    /// instead of fifteen times. Runs before the wiring pass, so a gang's wire
    /// is an obstacle every route respects and its taps are counted when the
    /// junction dots are worked out.
    fn planGangs(self: *State) std.mem.Allocator.Error!void {
        for (self.parts.items, 0..) |p, pi| {
            // A ganged cap is drawn by its bank, which already carries a rail
            // through both of its legs.
            if (p.banked != null) continue;
            for (try gang_mod.plan(self.a, try self.gangPins(p))) |g| {
                try self.drawGang(@intCast(pi), g);
            }
        }
    }

    /// One unit's pins as the gang planner sees them: where each pin's label or
    /// rail symbol would sit, and what it carries under the name it is LABELLED
    /// with — an open pad still counts, as something a run may not span.
    fn gangPins(self: *State, p: emit.Part) std.mem.Allocator.Error![]const gang_mod.PinAt {
        const u = self.req.shapes[p.shape].units[p.unit];
        const out = try self.a.alloc(gang_mod.PinAt, u.pins.len);
        for (u.pins, out, 0..) |pin, *slot, i| {
            slot.* = .{
                .index = @intCast(i),
                .side = pin.side,
                .net = netAt(p, i),
                .at = stubEnd(p, u, i),
            };
        }
        return out;
    }

    /// Draw one gang: a wire along the edge through every member's stub tip,
    /// and every member but the first losing its label — the first one's names
    /// the whole run, exactly as each separate label used to name its own pin.
    fn drawGang(self: *State, part: u32, g: gang_mod.Gang) std.mem.Allocator.Error!void {
        const ref = self.parts.items[part].id.ref;
        const key = try std.fmt.allocPrint(self.a, "gang:{s}:{s}:{s}", .{ ref, @tagName(g.side), g.net });
        try self.addWire(key, try gang_mod.runPts(self.a, g));
        for (g.pins, 0..) |pin, i| {
            try self.ganged.put(self.a, gangKey(part, pin.index), {});
            if (i > 0) try self.no_label.append(self.a, pin.at);
        }
    }

    /// Draw the connections that read better as wire than as a label pair.
    /// Runs on settled coordinates, and relies on `parts` being in `req.items`
    /// order — groups, and the clusters inside them, are contiguous spans
    /// placed in order, so the two lists index alike.
    fn drawWires(self: *State) std.mem.Allocator.Error!void {
        std.debug.assert(self.parts.items.len == self.req.items.len);
        try self.collectField();
        const sites = try self.siteList();
        try self.bindWires(sites);
        try self.netWires(sites);
        self.dots = try wire.junctions(self.a, self.segs.items);
    }

    /// Everything already on the sheet a route must respect: every pin's
    /// connection point, every stub end that carries a label or rail symbol,
    /// every symbol body, and every stub the emitter will draw.
    fn collectField(self: *State) std.mem.Allocator.Error!void {
        for (self.parts.items) |p| {
            const u = self.req.shapes[p.shape].units[p.unit];
            try self.bodies.append(self.a, bodyBox(p, u));
            for (u.pins, 0..) |pin, i| {
                const at = pinPoint(p, pin);
                try self.stops.append(self.a, at);
                // A ganged cap's legs are already drawn by its bank, and its
                // pin sides mean nothing once it is turned on end.
                if (p.banked != null) continue;
                if (netAt(p, i).len == 0) continue;
                const end = stubEnd(p, u, i);
                try self.stops.append(self.a, end);
                try self.segs.append(self.a, .{ .a = at, .b = end });
            }
        }
    }

    /// Every pin a wire could be drawn to, in placement order so the runs the
    /// two rules below pick are the same on every export.
    fn siteList(self: *State) std.mem.Allocator.Error![]Site {
        var out: std.ArrayList(Site) = .empty;
        for (self.parts.items, 0..) |p, pi| {
            // A ganged cap is already wired by its bank; drawing a second run
            // to it would double-connect the pin the bank's rail carries.
            if (p.banked != null) continue;
            const u = self.req.shapes[p.shape].units[p.unit];
            for (u.pins, 0..) |pin, k| {
                // Identity comes from the PLACEABLE's own net names, not the
                // part's label text: a bypass stub is labelled as its rail but
                // is still the two-pin net the small-net rule may draw.
                const net = netAt2(self.req.items[pi], k);
                if (net.len == 0) continue;
                if (isRailNet(netAt(p, k))) continue;
                try out.append(self.a, .{
                    .part = @intCast(pi),
                    .pin = @intCast(k),
                    .end = .{ .at = stubEnd(p, u, k), .side = pin.side },
                    .net = net,
                    .group = self.req.items[pi].group,
                    .cluster = self.req.items[pi].cluster,
                    // A ganged pin starts out an anchor rather than free: a
                    // decoupling cap may still be drawn TO the IC pad it
                    // declares even though that pad now sits on a gang, but
                    // nothing may be drawn FROM it — its connection, and its
                    // label, already belong to the run along that edge.
                    .role = if (self.ganged.contains(gangKey(@intCast(pi), @intCast(k)))) .anchor else .free,
                });
            }
        }
        return out.items;
    }

    /// A decoupling cap's power leg, drawn to the exact IC pad its
    /// `(decouples "IC" PAD)` names — the connection the board's ERC already
    /// insists the design declare, and the one a reader most wants drawn.
    fn bindWires(self: *State, sites: []Site) std.mem.Allocator.Error!void {
        const binds = self.req.facts.binds orelse return;
        for (sites, 0..) |s, si| {
            if (s.role != .free) continue;
            const bind = binds.get(self.refOf(s)) orelse continue;
            const ai = self.padSite(sites, bind, s.net) orelse continue;
            if (ai == si) continue;
            if (!sameCluster(sites[ai], s)) continue;
            _ = try self.joinSites(sites, ai, si);
        }
    }

    /// The site of `bind`'s IC pad, when that pad is on this sheet carrying the
    /// same net as the cap leg being drawn.
    fn padSite(self: *State, sites: []const Site, bind: Bind, net: []const u8) ?usize {
        for (sites, 0..) |s, i| {
            if (s.role == .spoke) continue;
            if (!std.mem.eql(u8, s.net, net)) continue;
            if (!std.mem.eql(u8, self.refOf(s), bind.ref)) continue;
            if (!std.mem.eql(u8, self.padOf(s), bind.pad)) continue;
            return i;
        }
        return null;
    }

    /// A net whose entire membership is two or three pins sitting in one
    /// cluster: a series passive between two parts, a strap resistor, a
    /// crystal's load pair. Drawing it loses nothing — its anchor's label still
    /// names it, and no pin of it lives anywhere else.
    fn netWires(self: *State, sites: []Site) std.mem.Allocator.Error!void {
        const sizes = self.req.facts.net_pins orelse return;
        var by_net: std.StringArrayHashMapUnmanaged(std.ArrayList(u32)) = .empty;
        defer by_net.deinit(self.a);
        for (sites, 0..) |s, i| {
            const gop = try by_net.getOrPut(self.a, s.net);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.a, @intCast(i));
        }
        for (by_net.keys(), by_net.values()) |net, run| {
            if (!wholeNetHere(sites, run.items, sizes.get(net) orelse 0)) continue;
            try self.joinRun(sites, run.items);
        }
    }

    /// Draw a small net as a CHAIN — first pin to second, second to third —
    /// rather than a star. A second run leaving one pin would have to overlap
    /// the first where they share that pin's outward lane, which KiCad reads as
    /// two wires merging; hopping pin to pin keeps every leg its own corridor,
    /// and the shared pin ends up with three wire ends and a junction dot,
    /// exactly as it would be drawn by hand. A link that will not route falls
    /// back to the run's head before the pin gives up and keeps its label.
    fn joinRun(self: *State, sites: []Site, run: []const u32) std.mem.Allocator.Error!void {
        const head = run[0];
        if (sites[head].role == .spoke) return;
        var last = head;
        for (run[1..]) |i| {
            if (sites[i].role != .free) continue;
            if (try self.joinSites(sites, last, i)) {
                last = i;
            } else if (last != head) {
                _ = try self.joinSites(sites, head, i);
            }
        }
    }

    /// Route one spoke onto the pin already on the run. On success the spoke's
    /// own label becomes redundant: the run's head names all of it.
    fn joinSites(self: *State, sites: []Site, ai: usize, si: usize) std.mem.Allocator.Error!bool {
        const key = try self.wireKey(sites[ai], sites[si]);
        const path = try wire.route(self.a, sites[ai].end, sites[si].end, self.obstacles(), key) orelse return false;
        try self.paths.append(self.a, path);
        try wire.appendSegs(self.a, &self.segs, path.pts);
        try self.no_label.append(self.a, sites[si].end.at);
        if (sites[ai].role == .free) sites[ai].role = .anchor;
        sites[si].role = .spoke;
        return true;
    }

    fn obstacles(self: *State) wire.Field {
        return .{
            .stops = self.stops.items,
            .bodies = self.bodies.items,
            .segs = self.segs.items,
        };
    }

    /// A wire's uuid seed: the two pins it joins, which is stable across
    /// re-exports as long as the connection itself is.
    fn wireKey(self: *State, from: Site, to: Site) std.mem.Allocator.Error![]const u8 {
        return std.fmt.allocPrint(self.a, "{s}:{s}>{s}:{s}", .{
            self.refOf(from), self.padOf(from), self.refOf(to), self.padOf(to),
        });
    }

    fn refOf(self: *State, s: Site) []const u8 {
        return self.parts.items[s.part].id.ref;
    }

    fn padOf(self: *State, s: Site) []const u8 {
        const p = self.parts.items[s.part];
        return self.req.shapes[p.shape].units[p.unit].pins[s.pin].pad;
    }

    /// Place one ground symbol, minting its `#PWR…` reference.
    fn railPin(self: *State, net: []const u8, x: i32, y: i32, angle: u32) std.mem.Allocator.Error!void {
        const rail = try self.railIndex(net);
        try self.pins.append(self.a, try self.newRailPin(rail, x, y, angle));
    }

    fn newRailPin(self: *State, rail: u32, x: i32, y: i32, angle: u32) std.mem.Allocator.Error!emit.RailPin {
        const ref = try self.nextRef("#PWR");
        return .{
            .rail = rail,
            .ref = ref,
            .uuid = try emit.elementUuid(self.a, self.req.sheet.design, "pwr", ref),
            .x = x,
            .y = y,
            .angle = angle,
        };
    }

    /// Library index of the symbol naming `net`. Two rails cannot share one
    /// library entry: the entry's Value property is what names the net.
    fn railIndex(self: *State, net: []const u8) std.mem.Allocator.Error!u32 {
        const gop = try self.rail_of_net.getOrPut(self.a, net);
        if (gop.found_existing) return gop.value_ptr.*;
        gop.value_ptr.* = @intCast(self.rails.items.len);
        try self.rails.append(self.a, try railFor(self.a, net));
        return gop.value_ptr.*;
    }

    /// Record one placed symbol in the order the emitter will write it, so the
    /// self-check can match it back out of the bytes.
    fn note(self: *State, uuid: []const u8, lib_name: []const u8) std.mem.Allocator.Error!void {
        try self.uuids.append(self.a, uuid);
        try self.lib_ids.append(self.a, try self.libId(lib_name));
    }

    /// Same, for a `#PWR…` rail symbol: its Value is checked too, because that
    /// property is what names the net.
    fn notePower(self: *State, rp: emit.RailPin) std.mem.Allocator.Error!void {
        const r = self.rails.items[rp.rail];
        try self.note(rp.uuid, r.lib_name);
        try self.rail_values.append(self.a, r.net);
    }

    fn nextRef(self: *State, prefix: []const u8) std.mem.Allocator.Error![]const u8 {
        self.req.seq.* += 1;
        return std.fmt.allocPrint(self.a, "{s}{d:0>2}", .{ prefix, self.req.seq.* });
    }

    fn libId(self: *State, lib_name: []const u8) std.mem.Allocator.Error![]const u8 {
        return std.fmt.allocPrint(self.a, "netlisp:{s}", .{lib_name});
    }

    /// One `power_out` driver per ground rail, in a row under the content.
    /// Without them KiCad's ERC reports `power_pin_not_driven` on every ground
    /// symbol the sheets place. Returns the right edge of the row.
    fn driveRails(self: *State, y: i32) std.mem.Allocator.Error!i32 {
        var x: i32 = flag_margin;
        for (self.req.flag_nets) |net| {
            const ref = try self.nextRef("#FLG");
            try self.flags.append(self.a, .{
                .net = net,
                .ref = ref,
                .uuid = try emit.elementUuid(self.a, self.req.sheet.design, "flg", ref),
                .x = x,
                .y = y,
            });
            x += flag_pitch;
        }
        return x;
    }

    /// Grid-arrange the child-sheet boxes under the sheet's own content, and
    /// report the extents they occupy.
    fn layoutChildren(self: *State, y0: i32) std.mem.Allocator.Error!emit.Rect {
        const n = self.req.children.len;
        if (n == 0) return .{ .x = 0, .y = y0, .w = 0, .h = 0 };
        var cols: usize = 1;
        while (cols * cols < n * 2) cols += 1;
        const step_x = sheet_box_w + sheet_box_gap;
        const step_y = sheet_box_h + 2 * sheet_box_gap;
        for (self.req.children, 0..) |*c, i| {
            c.at = .{
                .x = flag_margin + @as(i32, @intCast(i % cols)) * step_x,
                .y = y0 + @as(i32, @intCast(i / cols)) * step_y,
                .w = sheet_box_w,
                .h = sheet_box_h,
            };
        }
        const rows = (n + cols - 1) / cols;
        return .{
            .x = 0,
            .y = y0,
            .w = flag_margin + @as(i32, @intCast(@min(n, cols))) * step_x,
            .h = @as(i32, @intCast(rows)) * step_y,
        };
    }

    fn finish(self: *State, layout: sheet_mod.Layout) std.mem.Allocator.Error!Result {
        // A sheet with no symbols of its own (the root of a hierarchy) has no
        // content band, so its children start straight under the top margin.
        const content_h = if (self.req.items.len == 0) flag_margin else layout.page_h;
        const kids = try self.layoutChildren(content_h);
        var bottom = content_h + kids.h;
        if (kids.h > 0) bottom += flag_margin;
        const flag_y = bottom + emit.stub_len;
        const flag_x = try self.driveRails(flag_y);
        if (self.flags.items.len > 0) bottom = flag_y + flag_margin;
        // The emitter writes every part, then every rail pin, then each flag
        // (whose own global label is its net); the expectations follow suit.
        for (self.pins.items) |rp| try self.notePower(rp);
        for (self.flags.items) |f| {
            try self.note(f.uuid, emit.flag_lib_name);
            try self.labels.append(self.a, f.net);
        }

        var page = self.req.sheet;
        const widest = @max(@max(layout.page_w, kids.w + flag_margin), flag_x + flag_margin);
        page.page_w = sheet_mod.clampPage(widest);
        page.page_h = sheet_mod.clampPage(bottom);

        return .{
            .doc = .{
                .sheet = page,
                .shapes = self.req.shapes,
                .parts = self.parts.items,
                .captions = self.captions.items,
                .power = .{
                    .rails = self.rails.items,
                    .pins = self.pins.items,
                    .flags = self.flags.items,
                },
                .wiring = .{
                    .paths = self.paths.items,
                    .junctions = self.dots,
                    .no_label = self.no_label.items,
                    .labels = self.free_labels.items,
                },
                .children = self.req.children,
            },
            .expect = .{
                .uuids = self.uuids.items,
                .lib_ids = self.lib_ids.items,
                .labels = self.labels.items,
                .rail_values = self.rail_values.items,
                .no_connects = self.no_connects,
                .sheets = try self.childFiles(),
                // Every stub, every routed segment, and one wire under each
                // PWR_FLAG down to its label.
                .wires = self.segs.items.len + self.flags.items.len,
            },
        };
    }

    fn childFiles(self: *State) std.mem.Allocator.Error![]const []const u8 {
        const out = try self.a.alloc([]const u8, self.req.children.len);
        for (self.req.children, 0..) |c, i| out[i] = c.file;
        return out;
    }
};

/// A pin's identity inside one sheet, for the ganged set.
fn gangKey(part: u32, pin: u32) u64 {
    return (@as(u64, part) << 32) | pin;
}

/// `cell` widened and deepened for a displayed part number. It is centred on the
/// symbol's origin one line under the Value, so the cell has to gain that line
/// below AND enough width either side of the origin — an MPN is routinely longer
/// than the body it names, and an unreserved one would print across whatever the
/// packer put next to it.
fn withMpn(it: Placeable, cell: sheet_mod.Cell) sheet_mod.Cell {
    const mpn = emit.shownMpn(it.id) orelse return cell;
    const half = emit.mpnHalfSpan(mpn);
    var out = cell;
    out.ox = @max(cell.ox, half);
    out.w = @max(cell.w + (out.ox - cell.ox), out.ox + half);
    out.h = cell.h + emit.mpn_drop + shape_mod.grid;
    return out;
}

/// The heading one band of symbols gets on a sheet titled `title`, or null when
/// it needs none. The sheet already prints its own title at the top of the page,
/// so a band holding that section's own parts would print the title a SECOND
/// time — which is exactly what put it on the page twice — and a band holding
/// one of the section's modules only has to name the module.
fn bandHeading(title: []const u8, text: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, text, title)) return null;
    if (title.len == 0) return text;
    const cut = title.len + caption_join.len;
    if (text.len <= cut or !std.mem.startsWith(u8, text, title)) return text;
    if (!std.mem.eql(u8, text[title.len..cut], caption_join)) return text;
    return text[cut..];
}

/// The net LABEL one placed pin carries; "" when the flattener left the pad
/// open.
fn netAt(p: emit.Part, i: usize) []const u8 {
    return if (i < p.nets.len) p.nets[i] else "";
}

/// The net one pin carries under netlisp's own spelling — the identity the
/// wiring pass and the design-wide pin census are keyed on.
fn netAt2(it: Placeable, i: usize) []const u8 {
    return if (i < it.nets.len) it.nets[i] else "";
}

/// Sheet position of one pin of a placed part. Library coordinates are y-UP
/// about the symbol origin and the sheet is y-DOWN; a part ganged into a bank
/// stands at a quarter turn, which KiCad applies counter-clockwise in the
/// library's own frame.
fn pinPoint(p: emit.Part, pin: shape_mod.Pin) wire.Point {
    const r = rotateLib(pin.x, pin.y, p.banked orelse 0);
    return .{ .x = p.x + r[0], .y = p.y - r[1] };
}

fn rotateLib(x: i32, y: i32, angle: u32) [2]i32 {
    return switch (@mod(angle, 360)) {
        90 => .{ -y, x },
        180 => .{ -x, -y },
        270 => .{ y, -x },
        else => .{ x, y },
    };
}

/// The rectangle a placed part's body occupies on the sheet. A ganged part
/// stands on end, so its drawn extents are its unit's the other way round.
fn bodyBox(p: emit.Part, u: shape_mod.Unit) wire.Box {
    const turned = p.banked != null;
    const hw = if (turned) u.half_h else u.half_w;
    const hh = if (turned) u.half_w else u.half_h;
    return .{ .x0 = p.x - hw, .y0 = p.y - hh, .x1 = p.x + hw, .y1 = p.y + hh };
}

/// Where pin `i` of a placed unit holds its label or rail symbol, and the point
/// a drawn wire is routed between. Only ever asked of an upright part, whose
/// `pin.side` still names a real edge. The reach comes from the unit rather
/// than a constant because a crowded edge's labels were dealt into two columns
/// (`kicad_sch/stagger.zig`) — the emitter draws the stub to exactly this point.
fn stubEnd(p: emit.Part, u: shape_mod.Unit, i: usize) wire.Point {
    const pin = u.pins[i];
    const at = pinPoint(p, pin);
    const end = emit.labelPoint(at.x, at.y, pin.side, emit.stubReach(u, i));
    return .{ .x = end[0], .y = end[1] };
}

/// The IC a cluster is built around, for a bank's caption. `plan.cluster` puts
/// the hub first, so a cluster that starts with a passive is the trailing
/// bucket and has no IC to name.
fn clusterIc(items: []const Placeable) []const u8 {
    if (items.len == 0) return "";
    const ref = items[0].id.ref;
    return if (plan_mod.isPassiveRef(ref)) "" else ref;
}

/// True when a ref-des names a bypass capacitor — the same `C` prefix
/// netlisp's own `decoupling_unbound` ERC keys its bypass-cap rule on, read off
/// the leaf of a sub-block path.
fn isBypassRef(ref: []const u8) bool {
    const leaf = if (std.mem.lastIndexOfScalar(u8, ref, '/')) |i| ref[i + 1 ..] else ref;
    if (leaf.len == 0) return false;
    return std.ascii.toUpper(leaf[0]) == 'C';
}

/// True when a net is small enough to draw and every one of its pins is right
/// here, in a single cluster. Both halves matter: a pin on another sheet would
/// still need its label, and pins scattered across the page would need a wire
/// nobody can follow.
fn wholeNetHere(sites: []const Site, run: []const u32, total: u32) bool {
    if (total < 2 or total > 3) return false;
    if (run.len != total) return false;
    const head = sites[run[0]];
    for (run[1..]) |i| {
        if (!sameCluster(sites[i], head)) return false;
    }
    return true;
}

/// True when two pins landed in the same packed cluster — the block a wire can
/// stay inside, and the only scale at which a drawn connection is easier to
/// follow than the net name written twice.
fn sameCluster(x: Site, y: Site) bool {
    if (x.group != y.group) return false;
    return x.cluster == y.cluster;
}

fn groupChanged(prev: Placeable, next: Placeable) bool {
    return prev.group != next.group;
}

fn clusterChanged(prev: Placeable, next: Placeable) bool {
    return prev.group != next.group or prev.cluster != next.cluster;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: export_kicad_sch - Ground-class nets are drawn as power symbols while every other net keeps its label
test "kicad-sch: isRailNet accepts the canonical grounds and nothing else" {
    try testing.expect(isRailNet("GND"));
    try testing.expect(isRailNet("AGND"));
    try testing.expect(isRailNet("DGND"));
    try testing.expect(isRailNet("VSSA"));
    // A module-private ground still counts; its symbol keeps the full name.
    try testing.expect(isRailNet("adc1/GND"));
    try testing.expect(!isRailNet("VDD3V3"));
    try testing.expect(!isRailNet("GND_SENSE"));
    try testing.expect(!isRailNet(""));
}

// spec: export_kicad_sch - A band whose heading repeats the sheet's own title is drawn once, as the title, and a module inside it drops the section prefix
test "kicad-sch: a band heading never repeats the sheet title" {
    const title = "STM32N657L0H3Q Core System";
    // The section's own parts: the page title above them already says this.
    try testing.expect(bandHeading(title, title) == null);
    // One of its modules: the section prefix is the title, so only the module
    // name is left to say.
    try testing.expectEqualStrings("charger", bandHeading(title, "STM32N657L0H3Q Core System / charger").?);
    // An unrelated heading, and a sheet with no title of its own, keep theirs.
    try testing.expectEqualStrings("sub-block buck", bandHeading(title, "sub-block buck").?);
    try testing.expectEqualStrings(title, bandHeading("", title).?);
    // A heading that merely starts with the title is not a prefixed one.
    try testing.expectEqualStrings(
        "STM32N657L0H3Q Core Systems",
        bandHeading(title, "STM32N657L0H3Q Core Systems").?,
    );
}
