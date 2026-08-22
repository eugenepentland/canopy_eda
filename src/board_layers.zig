//! The board's CANONICAL LAYER TABLE — one place that knows what copper a
//! board has, what each layer is called, which of them the router may draw on,
//! and how each one is spelled in a Gerber attribute or a KiCad file.
//!
//! Two index spaces coexist on a PCB and confusing them is a shipped short, so
//! they are distinct TYPES here rather than two meanings of `u8`:
//!
//!   * **`StackIndex`** — the 1-based PHYSICAL position, planes included:
//!     1 = F.Cu, `stackCount()` = B.Cu, everything between an inner layer.
//!     This is what a `(stackup N (plane IDX …))` form authors, what the
//!     impedance model stacks, and what a Gerber file name counts.
//!   * **`SignalIndex`** — the dense ROUTABLE numbering, planes SKIPPED:
//!     0 = F.Cu, 1 = B.Cu, then 2.. for each inner layer no plane claimed, in
//!     stack order. This is what `router.Track.layer` carries, what a saved
//!     layout's `"l"` field persists, and what a route policy's layer mask
//!     indexes.
//!
//! A board with a ground plane on In1 has signal index 2 on stack index 3 —
//! pass one where the other is meant and copper lands on the plane. The two
//! enums make that a compile error at every new call site; the older `u8`
//! helpers on `optimizer.BoardRules` forward here and keep their existing
//! signatures so the wide call surface is untouched.
//!
//! `Stack` is the cheap scalar view (the primitive stackup facts, no
//! allocation, safe in a hot loop); `LayerTable` materializes one `Row` per
//! physical copper layer for the consumers that want to walk the board
//! top-to-bottom — the viewer blob, the Gerber file plan, the describe JSON —
//! followed by the fixed TECHNICAL rows (mask, paste, silkscreen, board
//! profile) that every board carries regardless of its stackup. `rows()` is the
//! copper set, `techRows()` the technical set, and `fabRows()` the whole
//! fabrication package in emission order.
//!
//! Dependency-light on purpose: this module imports only `std`, so every
//! subsystem — evaluator, placer, router, exporters, server — can derive from
//! it without a cycle.
//!
//! Its sibling `render_order.zig` is the same idea for the other half of a
//! layer's identity: this file says what copper a board HAS, that one says in
//! what order the render surfaces PAINT it. Both are `std`-only tables that
//! every renderer derives from rather than restating.

const std = @import("std");
const testing = std.testing;

/// Ceiling on `(stackup N …)`, enforced by the evaluator's stackup form.
pub const max_copper_layers: u8 = 32;
/// Ceiling on the ROUTABLE layers a `LayerSet` (u64) can name. The router's
/// per-net layer masks are u64 words, so signal index 64+ can never be
/// restricted or preferred.
pub const max_signal_layers: u8 = 64;
/// Clamp a persisted sidecar `"l"` field is read through, so a corrupt file
/// cannot wrap a `u8`.
pub const max_sidecar_layer: u8 = 255;

/// Total copper layers the LEGACY IMPLICIT model assumes for a block that
/// authored no `(stackup …)` form. The single spelling of that default —
/// `placement/implicit_plane.zig` re-exports it, and every consumer that used
/// to restate "no stackup ⇒ 4" reads it from here.
pub const implicit_copper_layers: u8 = 4;
/// Stack index of the implicit GROUND plane (In1.Cu).
pub const implicit_ground_stack: u8 = 2;
/// Stack index of the implicit SUPPLY-RAIL plane (In2.Cu) — a second ground
/// plane when no rail qualifies.
pub const implicit_rail_stack: u8 = 3;

/// Canonical KiCad name of the top copper face.
pub const f_cu = "F.Cu";
/// Canonical KiCad name of the bottom copper face.
pub const b_cu = "B.Cu";

/// The `.kicad_pcb` spelling of the one `tech_specs` row with this role and
/// face. Comptime-only: it reads the same table `build` copies onto every
/// `LayerTable`, so the named constants below and the rows a fabrication
/// package emits are one table rather than two that can disagree.
fn techKicadName(comptime kind: Kind, comptime side: ?Side) []const u8 {
    return comptime for (tech_specs) |spec| {
        if (spec.kind == kind and spec.side == side) break spec.kicad;
    } else @compileError("board_layers: no technical layer row has that role and face");
}

/// Canonical KiCad name of the front solder-mask layer.
pub const f_mask = techKicadName(.mask, .front);
/// Canonical KiCad name of the back solder-mask layer.
pub const b_mask = techKicadName(.mask, .back);
/// Canonical KiCad name of the front solder-paste (stencil) layer.
pub const f_paste = techKicadName(.paste, .front);
/// Canonical KiCad name of the back solder-paste (stencil) layer.
pub const b_paste = techKicadName(.paste, .back);
/// Canonical KiCad FILE name of the front silkscreen — `F.SilkS`, not the
/// `F.Silkscreen` its UI shows (see `Row.kicadName`).
pub const f_silks = techKicadName(.silk, .front);
/// Canonical KiCad FILE name of the back silkscreen (see `f_silks`).
pub const b_silks = techKicadName(.silk, .back);
/// Canonical KiCad name of the board profile.
pub const edge_cuts = techKicadName(.edge, null);

/// KiCad layers netlisp reads or writes in board and footprint files but never
/// FABRICATES: no `tech_specs` row emits a Gerber for them, so they are named
/// here instead of in that table (adding a row there ships another file). They
/// are still one vocabulary with the layers above — a converted footprint's
/// courtyard, an imported board's user drawings and the `(layer …)` token an
/// exporter writes must all spell them the same way.
pub const f_crtyd = "F.CrtYd";
/// Back courtyard — the keep-clear outline (see `f_crtyd`).
pub const b_crtyd = "B.CrtYd";
/// Front fabrication drawing — assembly art KiCad's own libraries carry.
pub const f_fab = "F.Fab";
/// Back fabrication drawing (see `f_fab`).
pub const b_fab = "B.Fab";
/// Front adhesive — glue-dispense art a converted footprint may bring in.
pub const f_adhes = "F.Adhes";
/// Back adhesive (see `f_adhes`).
pub const b_adhes = "B.Adhes";
/// KiCad's generic user drawing layer.
pub const dwgs_user = "Dwgs.User";
/// KiCad's generic user comment layer.
pub const cmts_user = "Cmts.User";

