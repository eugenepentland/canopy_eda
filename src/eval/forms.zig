//! The evaluator's form-dispatch tables: the `SpecialForm`, `Builtin`, and
//! `ScopeForm` enums (each head atom -> variant) plus their arity/scope schemas.
//! One central mapping so a typo'd head is a lookup miss, not a silent no-op.
//! These registries are what `docgen.zig` reads to generate the language
//! reference — an undocumented variant is a compile error.

const std = @import("std");
const board_layers = @import("../board_layers.zig");

/// The top copper face as the DSL reference spells it: QUOTED, because every
/// layer slot in a `(pcb-plan …)` form takes a quoted layer name. Derived from
/// the layer table so the documented example names a layer the board model has.
const doc_f_cu = "\"" ++ board_layers.f_cu ++ "\"";

/// Top-level special form recognised by `evalForm`. Each variant
/// corresponds to a head atom in the S-expression source. Keeping the
/// mapping in one table makes typo-style bugs ("difmodule" silently
/// becoming an unbound-variable lookup) impossible and turns every
/// dispatch site into a `switch` Zig can check for exhaustiveness.
pub const SpecialForm = enum {
    let,
    repeat,
    if_,
    import,
    defmodule,
    design_block,
    block,
    assert_,
    assert_range,
    fmt_,
    id_,
    implements,

    pub fn fromAtom(name: []const u8) ?SpecialForm {
        return atom_to_form.get(name);
    }

    /// The source spelling of this form's head atom — used by arity/type
    /// diagnostics so the message names the offending form. Derived from
    /// the registry table so the two can never drift.
    pub fn sourceName(self: SpecialForm) []const u8 {
        for (atom_to_form.keys(), atom_to_form.values()) |k, v| {
            if (v == self) return k;
        }
        return "?";
    }
};

const atom_to_form = std.StaticStringMap(SpecialForm).initComptime(.{
    .{ "let", .let },
    .{ "repeat", .repeat },
    .{ "if", .if_ },
    .{ "import", .import },
    .{ "defmodule", .defmodule },
    .{ "design-block", .design_block },
    .{ "block", .block },
    .{ "assert", .assert_ },
    .{ "assert-range", .assert_range },
    .{ "fmt", .fmt_ },
    .{ "id", .id_ },
    .{ "implements", .implements },
});

/// Arithmetic, comparison, and logic builtin operators. Recognising
/// these via the enum (rather than a name-matching ladder) lets the
/// evaluator skip building the eval-args list for non-builtins and
/// keeps the operator table in one place.
pub const Builtin = enum {
    add,
    sub,
    mul,
    div,
    mod,
    gt,
    gte,
    lt,
    lte,
    eq,
    neq,
    and_,
    or_,
    not_,
    e96,

    pub fn fromAtom(name: []const u8) ?Builtin {
        return atom_to_builtin.get(name);
    }
};

const atom_to_builtin = std.StaticStringMap(Builtin).initComptime(.{
    .{ "+", .add },
    .{ "-", .sub },
    .{ "*", .mul },
    .{ "/", .div },
    .{ "%", .mod },
    .{ ">", .gt },
    .{ ">=", .gte },
    .{ "<", .lt },
    .{ "<=", .lte },
    .{ "==", .eq },
    .{ "!=", .neq },
    .{ "and", .and_ },
    .{ "or", .or_ },
    .{ "not", .not_ },
    .{ "e96", .e96 },
});

/// Forms that may appear inside a `(design-block …)`, a `(section …)`,
/// or a nested sub-section. The three scopes overlap heavily; declaring
/// the set once lets `design_block.zig` switch on a single enum in each
/// scope (instead of maintaining three near-duplicate if/else ladders),
/// which gives Zig exhaustiveness checking and lets a typo like
/// `(noet …)` fall through silently rather than half-eval an unbound
/// variable.
pub const ScopeForm = enum {
    // Forms shared by every scope (also valid at top level)
    instance,
    port,
    bus_port,
    note,
    section,
    decouple,
    series,
    fanout,
    net,
    bus_net,
    pullup,
    pulldown,
    divider,
    led,
    // Section / sub-section only
    pins,
    protocol,
    calc,
    description,
    role,
    diagram,
    hosts,
    category,
    // Top-level only (design-block scope)
    group,
    function,
    sub_block,
    verifies,
    test_point,
    decouple_defaults,
    kicad_pcb,
    stub,
    layout,
    board,
    board_role,
    power_plane,
    revision,
    rough,
    stackup,
    pdn,
    fabrication_layer,
    net_class,
    design_rules,
    pcb_plan,

    pub fn fromAtom(name: []const u8) ?ScopeForm {
        return atom_to_scope_form.get(name);
    }
};

const atom_to_scope_form = std.StaticStringMap(ScopeForm).initComptime(.{
    .{ "instance", .instance },
    .{ "port", .port },
    .{ "bus-port", .bus_port },
    .{ "note", .note },
    .{ "section", .section },
    .{ "decouple", .decouple },
    .{ "series", .series },
    .{ "fanout", .fanout },
    .{ "net", .net },
    .{ "bus-net", .bus_net },
    .{ "pullup", .pullup },
    .{ "pulldown", .pulldown },
    .{ "divider", .divider },
    .{ "led", .led },
    .{ "pins", .pins },
    .{ "protocol", .protocol },
    .{ "calc", .calc },
    .{ "description", .description },
    .{ "role", .role },
    .{ "diagram", .diagram },
    .{ "hosts", .hosts },
    .{ "category", .category },
    .{ "group", .group },
    .{ "function", .function },
    .{ "sub-block", .sub_block },
    .{ "verifies", .verifies },
    .{ "test-point", .test_point },
    .{ "decouple-defaults", .decouple_defaults },
    .{ "kicad-pcb", .kicad_pcb },
    .{ "stub", .stub },
    // `diagram-layout` is the canonical (and only) name for the schematic
    // block-diagram arrangement; the word "layout" alone means PCB placement.
    .{ "diagram-layout", .layout },
    .{ "board", .board },
    .{ "board-role", .board_role },
    .{ "power-plane", .power_plane },
    .{ "revision", .revision },
    .{ "rough", .rough },
    .{ "stackup", .stackup },
    .{ "pdn", .pdn },
    .{ "fabrication-layer", .fabrication_layer },
    .{ "net-class", .net_class },
    .{ "design-rules", .design_rules },
    .{ "pcb-plan", .pcb_plan },
});

// ── Schema ─────────────────────────────────────────────────────────────
// One table declares the arity of every form whose grammar is fixed
// enough to validate up front. The cap (`max_args = null` means
// unbounded) is intentionally generous — these aren't full type
// signatures, just the shape the evaluator can pre-check before
// dispatch. Adding coverage is one entry per form.

/// Arity contract for a single form. `null` for `max_args` means the
/// form accepts arbitrarily many children (e.g. `cond`, `fmt`).
pub const FormSchema = struct {
    min_args: u8,
    max_args: ?u8,
};

/// Schemas for the special forms. The evaluator routes through
/// `SpecialForm.fromAtom` first, then calls `validateArity` with the
/// matching schema before evaluating the body. Forms not listed
/// (e.g. `id`, which the evaluator short-circuits to `.nil`) skip
/// arity checking.
pub const special_form_schema = blk: {
    const Pair = struct { SpecialForm, FormSchema };
    const pairs = [_]Pair{
        .{ .let, .{ .min_args = 2, .max_args = 2 } },
        .{ .repeat, .{ .min_args = 4, .max_args = null } },
        .{ .if_, .{ .min_args = 3, .max_args = 3 } },
        .{ .import, .{ .min_args = 1, .max_args = null } },
        .{ .defmodule, .{ .min_args = 2, .max_args = null } },
        .{ .design_block, .{ .min_args = 1, .max_args = null } },
        .{ .block, .{ .min_args = 1, .max_args = null } },
        .{ .assert_, .{ .min_args = 2, .max_args = 2 } },
        .{ .assert_range, .{ .min_args = 4, .max_args = 4 } },
        .{ .fmt_, .{ .min_args = 1, .max_args = null } },
        .{ .implements, .{ .min_args = 1, .max_args = null } },
    };
    var table: [@typeInfo(SpecialForm).@"enum".field_names.len]?FormSchema = @splat(null);
    for (pairs) |p| table[@backingInt(p[0])] = p[1];
    break :blk table;
};

