//! Projecting the lumped thermal screen onto the board it will actually run on
//! — the single seam between `eval/thermal.zig` (what each part burns, and what
//! it is rated for) and `placement/thermal_field.zig` (where that heat goes once
//! the parts have positions).
//!
//! Four surfaces need this projection: the `?thermal=1` heat-zone PNG, the
//! `scenarios` block of `GET /api/thermal/:name`, the `describe_thermal` CLI
//! tool that shares those bytes, and the review document's cooling-scenario
//! table. Every one of them must be talking about the SAME board — the same
//! outline, the same layer count, the same part boxes — or a reader comparing
//! the picture against the table is comparing two different simulations. So the
//! projection is written once here and nowhere else.
//!
//! Two things are deliberately explicit rather than guessed:
//!
//!   * **A design with no authored outline is reported, not silently sized.**
//!     A board bigger than its parts spreads more heat, so the parts' bounding
//!     box is a genuinely different answer from a `(board …)` rectangle —
//!     `Board.authored` carries which one was used.
//!   * **A powered part with no placed twin is SKIPPED, never guessed onto the
//!     board.** It comes back in the scenario's `skipped` list and every surface
//!     shows it, because dropping a watt on the floor would make the whole
//!     field quietly optimistic.
//!
//! Everything the read surfaces get back is ABSOLUTE °C at a caller-chosen
//! ambient (`Ladder`), converted here from the solver's rise field. That
//! conversion is the whole reason the solver is ambient-free: one solve serves
//! every ambient, and the arithmetic lives in one place.

const std = @import("std");
const flat_netlist = @import("flat_netlist.zig");
const net_name = @import("net_name.zig");
const impedance = @import("placement/impedance.zig");
const optimizer = @import("placement/optimizer.zig");
const pour = @import("placement/pour.zig");
const router = @import("placement/router.zig");
const thermal = @import("eval/thermal.zig");
const thermal_field = @import("placement/thermal_field.zig");

/// The cooling scenarios, re-exported here so a caller can NAME one without
/// importing the solver. That matters to the web layer, which may not compile
/// against `placement/` internals: `?scenario=` has to parse into this enum,
/// and the enum is the only part of the solver a request needs to mention.
pub const Scenario = thermal_field.Scenario;

/// The solver's own types, re-exported. A caller that only ever hands these
/// back to this module — the serve layer's field cache and its field endpoint —
/// names them from here rather than compiling against `placement/` directly,
/// which is the dependency direction the layering rule asks for.
pub const ScenarioResult = thermal_field.ScenarioResult;
pub const PartField = thermal_field.PartField;
pub const Placement = optimizer.Placement;
pub const Heatsink = thermal_field.Heatsink;
pub const HeatsinkMaterial = thermal_field.HeatsinkMaterial;
pub const FinAxis = thermal_field.FinAxis;

/// The board's copper as this projection needs it: the routed tracks and vias,
/// and the hand-drawn zones. Exactly `pour.Copper`, because sampling the outer
/// pours means asking the pour engine for the very fill the Gerber emits —
/// re-deriving a second, nearly-right fill here is how a picture and a number
/// come to disagree about the same board.
///
/// Empty is a perfectly good value: a design with no routes yet simply has its
/// pours computed over bare pads, which is what the PCB view draws too.
pub const Copper = pour.Copper;

// ── Projecting a placement into solver inputs ─────────────────────────────

/// The rectangle the field is solved over, and whether the design authored it.
pub const Board = struct {
    rect: thermal_field.BoardRect,
    /// False ⇒ `rect` is the parts' bounding box standing in for an outline the
    /// design never declared. Reported rather than hidden: a 100 mm board and
    /// the 40 mm huddle of parts on it spread heat very differently, so a
    /// reader has to know which of the two was measured.
    authored: bool,
};

/// The board rectangle the spreader runs over: the placement's own outline when
/// it has one (the same `board_rect` the fab outputs, the DRC and the describe
/// endpoint resolve), else the bounding box of the placed parts.
pub fn boardOf(p: optimizer.Placement) Board {
    if (p.board_rect) |r| return .{
        .rect = .{ .x_mm = r.minx, .y_mm = r.miny, .w_mm = r.w, .h_mm = r.h },
        .authored = true,
    };
    return .{
        .rect = .{
            .x_mm = p.minx,
            .y_mm = p.miny,
            .w_mm = p.maxx - p.minx,
            .h_mm = p.maxy - p.miny,
        },
        .authored = false,
    };
}

/// Copper layers that spread heat on a board with these rules.
///
/// A design declaring no `(stackup …)` runs on the implicit four-layer model,
/// whose two inner layers are both planes — so it gets
/// `thermal_field.default_spreader_layers` without counting anything. A
/// DECLARED stackup is counted honestly: the two outer faces plus one per
/// `(plane …)` row that sits on an INNER position, which is what
/// `thermal_field.spreaderLayers` is written to take. `(stackup 2)` therefore
/// spreads through two layers and not four.
pub fn spreaderLayersOf(rules: optimizer.BoardRules) u8 {
    if (!rules.declaredStackup()) return thermal_field.default_spreader_layers;
    var inner: usize = 0;
    for (rules.planes.declared) |plane| {
        if (plane.index > 1 and plane.index < rules.copper_layers) inner += 1;
    }
    return thermal_field.spreaderLayers(inner);
}

/// Millimetres as the solver's metres.
fn mmToM(mm: f64) f64 {
    return mm * 1.0e-3;
}

/// The conducting sheet `rules` describes: the outer foils it actually
/// specifies, the inner PLANE foils, the finished thickness, and how far a
/// part's land is from the first plane below it.
///
/// A design that declares no `(stackup …)` gets the solver's own screening
/// convention rather than a stack invented here — the same 1.6 mm, one-ounce
/// board `spreaderLayersOf` has always implied, so nothing about an
/// unstackuped design's answer moves.
///
/// Inner SIGNAL foils are left out for the same reason `spreaderLayersOf`
/// leaves them out of the layer count: a routed inner layer is a few per cent
/// copper by area and spreads almost nothing.
pub fn sheetOf(rules: optimizer.BoardRules) thermal_field.Sheet {
    if (!rules.declaredStackup()) return thermal_field.defaultSheet(spreaderLayersOf(rules));
    const stack = rules.physical.stack;
    const n = if (stack.layers > 0) stack.layers else outerIndex(rules);
    if (n < 2) return thermal_field.defaultSheet(spreaderLayersOf(rules));

    var sheet = thermal_field.Sheet{
        .outer_cu_m = mmToM(stack.foilMm(1) + stack.foilMm(n)),
        .laminate_m = mmToM(finishedMm(rules, stack)),
    };
    var i: u8 = 2;
    while (i < n) : (i += 1) {
        if (stack.isPlane(i)) sheet.inner_cu_m += mmToM(stack.foilMm(i));
    }
    const hop = transferHopMm(stack, n);
    if (hop > 0) sheet.transfer_m = mmToM(hop);
    return sheet;
}

/// The bottom copper index, from whichever of the two spellings of the layer
/// count the rules carry.
fn outerIndex(rules: optimizer.BoardRules) u8 {
    return std.math.cast(u8, rules.copper_layers) orelse 0;
}

/// Finished board thickness (mm): what the stackup states, else what the rules
/// carry, else the fab default the impedance solver assumes.
fn finishedMm(rules: optimizer.BoardRules, stack: impedance.Stack) f64 {
    if (stack.board_mm > 0) return stack.board_mm;
    if (rules.physical.board_thickness > 0) return rules.physical.board_thickness;
    return impedance.default_board_mm;
}

/// How far heat crosses to get from the top foil to the first PLANE beneath it
/// (mm) — the dielectric hops and any buried signal foil in between. A stack
/// with no plane at all returns the whole buildup, which is the honest answer:
/// there is nothing nearby to spread into.
fn transferHopMm(stack: impedance.Stack, layers: u8) f64 {
    var hop: f64 = 0;
    var i: u8 = 1;
    while (i < layers) : (i += 1) {
        hop += stack.gapMm(i);
        if (stack.isPlane(i + 1)) return hop;
        hop += stack.foilMm(i + 1);
    }
    return hop;
}

