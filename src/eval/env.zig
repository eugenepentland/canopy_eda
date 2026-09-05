//! The evaluator's core data model: the `Value` union the interpreter passes
//! around, the `Env` lexical scope chain, and the record types the built design
//! carries — `DesignBlock`, `Instance`, `Net`, `Port`, `Note`, `Group`,
//! `SubBlock`, `Check`, `Requirement`, … — plus small parse helpers
//! (`parseNoteRef`). The requirement-check grammar (`parseCheck` and the
//! `check_docs` table over `Check`) lives in `check_grammar.zig`. String
//! fields borrow the source/AST buffers (never freed); this module is the
//! shared vocabulary of the whole pipeline.

const std = @import("std");
const pad_neck_profile = @import("../pad_neck_profile.zig");
const ast = @import("../sexpr/ast.zig");
const numeric = @import("../numeric.zig");

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
        /// The subset of those attributes that `eval/attrs.zig` could place in
        /// a typed slot, keyed by the slot's property name. Authored keyed
        /// (`(rating 25V)`) and bare (`"25V"`) attributes both land here, which
        /// is what makes the two spellings mean the same thing downstream.
        typed_attrs: []const Property = &.{},
    },
    /// A block definition: a named, optionally-parameterized circuit.
    block_def: BlockDef,
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
pub const BlockDef = struct {
    name: []const u8,
    params: []const []const u8,
    /// Per-parameter default expression, parallel to `params`. A `(param
    /// default)` pair in the defmodule parameter list stores the default's
    /// AST here; it is evaluated at call time only when the caller omits the
    /// argument. Null = required parameter.
    defaults: []const ?ast.Node,
    body: []const ast.Node,
    /// Import scope from the module file
    imports: *Env,
    /// File the `(defmodule …)` was read from. A module body evaluates long
    /// after its file was loaded, so `callModule` restores this as the
    /// evaluator's current file — otherwise every diagnostic raised inside the
    /// module would be attributed to whichever design happened to call it.
    /// Empty for definitions evaluated from a buffer with no path.
    source_file: []const u8 = "",
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
    /// Display name for the power-budget consumer row, from `(load "name")` on the
    /// pin form. Lets a rolled-up annotation (e.g. a rail's load lumped on its bulk
    /// cap or filter bead) name the real part(s) drawing the current instead of the
    /// carrier component. Empty ⇒ the budget falls back to the instance's component.
    load_label: []const u8 = "",
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
    /// Signal-type keyword from the port form (`power`, `rf`, `clock`, …), ""
    /// when none was written. The PCB rough placer reads it as flow context:
    /// a `power`/`rf` port's direction orients the module (in → left edge,
    /// out → right edge).
    kind: []const u8 = "",
    /// Explicit board-edge hint from `(side left|right|top|bottom)` — the
    /// author's override for where this port's net enters/leaves the module.
    /// "" = unset (the placer falls back to the direction convention above).
    side: []const u8 = "",
    /// Optional electrical character carried by this port — declared via an
    /// `(electrical (type ...) (v-oh-typ ...) ...)` sub-clause on a top-level
    /// `(port …)`. Used by `checkVoltageDomainCompat` as a virtual
    /// driver/receiver on the port's net so cross-board interface contracts
    /// (e.g. "this mezzanine pin is 3.3 V CMOS") show up in ERC even when the
    /// far-side device lives in a different design.
    electrical: ?ElectricalDecl = null,
    /// Pair key shared by the two lanes a `(diff-port "BASE" …)` expands to —
    /// the form's base name, identical on the `_P` and `_N` port. Empty on a
    /// hand-written `(port …)`, so it is also the "this port was declared as
    /// half of a differential pair" flag ERC's both-or-neither rule keys on.
    diff_pair_of: []const u8 = "",

    /// True when this port carries supply-rail specs — a nominal voltage, a
    /// rated range, a current capacity, or an efficiency. Declared once here
    /// so `eval/rails` (rail-source detection) and `eval/power_sequencing`
    /// (enable-graph power-port test) share one definition instead of two
    /// hand-kept-in-sync copies.
    pub fn isPowerSource(self: Port) bool {
        return self.nominal != null or
            self.rated_min != null or self.rated_max != null or
            self.current_typ != null or self.current_max != null or
            self.efficiency != null or self.efficiency_linear;
    }

    /// True when an explicit `(port … KIND)` word says this port is NOT a
    /// supply — `signal`, `rf`, `clock`, … A port declaring no kind says
    /// nothing either way, so it stays eligible.
    ///
    /// "An explicit non-power kind is authoritative" is the rule the decoupling
    /// census in `eval/net_analysis` already applies, so a rated enable input
    /// can declare its voltage envelope without becoming a rail. Declared once
    /// here because the power budget must apply the SAME rule: a regulator's
    /// whole input current charged to the rail its ENABLE pin happens to sit on
    /// is a load on a rail that never carries it.
    pub fn isDeclaredNonPower(self: Port) bool {
        return self.kind.len > 0 and !std.ascii.eqlIgnoreCase(self.kind, "power");
    }
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

/// One datasheet-review category that was intentionally judged not
/// applicable to a component. The rationale is mandatory in strict preflight
/// so an omitted topic cannot be disguised as an unexplained N/A.
pub const DatasheetReviewNa = struct {
    category: []const u8,
    rationale: []const u8,
};

/// Completion state of the component-library datasheet review. `draft` is
/// useful while requirements are still being extracted; `stale` records a
/// known superseded review without deleting its provenance.
pub const DatasheetReviewStatus = enum { draft, complete, stale };

/// Evidence that an active component's datasheet was reviewed before it was
/// used in a schematic. Stored inside `(component ...)` as:
///
///   (datasheet-review
///     (datasheet "part.pdf")
///     (sha256 "...")
///     (status complete)
///     (reviewed-by "agent-or-human")
///     (date "YYYY-MM-DD")
///     (category supply)
///     (category-na sequencing "not applicable: always-on device"))
///
/// Preflight also hashes the current PDF, so replacing a datasheet makes the
/// record stale even if the form was not manually changed.
pub const DatasheetReview = struct {
    datasheet: []const u8,
    sha256: []const u8,
    status: DatasheetReviewStatus = .draft,
    reviewed_by: []const u8 = "",
    date: []const u8 = "",
    categories: []const []const u8 = &.{},
    not_applicable: []const DatasheetReviewNa = &.{},
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
    /// `(channels N)`: this stub stands for N identical channels, drawn as N
    /// offset cards stacked behind one box (e.g. a 2-channel PSU, 4 banana
    /// jacks). Its signals wire one representative channel. 1 ⇒ a single box.
    channels: u8 = 1,
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
    /// `netlisp freeze-requirement-ids` once a design starts using verifies.
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
    decoupling: struct {
        pin_a: []const u8,
        pin_b: []const u8,
        min_uf: f64,
        /// Optional upper bound. This distinguishes a required 100 nF
        /// high-frequency bypass from a 10 µF bulk capacitor, while omitting
        /// it preserves the original minimum-only check.
        max_uf: ?f64 = null,
    },
    /// `(pullup-range (pin "P") (net "N") (min-ohms L) (max-ohms H))` — a
    /// resistor must bridge the net seen on pin P and the named net N, with
    /// value in the given range. Covers PROG-style "charge-current set
    /// resistor must be 2k–67k" checks.
    pullup_range: struct { pin: []const u8, target_net: []const u8, min_ohms: f64, max_ohms: f64 },
    /// `(voltage-range (pin "V") (min L) (max H))` — the port declared on
    /// the net wired to pin V must fall inside the range L..H. Covers
    /// "VDD input supply must be 3.75–6V" style envelope checks against
    /// the design's declared rails.
    voltage_range: struct {
        pin: []const u8,
        min_v: f64,
        max_v: f64,
        /// Non-empty only for the grammar alias `(voltage-not-above …)`.
        /// Keeping the two voltage comparisons in one variant avoids widening
        /// the already-large requirement-check union.
        not_above_pin: []const u8 = "",
        margin_v: f64 = 0,
    },
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
    /// `(feedback-divider (pin "FB") (return-net "GND")
    /// (reference-v 0.6) (tolerance-pct 2))` — locate the upper/lower
    /// resistors incident to FB, calculate VOUT=VREF*(1+Rtop/Rbottom), and
    /// compare it with the declared output rail (or voltage encoded in its
    /// net name).
    feedback_divider: struct {
        pin: []const u8,
        return_net: []const u8,
        reference_v: f64,
        tolerance_pct: f64,
    },
    /// `(set-resistor-output (pin "SET") (return-net "GND")
    /// (output-pin "OUT") (current-ua 100) (tolerance-pct 2))` — calculate
    /// VOUT=ISET*RSET and compare it with the output rail declaration/name.
    set_resistor_output: struct {
        pin: []const u8,
        return_net: []const u8,
        output_pin: []const u8,
        current_ua: f64,
        tolerance_pct: f64,
    },
    /// `(cap-rating (pin "A") (pin "B") [(min-ratio X)] [(min-v V)])` — every
    /// capacitor bridging the nets on pins A and B must carry a voltage-rating
    /// attribute of at least `min_ratio` times the worst-case DC potential the
    /// design derives across those two nets (`eval/net_envelopes`), and at
    /// least `min_v` volts. A cap with no rating is never a pass, and a net
    /// with no derivable envelope is reported unproven rather than assumed
    /// safe. Covers "the input cap must be rated for the worst-case IN
    /// voltage" style datasheet prose.
    cap_rating: struct {
        pin_a: []const u8,
        pin_b: []const u8,
        /// Multiple of the derived envelope every bridging cap must carry.
        /// `0` disables the ratio arm (only `(min-v …)` was written).
        min_ratio: f64,
        /// Absolute floor in volts. `0` disables the absolute arm.
        min_v: f64,
    },
    /// `(max-distance (pin "P") (kind C|R|L|any) (mm D) [(min-value X)]
    /// [(max-value Y)])` — the nearest matching passive on pin P's net must
    /// sit within D mm of that pad in the SAVED LAYOUT. `netlisp check` has no
    /// geometry, so the requirement checker reports it layout-deferred and the
    /// measurement itself is the `req-distance-far` lint in
    /// `src/placement/layout_lint.zig`.
    max_distance: struct {
        pin: []const u8,
        kind: DistanceKind,
        max_mm: f64,
        /// Value-window filter in the kind's natural unit (ohms / uH / uF),
        /// exactly like `series_element`. Null ends are unbounded.
        min_value: ?f64 = null,
        max_value: ?f64 = null,
    },
    /// `(sequence (pin "A") before (pin "B") [(margin-ms N)])` — the supply
    /// rail on pin A must come up before the rail on pin B, judged against
    /// `eval/power_sequencing`'s derived order. `margin_ms` is recorded and
    /// reported but only enforced once the sequencing model carries timing.
    sequence: struct {
        pin_a: []const u8,
        pin_b: []const u8,
        margin_ms: f64 = 0,
    },
};

/// Passive class a `(max-distance …)` rule accepts, by ref-des prefix. `any`
/// matches every two-terminal passive class the schematic recognises, for the
/// datasheet rules that say "the coupling element" without naming R, L or C.
pub const DistanceKind = enum { C, R, L, any };

/// One `(check (max-distance …))` requirement resolved against the built
/// block: the pad the distance is measured from, and the ref-des of every
/// passive that already satisfies the rule's kind/value filter on that pad's
/// net. Resolved once in the evaluator (`builders.resolveDistanceRules`) and
/// carried to the placement layer through `flat_netlist.FlatInstance`, so the
/// layout lint never loads a pinout or parses a component value — the same
/// "resolve once, share" contract `placement/near_bind.zig` documents.
pub const DistanceRule = struct {
    /// Requirement id, so a lint finding points back at the datasheet rule.
    req_id: []const u8,
    /// Physical pad on the declaring part the distance is measured from.
    pad: []const u8,
    /// Every passive satisfying the kind/value filter on that pad's net.
    /// Empty means the netlist cannot satisfy the rule at any placement,
    /// which the requirement checker reports as a failure at build time.
    candidates: []const []const u8 = &.{},
    max_mm: f64,
    /// Human spelling of the kind/value filter, for the lint message
    /// (e.g. `C in [0.010, 0.100] uF`).
    what: []const u8 = "",
};

/// Element kind for `series-element` checks. Determines which ref-des prefix
/// (R/L/C) the check engine filters by, and which value-parser to use.
pub const SeriesKind = enum { R, L, C };

/// True if `needle` exactly equals any string in `haystack`. Used to test a
/// field/form key against a fixed set of known/structural keywords.
pub fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
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
                // checkedInt rejects NaN/negative/out-of-range in float space —
                // a bare @intFromFloat on those is UB in the safety-off build.
                if (numeric.checkedInt(u32, n)) |p| page = p;
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

/// A hand-authored functional super-block for the top-level system view:
/// `(function "name" "caption" [(stack N)] (hosts "Section A" "Section B" …))`.
/// `hosts` names authored sections / sheet titles (the same keys the editor's
/// bands use — the synthetic "Power" band is a valid host too). `caption` is
/// the what-it-does verb/spec line ("0–18 V · 3 A per channel"); `stack` > 1
/// renders as N offset cards ("×N identical channels").
pub const FunctionSpec = struct {
    name: []const u8,
    caption: []const u8 = "",
    stack: u8 = 1,
    hosts: []const []const u8 = &.{},
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
    /// The part's library documentation — its datasheet PDFs and the
    /// digest-bound review record. See `ComponentDocs`.
    docs: ComponentDocs = .{},
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
    /// The authored typed attributes (`voltage`, `dielectric`, `tolerance`,
    /// `power`, `current`, `tempco`, `esr`, `esl`), keyed by property name.
    /// They are already merged into `properties`; this is the record of what
    /// the DESIGN asked for, kept so a parts-table row that overrides a rating
    /// can be reported as a disagreement rather than silently winning.
    typed_attrs: []const Property = &.{},
    /// `(check (max-distance …))` requirements resolved against this
    /// placement — see `DistanceRule`. Empty for every part that declares
    /// none, which is almost all of them.
    distance_rules: []const DistanceRule = &.{},
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
    /// True when the instance declares `(dnp)` — Do Not Populate. The footprint
    /// and pads stay in the netlist / on the board (so the option can be stuffed
    /// during a rework), but it is excluded from the assembly BOM and marked DNP
    /// in the schematic, the KiCad netlist, and the .kicad_pcb footprint attrs.
    dnp: bool = false,
    /// Every authored *placement* binding this instance carries — which hub pad
    /// it decouples, which pad it must sit beside. See `InstanceBinds`.
    bind: InstanceBinds = .{},
    /// `(strap-ok PIN "reason")` blessings — explicit sign-offs that a config /
    /// enable / reset strap on this part is *deliberately* tied straight to a
    /// rail (rather than driven through a pull-up/down). Each entry pins a
    /// physical pad (resolved like a `(pin …)` token) to a human reason. The
    /// `strap_tied_to_rail` ERC error fires on any strap pad sitting on a rail
    /// net that lacks a non-empty blessing here. Empty ⇒ no strap tie is blessed.
    strap_oks: []const StrapOk = &.{},
    /// `(nc-ok PIN "reason")` blessings — explicit sign-offs that a pad the part
    /// would otherwise want connected is *deliberately* left a no-connect. Each
    /// entry pins a physical pad (resolved like a `(pin …)` token) to a human
    /// reason. The `no_connect` ERC finding fires on any unconnected pad the
    /// pinout classifies as needing a connection (a declared input, a config
    /// strap) that lacks a non-empty blessing here. Empty ⇒ nothing is blessed.
    nc_oks: []const NcOk = &.{},
    /// Everything the thermal analyzer needs about this placed part: the
    /// library part's declared thermal envelope plus any `(power …)` the
    /// instance itself declares. See `InstanceThermal`.
    thermal: InstanceThermal = .{},
    /// Structural evidence read off the part's `lib/pinouts` entry when the
    /// instance was built. See `PinoutFacts` — it is what lets semantic
    /// classification stop guessing from the ref-des letter.
    pinout_facts: PinoutFacts = .{},
};

/// What the shape of a part's `lib/pinouts` entry says about the KIND of part
/// it is, summarised once at instance-build time so consumers need no
/// evaluator, no project directory, and no second file read.
///
/// This exists because a ref-des letter is weak evidence: the KiCad importer
/// defaults every part it does not recognise to the IC class `U`, so barrel
/// jacks, SMA connectors, board-to-board sockets, LEDs, crystals, tact
/// switches and M2 SMT spacers all arrive wearing `U`. A pinout, by contrast,
/// is generated from the part itself and says something structural: a part
/// with no supply pad is not an integrated circuit, and a part whose every pad
/// is named after its own number carries no electrical function at all.
///
/// All-false / `known = false` is the honest "no pinout file to read" answer,
/// and every consumer treats it as "no evidence", never as "no supply pin".
pub const PinoutFacts = struct {
    /// A `lib/pinouts` entry was found and parsed. False ⇒ every other field
    /// is meaningless; callers must not read absence as evidence.
    known: bool = false,
    /// At least one pad's function name reads as a real supply pad
    /// (`placement/pin_roles.isSupplyFn`) — VCC/VDD/VIN/…, straps excluded.
    has_supply: bool = false,
    /// At least one pad's function name reads as a ground / exposed-pad
    /// return (`placement/pin_roles.isGroundFn`).
    has_ground: bool = false,
    /// Every pad's function name is a bare number: the importer had no
    /// function names to record, which is the signature of a connector or a
    /// mechanical part rather than of a device with pin functions.
    positional: bool = false,
    /// How many distinct pads the pinout declares. Saturates rather than
    /// wraps; only ever compared, never summed.
    pin_count: u16 = 0,
};

/// The library documentation attached to a part: the datasheet PDFs in
/// `lib/datasheets/` it is documented by, and the digest-bound record proving
/// those pages were reviewed. One value rather than two loose fields because
/// every consumer reads them together (preflight checks the review names a PDF
/// the part actually carries) and because the three records that hold them —
/// the component cache entry, the resolved component, and the placed
/// `Instance` — are wide enough already.
pub const ComponentDocs = struct {
    /// PDF filenames in `lib/datasheets/` declared by the component in its
    /// library definition. Copied onto every instance so downstream renderers
    /// don't have to re-query the evaluator's cache.
    datasheets: []const []const u8 = &.{},
    /// Provenance/completeness record for the datasheet requirement review.
    /// Null for legacy components; authoring mode warns and strict preflight
    /// gates until a complete digest-bound review is present.
    review: ?DatasheetReview = null,
};

/// A library part's declared thermal envelope, from `(thermal …)` in its
/// `lib/components/<name>.sexp` file. Every field is optional: a part declares
/// what its datasheet states and nothing more, and the thermal analyzer falls
/// back to a package estimate for a missing `theta_ja`.
///
/// Resistances are °C/W; temperatures are °C.
pub const ThermalDecl = struct {
    /// Junction-to-ambient resistance (°C/W) — the screening figure, on the
    /// JEDEC board the datasheet used.
    theta_ja: ?f64 = null,
    /// Junction-to-board resistance (°C/W). The lumped Tier-0 screen has no
    /// board to be above and does not use it; it is carried through the
    /// screened row to `placement/thermal_field.zig`, which hangs the junction
    /// this far above the copper under the part.
    theta_jb: ?f64 = null,
    /// Junction-to-case resistance through the package top (°C/W). This is the
    /// package-side path used when a cold plate or heatsink contacts the lid;
    /// unlike psi_jt it is a resistance suitable for a heat-flow model.
    theta_jc: struct {
        /// Generic junction-to-case value whose endpoint direction the source
        /// did not identify. Recorded, never guessed into a top/bottom path.
        generic: ?f64 = null,
        top: ?f64 = null,
        /// Junction-to-case resistance through the exposed pad / package
        /// bottom (°C/W).
        bottom: ?f64 = null,
    } = .{},
    /// Junction-to-top characterisation parameter (°C/W), for correlating a
    /// case-temperature measurement back to the junction. Recorded, not yet
    /// consumed by any analysis.
    psi: struct {
        jt: ?f64 = null,
        /// Junction-to-board characterisation parameter (°C/W).
        jb: ?f64 = null,
    } = .{},
    /// Absolute-maximum junction temperature (°C).
    tj_max: ?f64 = null,
    /// Minimum rated ambient (°C) from `(operating MIN MAX)`.
    operating_min: ?f64 = null,
    /// Maximum rated ambient (°C) from `(operating MIN MAX)`.
    operating_max: ?f64 = null,
};

/// `(power …)` on an instance — the author's own statement of what this part
/// dissipates, in watts. It outranks every derived figure, because a datasheet
/// number beats a rail-current approximation.
pub const PowerDecl = struct {
    /// Typical dissipation (W). `(power 1.2)` sets this alone.
    typ: ?f64 = null,
    /// Worst-case dissipation (W), from `(power (typ …) (max …))`.
    max: ?f64 = null,
};

/// The thermal facts one placed part carries: what the library says about the
/// package, and what the design says the part dissipates. One field on
/// `Instance` rather than two, so the thermal feature costs the record one
/// slot and reads as one concern.
pub const InstanceThermal = struct {
    /// The component's `(thermal …)` declaration, copied off the library entry
    /// so downstream analyzers need no evaluator. Null ⇒ the part declared none.
    decl: ?ThermalDecl = null,
    /// The instance's own `(power …)` declaration. Null ⇒ the analyzer derives
    /// dissipation from pin-current annotations or regulator loss instead.
    power: ?PowerDecl = null,
};

/// `(decouples "IC" PIN)` — bind a decoupling cap's power leg to a specific hub
/// pad. Pins the decoupling-loop target + ratsnest endpoint to that pad, so on a
/// multi-pad rail each cap visibly serves its own pin.
///
/// The IC and the pad are ONE value because the pad alone is ambiguous: a pad
/// number belongs to exactly one part, but a rail shared by two ICs has two
/// parts carrying a pad of that number, and matching on the string picks
/// whichever the net happens to list first. Both halves are therefore carried
/// through the flatten together.
pub const DecoupleBind = struct {
    /// The named hub ref, module-local as written. "" ⇒ no binding.
    ic: []const u8 = "",
    /// The pad it targets. "" ⇒ no binding (auto: lowest-numbered supply pad).
    /// Resolved against the TARGET's pinout in a post-build pass
    /// (`builders.resolveDecoupleTargets`), not the cap's — the cap has no
    /// pinout, and the target may be declared after it.
    pin: []const u8 = "",
    /// `(decouples rail)` — explicit opt-out: this cap serves the whole rail (a
    /// reservoir / deliberately rail-level bypass), so the per-pin-decoupling
    /// lint must not require a pad binding for it. Distinct from "no form at
    /// all" (which IS flagged on a multi-supply-pad rail).
    rail: bool = false,
};

/// `(near "REF" PIN [(own PAD)])` — declare that this two-terminal passive must
/// sit physically ADJACENT to one named pad of another part: a series
/// termination at its driver pin, a feedback resistor at the FB pad, an RF
/// matching element at the port it matches, a bulk cap at the rail's entry pin.
///
/// Pure adjacency, and deliberately NOT decoupling: there is no ground return
/// and no loop, so a near binding never enters the inductance score or the
/// plane-stitch model. `(decouples …)` stays the spelling for a bypass cap —
/// carrying both on one part is an ERC error (`invalid_near_binding`).
pub const NearBind = struct {
    /// The named target ref, module-local as written. "" ⇒ no binding.
    ref: []const u8 = "",
    /// The target's pad. Resolved against the TARGET's pinout in the same
    /// post-build pass the decoupling binding uses, for the same reason: the
    /// map that gives a function name meaning belongs to the target, and the
    /// target may be declared after this part. "" ⇒ no binding.
    pin: []const u8 = "",
    /// `(own PAD)` — which of this part's own legs docks against the target.
    /// "" ⇒ infer it: the leg that shares a net with the resolved target pin.
    /// Spell it only when BOTH legs share a net with the target pin.
    own: []const u8 = "",
};

/// Every authored placement binding an instance carries. One field rather than
/// five loose ones because they are read together by every consumer that cares
/// (the flatten, the placer, ERC, the layout lint) and because `Instance` is a
/// wide enough record already.
pub const InstanceBinds = struct {
    decouple: DecoupleBind = .{},
    near: NearBind = .{},
};

/// One `(strap-ok PIN "reason")` blessing on an instance — see `Instance.strap_oks`.
pub const StrapOk = struct {
    /// Physical pad id the blessing covers (resolved from the form's PIN token).
    pin: []const u8,
    /// Why tying this strap straight to a rail is correct (datasheet rationale,
    /// default-config note, …). Must be non-empty to actually suppress the error.
    reason: []const u8 = "",
};

/// One `(nc-ok PIN "reason")` blessing on an instance — see `Instance.nc_oks`.
/// Same shape as `StrapOk`, but its semantics are "this pad is intentionally a
/// no-connect" rather than "this strap is intentionally tied to a rail".
pub const NcOk = struct {
    /// Physical pad id the blessing covers (resolved from the form's PIN token).
    pin: []const u8,
    /// Why leaving this pad unconnected is correct (datasheet "leave floating"
    /// note, internal pull-up, unused-channel rationale, …). Must be non-empty
    /// to actually suppress the finding.
    reason: []const u8 = "",
};

/// True when `component` names a test point (`testpoint` or `testpoint-*`).
/// Test points are excluded from BOM/coverage/assembly tallies, so review,
/// coverage, and the BOM HTML all need this one classification rule.
pub fn isTestPoint(component: []const u8) bool {
    return std.mem.eql(u8, component, "testpoint") or
        std.mem.startsWith(u8, component, "testpoint-");
}

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
    /// `(reflow)` marker: opt this instantiation out of module-layout
    /// composition — the parent's placer re-flows the module's parts freely
    /// instead of docking the module's own `(placement …)` as a rigid macro.
    reflow: bool = false,
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
    rf,
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
    /// Power-domain tag (e.g. "digital"/"analog"/"rf"). Empty when the part
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

/// A test point declared via the first-class `(test-point …)` form. The form
/// creates a physical `testpoint` instance by default; `virtual` records the
/// explicit marker-only opt-out. Keeping the declaration alongside a physical
/// instance preserves its purpose / required-for metadata for review and ERC.
pub const TestPoint = struct {
    ref_des: []const u8,
    net: []const u8,
    purpose: []const u8 = "",
    required_for: []const TestPointTag = &.{},
    virtual: bool = false,
};

/// A first-class power rail in the design, derived in a post-eval pass by
/// `eval/rails.build` from sub-block output ports + ferrite-bead union-find.
/// Persisted on `DesignBlock` so every downstream analysis (power_budget,
/// power_sequencing, ERC checks, tree visualisation) sees the same canonical
/// rail set instead of recomputing rail identity from emergent topology.
pub const PowerRail = struct {
    /// Proven lower and upper operating bounds for release rating checks.
    pub const RatedVoltage = struct {
        min: ?f64 = null,
        max: ?f64 = null,
    };

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
    /// Authored operating range for the rail. Release checks use `max`, not
    /// the nominal/midpoint, when proving voltage ratings.
    rated_voltage: RatedVoltage = .{},
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
};

/// One `(module-policy (net-class "NET" class))` pin: the placement
/// criticality class an author fixed for a net, overriding the name heuristic.
/// `class` is the atom as written — validated at parse time against the
/// module-policy vocabulary — so this module needs no placement import.
pub const NetClassPin = struct {
    net: []const u8,
    class: []const u8,
};

/// The proven worst-case DC potential range a net's copper reaches, keyed by
/// the FLATTENED net name (`buck_5v75/VIN_F`, `V_12V`) so a sub-block-internal
/// node is nameable at all. Release rating checks read these exactly as they
/// read a `PowerRail`'s rated envelope, which is what lets a part sitting two
/// ferrites deep inside a module have its voltage and dissipation proved.
///
/// `origin` records how the envelope was established, because the two sources
/// carry different authority: `.derived` is a consequence of declarations the
/// design already made (a module port's `(rated …)`, a rail, a DC-conducting
/// ferrite between them), while `.declared` is an author's `(net-envelope …)`
/// assertion about something the topology cannot derive — a GPIO's drive level,
/// a divider's output. A `.declared` envelope that fails to cover a `.derived`
/// one for the same net is a contradiction, and reported as such.
pub const NetEnvelope = struct {
    /// How an envelope was established: `derived` follows from declarations the
    /// design already makes, `declared` is an author's `(net-envelope …)`.
    pub const Origin = enum { derived, declared };

    /// Flattened (`sub-block/`-scoped, net-tie-canonicalised) net name.
    net: []const u8,
    min: f64,
    max: f64,
    origin: Origin = .derived,
    /// Free text from a `(net-envelope … "why")`; empty when derived.
    rationale: []const u8 = "",
    /// Correlation class for envelopes derived through series resistors and
    /// inductors (`eval/net_envelopes`' series-domain pass). Nets sharing a
    /// nonzero `domain` are ONE DC node reached through series conductors, so
    /// their potentials move together: the voltage ACROSS the series element
    /// joining them is bounded by its IR drop, not by the width of the two
    /// intervals treated independently. `0` = not derived that way (seeded,
    /// declared, or ferrite-derived), for which no correlation is claimed.
    domain: u32 = 0,
    /// True for a derived envelope whose extent rests on DEVICE supplies — a
    /// feasibility bound on a driven node ("nothing available to the driver
    /// exceeds X"), not a potential conducted from an anchor. A rating check
    /// may prove safety against such a bound, but must not report the bound
    /// itself as an exposure the part experiences.
    bounded: bool = false,
};

/// Board-level transient intent for one physical power domain. Unlike the DC
/// power budget, PDN domains are not collapsed through ferrite beads: the
/// authored `net` names the copper node whose impedance is to be screened.
pub const PdnIntent = struct {
    net: []const u8,
    ripple_v: f64,
    step_current_a: ?f64 = null,
    rise_time_s: ?f64 = null,
    source_resistance_ohm: ?f64 = null,
    source_inductance_h: ?f64 = null,
    f_min_hz: f64 = 1.0e3,
    f_max_hz: f64 = 1.0e9,
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

/// One `(row "a" "b" …)` directive from a `(layout …)` form: an ordered list of
/// block keys that share a horizontal band. Rows stack top-to-bottom in
/// declaration order; members lay left-to-right in list order.
pub const LayoutRow = struct {
    members: []const []const u8 = &.{},
};

/// One `(group "Label" "a" "b" …)` directive from a `(layout …)` form: a named
/// visual region drawn as a labeled translucent box behind its member blocks
/// (their bounding box, padded). Purely cosmetic — it groups already-placed
/// blocks so a dense diagram reads as labeled sections; it does not move them.
pub const LayoutGroup = struct {
    label: []const u8,
    members: []const []const u8 = &.{},
};

/// Which side of the diagram an `(edge …)` directive pins its blocks to.
pub const EdgeSide = enum { left, right };

/// One `(edge left|right "a" "b" …)` directive: pins its blocks to the far
/// left/right column of the diagram (just outside everything else), stacked
/// vertically and centered on the content. Unlike `(place …)`, the column is
/// resolved *after* the rest of the layout, so the blocks stay on the edge no
/// matter what is added between them.
pub const LayoutEdge = struct {
    side: EdgeSide,
    members: []const []const u8 = &.{},
};

/// A declarative, Mermaid-style block-diagram layout from a top-level
/// `(layout …)` form: either relative `(place …)` directives or `(row …)` bands
/// (or both) that the diagram's `computeFreeLayout` resolves into absolute box
/// positions. Empty `placements` *and* `rows` ⇒ no free layout declared, so the
/// diagram keeps its category-column views.
pub const LayoutSpec = struct {
    placements: []const Placement = &.{},
    rows: []const LayoutRow = &.{},
    groups: []const LayoutGroup = &.{},
    edges: []const LayoutEdge = &.{},
};

/// Which physical board edge a `(board …)` `(left|right|top|bottom …)` list
/// docks its parts to.
pub const PlacementSide = enum { left, right, top, bottom };

/// One part in a `(board …)` edge or `(corners …)` list: the ref-des and an
/// optional rotation override (degrees CCW). `null` ⇒ the solver picks the
/// pads-inward default rotation.
pub const PlacementItem = struct {
    ref: []const u8 = "",
    rot: ?f64 = null,
};

/// One `(left|right|top|bottom …)` edge list of a `(board …)` form: the parts
/// docked flush inside that board edge, in authored order.
pub const PlacementSideSpec = struct {
    side: PlacementSide,
    items: []const PlacementItem = &.{},
};
/// Explicit fabrication role; absent `(board-role …)` defaults to subcircuit.
pub const BoardRole = enum { subcircuit, board };

/// Board face receiving an external fabrication backing. Kept separate from
/// placement.Side so the evaluator remains independent of the placement
/// engine while still carrying an explicit, reviewable top/bottom choice.
pub const FabricationSide = enum { top, bottom };

/// Geometry source for one positive fabrication-layer region. `board` follows
/// the exact authored or saved outline used by the manufacturing export;
/// `polygon` is an independently authored world-mm contour.
pub const FabricationRegion = union(enum) {
    board,
    polygon: []const [2]f64,
};

/// Footprints removed from a backing region. By default only components on the
/// backing's own face are projected; `all_sides` is an explicit opt-in for a
/// process that needs clearance through the board regardless of assembly side.
pub const FabricationFootprintExclusion = struct {
    enabled: bool = false,
    all_sides: bool = false,
    /// Empty means every footprint in the selected side scope.
    refs: []const []const u8 = &.{},
    clearance: f64 = 0,
};

/// An optional, separately fabricated board backing such as JLCPCB FPC tape.
/// This is deliberately outside StackupSpec: its thickness is additional to
/// the finished PCB thickness and its Gerber owns application geometry.
pub const FabricationLayerSpec = struct {
    /// Gerber basename, including `.gbr` (for example `psb_tesa8854.gbr`).
    name: []const u8,
    kind: []const u8 = "adhesive",
    side: FabricationSide,
    material: []const u8,
    thickness: f64,
    regions: []const FabricationRegion,
    exclude_footprints: FabricationFootprintExclusion = .{},
};
/// Feature families a generic keepout may exclude.
pub const PerimeterKeepoutBlocks = struct {
    components: bool = false,
    tracks: bool = false,
    vias: bool = false,
};

/// Generic keepout policy attached to the board's perimeter fence. Clearance
/// starts at the fence via's inward copper edge; allowed nets may cross it.
pub const PerimeterKeepoutSpec = struct {
    clearance: f64 = 0,
    blocks: PerimeterKeepoutBlocks = .{},
    allow_nets: []const []const u8 = &.{},
};

/// Board face(s) an authored `(board … (keepout …))` region reserves. `both`
/// is the honest default for a mechanical obstruction that owns the whole
/// board thickness there; `top`/`bottom` reserve one assembly face only.
pub const BoardKeepoutSide = enum { top, bottom, both };

/// One author-declared board-interior keepout region — the mechanical
/// counterpart of the perimeter band. Its rectangle is board-local mm from the
/// outline's top-left, the SAME frame `BoardHeatsinkSpec.rect` uses, because
/// the regions these describe (a heatsink plate's footprint, a shield can, a
/// bracket) are read off the same mechanical drawing. Unlike the perimeter
/// keepout it is not derived from anything: the author states the rectangle,
/// so nothing about the outline or the fence can move it.
pub const BoardKeepoutSpec = struct {
    /// Author's label, printed by DRC, the describe endpoint and the renderers.
    name: []const u8,
    rect: struct { x: f64, y: f64, w: f64, h: f64 },
    side: BoardKeepoutSide,
    /// Which physical families the region excludes. Defaults to all three; an
    /// explicit `(blocks …)` narrows it.
    blocks: PerimeterKeepoutBlocks = .{ .components = true, .tracks = true, .vias = true },
    /// Copper admitted through anyway, by net name (a heatsink plate that is
    /// bonded to GND still wants its stitching).
    allow_nets: []const []const u8 = &.{},
    /// Optional `(reason "…")` — why the space is reserved, carried to every
    /// surface that names the region so a reader never has to find the commit.
    reason: []const u8 = "",
};

/// A plated-through via fence generated continuously around the board outline.
/// Dimensions are millimetres. `edge_offset` is measured from the finished
/// edge to each via centre; `mask_width` is the solder-mask-free band measured
/// inward from that edge on both outer faces. An all-zero value is undeclared.
pub const PerimeterFenceSpec = struct {
    via_dia: f64 = 0,
    via_drill: f64 = 0,
    spacing: f64 = 0,
    edge_offset: f64 = 0,
    mask_width: f64 = 0,
    net: []const u8 = "GND",
    keepout: PerimeterKeepoutSpec = .{},
};

/// One physical heatsink that belongs to the board design rather than
/// to an editor sidecar. Coordinates and dimensions are board-local mm from
/// the outline's top-left. The target is a stable source identity: sub-block
/// name plus module-local origin,
/// so ordinary ref-des renumbering cannot silently move the sink to a recycled
/// reference designator.
pub const BoardHeatsinkSpec = struct {
    rect: struct { x: f64, y: f64, w: f64, h: f64 },
    side: FabricationSide,
    target: struct { scope: []const u8, origin: []const u8 },
    material: []const u8 = "aluminum_6063",
    geometry: struct {
        shape: []const u8 = "finned",
        base_mm: f64 = 2,
        fin_height_mm: f64 = 10,
        fin_thickness_mm: f64 = 1,
        fin_gap_mm: f64 = 1.5,
        fin_axis: []const u8 = "length",
        lower_width_mm: f64 = 0,
        lower_length_mm: f64 = 0,
        lower_height_mm: f64 = 0,
    } = .{},
    pad: struct { thickness_mm: f64 = 0.5, conductivity_w_mk: f64 = 6 } = .{},
};

/// One axial fan aimed normal to a PCB face. The rectangle is the fan outlet's
/// board projection in board-local millimetres; `distance_mm` is outlet plane
/// to that PCB face. Catalog free-air flow and shutoff pressure stay separate,
/// while `operating_flow_fraction` states the installed-flow assumption used
/// by the screening model.
pub const BoardFanSpec = struct {
    model: []const u8,
    rect: struct { x: f64, y: f64, w: f64, h: f64 },
    side: FabricationSide,
    distance_mm: f64,
    free_air_flow_m3_s: f64,
    max_static_pressure_pa: f64,
    operating_flow_fraction: f64,
};

/// Optional physical cooling assemblies declared by the board.
pub const BoardThermalAssemblySpec = struct {
    heatsink: ?BoardHeatsinkSpec = null,
    fan: ?BoardFanSpec = null,
};
/// The physical board declared by a top-level `(board …)` form: the outline
/// rectangle plus the parts that live ON it — connectors docked to a named
/// board edge (`(left|right|top|bottom "ref" …)` lists, same item grammar as
/// `(placement …)` incl. `(rot N "ref")`) and mounting hardware pinned at the
/// `(corners …)` (TL, TR, BR, BL in authored order). `(size W H)` is required;
/// without it the optimizer ignores the form and lint reports it.
pub const BoardSpec = struct {
    /// Stable company/shop-floor part number for this board family. The
    /// fabrication identity prints it beside the geometry hash when present.
    part_number: []const u8 = "",
    /// Outline size in mm. 0 ⇒ `(size …)` missing → the form is inert.
    w: f64 = 0,
    h: f64 = 0,
    /// `(corner-radius R)` — round the outline's corners with radius R mm
    /// (emitted as fine polyline arcs on every exact-shape consumer:
    /// Edge.Cuts, board-edge DRC, the renderers). 0 = square corners.
    corner_radius: f64 = 0,
    /// `(outline-approved "DIGEST")` — the author's explicit acceptance of a
    /// saved outline whose profile `(size W H)` + `(corner-radius R)` cannot
    /// describe (a notch, a recess, mixed corner radii). Content-bound: it
    /// pins that exact profile's `placement/outline` digest, so redrawing the
    /// outline makes the approval stale rather than silently blessing the new
    /// shape. Empty ⇒ unapproved. The approval covers the PROFILE only — the
    /// declared size is still compared, and still drives the docs.
    outline_approved: []const u8 = "",
    /// Edge-docked parts per board edge (NOT sides of an anchor — the words
    /// name the physical board edge the connector mounts on).
    sides: []const PlacementSideSpec = &.{},
    /// Corner-pinned parts (mounting holes/standoffs): TL, TR, BR, BL.
    corners: []const PlacementItem = &.{},
    /// Optional board-edge via fence and exposed-mask band.
    perimeter_fence: PerimeterFenceSpec = .{},
    /// Author-declared interior keepout regions, in authored order.
    keepouts: []const BoardKeepoutSpec = &.{},
    /// Authored default heatsink. A saved layout may override this assembly;
    /// deleting/rebuilding the sidecar falls back here.
    thermal: BoardThermalAssemblySpec = .{},
    role: BoardRole = .subcircuit,
    /// Subcircuit plane policy: false removes non-ground authored planes, or
    /// suppresses the dominant-supply plane in the implicit stackup model.
    /// Ground planes and the physical copper-layer construction remain.
    power_plane: bool = true,
    present: bool = false,
};
/// One `(plane IDX "NET")` entry of a `(stackup …)` form: copper layer IDX
/// (1-based, 1 = top/F.Cu, `layers` = bottom/B.Cu) is a solid plane carrying
/// NET instead of a routed signal layer.
pub const StackupPlane = struct {
    index: u8,
    net: []const u8,
};

/// Physical foil details for one numbered copper layer. Electrical role stays
/// in `StackupPlane`; construction and routing semantics are deliberately
/// independent so a routed outer pour can still carry ordinary signal tracks.
pub const StackupCopper = struct {
    index: u8,
    thickness: f64,
    material: []const u8 = "Copper",
    /// Fabricated trapezoid: base/artwork width minus the finished narrow-face
    /// width (mm). Zero keeps the rectangular closed-form geometry.
    width_reduction: f64 = 0,
    /// Which board-normal face is narrow after etching. `up` points toward
    /// layer 1; `down` toward the bottom copper layer.
    narrow_side: enum { up, down } = .up,
};

/// One outer-face soldermask process profile. JLC and other impedance tables
/// distinguish coating over laminate from coating over copper; retaining both
/// heights is necessary to reproduce the real stepped cross-section.
pub const StackupSoldermask = struct {
    side: FabricationSide,
    material: []const u8 = "Soldermask",
    er: f64,
    substrate_thickness: f64,
    copper_thickness: f64,
};

/// Physical dielectric construction category from the fab stackup table.
pub const StackupDielectricKind = enum { prepreg, core };

/// The dielectric interval immediately below copper layer `after_layer` and
/// above `after_layer + 1`. A four-layer stack therefore has intervals 1–3.
pub const StackupDielectric = struct {
    after_layer: u8,
    kind: StackupDielectricKind,
    material: []const u8 = "",
    thickness: f64,
    /// Relative permittivity (εr) from `(er X)`. 0 = undeclared, and the
    /// impedance model's generic FR-4 default (`impedance.default_er`, 4.4)
    /// applies. This is the one stackup number that is purely electrical:
    /// nothing about construction or routing reads it, but a
    /// `(net-class … (impedance …))` width cannot be solved without it.
    er: f64 = 0,
};

/// The board's copper stack from a top-level `(stackup N (plane IDX "NET")…)`
/// form. `layers` is the total copper count; layers not named in `planes` are
/// signal layers. `present=false` ⇒ no form authored — the router keeps its
/// legacy implicit model (4 layers; In1 ground, In2 the dominant supply rail
/// or ground again — see `placement/implicit_plane.zig`). `(stackup 2)`
/// declares a plain 2-layer board with NO planes: ground/power become routed
/// copper like any other net.
pub const StackupSpec = struct {
    layers: u8 = 0,
    planes: []const StackupPlane = &.{},
    /// Optional physical foil declarations, one per numbered copper layer.
    copper: []const StackupCopper = &.{},
    /// Optional physical dielectric declarations, one per adjacent-layer gap.
    dielectrics: []const StackupDielectric = &.{},
    /// Optional top/bottom coating profiles used by process-aware impedance.
    soldermasks: []const StackupSoldermask = &.{},
    present: bool = false,
    /// Canonical fabricator preset name, or empty for a custom construction.
    preset: []const u8 = "",
    /// Finished board thickness (mm) from `(thickness MM)`; 0 ⇒ unset (the
    /// Gerber job file's fab-standard 1.6 mm default applies).
    thickness: f64 = 0,

    /// The declared plane carrying `net` names a ground-ish plane? Helper for
    /// the router: true when ANY plane is declared (used per-net at routing).
    pub fn hasPlanes(self: StackupSpec) bool {
        return self.planes.len > 0;
    }

    /// Sum of every authored copper foil and dielectric thickness. This is the
    /// complete construction total when all layers and gaps are declared;
    /// `thickness` remains the nominal finished-board value reported to
    /// fabrication (often 1.6 mm for a 1.5862 mm buildup).
    pub fn constructionThickness(self: StackupSpec) f64 {
        var total: f64 = 0;
        for (self.copper) |layer| total += layer.thickness;
        for (self.dielectrics) |layer| total += layer.thickness;
        return total;
    }
};

/// One routing rule from a top-level `(net-class "name" (width MM)
/// (clearance MM) (via DIA DRILL) (priority 0-7) (nets "A" "B" …))` form:
/// trace geometry + routing order for the named nets. A declaration may be a
/// profile only (`nets` empty), membership only (all numeric fields zero), or
/// both. This lets a reusable subcircuit assign a semantic class while its
/// destination board supplies that class's geometry. A zero field keeps the
/// inherited/router default; `nets` entries match local net names
/// case-insensitively. `priority` is the routing-order tier — the router
/// routes higher tiers first, so a critical net (crystal, flash bus, SMPS
/// loop) claims its short path before a bulk rail can block it (the maze
/// router has no rip-up; first-routed wins).
pub const NetClassSpec = struct {
    /// Pad-local trace width, constant-neck length, and taper length.
    pub const PadNeck = pad_neck_profile.Profile;

    name: []const u8 = "",
    width: f64 = 0,
    /// Pad-local neck-down profile. The ordinary class width remains the
    /// routed trunk width; generated copper may use `width` for at most
    /// `max_length` from an SMD land centre, then grows back to the trunk over
    /// `taper_length`. A zero width leaves necking disabled.
    /// This compact trace-width profile also carries the independently authored
    /// `(power-branch-width MM)` reduction for plane-backed rail fanouts.
    pad_neck: PadNeck = .{},
    clearance: f64 = 0,
    via_dia: f64 = 0,
    via_drill: f64 = 0,
    priority: u32 = 0,
    nets: []const []const u8 = &.{},
    /// `(diff-pair [GAP])` marker: <0 = not a differential pair (the default);
    /// 0 = a pair coupling at the class clearance; >0 = an explicit target
    /// edge-to-edge gap (mm). The router routes the pair's N net right after its
    /// P net and biases it into a corridor hugging the twin.
    diff_gap: f64 = -1,
    /// RF discipline this class declares (see `ClassRf`); bend radius, escape,
    /// via fencing and the keepout halo all live there because each is only
    /// meaningful alongside — or defaults off — the class's `(max-freq …)`.
    rf: ClassRf = .{},
    /// `(resolution MM)` — how finely this class's nets are rastered when the
    /// router falls back to a bounded rescue window (0 = the adaptive default).
    /// The maze must place a centerline on a lattice, so a net whose only legal
    /// path clears its obstacles by less than the grid pitch cannot route at any
    /// ordering or priority; declaring a finer pitch buys that net a window it
    /// can be represented in, and only the declaring nets pay for it.
    resolution_mm: f64 = 0,
    /// `(match-group …)` length matching this class declares (see `ClassMatch`).
    /// Grouped into one field the way `rf` is: the two members only mean
    /// anything together — a tolerance with no group names no constraint.
    match: ClassMatch = .{},
    /// Return-current continuity policy declared by `(return-path …)`. Fast
    /// classes (frequency / impedance declared) receive the geometric plane
    /// audit automatically; this block supplies explicit reference, stitching,
    /// and loop-area budgets for any class, including switching nodes.
    return_path: ClassReturnPath = .{},
};

/// Return-path integrity policy for one net class. A bare `(return-path)` opts
/// an otherwise ordinary class into the plane-gap and layer-transition audit.
/// Zero-valued limits keep their documented defaults or disable that one
/// budget, rather than inventing board-specific EMC numbers.
pub const ClassReturnPath = struct {
    declared: bool = false,
    /// `(reference "NET")` pins the expected return net. Empty resolves the
    /// nearest declared reference plane independently for each signal layer.
    reference_net: []const u8 = "",
    /// `(stitch-radius MM)` — maximum signal-transition to stitching-via/cap
    /// distance. 0 uses the DRC's 2 mm default.
    stitch_radius_mm: f64 = 0,
    /// `(max-loop-area MM2)` — maximum estimated trace/reference loop area.
    /// 0 leaves the estimate unbudgeted and therefore emits no area warning.
    max_loop_area_mm2: f64 = 0,
};

/// Length matching declared by a `(net-class … (match-group "NAME"
/// [(tolerance MM)]))` sub-form: which set this class's nets must arrive with,
/// and how far apart they may end up.
pub const ClassMatch = struct {
    /// The group's authored name ("" = this class declares none, the default).
    /// The NAME is the join key, not the class: two classes carrying different
    /// trace geometry may name the same group, which is how a bus split across
    /// a wide and a narrow class still matches as one set.
    group: []const u8 = "",
    /// `(tolerance MM)` — the allowed max−min routed length spread (mm).
    /// 0 = undeclared, and the group falls back to the measurement module's
    /// default (`placement/match_group.default_tolerance_mm`).
    tolerance_mm: f64 = 0,
};
/// Ground via fencing declared by a `(net-class … (fence …))` sub-form (see
/// `ClassRf.fence`): the class's routed traces get a flanking row of stitching
/// vias, generated on demand by a later tool rather than by the autorouter.
/// Every child is optional — a bare `(fence)` means "all defaults" — so each
/// field carries a 0/"" sentinel meaning "derive me at generation time" rather
/// than a concrete number the author never wrote.
pub const ClassFence = struct {
    /// The `(fence …)` sub-form appeared at all. This is the whole opt-in: a
    /// class without it is never fenced, whatever the other fields say (they
    /// are all sentinels then anyway).
    declared: bool = false,
    /// `(pitch MM)` — via centre-to-centre spacing along the trace.
    /// 0 = derive from the class's `(max-freq …)` as guided-wavelength/10.
    pitch_mm: f64 = 0,
    /// Generated and solder-mask-open fence row counts. `(layers N)` defaults
    /// to one generated row; `(mask-layers N)` uses 0 as its undeclared
    /// sentinel, exposing every generated row for backward compatibility.
    rows: struct { generated: u8 = 1, mask_open: u8 = 0 } = .{},
    /// `(offset MM)` — copper-edge to fence-via copper-edge gap. 0 = derive as
    /// the class clearance plus a fabrication margin.
    offset_mm: f64 = 0,
    /// `(via DIA DRILL)` copper diameter for the fence vias (mm).
    /// 0 = inherit the class's own `(via …)`, else the board design rules.
    via_dia: f64 = 0,
    /// `(via DIA DRILL)` drill diameter for the fence vias (mm).
    /// 0 = inherit the class's own `(via …)`, else the board design rules.
    via_drill: f64 = 0,
    /// `(net "NAME")` — the net the fence vias stitch. "" = resolve to the
    /// board's first declared ground/plane net when the fence is generated.
    net: []const u8 = "",
};

/// The class's ELECTRICAL declarations and the discipline each implies (see
/// `NetClassSpec.rf`): the highest frequency it carries, its controlled-impedance
/// target, and — following from those — bend radius, pad escape, ground via
/// fencing and the same-layer keepout halo. Grouped because none of these is a
/// geometry number the author picks directly the way `width` / `clearance` are:
/// each states a physical property of the signal, from which geometry follows.
pub const ClassRf = struct {
    /// `(band MIN_HZ MAX_HZ)` lower edge. The upper edge shares
    /// `max_freq_hz` with `(max-freq …)` so existing RF disciplines and the
    /// electrical model cannot drift onto different bandwidths. 0 means use
    /// the compatibility band `max_freq_hz / 100 .. max_freq_hz`.
    electrical: struct {
        band_start_hz: f64 = 0,
        /// `(return-loss DB)` minimum worst-case return loss over the class
        /// band. 0 is the authored sentinel; resolution supplies 20 dB.
        return_loss_target_db: f64 = 0,
    } = .{},
    /// `(max-freq HZ)` — the highest signal frequency the class carries
    /// (0 = undeclared). Declaring it opts the class into RF bend discipline:
    /// routed corners become arcs with centerline radius >= 3x the trace
    /// width, and corners that can't reach that radius are flagged by DRC.
    max_freq_hz: f64 = 0,
    /// `(escape MM)` — straight pad-escape distance: the class's traces leave
    /// each pad straight for this length before any bend. <0 = undeclared
    /// (a max-freq class then defaults to 1 mm); an explicit 0 disables it.
    escape_mm: f64 = -1,
    /// `(min-bend-radius N)` — the class's bend-radius FLOOR as a multiple of
    /// the trace width (floor = N × width). 0 = undeclared (a max-freq class
    /// then uses the 3× rule-of-thumb default). Only meaningful with
    /// `(max-freq …)`: it moves both the compliance floor the sharp_bend check
    /// enforces AND, when N exceeds the 5× aim cap, the radius the smoother
    /// aims for.
    min_bend_ratio: f64 = 0,
    /// `(fence …)` — flanking ground stitching vias for this class's traces
    /// (see `ClassFence`). Undeclared leaves `declared = false`.
    fence: ClassFence = .{},
    /// `(mask-relief MM)` — per-side solder-mask pullback from this class's
    /// routed copper: the Gerber mask opens along the class's outer-layer
    /// traces and vias, exposing bare copper (an RF microstrip convention —
    /// mask over the trace shifts and losses the line). <0 = undeclared: a
    /// max-freq class defaults ON at the board's mask margin, any other class
    /// stays tented. An explicit 0 keeps a max-freq class tented; >0 sets the
    /// pullback (and opts in a class with no `(max-freq …)`).
    mask_relief_mm: f64 = -1,
    /// `(keepout MM …)` — the halo (mm) foreign copper must keep from this
    /// class's own copper, ON THE SAME LAYER only (a signal may cross freely on
    /// another layer; a through-via barrel lands on every layer and so is still
    /// blocked by the halo). 0 = no halo declared.
    keepout_mm: f64 = 0,
    /// `(keepout MM (escape MM))` — the radius around this class's own pad
    /// terminals inside which the halo is relaxed, so a neighbouring signal may
    /// leave its IC right beside the RF pad. <0 = undeclared (inherit the
    /// class's resolved `escape_mm`); an explicit 0 means no exemption at all —
    /// the same load-bearing −1 sentinel convention `escape_mm` uses.
    keepout_escape_mm: f64 = -1,
    /// `(impedance OHMS)` — the class's target single-ended characteristic
    /// impedance. 0 = undeclared. Declared ALONE, the class's track width is
    /// DERIVED from it against the `(stackup …)` buildup (see
    /// `placement/impedance.zig`) — which is what makes `max_freq_hz` above an
    /// electrical statement rather than a geometry convention. Declared
    /// alongside an authored `(width …)`, the width WINS and this becomes a
    /// CHECK: the `impedance_mismatch` lint reports the width's computed Z₀
    /// when it misses the target by more than the fab's tolerance band.
    impedance: struct {
        ohms: f64 = 0,
        /// `(diff-impedance OHMS …)` — target impedance across the two traces
        /// of a `(diff-pair GAP)` class. 0 = undeclared.
        diff_ohms: f64 = 0,
        /// Optional 1-based copper layer nested in either impedance form.
        /// 0 = resolve against the first usable signal layer.
        layer: u8 = 0,
        /// `(ground-gap MM)` — desired same-layer edge-to-edge gap from an outer
        /// trace to its ground pour. Positive selects grounded-coplanar analysis;
        /// resolution raises it to the copper-clearance floor before use.
        ground_gap_mm: f64 = 0,
        /// Optional `(max MM)` child of `(ground-gap MM …)`. Positive lets the
        /// pour widen its slot per routed section to preserve the impedance
        /// target as the trace tapers; 0 keeps the authored gap fixed.
        ground_gap_max_mm: f64 = 0,
    } = .{},
};

/// One `(wave "name" selector…)` entry of a `(pcb-plan …)` place or route
/// section — the ordered unit of layout completion. A *place* wave selects
/// parts (`refs` / `sections` / `sub_blocks` / `rest`); a *route* wave selects
/// nets (`classes` / `net_classes` / `nets` / `rest`). Only the selectors valid
/// for the wave's own section are populated — a cross-section selector is warned
/// and dropped at parse time — so on a place wave the route lists are always
/// empty and vice versa. `rest` is the catch-all flag: it names no members and
/// means "everything not claimed by an earlier wave in this section" (resolving
/// that into a concrete set is a later slice; parse only records the flag).
/// `classes` atoms are stored as the raw `placement/module_policy.NetClass`
/// enum-name strings, validated at parse time. `reason` is an optional
/// one-string rationale. Route waves may also name preferred signal layers
/// (a cost bias) and allowed signal layers (a hard trace-layer constraint;
/// terminal pad layers remain reachable for breakout). All member slices
/// reference the source AST buffers (never freed, per project convention).
pub const PlanWaypoint = struct {
    x: f64 = 0,
    y: f64 = 0,
    layer: []const u8 = "",
    guide: ?PlanGuide = null,
};

/// One authored `(branch (at …)…)` of a route wave's `(branches …)` guide
/// TREE: the ordered corridor from the tree's shared root terminal out to the
/// one terminal this branch serves. Its points are ordinary waypoints — the
/// root and the served terminal are the pads themselves and are never written
/// here — so a branch reads exactly like a `(waypoints …)` chain that happens
/// to be one limb of a multi-drop net.
///
/// Which terminal a branch serves is decided GEOMETRICALLY when the tree is
/// matched to a net (`placement/guide_branch`), never by the order the
/// branches were authored in: the router's terminal order comes out of
/// flattening and a design author cannot see it.
pub const PlanBranch = struct {
    waypoints: []const PlanWaypoint = &.{},
};

/// A cardinal side of a placed part's courtyard.
pub const PlanGuideSide = enum { north, south, east, west };

/// A placement-relative routing instruction embedded in a `PlanWaypoint`.
/// These keep route plans stable when a part moves: resolution lowers the
/// named pin/part geometry onto the placement grid as ordinary router
/// waypoints.
pub const PlanGuide = union(enum) {
    /// Leave a named pad toward its nearest part edge, one clearance beyond
    /// the pad's copper boundary.
    escape_from: struct {
        ref: []const u8,
        pin: []const u8,
        layer: []const u8,
    },
    /// Route through the midpoint of two named pad centres.
    between_pins: struct {
        from_ref: []const u8,
        from_pin: []const u8,
        to_ref: []const u8,
        to_pin: []const u8,
        layer: []const u8,
    },
    /// Route just outside one named side of a part courtyard.
    beside: struct {
        ref: []const u8,
        side: PlanGuideSide,
        layer: []const u8,
    },
};

/// `(assign-escapes ["LAYER"] ["HUBREF"] [(reserve)])` on a route wave: solve the wave's
/// nets as ONE contended escape rather than routing them one at a time. The
/// resolver hands the wave's net set to `placement/escape_assign`, which finds
/// their shared hub, cuts a corridor cross-section at the tightest constriction
/// they all still fit through, and assigns each net its own parallel lane —
/// then emits the lanes as soft per-net router guides. Both strings are
/// optional overrides: `layer` names the copper face the lanes are drawn on
/// (default: the hub's own side), `hub` names the escape part (default: the
/// part hosting pads of the most nets in the set).
pub const PlanEscapeSpec = struct {
    layer: []const u8 = "",
    hub: []const u8 = "",
    /// `(reserve)`: also RESERVE each assigned lane for its net rather than only
    /// biasing the maze toward it. A soft guide is a cost bonus a later net may
    /// ignore outright, so an assignment survives only until something else
    /// wants the same channel; a reservation is refused to every other net for
    /// the whole run (`placement/lane_reserve`). Off by default — the guides
    /// stay exactly what they are — because a reservation can cost the nets it
    /// excludes, which a guide never can.
    reserve: bool = false,
};

/// The corridor a route wave's nets follow — authored explicitly, or solved.
/// `waypoints` is the ordered `(waypoints (at …))` / `(guides …)` corridor every
/// net of the wave shares; `assign_escapes` is the `(assign-escapes …)` opt-in
/// that lets the joint escape assigner derive a DIFFERENT corridor per net (its
/// own parallel lane) instead; `topology` is the `(topology)` opt-in that has
/// the whole wave's topology planned up front. They compose: a wave may author a
/// shared corridor and still have its escape fan assigned and its topology
/// planned.
pub const PlanWaveCorridor = struct {
    waypoints: []const PlanWaypoint = &.{},
    /// Ordered physical corridor tried only when a net's ordinary broad attempt
    /// fails, and again by post-route residual repair. Unlike ordinary
    /// waypoints, these never replace the broad attempt that runs first.
    repair_waypoints: []const PlanWaypoint = &.{},
    /// Authored `(branches (branch (at …)…)…)`: one hard corridor per limb of a
    /// multi-drop net's guide TREE, all sharing one root terminal. Unlike
    /// `waypoints` — which a multi-terminal net reuses as ONE trunk to every
    /// later terminal — each branch here is its own path, which is what a
    /// shared clock or bus needs and what a single linear corridor cannot say.
    branches: []const PlanBranch = &.{},
    assign_escapes: ?PlanEscapeSpec = null,
    /// Authored `(topology)` on this route wave: work out a route topology for
    /// the whole wave before the maze runs, instead of routing its nets one at a
    /// time and letting the early ones wall in the late ones. The third steering
    /// strategy alongside the two above, and it composes with them the same way.
    /// The plan-level `PcbPlanSpec.topology` turns it on for every route wave at
    /// once. Route-only — a `(topology)` in a place wave is warned and skipped
    /// like any other route selector there.
    topology: bool = false,
    /// Authored `(seed-first)` for a bounded waypoint-only first claim before
    /// the ordinary whole-board route.
    seed_first: bool = false,
};

/// One named routing wave within a PCB plan.
pub const PlanWave = struct {
    name: []const u8,
    reason: ?[]const u8 = null,
    refs: []const []const u8 = &.{},
    sections: []const []const u8 = &.{},
    sub_blocks: []const []const u8 = &.{},
    classes: []const []const u8 = &.{},
    net_classes: []const []const u8 = &.{},
    nets: []const []const u8 = &.{},
    preferred_layers: []const []const u8 = &.{},
    allowed_layers: []const []const u8 = &.{},
    /// How this wave's nets are steered once selected (see `PlanWaveCorridor`).
    corridor: PlanWaveCorridor = .{},
    max_vias: ?u16 = null,
    rest: bool = false,
};

/// The design's ordered PCB-completion plan from a top-level
/// `(pcb-plan (place (wave …)…) (route (wave …)…))` form: `place` waves order
/// part placement, `route` waves order net routing, both in authored order. A
/// later resolution slice turns each wave's selector member names into concrete
/// part/net sets — this struct is the parse-time record only, with no existence
/// checking of the named refs/sections/nets. At most one `(pcb-plan …)` per
/// design (a duplicate is warned and the first kept); the enclosing optional on
/// `DesignBlock.pcb_plan` is null when no plan is authored.
/// How hard the router retries before reporting a net failed, as authored by
/// `(route (effort one-shot|standard) …)`. The DSL-side twin of
/// `route_policy.Effort`; `route_plan` maps between them so the evaluator does
/// not depend on the placement layer.
pub const PlanEffort = enum {
    /// One deterministic pass — a net the maze cannot route fails immediately
    /// with its diagnosis. The mode for an agent or human iterating on the plan.
    one_shot,
    /// Escalate, rip up, re-route, rescue in fine windows (the historical
    /// behaviour, and the default when no `(effort …)` is authored).
    standard,
};

/// The design's ordered PCB-completion plan from a top-level
/// `(pcb-plan (place (wave …)…) (route [(effort …)]
/// [(max-route-seconds N)] (wave …)…))` form: `place` waves order part
/// placement, `route` waves order net routing, both in authored order, and the
/// section-level controls bound how hard and how long the router works. A later
/// resolution slice turns each wave's selector member names into concrete
/// part/net sets — this struct is the parse-time record only, with no existence
/// checking of the named refs/sections/nets. At most one `(pcb-plan …)` per
/// design (a duplicate is warned and the first kept); the enclosing optional on
/// `DesignBlock.pcb_plan` is null when no plan is authored.
pub const PcbPlanSpec = struct {
    place: []const PlanWave = &.{},
    route: []const PlanWave = &.{},
    /// Authored `(route (effort …))`, or null to keep the router's default.
    effort: ?PlanEffort = null,
    /// Authored `(route (max-route-seconds N))`, or null for no wall-clock
    /// deadline. The budget belongs to the whole route transaction, including
    /// its bounded connectivity gate and any candidate comparison.
    max_route_seconds: ?u32 = null,
    /// Authored plan-level `(pcb-plan (topology) …)`: every route wave plans a
    /// global topology, as if each had authored its own `(topology)`. False (no
    /// form) leaves each wave's own flag alone, which is the historical
    /// behaviour — a plan with no `(topology)` anywhere resolves unchanged.
    topology: bool = false,
};

/// The board's solder-mask geometry as ONE rule group — the values a
/// fabricator quotes together and the DRC/Gerber path always reads together
/// (`margin` sets each opening's size, `web` the strip that must survive
/// BETWEEN two openings, and `relief_corner_radius` cleans up an RF opening's
/// termination without changing that web). Carried nested because
/// `DesignRulesSpec` and `DesignRules` are both at their field-count ceiling:
/// grouping these related rules makes room without a cap raise. The two fab
/// dimensions state their defaults at the declaration sites; the optional
/// corner radius has its explicit zero default here.
pub const MaskRules = struct {
    /// Solder-mask opening expansion per pad side (mm).
    margin: f64,
    /// Smallest mask web left between two adjacent openings (mm).
    web: f64,
    /// Fillet radius at an RF mask-relief run where the opening stops at a
    /// component pad dam (mm). Zero preserves the square termination.
    relief_corner_radius: f64 = 0,
};

/// Board-outline spacing rules (mm). Grouped because the design-rule structs
/// intentionally stay below Guardian's field-count ceiling, and these two
/// values describe the same physical boundary:
///   • `copper` — copper feature to finished board edge.
///   • `component` — component courtyard/body proxy to finished board edge.
pub const EdgeRules = struct {
    copper: f64,
    component: f64,
};

/// The board's default via geometry (mm) — the two numbers the `(via DIA
/// DRILL)` sub-form authors together and every consumer reads together.
/// Grouped for the same reason `MaskRules` is: the design-rule structs sit at
/// Guardian's field-count ceiling, so a pair that is already one sub-form
/// becomes one field rather than two.
pub const ViaRules = struct {
    /// Via copper (land) diameter, mm.
    dia: f64,
    /// Via drilled-hole diameter, mm.
    drill: f64,
    /// Minimum finished copper thickness on each plated via wall, mm. Zero in
    /// the authored spec keeps the tool's built-in 25 um assumption.
    plating: f64 = 0,
};

/// Historical power-screen assumption for boards that do not state their
/// fabricator's minimum finished via-wall copper thickness.
pub const default_via_plating_mm: f64 = 0.025;

/// The built-in copper-to-copper spacing (mm) — what
/// `placement/optimizer.DesignRules.clearance` resolves to when no
/// `(design-rules (clearance …))` is authored. Named here, on the layer both
/// sides can see, so the eval layer's parse-time cross-checks compare an
/// authored rule against the *same* number the placement layer will resolve,
/// without the eval→placement import the one-way layering forbids.
pub const default_clearance_mm: f64 = 0.127;

/// The built-in copper-pour isolation gap (mm) for an INNER plane — what
/// `placement/optimizer.DesignRules.pour_clearance` resolves to when no
/// `(design-rules (pour-clearance …))` is authored. Fab-safe by design: it is
/// deliberately looser than `default_clearance_mm`, because an inner plane's
/// antipad is etched blind between two laminated foils, so its boundary is
/// held far less precisely than a drawn trace. It is only the BASE gap — an RF
/// `(net-class …)` still carves its own per-net exceptions over it (a
/// `(ground-gap …)` opening, a solved impedance via antipad), and neither the
/// default nor an authored override touches those.
pub const default_pour_clearance_mm: f64 = 0.3;

/// The built-in copper-pour isolation gap (mm) for a pour on an OUTER copper
/// FACE (F.Cu / B.Cu) — what `PourRules.clearance_outer` resolves to when no
/// `(design-rules (pour-clearance …))` is authored. Held tighter than the
/// inner default because an outer-face pour is photo-defined against finished
/// outer copper exactly as a trace is, not etched as an inner plane's antipad,
/// so its boundary lands where it was drawn; 0.2 still stands well clear of
/// the `default_clearance_mm` (0.127) copper-to-copper floor. The split is
/// between the two DEFAULTS only: one authored `(design-rules (pour-clearance
/// MM))` replaces both.
pub const default_outer_pour_clearance_mm: f64 = 0.2;

/// Board-level manufacturing controls specific to computed copper pours.
pub const PourRules = struct {
    min_width: f64 = 0,
    corner_radius: f64 = 0,
    /// The pour isolation gap (mm) for an OUTER copper face, the twin of
    /// `optimizer.DesignRules.pour_clearance` (which governs inner planes).
    /// It lives on this grouped struct rather than beside its twin because
    /// both design-rule structs sit at Guardian's field-count ceiling — the
    /// same reason `MaskRules` / `EdgeRules` / `ViaRules` are grouped — and a
    /// pour control is exactly what this group holds. Authored by nothing of
    /// its own: `(design-rules (pour-clearance MM))` sets it together with the
    /// inner gap, so a board still tunes its pours through ONE knob.
    clearance_outer: f64 = default_outer_pour_clearance_mm,
    /// Largest permitted centre-to-centre distance from an SMD ground pad to
    /// a same-net through via reaching the ground plane. The check is active
    /// only for nets actually carried by a declared plane.
    ground_via_max: f64 = 1.0,
};
/// Board-level default design rules from a top-level `(design-rules
/// (clearance MM) (min-drill MM) (mask-margin MM)
/// (mask-relief-corner-radius MM) (copper-edge MM)
/// (component-edge MM)
/// (hole-to-hole MM) (min-annular MM))` form. Each sub-form is optional; a
/// zero (unset) field keeps the toolchain's built-in default (see the DRC /
/// Gerber constants). Existing routing and fabrication geometry stays at its
/// legacy value when the form is absent; the component-edge DRC uses its new
/// 2.5 mm assembly default. These are GLOBAL defaults: a per-net
/// `(net-class …)` still overrides width/clearance/via for its own nets, but
/// the extra rules
/// (min-drill, mask-margin, copper-edge, component-edge, hole-to-hole,
/// min-annular) have no
/// per-class equivalent and apply board-wide.
///   • `clearance`   — copper-to-copper spacing (mm); the DRC + router default.
///   • `min_drill`   — smallest legal drilled hole (mm); a via/pad below it flags.
///   • `mask.margin` — solder-mask opening expansion per pad side (mm; Gerber).
///   • `mask.relief_corner_radius` — fillet radius where an RF trace opening
///     terminates against a component pad dam (mm; Gerber + assembly review).
///   • `edge.copper` — copper-to-board-outline clearance (mm; Gerber pullback + DRC).
///   • `edge.component` — component courtyard-to-board-outline clearance (mm; DRC).
///   • `hole_to_hole`— wall-to-wall spacing between two drilled holes (mm; DRC).
///   • `via_to_via`  — copper spacing between two vias of the SAME net (mm; DRC).
///     Unset ⇒ the pair's resolved copper clearance, which flags a near-stacked
///     redundant via without policing a legitimate stitch-fence pitch.
///   • `min_annular` — minimum via annular ring, copper radius − drill radius (mm; DRC).
///   • `mask.web`    — smallest solder-mask web between two adjacent openings (mm; DRC).
///   • `min_width`   — narrowest legal track (mm; DRC — a net-class width still overrides per net).
///   • `pour_clearance` — the BASE copper-pour isolation gap (mm): how far a
///     solid pour keeps from foreign copper. ONE knob for both faces of the
///     board: an authored value governs inner planes AND outer-face pours
///     alike. Unset ⇒ the two differ by layer class — `default_pour_clearance_mm`
///     on an inner plane, `default_outer_pour_clearance_mm` on an outer face.
///     RF classes still carve their own exceptions per net (a `(ground-gap …)`
///     opening, a solved impedance via antipad); this is only the floor for
///     everything else.
///   • `pour.min_width` — narrowest retained copper-pour section (mm).
///   • `pour.corner_radius` — requested copper-pour corner fillet radius (mm).
///   • `pour.ground_via_max` — maximum SMD-ground-pad centre to same-net plane
///     via centre distance (mm); zero leaves the optional rule disabled.
/// `track_width`/`via.dia`/`via.drill` are the board's DEFAULT routing geometry
/// (mm) — the seed for the autorouter's `RouteParams` when no query/panel
/// override is given. A per-net `(net-class …)` still overrides them for its
/// own nets, and an omitted value keeps the router default (track 0.127, via
/// 0.4 ⌀ / 0.2 drill).
pub const DesignRulesSpec = struct {
    clearance: f64 = 0,
    min_drill: f64 = 0,
    mask: MaskRules = .{ .margin = 0, .web = 0, .relief_corner_radius = 0 },
    edge: EdgeRules = .{ .copper = 0, .component = 0 },
    hole_to_hole: f64 = 0,
    via_to_via: f64 = 0,
    min_annular: f64 = 0,
    track_width: f64 = 0,
    via: ViaRules = .{ .dia = 0, .drill = 0, .plating = 0 },
    min_width: f64 = 0,
    pour_clearance: f64 = 0,
    pour: PourRules = .{},
    present: bool = false,
};

/// One historical entry from a `(change "id" "summary")` line inside the
/// `(revision …)` form — the in-file changelog. By convention the list is
/// newest-first and `id` matches the revision the change shipped in.
pub const RevisionChange = struct {
    id: []const u8,
    summary: []const u8,
};

/// Declared design revision from a top-level `(revision "id" (date "…")
/// (change …)…)` form: the canonical, human-meaningful board revision a
/// recipient reads to know which spin of the design they're holding, and
/// the one a designer bumps by hand when cutting a new revision. Distinct
/// from the per-edit snapshot/version history (`/api/history`, the live
/// `/api/version` counter) — those track *every save*; this tracks the
/// deliberate manufacturing revision that belongs on the schematic header,
/// the review doc, and (later) the KiCad title block.
/// `present=false` ⇒ no `(revision …)` form; the design is unversioned.
pub const Revision = struct {
    id: []const u8 = "",
    date: []const u8 = "",
    changes: []const RevisionChange = &.{},
    present: bool = false,
};

/// One named priority group in a `(rough …)` form — a set of parts (by ref-des
/// or module-local origin name) that share a placement priority. Group ORDER in
/// the form body is the priority: the first group is placed first and packs
/// tightest to the anchor IC, later groups fan outward. A group is a priority
/// *tier*, not a spatial cluster — each member still lands on the IC side its
/// pad connects to; the group only sets how close.
pub const RoughGroup = struct {
    /// Author label (the string in `(group "name" …)`); cosmetic, for export.
    name: []const u8 = "",
    /// Member parts in this tier, by ref-des or origin name (matched leniently,
    /// like `(module-policy …)`: exact or by leaf segment after the last `/`).
    members: []const []const u8 = &.{},
};

/// Author-declared rough-placement seed from a top-level `(rough …)` form: the
/// anchor IC everything centres on, plus ordered priority groups telling the
/// rough placer which parts to place first (tightest to the anchor). Consumed by
/// `placement/optimizer.zig`'s `packPadAnchored` in `?rough=1` mode. `present=
/// false` ⇒ none authored, so the rougher uses its most-connected-hub anchor +
/// the pad-count heuristic with no priority ordering.
pub const RoughSpec = struct {
    /// Anchor IC ref-des or origin name (matched leniently). Empty ⇒ the rougher
    /// picks the most-connected hub.
    anchor: []const u8 = "",
    /// Priority groups in descending priority (index 0 = placed first).
    groups: []const RoughGroup = &.{},
    /// Closed-chain member sets whose whole-loop footprint must stay compact.
    critical_loops: []const RoughGroup = &.{},
    present: bool = false,
};

/// Provenance of a `DesignBlock`: a top-level `(design-block …)` root vs the
/// body of an embedded `(defmodule …)` application. The prior `from_module`
/// bool maps to `.embedded`. This is the placement-engine knob for role-based
/// auto-placement — kept distinct from a block's board/subcircuit *role*, which
/// is derived from declared content.
pub const BlockOrigin = enum { design_root, embedded };

/// The fully-evaluated result of a `(design-block …)`: the flattened netlist
/// (instances + nets + ports), the section/sub-block tree, and the design
/// metadata (verifications, rails, functions) the review and diagram layers
/// consume.
pub const DesignBlock = struct {
    name: []const u8,
    instances: []const Instance,
    nets: []const Net,
    ports: []const Port,
    notes: []const Note,
    groups: []const Group,
    sub_blocks: []const SubBlock,
    sections: []const Section = &.{},
    /// Hand-authored functional super-blocks (`(function …)` forms) — the
    /// top-level "what the system does" layer above sections. Empty for
    /// designs that don't author them.
    functions: []const FunctionSpec = &.{},
    /// Provenance: `.embedded` when this block is the body of a `(defmodule …)`
    /// application — a `(sub-block …)` instantiation, a standalone module
    /// preview, or a zero-arg resolve — vs `.design_root` for a top-level
    /// `(design-block …)`. Stamped `.embedded` by `callModule`. Gates role-based
    /// auto-placement (`(placement (auto "REF"))`), which engages for embedded
    /// (module) roots only: a full design's overall arrangement stays the force
    /// solve, while each module it instantiates is laid out around its declared
    /// anchor and composed in.
    origin: BlockOrigin = .design_root,
    /// Defmodule/block-definition name that produced this embedded root.
    /// Unlike `name` (a user-facing design-block title that may be formatted),
    /// this is stable source provenance for module policy and dependency checks.
    /// Empty on top-level designs and test fixtures not evaluated via a module.
    module_name: []const u8 = "",
    /// Net ties for cross-block connections (sub-block port wiring).
    net_ties: []const NetTie = &.{},
    /// Design-side `(verifies …)` sign-offs that answer library requirements
    /// the netlist alone can't verify.
    verifications: []const Verification = &.{},
    /// Derived power rails, populated by `eval/rails.build` at the tail of
    /// `evalDesignBlock`. Empty for blocks with no regulator sub-blocks or
    /// board-edge power ports.
    rails: []const PowerRail = &.{},
    /// Worst-case DC voltage envelopes per FLAT net name, populated by
    /// `eval/net_envelopes.build`. Separate from `rails` on purpose: a rail is
    /// a node in the supply tree (it gets a test point, a current budget, a PDN
    /// screen), while an envelope is only "what potential does copper on this
    /// net reach", which is also true of a filtered pin node and of a signal
    /// whose driver the author declared.
    net_envelopes: []const NetEnvelope = &.{},
    /// Author-pinned placement classes from `(module-policy (net-class …))`,
    /// consulted before the name heuristic by the placer, the ERC info row and
    /// the describe facts. Named like envelopes: the flattened net name, or a
    /// bare leaf that matches any module-local net of that name.
    net_class_pins: []const NetClassPin = &.{},
    /// Explicit AC target-impedance intent. This stays separate from `rails`
    /// because those entries intentionally union ferrite-connected nets for
    /// DC budgeting while a ferrite is an AC element/domain boundary.
    pdn_intents: []const PdnIntent = &.{},
    /// Test points declared via the first-class `(test-point …)` form,
    /// including physical declarations and explicit `(virtual)` markers.
    /// Legacy `(instance "TP1" testpoint …)` instances remain recognised too.
    test_points: []const TestPoint = &.{},
    /// Absolute path to the `.kicad_pcb` this design pushes board updates
    /// to, declared via `(kicad-pcb "<path>")` in the design source. Null
    /// when the design has no PCB target — the file-based KiCad sync
    /// endpoint refuses to write without it.
    kicad_pcb_path: ?[]const u8 = null,
    /// Placeholder parts declared via top-level `(stub …)` forms — sketched
    /// components with a bounding box and named signals but no real library
    /// footprint yet. They render as diagram nodes and export as pad-less KiCad
    /// outlines. Empty for designs with no `(stub …)` forms.
    parts: []const PlaceholderPart = &.{},
    /// Declarative Mermaid-style layout from a top-level `(layout …)` form. Its
    /// `(place …)` directives position diagram blocks relative to one another;
    /// the diagram's `computeFreeLayout` resolves them into a free-floating view.
    /// Empty `placements` ⇒ no layout declared, so the category-column views stand.
    layout: LayoutSpec = .{},
    /// Physical board outline + edge-docked connectors + corner mounting
    /// hardware from a top-level `(board …)` form. `present=false` ⇒ none
    /// authored — the layout stays an unbounded part cluster.
    board: BoardSpec = .{},
    /// Declared board revision from a top-level `(revision …)` form — the
    /// canonical human-meaningful spin id (+ optional date + in-file
    /// changelog). `present=false` ⇒ the design declares no revision.
    revision: Revision = .{},
    /// Author-declared rough-placement seed from a top-level `(rough …)` form:
    /// the anchor IC + ordered priority groups the rough placer (`?rough=1`)
    /// honours. `present=false` ⇒ the rougher uses its heuristic defaults.
    rough: RoughSpec = .{},
    /// Copper stack from a top-level `(stackup …)` form. `present=false` ⇒
    /// legacy implicit model (4 layers; the router assumes a ground plane and a
    /// dominant-supply-rail plane — see `placement/implicit_plane.zig`).
    stackup: StackupSpec = .{},
    /// External adhesive/stiffener artwork, emitted as optional Gerbers and
    /// intentionally excluded from the electrical PCB stackup thickness.
    fabrication_layers: []const FabricationLayerSpec = &.{},
    /// Routing rules from top-level `(net-class …)` forms, in authored order.
    /// The first class naming a net wins when two overlap.
    net_classes: []const NetClassSpec = &.{},
    /// Board-level default design rules from a top-level `(design-rules …)`
    /// form. `present=false` ⇒ none authored — every rule falls back to the
    /// toolchain's built-in constant so existing designs are unchanged.
    design_rules: DesignRulesSpec = .{},
    /// Ordered PCB-completion plan from a top-level `(pcb-plan …)` form: the
    /// place-then-route wave order a later resolution slice turns into concrete
    /// part/net member sets. Null ⇒ no plan authored.
    pcb_plan: ?PcbPlanSpec = null,
};

/// Assertion result.
pub const AssertionResult = struct {
    passed: bool,
    message: []const u8,
    is_warning: bool = false,
    /// True when the evaluator owns a dynamically formatted message and must
    /// release it during deinit. Source-backed assertion strings stay false.
    message_owned: bool = false,
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

    pub fn put(self: *Env, name: []const u8, value: Value) std.mem.Allocator.Error!void {
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

// spec: fab_readiness - Declared plane-carried ground nets default to a 1 mm maximum SMD-pad-to-stitch-via distance
test "ground via distance protection is enabled by default" {
    try std.testing.expectEqual(@as(f64, 1.0), (PourRules{}).ground_via_max);
}