/// Look up the schema for a special form. Returns `null` when no
/// arity contract is declared (only `.id_` is unconstrained).
pub fn schemaFor(sf: SpecialForm) ?FormSchema {
    return special_form_schema[@backingInt(sf)];
}

/// Reported when `validateArity` rejects a form. `got` is the actual
/// argument count; `schema` is the contract it failed to meet. Callers
/// use this to render diagnostics like
/// `let takes 2 args, got 3 at sexp:42:7`.
pub const ArityViolation = struct {
    schema: FormSchema,
    got: usize,
};

/// Returns the violation when `arg_count` is outside the schema's
/// [min_args, max_args] range, or null when the call is in-bounds.
/// Callers convert violations to their preferred error (e.g.
/// `EvalError.ArityError`) with a span attached for diagnostics.
pub fn validateArity(schema: FormSchema, arg_count: usize) ?ArityViolation {
    if (arg_count < schema.min_args) return .{ .schema = schema, .got = arg_count };
    if (schema.max_args) |max| {
        if (arg_count > max) return .{ .schema = schema, .got = arg_count };
    }
    return null;
}

// ── Documentation tables ───────────────────────────────────────────────
// `src/docgen.zig` walks these tables to emit `docs/language-forms.md`.
// Keeping the syntax + one-line description next to the enum variants
// (rather than in a separate markdown file) means a new form can't be
// added without also documenting it — `requireAllDocumented` turns a
// missing row into a compile error naming the undocumented variant.

/// One row of the generated reference. `syntax` is the source-form
/// template a human would write; `summary` is a one-line description.
pub const FormDoc = struct {
    syntax: []const u8,
    summary: []const u8,
};

/// Comptime-unwrap an optional-element doc table, turning any variant
/// that was never assigned a row into a compile error naming it. This is
/// what makes the doc tables exhaustive *by construction*: adding an enum
/// variant without documenting it stops the build.
pub fn requireAllDocumented(
    comptime E: type,
    comptime T: type,
    comptime table: [@typeInfo(E).@"enum".field_names.len]?T,
) [@typeInfo(E).@"enum".field_names.len]T {
    var out: [table.len]T = undefined;
    for (table, 0..) |entry, i| {
        out[i] = entry orelse @compileError("missing doc-table row for " ++
            @typeName(E) ++ "." ++ @typeInfo(E).@"enum".field_names[i] ++
            " — every form must be documented (see docs/language-forms.md)");
    }
    return out;
}

pub const special_form_docs = blk: {
    const N = @typeInfo(SpecialForm).@"enum".field_names.len;
    var t: [N]?FormDoc = @splat(null);
    t[@backingInt(SpecialForm.let)] = .{
        .syntax = "(let name expr)",
        .summary = "Bind `name` to the evaluated value of `expr` in the current scope.",
    };
    t[@backingInt(SpecialForm.repeat)] = .{
        .syntax = "(repeat name start end body… [(id hex8)] [(ids (\"origin@index\" hex8)…)])",
        .summary = "Evaluate `body` once per integer from `start` through `end`, inclusive, " ++
            "with `name` bound in a fresh lexical scope for each iteration. The optional IDs sidecar " ++
            "pins migrated child identities; otherwise they derive from origin key + index.",
    };
    t[@backingInt(SpecialForm.if_)] = .{
        .syntax = "(if cond then else)",
        .summary = "Short-circuit conditional. Only the matching branch is evaluated.",
    };
    t[@backingInt(SpecialForm.import)] = .{
        .syntax = "(import name…)",
        .summary = "Load library components or modules by name. Searches `lib/components/` then `lib/modules/`.",
    };
    t[@backingInt(SpecialForm.defmodule)] = .{
        .syntax = "(defmodule name (param | (param default)…) [\"docstring\"] body…)",
        .summary = "Define a parameterised module that closes over the surrounding env. " ++
            "A `(param default)` pair makes the argument optional — its default evaluates at " ++
            "call time when omitted, so a fully-defaulted module also renders standalone.",
    };
    t[@backingInt(SpecialForm.design_block)] = .{
        .syntax = "(design-block \"name\" form…)",
        .summary = "The root container — every `.sexp` design file evaluates to one.",
    };
    t[@backingInt(SpecialForm.block)] = .{
        .syntax = "(block \"name\" form… | name (param | (param default)…) [\"docstring\"] body…)",
        .summary = "The unified circuit definition. A string name is an eager design root " ++
            "(identical to `(design-block …)`); a bare-atom name with a parameter list is a " ++
            "parameterised, embeddable definition (identical to `(defmodule …)`). " ++
            "`(design-block …)` and `(defmodule …)` remain as permanent aliases.",
    };
    t[@backingInt(SpecialForm.assert_)] = .{
        .syntax = "(assert cond \"message\")",
        .summary = "Record a pass/fail entry. Failures surface in the review report, never aborts the build.",
    };
    t[@backingInt(SpecialForm.assert_range)] = .{
        .syntax = "(assert-range value lo hi \"label\")",
        .summary = "Record an assertion that `value` is in `[lo, hi]`, with a formatted diagnostic.",
    };
    t[@backingInt(SpecialForm.fmt_)] = .{
        .syntax = "(fmt \"template\" args…)",
        .summary = "Format a string. See the “String formatting directives” table for the `~X` specifiers.",
    };
    t[@backingInt(SpecialForm.id_)] = .{
        .syntax = "(id <hex8>)",
        .summary = "Stable 8-char identifier auto-inserted by the build. Evaluator short-circuits to `.nil`.",
    };
    t[@backingInt(SpecialForm.implements)] = .{
        .syntax = "(implements component [(policy canonical|recommended|example)] [(role name)])",
        .summary = "Declare that the enclosing module implements a primary component. " ++
            "Canonical implementations prohibit direct board instantiation; recommended " ++
            "implementations warn; examples are discovery-only.",
    };
    break :blk requireAllDocumented(SpecialForm, FormDoc, t);
};

pub const builtin_docs = blk: {
    const N = @typeInfo(Builtin).@"enum".field_names.len;
    var t: [N]?FormDoc = @splat(null);
    t[@backingInt(Builtin.add)] = .{ .syntax = "(+ a b)", .summary = "Numeric addition." };
    t[@backingInt(Builtin.sub)] = .{ .syntax = "(- a b)", .summary = "Numeric subtraction." };
    t[@backingInt(Builtin.mul)] = .{ .syntax = "(* a b)", .summary = "Numeric multiplication." };
    t[@backingInt(Builtin.div)] = .{ .syntax = "(/ a b)", .summary = "Numeric division. Errors on divide-by-zero." };
    t[@backingInt(Builtin.mod)] = .{ .syntax = "(% a b)", .summary = "Numeric modulo. Errors on divide-by-zero." };
    t[@backingInt(Builtin.gt)] = .{ .syntax = "(> a b)", .summary = "Numeric greater-than → boolean." };
    t[@backingInt(Builtin.gte)] = .{ .syntax = "(>= a b)", .summary = "Numeric greater-or-equal → boolean." };
    t[@backingInt(Builtin.lt)] = .{ .syntax = "(< a b)", .summary = "Numeric less-than → boolean." };
    t[@backingInt(Builtin.lte)] = .{ .syntax = "(<= a b)", .summary = "Numeric less-or-equal → boolean." };
    t[@backingInt(Builtin.eq)] = .{
        .syntax = "(== a b)",
        .summary = "Equality, defined for number-number and string-string.",
    };
    t[@backingInt(Builtin.neq)] = .{
        .syntax = "(!= a b)",
        .summary = "Inequality, defined for number-number and string-string.",
    };
    t[@backingInt(Builtin.and_)] = .{ .syntax = "(and a b)", .summary = "Boolean and (eager — both args evaluated)." };
    t[@backingInt(Builtin.or_)] = .{ .syntax = "(or a b)", .summary = "Boolean or (eager — both args evaluated)." };
    t[@backingInt(Builtin.not_)] = .{ .syntax = "(not a)", .summary = "Boolean negation." };
    t[@backingInt(Builtin.e96)] = .{ .syntax = "(e96 r)", .summary = "Snap a resistance/number to the nearest E96 (1%) standard value." };
    break :blk requireAllDocumented(Builtin, FormDoc, t);
};

