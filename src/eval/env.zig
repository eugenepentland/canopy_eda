const std = @import("std");
const ast = @import("../sexpr/ast.zig");

// ── Constants ─────────────────────────────────────────────────────
const PULLUP_RANGE_MIN_CHILDREN: usize = 5;
const DECOUPLING_PER_PIN_MIN_CHILDREN: usize = 5;
const SERIES_ELEMENT_MIN_CHILDREN: usize = 6;
const SERIES_ELEMENT_MAX_INDEX: usize = 5;

/// A value in the evaluator.
pub const Value = union(enum) {
    number: f64,
    string: []const u8,
    boolean: bool,
    /// Reference to a component definition (name)
    component: []const u8,
    /// Reference to a component-family instantiation (family_name, value_string, attrs)
    component_instance: struct {
        family: []const u8,
        value: []const u8,
        /// Schematic-level attributes (e.g., "np0", "x7r" for dielectric type)
        attrs: []const []const u8 = &.{},
    },
    /// A module definition (name, params, body nodes)
    module: ModuleDef,
    /// A design block result
    design_block: *DesignBlock,
    /// Nil / void
    nil,

    pub fn asNumber(self: Value) ?f64 {
        return switch (self) {
            .number => |n| n,
            else => null,
        };
    }

    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn asBool(self: Value) ?bool {
        return switch (self) {
            .boolean => |b| b,
            else => null,
        };
    }

    pub fn isTruthy(self: Value) bool {
        return switch (self) {
            .boolean => |b| b,
            .nil => false,
            .number => |n| n != 0.0,
            else => true,
        };
    }
};

/// A `(defmodule …)` definition: the parameter list, body AST nodes, and the
/// module file's lexical scope so calls bind parameters into a child env that
/// still resolves imports the module declared.
pub const ModuleDef = struct {
    name: []const u8,
    params: []const []const u8,
    body: []const ast.Node,
    /// Import scope from the module file
    imports: *Env,
};

/// A pin reference in a net.
pub const PinRef = struct {
    ref_des: []const u8,
    pin: []const u8,
    /// Alternate functions the user explicitly asserted via `(as "FN1" "FN2" ...)`. Empty slice
    /// when none were asserted. Multiple entries let a single pin declare it's being used in
    /// more than one role — e.g. `(as "TIM1_CH1" "GPIO")` for a pin that's both bit-banged and
    /// driven by a timer depending on firmware phase.
    asserted_fns: []const []const u8 = &.{},
    /// Typical current drawn by this instance on the owning pin-group's net (A).
    /// Populated from `(i-typ X)` on the pin form and attached only to the first
    /// physical pin of the group — the remaining pins carry null so a straight sum
    /// across a net counts each instance's contribution exactly once.
    i_typ: ?f64 = null,
    /// Absolute-max current drawn by this instance on the owning pin-group's net (A).
    /// Populated from `(i-max X)`; same single-pin attachment semantics as i_typ.
    i_max: ?f64 = null,
};

/// A net in a design block.
pub const Net = struct {
    name: []const u8,
    pins: []const PinRef,
};

/// A port definition.
pub const Port = struct {
    name: []const u8,
    net: []const u8,
    direction: []const u8,
    rated_min: ?f64 = null,
    rated_max: ?f64 = null,
    nominal: ?f64 = null,
    /// Typical current capacity (A) — set from `(current <typ> <max>)` on a port.
    /// On a regulator output this is the typical deliverable current; on a
    /// consumer input it's the expected draw under nominal conditions.
    current_typ: ?f64 = null,
    /// Absolute-max current capacity (A) from `(current <typ> <max>)`.
    current_max: ?f64 = null,
    /// Power-conversion efficiency (0.0–1.0) from `(efficiency <ratio>)` on an
    /// output port. Used by the power-budget analyzer to back-compute input
    /// current draw (`Iin = Iout × Vout/Vin / η`) so VBATT and other upstream
    /// rails include the regulators that tap them.
    efficiency: ?f64 = null,
    /// `(efficiency linear)` was declared. Meaningful only on output ports of
    /// linear regulators (LDOs): η is computed as `Vout/Vin` at analysis
    /// time, which reduces to `Iin ≈ Iout` regardless of the input rail.
    efficiency_linear: bool = false,
    /// Name of the net/port that enables this rail. Populated from
    /// `(enable "NET")` on an output port. Drives the review's power-sequencing
    /// table so debuggers can see "VOUT comes up after PG_3V3 asserts."
    enable_net: []const u8 = "",
    /// Whether this port is optional (no ERC error if unconnected).
    optional: bool = false,
    /// Optional electrical character carried by this port — declared via an
    /// `(electrical (type ...) (v-oh-typ ...) ...)` sub-clause on a top-level
    /// `(port …)`. Used by `checkVoltageDomainCompat` as a virtual
    /// driver/receiver on the port's net so cross-board interface contracts
    /// (e.g. "this mezzanine pin is 3.3 V CMOS") show up in ERC even when the
    /// far-side device lives in a different design.
    electrical: ?ElectricalDecl = null,
};

/// A note annotation.
pub const Note = struct {
    ref_des: []const u8,
    text: []const u8,
};

/// Reference to a page in an uploaded datasheet PDF. Used by both section
/// notes (design-specific commentary on a section) and component requirements
/// (library-level rules for using a part).
pub const NoteRef = struct {
    /// Filename in `lib/datasheets/` (e.g. `"stm32n657-rev4.pdf"`).
    pdf: []const u8,
    /// 1-based page index. 0 means "link to the PDF without a specific page".
    page: u32 = 0,
    /// Verbatim datasheet text the rule was sourced from. When present, the
    /// `/pdf-view/` viewer auto-highlights this string on load — so a click
    /// from a requirement lands on the cited page with the source paragraph
    /// visibly marked. Keep short and distinctive (one line on the PDF) so
    /// the per-span match in the viewer reliably finds it.
    quote: ?[]const u8 = null,
};