/// The BACK-side twin of a FRONT-side layer name, or `name` unchanged when the
/// layer has no side at all (an inner copper layer, `*.Cu`, `Edge.Cuts`, a user
/// layer) — and unchanged for a back-side name, so the mapping is one-way and
/// idempotent-safe on already-flipped input.
///
/// Library footprints are authored front-side. Splicing one onto a part that
/// lives on the back must flip EVERY layer reference it carries or the part's
/// copper lands on the wrong face of the board, so the twin relation is a fact
/// about the layer model and is spelled here once.
pub fn backSideName(name: []const u8) []const u8 {
    const twins = [_][2][]const u8{
        .{ f_cu, b_cu },       .{ f_paste, b_paste }, .{ f_mask, b_mask },
        .{ f_silks, b_silks }, .{ f_fab, b_fab },     .{ f_crtyd, b_crtyd },
        .{ f_adhes, b_adhes },
    };
    for (twins) |t| {
        if (std.mem.eql(u8, name, t[0])) return t[1];
    }
    return name;
}

/// Bytes a caller must supply to hold any copper-layer name ("In31.Cu" is the
/// longest at `max_copper_layers`).
pub const name_buf_len: usize = 12;

/// The dense ROUTABLE layer index — what tracks, vias and layer masks carry.
/// Non-exhaustive: the count is a board property, not a compile-time set.
pub const SignalIndex = enum(u8) {
    top = 0,
    bottom = 1,
    _,

    /// Read a raw routable index (a track's `layer`, a sidecar `"l"`) as a
    /// `SignalIndex`.
    pub fn of(v: u8) SignalIndex {
        return @fromBackingInt(@intCast(v));
    }

    /// The raw index, for the `u8`-typed call surface and JSON output.
    pub fn int(self: SignalIndex) u8 {
        return @backingInt(self);
    }

    /// This index's bit position in a `LayerSet`, or null when it lies past
    /// the u64 mask's reach (`max_signal_layers`).
    pub fn bit(self: SignalIndex) ?u6 {
        const v = self.int();
        if (v >= max_signal_layers) return null;
        return @intCast(v);
    }
};

/// The 1-based PHYSICAL copper position, planes included.
pub const StackIndex = enum(u8) {
    /// F.Cu, on every board.
    front = 1,
    _,

    /// Read a raw 1-based copper position (a `(plane IDX …)` argument) as a
    /// `StackIndex`.
    pub fn of(v: u8) StackIndex {
        return @fromBackingInt(@intCast(v));
    }

    /// The raw 1-based position, for the `u8`-typed call surface and JSON.
    pub fn int(self: StackIndex) u8 {
        return @backingInt(self);
    }
};

/// What a layer is FOR. The copper roles plus the four technical roles the
/// fabrication package ships (`mask`, `paste`, `silk`, `edge`); `courtyard` /
/// `fab` / `doc` are the remaining KiCad-shaped roles, reserved for the
/// documentation layers no exporter generates yet.
pub const Kind = enum {
    /// Routable copper — the router may draw here.
    signal,
    /// Solid-pour copper claimed by a `(plane …)` or the implicit model.
    plane,
    silk,
    mask,
    paste,
    courtyard,
    fab,
    edge,
    doc,

    /// True for the two copper roles; false for every technical/user role.
    pub fn isCopper(self: Kind) bool {
        return self == .signal or self == .plane;
    }

    /// The Gerber `%TF.FilePolarity` a layer of this role is written with.
    /// SOLDER MASK is the one NEGATIVE role in the package — a flash there is
    /// an OPENING in the mask, not material — and this is the single place
    /// that rule is spelled, so a layer file's own attribute and the job
    /// file's `FilesAttributes` entry can never disagree about it.
    pub fn gerberPolarity(self: Kind) []const u8 {
        return if (self == .mask) "Negative" else "Positive";
    }
};

/// Which physical board FACE a layer belongs to. Null on a row that has none:
/// an inner copper layer, or the board profile.
pub const Side = enum { front, back };

/// A DECLARED `(plane IDX "NET")` entry: which 1-based copper stack index it
/// claims and the flattened net it pours. `optimizer.PlaneAt` is this type, so
/// a `BoardRules` plane slice needs no conversion to be read here.
pub const PlaneAt = struct { index: u8, net: []const u8 };

/// Canonical display colours for the outer copper faces, shared by every
/// render surface (viewer blob, page legend, PNG mirror these hexes) — KiCad
/// pcbnew's default F.Cu / B.Cu colours.
pub const signal_layer_colors = [_][]const u8{ "#C83434", "#4D7FC4" };
/// KiCad pcbnew's default In1..In4 colours, cycling for deeper stacks.
pub const inner_layer_colors = [_][]const u8{ "#C2C200", "#C200C2", "#C2C2C2", "#00C2C2" };

/// The display colour of a SIGNAL index — outer pair, then the inner palette
/// cycling from index 2.
pub fn signalColor(sig: SignalIndex) []const u8 {
    const v = sig.int();
    if (v < signal_layer_colors.len) return signal_layer_colors[v];
    return inner_layer_colors[(v - 2) % inner_layer_colors.len];
}

/// The display colour of a physical STACK position on a board of `count`
/// copper layers — the outer faces keep their own colours and every inner
/// position (plane or not) takes the inner palette by depth.
pub fn stackColor(stack: StackIndex, count: u8) []const u8 {
    const i = stack.int();
    if (i == 1) return signal_layer_colors[0];
    if (count > 1 and i == count) return signal_layer_colors[1];
    return inner_layer_colors[(i -| 2) % inner_layer_colors.len];
}

/// `In<k>.Cu` for inner stack index `stack` (In1 is stack index 2).
pub fn innerName(stack: StackIndex, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "In{d}.Cu", .{stack.int() - 1}) catch "In?.Cu";
}

/// Canonical KiCad name of a physical stack position on a board of `count`
/// copper layers. Out-of-range positions still get their arithmetic name
/// rather than an error — a `(plane 9 …)` on a 4-layer stack is reported as
/// `In8.Cu`, which is what it literally asked for.
pub fn stackName(stack: StackIndex, count: u8, buf: []u8) []const u8 {
    const i = stack.int();
    if (i == 1) return f_cu;
    if (count > 1 and i == count) return b_cu;
    return innerName(stack, buf);
}

