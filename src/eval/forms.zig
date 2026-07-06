const std = @import("std");

/// Top-level special form recognised by `evalForm`. Each variant
/// corresponds to a head atom in the S-expression source. Keeping the
/// mapping in one table makes typo-style bugs ("difmodule" silently
/// becoming an unbound-variable lookup) impossible and turns every
/// dispatch site into a `switch` Zig can check for exhaustiveness.
pub const SpecialForm = enum {
    let,
    if_,
    import,
    defmodule,
    design_block,
    block,
    assert_,
    assert_range,
    fmt_,
    id_,

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
    .{ "if", .if_ },
    .{ "import", .import },
    .{ "defmodule", .defmodule },
    .{ "design-block", .design_block },
    .{ "block", .block },
    .{ "assert", .assert_ },
    .{ "assert-range", .assert_range },
    .{ "fmt", .fmt_ },
    .{ "id", .id_ },
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
    revision,
    rough,
    stackup,
    net_class,
    design_rules,

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
    .{ "revision", .revision },
    .{ "rough", .rough },
    .{ "stackup", .stackup },
    .{ "net-class", .net_class },
    .{ "design-rules", .design_rules },
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
        .{ .if_, .{ .min_args = 3, .max_args = 3 } },
        .{ .import, .{ .min_args = 1, .max_args = null } },
        .{ .defmodule, .{ .min_args = 2, .max_args = null } },
        .{ .design_block, .{ .min_args = 1, .max_args = null } },
        .{ .block, .{ .min_args = 1, .max_args = null } },
        .{ .assert_, .{ .min_args = 2, .max_args = 2 } },
        .{ .assert_range, .{ .min_args = 4, .max_args = 4 } },
        .{ .fmt_, .{ .min_args = 1, .max_args = null } },
    };
    var table: [@typeInfo(SpecialForm).@"enum".fields.len]?FormSchema = @splat(null);
    for (pairs) |p| table[@intFromEnum(p[0])] = p[1];
    break :blk table;
};