/// A design-specific note attached to a section. Stored inline in the design's
/// `.sexp` via `(note "text" (ref "file.pdf" (page N)))`.
pub const SectionNote = struct {
    text: []const u8,
    ref: ?NoteRef = null,
};

/// A design-side sign-off that explicitly answers a library `(requirement ...)`.
/// Stored at top level inside `(design-block ...)` via:
///   `(verifies (req "<ref-des>" <req-id>) "rationale prose")`
/// or the long form with optional `(rationale ...)`, `(signed-off-by ...)`,
/// `(date ...)` sub-forms.
///
/// Use cases: requirements the netlist alone can't answer (firmware
/// sequencing, layout proximity, BOM matching across channels). The review
/// pairs each verifies entry with its target `(ref_des, req_id)` so the UI
/// shows "machine check failed/n.a. → human signed off with prose".
///
/// Override semantics: when a target requirement also has a `(check ...)`
/// that *fails*, the verifies entry does NOT flip the status to `verified`.
/// The review marks the requirement as fail-with-override so a real defect
/// can never be silently buried by prose. When the requirement has no check
/// (or the check is `na`), a matching verifies flips the status to
/// `verified`.
pub const Verification = struct {
    /// Reference designator of the target instance (e.g. "U1", "U_VREF").
    /// Empty when the sign-off targets a part by stable id instead (see
    /// `target_id`). Exactly one of `ref_des` / `target_id` is non-empty.
    ref_des: []const u8 = "",
    /// Stable 8-char instance id (the `(id <hex>)` token) of the target part.
    /// When non-empty, `applyVerifications` matches on `Instance.id` instead
    /// of `Instance.ref_des`, so the sign-off survives ref-des renumbering and
    /// sub-block renames. Set by the `(verifies (req (id <hex>) …) …)` form.
    target_id: []const u8 = "",
    /// Requirement ID — either explicit `(id …)` from the component file or
    /// the CRC32-derived fallback. Matched against `Requirement.id`.
    req_id: []const u8,
    /// Free-text justification for the sign-off.
    rationale: []const u8,
    /// Optional signer (email or handle).
    signed_by: []const u8 = "",
    /// Optional ISO-8601 date.
    date: []const u8 = "",
};

/// One critical IC declared up front in the design document, before (or
/// independent of) being placed as an `(instance …)`. Stored at design-block
/// top level via:
///   `(design-doc (critical-ic <component> (role "…") (rationale "…") (mpn "…")) …)`
///
/// The `component` field is the intended `lib/components/<name>.sexp` basename
/// — the same key an `(instance …)` references — so the traceability join can
/// match a declaration to its placement by component name. A declared IC need
/// not exist in the library yet: every lifecycle stage simply reads "unmet"
/// until the part is imported, given requirements, and placed.
pub const CriticalIc = struct {
    /// Library component basename (and `(instance …)` component reference).
    component: []const u8,
    /// Short functional role, e.g. "Main MCU", "RF transmitter".
    role: []const u8 = "",
    /// Why this part was chosen — design rationale prose.
    rationale: []const u8 = "",
    /// Manufacturer part number, used as a fallback datasheet-match key.
    mpn: []const u8 = "",
};

/// A named virtual pin on a placeholder `(stub …)`. A stub declares its
/// interface by *signal* (a logical name on a net) rather than by physical
/// pin number — the placeholder has no real pinout yet. `class` is a diagram
/// wire-class key (e.g. "i2c", "power", "clock"); `net` is the net the signal
/// sits on, so two parts naming the same net get a diagram edge.
pub const PartSignal = struct {
    name: []const u8,
    class: []const u8 = "",
    net: []const u8,
};

/// A placeholder component declared up front with `(stub "name" …)`, before a
/// real library component exists. It auto-places (gets a ref-des + stable id,
/// no `(instance …)` line), renders as a categorised diagram node wired by its
/// signals, and exports to KiCad as a pad-less bounding-box footprint sized
/// `width`×`height` mm for floor-planning. A real `(import "name")` of the same
/// key later supersedes it — promotion to a fully specified part.
pub const PlaceholderPart = struct {
    /// Auto-assigned (or `(ref …)`-overridden) reference designator, e.g. "U1".
    ref_des: []const u8,
    /// The declared key — the same name a later `(instance …)`/`(import …)` uses.
    name: []const u8,
    /// Short functional role, e.g. "Host MCU". Empty when undeclared.
    role: []const u8 = "",
    /// Manufacturer part number for the BOM + datasheet match. Empty when undeclared.
    mpn: []const u8 = "",
    /// Diagram category key (mcu/power/memory/clock/comms/sensor/analog/
    /// protection/connector). Empty ⇒ classifier falls back to name heuristics.
    category: []const u8 = "",
    /// Bounding-box width in mm for the KiCad placeholder footprint. 0 ⇒ unset.
    width: f64 = 0,
    /// Bounding-box height in mm. 0 ⇒ unset.
    height: f64 = 0,
    /// Stable 8-char id, auto-inserted into source on first build. Survives
    /// promotion so the KiCad footprint identity (uuidFromId) is preserved.
    id: []const u8 = "",
    /// Named virtual pins wired to nets — the part's diagram interface.
    signals: []const PartSignal = &.{},
};

/// A library-level rule for using a component correctly. Stored in the
/// component's `lib/components/<name>.sexp` via
/// `(requirement "text" (ref "file.pdf" (page N)))`. Used to validate that
/// designs using the part follow the datasheet's requirements. An optional
/// `(check ...)` clause turns the requirement into a build-time assertion —
/// the check engine walks the design and marks the requirement pass/fail
/// instead of leaving it reviewer-judged.
pub const Requirement = struct {
    text: []const u8,
    ref: ?NoteRef = null,
    check: ?Check = null,
    /// 8-char hex ID. When the source declares `(id <hex>)` inside the
    /// `(requirement ...)` form, that wins. Otherwise this field is the
    /// CRC32 of `text` formatted as 8 lowercase hex digits — derived at
    /// parse time so every requirement is addressable from a `(verifies ...)`
    /// form without a prior freeze. Editing the requirement text without
    /// freezing first will break links, so we recommend running
    /// `eda freeze-requirement-ids` once a design starts using verifies.
    id: []const u8 = "",
};