/// Whether `name` is a copper spelling a KiCad import may carry verbatim
/// beyond a board's own routable rows: the both-faces `F&B.Cu`, the
/// every-copper `*.Cu`, and any `In<digits>.Cu` inner (an imported board may
/// name an inner this stackup does not route). Case-insensitive, as KiCad's
/// own readers are. The sidecar's zone validator accepts these so a
/// round-tripped board is never refused over a layer the editor itself would
/// not mint.
pub fn isImportedCopperName(name: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, "F&B.Cu") or std.ascii.eqlIgnoreCase(name, "*.Cu")) return true;
    if (!std.ascii.startsWithIgnoreCase(name, "In") or !std.ascii.endsWithIgnoreCase(name, ".Cu")) return false;
    const digits = name[2 .. name.len - 3];
    if (digits.len == 0) return false;
    for (digits) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

// spec: placement/optimizer - an imported copper spelling is recognized case-insensitively apart from the board's own rows
test "imported copper spellings are recognized without minting rows" {
    try std.testing.expect(isImportedCopperName("F&B.Cu"));
    try std.testing.expect(isImportedCopperName("*.Cu"));
    try std.testing.expect(isImportedCopperName("in3.cu"));
    try std.testing.expect(isImportedCopperName("In12.Cu"));
    // The board's own rows resolve through the table, never here — and a
    // malformed inner is a client bug, not an import spelling.
    try std.testing.expect(!isImportedCopperName("F.Cu"));
    try std.testing.expect(!isImportedCopperName("In.Cu"));
    try std.testing.expect(!isImportedCopperName("InX.Cu"));
    try std.testing.expect(!isImportedCopperName("Edge.Cuts"));
}