/// Per-cell outer-copper coverage, sampled from the board's OWN poured fills
/// onto exactly the cells `thermal_field` will solve.
///
/// Only a design that declares a stackup is sampled. Coverage derates the
/// spreading, so guessing it on a board whose copper we cannot see would make
/// the answer quietly pessimistic for no reason; handing the solver no map at
/// all keeps the uniform board it has always assumed. Each face carries half
/// the outer cross-section, so a board poured on one side only reads 0.5.
///
/// Tracks and pads are deliberately NOT counted: on a poured board they sit
/// inside the fill already, and on an unpoured one they are a couple of per
/// cent of the layer — a rounding error against the planes.
pub fn coverageOf(
    arena: std.mem.Allocator,
    p: optimizer.Placement,
    copper: Copper,
) std.mem.Allocator.Error!?thermal_field.Coverage {
    if (!p.rules.declaredStackup()) return null;
    const shape = thermal_field.gridShape(boardOf(p).rect);
    const frac = try arena.alloc(f32, shape.cols * shape.rows);
    @memset(frac, 0);

    // Both faces share the same board lattice. Build its edge-distance field
    // once and skip contour tracing: coverage only asks whether each thermal
    // cell centre is inside copper.
    var specs: [2]pour.LayerSpec = undefined;
    var n: usize = 0;
    for ([_]optimizer.Side{ .top, .bottom }) |side| {
        specs[n] = outerSpec(arena, p, copper, side) orelse continue;
        n += 1;
    }
    if (n == 0) return null;
    const fills = pour.computeMasks(arena, p, copper, specs[0..n]) catch return null;
    for (fills) |fill| addFace(frac, shape, fill);
    return .{ .cols = shape.cols, .rows = shape.rows, .outer_frac = frac };
}

/// One outer face's declared pour, specified the same way the renderer and the
/// Gerber specify it. Null when that side declares no pour net; null too when
/// the higher-priority boundaries cannot be resolved, so a pour failure falls
/// back to the uniform board rather than claiming the face is bare.
fn outerSpec(
    arena: std.mem.Allocator,
    p: optimizer.Placement,
    copper: Copper,
    side: optimizer.Side,
) ?pour.LayerSpec {
    const net = p.rules.pourNetOnSide(side) orelse return null;
    var spec = pour.outerSpec(net, side);
    spec.higher = pour.higherThanDeclared(
        arena,
        copper.zones,
        if (side == .top) 0 else 1,
        spec.net,
    ) catch return null;
    return spec;
}

/// Add this face's half-share to every cell whose CENTRE the fill covers.
fn addFace(frac: []f32, shape: thermal_field.GridShape, fill: pour.Fill) void {
    var r: usize = 0;
    while (r < shape.rows) : (r += 1) {
        const y = shape.origin_y_mm + (@as(f64, @floatFromInt(r)) + 0.5) * shape.cell_mm;
        var c: usize = 0;
        while (c < shape.cols) : (c += 1) {
            const x = shape.origin_x_mm + (@as(f64, @floatFromInt(c)) + 0.5) * shape.cell_mm;
            if (fill.contains(x, y)) frac[r * shape.cols + c] += 0.5;
        }
    }
}

/// The board's ratings ceiling: the tightest declared `(operating … MAX)` and
/// the part that declares it.
///
/// Deliberately NOT the lumped screen's own `max_ambient`, which already mixes
/// in each part's junction-derived ceiling — the field computes its own
/// junction ceilings from the placed board, and folding the layout-free ones in
/// would cap every scenario at the still-air answer the ladder exists to
/// improve on.
pub fn ratingsCap(bt: thermal.BoardThermal) thermal_field.AmbientLimit {
    var cap = thermal_field.AmbientLimit{};
    for (bt.parts) |row| {
        const c = row.limits.operating_max_c orelse continue;
        if (cap.c == null or c < cap.c.?) cap = .{ .c = c, .ref_des = row.ref_des };
    }
    return cap;
}

/// Where each `bt` row sits on `p`, in the solver's terms. One `PartInput` per
/// screened row, in the analysis's order, with `box` null for any row that
/// matched no placed part — which is what puts it in the scenario's `skipped`
/// list instead of onto a position it does not have.
///
/// A placed row also carries the two things the LAYOUT decides about a part's
/// heat rather than its datasheet: which face it is mounted on, and how many
/// via barrels stand under it.
pub fn partInputs(
    allocator: std.mem.Allocator,
    bt: thermal.BoardThermal,
    p: optimizer.Placement,
    copper: Copper,
) std.mem.Allocator.Error![]thermal_field.PartInput {
    var index = try PartIndex.build(allocator, p);
    defer index.deinit(allocator);

    const out = try allocator.alloc(thermal_field.PartInput, bt.parts.len);
    for (bt.parts, out) |row, *slot| {
        slot.* = .{
            .ref_des = row.ref_des,
            .origin_key = row.origin_key,
            .watts = row.power.watts orelse 0,
            .theta_jb = row.theta.jb,
            .theta_jc = .{ .generic = row.theta.jc.generic, .top = row.theta.jc.top, .bottom = row.theta.jc.bottom },
            .theta_ja = row.theta.ja,
            .tj_max = row.limits.tj_max,
        };
        const pi = index.find(p, row.ref_des, row.origin_key) orelse continue;
        placeInput(slot, p.parts[pi], copper.vias);
    }
    return out;
}

/// Fill in everything a PLACED part contributes: its box, its side, and the
/// vias standing inside it.
fn placeInput(slot: *thermal_field.PartInput, part: optimizer.Part, vias: []const router.Via) void {
    const box = courtyardBox(part);
    const stitch = viasUnder(vias, box);
    slot.mount = .{
        .box = box,
        .side = if (part.side == .bottom) .bottom else .top,
        .thermal_vias = stitch.count,
        .via_drill_mm = stitch.drill_mm,
    };
}

/// Via barrels standing inside a part's box, and the narrowest drill among
/// them.
///
/// EVERY via counts, not only the ones on a plane net: heat does not know what
/// net a barrel belongs to, and a BGA's escape vias really do carry it down.
/// The narrowest drill is used because a thinner barrel is the poorer
/// conductor, which is the direction to be wrong in.
const Stitch = struct { count: usize = 0, drill_mm: f64 = 0 };

fn viasUnder(vias: []const router.Via, box: thermal_field.BoardRect) Stitch {
    var out = Stitch{};
    for (vias) |v| {
        if (v.x < box.x_mm or v.x > box.x_mm + box.w_mm) continue;
        if (v.y < box.y_mm or v.y > box.y_mm + box.h_mm) continue;
        out.count += 1;
        if (v.drill > 0 and (out.drill_mm == 0 or v.drill < out.drill_mm)) out.drill_mm = v.drill;
    }
    return out;
}

/// Everything one ladder run over `p` is computed from — the board rectangle,
/// the sheet its stackup implies, the coverage its pours sample to, one row per
/// screened part, and the ratings ceiling every scenario is capped by.
pub fn inputsFor(
    allocator: std.mem.Allocator,
    bt: thermal.BoardThermal,
    p: optimizer.Placement,
    copper: Copper,
) std.mem.Allocator.Error!thermal_field.Inputs {
    return .{
        .board = boardOf(p).rect,
        .spreader_layers = spreaderLayersOf(p.rules),
        .sheet = sheetOf(p.rules),
        .coverage = try coverageOf(allocator, p, copper),
        .parts = try partInputs(allocator, bt, p, copper),
        .ratings_cap = ratingsCap(bt),
    };
}

/// A placed part's world-space courtyard as the solver's rectangle — the same
/// box the PNG outlines and the describe endpoint measures gaps against, so the
/// cells a part heats are exactly the cells drawn under it.
fn courtyardBox(part: optimizer.Part) thermal_field.BoardRect {
    const court = optimizer.worldCourtyard(&part);
    return .{ .x_mm = court.minx, .y_mm = court.miny, .w_mm = court.w, .h_mm = court.h };
}