/// Which scopes accept each `ScopeForm` variant. The set drives the
/// scope-availability column in the generated reference.
pub const ScopeAvailability = packed struct {
    design_block: bool,
    section: bool,
    sub_section: bool,
};

/// A design-scope form's doc row plus the scopes that accept it.
pub const ScopedFormDoc = struct { doc: FormDoc, scope: ScopeAvailability };

pub const scope_form_docs = blk: {
    const N = @typeInfo(ScopeForm).@"enum".field_names.len;
    var t: [N]?ScopedFormDoc = @splat(null);

    const all = ScopeAvailability{ .design_block = true, .section = true, .sub_section = true };
    const dsec = ScopeAvailability{ .design_block = false, .section = true, .sub_section = true };
    const tl = ScopeAvailability{ .design_block = true, .section = false, .sub_section = false };
    const sec = ScopeAvailability{ .design_block = false, .section = true, .sub_section = false };

    t[@backingInt(ScopeForm.instance)] = .{ .scope = all, .doc = .{
        .syntax = "(instance \"REF\" component pin… [(power WATTS | (typ WATTS) (max WATTS))])",
        .summary = "Place a component with inline pin-to-net bindings. `(power …)` states what " ++
            "this part dissipates, for the thermal screening — see “Thermal declarations”.",
    } };
    t[@backingInt(ScopeForm.port)] = .{ .scope = all, .doc = .{
        .syntax = "(port \"name\" [net] dir [kind] [(rated lo hi)] [(side left|right|top|bottom)])",
        .summary = "Declare a block boundary signal. A power/rf port's direction (or an explicit (side …)) tells the PCB " ++
            "rough placer where the net enters/leaves the module — in → left, out → right.",
    } };
    t[@backingInt(ScopeForm.bus_port)] = .{ .scope = all, .doc = .{
        .syntax = "(bus-port \"prefix\" width dir …)",
        .summary = "Declare a multi-bit boundary bus that expands to one port per lane.",
    } };
    t[@backingInt(ScopeForm.note)] = .{ .scope = all, .doc = .{
        .syntax = "(note \"id\" \"text\" [(ref …)])",
        .summary = "Attach a design-time note to the surrounding scope.",
    } };
    t[@backingInt(ScopeForm.section)] = .{ .scope = all, .doc = .{
        .syntax = "(section \"name\" [\"subtitle\"] form…)",
        .summary = "Functional subsystem card. Inside `(section …)` nests one level into a sub-section.",
    } };
    t[@backingInt(ScopeForm.decouple)] = .{ .scope = all, .doc = .{
        .syntax = "(decouple \"NET\" [(comp \"val\")] COUNT per-pin [REF|auto] PIN…)",
        .summary = "Emit COUNT decoupling caps per listed host pin. Component and REF may come from " ++
            "(decouple-defaults …); a trailing `auto` expands to the pins already declared on the net.",
    } };
    t[@backingInt(ScopeForm.series)] = .{ .scope = all, .doc = .{
        .syntax = "(series …)",
        .summary = "Insert a series element (resistor / ferrite / etc.) between two nets.",
    } };
    t[@backingInt(ScopeForm.fanout)] = .{ .scope = all, .doc = .{
        .syntax = "(fanout \"COMMON\" (comp) \"NET1\" \"NET2\" … [(id …)])",
        .summary = "Place one component from a shared COMMON net to each listed net (star of series elements).",
    } };
    t[@backingInt(ScopeForm.net)] = .{ .scope = all, .doc = .{
        .syntax = "(net \"A\" \"B\" …)",
        .summary = "Tie one or more nets to a canonical name (net-merge).",
    } };
    t[@backingInt(ScopeForm.bus_net)] = .{ .scope = all, .doc = .{
        .syntax = "(bus-net \"PREFIX\" lo hi \"SUB\") | (bus-net \"PREFIX\" lo hi (suffix \"S\") (over \"SUB\" (port-base \"P\" N)))",
        .summary = "Tie a lane range to a sub-block bus, including an optional parent suffix and offset child-port family.",
    } };
    t[@backingInt(ScopeForm.pullup)] = .{ .scope = all, .doc = .{
        .syntax = "(pullup \"SIGNAL\" VALUE \"RAIL\")",
        .summary = "Emit a resistor from a signal to a positive rail, retaining pull-up intent.",
    } };
    t[@backingInt(ScopeForm.pulldown)] = .{ .scope = all, .doc = .{
        .syntax = "(pulldown \"SIGNAL\" VALUE [\"RETURN\"])",
        .summary = "Emit a resistor from a signal to GND (or an explicit return), retaining pull-down intent.",
    } };
    t[@backingInt(ScopeForm.divider)] = .{ .scope = all, .doc = .{
        .syntax = "(divider \"VIN\" \"TAP\" \"RETURN\" R_TOP R_BOTTOM [(expect V TOLERANCE)])",
        .summary = "Emit a two-resistor divider and optionally assert its calculated tap voltage.",
    } };
    t[@backingInt(ScopeForm.led)] = .{ .scope = all, .doc = .{
        .syntax = "(led \"NAME\" \"SUPPLY\" COLOR (r VALUE) [(return \"NET\")])",
        .summary = "Emit a series resistor and LED indicator with semantic labels.",
    } };

    t[@backingInt(ScopeForm.pins)] = .{ .scope = all, .doc = .{
        .syntax = "(pins \"REF\" (group \"label\") pin-form…)",
        .summary = "Group a main-IC's pin assignments under a sub-section.",
    } };
    t[@backingInt(ScopeForm.protocol)] = .{ .scope = dsec, .doc = .{
        .syntax = "(protocol atom)",
        .summary = "Tag a section with a protocol keyword (e.g. `usb`, `i2c`).",
    } };
    t[@backingInt(ScopeForm.calc)] = .{ .scope = dsec, .doc = .{
        .syntax = "(calc …)",
        .summary = "Inline design math block, surfaced in the review report.",
    } };
    t[@backingInt(ScopeForm.description)] = .{ .scope = dsec, .doc = .{
        .syntax = "(description \"text\")",
        .summary = "One-line section description used in the review report and overview SVG.",
    } };

    t[@backingInt(ScopeForm.role)] = .{ .scope = sec, .doc = .{
        .syntax = "(role input|output)",
        .summary = "Tag a section as a block input or output for the overview diagram.",
    } };
    t[@backingInt(ScopeForm.diagram)] = .{ .scope = sec, .doc = .{
        .syntax = "(diagram hidden)",
        .summary = "Opt this section out of the block-diagram view (schematic card still renders).",
    } };
    t[@backingInt(ScopeForm.hosts)] = .{ .scope = sec, .doc = .{
        .syntax = "(hosts \"sub1\" \"sub2\" …)",
        .summary = "Fold the named sub-blocks into this section's block-diagram node (explicit attachment).",
    } };
    t[@backingInt(ScopeForm.category)] = .{ .scope = sec, .doc = .{
        .syntax = "(category <key>)",
        .summary = "Set this section's diagram category (e.g. mcu, power, rf), overriding the name heuristic.",
    } };

    t[@backingInt(ScopeForm.group)] = .{ .scope = tl, .doc = .{
        .syntax = "(group \"name\" (\"R1\" \"R2\" …))",
        .summary = "Bundle ref-des components for the schematic renderer's visual grouping pass. " ++
            "Members are a LIST of ref-des strings. NOTE: a different, unrelated (group …) form " ++
            "lives inside (diagram-layout …) — there it takes variadic block keys (section names / " ++
            "sub-block handles), e.g. (group \"Label\" \"Block A\" \"Block B\" …), to cluster " ++
            "diagram blocks; that one is parsed inline by the layout form, not this registry entry.",
    } };
    t[@backingInt(ScopeForm.function)] = .{ .scope = tl, .doc = .{
        .syntax = "(function \"name\" [\"caption\"] [(stack N)] (hosts \"Section A\" \"Section B\" …))",
        .summary = "Hand-authored functional super-block for the top-level system view: groups the " ++
            "named sections/sheets into one what-it-does block (caption = verb/spec line, " ++
            "stack N = ×N identical channels). The functional schematic draws these as its outermost grouping.",
    } };
    t[@backingInt(ScopeForm.sub_block)] = .{ .scope = all, .doc = .{
        .syntax = "(sub-block \"name\" (module-call args…))",
        .summary = "Instantiate a parameterised module inside the design. Its parts flatten into " ++
            "the netlist under the sub-block path prefix and the PCB solver places them with the " ++
            "rest of the board.",
    } };
    t[@backingInt(ScopeForm.verifies)] = .{ .scope = tl, .doc = .{
        .syntax = "(verifies (req \"REF\" REQID) [rationale])",
        .summary = "Mark a requirement as satisfied by a specific instance.",
    } };
    t[@backingInt(ScopeForm.test_point)] = .{ .scope = all, .doc = .{
        .syntax = "(test-point \"REF\" \"NET\" [(virtual)] [(purpose \"text\")] [(required-for tag…)])",
        .summary = "Place a physical measurement / bring-up pad. Add `(virtual)` for a schematic-only marker.",
    } };
    t[@backingInt(ScopeForm.decouple_defaults)] = .{ .scope = tl, .doc = .{
        .syntax = "(decouple-defaults (ic \"REF\") (bypass (comp)))",
        .summary = "Set per-design decouple defaults: a fallback IC ref and bypass cap so (decouple …) can omit both.",
    } };
    t[@backingInt(ScopeForm.kicad_pcb)] = .{ .scope = tl, .doc = .{
        .syntax = "(kicad-pcb \"absolute/path/to/board.kicad_pcb\")",
        .summary = "Declare the PCB file the file-based KiCad sync writes board updates to.",
    } };
    t[@backingInt(ScopeForm.stub)] = .{ .scope = tl, .doc = .{
        .syntax = "(stub \"name\" [(role …)] [(mpn …)] [(category key)] [(size W H)] [(channels N)] [(ref \"REF\")] (signal \"name\" class \"net\")…)",
        .summary = "Declare a placeholder part — auto-placed, sized bounding box, signal-wired, optionally " ++
            "N stacked channels — for design-phase diagrams before a real component exists.",
    } };
    t[@backingInt(ScopeForm.layout)] = .{ .scope = tl, .doc = .{
        .syntax = "(diagram-layout (anchor \"name\") (place \"name\" (right-of|left-of|above|below \"ref\"))…)",
        .summary = "Position blocks relative to one another on the SCHEMATIC block diagram " ++
            "(Mermaid-style, free-floating) — nothing to do with PCB placement, which is " ++
            "the force / rough solver on /pcb-layout.",
    } };
    t[@backingInt(ScopeForm.board)] = .{ .scope = tl, .doc = .{
        .syntax = "(board (size W H) [(corner-radius R)] " ++
            "[(perimeter-fence (via DIA DRILL) (spacing PITCH) (edge-offset OFFSET) (mask-width WIDTH) [(net \"GND\")] " ++
            "[(keepout CLEARANCE [(blocks components tracks vias)] [(allow-nets \"NET\"…)])])] " ++
            "(left|right|top|bottom \"REF\"… | (rot N \"REF\")…)… [(corners \"REF\"…)])",
        .summary = "Physical board outline + edge hardware: (size W H) is the outline in mm " ++
            "(required — without it the form is inert). (corner-radius R) rounds the outline's " ++
            "corners with radius R mm — the shape flows to " ++ board_layers.edge_cuts ++
            ", the board-edge DRC, and " ++
            "every renderer as a fine polyline. (perimeter-fence …) generates plated vias " ++
            "around that exact outline; DIA and DRILL set their finished diameter and hole, " ++
            "PITCH is their nominal centre spacing, OFFSET is the via-centre distance from the " ++
            "finished edge, and WIDTH removes solder mask inward from the edge only on a face carrying a matching GND pour (" ++ board_layers.f_mask ++
            " / " ++ board_layers.b_mask ++ "). Component bodies/courtyards do not interrupt the derived edge hardware: " ++
            "pad proximity is the only component-derived reason to suppress a fence via, and its annulus stays at least 0.2 mm " ++
            "from the pad. Each face's mask opening retains solder mask over foreign pads, tracks, vias, and the GND pour " ++
            "clearance around them. Ordinary copper and drill DRC legality still applies to every via. The fence net defaults to GND. " ++
            "(keepout CLEARANCE …) reserves a visible " ++
            "band beyond the vias' inward copper edge; (blocks …) chooses whether components, " ++
            "tracks, and/or vias are forbidden there (all three by default), while (allow-nets …) " ++
            "admits named copper such as GND. Each (left|right|top|bottom …) list " ++
            "docks those parts flush INSIDE that board edge (the words name physical edges, " ++
            "not sides of an anchor), slid along the edge toward the pads they connect to; " ++
            "(rot N \"REF\") overrides the default pads-inward rotation. (corners …) pins " ++
            "mounting hardware at the four corners (TL, TR, BR, BL in authored order). " ++
            "The force-solved interior placement is centered in the outline; the rendered " ++
            "views draw the outline rectangle.",
    } };
    t[@backingInt(ScopeForm.board_role)] = .{ .scope = tl, .doc = .{
        .syntax = "(board-role board|subcircuit)",
        .summary = "Explicitly declare whether this design is a fabricable BOARD or a reusable " ++
            "SUBCIRCUIT — drives the home page's Board/Subcircuit role tag + filter. The role is " ++
            "explicit, not auto-detected: a design with no (board-role …) form defaults to " ++
            "subcircuit, so a fabricable board must declare (board-role board). Independent of " ++
            "(board …) (physical outline) and (kicad-pcb …) (sync target), which keep their own " ++
            "jobs and no longer influence the role.",
    } };
    t[@backingInt(ScopeForm.power_plane)] = .{ .scope = tl, .doc = .{
        .syntax = "(power-plane on|off)",
        .summary = "Choose whether a subcircuit uses supply planes. Off routes supply rails as ordinary copper " ++
            "while retaining every ground plane and the physical stackup: it suppresses the implicit dominant-supply " ++
            "plane or any authored non-ground (plane …) entries. On restores the planes declared in source.",
    } };
    t[@backingInt(ScopeForm.rough)] = .{ .scope = tl, .doc = .{
        .syntax = "(rough [(anchor \"REF\")] (group \"name\" \"REF\"…)… (critical-loop \"name\" \"REF\"…)…)",
        .summary = "Author the rough-placement seed (the `?rough=1` / \"Rough\" button on /pcb-layout): " ++
            "(anchor …) names the IC everything centres on (default: the most-connected hub), and each " ++
            "(group …) is a priority TIER in descending order — the first group is placed first and " ++
            "packs tightest to the anchor, later groups fan outward. A group sets priority, not " ++
            "position: every member still lands on the IC side its pad connects to (GND ignored), so " ++
            "a bypass cap sits by its VDD pad and a pull resistor by its signal pad. Parts in no " ++
            "group are placed last. A (critical-loop …) keeps a complete feedback/hot-loop member set " ++
            "compact on one anchor edge and adds its aggregate span to candidate selection. Refs match " ++
            "by ref-des or module-local origin name (exact or leaf).",
    } };
    t[@backingInt(ScopeForm.stackup)] = .{ .scope = tl, .doc = .{
        .syntax = "(stackup N|\"PRESET\" [(plane IDX \"NET\")…] [(pour top|bottom \"NET\")…] " ++
            "[(copper IDX (thickness MM) [(material \"NAME\")])] " ++
            "[(dielectric AFTER_IDX core|prepreg (material \"NAME\") (thickness MM) [(er X)])] [(thickness MM)])",
        .summary = "Declare the board's copper stack: N total copper layers (1-based, 1 = top/" ++
            board_layers.f_cu ++ ", N = bottom/" ++ board_layers.b_cu ++
            "), or name a built-in fabricator construction such as " ++
            "`(stackup \"JLC04161H-7628\" …)`. A preset supplies copper, dielectric, Dk, and finished " ++
            "thickness while the board still owns its electrical plane/pour roles. The Stackup panel " ++
            "lists every available preset; a numeric N keeps the fully custom form. Each " ++
            "(plane IDX \"NET\") makes layer IDX a solid plane carrying NET, " ++
            "all other layers are routed signal layers. `(pour top|bottom \"NET\")` is sugar for a " ++
            "plane on the matching OUTER layer (top = 1, bottom = N): the face is emitted as a solid " ++
            "copper pour (Gerber + /pcb-layout + PNG), NET pads already on that face connect through " ++
            "the pour with no stitching via, and signal routing prefers the un-poured face. " ++
            "Physical construction is optional and independent of electrical role: `(copper IDX …)` " ++
            "records each foil's material/thickness, while `(dielectric AFTER_IDX core|prepreg …)` " ++
            "records the interval immediately below that copper layer (valid gaps are 1 through N-1). A " ++
            "dielectric may also declare its relative permittivity with (er X) — the one purely " ++
            "ELECTRICAL number in the stackup: nothing about construction, routing or fabrication reads " ++
            "it, but a (net-class … (impedance OHMS)) width is solved against it. Undeclared, generic " ++
            "FR-4's 4.4 applies, and a board with no (dielectric …) intervals at all has its heights " ++
            "synthesised by spreading the finished thickness evenly over the gaps. An " ++
            "optional (thickness MM) sets the finished board thickness reported in the Gerber .gbrjob " ++
            "(default 1.6 mm). `(stackup 2)` is a plain 2-layer board with no planes — ground/power " ++
            "are routed as copper like any other net; `(stackup 2 (pour bottom \"GND\"))` is the " ++
            "classic 2-layer board with a bottom ground pour. Without the form the router keeps its " ++
            "legacy implicit model: 4 layers whose inner pair are assumed planes — In1 carries every " ++
            "ground-named net, and by default In2 carries the block's dominant supply rail (the rail-named net " ++
            "landing on the most pads), so that rail joins by stitching via like ground instead of " ++
            "being routed. A subcircuit's `(power-plane off)` setting routes supplies as ordinary " ++
            "copper and retains only ground planes, whether the stackup is implicit or authored; " ++
            "with no qualifying rail In2 is also a second ground plane, as it always was.",
    } };
    t[@backingInt(ScopeForm.pdn)] = .{ .scope = tl, .doc = .{
        .syntax = "(pdn \"NET\" (ripple-v V) [(step-current-a A)] [(rise-time-s S)] " ++
            "[(source-resistance-ohm R)] [(source-inductance-h L)] [(frequency HZ_MIN HZ_MAX)])",
        .summary = "Declare the transient-noise budget for one physical power domain. The routed-board " ++
            "PDN screen derives target impedance as ripple-v / step-current-a, extracts every bound " ++
            "decoupling capacitor with its BOM C/ESR/ESL and layout mounting inductance, sweeps Z(f), " ++
            "flags anti-resonance peaks, and emits a SPICE subcircuit. When step-current-a is omitted, " ++
            "the screen uses the rail's declared max-minus-typical load (or maximum load) and labels " ++
            "that assumption. Ferrite-connected nets require separate pdn forms because they are one " ++
            "DC budget but distinct AC domains.",
    } };
    t[@backingInt(ScopeForm.fabrication_layer)] = .{ .scope = tl, .doc = .{
        .syntax = "(fabrication-layer \"FILE.gbr\" (side top|bottom) (material \"NAME\") (thickness MM) " ++
            "[(kind adhesive|stiffener)] (region board|(polygon (xy X Y)…))… " ++
            "[(exclude-footprints same-side|all-sides [\"REF\"…] [(clearance MM)])])",
        .summary = "Declare separately applied fabrication artwork such as FPC backing tape. The required side is " ++
            "independent of component placement; `(region board)` follows the exact board outline, while polygon " ++
            "regions are directly editable in world millimetres. `(exclude-footprints same-side)` clears the " ++
            "courtyards of footprints mounted on the backing face; `all-sides` projects both faces. Optional quoted " ++
            "refs restrict the exclusions, and clearance grows every cutout. Thickness is manufacturing metadata " ++
            "and is added to, not included in, `(stackup … (thickness …))`. The Gerber basename must be safe and " ++
            "end in `.gbr`; JLCPCB tape names conventionally use `pst_` for top and `psb_` for bottom.",
    } };
    t[@backingInt(ScopeForm.net_class)] = .{ .scope = tl, .doc = .{
        .syntax = "(net-class \"name\" [(width MM)] [(power-branch-width MM)] [(clearance MM)] " ++
            "[(pad-escape-width MM)] [(pad-escape-max-length MM)] [(taper-length MM)] " ++
            "[(via DIA DRILL)] [(priority 0-7)] [(diff-pair [GAP_MM])] [(max-freq HZ)] " ++
            "[(band MIN_HZ MAX_HZ)] [(return-loss DB)] " ++
            "[(escape MM)] [(min-bend-radius N)] [(resolution MM)] " ++
            "[(impedance OHMS [(layer IDX)])] [(diff-impedance OHMS [(layer IDX)])] [(ground-gap MM [(max MM)])] " ++
            "[(match-group \"NAME\" [(tolerance MM)])] " ++
            "[(return-path [(reference \"NET\")] [(stitch-radius MM)] [(max-loop-area MM2)])] " ++
            "[(fence [(pitch MM)] [(layers N)] [(mask-layers N)] [(offset MM)] [(via DIA DRILL)] [(net \"N\")])] " ++
            "[(keepout MM [(escape MM)])] [(mask-relief MM)] [(nets \"A\" \"B\"…)])",
        .summary = "Routing geometry + routing order profile and/or membership for named nets: " ++
            "trace width, copper clearance, " ++
            "an optional power-branch-width that starts plane-backed rail fanouts narrow while preserving width as the conservative whole-rail fallback (post-route DRC solves each segment's current and identifies only the branches that must grow), " ++
            "an optional short pad-local neck width/maximum length/linear taper back to the class width " ++
            "(applied only where the land's span across the actual launch is narrower than the trace), " ++
            "and via size (diameter + drill) in mm, plus a routing-priority tier — the autorouter " ++
            "routes higher tiers first, so a critical net (crystal, flash bus, a switcher's hot loop) " ++
            "claims its short path before a bulk rail can wall it off (the maze router has no rip-up; " ++
            "first-routed wins). Omitted numbers keep the router defaults (priority 0 = baseline); net " ++
            "names match the flattened netlist case-insensitively. A reusable subcircuit may assign " ++
            "membership with (nets …), while a destination board declares the same class name with " ++
            "geometry but no nets; destination fields override module fallbacks. The first class naming " ++
            "a net at the same hierarchy depth wins. (diff-pair) marks the class's nets a differential " ++
            "pair — the router routes the pair's N net right after its P net and biases it into a " ++
            "corridor hugging the twin; an optional GAP_MM sets the target edge-to-edge gap (default: " ++
            "the class clearance). (max-freq HZ) declares the highest signal frequency the class " ++
            "carries and opts its nets into RF bend discipline: no sharp corners — routed bends are " ++
            "smoothed into arcs aiming for the largest radius that fits (capped at 5x the trace " ++
            "width), with 3x width as the minimum (the standard RF rule of thumb); any corner that " ++
            "can't reach the minimum is flagged by the sharp_bend DRC check. (band MIN_HZ MAX_HZ) " ++
            "sets the electrical evaluation range (a max-freq-only class uses MAX/100..MAX for " ++
            "compatibility), and (return-loss DB) sets the minimum worst-case RL target over that " ++
            "band (default 20 dB). (escape MM) makes the " ++
            "class's traces leave every pad straight for MM millimetres before the first bend " ++
            "(a max-freq class defaults to 1 mm; (escape 0) disables). (min-bend-radius N) overrides " ++
            "that 3x default: it sets the per-class radius FLOOR to N times the trace width, so a raised " ++
            "N (e.g. 5) demands gentler sweeps — flagging MORE corners as sharp_bend unless they fit, and " ++
            "lifting the 5x aim cap when N exceeds it — while a lowered N (e.g. 2) accepts tighter corners " ++
            "and quiets the check; it acts only on a max-freq class. " ++
            "(match-group \"NAME\" [(tolerance MM)]) joins this class's nets to a LENGTH-MATCHED " ++
            "set — a bus whose members must arrive together, which (diff-pair …) cannot express " ++
            "because it matches exactly two legs and couples their geometry as it goes. NAME is " ++
            "the join key, not the class, so two classes with different trace geometry may name " ++
            "the same group and still match as one set; (tolerance MM) is the allowed max-minus-min " ++
            "spread over the members' ROUTED lengths (default 0.5 mm, and when two classes name one " ++
            "group with different budgets the TIGHTER wins). Each member's length is its effective " ++
            "copper length — the shortest path over its own copper, so a retrace or a spur is not " ++
            "counted as spent budget — plus one board thickness per via barrel it crosses, since " ++
            "members that hop layers a different number of times really are different lengths. " ++
            "The autorouter routes a group's longest-expected member FIRST so the short ones keep " ++
            "the slack to detour, and a group that ends up over budget is reported as a " ++
            "length_mismatch DRC WARNING (never a fab-blocking error — the copper is legal, a " ++
            "timing margin is what is at risk) with the per-net lengths in /api/pcb-describe's " ++
            "match_groups block. A group is judged only once at least two of its members carry " ++
            "copper, so a half-routed board never reads as mismatched. Length matching MEASURES; " ++
            "it does not lengthen anything — closing a spread is still a hand or tooling edit. " ++
            "(return-path …) opts any class into the fabricated reference-plane audit; classes " ++
            "that already declare max-freq, impedance, or diff-impedance are audited automatically. " ++
            "The check flags routed copper over a split/slot in its nearest declared reference plane " ++
            "and a layer transition whose reference changes without a nearby same-reference stitching " ++
            "via (or a capacitor bridging two different references). (reference \"NET\") overrides the " ++
            "nearest-plane net, (stitch-radius MM) overrides the 2 mm transition radius, and " ++
            "(max-loop-area MM2) warns when trace length times physical trace-to-reference separation " ++
            "exceeds the authored high-di/dt loop-area budget. All three are SI/EMC warnings, not fab errors. " ++
            "(fence …) flanks every routed " ++
            "trace of the class with a row of ground stitching vias on each side — generated on " ++
            "demand at end-of-design (not by the autorouter), so placement and routing are already " ++
            "settled when the fence lands. The fence wraps the net's whole COPPER — its traces " ++
            "AND the pads they land on — following a pour-style contour around all of it, so a via " ++
            "keeps the same gap from a wide 0402 or QFN pad as from the thin trace between them. " ++
            "All children optional: (pitch MM) is the via " ++
            "centre-to-centre spacing along the contour (default: a tenth of the guided wavelength " ++
            "implied by (max-freq …)); (layers N) selects 1–32 concentric rows (default 1), with " ++
            "each added row one resolved pitch farther outward; (mask-layers N) exposes only the N innermost rows " ++
            "through the derived RF solder-mask opening (default: expose every generated row); (offset MM) is the GAP from the net's copper edge to the fence " ++
            "via's copper edge (default: the DRC minimum — the clearance + a 0.1 mm margin), " ++
            "(via DIA DRILL) the fence via geometry (default: the class's own (via …), " ++
            "else the board (design-rules (via …))), and (net \"N\") the stitched net (default: the " ++
            "board's first ground plane). Sites blocked by other copper are simply skipped, so a " ++
            "fence may have gaps. (keepout MM) reserves a halo MM millimetres wide around the " ++
            "class's copper that foreign copper must stay out of, ON THE SAME LAYER only — signals " ++
            "cross freely on other layers, while a through-via barrel spans every layer and is " ++
            "blocked. Its (escape MM) relaxes the halo within MM of the class's own pads, where a " ++
            "neighbouring signal has to leave the same IC (default: the class's resolved (escape …) " ++
            "distance; (escape 0) exempts nothing). (mask-relief MM) sets the per-side solder-mask " ++
            "pullback from the class's routed copper: the Gerber mask opens along its outer-layer " ++
            "traces and vias — bare copper, the RF microstrip convention — and its declared fence's " ++
            "stitch vias untent alongside. A max-freq class defaults ON at the board's mask margin, " ++
            "and one that also declares a (fence …) widens the band over the whole stitch row (edge " ++
            "gap + fence via + margin) so the shielding vias' annular rings ship bare too; " ++
            "(mask-relief 0) keeps the class tented, and a positive MM overrides either default or " ++
            "opts in a class with no (max-freq …). Where a wide relief overlaps a nearby pad, a local " ++
            "pad-shaped mask island retains one board mask web around that pad's aperture while the RF " ++
            "trace stays exposed around the island; paste and solder therefore stay dammed at QFN and " ++
            "passive lands. An exposed stretch shorter than 1 mm keeps its mask outright — a sliver of " ++
            "bare trace between two lands is mask worth keeping. " ++
            "(impedance OHMS [(layer IDX)]) declares the class's target " ++
            "single-ended characteristic impedance, which is what turns (max-freq …) from geometry " ++
            "discipline into an electrical statement. Declared ALONE, the class's track WIDTH is " ++
            "derived from it: Z0 is solved against the (stackup …) buildup — microstrip on an outer " ++
            "face over its nearest plane, stripline on an inner layer between two — on the optional " ++
            "1-based copper layer, or the first signal layer with a usable reference when omitted. " ++
            "Every routed SMD launch on a single-ended impedance class transitions between the " ++
            "actual angle-aware land span and the nominal line over 1.2 trace widths; this local " ++
            "taper applies to wider and narrower lands even when the net branches, changes sides, " ++
            "or contains vias elsewhere. " ++
            "For single-ended impedance classes, each routed through-via also gets a circular antipad " ++
            "solved from its actual pad/drill and the stack's finished thickness and thickness-weighted " ++
            "er, floored at the ordinary copper clearance, and applied consistently to every foreign " ++
            "plane/pour; the report labels this as a first-order lumped-LC estimate, not 3D EM signoff. " ++
            "Differential vias are not auto-sized because their coupled/shared antipad and return-via " ++
            "geometry needs a field solver. " ++
            "(diff-impedance OHMS [(layer IDX)]) declares the impedance across a (diff-pair GAP); " ++
            "edge-coupled stripline is solved as twice the odd-mode impedance using that routed " ++
            "edge-to-edge gap. /api/pcb-describe's `impedance` block reports " ++
            "the whole per-layer table (each layer's reference kind, height, er, the width that would " ++
            "hit the target there, and what the width in force computes to) plus the single-ended " ++
            "via-transition estimate. Declared ALONGSIDE an " ++
            "explicit (width MM), the WIDTH WINS and the impedance becomes a CHECK: the " ++
            "impedance_mismatch lint warns, with the numbers, when that width's computed Z0 misses " ++
            "the target by more than 5%. (ground-gap MM [(max MM)]) declares the minimum edge-to-edge " ++
            "slot from an outer-layer trace to same-layer ground copper and selects grounded-coplanar " ++
            "analysis; the actual resolved gap is never smaller than the applicable copper clearance. " ++
            "An optional (max MM) lets a tapered trace widen that slot per routed width to preserve the " ++
            "impedance target, stopping honestly at the cap when the backing-plane microstrip limit is " ++
            "lower than the target. The resolved local value controls both analysis and the ground-pour " ++
            "opening. Inner " ++
            "signal layers remain stripline. A stackup with no reference plane for the layer, or a target " ++
            "no width in the formula's published domain reaches, derives nothing and says so rather " ++
            "than extrapolating. Repeat the form for more classes.",
    } };
    t[@backingInt(ScopeForm.design_rules)] = .{ .scope = tl, .doc = .{
        .syntax = "(design-rules [(clearance MM)] [(min-drill MM)] [(mask-margin MM)] [(mask-relief-corner-radius MM)] [(copper-edge MM)] [(component-edge MM)] " ++
            "[(hole-to-hole MM)] [(min-annular MM)] [(mask-web MM)] [(min-width MM)] [(pour-clearance MM)] " ++
            "[(pour-min-width MM)] " ++
            "[(pour-corner-radius MM)] [(ground-via-max MM)] [(track-width MM)] [(via DIA DRILL)] [(via-plating MM)])",
        .summary = "Board-level DEFAULT design rules (all sub-forms optional; mm): (clearance) copper-to-copper " ++
            "spacing for the router + DRC; (min-drill) smallest legal drilled hole; (mask-margin) solder-mask " ++
            "opening expansion per pad side; (mask-relief-corner-radius) fillets the ends of RF trace openings where they stop at pad dams; " ++
            "(copper-edge) copper-to-board-outline clearance; " ++
            "(component-edge) component-courtyard-to-board-outline clearance; (hole-to-hole) " ++
            "wall-to-wall spacing between two drilled holes; (min-annular) minimum via annular ring " ++
            "(copper radius − drill radius); (mask-web) smallest solder-mask web retained between adjacent " ++
            "openings — a positive strip below it is removed by merging those apertures; (min-width) narrowest legal track; (pour-clearance) the BASE copper-pour isolation " ++
            "gap — how far a solid pour holds off foreign copper (pad/track halos, hole and via antipads) " ++
            "on every ordinary net, and, with no (copper-edge …), its pullback from the board outline; an " ++
            "RF (net-class …) still carves its own per-net exceptions over it (a (ground-gap …) opening, a " ++
            "solved impedance via antipad), which this does not touch. A pour gap authored BELOW the " ++
            "board's copper clearance is accepted but warned — a pour cannot hold a gap the copper rule " ++
            "forbids. (pour-min-width) narrowest retained copper-pour section; (pour-corner-radius) radius used to round pour corners; " ++
            "(ground-via-max) maximum centre distance from every SMD ground pad to a same-net via reaching the ground plane (zero/omitted disables it); " ++
            "(track-width) the default routed trace width; " ++
            "(via DIA DRILL) the default via copper diameter + drill; (via-plating) the minimum finished " ++
            "copper thickness on each barrel wall used by the power-capacity screen. Track width and via geometry seed the autorouter's " ++
            "geometry — an explicit query/panel override still wins for interactive routing, but the fab " ++
            "gate judges the board against these authored rules. All are global defaults — a per-net " ++
            "(net-class …) still overrides width/clearance/via for its own nets. An omitted rule keeps the " ++
            "toolchain's built-in default (clearance 0.127, min-drill 0.2, mask-margin 0.05, mask-relief-corner-radius 0, copper-edge = " ++
            "clearance, component-edge 0.2, hole-to-hole 0.25, min-annular 0.1, mask-web 0.1, min-width 0.1, " ++
            "pour-clearance 0.3, track-width 0.127, " ++
            "via 0.4 / 0.2, via-plating 0.025), so a design with no form uses those defaults.",
    } };
    t[@backingInt(ScopeForm.revision)] = .{ .scope = tl, .doc = .{
        .syntax = "(revision \"ID\" [(date \"YYYY-MM-DD\")] [(change \"ID\" \"summary\")…])",
        .summary = "Declare the design's canonical board revision: a human-meaningful spin id " ++
            "(\"A\", \"F4\", \"1.2\"), an optional date, and an optional newest-first in-file " ++
            "changelog. Shown on the schematic header and review doc so a recipient of the .sexp " ++
            "can tell which revision they hold; bump it by hand when cutting a new spin. Distinct " ++
            "from the per-edit snapshot history — tag the git commit to anchor the bump.",
    } };
    t[@backingInt(ScopeForm.pcb_plan)] = .{ .scope = tl, .doc = .{
        .syntax = "(pcb-plan [(topology)] (place (wave \"name\" [(refs \"REF\"…)] [(sections \"S\"…)] " ++
            "[(sub-blocks \"slug\"…)] [(rest)] [(reason \"…\")])…) " ++
            "(route [(effort one-shot|standard)] [(max-route-seconds N)] " ++
            "(wave \"name\" [(classes atom…)] [(net-classes \"name\"…)] [(nets \"NET\"…)] " ++
            "[(preferred-layers " ++ doc_f_cu ++ "…)] [(allowed-layers " ++ doc_f_cu ++ "…)] " ++
            "[(max-vias N)] [(waypoints (at X Y " ++ doc_f_cu ++ ")…)] " ++
            "[(repair-waypoints (at X Y " ++ doc_f_cu ++ ")…)] " ++
            "[(branches (branch (at X Y " ++ doc_f_cu ++ ")…)…)] " ++
            "[(guides (escape-from \"REF\" \"PIN\" " ++ doc_f_cu ++ ") " ++
            "(between-pins \"REF\" \"PIN\" \"REF\" \"PIN\" " ++ doc_f_cu ++ ") " ++
            "(beside \"REF\" north|south|east|west " ++ doc_f_cu ++ ")…)] " ++
            "[(assign-escapes [" ++ doc_f_cu ++ "] [\"HUBREF\"] [(reserve)])] [(topology)] [(seed-first)] [(rest)] [(reason \"…\")])…))",
        .summary = "Declare the ordered plan for completing the PCB layout: (place …) waves order " ++
            "part placement, (route …) waves order net routing, each wave named and applied in " ++
            "authored order. (max-route-seconds N) gives the entire route transaction a cooperative wall-clock deadline; omitted keeps the historical unbounded-by-clock behavior. A PLACE wave selects parts with (refs …) ref-des, (sections …) " ++
            "section names, (sub-blocks …) sub-block slugs; a ROUTE wave selects nets with " ++
            "(classes …) module-policy criticality atoms (input_rail switch_node clock rf feedback " ++
            "analog, plus ground power control signal — a whole class's nets, no repetition), " ++
            "(net-classes …) authored (net-class …) names, and (nets …) one-off net names. " ++
            "(preferred-layers …) biases those nets toward named signal layers while retaining " ++
            "fallback paths; (allowed-layers …) restricts trace bodies to the named layers while " ++
            "still permitting terminal-pad breakout. (max-vias N) is a hard per-net via budget; an " ++
            "over-budget attempt is rolled back and retried without vias. " ++
            "(waypoints (at X Y \"layer\")…) constrains a " ++
            "route through ordered physical points; repeating a coordinate on two layers requests " ++
            "a via transition. (repair-waypoints …) writes the same kind of corridor but is tried " ++
            "ONLY after the net's ordinary attempt fails (and again by post-route residual " ++
            "repair), so a rescue corridor can never perturb a net the broad router already " ++
            "closes. (branches (branch (at …)…)…) authors a multi-drop net's guide TREE rather " ++
            "than one corridor: every (branch …) is the path from the tree's shared root " ++
            "terminal out to ONE drop, and limbs that leave the root together share that copper. " ++
            "Which limb serves which drop is worked out from the GEOMETRY — the root is the pad " ++
            "nearest where the limbs all start, and each limb takes the pad nearest where it " ++
            "ends — because the router's terminal order comes out of flattening and is not " ++
            "something a design can name. A tree is a COMPLETE specification: it needs exactly " ++
            "one limb per non-root terminal, and a tree whose limbs land on the same pad twice, " ++
            "end on the root, or cannot cover the net is refused whole (with a plan warning) so " ++
            "the net routes through the ordinary multi-terminal path instead of a wrong corridor. " ++
            "One limb on a two-terminal net is just a (waypoints …) chain and lowers to one. " ++
            "(guides …) expresses the same ordered corridor without board " ++
            "coordinates: (escape-from REF PIN LAYER) leaves that pad toward its nearest courtyard " ++
            "edge and one clearance beyond its copper, " ++
            "edge, (between-pins REF PIN REF PIN LAYER) uses the two pads' midpoint, and " ++
            "(beside REF SIDE LAYER) runs just outside a named courtyard side. Relative guides are " ++
            "resolved after placement and snapped to its grid, so they follow moved or rotated parts. " ++
            "(assign-escapes …) solves the WHOLE wave at once instead: its nets are treated as one " ++
            "contended escape, and the assigner finds their shared hub, cuts a corridor cross-section " ++
            "at the tightest constriction they all still fit through, and gives each net its own " ++
            "parallel lane (lane order follows endpoint order, so no two cross). Use it where several " ++
            "nets leave one connector or QFN through the same channel and routing them one at a time " ++
            "lets the first ones starve the rest. The lanes become SOFT per-net router guides, so an " ++
            "unusable lane costs a net a detour, never the net. Both strings are optional overrides: " ++
            "the copper face to fan out on (default: the hub's own side) and the hub ref (default: the " ++
            "part hosting pads of the most nets in the wave). Its optional (reserve) sub-form makes each " ++
            "assigned lane a HARD reservation as well: the lane's own net routes through it freely and " ++
            "every other net is refused it for the whole run, so a later net cannot take the channel the " ++
            "assignment was built around. Without it the lanes stay soft, which is the default because a " ++
            "reservation can cost the nets it excludes while a guide never can; a lane too fine for the " ++
            "routing raster to tell apart from its neighbour reserves nothing rather than locking the " ++
            "neighbour out. A bare " ++
            "(topology) opts the wave into global topology planning: its nets get a board-wide " ++
            "route topology worked out together before the maze runs, instead of each net being " ++
            "routed in turn and the early ones walling in the late ones. Authored plan-level " ++
            "((pcb-plan (topology) …)) it applies to EVERY route wave; authored on one wave it " ++
            "applies to that wave alone. Absent, nothing changes. A bare (seed-first) gives a " ++
            "waypoint-guided route wave one bounded first claim before the ordinary whole-board " ++
            "pass; only complete, DRC-safe synthesized copper is retained, and the seed shares the " ++
            "board's route deadline. It is inert without authored waypoints. A bare " ++
            "(rest) is the catch-all (everything not named by an earlier wave in that section; at " ++
            "most one per section), and (reason \"…\") documents why. Zero or one per design; the " ++
            "member names are recorded verbatim — resolving and existence-checking them is a later step.",
    } };
    break :blk requireAllDocumented(ScopeForm, ScopedFormDoc, t);
};