/// A short inline string. Every layer name and Gerber attribute value fits, so
/// a materialized `Row` OWNS its text and needs no allocator — a table can be
/// built in a request handler, a test, or a hot path alike.
pub const Text = struct {
    const cap = 24;

    bytes: [cap]u8 = @splat(0),
    len: u8 = 0,

    fn from(s: []const u8) Text {
        var t: Text = .{};
        const n = @min(s.len, cap);
        @memcpy(t.bytes[0..n], s[0..n]);
        t.len = @intCast(n);
        return t;
    }

    fn fmt(comptime spec: []const u8, args: anytype) Text {
        var t: Text = .{};
        const s = std.fmt.bufPrint(&t.bytes, spec, args) catch return from("?");
        t.len = @intCast(s.len);
        return t;
    }

    /// The stored bytes. Borrowed from the owning value, so keep the `Row`
    /// (or table) alive for as long as the slice is read.
    pub fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// How one copper layer identifies itself to a fab: the Gerber file-name
/// suffix and the X2 `%TF.FileFunction` attribute that names its role.
pub const GerberId = struct {
    /// File-name suffix appended to the design name ("In2_Cu.g3").
    suffix: Text = .{},
    /// X2 `.FileFunction` value ("Copper,L3,Inr").
    function: Text = .{},
};

/// How one layer NAMES and PRESENTS itself. The two spellings are separate
/// because they genuinely differ: KiCad's board files say `F.SilkS` where its
/// UI (and every human) says `F.Silkscreen`, and a package that mixes the two
/// writes a layer name no reader resolves.
pub const Naming = struct {
    /// The `.kicad_pcb` / `.kicad_sch` spelling (see `Row.kicadName`).
    kicad: Text = .{},
    /// The UI / display spelling (see `Row.name`).
    ui: Text = .{},
    /// Display hex, by stack position (see `stackColor`). COPPER ONLY — the
    /// technical rows are not drawn from the copper palette, so they carry "".
    color: []const u8 = "",
};

/// One fabrication layer: a physical copper layer (top-to-bottom, `stack` and
/// `signal` meaningful) or one of the fixed technical layers (`kind.isCopper()`
/// false, where `stack`/`signal`/colour carry nothing and `side` says which
/// face it belongs to).
pub const Row = struct {
    /// Its 1-based physical position. COPPER ONLY — a technical row leaves it
    /// at the default; read `kind`/`side` instead.
    stack: StackIndex = .front,
    /// The routable index tracks use for it, or null when a plane claims it —
    /// and always null on a technical row. An OUTER face that a `(pour …)`
    /// covers keeps its signal index — the router still draws there, the pour
    /// just costs more.
    signal: ?SignalIndex = null,
    /// What the layer is for.
    kind: Kind = .signal,
    /// Which board face this layer belongs to, or null when it has none (an
    /// inner copper layer, the board profile).
    side: ?Side = null,
    /// On a `.plane` row: the flattened net it pours, or null for the GROUND
    /// CLASS (the implicit model's ground plane carries every ground-named
    /// net, not one named one). Always null on a `.signal` row.
    plane_net: ?[]const u8 = null,
    /// What this layer is called and how it is drawn (see `Naming`).
    naming: Naming = .{},
    /// This layer's fabrication identity (see `GerberId`).
    gerber: GerberId = .{},

    /// Display name ("F.Cu" / "In2.Cu" / "F.Silkscreen").
    pub fn name(self: *const Row) []const u8 {
        return self.naming.ui.slice();
    }

    /// The spelling a `.kicad_pcb` / `.kicad_sch` uses — identical to `name`
    /// for copper, mask and paste, and `F.SilkS` / `B.SilkS` for silkscreen,
    /// whose file and UI spellings differ.
    pub fn kicadName(self: *const Row) []const u8 {
        return self.naming.kicad.slice();
    }

    /// Display hex of this layer's physical position (copper only).
    pub fn color(self: *const Row) []const u8 {
        return self.naming.color;
    }

    /// Gerber file-name suffix (KiCad naming + Protel extension).
    pub fn gerberSuffix(self: *const Row) []const u8 {
        return self.gerber.suffix.slice();
    }

    /// Gerber X2 `%TF.FileFunction` value.
    pub fn gerberFunction(self: *const Row) []const u8 {
        return self.gerber.function.slice();
    }

    /// Gerber X2 `%TF.FilePolarity` value (see `Kind.gerberPolarity`).
    pub fn gerberPolarity(self: *const Row) []const u8 {
        return self.kind.gerberPolarity();
    }

    /// Is this an outer copper face? Never true for a technical row, whose
    /// `stack` is not a board position at all.
    pub fn isOuter(self: *const Row, count: u8) bool {
        if (!self.kind.isCopper()) return false;
        const i = self.stack.int();
        return i == 1 or i == count;
    }
};

/// The primitive stackup facts every layer question is answered from — the
/// scalar view, allocation-free and cheap enough for a router inner loop.
/// Mirrors what `optimizer.BoardRules` already holds, so building one adds no
/// state anywhere.
pub const Stack = struct {
    /// The `(stackup N …)` count; 0 when the block authored no form.
    copper_layers: u8 = 0,
    /// DECLARED `(plane IDX "NET")` entries, in authored order.
    planes: []const PlaneAt = &.{},
    /// True when a `(stackup …)` form declared this board. False selects the
    /// LEGACY IMPLICIT model — the ONE discriminator, replacing the ad-hoc
    /// `plane_nets == null` tests that used to be restated per consumer.
    declared: bool = false,
    /// The implicit model's dominant supply rail (In2.Cu), when one qualified.
    implicit_rail: ?[]const u8 = null,

    /// The net a DECLARED plane pours at stack index `stack`, if any.
    pub fn declaredPlaneAt(self: Stack, stack: StackIndex) ?[]const u8 {
        for (self.planes) |pl| if (pl.index == stack.int()) return pl.net;
        return null;
    }

    /// How many PHYSICAL copper layers the board has: the implicit model's
    /// four when nothing was declared, else the authored count floored at the
    /// two faces every board has.
    pub fn stackCount(self: Stack) u8 {
        if (!self.declared) return implicit_copper_layers;
        return @min(@max(2, self.copper_layers), max_copper_layers);
    }

    /// How many ROUTABLE signal layers the board has: the two outer faces
    /// always, plus every inner layer no plane claimed. A block with no
    /// stackup form keeps exactly 2 (both inners are assumed planes), so
    /// existing boards and their persisted copper are unchanged.
    pub fn signalCount(self: Stack) u8 {
        if (self.copper_layers <= 2) return 2;
        var n: u8 = 2;
        var idx: u8 = 2;
        while (idx < self.copper_layers) : (idx += 1) {
            if (self.declaredPlaneAt(StackIndex.of(idx)) == null) n += 1;
        }
        return n;
    }

    /// The 1-based stack index signal layer `sig` lives on. Out-of-range
    /// indices fall back to the bottom copper (defensive; callers pass
    /// `sig < signalCount()`).
    pub fn signalStack(self: Stack, sig: SignalIndex) StackIndex {
        const s = sig.int();
        if (s == 0) return StackIndex.of(1);
        const bottom: u8 = if (self.copper_layers >= 2)
            self.copper_layers
        else if (self.copper_layers == 1) 1 else implicit_copper_layers;
        if (s == 1) return StackIndex.of(bottom);
        var seen: u8 = 2;
        var idx: u8 = 2;
        while (idx < self.copper_layers) : (idx += 1) {
            if (self.declaredPlaneAt(StackIndex.of(idx)) != null) continue;
            if (seen == s) return StackIndex.of(idx);
            seen += 1;
        }
        return StackIndex.of(bottom);
    }

    /// Canonical KiCad name of signal layer `sig`. Inner names render into
    /// `buf` (`name_buf_len` bytes suffice).
    pub fn signalName(self: Stack, sig: SignalIndex, buf: []u8) []const u8 {
        const s = sig.int();
        if (s == 0) return f_cu;
        if (s == 1) return b_cu;
        return innerName(self.signalStack(sig), buf);
    }

    /// The routable signal index of a KiCad copper-layer NAME — the
    /// authoritative inverse of `signalName`, so every consumer holding a
    /// zone/track layer string recovers the index tracks persist without
    /// restating the stackup arithmetic. Null for a name that routes nowhere:
    /// junk, or an inner layer a `(plane …)` claimed (it floods that layer, so
    /// a track there is a conflict). Case-insensitive, matching every
    /// name→index lookup across the router and import paths.
    pub fn signalIndexOfName(self: Stack, layer_name: []const u8) ?SignalIndex {
        var buf: [name_buf_len]u8 = undefined;
        const n = self.signalCount();
        var s: u8 = 0;
        while (s < n) : (s += 1) {
            const sig = SignalIndex.of(s);
            if (std.ascii.eqlIgnoreCase(self.signalName(sig, &buf), layer_name)) return sig;
        }
        return null;
    }

    /// Canonical KiCad name of a physical stack position on THIS board.
    pub fn nameOfStack(self: Stack, stack: StackIndex, buf: []u8) []const u8 {
        return stackName(stack, self.stackCount(), buf);
    }

    /// Materialize every copper layer, top-to-bottom.
    pub fn table(self: Stack) LayerTable {
        return build(self);
    }
};

/// Every fabrication layer of one board: the physical copper layers ordered
/// top→bottom, then the fixed technical layers in package-emission order.
pub const LayerTable = struct {
    /// Backing storage: `len` copper rows, then `tech_row_count` technical
    /// rows (see `rows` / `techRows` / `fabRows`).
    rows_buf: [max_copper_layers + tech_row_count]Row = @splat(.{}),
    /// How many COPPER rows of `rows_buf` this board fills.
    len: u8 = 0,
    /// The stackup facts the table was built from, kept so index arithmetic
    /// and the table can never disagree.
    stack: Stack = .{},

    /// The copper rows, top-to-bottom.
    pub fn rows(self: *const LayerTable) []const Row {
        return self.rows_buf[0..self.len];
    }

    /// The technical rows — mask, paste, silkscreen, board profile — in the
    /// order a fabrication package emits them. Fixed per board: they do not
    /// depend on the stackup.
    pub fn techRows(self: *const LayerTable) []const Row {
        return self.rows_buf[self.len..][0..tech_row_count];
    }

    /// EVERY layer a fabrication package ships, copper first then technical,
    /// in emission order — what the Gerber file plan walks.
    pub fn fabRows(self: *const LayerTable) []const Row {
        return self.rows_buf[0 .. @as(usize, self.len) + tech_row_count];
    }

    /// How many physical copper layers — always `rows().len`.
    pub fn stackCount(self: *const LayerTable) u8 {
        return self.len;
    }

    /// The row at 1-based stack index `stack`, or null when off the board.
    pub fn rowAtStack(self: *const LayerTable, stack: StackIndex) ?*const Row {
        const i = stack.int();
        if (i < 1 or i > self.len) return null;
        return &self.rows_buf[i - 1];
    }

    /// The row routable index `sig` draws on, or null when it names no layer.
    pub fn rowOfSignal(self: *const LayerTable, sig: SignalIndex) ?*const Row {
        for (self.rows()) |*row| {
            if (row.signal) |s| if (s == sig) return row;
        }
        return null;
    }

    /// Canonical KiCad name of a stack position, off-board indices included
    /// (see the free `stackName`).
    pub fn nameOfStack(self: *const LayerTable, stack: StackIndex, buf: []u8) []const u8 {
        return stackName(stack, self.len, buf);
    }
};

/// One technical layer's fixed identity. These do not depend on the stackup —
/// every board has exactly this set — so they are a comptime table `build`
/// copies verbatim onto the end of the copper rows.
const TechSpec = struct {
    kind: Kind,
    side: ?Side,
    /// The `.kicad_pcb` spelling.
    kicad: []const u8,
    /// The UI spelling (differs from `kicad` for silkscreen only).
    ui: []const u8,
    suffix: []const u8,
    function: []const u8,
};

/// The technical layers netlisp's fabrication package ships, in emission
/// order. Adding a row here adds a Gerber file to every package.
const tech_specs = [_]TechSpec{
    .{ .kind = .mask, .side = .front, .kicad = "F.Mask", .ui = "F.Mask", .suffix = "F_Mask.gts", .function = "Soldermask,Top" },
    .{ .kind = .mask, .side = .back, .kicad = "B.Mask", .ui = "B.Mask", .suffix = "B_Mask.gbs", .function = "Soldermask,Bot" },
    .{ .kind = .paste, .side = .front, .kicad = "F.Paste", .ui = "F.Paste", .suffix = "F_Paste.gtp", .function = "Paste,Top" },
    .{ .kind = .paste, .side = .back, .kicad = "B.Paste", .ui = "B.Paste", .suffix = "B_Paste.gbp", .function = "Paste,Bot" },
    .{ .kind = .silk, .side = .front, .kicad = "F.SilkS", .ui = "F.Silkscreen", .suffix = "F_Silkscreen.gto", .function = "Legend,Top" },
    .{ .kind = .silk, .side = .back, .kicad = "B.SilkS", .ui = "B.Silkscreen", .suffix = "B_Silkscreen.gbo", .function = "Legend,Bot" },
    .{ .kind = .edge, .side = null, .kicad = "Edge.Cuts", .ui = "Edge.Cuts", .suffix = "Edge_Cuts.gm1", .function = "Profile,NP" },
};

/// How many technical rows every table carries after its copper.
pub const tech_row_count: usize = tech_specs.len;

/// Build every fabrication row for `s` — copper top→bottom, then the fixed
/// technical set. Allocation-free: each row owns its strings.
pub fn build(s: Stack) LayerTable {
    var t: LayerTable = .{ .stack = s };
    t.len = s.stackCount();
    const count = t.len;
    var buf: [name_buf_len]u8 = undefined;
    var i: u8 = 1;
    while (i <= count) : (i += 1) {
        const stack = StackIndex.of(i);
        const carry = planeCarry(s, stack);
        const layer_name = Text.from(stackName(stack, count, &buf));
        t.rows_buf[i - 1] = .{
            .stack = stack,
            .signal = signalOfStack(s, stack),
            .kind = if (carry.is_plane) .plane else .signal,
            .side = copperSide(stack, count),
            .plane_net = carry.net,
            .naming = .{ .kicad = layer_name, .ui = layer_name, .color = stackColor(stack, count) },
            .gerber = .{
                .suffix = gerberSuffix(stack, count),
                .function = gerberFunction(stack, count),
            },
        };
    }
    for (tech_specs, 0..) |spec, k| {
        t.rows_buf[@as(usize, count) + k] = .{
            .kind = spec.kind,
            .side = spec.side,
            .naming = .{ .kicad = Text.from(spec.kicad), .ui = Text.from(spec.ui) },
            .gerber = .{ .suffix = Text.from(spec.suffix), .function = Text.from(spec.function) },
        };
    }
    return t;
}

/// The board face a physical copper position sits on, or null for an inner
/// layer (which faces nothing).
fn copperSide(stack: StackIndex, count: u8) ?Side {
    const i = stack.int();
    if (i == 1) return .front;
    if (count > 1 and i == count) return .back;
    return null;
}

/// What (if anything) pours solid on `stack`: a declared plane's net, or the
/// implicit model's inner ground / dominant-rail assignment.
fn planeCarry(s: Stack, stack: StackIndex) struct { is_plane: bool, net: ?[]const u8 } {
    if (s.declared) {
        if (s.declaredPlaneAt(stack)) |net| return .{ .is_plane = true, .net = net };
        return .{ .is_plane = false, .net = null };
    }
    return switch (stack.int()) {
        implicit_ground_stack => .{ .is_plane = true, .net = null },
        implicit_rail_stack => .{ .is_plane = true, .net = s.implicit_rail },
        else => .{ .is_plane = false, .net = null },
    };
}

/// The routable index that draws on `stack`, or null when none does. An outer
/// face keeps its index even under a declared pour.
fn signalOfStack(s: Stack, stack: StackIndex) ?SignalIndex {
    const n = s.signalCount();
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        const sig = SignalIndex.of(i);
        if (s.signalStack(sig) == stack) return sig;
    }
    return null;
}