/// Ref-des → placement index, exact first and then the `/`-leaf — the same
/// exact-then-leaf rule the PNG's `?refs=` matching uses.
const PartIndex = struct {
    /// A leaf carried by two parts maps here, so it resolves to NOTHING.
    const ambiguous: usize = std.math.maxInt(usize);

    exact: std.StringHashMapUnmanaged(usize) = .empty,
    origin: std.StringHashMapUnmanaged(usize) = .empty,
    leaf: std.StringHashMapUnmanaged(usize) = .empty,

    fn build(
        allocator: std.mem.Allocator,
        p: optimizer.Placement,
    ) std.mem.Allocator.Error!PartIndex {
        var self = PartIndex{};
        for (p.parts, 0..) |part, i| {
            try self.exact.put(allocator, part.ref_des, i);
            if (i < p.instances.len and p.instances[i].origin_key.len > 0) {
                const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ net_name.parent(part.ref_des) orelse "", p.instances[i].origin_key });
                try self.origin.put(allocator, key, i);
            }
            const short = net_name.leaf(part.ref_des);
            const gop = try self.leaf.getOrPut(allocator, short);
            gop.value_ptr.* = if (gop.found_existing) ambiguous else i;
        }
        return self;
    }

    fn deinit(self: *PartIndex, allocator: std.mem.Allocator) void {
        self.exact.deinit(allocator);
        self.origin.deinit(allocator);
        self.leaf.deinit(allocator);
    }

    /// The part `ref` names, or null. A leaf two parts share resolves to
    /// neither: guessing which board position a watt belongs to would be worse
    /// than reporting the part as unplaced, because the wrong guess is silent.
    fn find(self: PartIndex, p: optimizer.Placement, ref: []const u8, origin: []const u8) ?usize {
        if (origin.len > 0) {
            var buf: [512]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "{s}\x00{s}", .{ net_name.parent(ref) orelse "", origin }) catch return null;
            if (self.origin.get(key)) |i| return i;
        }
        if (self.exact.get(ref)) |i| return i;
        const i = self.leaf.get(net_name.leaf(ref)) orelse return null;
        if (i == ambiguous or i >= p.parts.len) return null;
        return i;
    }
};

/// A saved assembly target resolved onto the current thermal flatten. The
/// placement supplies the physical board side while the thermal row supplies
/// the current ref-des; scoped origin identity bridges ref-des renumbering.
pub const MountedTarget = struct {
    ref_des: []const u8,
    side: optimizer.Side,
};

/// Follow a saved target through ref-des renumbering without ever accepting a
/// recycled exact ref. Null means the saved placement no longer identifies a
/// current thermal part, so applying a sink would risk cooling the wrong IC.
pub fn resolveMountedTarget(bt: thermal.BoardThermal, p: optimizer.Placement, saved_ref: []const u8) ?MountedTarget {
    var mounted: ?MountedTarget = null;
    var origin: []const u8 = "";
    for (p.parts, 0..) |part, i| {
        if (!std.mem.eql(u8, part.ref_des, saved_ref)) continue;
        mounted = .{ .ref_des = saved_ref, .side = part.side };
        if (i < p.instances.len) origin = p.instances[i].origin_key;
        break;
    }
    const saved = mounted orelse return null;
    if (origin.len == 0) return saved;
    for (bt.parts) |part| {
        if (!std.mem.eql(u8, net_name.parent(part.ref_des) orelse "", net_name.parent(saved_ref) orelse "")) continue;
        if (std.mem.eql(u8, part.origin_key, origin)) return .{ .ref_des = part.ref_des, .side = saved.side };
    }
    return null;
}

// ── The ladder as the read surfaces report it ─────────────────────────────

/// One part's row at an ambient: absolute junction and board temperatures
/// rather than the solver's rises above ambient.
pub const PartRow = struct {
    ref: []const u8,
    origin_key: []const u8 = "",
    /// Junction temperature (°C). Null when the part declares neither a θJB nor
    /// a θJA to fall back on, so no junction could be computed at all.
    tj_c: ?f64 = null,
    /// Hottest board copper under the part (°C).
    board_c: f64 = 0,
    /// True when `tj_c` went through the half-of-θJA convention rather than a
    /// declared θJB.
    jb_estimated: bool = false,
    /// Directional package branch used for this scenario.
    junction_path: thermal_field.JunctionPath = .board,
    /// Highest ambient this part alone tolerates (°C) — already an ambient, so
    /// it does NOT shift with the ambient the rest of the row is read at.
    max_ambient_c: ?f64 = null,
};

/// The hottest point of one scenario's board.
pub const Hotspot = struct { x_mm: f64 = 0, y_mm: f64 = 0, c: f64 = 0 };

/// One end of an ambient window and the part that sets it, with the field
/// spelled `ref` the way every other facts surface spells it.
pub const Limit = struct { c: ?f64 = null, ref: []const u8 = "" };

/// One cooling scenario at one ambient.
pub const Row = struct {
    scenario: thermal_field.Scenario,
    /// False ⇒ the solve hit its iteration ceiling. The numbers are still
    /// reported; they are simply not to be trusted.
    converged: bool = true,
    /// Hottest copper anywhere on the board (°C) — the same temperature
    /// `hotspot` sits at, named at the top level for a reader who wants one
    /// number for the scenario.
    board_max_c: f64 = 0,
    hotspot: Hotspot = .{},
    /// Highest ambient the whole board tolerates under this scenario.
    max_ambient: Limit = .{},
    parts: []const PartRow = &.{},
    /// Ref-des of every screened part that matched no placed part.
    skipped: []const []const u8 = &.{},
    heatsink: HeatsinkPlacement = .{},

    /// The part a reader looks at first: the hottest junction, with board
    /// copper standing in for a part that has no junction figure. Null for a
    /// scenario with no placed part at all. Ties keep solver order.
    pub fn hottest(self: Row) ?PartRow {
        var best: ?PartRow = null;
        for (self.parts) |row| {
            if (best == null or heat(row) > heat(best.?)) best = row;
        }
        return best;
    }
};

fn heat(row: PartRow) f64 {
    return row.tj_c orelse row.board_c;
}

/// The whole four-rung ladder at one ambient.
pub const Ladder = struct {
    /// Ambient every absolute temperature below was computed at (°C).
    ambient_c: f64,
    /// One row per scenario, in `thermal_field.Scenario` enum order.
    rows: []const Row = &.{},
    /// Ref-des the heatsink rung bolts its sink to; empty when the board had no
    /// placed part to bolt one to.
    heatsink_ref: []const u8 = "",
    heatsink_side: ?thermal_field.HeatsinkSide = null,
    heatsink_face: ?thermal_field.Side = null,
};

/// A surface's cooling-scenario answer: the ladder, or the reason it has none.
/// Both spellings travel together so no surface has to invent its own way of
/// saying "this board has no layout yet".
pub const Answer = struct {
    ladder: ?Ladder = null,
    /// Why there is no ladder, as a sentence a reader can act on. Empty
    /// whenever `ladder` is set.
    unavailable: []const u8 = "",
};

/// Solve the whole ladder over `p` and report it at `ambient_c`.
pub fn solveAt(
    allocator: std.mem.Allocator,
    bt: thermal.BoardThermal,
    p: optimizer.Placement,
    ambient_c: f64,
    copper: Copper,
) std.mem.Allocator.Error!Ladder {
    return ladderAt(allocator, try solveFields(allocator, bt, p, copper), ambient_c);
}

/// Every rung's field, in RISES above ambient and with no ambient chosen yet —
/// the whole ladder minus the last arithmetic step. This is the shape worth
/// CACHING (`serve/thermal_cache.zig`): the expensive part is the relaxation,
/// and one relaxed field answers every ambient a reader can dial in.
pub fn solveFields(
    allocator: std.mem.Allocator,
    bt: thermal.BoardThermal,
    p: optimizer.Placement,
    copper: Copper,
) std.mem.Allocator.Error![]ScenarioResult {
    return thermal_field.solveScenarios(allocator, try inputsFor(allocator, bt, p, copper));
}

/// As `solveFields`, with a physical assembly authored by the saved layout.
/// Null preserves the historical automatic screening sink.
pub fn solveFieldsWithHeatsink(
    allocator: std.mem.Allocator,
    bt: thermal.BoardThermal,
    p: optimizer.Placement,
    copper: Copper,
    heatsink: ?Heatsink,
) std.mem.Allocator.Error![]ScenarioResult {
    var inputs = try inputsFor(allocator, bt, p, copper);
    if (heatsink) |sink| inputs.heatsink = sink;
    return thermal_field.solveScenarios(allocator, inputs);
}