// ── Tests ──────────────────────────────────────────────────────────────

// spec: eval/forms - SpecialForm.fromAtom resolves every head atom the evaluator dispatches on
test "SpecialForm registry covers every variant" {
    // Every enum variant must have a matching atom in the lookup table.
    // Build a set of seen variants by iterating the table, then check
    // its size equals the variant count.
    var seen = std.bit_set.IntegerBitSet(@typeInfo(SpecialForm).@"enum".field_names.len).empty;
    for (atom_to_form.values()) |v| seen.set(@backingInt(v));
    try std.testing.expectEqual(@typeInfo(SpecialForm).@"enum".field_names.len, seen.count());
}

// spec: eval/forms - SpecialForm.fromAtom rejects atoms that aren't registered special forms
test "SpecialForm.fromAtom returns null for unknown names" {
    try std.testing.expect(SpecialForm.fromAtom("instance") == null);
    try std.testing.expect(SpecialForm.fromAtom("") == null);
    try std.testing.expect(SpecialForm.fromAtom("LET") == null);
    try std.testing.expectEqual(SpecialForm.let, SpecialForm.fromAtom("let").?);
    try std.testing.expectEqual(SpecialForm.design_block, SpecialForm.fromAtom("design-block").?);
}

// spec: eval/forms - block is the unified definition form; design-block and defmodule remain permanent aliases
test "block form resolves and legacy definition keywords remain aliases" {
    try std.testing.expectEqual(SpecialForm.block, SpecialForm.fromAtom("block").?);
    try std.testing.expectEqual(SpecialForm.design_block, SpecialForm.fromAtom("design-block").?);
    try std.testing.expectEqual(SpecialForm.defmodule, SpecialForm.fromAtom("defmodule").?);
}