/// Compute the auto-derived 8-char hex requirement ID from the requirement
/// text. Returned slice is owned by the caller (allocated via `allocator`).
pub fn requirementIdForText(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]const u8 {
    var hasher = std.hash.Crc32.init();
    hasher.update(text);
    const h = hasher.final();
    return std.fmt.allocPrint(allocator, "{x:0>8}", .{h});
}

/// Tagged union of automated-check primitives that can hang off a
/// Requirement. Each variant names a pattern the check engine knows how
/// to match against a live design, keyed to one placement of the part.
///
/// Pin references use the *function* name declared in `lib/pinouts/*.sexp`
/// (e.g. "VDD", "EP") — not a physical pin ID — because the same physical
/// pin can carry different nets depending on how a design wires it.
pub const Check = union(enum) {
    /// `(connected (pin "A") (pin "B"))` — both pins of this instance must
    /// resolve to the same net. Catches missed tie-together of EP↔VSS,
    /// VDD-domain shorts, etc.
    connected: struct { pin_a: []const u8, pin_b: []const u8 },
    /// `(decoupling (pin "A") (pin "B") (min-uf F))` — at least one
    /// capacitor, of value ≥ F µF, must bridge the nets carrying pin A and
    /// pin B on this instance. Implements the canonical bypass-cap rule
    /// ("VDD needs ≥4.7µF to VSS").
    decoupling: struct { pin_a: []const u8, pin_b: []const u8, min_uf: f64 },
    /// `(pullup-range (pin "P") (net "N") (min-ohms L) (max-ohms H))` — a
    /// resistor must bridge the net seen on pin P and the named net N, with
    /// value in the given range. Covers PROG-style "charge-current set
    /// resistor must be 2k–67k" checks.
    pullup_range: struct { pin: []const u8, target_net: []const u8, min_ohms: f64, max_ohms: f64 },
    /// `(voltage-range (pin "V") (min L) (max H))` — the port declared on
    /// the net wired to pin V must fall inside the range L..H. Covers
    /// "VDD input supply must be 3.75–6V" style envelope checks against
    /// the design's declared rails.
    voltage_range: struct { pin: []const u8, min_v: f64, max_v: f64 },
    /// `(tied-to-net (pin "P") (net "N"))` — pin P must resolve to net N
    /// (alias-aware). Covers "PDR_ON must be tied to VDDA18_AON" style
    /// fixed-net rules where the part datasheet calls out a specific rail.
    tied_to_net: struct { pin: []const u8, target_net: []const u8 },
    /// `(not-connected (pin "P"))` — pin P must NOT be wired to anything.
    /// Used for DNC pins that the datasheet says must float. Looks at raw
    /// `block.nets`, not the alias-folded view, so a per-pin stub with no
    /// foreign pins counts as disconnected.
    not_connected: struct { pin: []const u8 },
    /// `(pin-not-floating (pin "P"))` — pin P must resolve to a non-empty
    /// net with at least one other co-pin. Inverse of `not-connected`;
    /// catches BOOT0-style "must be tied to a defined logic level" rules.
    pin_not_floating: struct { pin: []const u8 },
    /// `(pins-on-same-net (pins "A" "B" "C" ...))` — every listed pin
    /// function on this instance must resolve to the same (alias-equal)
    /// net. Generalises `connected` to N pins; covers "all VSSSMPS pins
    /// must be tied externally to VSS" type rules.
    pins_on_same_net: struct { pins: []const []const u8 },
    /// `(decoupling-per-pin (return-pin "GND") (pins "VDD_1" "VDD_2") (min-uf F) (count N))`
    /// — for each VDD pin, find at least one cap of value ≥ F µF whose
    /// terminals are on (that-pin's net, return-pin's net). Total distinct
    /// caps satisfying the rule must be ≥ N. Implements "one 100 nF MLCC
    /// per VDD pin" rules where the existing `decoupling` primitive's
    /// "≥1 cap total" semantics are too lax.
    decoupling_per_pin: struct {
        return_pin: []const u8,
        pins: []const []const u8,
        min_uf: f64,
        count: u32,
    },
    /// `(series-element (kind R|L|C) (pin "P") (target-net "N") (min X) (max Y))` —
    /// a resistor / inductor / capacitor of value in [min, max] must bridge
    /// the net resolved on pin P and the named net. Generalisation of
    /// `pullup-range`; min/max units are ohms/µH/µF chosen by `kind`.
    series_element: struct {
        kind: SeriesKind,
        pin: []const u8,
        target_net: []const u8,
        min: f64,
        max: f64,
    },
};

/// Element kind for `series-element` checks. Determines which ref-des prefix
/// (R/L/C) the check engine filters by, and which value-parser to use.
pub const SeriesKind = enum { R, L, C };