/// One scenario's rise field and the same scenario as absolute °C — the pair a
/// heat-zone image is drawn from, resolved together so a picture cannot show one
/// scenario's field under another's numbers.
pub const Painted = struct {
    /// The solved field, in rises above ambient.
    result: thermal_field.ScenarioResult,
    /// That field's scenario at the caller's ambient.
    row: Row,
    /// Each PLACED part's row, index-aligned with the placement's `parts`.
    part_rows: []const ?PartRow = &.{},
};

/// Solve exactly ONE scenario over `p` and report it at `ambient_c` — the
/// single-view path, where solving the other three rungs would be work thrown
/// away. The heatsink rung still costs its still-air solve; see
/// `thermal_field.solveScenario`.
pub fn paintAt(
    allocator: std.mem.Allocator,
    bt: thermal.BoardThermal,
    p: optimizer.Placement,
    scenario: Scenario,
    ambient_c: f64,
    copper: Copper,
) std.mem.Allocator.Error!Painted {
    const inputs = try inputsFor(allocator, bt, p, copper);
    const result = try thermal_field.solveScenario(allocator, inputs, scenario);
    const ladder = try ladderAt(allocator, &.{result}, ambient_c);
    return .{
        .result = result,
        .row = ladder.rows[0],
        .part_rows = try rowsByPart(allocator, p, ladder.rows[0].parts),
    };
}

/// Report ONE rung of an already-solved ladder at `ambient_c`, without solving
/// anything.
///
/// `paintAt` above is the cold path: it solves the scenario it is asked for.
/// This is the warm one — a caller that already holds the ladder (the server
/// caches it, keyed on the design's sources and layout) pays only the ambient
/// arithmetic and the part join. Both return the same `Painted`, so the picture
/// a reader gets is the same whether the solve was fresh or cached.
///
/// `results` must be a solved ladder in `Scenario` order; an unknown scenario
/// falls back to its first rung rather than inventing an empty field.
pub fn paintFrom(
    allocator: std.mem.Allocator,
    results: []const thermal_field.ScenarioResult,
    p: optimizer.Placement,
    scenario: Scenario,
    ambient_c: f64,
) std.mem.Allocator.Error!?Painted {
    if (results.len == 0) return null;
    const result = pick: {
        for (results) |r| if (r.scenario == scenario) break :pick r;
        break :pick results[0];
    };
    const ladder = try ladderAt(allocator, &.{result}, ambient_c);
    return .{
        .result = result,
        .row = ladder.rows[0],
        .part_rows = try rowsByPart(allocator, p, ladder.rows[0].parts),
    };
}

/// Convert solved scenarios (rises above ambient) into the absolute-°C rows the
/// read surfaces publish. The solver's fields are ambient-free by construction,
/// so this is the ONLY place the ambient is added — one arithmetic, one set of
/// numbers, however many surfaces read them.
pub fn ladderAt(
    allocator: std.mem.Allocator,
    results: []const thermal_field.ScenarioResult,
    ambient_c: f64,
) std.mem.Allocator.Error!Ladder {
    const rows = try allocator.alloc(Row, results.len);
    for (results, rows) |result, *row| row.* = try rowAt(allocator, result, ambient_c);
    var sink_ref: []const u8 = "";
    var sink_side: ?thermal_field.HeatsinkSide = null;
    var sink_face: ?thermal_field.Side = null;
    for (results) |result| {
        if (result.scenario != .heatsink) continue;
        sink_ref = result.heatsink_ref;
        sink_side = result.heatsink_side;
        sink_face = result.heatsink_face;
        break;
    }
    if (sink_ref.len == 0 and results.len > 0) sink_ref = thermal_field.heatsinkTarget(results[0].parts) orelse "";
    return .{ .ambient_c = ambient_c, .rows = rows, .heatsink_ref = sink_ref, .heatsink_side = sink_side, .heatsink_face = sink_face };
}

fn rowAt(
    allocator: std.mem.Allocator,
    result: thermal_field.ScenarioResult,
    ambient_c: f64,
) std.mem.Allocator.Error!Row {
    const parts = try allocator.alloc(PartRow, result.parts.len);
    for (result.parts, parts) |field, *row| {
        row.* = .{
            .ref = field.ref_des,
            .origin_key = field.origin_key,
            .tj_c = if (field.tj_rise_c) |rise| ambient_c + rise else null,
            .board_c = ambient_c + field.board_rise_c,
            .jb_estimated = field.jb_estimated,
            .junction_path = field.junction_path,
            .max_ambient_c = field.max_ambient_c,
        };
    }
    return .{
        .scenario = result.scenario,
        .converged = result.converged,
        .board_max_c = ambient_c + result.hotspot.rise_c,
        .hotspot = .{
            .x_mm = result.hotspot.x_mm,
            .y_mm = result.hotspot.y_mm,
            .c = ambient_c + result.hotspot.rise_c,
        },
        .max_ambient = .{ .c = result.max_ambient.c, .ref = result.max_ambient.ref_des },
        .parts = parts,
        .skipped = result.skipped,
        .heatsink = .{
            .ref = result.heatsink_ref,
            .side = result.heatsink_side orelse .board_backside,
            .face = result.heatsink_face,
        },
    };
}

/// Each PLACED part's row, index-aligned with `p.parts` — the reverse of the
/// join `partInputs` made, so the image labels a part with exactly the row the
/// facts JSON reports for it. A null entry is a part the screen said nothing
/// about (a passive with no dissipation and no ratings, most of a board).
pub fn rowsByPart(
    allocator: std.mem.Allocator,
    p: optimizer.Placement,
    rows: []const PartRow,
) std.mem.Allocator.Error![]const ?PartRow {
    const out = try allocator.alloc(?PartRow, p.parts.len);
    @memset(out, null);
    var index = try PartIndex.build(allocator, p);
    defer index.deinit(allocator);
    for (rows) |row| {
        const pi = index.find(p, row.ref, row.origin_key) orelse continue;
        out[pi] = row;
    }
    return out;
}

// ── The board-coupled verdict ─────────────────────────────────────────────

/// The board-coupled verdict: the least cooling under which every judgeable
/// part clears its derated junction limit at the ladder's own ambient.
///
/// Same enum and the same `thermal.derate_c` margin as the lumped screen, so a
/// reader is comparing two answers to ONE question. What differs is the model
/// underneath, and it differs a lot: `eval/thermal.zig` scales one θJA per rung,
/// and a datasheet θJA is measured on the JEDEC 2s2p board — 76 x 114 mm, some
/// five times the area of a small module — so it is systematically optimistic
/// for a real board. This reads the junctions the spreader computed over the
/// board's ACTUAL outline, stackup and part positions. Where the two disagree,
/// this one is the board being built, which is why every surface that has a
/// ladder puts its headline here.
///
/// `insufficient_data` when no part carries enough to be judged at all.
pub fn boardVerdict(ladder: Ladder) thermal.Verdict {
    if (!anyJudgeable(ladder)) return .insufficient_data;
    const row = governingRow(ladder) orelse return .over_limit;
    return switch (row.scenario) {
        .natural => .passive_ok,
        .airflow_1ms, .airflow_2ms => .needs_airflow,
        .heatsink => .needs_heatsink,
    };
}

/// The first scenario in `Scenario` enum order — worst cooling first — under
/// which every judgeable part clears its derated limit. This is the rung a
/// board-model sentence is phrased from ("usable to N °C with 1 m/s airflow"),
/// and null means no rung of the ladder works.
pub fn governingRow(ladder: Ladder) ?Row {
    for (ladder.rows) |row| {
        if (allClearDerate(row, ladder.ambient_c)) return row;
    }
    return null;
}

/// The ladder's row for `scenario`. Rows arrive in enum order, but a caller
/// naming the scenario it wants cannot be broken by that order changing.
pub fn rowFor(ladder: Ladder, scenario: Scenario) ?Row {
    for (ladder.rows) |row| {
        if (row.scenario == scenario) return row;
    }
    return null;
}