/// Gerber file-name suffix for a physical position: KiCad's layer naming with
/// the Protel extension every CAM package auto-detects.
fn gerberSuffix(stack: StackIndex, count: u8) Text {
    const i = stack.int();
    if (i == 1) return Text.from("F_Cu.gtl");
    if (count > 1 and i == count) return Text.from("B_Cu.gbl");
    return Text.fmt("In{d}_Cu.g{d}", .{ i - 1, i });
}

/// Gerber X2 `%TF.FileFunction` value for a physical position. "Inr" is the
/// X2 spec's spelling for EVERY inner copper layer — a plane is not a distinct
/// file function, and the writer's older "Inner" for plane files was neither
/// in the spec nor readable by CAM as an inner copper layer.
fn gerberFunction(stack: StackIndex, count: u8) Text {
    const i = stack.int();
    if (i == 1) return Text.from("Copper,L1,Top");
    if (count > 1 and i == count) return Text.fmt("Copper,L{d},Bot", .{i});
    return Text.fmt("Copper,L{d},Inr", .{i});
}

/// What reading a saved layout's persisted layer indices back against THIS
/// board found. A `<design>.layouts.json` is user data: an index that no longer
/// names a routable layer (the stackup shrank, or the file was hand-edited) is
/// KEPT — deleting a user's copper over a stackup edit is never the right
/// answer — so the out-of-range entries are REPORTED instead, on stderr as the
/// layout loads and as a lint entry on `/api/pcb-describe`.
pub const LayerAudit = struct {
    /// The board's routable layer count the entries were judged against.
    signals: u8 = 0,
    /// How many entries named a layer at or past `signals`.
    over: usize = 0,
    /// The highest offending index seen, and the net that carried it — enough
    /// for a warning that names one concrete example rather than a bare count.
    worst: u8 = 0,
    net: []const u8 = "",

    /// Judge one persisted index. In-range entries are free (the common case
    /// on every board), so this is safe to call per track.
    pub fn note(self: *LayerAudit, layer: u8, net: []const u8) void {
        if (layer < self.signals) return;
        self.over += 1;
        if (self.over == 1 or layer > self.worst) {
            self.worst = layer;
            self.net = net;
        }
    }

    /// True when every entry named a layer this board actually has.
    pub fn clean(self: LayerAudit) bool {
        return self.over == 0;
    }
};

