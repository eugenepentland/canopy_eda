const std = @import("std");

/// Top-level special form recognised by `evalForm`. Each variant
/// corresponds to a head atom in the S-expression source. Keeping the
/// mapping in one table makes typo-style bugs ("difmodule" silently
/// becoming an unbound-variable lookup) impossible and turns every
/// dispatch site into a `switch` Zig can check for exhaustiveness.
pub const SpecialForm = enum {
    let,
    if_,
    cond,
    import,
    defmodule,
    design_block,
    assert_,
    assert_range,
    fmt_,
    id_,

    pub fn fromAtom(name: []const u8) ?SpecialForm {
        return atom_to_form.get(name);
    }
};

const atom_to_form = std.StaticStringMap(SpecialForm).initComptime(.{
    .{ "let", .let },
    .{ "if", .if_ },
    .{ "cond", .cond },
    .{ "import", .import },
    .{ "defmodule", .defmodule },
    .{ "design-block", .design_block },
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
    status,
    role,
    diagram,
    hosts,
    category,
    // Top-level only (design-block scope)
    group,
    sub_block,
    verifies,
    design_doc,
    test_point,
    power_config,
    decouple_defaults,
    kicad_pcb,
    function,
    stub,
    layout,
    placement_order,
    constraints,
    placement,

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
    .{ "status", .status },
    .{ "role", .role },
    .{ "diagram", .diagram },
    .{ "hosts", .hosts },
    .{ "category", .category },
    .{ "group", .group },
    .{ "sub-block", .sub_block },
    .{ "verifies", .verifies },
    .{ "design-doc", .design_doc },
    .{ "test-point", .test_point },
    .{ "power-config", .power_config },
    .{ "decouple-defaults", .decouple_defaults },
    .{ "kicad-pcb", .kicad_pcb },
    .{ "function", .function },
    .{ "stub", .stub },
    .{ "layout", .layout },
    .{ "placement-order", .placement_order },
    .{ "constraints", .constraints },
    .{ "module", .constraints },
    .{ "placement", .placement },
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
        .{ .cond, .{ .min_args = 1, .max_args = null } },
        .{ .import, .{ .min_args = 1, .max_args = 1 } },
        .{ .defmodule, .{ .min_args = 3, .max_args = null } },
        .{ .design_block, .{ .min_args = 1, .max_args = null } },
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
// The renderer below walks these tables to emit `docs/language-forms.md`.
// Keeping the syntax + one-line description next to the enum variants
// (rather than in a separate markdown file) means a new form can't be
// added without also documenting it — the comptime indexed arrays force
// exhaustive coverage.

/// One row of the generated reference. `syntax` is the source-form
/// template a human would write; `summary` is a one-line description.
pub const FormDoc = struct {
    syntax: []const u8,
    summary: []const u8,
};

pub const special_form_docs = blk: {
    const N = @typeInfo(SpecialForm).@"enum".fields.len;
    var t: [N]FormDoc = undefined;
    t[@intFromEnum(SpecialForm.let)] = .{
        .syntax = "(let name expr)",
        .summary = "Bind `name` to the evaluated value of `expr` in the current scope.",
    };
    t[@intFromEnum(SpecialForm.if_)] = .{
        .syntax = "(if cond then else)",
        .summary = "Short-circuit conditional. Only the matching branch is evaluated.",
    };
    t[@intFromEnum(SpecialForm.cond)] = .{
        .syntax = "(cond (test1 expr1) … (else exprN))",
        .summary = "Walk clauses in order, returning the first matching expression's value.",
    };
    t[@intFromEnum(SpecialForm.import)] = .{
        .syntax = "(import name)",
        .summary = "Load a library component or module by name. Searches `lib/components/` then `lib/modules/`.",
    };
    t[@intFromEnum(SpecialForm.defmodule)] = .{
        .syntax = "(defmodule name (params…) body…)",
        .summary = "Define a parameterised module that closes over the surrounding env.",
    };
    t[@intFromEnum(SpecialForm.design_block)] = .{
        .syntax = "(design-block \"name\" form…)",
        .summary = "The root container — every `.sexp` design file evaluates to one.",
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
        .summary = "Format a string using `~V`/`~R`/`~C`/`~A`/`~S` directives.",
    };
    t[@intFromEnum(SpecialForm.id_)] = .{
        .syntax = "(id <hex8>)",
        .summary = "Stable 8-char identifier auto-inserted by the build. Evaluator short-circuits to `.nil`.",
    };
    break :blk t;
};

pub const builtin_docs = blk: {
    const N = @typeInfo(Builtin).@"enum".fields.len;
    var t: [N]FormDoc = undefined;
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
    break :blk t;
};

/// Which scopes accept each `ScopeForm` variant. The set drives the
/// scope-availability column in the generated reference.
pub const ScopeAvailability = packed struct {
    design_block: bool,
    section: bool,
    sub_section: bool,
};

pub const scope_form_docs = blk: {
    const N = @typeInfo(ScopeForm).@"enum".fields.len;
    var t: [N]struct { doc: FormDoc, scope: ScopeAvailability } = undefined;

    const all = ScopeAvailability{ .design_block = true, .section = true, .sub_section = true };
    const dsec = ScopeAvailability{ .design_block = false, .section = true, .sub_section = true };
    const tl = ScopeAvailability{ .design_block = true, .section = false, .sub_section = false };
    const sec = ScopeAvailability{ .design_block = false, .section = true, .sub_section = false };

    t[@intFromEnum(ScopeForm.instance)] = .{ .scope = all, .doc = .{
        .syntax = "(instance \"REF\" component pin…)",
        .summary = "Place a component with inline pin-to-net bindings.",
    } };
    t[@intFromEnum(ScopeForm.port)] = .{ .scope = all, .doc = .{
        .syntax = "(port \"name\" [net] dir [(rated lo hi)])",
        .summary = "Declare a block boundary signal.",
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
        .syntax = "(decouple \"NET\" item…) | (decouple (cap-0402 \"100nF\") N per-pin \"REF\" \"NET1\" …)",
        .summary = "Emit decoupling capacitors against a net, in single- or multi-net form.",
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
    t[@intFromEnum(ScopeForm.status)] = .{ .scope = dsec, .doc = .{
        .syntax = "(status concept|implemented|review)",
        .summary = "Section completion status. Inferred when omitted.",
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
    t[@intFromEnum(ScopeForm.sub_block)] = .{ .scope = tl, .doc = .{
        .syntax = "(sub-block \"name\" (module-call args…))",
        .summary = "Instantiate a parameterised module inside the design.",
    } };
    t[@intFromEnum(ScopeForm.verifies)] = .{ .scope = tl, .doc = .{
        .syntax = "(verifies (req \"REF\" REQID) [rationale])",
        .summary = "Mark a requirement as satisfied by a specific instance.",
    } };
    t[@intFromEnum(ScopeForm.design_doc)] = .{ .scope = tl, .doc = .{
        .syntax = "(design-doc (critical-ic comp (role \"…\") (rationale \"…\") (mpn \"…\")) …)",
        .summary = "Up-front critical-IC lifecycle / traceability declaration for the design.",
    } };
    t[@intFromEnum(ScopeForm.test_point)] = .{ .scope = tl, .doc = .{
        .syntax = "(test-point …)",
        .summary = "Declare a measurement / bring-up access point.",
    } };
    t[@intFromEnum(ScopeForm.power_config)] = .{ .scope = tl, .doc = .{
        .syntax = "(power-config (derating N))",
        .summary = "Per-design power-budget configuration knobs.",
    } };
    t[@intFromEnum(ScopeForm.decouple_defaults)] = .{ .scope = tl, .doc = .{
        .syntax = "(decouple-defaults (ic \"REF\") (bypass (comp)))",
        .summary = "Set per-design decouple defaults: a fallback IC ref and bypass cap so (decouple …) can omit both.",
    } };
    t[@intFromEnum(ScopeForm.kicad_pcb)] = .{ .scope = tl, .doc = .{
        .syntax = "(kicad-pcb \"absolute/path/to/board.kicad_pcb\")",
        .summary = "Declare the PCB file the file-based KiCad sync writes board updates to.",
    } };
    t[@intFromEnum(ScopeForm.function)] = .{ .scope = tl, .doc = .{
        .syntax = "(function \"Name\" [\"subtitle\"] [(verb \"…\")] [(stack N)] [(chain pos \"stage\")] (includes \"section\"…))",
        .summary = "Declare a high-level functional subsystem for the Function view; (chain …) also places it on the Signal Chain view's narrative spine.",
    } };
    t[@intFromEnum(ScopeForm.stub)] = .{ .scope = tl, .doc = .{
        .syntax = "(stub \"name\" [(role …)] [(mpn …)] [(category key)] [(size W H)] [(channels N)] [(ref \"REF\")] (signal \"name\" class \"net\")…)",
        .summary = "Declare a placeholder part — auto-placed, sized bounding box, signal-wired, optionally N stacked channels — for design-phase diagrams before a real component exists.",
    } };
    t[@intFromEnum(ScopeForm.layout)] = .{ .scope = tl, .doc = .{
        .syntax = "(layout (anchor \"name\") (place \"name\" (right-of|left-of|above|below \"ref\"))…)",
        .summary = "Declare a Mermaid-style free-floating block-diagram layout by positioning blocks relative to one another.",
    } };
    t[@intFromEnum(ScopeForm.placement_order)] = .{ .scope = tl, .doc = .{
        .syntax = "(placement-order \"HUB\" \"REF\"… | (near <pin> \"REF\")…)",
        .summary = "Order the passives around a hub for PCB auto-placement (first = highest priority); (near …) also pins which hub pad a cap's loop targets.",
    } };
    t[@intFromEnum(ScopeForm.constraints)] = .{ .scope = tl, .doc = .{
        .syntax = "(constraints | module \"name\" " ++
            "(power-rail L (role input) (net N)) (proximity REF (to-pin HUB PIN) (max n mm) (priority …)) " ++
            "(net-length (net N) (minimize) (priority …)) (deprioritize (REF…)) " ++
            "(keep-out (net N)|(part REF) (from REF) (min n mm)) (group (REF…) (style …)) …)",
        .summary = "Phase-A PCB placement constraints (circuit intent the auto-placer can't infer): " ++
            "rail roles, proximity pulls, weighted nets, deprioritized straps, keep-outs, groups. " ++
            "Refs/nets/pins validated against the netlist. See docs/constraints_dsl.md.",
    } };
    t[@intFromEnum(ScopeForm.placement)] = .{ .scope = tl, .doc = .{
        .syntax = "(placement (anchor \"REF\") " ++
            "(left|right|top|bottom \"REF\"… | (rot N \"REF\")…)… [(switch \"REF\" side)])",
        .summary = "Agent-authored PCB floorplan: declare each part's side of the main IC, " ++
            "the order along that edge, and an optional rotation; the solver legalizes it to " ++
            "exact coordinates (the manual twin of the automatic switcher floorplan).",
    } };
    break :blk t;
};

/// Render a Markdown reference for every form recognised by the
/// evaluator, drawn from the registries + schema + doc tables above.
/// The output is deterministic — call it from a build step or test and
/// compare to a checked-in file to enforce that the docs never lag the
/// implementation. Caller owns the returned slice.
pub fn renderLanguageReference(allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try renderTo(buf.writer(allocator));
    return buf.toOwnedSlice(allocator);
}

fn renderTo(writer: anytype) !void {
    try writer.writeAll(
        \\# S-Expression Language: Form Reference
        \\
        \\<!-- Auto-generated from src/eval/forms.zig. Do not edit by hand —
        \\     run `zig build run -- gen-language-docs` to regenerate. -->
        \\
        \\Every special form, builtin operator, and design-scope form the
        \\evaluator recognises, with its arity contract and a one-line
        \\summary. The hand-written prose lives in
        \\[`sexp-language.md`](sexp-language.md); this file is the
        \\machine-checked grammar surface.
        \\
        \\## Special forms
        \\
        \\Arguments are passed un-evaluated; each form decides what to evaluate.
        \\
        \\| Form | Arity | Summary |
        \\| --- | --- | --- |
        \\
    );
    inline for (@typeInfo(SpecialForm).@"enum".fields) |f| {
        const variant: SpecialForm = @enumFromInt(f.value);
        const doc = special_form_docs[@intFromEnum(variant)];
        try writer.writeAll("| `");
        try writer.writeAll(doc.syntax);
        try writer.writeAll("` | ");
        try writeArity(writer, schemaFor(variant));
        try writer.writeAll(" | ");
        try writer.writeAll(doc.summary);
        try writer.writeAll(" |\n");
    }

    try writer.writeAll(
        \\
        \\## Builtin operators
        \\
        \\Arithmetic, comparison, and logic operators. Arguments are evaluated left-to-right before the operator runs.
        \\
        \\| Form | Summary |
        \\| --- | --- |
        \\
    );
    inline for (@typeInfo(Builtin).@"enum".fields) |f| {
        const variant: Builtin = @enumFromInt(f.value);
        const doc = builtin_docs[@intFromEnum(variant)];
        try writer.writeAll("| `");
        try writer.writeAll(doc.syntax);
        try writer.writeAll("` | ");
        try writer.writeAll(doc.summary);
        try writer.writeAll(" |\n");
    }

    try writer.writeAll(
        \\
        \\## Design-scope forms
        \\
        \\Forms that may appear directly inside a `(design-block …)`, a
        \\`(section …)`, or a nested sub-section. The scope column lists
        \\where each is accepted: **D** = design-block top level,
        \\**S** = section, **s** = sub-section.
        \\
        \\| Form | Scope | Summary |
        \\| --- | --- | --- |
        \\
    );
    inline for (@typeInfo(ScopeForm).@"enum".fields) |f| {
        const variant: ScopeForm = @enumFromInt(f.value);
        const row = scope_form_docs[@intFromEnum(variant)];
        try writer.writeAll("| `");
        try writer.writeAll(row.doc.syntax);
        try writer.writeAll("` | ");
        if (row.scope.design_block) try writer.writeAll("D") else try writer.writeAll("·");
        if (row.scope.section) try writer.writeAll("S") else try writer.writeAll("·");
        if (row.scope.sub_section) try writer.writeAll("s") else try writer.writeAll("·");
        try writer.writeAll(" | ");
        try writer.writeAll(row.doc.summary);
        try writer.writeAll(" |\n");
    }
}

fn writeArity(writer: anytype, schema: ?FormSchema) !void {
    const s = schema orelse {
        try writer.writeAll("—");
        return;
    };
    if (s.max_args) |max| {
        if (max == s.min_args) {
            try writer.print("{d}", .{s.min_args});
        } else {
            try writer.print("{d}–{d}", .{ s.min_args, max });
        }
    } else {
        try writer.print("{d}+", .{s.min_args});
    }
}

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

// spec: eval/forms - renderLanguageReference output matches the committed docs/language-forms.md so docs can never lag the registry
test "language-forms.md is in sync with the registry" {
    const alloc = std.testing.allocator;

    // Skip when the test is invoked outside a project tree (the file
    // simply isn't there to compare against). The round-trip test in
    // sexpr/printer.zig uses the same pattern.
    var file = std.fs.cwd().openFile("docs/language-forms.md", .{}) catch return;
    defer file.close();
    const committed = try file.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(committed);

    const generated = try renderLanguageReference(alloc);
    defer alloc.free(generated);

    // expectEqualStrings produces a usable diff on failure. To
    // regenerate the file, run `zig build run -- gen-language-docs`.
    try std.testing.expectEqualStrings(committed, generated);
}