/// Is there a single part anywhere on the ladder with enough declared to judge?
fn anyJudgeable(ladder: Ladder) bool {
    for (ladder.rows) |row| {
        for (row.parts) |part| {
            if (part.max_ambient_c != null) return true;
        }
    }
    return false;
}

fn allClearDerate(row: Row, ambient_c: f64) bool {
    for (row.parts) |part| {
        if (!clearsDerate(part, ambient_c)) return false;
    }
    return true;
}

/// Does this part sit the derate margin under its junction limit at
/// `ambient_c`?
///
/// The test is the lumped screen's own — `Tj ≤ Tj_max − derate` — rearranged
/// rather than restated, so the two can never drift on the margin they demand.
/// A part's `max_ambient_c` IS `Tj_max − Tj_rise` and its `tj_c` is
/// `ambient + Tj_rise`, so "the junction sits `derate` below its limit" is
/// exactly "the part tolerates `derate` more ambient than it is being read at".
///
/// A part with no junction ceiling declares nothing to judge and cannot fail —
/// the same pass the lumped screen gives a row it could not compute.
fn clearsDerate(part: PartRow, ambient_c: f64) bool {
    const ceiling = part.max_ambient_c orelse return true;
    return ceiling >= ambient_c + thermal.derate_c;
}

/// Physical and package-relative location named by a scenario result.
pub const HeatsinkPlacement = struct {
    ref: []const u8 = "",
    side: thermal_field.HeatsinkSide = .board_backside,
    face: ?thermal_field.Side = null,
};

/// Spell a cooling scenario for a table, including the sink target and face.
pub fn scenarioLabel(
    allocator: std.mem.Allocator,
    scenario: thermal_field.Scenario,
    sink: HeatsinkPlacement,
) std.mem.Allocator.Error![]const u8 {
    return switch (scenario) {
        .natural => "Still air",
        .airflow_1ms => "1 m/s airflow",
        .airflow_2ms => "2 m/s airflow",
        .heatsink => if (sink.ref.len > 0)
            std.fmt.allocPrint(allocator, "Heatsink on {s} ({s})", .{ sink.ref, sinkLabel(sink) })
        else
            std.fmt.allocPrint(allocator, "Heatsink ({s})", .{sinkLabel(sink)}),
    };
}

/// The same scenario as a clause inside a sentence about the board, e.g.
/// "usable to 44 °C ambient **with 1 m/s airflow**". Separate from
/// `scenarioLabel`, which is a table cell and reads as a heading.
pub fn coolingClause(
    allocator: std.mem.Allocator,
    scenario: thermal_field.Scenario,
    sink: HeatsinkPlacement,
) std.mem.Allocator.Error![]const u8 {
    return switch (scenario) {
        .natural => "in still air",
        .airflow_1ms => "with 1 m/s airflow",
        .airflow_2ms => "with 2 m/s airflow",
        .heatsink => if (sink.ref.len > 0)
            std.fmt.allocPrint(allocator, "with a heatsink on the {s} at {s}", .{ sinkLabel(sink), sink.ref })
        else
            std.fmt.allocPrint(allocator, "with a heatsink on the {s}", .{sinkLabel(sink)}),
    };
}

/// The intervention a scenario represents, as the opening of a verdict
/// sentence: "Needs ~1 m/s airflow", "Needs a heatsink on U5". Null names the
/// case where no rung works at all.
pub fn interventionPhrase(
    allocator: std.mem.Allocator,
    scenario: ?thermal_field.Scenario,
    sink: HeatsinkPlacement,
) std.mem.Allocator.Error![]const u8 {
    const s = scenario orelse return "Over limit even with a heatsink";
    return switch (s) {
        .natural => "Passive cooling OK",
        .airflow_1ms => "Needs ~1 m/s airflow",
        .airflow_2ms => "Needs ~2 m/s airflow",
        .heatsink => if (sink.ref.len > 0)
            std.fmt.allocPrint(allocator, "Needs a heatsink on the {s} at {s}", .{ sinkLabel(sink), sink.ref })
        else
            std.fmt.allocPrint(allocator, "Needs a heatsink on the {s}", .{sinkLabel(sink)}),
    };
}

fn sinkLabel(sink: HeatsinkPlacement) []const u8 {
    if (sink.face) |face| return if (face == .top) "PCB top" else "PCB bottom";
    return if (sink.side == .package_top) "package top" else "board backside";
}

/// Collapse a solved ladder's sink fields into the label/report value object.
pub fn sinkOf(ladder: Ladder) HeatsinkPlacement {
    return .{
        .ref = ladder.heatsink_ref,
        .side = ladder.heatsink_side orelse .board_backside,
        .face = ladder.heatsink_face,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A placed part at `(x, y)` with a 2 × 2 mm courtyard.
fn testPart(ref: []const u8, x: f64, y: f64) optimizer.Part {
    return .{ .ref_des = ref, .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = x, .y = y };
}

/// A placement over `parts`, with an authored 40 × 40 mm outline when asked for.
fn testPlacement(parts: []optimizer.Part, authored: bool) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 5,
        .miny = 5,
        .maxx = 35,
        .maxy = 25,
        .generated = false,
        .board_rect = if (authored) .{ .minx = 0, .miny = 0, .w = 40, .h = 40 } else null,
    };
}

/// One screened row with a dissipation and a declared junction path.
fn testRow(ref: []const u8, watts: f64) thermal.PartThermal {
    return .{
        .ref_des = ref,
        .component = "ic",
        .power = .{ .watts = watts, .source = .explicit },
        .theta = .{ .ja = 60 },
        .limits = .{ .tj_max = 125, .operating_max_c = 85 },
    };
}

// spec: thermal_scenarios - the board rectangle is the placement's authored outline, and a design without one falls back to the parts bounding box with the substitution reported
test "the board rectangle prefers the authored outline and reports a fallback" {
    var parts = [_]optimizer.Part{testPart("U1", 10, 10)};

    const authored = boardOf(testPlacement(&parts, true));
    try testing.expect(authored.authored);
    try testing.expectEqual(@as(f64, 40), authored.rect.w_mm);
    try testing.expectEqual(@as(f64, 0), authored.rect.x_mm);

    const fallback = boardOf(testPlacement(&parts, false));
    try testing.expect(!fallback.authored);
    try testing.expectEqual(@as(f64, 5), fallback.rect.x_mm);
    try testing.expectEqual(@as(f64, 30), fallback.rect.w_mm);
    try testing.expectEqual(@as(f64, 20), fallback.rect.h_mm);
}

// spec: thermal_scenarios - screened parts are matched to placed parts by exact ref then by unique leaf, and a row matching nothing is left unplaced for the solver to report as skipped
test "screened rows match placed parts exact-then-leaf and unmatched rows stay unplaced" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parts = [_]optimizer.Part{
        testPart("U1", 10, 10),
        testPart("buck/U7", 20, 12),
        testPart("a/U9", 25, 15),
        testPart("b/U9", 30, 18),
    };
    const p = testPlacement(&parts, true);
    const bt = thermal.BoardThermal{
        .ambient_c = 25,
        .parts = &.{
            testRow("U1", 1.0), // exact
            testRow("U7", 0.5), // leaf of buck/U7
            testRow("U9", 0.5), // leaf carried by TWO parts — ambiguous
            testRow("U_GHOST", 2.0), // nothing at all
        },
    };

    const inputs = try partInputs(arena, bt, p, .{});
    try testing.expectEqual(@as(usize, 4), inputs.len);
    // The exact match takes U1's own courtyard: a 2 × 2 mm box centred on (10,10).
    try testing.expectEqual(@as(f64, 9), inputs[0].mount.box.?.x_mm);
    try testing.expectEqual(@as(f64, 2), inputs[0].mount.box.?.w_mm);
    // The leaf match lands on the sub-block part it names.
    try testing.expectEqual(@as(f64, 19), inputs[1].mount.box.?.x_mm);
    // An ambiguous leaf and an absent ref both stay unplaced rather than being
    // docked onto a position they do not have.
    try testing.expect(inputs[2].mount.box == null);
    try testing.expect(inputs[3].mount.box == null);
    // The projection carries the screen's own figures through untouched.
    try testing.expectEqual(@as(f64, 1.0), inputs[0].watts);
    try testing.expectEqual(@as(f64, 60), inputs[0].theta_ja.?);
    try testing.expectEqual(@as(f64, 125), inputs[0].tj_max.?);

    // …and the solver duly reports the two unmatched rows as skipped.
    const result = try thermal_field.solveScenario(arena, try inputsFor(arena, bt, p, .{}), .natural);
    try testing.expectEqual(@as(usize, 2), result.skipped.len);
    try testing.expectEqualStrings("U9", result.skipped[0]);
    try testing.expectEqualStrings("U_GHOST", result.skipped[1]);
}