/// Look up the schema for a special form. Returns `null` when no
/// arity contract is declared (only `.id_` is unconstrained).
pub fn schemaFor(sf: SpecialForm) ?FormSchema {
    return special_form_schema[@intFromEnum(sf)];
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
fn requireAllDocumented(
    comptime E: type,
    comptime T: type,
    comptime table: [@typeInfo(E).@"enum".fields.len]?T,
) [@typeInfo(E).@"enum".fields.len]T {
    var out: [table.len]T = undefined;
    for (table, 0..) |entry, i| {
        out[i] = entry orelse @compileError("missing doc-table row for " ++
            @typeName(E) ++ "." ++ @typeInfo(E).@"enum".fields[i].name ++
            " — every form must be documented (see docs/language-forms.md)");
    }
    return out;
}

pub const special_form_docs = blk: {
    const N = @typeInfo(SpecialForm).@"enum".fields.len;
    var t: [N]?FormDoc = @splat(null);
    t[@intFromEnum(SpecialForm.let)] = .{
        .syntax = "(let name expr)",
        .summary = "Bind `name` to the evaluated value of `expr` in the current scope.",
    };
    t[@intFromEnum(SpecialForm.if_)] = .{
        .syntax = "(if cond then else)",
        .summary = "Short-circuit conditional. Only the matching branch is evaluated.",
    };
    t[@intFromEnum(SpecialForm.import)] = .{
        .syntax = "(import name…)",
        .summary = "Load library components or modules by name. Searches `lib/components/` then `lib/modules/`.",
    };
    t[@intFromEnum(SpecialForm.defmodule)] = .{
        .syntax = "(defmodule name (param | (param default)…) [\"docstring\"] body…)",
        .summary = "Define a parameterised module that closes over the surrounding env. " ++
            "A `(param default)` pair makes the argument optional — its default evaluates at " ++
            "call time when omitted, so a fully-defaulted module also renders standalone.",
    };
    t[@intFromEnum(SpecialForm.design_block)] = .{
        .syntax = "(design-block \"name\" form…)",
        .summary = "The root container — every `.sexp` design file evaluates to one.",
    };
    t[@intFromEnum(SpecialForm.block)] = .{
        .syntax = "(block \"name\" form… | name (param | (param default)…) [\"docstring\"] body…)",
        .summary = "The unified circuit definition. A string name is an eager design root " ++
            "(identical to `(design-block …)`); a bare-atom name with a parameter list is a " ++
            "parameterised, embeddable definition (identical to `(defmodule …)`). " ++
            "`(design-block …)` and `(defmodule …)` remain as permanent aliases.",
    };
    t[@intFromEnum(SpecialForm.assert_)] = .{
        .syntax = "(assert cond \"message\")",
        .summary = "Record a pass/fail entry. Failures surface in the review report, never aborts the build.",
    };
    t[@intFromEnum(SpecialForm.assert_range)] = .{
        .syntax = "(assert-range value lo hi \"label\")",
        .summary = "Record an assertion that `value` is in `[lo, hi]`, with a formatted diagnostic.",
    };
    t[@intFromEnum(SpecialForm.fmt_)] = .{
        .syntax = "(fmt \"template\" args…)",
        .summary = "Format a string. See the “String formatting directives” table for the `~X` specifiers.",
    };
    t[@intFromEnum(SpecialForm.id_)] = .{
        .syntax = "(id <hex8>)",
        .summary = "Stable 8-char identifier auto-inserted by the build. Evaluator short-circuits to `.nil`.",
    };
    break :blk requireAllDocumented(SpecialForm, FormDoc, t);
};

pub const builtin_docs = blk: {
    const N = @typeInfo(Builtin).@"enum".fields.len;
    var t: [N]?FormDoc = @splat(null);
    t[@intFromEnum(Builtin.add)] = .{ .syntax = "(+ a b)", .summary = "Numeric addition." };
    t[@intFromEnum(Builtin.sub)] = .{ .syntax = "(- a b)", .summary = "Numeric subtraction." };
    t[@intFromEnum(Builtin.mul)] = .{ .syntax = "(* a b)", .summary = "Numeric multiplication." };
    t[@intFromEnum(Builtin.div)] = .{ .syntax = "(/ a b)", .summary = "Numeric division. Errors on divide-by-zero." };
    t[@intFromEnum(Builtin.mod)] = .{ .syntax = "(% a b)", .summary = "Numeric modulo. Errors on divide-by-zero." };
    t[@intFromEnum(Builtin.gt)] = .{ .syntax = "(> a b)", .summary = "Numeric greater-than → boolean." };
    t[@intFromEnum(Builtin.gte)] = .{ .syntax = "(>= a b)", .summary = "Numeric greater-or-equal → boolean." };
    t[@intFromEnum(Builtin.lt)] = .{ .syntax = "(< a b)", .summary = "Numeric less-than → boolean." };
    t[@intFromEnum(Builtin.lte)] = .{ .syntax = "(<= a b)", .summary = "Numeric less-or-equal → boolean." };
    t[@intFromEnum(Builtin.eq)] = .{
        .syntax = "(== a b)",
        .summary = "Equality, defined for number-number and string-string.",
    };
    t[@intFromEnum(Builtin.neq)] = .{
        .syntax = "(!= a b)",
        .summary = "Inequality, defined for number-number and string-string.",
    };
    t[@intFromEnum(Builtin.and_)] = .{ .syntax = "(and a b)", .summary = "Boolean and (eager — both args evaluated)." };
    t[@intFromEnum(Builtin.or_)] = .{ .syntax = "(or a b)", .summary = "Boolean or (eager — both args evaluated)." };
    t[@intFromEnum(Builtin.not_)] = .{ .syntax = "(not a)", .summary = "Boolean negation." };
    t[@intFromEnum(Builtin.e96)] = .{ .syntax = "(e96 r)", .summary = "Snap a resistance/number to the nearest E96 (1%) standard value." };
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
    const N = @typeInfo(ScopeForm).@"enum".fields.len;
    var t: [N]?ScopedFormDoc = @splat(null);

    const all = ScopeAvailability{ .design_block = true, .section = true, .sub_section = true };
    const dsec = ScopeAvailability{ .design_block = false, .section = true, .sub_section = true };
    const tl = ScopeAvailability{ .design_block = true, .section = false, .sub_section = false };
    const sec = ScopeAvailability{ .design_block = false, .section = true, .sub_section = false };

    t[@intFromEnum(ScopeForm.instance)] = .{ .scope = all, .doc = .{
        .syntax = "(instance \"REF\" component pin…)",
        .summary = "Place a component with inline pin-to-net bindings.",
    } };
    t[@intFromEnum(ScopeForm.port)] = .{ .scope = all, .doc = .{
        .syntax = "(port \"name\" [net] dir [kind] [(rated lo hi)] [(side left|right|top|bottom)])",
        .summary = "Declare a block boundary signal. A power/rf port's direction (or an explicit (side …)) tells the PCB " ++
            "rough placer where the net enters/leaves the module — in → left, out → right.",
    } };
    t[@intFromEnum(ScopeForm.bus_port)] = .{ .scope = all, .doc = .{
        .syntax = "(bus-port \"prefix\" width dir …)",
        .summary = "Declare a multi-bit boundary bus that expands to one port per lane.",
    } };
    t[@intFromEnum(ScopeForm.note)] = .{ .scope = all, .doc = .{
        .syntax = "(note \"id\" \"text\" [(ref …)])",
        .summary = "Attach a design-time note to the surrounding scope.",
    } };
    t[@intFromEnum(ScopeForm.section)] = .{ .scope = all, .doc = .{
        .syntax = "(section \"name\" [\"subtitle\"] form…)",
        .summary = "Functional subsystem card. Inside `(section …)` nests one level into a sub-section.",
    } };
    t[@intFromEnum(ScopeForm.decouple)] = .{ .scope = all, .doc = .{
        .syntax = "(decouple \"NET\" [(comp \"val\")] COUNT per-pin [REF|auto] PIN…)",
        .summary = "Emit COUNT decoupling caps per listed host pin. Component and REF may come from " ++
            "(decouple-defaults …); a trailing `auto` expands to the pins already declared on the net.",
    } };
    t[@intFromEnum(ScopeForm.series)] = .{ .scope = all, .doc = .{
        .syntax = "(series …)",
        .summary = "Insert a series element (resistor / ferrite / etc.) between two nets.",
    } };
    t[@intFromEnum(ScopeForm.fanout)] = .{ .scope = all, .doc = .{
        .syntax = "(fanout \"COMMON\" (comp) \"NET1\" \"NET2\" … [(id …)])",
        .summary = "Place one component from a shared COMMON net to each listed net (star of series elements).",
    } };
    t[@intFromEnum(ScopeForm.net)] = .{ .scope = all, .doc = .{
        .syntax = "(net \"A\" \"B\" …)",
        .summary = "Tie one or more nets to a canonical name (net-merge).",
    } };
    t[@intFromEnum(ScopeForm.bus_net)] = .{ .scope = all, .doc = .{
        .syntax = "(bus-net \"PREFIX\" lo hi \"SUB\") | (bus-net \"PREFIX\" lo hi (suffixes …) (over …) (ports …))",
        .summary = "Tie a lane range to a sub-block bus (1:1), or strided-fan-out the range across several sub-blocks' ports.",
    } };

    t[@intFromEnum(ScopeForm.pins)] = .{ .scope = dsec, .doc = .{
        .syntax = "(pins \"REF\" (group \"label\") pin-form…)",
        .summary = "Group a main-IC's pin assignments under a sub-section.",
    } };
    t[@intFromEnum(ScopeForm.protocol)] = .{ .scope = dsec, .doc = .{
        .syntax = "(protocol atom)",
        .summary = "Tag a section with a protocol keyword (e.g. `usb`, `i2c`).",
    } };
    t[@intFromEnum(ScopeForm.calc)] = .{ .scope = dsec, .doc = .{
        .syntax = "(calc …)",
        .summary = "Inline design math block, surfaced in the review report.",
    } };
    t[@intFromEnum(ScopeForm.description)] = .{ .scope = dsec, .doc = .{
        .syntax = "(description \"text\")",
        .summary = "One-line section description used in the review report and overview SVG.",
    } };

    t[@intFromEnum(ScopeForm.role)] = .{ .scope = sec, .doc = .{
        .syntax = "(role input|output)",
        .summary = "Tag a section as a block input or output for the overview diagram.",
    } };
    t[@intFromEnum(ScopeForm.diagram)] = .{ .scope = sec, .doc = .{
        .syntax = "(diagram hidden)",
        .summary = "Opt this section out of the block-diagram view (schematic card still renders).",
    } };
    t[@intFromEnum(ScopeForm.hosts)] = .{ .scope = sec, .doc = .{
        .syntax = "(hosts \"sub1\" \"sub2\" …)",
        .summary = "Fold the named sub-blocks into this section's block-diagram node (explicit attachment).",
    } };
    t[@intFromEnum(ScopeForm.category)] = .{ .scope = sec, .doc = .{
        .syntax = "(category <key>)",
        .summary = "Set this section's diagram category (e.g. mcu, power, rf), overriding the name heuristic.",
    } };

    t[@intFromEnum(ScopeForm.group)] = .{ .scope = tl, .doc = .{
        .syntax = "(group …)",
        .summary = "Visual group annotation rendered in the schematic.",
    } };
    t[@intFromEnum(ScopeForm.function)] = .{ .scope = tl, .doc = .{
        .syntax = "(function \"name\" [\"caption\"] [(stack N)] (hosts \"Section A\" \"Section B\" …))",
        .summary = "Hand-authored functional super-block for the top-level system view: groups the " ++
            "named sections/sheets into one what-it-does block (caption = verb/spec line, " ++
            "stack N = ×N identical channels). The editor map draws these as the outermost zoom level.",
    } };
    t[@intFromEnum(ScopeForm.sub_block)] = .{ .scope = tl, .doc = .{
        .syntax = "(sub-block \"name\" (module-call args…))",
        .summary = "Instantiate a parameterised module inside the design. Its parts flatten into " ++
            "the netlist under the sub-block path prefix and the PCB solver places them with the " ++
            "rest of the board.",
    } };
    t[@intFromEnum(ScopeForm.verifies)] = .{ .scope = tl, .doc = .{
        .syntax = "(verifies (req \"REF\" REQID) [rationale])",
        .summary = "Mark a requirement as satisfied by a specific instance.",
    } };
    t[@intFromEnum(ScopeForm.test_point)] = .{ .scope = tl, .doc = .{
        .syntax = "(test-point …)",
        .summary = "Declare a measurement / bring-up access point.",
    } };
    t[@intFromEnum(ScopeForm.decouple_defaults)] = .{ .scope = tl, .doc = .{
        .syntax = "(decouple-defaults (ic \"REF\") (bypass (comp)))",
        .summary = "Set per-design decouple defaults: a fallback IC ref and bypass cap so (decouple …) can omit both.",
    } };
    t[@intFromEnum(ScopeForm.kicad_pcb)] = .{ .scope = tl, .doc = .{
        .syntax = "(kicad-pcb \"absolute/path/to/board.kicad_pcb\")",
        .summary = "Declare the PCB file the file-based KiCad sync writes board updates to.",
    } };
    t[@intFromEnum(ScopeForm.stub)] = .{ .scope = tl, .doc = .{
        .syntax = "(stub \"name\" [(role …)] [(mpn …)] [(category key)] [(size W H)] [(channels N)] [(ref \"REF\")] (signal \"name\" class \"net\")…)",
        .summary = "Declare a placeholder part — auto-placed, sized bounding box, signal-wired, optionally " ++
            "N stacked channels — for design-phase diagrams before a real component exists.",
    } };
    t[@intFromEnum(ScopeForm.layout)] = .{ .scope = tl, .doc = .{
        .syntax = "(diagram-layout (anchor \"name\") (place \"name\" (right-of|left-of|above|below \"ref\"))…)",
        .summary = "Position blocks relative to one another on the SCHEMATIC block diagram " ++
            "(Mermaid-style, free-floating) — nothing to do with PCB placement, which is " ++
            "the force / rough solver on /pcb-layout.",
    } };
    t[@intFromEnum(ScopeForm.board)] = .{ .scope = tl, .doc = .{
        .syntax = "(board (size W H) " ++
            "(left|right|top|bottom \"REF\"… | (rot N \"REF\")…)… [(corners \"REF\"…)])",
        .summary = "Physical board outline + edge hardware: (size W H) is the outline in mm " ++
            "(required — without it the form is inert). Each (left|right|top|bottom …) list " ++
            "docks those parts flush INSIDE that board edge (the words name physical edges, " ++
            "not sides of an anchor), slid along the edge toward the pads they connect to; " ++
            "(rot N \"REF\") overrides the default pads-inward rotation. (corners …) pins " ++
            "mounting hardware at the four corners (TL, TR, BR, BL in authored order). " ++
            "The force-solved interior placement is centered in the outline; the rendered " ++
            "views draw the outline rectangle.",
    } };
    t[@intFromEnum(ScopeForm.rough)] = .{ .scope = tl, .doc = .{
        .syntax = "(rough [(anchor \"REF\")] (group \"name\" \"REF\"…)…)",
        .summary = "Author the rough-placement seed (the `?rough=1` / \"Rough\" button on /pcb-layout): " ++
            "(anchor …) names the IC everything centres on (default: the most-connected hub), and each " ++
            "(group …) is a priority TIER in descending order — the first group is placed first and " ++
            "packs tightest to the anchor, later groups fan outward. A group sets priority, not " ++
            "position: every member still lands on the IC side its pad connects to (GND ignored), so " ++
            "a bypass cap sits by its VDD pad and a pull resistor by its signal pad. Parts in no " ++
            "group are placed last. Refs match by ref-des or module-local origin name (exact or leaf).",
    } };
    t[@intFromEnum(ScopeForm.stackup)] = .{ .scope = tl, .doc = .{
        .syntax = "(stackup N [(plane IDX \"NET\")…] [(pour top|bottom \"NET\")…])",
        .summary = "Declare the board's copper stack: N total copper layers (1-based, 1 = top/F.Cu, " ++
            "N = bottom/B.Cu); each (plane IDX \"NET\") makes layer IDX a solid plane carrying NET, " ++
            "all other layers are routed signal layers. `(pour top|bottom \"NET\")` is sugar for a " ++
            "plane on the matching OUTER layer (top = 1, bottom = N): the face is emitted as a solid " ++
            "copper pour (Gerber + /pcb-layout + PNG), NET pads already on that face connect through " ++
            "the pour with no stitching via, and signal routing prefers the un-poured face. " ++
            "`(stackup 2)` is a plain 2-layer board with no planes — ground/power are routed as " ++
            "copper like any other net; `(stackup 2 (pour bottom \"GND\"))` is the classic 2-layer " ++
            "board with a bottom ground pour. Without the form the router keeps its legacy implicit " ++
            "model (4 layers with assumed GND+PWR inner planes).",
    } };
    t[@intFromEnum(ScopeForm.net_class)] = .{ .scope = tl, .doc = .{
        .syntax = "(net-class \"name\" [(width MM)] [(clearance MM)] [(via DIA DRILL)] [(priority 0-7)] (nets \"A\" \"B\"…))",
        .summary = "Routing geometry + routing order for the named nets: trace width, copper clearance, " ++
            "and via size (diameter + drill) in mm, plus a routing-priority tier — the autorouter " ++
            "routes higher tiers first, so a critical net (crystal, flash bus, a switcher's hot loop) " ++
            "claims its short path before a bulk rail can wall it off (the maze router has no rip-up; " ++
            "first-routed wins). Omitted numbers keep the router defaults (priority 0 = baseline); net " ++
            "names match the flattened netlist case-insensitively. The first class naming a net wins. " ++
            "Repeat the form for more classes (e.g. a wide \"power\" class and a tight \"rf\" class).",
    } };
    t[@intFromEnum(ScopeForm.design_rules)] = .{ .scope = tl, .doc = .{
        .syntax = "(design-rules [(clearance MM)] [(min-drill MM)] [(mask-margin MM)] [(copper-edge MM)] [(hole-to-hole MM)] [(min-annular MM)])",
        .summary = "Board-level DEFAULT design rules (all sub-forms optional; mm): (clearance) copper-to-copper " ++
            "spacing for the router + DRC; (min-drill) smallest legal drilled hole; (mask-margin) solder-mask " ++
            "opening expansion per pad side; (copper-edge) copper-to-board-outline clearance; (hole-to-hole) " ++
            "wall-to-wall spacing between two drilled holes; (min-annular) minimum via annular ring " ++
            "(copper radius − drill radius). These are global defaults — a per-net (net-class …) still " ++
            "overrides width/clearance/via for its own nets. An omitted rule keeps the toolchain's built-in " ++
            "default (clearance 0.127, min-drill 0.2, mask-margin 0.05, copper-edge = clearance, " ++
            "hole-to-hole 0.25, min-annular 0.1), so a design with no form is unchanged.",
    } };
    t[@intFromEnum(ScopeForm.revision)] = .{ .scope = tl, .doc = .{
        .syntax = "(revision \"ID\" [(date \"YYYY-MM-DD\")] [(change \"ID\" \"summary\")…])",
        .summary = "Declare the design's canonical board revision: a human-meaningful spin id " ++
            "(\"A\", \"F4\", \"1.2\"), an optional date, and an optional newest-first in-file " ++
            "changelog. Shown on the schematic header and review doc so a recipient of the .sexp " ++
            "can tell which revision they hold; bump it by hand when cutting a new spin. Distinct " ++
            "from the per-edit snapshot history — tag the git commit to anchor the bump.",
    } };
    break :blk requireAllDocumented(ScopeForm, ScopedFormDoc, t);
};

// ── Tests ──────────────────────────────────────────────────────────────

// spec: eval/forms - SpecialForm.fromAtom resolves every head atom the evaluator dispatches on
test "SpecialForm registry covers every variant" {
    // Every enum variant must have a matching atom in the lookup table.
    // Build a set of seen variants by iterating the table, then check
    // its size equals the variant count.
    var seen = std.bit_set.IntegerBitSet(@typeInfo(SpecialForm).@"enum".fields.len).initEmpty();
    for (atom_to_form.values()) |v| seen.set(@intFromEnum(v));
    try std.testing.expectEqual(@typeInfo(SpecialForm).@"enum".fields.len, seen.count());
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
    var seen = std.bit_set.IntegerBitSet(@typeInfo(Builtin).@"enum".fields.len).initEmpty();
    for (atom_to_builtin.values()) |v| seen.set(@intFromEnum(v));
    try std.testing.expectEqual(@typeInfo(Builtin).@"enum".fields.len, seen.count());
    try std.testing.expectEqual(Builtin.add, Builtin.fromAtom("+").?);
    try std.testing.expectEqual(Builtin.gte, Builtin.fromAtom(">=").?);
    try std.testing.expect(Builtin.fromAtom("foo") == null);
}

// spec: eval/forms - ScopeForm.fromAtom resolves every form name that can appear in a design-block / section / subsection
test "ScopeForm registry covers every variant" {
    var seen = std.bit_set.IntegerBitSet(@typeInfo(ScopeForm).@"enum".fields.len).initEmpty();
    for (atom_to_scope_form.values()) |v| seen.set(@intFromEnum(v));
    try std.testing.expectEqual(@typeInfo(ScopeForm).@"enum".fields.len, seen.count());
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
    inline for (@typeInfo(SpecialForm).@"enum".fields) |f| {
        const variant: SpecialForm = @enumFromInt(f.value);
        if (variant == .id_) {
            try std.testing.expect(schemaFor(variant) == null);
        } else {
            try std.testing.expect(schemaFor(variant) != null);
        }
    }
}