/// Parse `(check (<primitive> ...))` nested inside a `(requirement ...)`
/// body. Returns null if the form isn't a recognized check.
pub fn parseCheck(node: ast.Node) ?Check {
    const children = node.asList() orelse return null;
    if (children.len < 2) return null;
    const head = children[0].asAtom() orelse return null;
    if (!std.mem.eql(u8, head, "check")) return null;
    const body = children[1];
    const body_children = body.asList() orelse return null;
    if (body_children.len < 1) return null;
    const kind = body_children[0].asAtom() orelse return null;

    if (std.mem.eql(u8, kind, "connected")) {
        if (body_children.len < 3) return null;
        const a = pinArg(body_children[1]) orelse return null;
        const b = pinArg(body_children[2]) orelse return null;
        return .{ .connected = .{ .pin_a = a, .pin_b = b } };
    }
    if (std.mem.eql(u8, kind, "decoupling")) {
        if (body_children.len < 4) return null;
        const a = pinArg(body_children[1]) orelse return null;
        const b = pinArg(body_children[2]) orelse return null;
        const min_uf = namedNumberArg(body_children[3], "min-uf") orelse return null;
        return .{ .decoupling = .{ .pin_a = a, .pin_b = b, .min_uf = min_uf } };
    }
    if (std.mem.eql(u8, kind, "pullup-range")) {
        if (body_children.len < PULLUP_RANGE_MIN_CHILDREN) return null;
        const p = pinArg(body_children[1]) orelse return null;
        const net_name = netArg(body_children[2]) orelse return null;
        const lo = namedNumberArg(body_children[3], "min-ohms") orelse return null;
        const hi = namedNumberArg(body_children[4], "max-ohms") orelse return null;
        return .{ .pullup_range = .{ .pin = p, .target_net = net_name, .min_ohms = lo, .max_ohms = hi } };
    }
    if (std.mem.eql(u8, kind, "voltage-range")) {
        if (body_children.len < 4) return null;
        const p = pinArg(body_children[1]) orelse return null;
        const lo = namedNumberArg(body_children[2], "min") orelse return null;
        const hi = namedNumberArg(body_children[3], "max") orelse return null;
        return .{ .voltage_range = .{ .pin = p, .min_v = lo, .max_v = hi } };
    }
    if (std.mem.eql(u8, kind, "tied-to-net")) {
        if (body_children.len < 3) return null;
        const p = pinArg(body_children[1]) orelse return null;
        const n = netArg(body_children[2]) orelse return null;
        return .{ .tied_to_net = .{ .pin = p, .target_net = n } };
    }
    if (std.mem.eql(u8, kind, "not-connected")) {
        if (body_children.len < 2) return null;
        const p = pinArg(body_children[1]) orelse return null;
        return .{ .not_connected = .{ .pin = p } };
    }
    if (std.mem.eql(u8, kind, "pin-not-floating")) {
        if (body_children.len < 2) return null;
        const p = pinArg(body_children[1]) orelse return null;
        return .{ .pin_not_floating = .{ .pin = p } };
    }
    if (std.mem.eql(u8, kind, "pins-on-same-net")) {
        if (body_children.len < 2) return null;
        // Body: (pins-on-same-net (pins "A" "B" "C" ...))
        const pins_form = body_children[1].asList() orelse return null;
        if (pins_form.len < 3) return null;
        const ph = pins_form[0].asAtom() orelse return null;
        if (!std.mem.eql(u8, ph, "pins")) return null;
        // Allocate the pin slice in the global page allocator — same lifetime
        // policy as other AST string slices.
        const allocator = std.heap.page_allocator;
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        for (pins_form[1..]) |pn| {
            const s = pn.asText() orelse continue;
            list.append(allocator, s) catch return null;
        }
        if (list.items.len < 2) return null;
        return .{ .pins_on_same_net = .{ .pins = list.toOwnedSlice(allocator) catch return null } };
    }
    if (std.mem.eql(u8, kind, "decoupling-per-pin")) {
        if (body_children.len < DECOUPLING_PER_PIN_MIN_CHILDREN) return null;
        // (decoupling-per-pin (return-pin "X") (pins "A" "B"...) (min-uf F) (count N))
        const rp_form = body_children[1].asList() orelse return null;
        if (rp_form.len < 2) return null;
        const rp_head = rp_form[0].asAtom() orelse return null;
        if (!std.mem.eql(u8, rp_head, "return-pin")) return null;
        const return_pin = rp_form[1].asText() orelse return null;

        const pins_form = body_children[2].asList() orelse return null;
        if (pins_form.len < 2) return null;
        const ph = pins_form[0].asAtom() orelse return null;
        if (!std.mem.eql(u8, ph, "pins")) return null;
        const allocator = std.heap.page_allocator;
        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        for (pins_form[1..]) |pn| {
            const s = pn.asText() orelse continue;
            list.append(allocator, s) catch return null;
        }
        if (list.items.len == 0) return null;

        const min_uf = namedNumberArg(body_children[3], "min-uf") orelse return null;
        const count_f = namedNumberArg(body_children[4], "count") orelse return null;
        const count: u32 = if (count_f < 0) 0 else @intFromFloat(count_f);
        return .{ .decoupling_per_pin = .{
            .return_pin = return_pin,
            .pins = list.toOwnedSlice(allocator) catch return null,
            .min_uf = min_uf,
            .count = count,
        } };
    }
    if (std.mem.eql(u8, kind, "series-element")) {
        if (body_children.len < SERIES_ELEMENT_MIN_CHILDREN) return null;
        // (series-element (kind R|L|C) (pin "P") (target-net "N") (min X) (max Y))
        const kind_form = body_children[1].asList() orelse return null;
        if (kind_form.len < 2) return null;
        const kh = kind_form[0].asAtom() orelse return null;
        if (!std.mem.eql(u8, kh, "kind")) return null;
        const kind_atom = kind_form[1].asAtom() orelse return null;
        const sk: SeriesKind = if (std.mem.eql(u8, kind_atom, "R")) .R //
            else if (std.mem.eql(u8, kind_atom, "L")) .L //
            else if (std.mem.eql(u8, kind_atom, "C")) .C //
            else return null;
        const p = pinArg(body_children[2]) orelse return null;
        const tn_form = body_children[3].asList() orelse return null;
        if (tn_form.len < 2) return null;
        const tn_head = tn_form[0].asAtom() orelse return null;
        if (!std.mem.eql(u8, tn_head, "target-net")) return null;
        const target_net = tn_form[1].asText() orelse return null;
        const lo = namedNumberArg(body_children[4], "min") orelse return null;
        const hi = namedNumberArg(body_children[SERIES_ELEMENT_MAX_INDEX], "max") orelse return null;
        return .{ .series_element = .{
            .kind = sk,
            .pin = p,
            .target_net = target_net,
            .min = lo,
            .max = hi,
        } };
    }
    return null;
}

/// True if `needle` exactly equals any string in `haystack`. Used to test a
/// field/form key against a fixed set of known/structural keywords.
pub fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn pinArg(node: ast.Node) ?[]const u8 {
    const c = node.asList() orelse return null;
    if (c.len < 2) return null;
    const h = c[0].asAtom() orelse return null;
    if (!std.mem.eql(u8, h, "pin")) return null;
    return c[1].asText();
}