// spec: thermal_scenarios - layout thermal rows follow scoped origin identity across ref-des renumbering before considering a recycled exact ref
test "thermal placement follows origin across ref-des renumbering" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = [_]optimizer.Part{
        testPart("mixer/U15", 10, 10),
        testPart("mixer/U8", 30, 10),
    };
    const instances = [_]flat_netlist.FlatInstance{
        .{ .ref_des = "mixer/U15", .origin_key = "U1", .component = "mixer", .value = "", .footprint = "", .properties = &.{}, .uuid = "" },
        .{ .ref_des = "mixer/U8", .origin_key = "U2", .component = "other", .value = "", .footprint = "", .properties = &.{}, .uuid = "" },
    };
    var p = testPlacement(&parts, true);
    p.instances = &instances;
    var row = testRow("mixer/U8", 1);
    row.origin_key = "U1";
    const inputs = try partInputs(arena, .{ .ambient_c = 25, .parts = &.{row} }, p, .{});
    const box = inputs[0].mount.box orelse return error.TestExpectedMount;
    try testing.expectApproxEqAbs(@as(f64, 9), box.x_mm, 1e-9);
    const target = resolveMountedTarget(.{ .ambient_c = 25, .parts = &.{row} }, p, "mixer/U15") orelse
        return error.TestExpectedTarget;
    try testing.expectEqualStrings("mixer/U8", target.ref_des);
    try testing.expectEqual(optimizer.Side.top, target.side);
}

// spec: thermal_scenarios - the spreader layer count is the implicit four-layer board when no stackup is declared and the declared inner planes plus two outer faces when one is
test "the spreader layer count follows the declared stackup" {
    // No `(stackup …)` form at all ⇒ the implicit four-layer model.
    try testing.expectEqual(thermal_field.default_spreader_layers, spreaderLayersOf(.{}));

    // A declared plane-less two-layer board spreads through its two faces only.
    const none: []const []const u8 = &.{};
    try testing.expectEqual(@as(u8, 2), spreaderLayersOf(.{ .plane_nets = none, .copper_layers = 2 }));

    // A declared four-layer board with both inner layers poured spreads through
    // four; a plane declared on an OUTER face is already one of the two faces
    // and is not counted twice.
    const named: []const []const u8 = &.{"GND"};
    const inner = [_]optimizer.PlaneAt{ .{ .index = 2, .net = "GND" }, .{ .index = 3, .net = "V3V3" } };
    try testing.expectEqual(@as(u8, 4), spreaderLayersOf(.{
        .plane_nets = named,
        .copper_layers = 4,
        .planes = .{ .declared = &inner },
    }));
    const outer = [_]optimizer.PlaneAt{ .{ .index = 1, .net = "GND" }, .{ .index = 4, .net = "GND" } };
    try testing.expectEqual(@as(u8, 2), spreaderLayersOf(.{
        .plane_nets = named,
        .copper_layers = 4,
        .planes = .{ .declared = &outer },
    }));
}

// spec: thermal_scenarios - the ratings cap is the tightest declared operating maximum and never the lumped screen's junction-derived ceiling
test "the ratings cap comes from the declared operating maxima alone" {
    var hot = testRow("U1", 5.0);
    hot.limits.operating_max_c = 85;
    var cool = testRow("U2", 0.1);
    cool.limits.operating_max_c = 70;
    var unrated = testRow("U3", 0.1);
    unrated.limits.operating_max_c = null;

    const cap = ratingsCap(.{ .ambient_c = 25, .parts = &.{ hot, cool, unrated } });
    try testing.expectEqual(@as(f64, 70), cap.c.?);
    try testing.expectEqualStrings("U2", cap.ref_des);

    // Nothing rated ⇒ no cap at all, rather than a zero a scenario would obey.
    const open = ratingsCap(.{ .ambient_c = 25, .parts = &.{unrated} });
    try testing.expect(open.c == null);
}

// spec: thermal_scenarios - the ladder reports absolute temperatures at the caller's ambient, shifting junction and board figures by it while leaving each part's maximum ambient alone
test "the ladder converts rises to absolute temperatures at the requested ambient" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parts = [_]optimizer.Part{testPart("U1", 10, 10)};
    const p = testPlacement(&parts, true);
    const bt = thermal.BoardThermal{ .ambient_c = 25, .parts = &.{testRow("U1", 1.0)} };
    const results = try thermal_field.solveScenarios(arena, try inputsFor(arena, bt, p, .{}));

    const cold = try ladderAt(arena, results, 25);
    const warm = try ladderAt(arena, results, 55);
    try testing.expectEqual(@as(usize, 4), cold.rows.len);
    try testing.expectEqual(thermal_field.Scenario.natural, cold.rows[0].scenario);
    try testing.expectEqual(thermal_field.Scenario.heatsink, cold.rows[3].scenario);
    try testing.expectEqualStrings("U1", cold.heatsink_ref);

    // Thirty degrees more ambient is exactly thirty degrees more junction,
    // board copper and hotspot — the linearity the solver is built on.
    try testing.expectApproxEqAbs(cold.rows[0].parts[0].tj_c.? + 30, warm.rows[0].parts[0].tj_c.?, 1e-9);
    try testing.expectApproxEqAbs(cold.rows[0].parts[0].board_c + 30, warm.rows[0].parts[0].board_c, 1e-9);
    try testing.expectApproxEqAbs(cold.rows[0].board_max_c + 30, warm.rows[0].board_max_c, 1e-9);
    try testing.expectApproxEqAbs(cold.rows[0].hotspot.c + 30, warm.rows[0].hotspot.c, 1e-9);
    // `board_max_c` IS the hotspot's temperature, named twice for the reader.
    try testing.expectEqual(cold.rows[0].hotspot.c, cold.rows[0].board_max_c);

    // A maximum ambient is already an ambient, so it does NOT move with the one
    // the rest of the row is read at.
    try testing.expectEqual(cold.rows[0].max_ambient.c.?, warm.rows[0].max_ambient.c.?);
    try testing.expectEqual(cold.rows[0].parts[0].max_ambient_c.?, warm.rows[0].parts[0].max_ambient_c.?);

    // The hottest part is the one a reader is pointed at, and more airflow
    // strictly cools it.
    try testing.expectEqualStrings("U1", cold.rows[0].hottest().?.ref);
    try testing.expect(cold.rows[1].hottest().?.tj_c.? < cold.rows[0].hottest().?.tj_c.?);
}

// spec: thermal_scenarios - each placed part is handed back the very row the facts report for it, and a part the screen said nothing about is handed none
test "every placed part gets back its own reported row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parts = [_]optimizer.Part{
        testPart("U1", 10, 10),
        testPart("buck/U7", 20, 12),
        testPart("C9", 30, 18), // a passive the screen never listed
    };
    const p = testPlacement(&parts, true);
    const bt = thermal.BoardThermal{ .ambient_c = 25, .parts = &.{ testRow("U1", 1.0), testRow("U7", 0.5) } };
    const ladder = try solveAt(arena, bt, p, 25, .{});
    const by_part = try rowsByPart(arena, p, ladder.rows[0].parts);

    try testing.expectEqual(@as(usize, 3), by_part.len);
    try testing.expectEqualStrings("U1", by_part[0].?.ref);
    // The leaf join reaches the sub-block part, exactly as `partInputs` did.
    try testing.expectEqualStrings("U7", by_part[1].?.ref);
    try testing.expect(by_part[2] == null);
    // The row handed back IS the reported one, not a recomputation of it.
    try testing.expectEqual(ladder.rows[0].parts[0].tj_c.?, by_part[0].?.tj_c.?);
}