// spec: eval/forms - Builtin.fromAtom resolves every operator name
test "Builtin registry covers every variant" {
    var seen = std.bit_set.IntegerBitSet(@typeInfo(Builtin).@"enum".field_names.len).empty;
    for (atom_to_builtin.values()) |v| seen.set(@backingInt(v));
    try std.testing.expectEqual(@typeInfo(Builtin).@"enum".field_names.len, seen.count());
    try std.testing.expectEqual(Builtin.add, Builtin.fromAtom("+").?);
    try std.testing.expectEqual(Builtin.gte, Builtin.fromAtom(">=").?);
    try std.testing.expect(Builtin.fromAtom("foo") == null);
}

// spec: eval/forms - ScopeForm.fromAtom resolves every form name that can appear in a design-block / section / subsection
test "ScopeForm registry covers every variant" {
    var seen = std.bit_set.IntegerBitSet(@typeInfo(ScopeForm).@"enum".field_names.len).empty;
    for (atom_to_scope_form.values()) |v| seen.set(@backingInt(v));
    try std.testing.expectEqual(@typeInfo(ScopeForm).@"enum".field_names.len, seen.count());
    try std.testing.expectEqual(ScopeForm.instance, ScopeForm.fromAtom("instance").?);
    try std.testing.expectEqual(ScopeForm.sub_block, ScopeForm.fromAtom("sub-block").?);
    try std.testing.expect(ScopeForm.fromAtom("let") == null);
}