fn netArg(node: ast.Node) ?[]const u8 {
    const c = node.asList() orelse return null;
    if (c.len < 2) return null;
    const h = c[0].asAtom() orelse return null;
    if (!std.mem.eql(u8, h, "net")) return null;
    return c[1].asText();
}

fn namedNumberArg(node: ast.Node, name: []const u8) ?f64 {
    const c = node.asList() orelse return null;
    if (c.len < 2) return null;
    const h = c[0].asAtom() orelse return null;
    if (!std.mem.eql(u8, h, name)) return null;
    return c[1].asNumber();
}

/// Parse a `(ref "file.pdf" (page N))` form into a `NoteRef`. Returns null
/// if the node isn't a well-formed ref (wrong head atom, missing pdf
/// filename). Used by section-note and requirement parsers.
pub fn parseNoteRef(node: ast.Node) ?NoteRef {
    const children = node.asList() orelse return null;
    if (children.len < 2) return null;
    const head = children[0].asAtom() orelse return null;
    if (!std.mem.eql(u8, head, "ref")) return null;
    const pdf = children[1].asString() orelse return null;
    var page: u32 = 0;
    var quote: ?[]const u8 = null;
    for (children[2..]) |child| {
        const sub = child.asList() orelse continue;
        if (sub.len < 2) continue;
        const sub_head = sub[0].asAtom() orelse continue;
        if (std.mem.eql(u8, sub_head, "page")) {
            if (sub[1].asNumber()) |n| {
                if (n >= 0 and n < @as(f64, @floatFromInt(std.math.maxInt(u32)))) {
                    page = @intFromFloat(n);
                }
            }
        } else if (std.mem.eql(u8, sub_head, "quote")) {
            if (sub[1].asString()) |s| quote = s;
        }
    }
    return .{ .pdf = pdf, .page = page, .quote = quote };
}

/// A visual group.
pub const Group = struct {
    name: []const u8,
    members: []const []const u8,
};

/// A part grouping within an instance (for multi-part symbols).
pub const Part = struct {
    name: []const u8,
    pins: []const PartPin,
};

/// A pin assigned to a part (pin identifier + net name).
pub const PartPin = struct {
    pin: []const u8,
    net: []const u8,
    /// Function name from pinout file (e.g. "PG10"), empty if unavailable.
    pin_name: []const u8 = "",
    /// Feature group label from the enclosing `(pins ref (group "Foo") ...)`.
    /// Rendered as the leftmost column in the schematic master table.
    group: []const u8 = "",
};

/// One key/value attribute attached to a component or instance, e.g.
/// `manufacturer = "TI"` or `mpn = "STM32N657L0H3Q"`. Surfaced verbatim in
/// the BOM and KiCad netlist export.
pub const Property = struct {
    key: []const u8,
    value: []const u8,
};

/// A placed component in the design — a single ref-des bound to a library
/// component plus its value, footprint, attached requirements, and per-part
/// pin breakdown for multi-part symbols.
pub const Instance = struct {
    ref_des: []const u8,
    /// Descriptive label from source (e.g., "stm32", "flash"). Empty for auto-named passives.
    label: []const u8 = "",
    /// Stable module-local identity, stamped at creation and never rewritten by
    /// ref-des renumbering: the source name for named instances, the
    /// `value@pin#index` / `value#index` structural key for decouple/series
    /// children. Hierarchical (Option-4) sub-block identity hashes the parent
    /// sub-block's uuid with this, so a child's id survives renames and
    /// renumbers. Empty for plain top-level instances (which don't use it).
    origin_key: []const u8 = "",
    component: []const u8,
    value: []const u8,
    footprint: []const u8,
    symbol: []const u8,
    /// Pinout lookup key for lib/pinouts/*.sexp (falls back to symbol/component when unset).
    pinout: []const u8 = "",
    /// Component properties (manufacturer, mpn, etc.)
    properties: []const Property = &.{},
    /// PDF filenames in `lib/datasheets/` declared by the component in its
    /// library definition. Copied onto every instance so downstream renderers
    /// don't have to re-query the evaluator's cache.
    datasheets: []const []const u8 = &.{},
    /// Library-declared rules for using this part. Read-only during review.
    /// Edited by modifying `lib/components/<component>.sexp`.
    requirements: []const Requirement = &.{},
    /// True when the component declares `(ignore-requirements)` — opt-out for
    /// parts that don't need a requirement check (mounting hardware, debug
    /// headers, etc.). Read by the review summary's missing-requirements list.
    requirements_ignored: bool = false,
    /// Per-pin electrical-level metadata, copied from the library component's
    /// `(electrical …)` declarations. Sparse on purpose — pins without a
    /// matching declaration just aren't in the slice. Phase 2A's
    /// voltage-domain compatibility ERC reads this.
    electrical: []const ElectricalDecl = &.{},
    /// Schematic-level attributes (e.g., "np0", "x7r" for dielectric type)
    attrs: []const []const u8 = &.{},
    /// Optional multi-part breakdown. Empty = single-part (render as one hub).
    parts: []const Part = &.{},
    /// Byte offset of the component family name in the source file.
    source_offset: u32 = 0,
    /// 8-char hex ID from (id xxxxxxxx) in source. Primary stable identity key.
    id: []const u8 = "",
    /// Full UUID for PCB/KiCad export (derived from id or assigned by BOM).
    uuid: []const u8 = "",
    /// True when this instance was synthesised from a placeholder `(stub …)`
    /// form rather than a real library component. Downstream consumers skip
    /// pin-level geometry checks and pad-net emission for it, and ERC warns
    /// (never errors) that it needs a real component before fab.
    placeholder: bool = false,
};

