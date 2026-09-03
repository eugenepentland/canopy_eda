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
    for_,
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
    .{ "for", .for_ },
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
    diff_port,
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
    net_envelope,
    fabrication_layer,
    net_class,
    pll_loop,
    frequency_plan,
    design_rules,
    pcb_plan,
    module_policy,

    pub fn fromAtom(name: []const u8) ?ScopeForm {
        return atom_to_scope_form.get(name);
    }
};

const atom_to_scope_form = std.StaticStringMap(ScopeForm).initComptime(.{
    .{ "instance", .instance },
    .{ "port", .port },
    .{ "bus-port", .bus_port },
    .{ "diff-port", .diff_port },
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
    .{ "net-envelope", .net_envelope },
    .{ "module-policy", .module_policy },
    .{ "fabrication-layer", .fabrication_layer },
    .{ "net-class", .net_class },
    .{ "pll-loop", .pll_loop },
    .{ "frequency-plan", .frequency_plan },
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
        .{ .for_, .{ .min_args = 3, .max_args = null } },
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
    t[@backingInt(SpecialForm.for_)] = .{
        .syntax = "(for name (item…) body… [(id hex8)] [(ids (\"origin@ordinal\" hex8)…)])",
        .summary = "Evaluate `body` once per listed item — strings, numbers, or expressions — " ++
            "with `name` bound in a fresh lexical scope for each. The list sibling of `repeat`, " ++
            "so a channel letter can drive `(fmt …)` names; child identities derive from " ++
            "origin key + 0-based ordinal unless the IDs sidecar pins them.",
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
        .syntax = "(instance \"REF\" component sub-form…)",
        .summary = "Place a component with inline pin-to-net bindings. Its body grammar — `(pin …)`, " ++
            "`(near …)`, `(power …)` and the rest — is the “Instance sub-forms” table; any other " ++
            "`(key \"value\")` child is an inline property override on the placed part.",
    } };
    t[@backingInt(ScopeForm.port)] = .{ .scope = all, .doc = .{
        .syntax = "(port \"name\" [net] dir [kind] [optional] [role R] [protocol P] [class C] sub-form…)",
        .summary = "Declare a block boundary signal. A power/rf port's direction (or an explicit (side …)) tells the PCB " ++
            "rough placer where the net enters/leaves the module — in → left, out → right. The " ++
            "parenthesised options are the “Port sub-forms” table.",
    } };
    t[@backingInt(ScopeForm.bus_port)] = .{ .scope = all, .doc = .{
        .syntax = "(bus-port \"prefix\" lo hi [(suffixes S…)] port-modifier…)",
        .summary = "Declare a multi-bit boundary bus that expands to one port per lane. `(suffixes …)` " ++
            "emits one port per lane per suffix, e.g. a differential `P`/`N` pair.",
    } };
    t[@backingInt(ScopeForm.diff_port)] = .{ .scope = all, .doc = .{
        .syntax = "(diff-port \"BASE\" [net] dir [kind] [optional] [(rated lo hi)] [(side …)] [(suffixes P N)])",
        .summary = "Declare a differential boundary pair as one line: expands to the `BASE_P`/`BASE_N` " ++
            "ports (override the suffixes with `(suffixes …)`), replays every modifier onto both lanes, " ++
            "defaults their kind to `differential`, and records the pairing so ERC holds the two lanes " ++
            "to a both-or-neither connection rule.",
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
        .syntax = "(decouple \"NET\" [(comp \"val\")] COUNT per-pin [REF|auto] PIN…) | " ++
            "(decouple \"NET\" (per-pin (comp \"val\") FN…)… (bulk (comp \"val\") COUNT)… (bypass …)…)",
        .summary = "Emit COUNT decoupling caps per listed host pin. Component and REF may come from " ++
            "(decouple-defaults …); a trailing `auto` expands to the pins already declared on the net. " ++
            "The compact rail form takes sub-forms instead: `(per-pin …)` bypasses each named pin " ++
            "function (inferring the host), `(bulk COMPONENT COUNT)` adds shared rail capacitance, and " ++
            "`(bypass …)` takes the positional item list.",
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
        .syntax = "(bus-net \"PREFIX\" lo hi \"SUB\") | (bus-net \"PREFIX\" lo hi (suffix \"S\") (over \"SUB\" (port-base \"P\" N))) | " ++
            "(bus-net \"PREFIX\" lo hi [(suffixes S…)] (over \"SUB\"…) (ports P…))",
        .summary = "Tie a lane range to a sub-block bus, including an optional parent suffix and offset child-port family. " ++
            "The strided form distributes the channel range sub-major across every `(over …)` sub-block " ++
            "and `(ports …)` port family, emitting one tie per `(suffixes …)` entry.",
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
        .syntax = "(led \"NAME\" \"SUPPLY\" COLOR (r VALUE) [(return \"NET\")] [(anode \"NET\")])",
        .summary = "Emit a series resistor and LED indicator with semantic labels. `(anode …)` names " ++
            "the resistor/diode midpoint explicitly instead of the derived `<NAME>_LED_A`.",
    } };

    t[@backingInt(ScopeForm.pins)] = .{ .scope = all, .doc = .{
        .syntax = "(pins \"REF\" [(group \"label\")] pin-form…)",
        .summary = "Group a main-IC's pin assignments under a sub-section. Its children are the " ++
            "“Pins-block sub-forms” table.",
    } };
    t[@backingInt(ScopeForm.protocol)] = .{ .scope = dsec, .doc = .{
        .syntax = "(protocol atom)",
        .summary = "Tag a section with a protocol keyword (e.g. `usb`, `i2c`).",
    } };
    t[@backingInt(ScopeForm.calc)] = .{ .scope = dsec, .doc = .{
        .syntax = "(calc \"name\" (let NAME expr)… [(assert-range value lo hi \"label\")]…)",
        .summary = "Inline design math block, surfaced in the review report. Each `(let …)` binds and " ++
            "records a value in the block's own scope; `(assert-range …)` checks one of them.",
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
        .syntax = "(sub-block \"name\" (module-call args…) | \"path/to/file.sexp\" sub-form…)",
        .summary = "Instantiate a parameterised module inside the design. Its parts flatten into " ++
            "the netlist under the sub-block path prefix and the PCB solver places them with the " ++
            "rest of the board. Its trailing children — `(bridge …)` above all, which wires the " ++
            "module's ports to board nets — are the “Sub-block sub-forms” table.",
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
        .syntax = "(diagram-layout [(anchor \"name\")] [(place \"name\" (right-of|left-of|above|below \"ref\")…)]… " ++
            "[(row \"a\" \"b\"…)]… [(group \"Label\" \"a\" \"b\"…)]… [(edge left|right \"a\"…)]…)",
        .summary = "Position blocks relative to one another on the SCHEMATIC block diagram " ++
            "(Mermaid-style, free-floating) — nothing to do with PCB placement, which is " ++
            "the force / rough solver on /pcb-layout. Block keys are section names and " ++
            "sub-block handles. `(anchor …)` and a bare `(place …)` pin a root; `(row …)` is an " ++
            "ordered horizontal band; `(group …)` draws a labelled region over its members; " ++
            "`(edge …)` parks members against one side. Note these `(row …)`/`(group …)` forms are " ++
            "variadic block-key lists — unrelated to a section's `(row N)` grid hint or the " ++
            "design-scope `(group \"name\" (\"R1\"…))` member list.",
    } };
    t[@backingInt(ScopeForm.board)] = .{ .scope = tl, .doc = .{
        .syntax = "(board [(part-number \"PN\")] (size W H) [(corner-radius R)] [(outline-approved \"DIGEST\")] " ++
            "[(perimeter-fence (via DIA DRILL) (spacing PITCH) (edge-offset OFFSET) (mask-width WIDTH) [(net \"GND\")] " ++
            "[(keepout CLEARANCE [(blocks components tracks vias)] [(allow-nets \"NET\"…)])])] " ++
            "[(keepout \"NAME\" (rect X Y W H) (side top|bottom|both) " ++
            "[(blocks components tracks vias)] [(allow-nets \"NET\"…)] [(reason \"WHY\")])]… " ++
            "[(heatsink (rect X Y W H) (side top|bottom) (target \"SCOPE\" \"ORIGIN\") " ++
            "[(material aluminum_6063|aluminum_1050|copper)] [(shape finned|stepped)] [(base-mm N)] [(fin-height-mm N)] " ++
            "[(fin-thickness-mm N)] [(fin-gap-mm N)] [(fin-axis length|width)] " ++
            "[(lower-rect WIDTH LENGTH HEIGHT)] " ++
            "[(pad-thickness-mm N)] [(pad-k-w-mk N)])] " ++
            "[(fan (model \"MPN\") (rect X Y W H) (side top|bottom) (distance-mm N) " ++
            "(free-air-flow-m3-s N) (max-static-pressure-pa N) (operating-flow-fraction N))] " ++
            "(left|right|top|bottom \"REF\"… | (rot N \"REF\")…)… [(corners \"REF\"…)])",
        .summary = "Physical board outline + edge hardware: (size W H) is the outline in mm " ++
            "(required — without it the form is inert). (corner-radius R) rounds the outline's " ++
            "corners with radius R mm — the shape flows to " ++ board_layers.edge_cuts ++
            ", the board-edge DRC, and " ++
            "every renderer as a fine polyline. (outline-approved \"DIGEST\") accepts a saved outline " ++
            "profile this form cannot describe — a notch, a recess, mixed corner radii — by pinning that " ++
            "exact profile's digest, which the fabrication-readiness outline-drift finding prints for " ++
            "copy-paste. It approves the PROFILE only: (size W H) is still compared, and redrawing the " ++
            "outline makes the pin stale rather than silently blessing the new shape. " ++
            "(perimeter-fence …) generates plated vias " ++
            "around that exact outline; DIA and DRILL set their finished diameter and hole, " ++
            "PITCH is their nominal centre spacing, OFFSET is the via-centre distance from the " ++
            "finished edge, and WIDTH removes solder mask inward from the edge only on a face carrying a matching GND pour (" ++ board_layers.f_mask ++
            " / " ++ board_layers.b_mask ++ "). Component bodies/courtyards do not interrupt the derived edge hardware: " ++
            "pad proximity is the only component-derived reason to suppress a fence via, and its annulus stays at least 0.2 mm " ++
            "from the pad. Each face uses one continuous mask opening with copper-shaped protectors that retain solder mask over " ++
            "foreign pads, tracks, vias, and the GND pour clearance around them, leaving a 0.2 mm pad dam without oversized edge " ++
            "scallops. Ordinary copper and drill DRC legality still applies to every via. The fence net defaults to GND. " ++
            "(keepout CLEARANCE …) reserves a visible " ++
            "band beyond the vias' inward copper edge; (blocks …) chooses whether components, " ++
            "tracks, and/or vias are forbidden there (all three by default), while (allow-nets …) " ++
            "admits named copper such as GND. A named (keepout \"NAME\" (rect X Y W H) (side …) …) is the AUTHORED " ++
            "interior region — a heatsink plate's footprint, a shield can, a bracket — repeatable, its rectangle " ++
            "board-local millimetres from the outline's top-left (the (heatsink …) frame). (side top|bottom|both) " ++
            "picks the face(s) it reserves, (blocks …) the families it forbids there (all three by default), and " ++
            "(allow-nets …) admits named copper; (reason \"WHY\") is carried to DRC, /api/pcb-describe and the " ++
            "renderers. The placer refuses to put a component courtyard in it, DRC reports board_keepout for a " ++
            "courtyard, track, or via that lands there, and it is drawn and labelled on /pcb-layout and the PCB PNG. " ++
            "A rectangle outside the outline, a non-positive size, or an unknown side/blocks word is an error, not a " ++
            "warning. (heatsink …) authors the board's rebuildable default thermal assembly; " ++
            "its rectangle uses board-local millimetres from the outline's top-left, its physical construction feeds " ++
            "the heatsink scenario, and `(shape stepped)` replaces fins with one centered `(lower-rect WIDTH LENGTH HEIGHT)` " ++
            "solid for a board-to-enclosure cold plate. Its target is the stable sub-block/source-origin pair rather than a renumberable " ++
            "ref-des. A saved layout can override its physical assembly; " ++
            "removing or rebuilding the sidecar falls back to this declaration. Each (left|right|top|bottom …) list " ++
            "(fan …) authors an axial fan normal to one PCB face: its frame projection is board-local, distance is " ++
            "outlet-to-board normally or outlet-to-outer-sink-surface when a board sink shares that face, and the catalog " ++
            "free-flow/shutoff-pressure endpoints remain distinct. The required " ++
            "operating-flow-fraction states the installed-flow assumption instead of silently claiming both maxima at once. " ++
            "Its optional fan scenario applies distance-expanded forced convection only beneath that projected jet. " ++
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
            "[(copper IDX (thickness MM) [(material \"NAME\")] [(width-reduction MM)] [(narrow-side up|down)])] " ++
            "[(dielectric AFTER_IDX core|prepreg (material \"NAME\") (thickness MM) [(er X)])] " ++
            "[(soldermask top|bottom [(material \"NAME\")] (er X) (substrate-thickness MM) (copper-thickness MM))] " ++
            "[(thickness MM)])",
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
            "records each foil's material/thickness. `(width-reduction MM)` describes the fabricated " ++
            "narrow face of an etched trapezoid relative to its artwork/base width, and " ++
            "`(narrow-side up|down)` orients it toward layer 1 or layer N. " ++
            "`(dielectric AFTER_IDX core|prepreg …)` " ++
            "records the interval immediately below that copper layer (valid gaps are 1 through N-1). A " ++
            "dielectric may also declare its relative permittivity with (er X). `(soldermask …)` records " ++
            "the stepped coating used by impedance control: its height over bare laminate/between traces " ++
            "and its separate height over copper. Controlled-impedance synthesis uses Hammerstad/Cohn/" ++
            "Kirschning closed forms for their ideal domains, then a calibrated 2D capacitance-matrix " ++
            "solve for declared soldermask, trapezoids, mixed-Dk stripline, and other non-ideal " ++
            "cross-sections. A class whose mask artwork opens the trace is analyzed bare; a tented class " ++
            "uses the face's soldermask profile. Undeclared dielectric Dk uses generic FR-4's 4.4, " ++
            "undeclared process geometry stays rectangular/bare, and a board with no dielectric " ++
            "intervals at all has its heights " ++
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
    t[@backingInt(ScopeForm.module_policy)] = .{ .scope = tl, .doc = .{
        .syntax = "(module-policy (net-class \"NET\" ground|power|input_rail|switch_node|clock|rf|feedback|analog|control|signal)…)",
        .summary = "Pin the PCB-layout criticality class of named nets, overriding the name heuristic " ++
            "the placer, the routing order and the `layout_class_inferred` ERC info use " ++
            "(`module_policy.classifyNetName`). One (net-class …) child per net; the net is the " ++
            "FLATTENED name (\"sub-block/NET\" for a module-internal net) or a bare leaf that " ++
            "matches every module-local net of that name. A pinned net is no longer reported as " ++
            "inferred. Unknown class atoms and malformed children are warned and dropped.",
    } };
    t[@backingInt(ScopeForm.net_envelope)] = .{ .scope = tl, .doc = .{
        .syntax = "(net-envelope \"NET\" (rated LO HI) [\"why\"])",
        .summary = "Declare the worst-case DC potential range a net's copper reaches, for the release " ++
            "rating checks. Most nets need no such form: a rail's envelope already follows its own " ++
            "declaration, and it carries across a ferrite bead at any hierarchy depth onto the filtered " ++
            "node beyond it, so a module's internal supply is derived rather than authored. A series " ++
            "resistor likewise carries a known envelope onto the correlated node beyond it (an RC " ++
            "filter's tap, a termination or pull-up's far side, a bias tee fed through its choke), and " ++
            "a node joined to known nets only through series resistors and device pins is bounded by " ++
            "the supplies those devices reach — both derived, never authored. This form is " ++
            "for the nets no topology walk can bound — an enable a 3.3 V GPIO drives, a divider tap " ++
            "sitting between two declared rails, a bus a transceiver holds. The net is named the way a " ++
            "rail is: the FLATTENED name, so a board-level declaration reaches the module-local net " ++
            "bridged onto it and a module-internal node is nameable as \"sub-block/NET\". The optional " ++
            "trailing string records why. A declaration that fails to COVER the envelope the design " ++
            "already proves for that net is a failed assertion, not a silent override — declaring an " ++
            "enable at 3.3 V on a net a 5 V rail also reaches states something untrue.",
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
            "an optional power-branch-width that starts plane-backed rail fanouts narrow and is the authored FLOOR under every branch of the rail (post-route DRC solves each segment's OWN current and reports only the branches that must grow; where a solve exists it — not the class width — is the rule, so a leaf carrying a few milliamps is never charged against the trunk, and where the per-branch solve fails the whole-rail envelope is reported as an explained power_width_envelope WARNING instead of a fab error), " ++
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
            "pad-boundary chord available at its actual path crossing and the nominal line over 1.2 trace " ++
            "widths; this local taper applies to wider and narrower lands even when the net branches, " ++
            "changes sides, or contains vias elsewhere, without expanding a diagonal launch to the pad's " ++
            "longer centre chord. " ++
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
    t[@backingInt(ScopeForm.pll_loop)] = .{ .scope = tl, .doc = .{
        .syntax = "(pll-loop \"name\" (mode advisory|gate) (topology active-inverting) " ++
            "(components (c-cp \"REF\") (r-in \"REF\") (r-feedback \"REF\") " ++
            "(c-feedback \"REF\") (c-feedback-hf \"REF\") (r-isolation \"REF\") (c-tune \"REF\")) " ++
            "[(extra-tune-cap F [TOL_PCT])] (pfd HZ) (charge-pump A [TOL_PCT]) " ++
            "[(charge-pump-full-scale A)] " ++
            "(feedback-divider PRESCALER PLL_N) (kvco MIN_HZ_PER_V MAX_HZ_PER_V) " ++
            "[(operating-curve (point PLL_N KVCO_HZ_PER_V)…)] " ++
            "[(synthesize [(series e24)] [(resistance-range MIN MAX)] [(capacitance-range MIN MAX)] " ++
            "[(pinned \"KEY\" (c-cp F) (r-in R) (r-feedback R) (c-feedback F) (c-feedback-hf F) (r-isolation R) (c-tune F))])] " ++
            "(op-amp (gbw HZ) [(dc-gain RATIO)]) [(phase-margin (target MIN MAX) (hard-min DEG))] " ++
            "(polarity positive|negative) [(supply MIN_V MAX_V)] [(op-amp-max-supply V)] " ++
            "[(vtune MIN_V MAX_V)] [(output-headroom LOW_V HIGH_V)] " ++
            "[(ramp SPAN_HZ TIME_S)] [(max-ramp-phase-error RAD)] [(slew-rate V_PER_S)])",
        .summary = "Validate an inverting active charge-pump PLL directly from the named BOM R/C values and tolerances. " ++
            "The continuous-time small-signal solver includes finite op-amp gain/GBW, the external prescaler in N_eff, " ++
            "Kvco and deterministic component corners, then emits ordinary build/check assertions for crossover, phase " ++
            "margin, PFD/GBW ratios, polarity, output swing, and an approximate FMCW ramp phase-error/slew screen. " ++
            "An operating curve plus synthesize form searches E24 passive values and an ADF4159 charge-pump schedule " ++
            "quantized to 16 steps of (charge-pump-full-scale …) — default 5 mA; author the RSET-derived value, e.g. 4.8 mA at 5.1 kΩ — " ++
            "then verifies the proposal over interpolated operating points and exact component/current corners; the " ++
            "populated values are screened under that same quantized I_CP schedule too, so their scheduled-face margins " ++
            "print beside the deliberately pessimistic fixed-I_CP face. " ++
            "The search costs seconds and runs inside design evaluation, so every unpinned build prints a ready-to-paste " ++
            "(pinned \"KEY\" …) line carrying its winning values and a content key covering everything it read plus those " ++
            "values themselves; authoring that " ++
            "line inside synthesize makes later evaluations replay the result without searching, for identical assertions. " ++
            "A pin whose key no longer matches — any change to the declaration, the resolved values, or the pinned values " ++
            "themselves — is ignored with a " ++
            "warning and the full search runs, so pinning can only skip recomputation, never change an answer. " ++
            "Use advisory mode while Kvco or firmware Icp is provisional; gate mode makes failed limits build-blocking. " ++
            "This is not a sampled-PFD, phase-noise, nonlinear acquisition, SPICE, or capacitive-load-stability sign-off.",
    } };
    t[@backingInt(ScopeForm.frequency_plan)] = .{ .scope = tl, .doc = .{
        .syntax = "(frequency-plan \"name\" (mode advisory|gate) (output-band LO_HZ HI_HZ) " ++
            "[(source [(range LO_HZ HI_HZ)] [(delivered LO_HZ HI_HZ)])] " ++
            "(lo HZ [(drive DBM)] [(drive-window MIN_DBM MAX_DBM)]) " ++
            "(mixer difference [(sideband high|low|either)]) " ++
            "[(if-filter (low-pass HZ))] [(rf-filter [(low-pass HZ)] [(high-pass HZ)])] " ++
            "[(spurs [(max-order M)] [(in-band-limit DBC)])] " ++
            "[(spur-table (product M N DBC)…)])",
        .summary = "Screen a fixed-LO downconversion frequency plan and enumerate its spurious products. " ++
            "(output-band) is what the instrument is commanded to deliver, (lo) the fixed local oscillator, and " ++
            "(mixer difference (sideband …)) selects RF = LO + IF (high), LO − IF (low), or plans BOTH (either). " ++
            "From those the swept RF window is exact, so band closure against the source's (delivered) passband and " ++
            "(range) is a containment test that names the uncovered sub-interval and the output frequencies it costs — " ++
            "the check that decides an LO choice instead of arguing about it. The image sideband is placed and " ++
            "reported as rejected only when a declared (rf-filter) cutoff or the delivered passband actually excludes it. " ++
            "Every (m,n) product is enumerated by INTERVAL arithmetic over the whole RF sweep rather than by sampling: " ++
            "|m·RF − n·LO| is folded onto the positive axis (into two branches when it crosses DC inside the sweep, so a " ++
            "straddling product is correctly seen to reach down to DC) and classified co-channel with the output band, " ++
            "rejected by a declared (if-filter) cutoff, or out of band. The (m,m) diagonal family, which lands on exact " ++
            "multiples of the commanded IF and so cannot be moved by retuning the LO, is counted at the band's low edge " ++
            "with the IF above which the band carries none. Filters are modelled at CUTOFF level only — a product is " ++
            "rejected when its whole interval lies beyond a declared cutoff; there is no rolloff, insertion loss, or " ++
            "group delay. Levels are claimed ONLY where (spur-table (product M N DBC)) supplies measured or datasheet " ++
            "suppression, checked against (spurs (in-band-limit DBC)); every other row is a placement with no level " ++
            "attached, and an unlevelled co-channel product is reported as such rather than assumed small. " ++
            "(spurs (max-order M)) bounds enumeration at 9. Sum mixing is refused rather than approximated. " ++
            "Use advisory mode while an LO frequency or a drive measurement is provisional; gate mode makes a failed " ++
            "plan limit build-blocking. This is not a phase-noise, reciprocal-mixing, compression, or two-tone " ++
            "intermodulation analysis.",
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
            "toolchain's built-in default (clearance 0.127, min-drill 0.2, mask-margin 0, mask-relief-corner-radius 0, copper-edge = " ++
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

// ── Sub-form registries ────────────────────────────────────────────────
// The tables above cover the head atoms `evalForm` and the scope dispatch
// switch on. Compound forms carry their OWN grammar one level down —
// `(instance … (pin …) (near …))`, `(sub-block … (bridge …))`,
// `(component … (requirement …))` — matched by head atom rather than by an
// enum, so there is no variant for `requireAllDocumented` to hang off.
// Each table below is instead the single source of truth for one compound
// form's children: the evaluator derives its accepted-children /
// reserved-head-atom list from the table, `docgen.zig` renders the same rows
// into the reference, and its coverage test fails when a new `isForm("…")`
// head appears under `src/eval` that no registry names.

/// One documented child of a compound form.
pub const SubFormDoc = struct {
    /// Head atom exactly as written in source.
    name: []const u8,
    /// The source template a human would write.
    syntax: []const u8,
    /// One-line description for the generated reference.
    summary: []const u8,
    /// Head atom of the sibling row this one is written inside, or "" when it
    /// is a direct child of the compound form. A nested row is documented but
    /// stays out of the accepted-direct-children set, so a misplaced
    /// `(rename …)` under `(sub-block …)` still warns.
    within: []const u8 = "",
    /// Whether the compound form's own body reserves this head atom — refuses
    /// to re-read it as something else. An `(instance …)` body turns any
    /// unreserved `(key "value")` child into an inline property, so the
    /// reserved set is exactly what it must not capture. Direct children are
    /// always reserved; a nested row sets this only when the outer parser
    /// guards the atom too.
    reserved: bool = true,
};

/// True when `name` is a row of `table`, nested rows included.
pub fn isSubForm(table: []const SubFormDoc, name: []const u8) bool {
    for (table) |row| {
        if (std.mem.eql(u8, row.name, name)) return true;
    }
    return false;
}

/// True when `name` is accepted DIRECTLY under the compound form `table`
/// describes. Accepted-children checks compare against this.
pub fn isDirectSubForm(table: []const SubFormDoc, name: []const u8) bool {
    for (table) |row| {
        if (row.within.len == 0 and std.mem.eql(u8, row.name, name)) return true;
    }
    return false;
}

/// How many rows of `table` the compound form reserves.
fn reservedSubFormCount(comptime table: []const SubFormDoc) usize {
    var n: usize = 0;
    for (table) |row| {
        if (row.reserved) n += 1;
    }
    return n;
}

/// The head atoms a compound form reserves — what a parser compares against
/// before falling back to its catch-all reading. Returned by value so the
/// caller's `const` owns the array.
pub fn reservedSubFormNames(comptime table: []const SubFormDoc) [reservedSubFormCount(table)][]const u8 {
    var out: [reservedSubFormCount(table)][]const u8 = undefined;
    var n: usize = 0;
    for (table) |row| {
        if (!row.reserved) continue;
        out[n] = row.name;
        n += 1;
    }
    return out;
}

/// Comptime-reject a table that names one head atom twice — a duplicate would
/// double a reference row and make the derived name lists ambiguous.
fn requireUniqueSubFormNames(comptime table: []const SubFormDoc) void {
    comptime {
        for (table, 0..) |row, i| {
            for (table[i + 1 ..]) |other| {
                if (std.mem.eql(u8, row.name, other.name))
                    @compileError("duplicate sub-form row '" ++ row.name ++ "'");
            }
        }
    }
}

/// Comptime-reject a row that nests inside a form the table never declares,
/// or a direct child marked unreserved (a direct child is reserved by
/// definition — the parser dispatches on it).
fn requireSubFormParents(comptime table: []const SubFormDoc) void {
    comptime {
        for (table) |row| {
            if (row.within.len == 0 and !row.reserved)
                @compileError("direct sub-form '" ++ row.name ++ "' is always reserved");
            if (row.within.len != 0 and !isSubForm(table, row.within))
                @compileError("sub-form '" ++ row.name ++ "' nests inside unknown '" ++ row.within ++ "'");
        }
    }
}

/// Validate a sub-form table at compile time and return it, so a declaration
/// can wrap its literal in this call and get the checks for free.
pub fn requireWellFormedSubForms(comptime table: []const SubFormDoc) []const SubFormDoc {
    comptime {
        requireUniqueSubFormNames(table);
        requireSubFormParents(table);
        return table;
    }
}

/// Children of an `(instance "REF" component …)` body. `eval/instance.zig`
/// derives its reserved-head-atom list from this table with
/// `reservedSubFormNames`: a `(key "value")` child whose head is NOT reserved
/// here becomes an inline property override on the placed part — which is how
/// `(mpn "…")`, `(class ldo)` and `(module-bypass "reason")` are written — so
/// adding a row changes what the evaluator accepts.
pub const instance_form_docs = requireWellFormedSubForms(&[_]SubFormDoc{
    .{
        .name = "pin",
        .syntax = "(pin PAD… \"NET\" [(as \"FN\"…)] [(i-typ A)] [(i-max A)] [(load \"label\")])",
        .summary = "Wire one or more of this part's pads to a net. A pad token is a physical pad id or a " ++
            "pinout function name; every pad listed on one form lands on the same net.",
    },
    .{
        .name = "as",
        .within = "pin",
        .syntax = "(pin PAD \"NET\" (as \"FN\"…))",
        .summary = "Assert the pad resolves to these pinout function names — the spelling guard that warns " ++
            "when the library pinout disagrees. Honoured only on a single-pad `(pin …)`. Reserved at " ++
            "instance level too, so a stray one is never read as a property.",
    },
    .{
        .name = "i-typ",
        .within = "pin",
        .reserved = false,
        .syntax = "(pin … (i-typ AMPS))",
        .summary = "Typical current this pad draws or sources, feeding the rail budget and the thermal screen.",
    },
    .{
        .name = "i-max",
        .within = "pin",
        .reserved = false,
        .syntax = "(pin … (i-max AMPS))",
        .summary = "Worst-case current for the same budgets.",
    },
    .{
        .name = "load",
        .within = "pin",
        .reserved = false,
        .syntax = "(pin … (load \"label\"))",
        .summary = "Name the load this pad represents so the power budget can attribute the current to it.",
    },
    .{
        .name = "part",
        .syntax = "(part \"Name\" [(row N)] [(col N)] (pin …)…)",
        .summary = "Group pins into one labelled unit of a multi-part symbol. Each inner `(pin …)` wires " ++
            "exactly like a top-level one; the grouping only changes how the schematic draws the part.",
    },
    .{
        .name = "row",
        .within = "part",
        .reserved = false,
        .syntax = "(part … (row N))",
        .summary = "Grid hint on a part group. Accepted and inert — multi-part units are placed automatically.",
    },
    .{
        .name = "col",
        .within = "part",
        .reserved = false,
        .syntax = "(part … (col N))",
        .summary = "The column half of the same inert grid hint.",
    },
    .{
        .name = "bus",
        .syntax = "(bus \"NET_PREFIX\" BUS_NAME)",
        .summary = "Expand a bus the component's library definition declares: lane i of BUS_NAME is wired " ++
            "to `NET_PREFIX<i>`.",
    },
    .{
        .name = "note",
        .syntax = "(note \"text\")",
        .summary = "Attach a note to this part; it renders on the instance in the schematic.",
    },
    .{
        .name = "power",
        .syntax = "(power WATTS | (typ WATTS) (max WATTS))",
        .summary = "What this part dissipates, for the thermal screening — see “Thermal declarations”.",
    },
    .{
        .name = "dnp",
        .syntax = "(dnp)",
        .summary = "Do Not Populate: the part keeps its schematic symbol and its footprint on the board, " ++
            "and leaves the assembly BOM.",
    },
    .{
        .name = "decouples",
        .syntax = "(decouples \"IC\" PIN) | (decouples rail)",
        .summary = "Bind this capacitor's power leg to a specific hub pad, or opt the cap out of the " ++
            "per-pin decoupling lint because it deliberately serves the whole rail. PIN is resolved " ++
            "against the named IC's pinout, not this part's.",
    },
    .{
        .name = "near",
        .syntax = "(near \"REF\" PIN [(own PAD)])",
        .summary = "Place this part beside REF's pad PIN. PIN resolves against the TARGET's pinout, which " ++
            "is why it is kept raw until every instance exists.",
    },
    .{
        .name = "own",
        .within = "near",
        .reserved = false,
        .syntax = "(near … (own PAD))",
        .summary = "Which pad of THIS part faces the target — resolved through this part's own pinout.",
    },
    .{
        .name = "strap-ok",
        .syntax = "(strap-ok PIN \"reason\")",
        .summary = "Sign off a pin tied straight to a rail, satisfying the `strap_tied_to_rail` ERC rule.",
    },
    .{
        .name = "nc-ok",
        .syntax = "(nc-ok PIN \"reason\")",
        .summary = "Sign off a deliberately unconnected pad, satisfying the `no_connect` ERC rule.",
    },
    .{
        .name = "id",
        .syntax = "(id hex8)",
        .summary = "Stable identity anchor. The build mints one into the source when it is missing.",
    },
});

/// Children of a `(pins "REF" …)` block — the out-of-line way to wire an
/// already-placed part. `eval/builders.isKnownPinsChild` derives its
/// accepted set from the direct rows here.
pub const pins_form_docs = requireWellFormedSubForms(&[_]SubFormDoc{
    .{
        .name = "pin",
        .syntax = "(pin PAD… \"NET\" [(as \"FN\"…)] [(i-typ A)] [(i-max A)] [(load \"label\")])",
        .summary = "Identical to the `(instance … (pin …))` form, including its annotations — the two " ++
            "paths share one parser. Wiring a pad whose pinout function name differs from the net also " ++
            "records a function-name alias.",
    },
    .{
        .name = "bus",
        .syntax = "(bus \"NET_PREFIX\" [(as-prefix \"FN_PREFIX\")] LANE… | (LANE…)…)",
        .summary = "Wire a run of lanes in one form: lane i lands on `NET_PREFIX<i>`. Lane tokens may be " ++
            "listed flat or in parenthesised groups; both emit the same nets.",
    },
    .{
        .name = "as-prefix",
        .within = "bus",
        .reserved = false,
        .syntax = "(bus … (as-prefix \"FN_PREFIX\"))",
        .summary = "Auto-assert lane i as pinout function `FN_PREFIX<i>`, so a wide bus need not be " ++
            "expanded into one `(pin … (as …))` form per lane just to pass the pin-function check.",
    },
    .{
        .name = "group",
        .syntax = "(group \"label\")",
        .summary = "Label every pin this block declares, so the schematic draws them as one named group. " ++
            "Unrelated to the design-scope `(group …)` member list.",
    },
});

/// Children of a `(sub-block "name" (module-call …) …)` form.
/// `eval/builders.buildSubBlock` derives its accepted set from the direct
/// rows here, so an unknown child still warns instead of going silently dead.
pub const sub_block_form_docs = requireWellFormedSubForms(&[_]SubFormDoc{
    .{
        .name = "bridge",
        .syntax = "(bridge \"PREFIX\" PORT… [(rename PORT SUFFIX)]…)",
        .summary = "Wire the sub-block's ports to board nets without one `(net …)` line each: every " ++
            "bridged port P ties board net `PREFIX<suffix>` to module net `<name>/P`, with <suffix> " ++
            "defaulting to P. With an empty PREFIX and a `(rename …)` per port the form reads as a " ++
            "port-to-net map. Power and ground ports are normally left out and wired by the " ++
            "consolidated `(net …)` rails instead.",
    },
    .{
        .name = "rename",
        .within = "bridge",
        .reserved = false,
        .syntax = "(bridge … (rename PORT SUFFIX))",
        .summary = "Override one port's board-side suffix, so SPI `CS` can reach board net `…NCS` — or, " ++
            "with an empty prefix, name the board net outright.",
    },
    .{
        .name = "id",
        .syntax = "(id hex8)",
        .summary = "Stable identity anchor for the sub-block itself.",
    },
    .{
        .name = "ids",
        .syntax = "(ids (\"origin-key\" hex8)…)",
        .summary = "Sidecar pinning the identities of children minted inside this sub-block. Designs that " ++
            "declare `(hierarchical-ids)` derive them from the form id instead and need no sidecar.",
    },
    .{
        .name = "reflow",
        .syntax = "(reflow)",
        .summary = "Opt this sub-block out of module-layout composition, so the parent lays its contents " ++
            "out from scratch rather than reusing the module's own arrangement.",
    },
});

/// Children of a `(port …)` declaration. The port parser reads these by head
/// atom and warns on anything else, so the table is documentation rather than
/// a derived accepted set.
pub const port_form_docs = requireWellFormedSubForms(&[_]SubFormDoc{
    .{
        .name = "rated",
        .syntax = "(rated LO HI)",
        .summary = "The absolute voltage window this port's net may sit in; the release rating checks " ++
            "compare the design's proven envelope against it.",
    },
    .{
        .name = "nominal",
        .syntax = "(nominal VOLTS)",
        .summary = "The port's nominal voltage. The argument is evaluated, so a regulator module can " ++
            "publish an output computed from its own feedback-divider parameters. A bare trailing " ++
            "number means the same thing.",
    },
    .{
        .name = "current",
        .syntax = "(current TYP [MAX])",
        .summary = "What the port carries, feeding the rail budget.",
    },
    .{
        .name = "efficiency",
        .syntax = "(efficiency RATIO) | (efficiency linear)",
        .summary = "Conversion efficiency of the module behind an output port, so its input draw and " ++
            "dissipation can be back-computed. `linear` states the pass-through case.",
    },
    .{
        .name = "enable",
        .syntax = "(enable \"NET\")",
        .summary = "The net that gates this port, tying the rail to its sequencing.",
    },
    .{
        .name = "electrical",
        .syntax = "(electrical [(type …)] [(drive …)] [(v-ih-min V)] [(v-il-max V)] [(v-oh-typ V)] " ++
            "[(v-ol-typ V)] [(max-voltage V)] [(domain NAME)])",
        .summary = "Logic thresholds and drive class for the port, so the level-compatibility checks can " ++
            "run across a boundary. Same grammar as a component's `(electrical …)`, minus its pin name.",
    },
    .{
        .name = "side",
        .syntax = "(side left|right|top|bottom)",
        .summary = "Where this port's net enters or leaves the module — the PCB rough placer's explicit " ++
            "flow hint, overriding the direction heuristic.",
    },
});

/// Head atoms accepted in design scope that carry identity or layout intent
/// rather than circuit content. `eval/design_block.isInertFormHead` derives
/// its set from the direct rows here, so these never draw an
/// unknown-sub-form warning.
pub const marker_form_docs = requireWellFormedSubForms(&[_]SubFormDoc{
    .{
        .name = "id",
        .syntax = "(id hex8)",
        .summary = "Stable identity anchor on the enclosing form, minted into the source by the build.",
    },
    .{
        .name = "ids",
        .syntax = "(ids (\"origin-key\" hex8)…)",
        .summary = "Enumerated identity sidecar for the children a form emits — decoupling caps, series " ++
            "elements, repeat iterations, sub-block contents.",
    },
    .{
        .name = "hierarchical-ids",
        .syntax = "(hierarchical-ids)",
        .summary = "Design-block marker opting into derived child identity: every emitted child's uuid " ++
            "comes from its parent form's `(id …)` plus a structural key, so no `(ids …)` sidecar is " ++
            "written and a renumber cannot shuffle identities.",
    },
    .{
        .name = "row",
        .syntax = "(row N)",
        .summary = "Grid row for a section in the system diagram. A section with both a row and a column " ++
            "seeds the block-diagram layout when no `(diagram-layout …)` is authored.",
    },
    .{
        .name = "col",
        .syntax = "(col N)",
        .summary = "Grid column for the same section placement.",
    },
});

/// Fields of a `lib/components/<name>.sexp` `(component …)` or
/// `(component-family …)` definition. `eval/modules.zig` derives its
/// structural-field list from the direct rows here; any other `(key "value")`
/// child becomes an inline property carried onto every placed instance, which
/// is how `(class ldo)`, `(mpn "…")` and `(manufacturer "…")` are written.
pub const component_form_docs = requireWellFormedSubForms(&[_]SubFormDoc{
    .{
        .name = "symbol",
        .syntax = "(symbol \"name\")",
        .summary = "The schematic symbol to draw, resolved in `lib/symbols/`.",
    },
    .{
        .name = "footprint",
        .syntax = "(footprint name)",
        .summary = "The land pattern to place, resolved in `lib/footprints/`.",
    },
    .{
        .name = "pinout",
        .syntax = "(pinout \"name\")",
        .summary = "The pad-to-function map in `lib/pinouts/` that lets designs wire this part by " ++
            "function name. Defaults to the symbol name when omitted.",
    },
    .{
        .name = "description",
        .syntax = "(description \"text\")",
        .summary = "One-line part description, surfaced on every instance so renderers need not re-read " ++
            "the library file.",
    },
    .{
        .name = "parameter",
        .syntax = "(parameter NAME TYPE)",
        .summary = "`(component-family …)` only: names the value a call site supplies, e.g. " ++
            "`(cap-0402 \"100nF\")`.",
    },
    .{
        .name = "refdes",
        .syntax = "(refdes \"U\")",
        .summary = "Explicit ref-des class letter for this part's instances, overriding the family-name " ++
            "heuristic.",
    },
    .{
        .name = "bus",
        .syntax = "(bus \"name\" PIN…)",
        .summary = "Name an ordered pin group a design can wire in one step with the instance-level " ++
            "`(bus …)` sub-form.",
    },
    .{
        .name = "note",
        .syntax = "(note \"text\")",
        .summary = "Library note about the part.",
    },
    .{
        .name = "datasheet",
        .syntax = "(datasheet \"file.pdf\")",
        .summary = "One declared datasheet — a filename in `lib/datasheets/` or an absolute http(s) URL. " ++
            "See “Datasheet review preflight”.",
    },
    .{
        .name = "datasheet-review",
        .syntax = "(datasheet-review (datasheet \"…\") (sha256 \"…\") (status …) (reviewed-by \"…\") " ++
            "(date \"…\") (category KEY)… [(category-na KEY \"why\")…])",
        .summary = "Bind this part's requirement review to an exact PDF; replacing the file makes the " ++
            "review stale. See “Datasheet review preflight” for the full record.",
    },
    .{
        .name = "requirement",
        .syntax = "(requirement \"text\" [(ref \"file.pdf\" (page N) (quote \"…\"))] [(check …)] [(id \"…\")])",
        .summary = "A datasheet rule every design placing this part inherits. See “Requirement checks” " ++
            "for the executable `(check …)` grammar.",
    },
    .{
        .name = "ref",
        .within = "requirement",
        .reserved = false,
        .syntax = "(ref \"file.pdf\" [(page N)] [(quote \"…\")])",
        .summary = "The citation backing a requirement or a note: which declared PDF, which page, and the " ++
            "sentence it rests on. The release profile requires one on every requirement.",
    },
    .{
        .name = "page",
        .within = "ref",
        .reserved = false,
        .syntax = "(ref … (page N))",
        .summary = "1-based page number inside the cited PDF.",
    },
    .{
        .name = "quote",
        .within = "ref",
        .reserved = false,
        .syntax = "(ref … (quote \"…\"))",
        .summary = "The short source quote copied from that page.",
    },
    .{
        .name = "check",
        .within = "requirement",
        .reserved = false,
        .syntax = "(requirement … (check …))",
        .summary = "The machine-checkable half of the rule; an unrecognised one warns rather than passing " ++
            "silently. See “Requirement checks”.",
    },
    .{
        .name = "ignore-requirements",
        .syntax = "(ignore-requirements)",
        .summary = "Opt this part out of requirement inheritance entirely — for passives and connectors " ++
            "whose datasheet carries no design rules.",
    },
    .{
        .name = "electrical",
        .syntax = "(electrical \"PIN\" [(type …)] [(drive …)] [(v-ih-min V)] [(v-il-max V)] " ++
            "[(v-oh-typ V)] [(v-ol-typ V)] [(max-voltage V)] [(domain NAME)])",
        .summary = "Per-pin logic thresholds and drive class, one form per pin, for the " ++
            "level-compatibility checks.",
    },
    .{
        .name = "thermal",
        .syntax = "(thermal …)",
        .summary = "The part's thermal envelope — see “Thermal declarations” for the sub-forms.",
    },
});

/// Head atoms an `(instance …)` body must not read as an inline property.
pub const instance_reserved_forms = reservedSubFormNames(instance_form_docs);

/// Head atoms a `(component …)` / `(component-family …)` body must not read as
/// an inline property: every structural field the registry documents, plus the
/// two definition head atoms themselves, so a nested definition is skipped
/// rather than turned into a property.
pub const component_reserved_fields = reservedSubFormNames(component_form_docs) ++
    [_][]const u8{ "component", "component-family" };

/// Every sub-form registry, in the order `docgen.zig` renders them. The
/// coverage test walks this list, so a new table is checked the moment it is
/// added here.
pub const sub_form_tables = [_][]const SubFormDoc{
    instance_form_docs,
    pins_form_docs,
    sub_block_form_docs,
    port_form_docs,
    marker_form_docs,
    component_form_docs,
};

/// True when any sub-form registry documents `name`.
pub fn isRegisteredSubForm(name: []const u8) bool {
    for (sub_form_tables) |table| {
        if (isSubForm(table, name)) return true;
    }
    return false;
}

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

// spec: eval/forms - The instance sub-form registry reserves exactly the head atoms an instance body must not read as an inline property
test "instance sub-form registry reserves the instance body head atoms" {
    // Reserved = every direct child plus `(as …)`, which is written inside
    // `(pin …)` but guarded at instance level so a stray one is not a property.
    const expected = [_][]const u8{
        "pin", "as",        "part", "bus",      "note",  "power",
        "dnp", "decouples", "near", "strap-ok", "nc-ok", "id",
    };
    try std.testing.expectEqual(expected.len, instance_reserved_forms.len);
    for (expected) |name| {
        try std.testing.expect(containsName(&instance_reserved_forms, name));
    }
    // The pin annotations are documented but NOT reserved: `(load "x")` at
    // instance level still reads as an inline property, as it always has.
    try std.testing.expect(isSubForm(instance_form_docs, "load"));
    try std.testing.expect(!containsName(&instance_reserved_forms, "load"));
}

// spec: eval/forms - The sub-block sub-form registry accepts bridge, id, ids and reflow directly and keeps rename nested inside bridge
test "sub-block sub-form registry separates direct children from bridge's rename" {
    for ([_][]const u8{ "bridge", "id", "ids", "reflow" }) |name| {
        try std.testing.expect(isDirectSubForm(sub_block_form_docs, name));
    }
    // `(rename …)` is legal only inside `(bridge …)`, so a misplaced one must
    // still fail the accepted-children check and warn.
    try std.testing.expect(isSubForm(sub_block_form_docs, "rename"));
    try std.testing.expect(!isDirectSubForm(sub_block_form_docs, "rename"));
    try std.testing.expect(!isDirectSubForm(sub_block_form_docs, "net"));
}

// spec: eval/forms - The pins-block sub-form registry accepts pin, bus and group directly and keeps as-prefix nested inside bus
test "pins-block sub-form registry accepts pin, bus and group" {
    for ([_][]const u8{ "pin", "bus", "group" }) |name| {
        try std.testing.expect(isDirectSubForm(pins_form_docs, name));
    }
    try std.testing.expect(!isDirectSubForm(pins_form_docs, "as-prefix"));
    try std.testing.expect(isSubForm(pins_form_docs, "as-prefix"));
}

// spec: eval/forms - The component sub-form registry reserves every structural field plus both definition head atoms
test "component registry reserves the structural fields and the definition heads" {
    for ([_][]const u8{
        "symbol",     "footprint",           "pinout",      "parameter",
        "refdes",     "bus",                 "note",        "datasheet",
        "electrical", "ignore-requirements", "thermal",     "requirement",
        "component",  "component-family",    "description",
    }) |name| {
        try std.testing.expect(containsName(&component_reserved_fields, name));
    }
    // A requirement's citation forms are documented but stay unreserved, so a
    // top-level `(class ldo)`-style property child is unaffected.
    try std.testing.expect(!containsName(&component_reserved_fields, "ref"));
    try std.testing.expect(!containsName(&component_reserved_fields, "class"));
}

/// (test helper) True when `names` holds `needle`.
fn containsName(names: []const []const u8, needle: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}