/// A set of routable layers as the router's u64 mask. An EMPTY set means
/// UNRESTRICTED — the historical `layerInMask` convention, kept exactly: a net
/// with no authored layer preference may use every layer.
pub const LayerSet = struct {
    bits: u64 = 0,

    /// The unrestricted set (every layer allowed).
    pub const unrestricted: LayerSet = .{};

    /// Read a stored route-policy mask word as a set.
    pub fn fromRaw(bits: u64) LayerSet {
        return .{ .bits = bits };
    }

    /// The mask word, for the policy structs that persist one.
    pub fn raw(self: LayerSet) u64 {
        return self.bits;
    }

    /// True when no layer was named, i.e. every layer is allowed.
    pub fn isUnrestricted(self: LayerSet) bool {
        return self.bits == 0;
    }

    /// True when `sig` belongs to the set. An unrestricted set contains every
    /// layer; a restricted set can never contain one past the mask's reach.
    pub fn contains(self: LayerSet, sig: SignalIndex) bool {
        if (self.isUnrestricted()) return true;
        const b = sig.bit() orelse return false;
        return (self.bits & (@as(u64, 1) << b)) != 0;
    }

    /// The set plus `sig` (a layer past the mask's reach is dropped).
    pub fn with(self: LayerSet, sig: SignalIndex) LayerSet {
        const b = sig.bit() orelse return self;
        return .{ .bits = self.bits | (@as(u64, 1) << b) };
    }
};

// spec: placement/optimizer - the shared layer table places the implicit model's four layers with ground and rail planes inside
test "an undeclared board builds the implicit four-layer table" {
    const s = Stack{ .implicit_rail = "V_3V3" };
    const t = s.table();
    try testing.expectEqual(@as(u8, 4), t.stackCount());
    try testing.expectEqual(@as(u8, 2), s.signalCount());

    const rows = t.rows();
    try testing.expectEqualStrings(f_cu, rows[0].name());
    try testing.expectEqualStrings("In1.Cu", rows[1].name());
    try testing.expectEqualStrings("In2.Cu", rows[2].name());
    try testing.expectEqualStrings(b_cu, rows[3].name());

    // The outer faces route; both inners are planes — ground, then the
    // dominant supply rail this block qualified.
    try testing.expectEqual(SignalIndex.top, rows[0].signal.?);
    try testing.expectEqual(SignalIndex.bottom, rows[3].signal.?);
    try testing.expect(rows[1].signal == null);
    try testing.expect(rows[2].signal == null);
    try testing.expectEqual(Kind.plane, rows[1].kind);
    try testing.expect(rows[1].plane_net == null); // ground CLASS, not one net
    try testing.expectEqualStrings("V_3V3", rows[2].plane_net.?);

    // No rail qualified ⇒ two ground planes, the pre-rail model unchanged.
    const legacy = Stack{};
    try testing.expect(legacy.table().rows()[2].plane_net == null);
}

// spec: placement/optimizer - a declared stackup's routable indices skip its plane-claimed inner layers
test "a six-layer declared stackup numbers signals around its planes" {
    const planes = [_]PlaneAt{ .{ .index = 2, .net = "GND" }, .{ .index = 5, .net = "V_3V3" } };
    const s = Stack{ .copper_layers = 6, .declared = true, .planes = &planes };
    const t = s.table();
    try testing.expectEqual(@as(u8, 6), t.stackCount());
    // F.Cu, B.Cu and the two plane-free inners (stack 3 and 4).
    try testing.expectEqual(@as(u8, 4), s.signalCount());

    var buf: [name_buf_len]u8 = undefined;
    try testing.expectEqualStrings("F.Cu", s.signalName(SignalIndex.of(0), &buf));
    try testing.expectEqualStrings("B.Cu", s.signalName(SignalIndex.of(1), &buf));
    try testing.expectEqualStrings("In2.Cu", s.signalName(SignalIndex.of(2), &buf));
    try testing.expectEqualStrings("In3.Cu", s.signalName(SignalIndex.of(3), &buf));
    try testing.expectEqual(@as(u8, 3), s.signalStack(SignalIndex.of(2)).int());
    try testing.expectEqual(@as(u8, 6), s.signalStack(SignalIndex.of(1)).int());

    // Every row's own view agrees with the scalar arithmetic.
    try testing.expectEqual(Kind.plane, t.rowAtStack(StackIndex.of(5)).?.kind);
    try testing.expectEqualStrings("V_3V3", t.rowAtStack(StackIndex.of(5)).?.plane_net.?);
    try testing.expect(t.rowAtStack(StackIndex.of(5)).?.signal == null);
    try testing.expectEqualStrings("In3.Cu", t.rowOfSignal(SignalIndex.of(3)).?.name());
    try testing.expect(t.rowAtStack(StackIndex.of(7)) == null);
}

/// Every routable index of `s` names a layer that resolves back to it.
fn expectNamesRoundTrip(s: Stack) !void {
    var buf: [name_buf_len]u8 = undefined;
    var sig: u8 = 0;
    while (sig < s.signalCount()) : (sig += 1) {
        const name = s.signalName(SignalIndex.of(sig), &buf);
        try testing.expectEqual(SignalIndex.of(sig), s.signalIndexOfName(name).?);
    }
}