/// A sub-block reference.
pub const SubBlock = struct {
    name: []const u8,
    block: *DesignBlock,
    /// Where the sub-block's implementation lives, so the schematic page can
    /// offer a "copy source" affordance and the `/modules` viewer can find
    /// the file. For `(sub-block "x" (module-name …))` this is the module
    /// name (resolved to `lib/modules/<name>.sexp`); for `(sub-block "x"
    /// "path/to/file.sexp")` it is that project-relative path. Empty when the
    /// sub-block was constructed without source provenance (e.g. tests).
    source: []const u8 = "",
};

/// A pin group referencing a top-level instance's pins within a section.
pub const PinGroup = struct {
    ref_des: []const u8,
    pins: []const PartPin,
    /// Optional feature label from `(pins ref (group "Boot & Reset") ...)`.
    group: []const u8 = "",
};

/// Signal type classification for section interfaces.
pub const SignalType = enum {
    power,
    signal,
    clock,
    data,
    differential,
};

/// Direction of a section-level port for the block diagram. `in` is a sink
/// (consumes power/signal), `out` is a source, `io` is bidirectional like an
/// SPI or I2C bus.
pub const PortDirection = enum { in, out, io };

/// A declared interface on a section (in/out/io).
pub const SectionPort = struct {
    name: []const u8,
    direction: PortDirection,
    signal_type: SignalType = .signal,
    /// Voltage level for power signals.
    voltage: ?f64 = null,
    /// Additional signals grouped under this port (for buses/diff pairs).
    group: []const []const u8 = &.{},
    /// Role annotation (e.g., "enable", "reset", "interrupt").
    role: []const u8 = "",
    /// Protocol annotation (e.g., "SPI", "USB2.0-HS").
    protocol: []const u8 = "",
    /// Explicit diagram signal-class key (e.g. "power", "clock", "audio"),
    /// declared via `(class <key>)`. Authoritative for diagram edge
    /// classification — overrides both `signal_type` and net-name heuristics.
    /// Empty ⇒ fall back to `signal_type` then name heuristics.
    class: []const u8 = "",
    /// Whether this port is optional (no ERC error if unconnected).
    optional: bool = false,
    /// Optional electrical character carried by this port — declared via an
    /// `(electrical (type ...) (v-oh-typ ...) ...)` sub-clause inside the
    /// `(port …)` form. Same role as `Port.electrical`: feeds
    /// `checkVoltageDomainCompat` so signals crossing a section boundary
    /// (typical case: a mezzanine connector section declaring 3.3 V CMOS)
    /// participate in driver/receiver compatibility checks.
    electrical: ?ElectricalDecl = null,
};

/// A named calculation block with computed values.
pub const CalcBlock = struct {
    name: []const u8,
    /// Computed results as key-value pairs for display.
    results: []const CalcResult = &.{},
};

/// One named scalar produced by a `(calc …)` block — e.g. the Vout computed
/// from feedback resistors. Rendered into the section's review card so the
/// reviewer sees the design intent next to the components that implement it.
pub const CalcResult = struct {
    name: []const u8,
    value: f64,
};

/// Design maturity status for a section.
pub const SectionStatus = enum {
    /// High-level concept: ports and protocols defined, no component implementation yet.
    concept,
    /// Fully implemented with real components, pinouts, and passives.
    implemented,
    /// Implemented but flagged for review.
    review,
};

/// A named section that wraps related instances and pin groups.
pub const Section = struct {
    name: []const u8,
    /// Optional description shown under the section title.
    description: []const u8 = "",
    /// Explicit diagram category key (e.g. "mcu", "power", "rf"), declared via
    /// `(category <key>)`. Authoritative for the system-overview node identity
    /// and column placement — overrides the keyword `classifyByName` heuristic.
    /// Empty ⇒ fall back to `block_role` then the name heuristic.
    category: []const u8 = "",
    /// Design notes shown at the bottom of the section. Each carries optional
    /// datasheet page references so reviewers can jump from a note to the
    /// exact page in `lib/datasheets/` that backs the decision.
    notes: []const SectionNote = &.{},
    /// Instances declared inside this section.
    instances: []const Instance = &.{},
    /// Pin assignments for top-level instances referenced inside this section.
    pin_groups: []const PinGroup = &.{},
    /// Declared interfaces (in/out/io) for block diagram generation.
    ports: []const SectionPort = &.{},
    /// Communication protocols used by this section (e.g., "SPI", "I2C", "OctoSPI").
    protocols: []const []const u8 = &.{},
    /// Named calculation blocks.
    calcs: []const CalcBlock = &.{},
    /// Nested sub-sections (internal detail, shown in schematic but merged in block diagram).
    sub_sections: []const Section = &.{},
    /// Design maturity status (concept, implemented, review). Inferred from content if not explicit.
    status: SectionStatus = .implemented,
    /// Block diagram role: input (power source), output (power sink), or auto (inferred).
    block_role: BlockRole = .auto,
    /// Suppress this section from the block-diagram view at the top of
    /// the schematic page. Set via `(diagram hidden)` in the section
    /// body. Use for mechanical-only sections (mounting, fiducials) or
    /// passive instrumentation (test points) whose presence in the
    /// connectivity diagram adds noise without conveying connectivity.
    diagram_hidden: bool = false,
    /// Sub-block instance names this section owns, declared via
    /// `(hosts "psu1" "mon_ch1")`. The block-diagram resolver folds each
    /// named sub-block into this section's node (so it carries the
    /// section's label and edges) — an explicit, layout-independent
    /// alternative to the net-count attachment heuristic.
    hosts: []const []const u8 = &.{},
};

/// Block diagram placement role for sections.
pub const BlockRole = enum { auto, input, output };

/// A net-tie pair: merge net `b` into net `a`.
pub const NetTie = struct { a: []const u8, b: []const u8 };

/// Electrical role of a pin, declared on a library component. Drives
/// Phase 2A's voltage-domain compatibility ERC (driver vs receiver
/// classification) and is the foundation for future signal-integrity
/// analyses.
pub const ElectricalType = enum {
    input,
    output,
    io,
    power_in,
    power_out,
    passive,
    nc,
};