// spec: eval/forms - diagram-layout is the sole name for the schematic layout form; the legacy layout/module aliases are gone
test "diagram-layout is the schematic layout form and legacy aliases are retired" {
    try std.testing.expectEqual(ScopeForm.layout, ScopeForm.fromAtom("diagram-layout").?);
    // `layout` (PCB-placement now) and `module` (collided with defmodule) are no longer scope-form aliases.
    try std.testing.expectEqual(@as(?ScopeForm, null), ScopeForm.fromAtom("layout"));
    try std.testing.expectEqual(@as(?ScopeForm, null), ScopeForm.fromAtom("module"));
}

// spec: eval/forms - validateArity flags too-few and too-many arguments and accepts in-range counts
test "validateArity bounds-checks against the schema" {
    const let_schema = schemaFor(.let).?;
    try std.testing.expect(validateArity(let_schema, 1) != null);
    try std.testing.expect(validateArity(let_schema, 2) == null);
    try std.testing.expect(validateArity(let_schema, 3) != null);

    const fmt_schema = schemaFor(.fmt_).?;
    try std.testing.expect(validateArity(fmt_schema, 0) != null);
    try std.testing.expect(validateArity(fmt_schema, 1) == null);
    try std.testing.expect(validateArity(fmt_schema, 100) == null); // unbounded max
}

// spec: eval/forms - schemaFor returns the schema for every special form whose arity is fixed
test "schemaFor covers all special forms except id" {
    inline for (@typeInfo(SpecialForm).@"enum".field_values) |fval| {
        const variant: SpecialForm = @fromBackingInt(@intCast(fval));
        if (variant == .id_) {
            try std.testing.expect(schemaFor(variant) == null);
        } else {
            try std.testing.expect(schemaFor(variant) != null);
        }
    }
}