// spec: placement/optimizer - a copper-layer name resolves case-insensitively to its routable index and plane-claimed inners resolve to none
test "layer names round-trip through the shared table" {
    const planes = [_]PlaneAt{ .{ .index = 2, .net = "GND" }, .{ .index = 5, .net = "V_3V3" } };
    const s = Stack{ .copper_layers = 6, .declared = true, .planes = &planes };

    try expectNamesRoundTrip(s);
    try testing.expectEqual(SignalIndex.of(2), s.signalIndexOfName("in2.cu").?);
    // Plane-claimed inners and junk name no routable layer.
    try testing.expect(s.signalIndexOfName("In1.Cu") == null);
    try testing.expect(s.signalIndexOfName("In4.Cu") == null);
    try testing.expect(s.signalIndexOfName("Edge.Cuts") == null);

    // A plain two-layer board resolves only the outer pair.
    const two = Stack{ .copper_layers = 2, .declared = true };
    try testing.expectEqual(SignalIndex.top, two.signalIndexOfName("F.Cu").?);
    try testing.expect(two.signalIndexOfName("In1.Cu") == null);
}

// spec: placement/optimizer - the layer table spells each copper layer's Gerber suffix and X2 file function, giving every inner layer the spec's Inr regardless of any plane on it
test "the layer table carries each row's Gerber identity" {
    const implicit = (Stack{}).table();
    try testing.expectEqualStrings("F_Cu.gtl", implicit.rows()[0].gerberSuffix());
    try testing.expectEqualStrings("Copper,L1,Top", implicit.rows()[0].gerberFunction());
    try testing.expectEqualStrings("In1_Cu.g2", implicit.rows()[1].gerberSuffix());
    try testing.expectEqualStrings("Copper,L2,Inr", implicit.rows()[1].gerberFunction());
    try testing.expectEqualStrings("In2_Cu.g3", implicit.rows()[2].gerberSuffix());
    try testing.expectEqualStrings("B_Cu.gbl", implicit.rows()[3].gerberSuffix());
    try testing.expectEqualStrings("Copper,L4,Bot", implicit.rows()[3].gerberFunction());

    // EVERY inner copper layer is the X2 spec's "Inr" — a plane is not a
    // distinct file function, so a declared plane reads exactly like the
    // plane-free inner beside it.
    const planes = [_]PlaneAt{.{ .index = 2, .net = "GND" }};
    const four = (Stack{ .copper_layers = 4, .declared = true, .planes = &planes }).table();
    try testing.expectEqual(Kind.plane, four.rows()[1].kind);
    try testing.expectEqualStrings("Copper,L2,Inr", four.rows()[1].gerberFunction());
    try testing.expectEqualStrings("Copper,L3,Inr", four.rows()[2].gerberFunction());
    try testing.expect(std.mem.indexOf(u8, four.rows()[1].gerberFunction(), "Inner") == null);
    try testing.expectEqualStrings("In2_Cu.g3", four.rows()[2].gerberSuffix());

    const two = (Stack{ .copper_layers = 2, .declared = true }).table();
    try testing.expectEqual(@as(u8, 2), two.stackCount());
    try testing.expectEqualStrings("Copper,L2,Bot", two.rows()[1].gerberFunction());
}

// spec: placement/optimizer - the layer table carries the fixed technical rows (mask, paste, silkscreen, profile) after its copper, with their KiCad, UI and Gerber spellings
test "the layer table carries the technical fabrication rows" {
    const two = (Stack{ .copper_layers = 2, .declared = true }).table();
    // Copper is unchanged; the technical set follows it in emission order.
    try testing.expectEqual(@as(u8, 2), two.stackCount());
    try testing.expectEqual(@as(usize, 2), two.rows().len);
    try testing.expectEqual(tech_row_count, two.techRows().len);
    try testing.expectEqual(@as(usize, 2 + tech_row_count), two.fabRows().len);
    // …and a six-layer board's technical rows are the SAME rows, just further
    // along: they do not depend on the stackup.
    const six = (Stack{ .copper_layers = 6, .declared = true }).table();
    try testing.expectEqual(@as(usize, 6 + tech_row_count), six.fabRows().len);

    const tech = two.techRows();
    const want_suffix = [_][]const u8{
        "F_Mask.gts",       "B_Mask.gbs",       "F_Paste.gtp",   "B_Paste.gbp",
        "F_Silkscreen.gto", "B_Silkscreen.gbo", "Edge_Cuts.gm1",
    };
    const want_function = [_][]const u8{
        "Soldermask,Top", "Soldermask,Bot", "Paste,Top",  "Paste,Bot",
        "Legend,Top",     "Legend,Bot",     "Profile,NP",
    };
    for (tech, want_suffix, want_function) |*row, suffix, function| {
        try testing.expect(!row.kind.isCopper());
        try testing.expect(row.signal == null);
        try testing.expect(!row.isOuter(2)); // a technical row is never an outer FACE
        try testing.expectEqualStrings(suffix, row.gerberSuffix());
        try testing.expectEqualStrings(function, row.gerberFunction());
    }

    // Silkscreen is the one layer whose file and UI spellings differ.
    try testing.expectEqualStrings("F.SilkS", tech[4].kicadName());
    try testing.expectEqualStrings("F.Silkscreen", tech[4].name());
    try testing.expectEqualStrings("F.Mask", tech[0].kicadName());
    try testing.expectEqualStrings("F.Mask", tech[0].name());
    try testing.expectEqual(Side.front, tech[0].side.?);
    try testing.expectEqual(Side.back, tech[1].side.?);
    try testing.expect(tech[6].side == null); // the profile faces neither side

    // Copper keeps one spelling for both, and its faces are named.
    try testing.expectEqualStrings("F.Cu", two.rows()[0].name());
    try testing.expectEqualStrings("F.Cu", two.rows()[0].kicadName());
    try testing.expectEqual(Side.front, two.rows()[0].side.?);
    try testing.expectEqual(Side.back, two.rows()[1].side.?);
    try testing.expect(six.rows()[2].side == null); // an inner layer faces neither

    // Solder mask is the package's only NEGATIVE polarity, and the rule is
    // spelled once for every consumer of it.
    try testing.expectEqualStrings("Negative", tech[0].gerberPolarity());
    try testing.expectEqualStrings("Negative", tech[1].gerberPolarity());
    try testing.expectEqualStrings("Positive", tech[2].gerberPolarity());
    try testing.expectEqualStrings("Positive", tech[6].gerberPolarity());
    try testing.expectEqualStrings("Positive", two.rows()[0].gerberPolarity());
}