/// Drive strength / output-style for an `output` or `io` pin. Open-drain
/// outputs require an external pull-up to swing high — Phase 2A's ERC
/// flags rails missing one.
pub const Drive = enum {
    push_pull,
    open_drain,
    open_emitter,
};

/// Electrical-level metadata for one pin of a library component. Indexed
/// by the pin's *function name* (matches the second positional in
/// `lib/pinouts/<part>.sexp`'s `(pin <num> "FN")`) so it survives pinout
/// regeneration. Every field is optional — sparse annotation is fine and
/// downstream consumers skip pins they don't have data for.
pub const ElectricalDecl = struct {
    /// Pin function name as it appears in the pinout file.
    pin: []const u8,
    electrical_type: ?ElectricalType = null,
    drive: ?Drive = null,
    v_ih_min: ?f64 = null,
    v_il_max: ?f64 = null,
    v_oh_typ: ?f64 = null,
    v_ol_typ: ?f64 = null,
    /// Absolute-maximum voltage rating for this pin.
    max_voltage: ?f64 = null,
    /// Power-domain tag (matches `PowerDomain.name`). Empty when the part
    /// doesn't declare a domain — most parts are single-domain so this is
    /// usually omitted.
    domain: []const u8 = "",
};

/// Categories a test point can declare itself as required for. Drives the
/// Phase 2E coverage check ("every power rail must have a `power` test point",
/// "every clock section needs a `clock` test point", etc.).
pub const TestPointTag = enum {
    bring_up,
    power,
    clock,
    reset,
    debug,
    signal,
};

/// A test point declared via the first-class `(test-point …)` form. Distinct
/// from the legacy `(instance "TP1" testpoint …)` convention — both sources
/// coexist; the Phase 2E coverage check (and the review) will merge them.
pub const TestPoint = struct {
    ref_des: []const u8,
    net: []const u8,
    purpose: []const u8 = "",
    required_for: []const TestPointTag = &.{},
};

/// A named voltage domain — the partition a rail or pin belongs to from a
/// noise / isolation / level-shifting perspective. Two pins in different
/// domains can't drive each other electrically without explicit translation.
///
/// Phase 1A landed the type only; no consumer populates `PowerRail.domain`
/// today. Phase 2A's voltage-domain compatibility ERC is the first consumer,
/// and that's when attribution logic lands.
pub const PowerDomain = struct {
    /// Canonical domain name (e.g. `"digital"`, `"analog"`, `"rf"`, `"noisy"`).
    name: []const u8,
    /// When true, cross-domain connections to this domain require an
    /// explicit level shifter or isolation barrier — flagged by ERC.
    is_isolated: bool = false,
    /// Parent domain when this is a sub-domain (e.g. `"analog_1v8"`'s parent
    /// is `"analog"`). Null at the top of the hierarchy.
    parent: ?[]const u8 = null,
};

/// A first-class power rail in the design, derived in a post-eval pass by
/// `eval/rails.build` from sub-block output ports + ferrite-bead union-find.
/// Persisted on `DesignBlock` so every downstream analysis (power_budget,
/// power_sequencing, ERC checks, tree visualisation) sees the same canonical
/// rail set instead of recomputing rail identity from emergent topology.
pub const PowerRail = struct {
    /// Canonical top-level net name on the source side (e.g. "V1P8").
    /// When ferrite beads bridge nets, this is the source-side name; the
    /// bridged downstream names appear in `aliases`.
    name: []const u8,
    /// Alternate net names that resolve to this rail through ferrite bridging.
    /// Empty when no ferrite collapses onto this rail.
    aliases: []const []const u8 = &.{},
    /// Nominal voltage (V), resolved by `eval/rails` in this order:
    ///   1. Sub-block output port `nominal`.
    ///   2. Section power port `voltage` for the same rail name.
    ///   3. Top-level design port `nominal` or `(rated min max)` midpoint.
    /// Null when no declarer supplied a voltage.
    nominal: ?f64 = null,
    /// Sub-block name that sources this rail (e.g. "buck"). Empty when the
    /// rail enters from a board-edge port rather than a regulator.
    source_ref_des: []const u8 = "",
    /// Output port name on the source (e.g. "VOUT").
    source_port: []const u8 = "",
    /// Concatenated sub-block path (e.g. "buck/VOUT") matching the existing
    /// `power_budget.Rail.source_label` so downstream consumers don't have
    /// to reconstruct it.
    source_path: []const u8 = "",
    /// Typical deliverable current (A) declared by the source port. Null
    /// when the source didn't declare it.
    capacity_typ: ?f64 = null,
    /// Absolute-max deliverable current (A) declared by the source port.
    capacity_max: ?f64 = null,
    /// Net that gates this rail's bring-up (from `(enable …)` on the source
    /// port). Empty when the rail is always-on or driven by a PG signal.
    enable_net: []const u8 = "",
    /// Upstream rail name when this rail's source's input rail is itself a
    /// derived rail (e.g. 5V → 3V3 → 1V8). Always null in Phase 1A — the
    /// field is reserved for Phase 2C's cascaded-budget propagation, which
    /// is the first consumer that needs it.
    upstream_rail: ?[]const u8 = null,
};

/// The result of evaluating a design-block form.
/// A declared high-level functional subsystem for the **Function** view — the
/// glanceable "what does the system do" abstraction. `name` is the short
/// functional title ("Measurement"), `subtitle` an optional one-liner, `verb`
/// the action phrase shown on the block ("measures V/R, 3 kV isolated"), and
/// `includes` the section / sub-block names that roll up into this function.
/// Sections named by no `FunctionGroup` auto-group by category in the diagram.
pub const FunctionGroup = struct {
    name: []const u8,
    subtitle: []const u8 = "",
    verb: []const u8 = "",
    includes: []const []const u8 = &.{},
    /// `(stack N)`: render this block as N offset cards to show it's N identical
    /// channels (e.g. a 2-channel PSU). 1 ⇒ a single box.
    stack: u8 = 1,
};

/// One direction a `(place …)` constraint offsets a block in: horizontal
/// (`right_of`/`left_of`) constraints set the column, vertical (`above`/`below`)
/// set the row — so two constraints on different axes pin a block on both.
pub const PlaceRel = enum { right_of, left_of, above, below };