// spec: thermal_scenarios - every scenario carries a label a table can print, and the heatsink row names the part its sink is bolted to
test "each scenario carries a printable label naming the heatsink's target" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("Still air", try scenarioLabel(arena, .natural, .{ .ref = "U1" }));
    try testing.expectEqualStrings("1 m/s airflow", try scenarioLabel(arena, .airflow_1ms, .{ .ref = "U1" }));
    try testing.expectEqualStrings("2 m/s airflow", try scenarioLabel(arena, .airflow_2ms, .{ .ref = "U1" }));
    try testing.expectEqualStrings("Heatsink on U5 (board backside)", try scenarioLabel(arena, .heatsink, .{ .ref = "U5" }));
    // A board with nothing placed has no part to bolt a sink to, and says so by
    // dropping the clause rather than naming the empty string.
    try testing.expectEqualStrings("Heatsink (board backside)", try scenarioLabel(arena, .heatsink, .{}));
}

/// A ladder whose one part tolerates `ceilings[i]` °C of ambient under rung
/// `i`, read at `ambient_c`. Enough to drive the verdict ladder without a solve.
fn ceilingLadder(
    alloc: std.mem.Allocator,
    ceilings: [4]?f64,
    ambient_c: f64,
) std.mem.Allocator.Error!Ladder {
    const order = [_]Scenario{ .natural, .airflow_1ms, .airflow_2ms, .heatsink };
    const rows = try alloc.alloc(Row, order.len);
    for (order, ceilings, rows) |scenario, ceiling, *row| {
        const parts = try alloc.alloc(PartRow, 1);
        parts[0] = .{ .ref = "U1", .tj_c = 100, .board_c = 80, .max_ambient_c = ceiling };
        row.* = .{
            .scenario = scenario,
            .max_ambient = .{ .c = ceiling, .ref = "U1" },
            .parts = parts,
        };
    }
    return .{ .ambient_c = ambient_c, .rows = rows, .heatsink_ref = "U1" };
}

// spec: thermal_scenarios - the board verdict is the first cooling scenario in ladder order under which every judgeable part sits the shared derate margin under its junction limit, and over_limit when none does
test "the board verdict is the least cooling that clears the shared derate" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // At 25 °C the derate demands a part tolerate 45 °C of ambient. Still air
    // clears it, so the board needs no help at all.
    try testing.expectEqual(
        thermal.Verdict.passive_ok,
        boardVerdict(try ceilingLadder(a, .{ 50, 60, 70, 65 }, 25)),
    );
    // Still air one degree short: the first rung that clears governs, and both
    // airflow rungs report as the same intervention.
    try testing.expectEqual(
        thermal.Verdict.needs_airflow,
        boardVerdict(try ceilingLadder(a, .{ 44, 60, 70, 65 }, 25)),
    );
    try testing.expectEqual(
        thermal.Verdict.needs_airflow,
        boardVerdict(try ceilingLadder(a, .{ 44, 44, 70, 65 }, 25)),
    );
    // Only the sink clears ⇒ a heatsink; nothing clears ⇒ over limit.
    try testing.expectEqual(
        thermal.Verdict.needs_heatsink,
        boardVerdict(try ceilingLadder(a, .{ 44, 44, 44, 65 }, 25)),
    );
    try testing.expectEqual(
        thermal.Verdict.over_limit,
        boardVerdict(try ceilingLadder(a, .{ 44, 44, 44, 44 }, 25)),
    );

    // The boundary is exactly `ambient + derate`, and it is the LUMPED screen's
    // own margin rather than a second number this module chose.
    const edge = 25 + thermal.derate_c;
    try testing.expectEqual(
        thermal.Verdict.passive_ok,
        boardVerdict(try ceilingLadder(a, .{ edge, edge, edge, edge }, 25)),
    );
    // …and it moves with the ambient the ladder was read at: the SAME board
    // that passed at 25 °C needs airflow once read 6 °C hotter, because its
    // 50 °C still-air ceiling no longer clears 31 + 20.
    try testing.expectEqual(
        thermal.Verdict.needs_airflow,
        boardVerdict(try ceilingLadder(a, .{ 50, 60, 70, 65 }, 31)),
    );

    // A ladder nothing could be judged from says so rather than passing.
    try testing.expectEqual(
        thermal.Verdict.insufficient_data,
        boardVerdict(try ceilingLadder(a, .{ null, null, null, null }, 25)),
    );

    // The governing row is the rung that actually cleared — the one every
    // board-model sentence is phrased from.
    try testing.expectEqual(
        Scenario.airflow_1ms,
        governingRow(try ceilingLadder(a, .{ 44, 60, 70, 65 }, 25)).?.scenario,
    );
    try testing.expect(governingRow(try ceilingLadder(a, .{ 44, 44, 44, 44 }, 25)) == null);
    // …and a row can be fetched by scenario regardless of ladder order.
    try testing.expectEqual(
        Scenario.heatsink,
        rowFor(try ceilingLadder(a, .{ 50, 60, 70, 65 }, 25), .heatsink).?.scenario,
    );
}

// spec: thermal_scenarios - a board whose parts are all unplaced still solves, reporting every screened part as skipped rather than failing
test "a board with no placed parts solves to an all-skipped ladder" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var none = [_]optimizer.Part{};
    const p = testPlacement(&none, true);
    const bt = thermal.BoardThermal{ .ambient_c = 25, .parts = &.{ testRow("U1", 1.0), testRow("U2", 2.0) } };
    const ladder = try solveAt(arena, bt, p, 40, .{});

    try testing.expectEqual(@as(usize, 4), ladder.rows.len);
    for (ladder.rows) |row| {
        try testing.expectEqual(@as(usize, 0), row.parts.len);
        try testing.expectEqual(@as(usize, 2), row.skipped.len);
        try testing.expect(row.hottest() == null);
        // Nothing reaches the board, so every cell sits at ambient exactly.
        try testing.expectEqual(@as(f64, 40), row.board_max_c);
        // …and the only ceiling left is the parts' declared ratings.
        try testing.expectEqual(@as(f64, 85), row.max_ambient.c.?);
    }
    try testing.expectEqualStrings("", ladder.heatsink_ref);
}

// spec: thermal_scenarios - the ladder's rung fields are solvable on their own, ambient-free, so a caller can retain one solve and read it at any ambient afterwards
// spec: thermal_scenarios - a scenario can be painted from an already-solved ladder, giving the same field, row and part rows as solving that scenario fresh
test "a ladder solved once paints and reads at any ambient without re-solving" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parts = [_]optimizer.Part{ testPart("U1", 10, 10), testPart("U2", 28, 18) };
    const p = testPlacement(&parts, true);
    const bt = thermal.BoardThermal{ .ambient_c = 25, .parts = &.{ testRow("U1", 1.5), testRow("U2", 0.4) } };

    // One ambient-free solve — the shape the field cache retains.
    const fields = try solveFields(arena, bt, p, .{});
    try testing.expectEqual(@typeInfo(Scenario).@"enum".field_names.len, fields.len);

    // Reading it at two ambients shifts every absolute temperature one for one
    // while the underlying rise field never moves. This is what lets one solve
    // answer every ambient a reader dials in.
    const at25 = try ladderAt(arena, fields, 25);
    const at70 = try ladderAt(arena, fields, 70);
    try testing.expectApproxEqAbs(at25.rows[0].board_max_c + 45, at70.rows[0].board_max_c, 1e-9);
    try testing.expectApproxEqAbs(at25.rows[0].max_ambient.c.?, at70.rows[0].max_ambient.c.?, 1e-9);

    // Painting from the retained ladder is the same picture solving that one
    // scenario fresh would have produced — same field, same row, same parts.
    const warm = (try paintFrom(arena, fields, p, .airflow_1ms, 40)).?;
    const cold = try paintAt(arena, bt, p, .airflow_1ms, 40, .{});
    try testing.expectEqual(cold.result.scenario, warm.result.scenario);
    try testing.expectEqual(cold.result.grid.rise_c.len, warm.result.grid.rise_c.len);
    for (cold.result.grid.rise_c, warm.result.grid.rise_c) |c, w| try testing.expectApproxEqAbs(c, w, 1e-4);
    try testing.expectApproxEqAbs(cold.row.board_max_c, warm.row.board_max_c, 1e-4);
    try testing.expectEqual(cold.part_rows.len, warm.part_rows.len);
    try testing.expectApproxEqAbs(cold.part_rows[0].?.board_c, warm.part_rows[0].?.board_c, 1e-4);

    // An empty ladder has nothing to paint, and says so rather than inventing
    // an all-ambient board.
    try testing.expect(try paintFrom(arena, &.{}, p, .natural, 25) == null);
}