// spec: placement/optimizer - each named layer constant is the exact KiCad spelling the materialized table gives that role and face
test "the named layer constants are the spellings the table itself carries" {
    const t = (Stack{ .copper_layers = 2, .declared = true }).table();
    try testing.expectEqualStrings("F.Cu", t.rows()[0].kicadName());
    try testing.expectEqualStrings("B.Cu", t.rows()[1].kicadName());
    try testing.expectEqualStrings(t.rows()[0].kicadName(), f_cu);
    try testing.expectEqualStrings(t.rows()[1].kicadName(), b_cu);

    // A fabricated constant must find its own row (a table reorder or renamed
    // row cannot leave it pointing at nothing); a DOCUMENT constant must find
    // none, because no Gerber ships for it.
    const Expect = struct { name: []const u8, fabricated: bool };
    const cases = [_]Expect{
        .{ .name = f_mask, .fabricated = true },     .{ .name = b_mask, .fabricated = true },
        .{ .name = f_paste, .fabricated = true },    .{ .name = b_paste, .fabricated = true },
        .{ .name = f_silks, .fabricated = true },    .{ .name = b_silks, .fabricated = true },
        .{ .name = edge_cuts, .fabricated = true },  .{ .name = f_crtyd, .fabricated = false },
        .{ .name = b_crtyd, .fabricated = false },   .{ .name = f_fab, .fabricated = false },
        .{ .name = b_fab, .fabricated = false },     .{ .name = f_adhes, .fabricated = false },
        .{ .name = b_adhes, .fabricated = false },   .{ .name = dwgs_user, .fabricated = false },
        .{ .name = cmts_user, .fabricated = false },
    };
    for (cases) |c| {
        try testing.expectEqual(c.fabricated, rowNamed(&t, c.name) != null);
    }

    // The FILE spelling of silkscreen is not the UI spelling beside it.
    try testing.expectEqualStrings("F.SilkS", f_silks);
    try testing.expectEqualStrings("F.Silkscreen", rowNamed(&t, f_silks).?.name());
    try testing.expectEqualStrings("Edge.Cuts", edge_cuts);
    try testing.expectEqualStrings("F.CrtYd", f_crtyd);
    try testing.expectEqualStrings("Dwgs.User", dwgs_user);
}

/// The fabrication row `t` spells `kicad_name`, or null when the table ships
/// none — test support for the named-constant check above.
fn rowNamed(t: *const LayerTable, kicad_name: []const u8) ?*const Row {
    for (t.fabRows()) |*row| {
        if (std.mem.eql(u8, row.kicadName(), kicad_name)) return row;
    }
    return null;
}

// spec: placement/optimizer - a front-side layer name flips to its back-side twin while a sideless or already-back name passes through unchanged
test "a front-side layer name flips to its back twin and a sideless one does not" {
    const cases = [_][2][]const u8{
        // Every front-side layer a library footprint can carry has a twin.
        .{ "F.Cu", "B.Cu" },           .{ "F.Paste", "B.Paste" },
        .{ "F.Mask", "B.Mask" },       .{ "F.SilkS", "B.SilkS" },
        .{ "F.Fab", "B.Fab" },         .{ "F.CrtYd", "B.CrtYd" },
        .{ "F.Adhes", "B.Adhes" },
        // Sideless layers, inner copper and already-back names pass through —
        // flipping one would move a board profile or double-flip a back part.
            .{ "Edge.Cuts", "Edge.Cuts" },
        .{ "*.Cu", "*.Cu" },           .{ "In2.Cu", "In2.Cu" },
        .{ "Dwgs.User", "Dwgs.User" }, .{ "B.Cu", "B.Cu" },
        .{ "B.SilkS", "B.SilkS" },
    };
    for (cases) |c| {
        try testing.expectEqualStrings(c[1], backSideName(c[0]));
    }
}

// spec: placement/optimizer - a stack row takes the KiCad palette colour of its physical position and an outer pour keeps its routable index
test "layer rows carry position colours and poured outer faces stay routable" {
    const planes = [_]PlaneAt{
        .{ .index = 1, .net = "GND" },
        .{ .index = 2, .net = "GND" },
        .{ .index = 4, .net = "GND" },
    };
    const t = (Stack{ .copper_layers = 4, .declared = true, .planes = &planes }).table();
    try testing.expectEqualStrings("#C83434", t.rows()[0].color());
    try testing.expectEqualStrings("#C2C200", t.rows()[1].color());
    try testing.expectEqualStrings("#C200C2", t.rows()[2].color());
    try testing.expectEqualStrings("#4D7FC4", t.rows()[3].color());

    // `(pour top)` / `(pour bottom)` claim the outer faces, but the router
    // still draws there — the pour only costs more.
    try testing.expectEqual(Kind.plane, t.rows()[0].kind);
    try testing.expectEqual(SignalIndex.top, t.rows()[0].signal.?);
    try testing.expectEqual(SignalIndex.bottom, t.rows()[3].signal.?);
    // The one plane-free inner is signal index 2, on stack 3.
    try testing.expectEqual(SignalIndex.of(2), t.rows()[2].signal.?);
}

// spec: placement/optimizer - an empty routable-layer set allows every layer while a named one allows only its members
test "a layer set with no bits is unrestricted" {
    try testing.expect(LayerSet.unrestricted.isUnrestricted());
    try testing.expect(LayerSet.unrestricted.contains(SignalIndex.of(0)));
    try testing.expect(LayerSet.unrestricted.contains(SignalIndex.of(63)));
    try testing.expect(LayerSet.unrestricted.contains(SignalIndex.of(200)));

    const only_bottom = LayerSet.unrestricted.with(SignalIndex.bottom);
    try testing.expect(!only_bottom.isUnrestricted());
    try testing.expect(only_bottom.contains(SignalIndex.bottom));
    try testing.expect(!only_bottom.contains(SignalIndex.top));
    // Past the u64 mask's reach a restricted set can hold nothing.
    try testing.expect(!only_bottom.contains(SignalIndex.of(max_signal_layers)));
    try testing.expectEqual(only_bottom, only_bottom.with(SignalIndex.of(max_signal_layers)));
}