/// One `(rel "ref")` sub-clause of a `(place …)` directive: position the block
/// one box-plus-gap in direction `rel` from the block keyed `reference`.
pub const PlaceConstraint = struct {
    rel: PlaceRel,
    reference: []const u8,
};

/// One `(place "name" (rel "ref")…)` directive from a `(layout …)` form. With no
/// constraints the block is a pinned anchor (a fixed root). With one or more,
/// each constraint positions `name` relative to a referenced block; the
/// placement resolves only once *every* referenced block is itself placed, so a
/// block can be positioned by several others (recursive relative placement).
pub const Placement = struct {
    name: []const u8,
    constraints: []const PlaceConstraint = &.{},
};

/// A declarative, Mermaid-style block-diagram layout from a top-level
/// `(layout …)` form: a list of relative `(place …)` directives the diagram's
/// `computeFreeLayout` resolves into absolute box positions. Empty `placements`
/// ⇒ no free layout declared, so the diagram keeps its category-column views.
pub const LayoutSpec = struct {
    placements: []const Placement = &.{},
};

/// The fully-evaluated result of a `(design-block …)`: the flattened netlist
/// (instances + nets + ports), the section/sub-block tree, and the design-doc
/// metadata (critical ICs, verifications, rails, functions) the review and
/// diagram layers consume.
pub const DesignBlock = struct {
    name: []const u8,
    instances: []const Instance,
    nets: []const Net,
    ports: []const Port,
    notes: []const Note,
    groups: []const Group,
    sub_blocks: []const SubBlock,
    sections: []const Section = &.{},
    /// Net ties for cross-block connections (sub-block port wiring).
    net_ties: []const NetTie = &.{},
    /// Design-side `(verifies …)` sign-offs that answer library requirements
    /// the netlist alone can't verify.
    verifications: []const Verification = &.{},
    /// Critical ICs declared in the `(design-doc …)` form. The traceability
    /// panel joins these against the library + placed instances + checks to
    /// show each part's progress through its import → requirements → placed
    /// lifecycle. Empty when the design has no `(design-doc …)` form.
    critical_ics: []const CriticalIc = &.{},
    /// Derived power rails, populated by `eval/rails.build` at the tail of
    /// `evalDesignBlock`. Empty for blocks with no regulator sub-blocks or
    /// board-edge power ports.
    rails: []const PowerRail = &.{},
    /// Test points declared via the first-class `(test-point …)` form.
    /// Legacy `(instance "TP1" testpoint …)` instances continue to be
    /// collected through the existing review pipeline; Phase 2E merges the
    /// two sources for the coverage check.
    test_points: []const TestPoint = &.{},
    /// Configured power-budget derating from `(power-config (derating R))`.
    /// Null → consumers use their built-in default (0.8 today). Applied by
    /// `power_budget.analyze` to scale the tight-margin threshold.
    derating: ?f64 = null,
    /// Absolute path to the `.kicad_pcb` this design pushes board updates
    /// to, declared via `(kicad-pcb "<path>")` in the design source. Null
    /// when the design has no PCB target — the file-based KiCad sync
    /// endpoint refuses to write without it.
    kicad_pcb_path: ?[]const u8 = null,
    /// Declared functional subsystems for the high-level Function view, from
    /// top-level `(function …)` forms. Empty ⇒ the Function view auto-groups
    /// every section by category instead.
    functions: []const FunctionGroup = &.{},
    /// Placeholder parts declared via top-level `(stub …)` forms — sketched
    /// components with a bounding box and named signals but no real library
    /// footprint yet. They render as diagram nodes, export as pad-less KiCad
    /// outlines, and appear in the traceability table as "needs real
    /// footprint". Empty for designs with no `(stub …)` forms.
    parts: []const PlaceholderPart = &.{},
    /// Declarative Mermaid-style layout from a top-level `(layout …)` form. Its
    /// `(place …)` directives position diagram blocks relative to one another;
    /// the diagram's `computeFreeLayout` resolves them into a free-floating view.
    /// Empty `placements` ⇒ no layout declared, so the category-column views stand.
    layout: LayoutSpec = .{},
};

/// Assertion result.
pub const AssertionResult = struct {
    passed: bool,
    message: []const u8,
    is_warning: bool = false,
};

/// Lexical environment with parent chain.
pub const Env = struct {
    bindings: std.StringHashMapUnmanaged(Value),
    parent: ?*Env,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, parent: ?*Env) Env {
        return .{
            .bindings = .empty,
            .parent = parent,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Env) void {
        self.bindings.deinit(self.allocator);
    }

    pub fn put(self: *Env, name: []const u8, value: Value) !void {
        try self.bindings.put(self.allocator, name, value);
    }

    pub fn get(self: *const Env, name: []const u8) ?Value {
        if (self.bindings.get(name)) |v| return v;
        if (self.parent) |p| return p.get(name);
        return null;
    }
};

// spec: eval/env - Stores and retrieves values by name in an environment
test "env get and put" {
    const alloc = std.testing.allocator;
    var env = Env.init(alloc, null);
    defer env.deinit();

    try env.put("x", .{ .number = 42.0 });
    const v = env.get("x").?;
    try std.testing.expectEqual(@as(f64, 42.0), v.asNumber().?);
    try std.testing.expect(env.get("y") == null);
}

// spec: eval/env - Resolves names through a parent environment chain
test "env parent chain" {
    const alloc = std.testing.allocator;
    var parent = Env.init(alloc, null);
    defer parent.deinit();
    try parent.put("x", .{ .number = 1.0 });

    var child = Env.init(alloc, &parent);
    defer child.deinit();
    try child.put("y", .{ .number = 2.0 });

    try std.testing.expectEqual(@as(f64, 1.0), child.get("x").?.asNumber().?);
    try std.testing.expectEqual(@as(f64, 2.0), child.get("y").?.asNumber().?);
    try std.testing.expect(parent.get("y") == null);
}