// spec: thermal_scenarios - the conducting sheet is read off a declared stackup's finished thickness, per-foil copper weights and dielectric hop, and a design declaring none falls back to the solver's own screening convention
test "the conducting sheet is read off the declared stackup" {
    // No `(stackup …)` at all ⇒ the solver's own screening sheet, untouched,
    // so an unstackuped design's numbers do not move.
    const screen = thermal_field.defaultSheet(thermal_field.default_spreader_layers);
    const bare = sheetOf(.{});
    try testing.expectEqual(screen.outer_cu_m, bare.outer_cu_m);
    try testing.expectEqual(screen.inner_cu_m, bare.inner_cu_m);
    try testing.expectEqual(screen.laminate_m, bare.laminate_m);
    try testing.expectEqual(screen.transfer_m, bare.transfer_m);

    // A declared four-layer board: 2 oz outer foil, 1 oz inner planes, a 0.8 mm
    // finished board, and a 0.15 mm dielectric from the top foil to the plane
    // right under it.
    const named: []const []const u8 = &.{"GND"};
    const declared = [_]optimizer.PlaneAt{
        .{ .index = 2, .net = "GND" },
        .{ .index = 3, .net = "V3V3" },
    };
    const foils = [_]impedance.Foil{
        .{ .index = 1, .thickness_mm = 0.07 },
        .{ .index = 2, .thickness_mm = 0.035 },
        .{ .index = 3, .thickness_mm = 0.035 },
        .{ .index = 4, .thickness_mm = 0.07 },
    };
    const dielectrics = [_]impedance.Dielectric{
        .{ .after_layer = 1, .thickness_mm = 0.15, .er = 4.3 },
    };
    const planes: []const u8 = &.{ 2, 3 };
    const sheet = sheetOf(.{
        .plane_nets = named,
        .copper_layers = 4,
        .planes = .{ .declared = &declared },
        .physical = .{ .stack = .{
            .layers = 4,
            .planes = planes,
            .foils = &foils,
            .dielectrics = &dielectrics,
            .board_mm = 0.8,
        } },
    });
    // The two outer foils spread as one face pair, the two inner planes as the
    // other, and the laminate is the finished thickness the fab was told.
    try testing.expectApproxEqAbs(0.14e-3, sheet.outer_cu_m, 1e-12);
    try testing.expectApproxEqAbs(0.07e-3, sheet.inner_cu_m, 1e-12);
    try testing.expectApproxEqAbs(0.8e-3, sheet.laminate_m, 1e-12);
    // The transfer hop stops at the FIRST plane below the top face, not at the
    // far side of the board.
    try testing.expectApproxEqAbs(0.15e-3, sheet.transfer_m, 1e-12);
}

// spec: thermal_scenarios - a part carries its mounted side and the vias standing inside its own courtyard into the solver, so a bottom-side part blocks the bottom face and a via array under a land is counted
test "a part carries its side and the vias under it into the solver" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parts = [_]optimizer.Part{ testPart("U1", 10, 10), testPart("U2", 30, 20) };
    parts[1].side = .bottom;
    const p = testPlacement(&parts, true);
    const bt = thermal.BoardThermal{
        .ambient_c = 25,
        .parts = &.{ testRow("U1", 1.0), testRow("U2", 1.0) },
    };
    // Four vias inside U1's 2 × 2 mm courtyard, one just outside it, and one
    // under U2 — heat does not care what net any of them belongs to.
    const vias = [_]router.Via{
        .{ .x = 9.5, .y = 9.5, .dia = 0.6, .net = 0, .drill = 0.3 },
        .{ .x = 10.5, .y = 9.5, .dia = 0.6, .net = 1, .drill = 0.3 },
        .{ .x = 9.5, .y = 10.5, .dia = 0.6, .net = 2, .drill = 0.25 },
        .{ .x = 10.5, .y = 10.5, .dia = 0.6, .net = 3, .drill = 0.3 },
        .{ .x = 14.0, .y = 10.0, .dia = 0.6, .net = 4, .drill = 0.2 },
        .{ .x = 30.0, .y = 20.0, .dia = 0.8, .net = 5, .drill = 0.4 },
    };

    const inputs = try partInputs(arena, bt, p, .{ .vias = &vias });
    try testing.expectEqual(thermal_field.Side.top, inputs[0].mount.side);
    try testing.expectEqual(thermal_field.Side.bottom, inputs[1].mount.side);
    // Only the four standing inside the land count, and the narrowest of them
    // sets the drill — the thinner barrel is the poorer conductor, which is the
    // direction to be wrong in.
    try testing.expectEqual(@as(usize, 4), inputs[0].mount.thermal_vias);
    try testing.expectApproxEqAbs(0.25, inputs[0].mount.via_drill_mm, 1e-12);
    try testing.expectEqual(@as(usize, 1), inputs[1].mount.thermal_vias);

    // And a board with no routed copper at all hands the solver no vias rather
    // than inventing a stitch pattern under every part.
    const dry = try partInputs(arena, bt, p, .{});
    try testing.expectEqual(@as(usize, 0), dry[0].mount.thermal_vias);
}

// spec: thermal_scenarios - outer copper coverage is sampled from the board's own poured fills onto the solver's cells, and a design whose rules declare no stackup hands the solver no coverage rather than a guessed one
test "outer copper coverage is sampled from the board's own pours" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parts = [_]optimizer.Part{testPart("U1", 10, 10)};

    // A design that declared no stackup has no poured fills to sample, so the
    // solver is handed nothing and keeps its uniform screening sheet rather
    // than a coverage map guessed on the design's behalf.
    var plain = testPlacement(&parts, true);
    try testing.expect(try coverageOf(arena, plain, .{}) == null);

    // A declared stackup whose outer faces carry no plane net is the same
    // story: declared is not the same as poured.
    const named: []const []const u8 = &.{"GND"};
    const inner = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    plain.rules = .{
        .plane_nets = named,
        .copper_layers = 4,
        .planes = .{ .declared = &inner },
    };
    try testing.expect(try coverageOf(arena, plain, .{}) == null);

    // Pour GND on the top face and the map lands on exactly the cells the solve
    // will use, each cell between bare and both-faces-poured.
    const outer = [_]optimizer.PlaneAt{
        .{ .index = 1, .net = "GND" },
        .{ .index = 2, .net = "GND" },
    };
    const nets = [_]optimizer.FlatNet{.{ .name = "GND", .pins = &.{} }};
    var poured = testPlacement(&parts, true);
    poured.nets = &nets;
    poured.rules = .{
        .plane_nets = named,
        .copper_layers = 4,
        .planes = .{ .declared = &outer },
    };
    // A GND via seeds the top pour — an unseeded fill is an orphan island and
    // renders nothing, which is the pour's own rule, not the field's.
    const stitch = [_]router.Via{.{ .x = 20, .y = 20, .dia = 0.6, .net = 0, .drill = 0.3 }};
    const cov = (try coverageOf(arena, poured, .{ .vias = &stitch })).?;
    const shape = thermal_field.gridShape(boardOf(poured).rect);
    try testing.expectEqual(shape.cols, cov.cols);
    try testing.expectEqual(shape.rows, cov.rows);
    try testing.expectEqual(shape.cols * shape.rows, cov.outer_frac.len);

    var covered: usize = 0;
    for (cov.outer_frac) |f| {
        try testing.expect(f >= 0 and f <= 1);
        if (f > 0) covered += 1;
    }
    // One poured face out of two ⇒ half coverage over the board's interior.
    try testing.expect(covered > 0);
    try testing.expectApproxEqAbs(@as(f32, 0.5), cov.outer_frac[cov.outer_frac.len / 2], 1e-6);
}
