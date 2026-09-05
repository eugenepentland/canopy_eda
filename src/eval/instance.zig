//! Evaluates `(instance …)`: resolves the component/family reference, builds the
//! `Instance` (ref-des, pins, parts, DNP, and the decouple/strap/nc sign-offs),
//! and parses each `(pin …)` including its rating tail (typ/max current, load
//! label). The per-part heart of design-block evaluation.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const env_mod = @import("env.zig");
const attrs_mod = @import("attrs.zig");
const evaluator_mod = @import("evaluator.zig");
const Evaluator = evaluator_mod.Evaluator;
const EvalError = evaluator_mod.EvalError;
const ids = @import("ids.zig");
const pin_roles = @import("../placement/pin_roles.zig");
const footprint_pads = @import("footprint_pads.zig");
const suggest = @import("suggest.zig");
const thermal = @import("thermal.zig");
const forms_mod = @import("forms.zig");
const variants = @import("variants.zig");
const PinNetDecl = evaluator_mod.PinNetDecl;

// ── Constants ─────────────────────────────────────────────────────
const series_named_ref_min_arity: usize = 5;

/// The `(instance …)` body sub-forms this parser dispatches on, derived from
/// the documented registry so the reference and the parser cannot disagree.
/// Any other head falls through to the inline-property branch, so this list is
/// also half of the vocabulary a typo is measured against.
const known_forms = forms_mod.instance_reserved_forms;

/// `(row N)` / `(col N)` are legal in an instance body but consumed by the
/// layout rather than by this parser — they reach the property branch and are
/// dropped there without a warning. They are still spellings an author can
/// mistype, so they join the typo vocabulary.
const grid_hint_forms = [_][]const u8{ "row", "col" };

/// Every legal `(instance …)` sub-form head. A body head close enough to one
/// of these (see `suggest.Budget.strict`) is a typo, not a property.
const instance_sub_forms = known_forms ++ grid_hint_forms;

/// What the library knows about one part's pads, as the two independent
/// records that can carry it: the `lib/pinouts` map (pad id → function name)
/// when the part has a pinout file, and the name of its footprint, whose
/// `(pad …)` ids answer for everything else (passives, connectors, mechanical
/// parts). A part with neither has an unknown pad set and every pad token on
/// it passes unchecked.
///
/// The footprint is named rather than loaded so `requirePad` can read it
/// LAZILY — a pad that the pinout already accounts for never costs a file
/// read, and a footprint is read at most once per build (cached on the
/// evaluator) however many instances place it.
pub const PartPads = struct {
    pinout: ?*const std.StringHashMapUnmanaged([]const u8) = null,
    footprint: []const u8 = "",
};

/// One pad token under check: the sub-form that named it, the token as
/// written, and the pad id it resolved to. `raw` and `pad` differ exactly
/// when the author wrote a pinout function name instead of a pad id, and the
/// diagnostic quotes the spelling the author used.
const PadRef = struct { form: []const u8, raw: []const u8, pad: []const u8 };

const Node = ast.Node;
const Value = env_mod.Value;
const Env = env_mod.Env;
const Instance = env_mod.Instance;
const Note = env_mod.Note;

/// Result of building an instance: the instance + any inline pin-net declarations + notes
pub const InstanceResult = struct {
    instance: Instance,
    pin_nets: []const PinNetDecl,
    inline_notes: []const Note,
};

/// Component metadata extracted from a Value. Before this helper, buildInstance,
/// instanceFromValue, and emitDecoupleItems each rebuilt the same (family,
/// value, attrs) → library-lookup sequence, so adding a new field meant editing
/// three parallel sites.
pub const ResolvedComponent = struct {
    family: []const u8,
    value: []const u8,
    footprint: []const u8,
    symbol: []const u8,
    pinout: []const u8,
    properties: []const env_mod.Property,
    attrs: []const []const u8,
    /// The authored typed attributes, kept alongside `properties` (which
    /// already contains them) so a later parts-table selection that overwrites
    /// a rating can still be compared against what the design asked for.
    typed_attrs: []const env_mod.Property = &.{},
    docs: env_mod.ComponentDocs = .{},
    /// The library part's `(thermal …)` envelope, carried through so every
    /// instance built from this component reaches the thermal analyzer with
    /// its θJA / Tj(max) / rated ambient range already attached.
    thermal: ?env_mod.ThermalDecl = null,
    requirements: []const env_mod.Requirement = &.{},
    requirements_ignored: bool = false,
    electrical: []const env_mod.ElectricalDecl = &.{},
};

/// Extract component metadata from a Value. Returns null when the Value isn't a
/// component form. When `family` isn't in the component cache the library
/// fields come back empty — callers decide whether that should surface as an
/// error (buildInstance does; instanceFromValue does not).
pub fn resolveComponent(self: *Evaluator, val: Value) ?ResolvedComponent {
    const family: []const u8 = switch (val) {
        .component => |c| c,
        .component_instance => |ci| ci.family,
        else => return null,
    };
    const value: []const u8 = switch (val) {
        .component_instance => |ci| ci.value,
        else => "",
    };
    const attrs: []const []const u8 = switch (val) {
        .component_instance => |ci| ci.attrs,
        else => &.{},
    };
    const typed: []const env_mod.Property = switch (val) {
        .component_instance => |ci| ci.typed_attrs,
        else => &.{},
    };
    if (self.component_cache.get(family)) |cd| {
        return .{
            .family = family,
            .value = value,
            .footprint = cd.footprint_name,
            .symbol = cd.symbol_name,
            .pinout = cd.pinout_name,
            .properties = withTypedAttributes(self, cd.properties, typed),
            .attrs = attrs,
            .typed_attrs = typed,
            .docs = cd.docs,
            .thermal = cd.thermal,
            .requirements = cd.requirements,
            .requirements_ignored = cd.requirements_ignored,
            .electrical = cd.electrical,
        };
    }
    return .{
        .family = family,
        .value = value,
        .footprint = "",
        .symbol = "",
        .pinout = "",
        .properties = withTypedAttributes(self, &.{}, typed),
        .attrs = attrs,
        .typed_attrs = typed,
    };
}

/// The library component's properties with the instantiation's typed
/// attributes layered on top.
///
/// The authored rating wins over a library default under the same key: the
/// design just said `(cap-0402 "1uF" (rating 25V))` about THIS placement,
/// which is strictly more specific than whatever the family declares for all
/// of them. A parts-table selection later overrides both — the selected row is
/// the physical part, and `erc.checkTypedAttributeMismatch` reports the case
/// where it disagrees with what was asked for instead of letting it pass in
/// silence.
///
/// `esr`/`esl` additionally land as the PDN model numbers
/// (`pdn-esr-ohm` / `pdn-esl-h`) `placement/pdn_impedance` already reads, so
/// an authored override reaches the impedance screen without teaching it a
/// second spelling.
fn withTypedAttributes(
    self: *Evaluator,
    base: []const env_mod.Property,
    typed: []const env_mod.Property,
) []const env_mod.Property {
    if (typed.len == 0) return base;
    var merged: std.ArrayList(env_mod.Property) = .empty;
    for (base) |property| {
        if (hasProperty(typed, property.key)) continue;
        merged.append(self.allocator, property) catch return base;
    }
    for (typed) |property| {
        merged.append(self.allocator, property) catch return base;
        const slot = attrs_mod.slotForKey(property.key) orelse continue;
        const model = attrs_mod.modelProperty(slot, property.value) orelse continue;
        if (hasProperty(base, model.key) or hasProperty(merged.items, model.key)) continue;
        const rendered = std.fmt.allocPrint(self.allocator, "{d}", .{model.value}) catch continue;
        merged.append(self.allocator, .{ .key = model.key, .value = rendered }) catch return base;
    }
    return merged.toOwnedSlice(self.allocator) catch base;
}

fn hasProperty(properties: []const env_mod.Property, key: []const u8) bool {
    for (properties) |property| {
        if (std.ascii.eqlIgnoreCase(property.key, key)) return true;
    }
    return false;
}

/// Evaluate an `(instance "REF" (component …) (pin …) …)` form into an
/// `InstanceResult`: the placed `Instance`, every inline pin-net declaration
/// it produced, and any `(note …)` annotations sitting inside the form. The
/// body may also contain bare net strings; they bind physical pads 1, 2, … in
/// string order, while every existing sub-form remains available alongside them.
/// component must resolve through the library cache or this errors —
/// missing footprints would silently break KiCad export downstream.
pub fn buildInstance(self: *Evaluator, form_children: []const Node, env: *Env) EvalError!InstanceResult {
    // form_children includes "instance" atom: (instance "R4" (res-0402 "220k") (pin 1 "NET_A") ...)
    const args = form_children[1..];
    if (args.len < 2) {
        self.setError(form_children[0].span, "(instance …) expects at least 2 arguments: (instance \"REF\" component …)");
        return EvalError.ArityError;
    }
    const ref_val = try self.evalNode(args[0], env);
    const ref_des = ref_val.asString() orelse {
        self.setError(args[0].span, "(instance …) ref-des must be a string, e.g. (instance \"U1\" …)");
        return EvalError.TypeError;
    };

    // Parse (id xxxxxxxx) from full form children
    const parsed_id = ids.parseId(form_children);
    const inst_id = parsed_id orelse try ids.generateId(self);

    // Track for auto-insertion if no (id ...) was in source
    if (parsed_id == null) {
        try self.pending_ids.append(self.allocator, .{
            .form_offset = form_children[0].span.offset -| 1,
            .id = inst_id,
        });
    }

    const comp_val = try self.evalNode(args[1], env);
    const comp_offset = ids.componentSourceOffset(args[1]);
    const resolved = resolveComponent(self, comp_val) orelse {
        self.setErrorFmt(args[1].span, "(instance \"{s}\" …) second argument must be a component, e.g. (cap-0402 \"100nF\")", .{ref_des});
        return EvalError.TypeError;
    };
    // (instance ...) requires the component to resolve through the library —
    // an empty footprint signals that the family wasn't in the cache.
    if (!self.component_cache.contains(resolved.family)) {
        self.setErrorFmt(args[1].span, "component '{s}' is not imported — add (import {s})", .{ resolved.family, resolved.family });
        return EvalError.UnboundVariable;
    }
    const inst = Instance{
        .ref_des = ref_des,
        .label = ref_des,
        // Stable module-local identity for hierarchical sub-block ids: the
        // source name, captured before any global ref-des renumber.
        .origin_key = ref_des,
        .component = resolved.family,
        .value = resolved.value,
        .footprint = resolved.footprint,
        .symbol = resolved.symbol,
        .pinout = resolved.pinout,
        .properties = resolved.properties,
        .attrs = resolved.attrs,
        .typed_attrs = resolved.typed_attrs,
        .docs = resolved.docs,
        .requirements = resolved.requirements,
        .requirements_ignored = resolved.requirements_ignored,
        .electrical = resolved.electrical,
        .source_offset = comp_offset,
        .id = inst_id,
        .thermal = .{ .decl = resolved.thermal },
    };

    // Resolve pinout for reverse lookup (function_name -> pin_id); null when the
    // component has no lib/pinouts file (the pinout-less-wiring guard keys on it).
    const reverse_pinout = resolveReversePinout(self, &inst);
    // Both pad records this part has, for the pad-existence check. The
    // footprint is only named here; `requirePad` loads it on demand.
    const part_pads = PartPads{ .pinout = reverse_pinout, .footprint = resolved.footprint };

    // Parse inline pin declarations:
    //   (pin 1 "NET")               -- single pin
    //   (pin 3 4 5 6 7 "NET")       -- multiple pins on same net
    //   (connect FUNC "NET" ...)     -- connect by function name from pinout
    var pin_nets: std.ArrayList(PinNetDecl) = .empty;
    var parts: std.ArrayList(env_mod.Part) = .empty;
    var inline_notes: std.ArrayList(Note) = .empty;
    var inline_props: std.ArrayList(env_mod.Property) = .empty;
    var dnp_flag = false;
    var variant_rules: std.ArrayList(env_mod.VariantRule) = .empty;
    var binds: env_mod.InstanceBinds = .{};
    var strap_oks: std.ArrayList(env_mod.StrapOk) = .empty;
    var nc_oks: std.ArrayList(env_mod.NcOk) = .empty;
    var power: ?env_mod.PowerDecl = null;

    var positional_pad: usize = 1;
    for (args[2..]) |form| {
        if (form.asString()) |net_name| {
            const pad = std.fmt.allocPrint(self.allocator, "{d}", .{positional_pad}) catch
                return EvalError.OutOfMemory;
            try pin_nets.append(self.allocator, .{ .ref_des = ref_des, .pin = pad, .net = net_name });
            positional_pad += 1;
        } else if (form.isForm("note")) {
            try parseInlineNote(self, form, ref_des, env, &inline_notes);
        } else if (form.isForm("pin")) {
            try parsePinForm(self, form, ref_des, env, &pin_nets, part_pads);
        } else if (form.isForm("part")) {
            // Multi-part symbol: (part "Name" (row N) (col N) (pin …) …). Each
            // inner (pin …) wires exactly like a top-level pin (so the IC is
            // electrically connected), and the part is recorded on the instance
            // so the schematic renders one labelled box per function group.
            try parsePartForm(self, form, ref_des, env, &pin_nets, &parts, part_pads);
        } else if (form.isForm("dnp")) {
            // (dnp) — mark Do Not Populate. Bare flag form (no value).
            dnp_flag = true;
        } else if (variants.isInstanceForm(form)) {
            // (only-in …) / (dnp-in …) / (value-in …) — assembly-variant
            // clauses. Names are checked against the ROOT design's `(variant …)`
            // declarations here, so a typo inside a module body reports the
            // module's own file and line.
            try variants.parseInstanceForm(self, form, ref_des, resolved.family, env, &variant_rules);
        } else if (form.isForm("decouples")) {
            try parseDecouples(self, form, ref_des, env, &binds.decouple);
        } else if (form.isForm("near")) {
            try parseNear(self, form, ref_des, env, part_pads, &binds.near);
        } else if (form.isForm("strap-ok")) {
            try parseStrapOk(self, form, ref_des, env, part_pads, &strap_oks);
        } else if (form.isForm("nc-ok")) {
            try parseNcOk(self, form, ref_des, env, part_pads, &nc_oks);
        } else if (form.isForm("power")) {
            power = thermal.parsePower(form.asList().?) orelse blk: {
                self.warnFmt(form.span, "(power …) on \"{s}\" — expected (power WATTS) or (power (typ W) (max W))", .{ref_des});
                break :blk power;
            };
        } else if (form.isForm("bus")) {
            // (bus "NET_PREFIX" "BUS_NAME") -- expand component bus definition
            const bc = form.asList().?;
            if (bc.len >= 3) {
                const prefix_val = try self.evalNode(bc[1], env);
                const prefix = prefix_val.asString() orelse continue;
                const bus_name_val = try self.evalNode(bc[2], env);
                const bus_name = bus_name_val.asString() orelse (bc[2].asAtom() orelse continue);
                // Look up bus definition from component
                const comp_data = self.component_cache.get(inst.component);
                if (comp_data) |cd| {
                    for (cd.buses) |bus_def| {
                        if (std.mem.eql(u8, bus_def.name, bus_name)) {
                            for (bus_def.pins, 0..) |bus_pin, idx| {
                                const net = std.fmt.allocPrint(self.allocator, "{s}{d}", .{ prefix, idx }) catch continue;
                                // Resolve pin through pinout
                                const resolved_pin = if (reverse_pinout) |rp| (resolvePinName(self, rp, bus_pin, form.span) orelse bus_pin) else bus_pin;
                                try pin_nets.append(self.allocator, .{ .ref_des = ref_des, .pin = resolved_pin, .net = net });
                            }
                            break;
                        }
                    }
                }
            }
        } else {
            try parseUnknownSubForm(self, form, ref_des, env, &inline_props);
        }
    }

    warnPinoutlessMultiPad(self, form_children[0].span, &inst, reverse_pinout, pin_nets.items);

    try variants.validateInstance(self, form_children[0].span, ref_des, dnp_flag, variant_rules.items);

    var final_inst = inst;
    final_inst.pinout_facts = summarisePinout(reverse_pinout);
    // The SELECTED assembly variant lands on the two fields the rest of the
    // toolchain already reads — `dnp` and `value` — so ERC exemptions, the BOM,
    // the KiCad attributes, the schematic and the layout need no variant
    // awareness. The clauses themselves ride along for the population matrix.
    const applied = variants.apply(self.variants.scope, variant_rules.items);
    final_inst.dnp = dnp_flag or applied.dnp;
    if (applied.value) |override| {
        final_inst.variants.base_value = inst.value;
        final_inst.value = override;
    }
    if (variant_rules.items.len > 0)
        final_inst.variants.rules = variant_rules.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
    final_inst.bind = binds;
    final_inst.thermal.power = power;
    if (strap_oks.items.len > 0) final_inst.strap_oks = strap_oks.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
    if (nc_oks.items.len > 0) final_inst.nc_oks = nc_oks.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
    if (parts.items.len > 0) final_inst.parts = parts.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;

    // Merge properties: start with component defaults, override with inline
    if (inline_props.items.len > 0) {
        try mergeInstanceProperties(self, &final_inst, inline_props.items);
    }

    return InstanceResult{
        .instance = final_inst,
        .pin_nets = pin_nets.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        .inline_notes = inline_notes.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
    };
}

/// Handle an `(instance …)` body form this parser does not dispatch on: it is
/// either a typo of a real sub-form (rejected) or an inline property
/// `(key "value")` (appended to `inline_props`).
///
/// Shapes that cannot become a property — a bare token, a 1-element list, a
/// non-string value — are silently dead, so each warns, except the
/// documented-but-inert `(row N)` / `(col N)` grid hints.
fn parseUnknownSubForm(
    self: *Evaluator,
    form: Node,
    ref_des: []const u8,
    env: *Env,
    inline_props: *std.ArrayList(env_mod.Property),
) EvalError!void {
    const fc = form.asList() orelse {
        self.warnFmt(form.span, "ignored bare token in (instance \"{s}\" …) body", .{ref_des});
        return;
    };
    if (fc.len > 0) try rejectNearMissSubForm(self, form.span, ref_des, fc[0].asAtom() orelse "");
    if (fc.len < 2) {
        self.warnFmt(form.span, "ignored sub-form in (instance \"{s}\" …) — properties need a value: (key \"value\")", .{ref_des});
        return;
    }
    const key = fc[0].asAtom() orelse return;
    if (env_mod.containsString(&known_forms, key)) return;
    const val = (try self.evalNode(fc[1], env)).asString() orelse {
        if (!env_mod.containsString(&grid_hint_forms, key)) {
            self.warnFmt(form.span, "ignored sub-form ({s} …) in (instance \"{s}\" …) — property values must be strings", .{ key, ref_des });
        }
        return;
    };
    try inline_props.append(self.allocator, .{ .key = key, .value = val });
}

/// Reject a body sub-form whose head is one or two edits away from a real
/// `(instance …)` sub-form.
///
/// Everything this parser does not dispatch on becomes an inline property
/// `(key "value")`, which is what makes `(decuples "U1" 1)` build clean: the
/// decoupling sign-off it promised was never declared, and a BOM property
/// named `decuples` took its place. Only a NEAR-MISS is rejected, so a
/// deliberate property key (`module-bypass`, `emi-couples`) keeps working
/// exactly as before.
fn rejectNearMissSubForm(self: *Evaluator, span: ast.Span, ref_des: []const u8, head: []const u8) EvalError!void {
    // A legal head reaches this branch too — `(id …)` and `(as …)` are
    // consumed elsewhere and fall through here — and a legal head is never a
    // typo, however close it sits to another one (`id` is two edits from
    // `pin`).
    if (env_mod.containsString(&instance_sub_forms, head)) return;
    // `.strict`: this verdict is itself the error, so a short head gets one
    // edit of slack rather than two — `(mpn 42)` is a property, not a `(pin
    // …)` typo, even though it sits two edits away.
    const suggestion = suggest.nearestOf(head, &instance_sub_forms, .strict) orelse return;
    self.setErrorFmt(span, "unknown sub-form ({s} …) in (instance \"{s}\" …) — did you mean ({s} …)?", .{ head, ref_des, suggestion });
    return EvalError.InvalidForm;
}

/// Append a well-formed `(note "text")` from an instance body. Keeping this
/// small parser out of `buildInstance` leaves room there for independent body
/// forms without raising its frozen complexity ceiling.
fn parseInlineNote(
    self: *Evaluator,
    form: Node,
    ref_des: []const u8,
    env: *Env,
    inline_notes: *std.ArrayList(Note),
) EvalError!void {
    const children = form.asList().?;
    if (children.len < 2) return;
    const value = try self.evalNode(children[1], env);
    const text = value.asString() orelse return;
    try inline_notes.append(self.allocator, .{ .ref_des = ref_des, .text = text });
}

/// The name `getSymbolPins` searches lib/pinouts/ for: a component's declared
/// pinout, else its symbol, else the instance's own symbol field.
fn pinoutLookupName(self: *Evaluator, inst: *const Instance) []const u8 {
    const cd = self.component_cache.get(inst.component) orelse return inst.symbol;
    return if (cd.pinout_name.len > 0) cd.pinout_name else cd.symbol_name;
}

/// Resolve the reverse pinout (function-name → pad id) for an instance's
/// component, or null when the part has no lib/pinouts file. Extracted so
/// `buildInstance` stays flat; the pinout-less-wiring guard shares the null.
fn resolveReversePinout(self: *Evaluator, inst: *const Instance) ?*const std.StringHashMapUnmanaged([]const u8) {
    const lookup = pinoutLookupName(self, inst);
    return if (lookup.len > 0) ids.getSymbolPins(self, lookup) else null;
}

/// Summarise a part's pinout into the structural facts semantic classification
/// needs (`env.PinoutFacts`). Reads the already-loaded, already-cached pad →
/// function map, so it costs one pass over a map the instance build resolved
/// anyway — never a second file read.
///
/// A null map (no `lib/pinouts` file) yields the all-false `known = false`
/// value, which every consumer must read as "no evidence" rather than as
/// "no supply pin": most passives simply have no pinout to consult.
fn summarisePinout(pinout: ?*const std.StringHashMapUnmanaged([]const u8)) env_mod.PinoutFacts {
    const map = pinout orelse return .{};
    var facts = env_mod.PinoutFacts{ .known = true, .positional = true };
    var it = map.iterator();
    while (it.next()) |entry| {
        const fn_name = entry.value_ptr.*;
        facts.pin_count +|= 1;
        if (pin_roles.isSupplyFn(fn_name)) facts.has_supply = true;
        if (pin_roles.isGroundFn(fn_name)) facts.has_ground = true;
        if (!isAllDigits(fn_name)) facts.positional = false;
    }
    if (facts.pin_count == 0) return .{};
    return facts;
}

/// True when `s` is a non-empty run of decimal digits — the importer's
/// "I had no function name for this pad, so I wrote its number" spelling
/// (`(pin 07 "07")`). Used only to detect that shape, never to parse a value.
fn isAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// Warn once when an instance wires a component that has no pinout file. With
/// `reverse_pinout == null` every `(pin N …)` token is taken verbatim, so
/// nothing checks the pad numbers against the real part. Gated to genuine
/// multi-pad ICs — fires only at ≥3 distinct pads, so 2-pin passives (covered by
/// the generic-cap/res/ind pinouts anyway), test points, LEDs, diodes and
/// fiducials never trip it. The hint names the pinout file to add.
fn warnPinoutlessMultiPad(
    self: *Evaluator,
    span: ast.Span,
    inst: *const Instance,
    reverse_pinout: ?*const std.StringHashMapUnmanaged([]const u8),
    pin_nets: []const PinNetDecl,
) void {
    if (reverse_pinout != null or pin_nets.len < 3) return;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(self.allocator);
    for (pin_nets) |pn| seen.put(self.allocator, pn.pin, {}) catch continue;
    if (seen.count() < 3) return;
    const lookup = pinoutLookupName(self, inst);
    const hint = if (lookup.len > 0) lookup else inst.component;
    self.warnFmt(span, "instance \"{s}\": component \"{s}\" has no pinout — pad " ++
        "numbers are unchecked (add lib/pinouts/{s}.sexp or regenerate_pinout " ++
        "to validate them)", .{ inst.ref_des, inst.component, hint });
}

/// Error when `pad` is not a pad this part has.
///
/// A `(pin 99 "X")` on an 11-pad part used to produce nothing but a
/// downstream floating-net warning about net `X`; the pad itself reached the
/// netlist and the KiCad export as a pad no footprint defines. The two
/// library records that can answer are consulted in cost order: the pinout
/// map (already resolved and in memory), then the footprint's pad ids (one
/// cached read). A part with neither record has an unknown pad set, so its
/// tokens pass unchecked — that is most passives' normal state.
fn requirePad(self: *Evaluator, pads: PartPads, span: ast.Span, ref_des: []const u8, ref: PadRef) EvalError!void {
    const pad = ref.pad;
    if (pad.len == 0) return;
    const pinout_count = if (pads.pinout) |pm| blk: {
        if (pm.contains(pad)) return;
        break :blk pm.count();
    } else 0;
    const fp = footprint_pads.get(self, pads.footprint);
    const fp_count = if (fp) |f| blk: {
        if (f.contains(pad)) return;
        break :blk f.count();
    } else 0;
    if (pinout_count == 0 and fp_count == 0) return; // pad set unknown — say nothing
    // The two records overlap, so the larger of them is the honest floor on
    // how many pads the part has — and the number the author can count.
    self.setError(span, padErrorMessage(self, pads, ref_des, ref, @max(pinout_count, fp_count)));
    return EvalError.InvalidForm;
}

/// The diagnostic for a pad that does not exist, with a did-you-mean when the
/// token is a near-miss of one of the part's pin FUNCTION names (`VDDA` for
/// `VDA`) — the spelling authors reach for, and the one a pad-id list cannot
/// hint at. Error path only, so the candidate scan is never a build cost.
fn padErrorMessage(self: *Evaluator, pads: PartPads, ref_des: []const u8, ref: PadRef, pad_count: usize) []const u8 {
    const raw = ref.raw;
    const hint = nearestPinFunction(self, pads.pinout, raw);
    const suffix = if (hint) |h|
        std.fmt.allocPrint(self.allocator, " — did you mean {s}?", .{h}) catch ""
    else
        "";
    return std.fmt.allocPrint(
        self.allocator,
        "({s} {s} …) on instance \"{s}\" — this part has no pad {s} ({d} pads){s}",
        .{ ref.form, raw, ref_des, raw, pad_count, suffix },
    ) catch "pad does not exist on this part";
}

/// Nearest pin function name to `raw` across the part's pinout, or null when
/// the part has no pinout or nothing is within the suggester's edit budget.
fn nearestPinFunction(self: *Evaluator, pinout: ?*const std.StringHashMapUnmanaged([]const u8), raw: []const u8) ?[]const u8 {
    // A numeric pad token is a pad id the author got wrong, not a misspelled
    // function name; and below three characters a two-edit budget reaches
    // essentially every short function name ("P1" is two edits from "NC").
    // Both produce confident nonsense, so neither gets a hint.
    if (raw.len < 3 or isAllDigits(raw)) return null;
    const map = pinout orelse return null;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(self.allocator);
    var it = map.valueIterator();
    while (it.next()) |v| names.append(self.allocator, v.*) catch return null;
    return suggest.nearestOf(raw, names.items, .advisory);
}

/// Parse a `(part "Name" (row N) (col N) (pin … "NET") …)` multi-part-symbol
/// block on an instance. Each inner `(pin …)` is wired exactly like a
/// top-level pin (appended to `pin_nets`, so the IC is electrically connected),
/// and the resolved (pin, net) pairs are recorded as a `Part` tagged with the
/// part name so the schematic renders one labelled box per part. `(row …)` /
/// `(col …)` grid hints are layout-only and ignored here.
fn parsePartForm(
    self: *Evaluator,
    form: Node,
    ref_des: []const u8,
    env: *Env,
    pin_nets: *std.ArrayList(PinNetDecl),
    parts: *std.ArrayList(env_mod.Part),
    pads: PartPads,
) EvalError!void {
    const children = form.asList() orelse return;
    if (children.len < 2) return;
    const name_val = try self.evalNode(children[1], env);
    const name = name_val.asString() orelse (children[1].asAtom() orelse "");

    // Wire the part's pins through the same parser top-level pins use, then snapshot
    // the freshly-appended (pin, net) pairs into a Part (grouped by the part name).
    const before = pin_nets.items.len;
    for (children[2..]) |child| {
        if (child.isForm("pin")) try parsePinForm(self, child, ref_des, env, pin_nets, pads);
    }
    var part_pins: std.ArrayList(env_mod.PartPin) = .empty;
    for (pin_nets.items[before..]) |pn| {
        try part_pins.append(self.allocator, .{ .pin = pn.pin, .net = pn.net, .group = name });
    }
    try parts.append(self.allocator, .{
        .name = name,
        .pins = part_pins.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
    });
}

/// Parse a `(near "REF" PIN [(own PAD)])` adjacency declaration into `out`.
///
/// PIN is kept RAW here, exactly as `(decouples …)` keeps its pad: the pinout
/// that gives a function name meaning belongs to the TARGET, which this passive
/// cannot see (it has no pinout of its own) and which may be declared later in
/// the block. `builders.resolveNearTargets` resolves it once every instance
/// exists. `(own PAD)` names a pad of THIS part, so it resolves here through the
/// part's own reverse pinout like any `(pin …)` token.
///
/// A malformed form warns and binds nothing — silently keeping half a binding
/// would place the part against a pad the author never named.
/// `(decouples "IC" PIN)` — bind this cap's power leg to a specific hub pad;
/// `(decouples rail)` — opt out of the per-pin-decoupling lint because the cap
/// deliberately serves the whole rail. The twin of `parseNear` below, and split
/// out for the same reason: the instance body reads as a list of sub-forms, not
/// as one function holding every sub-form's grammar.
fn parseDecouples(
    self: *Evaluator,
    form: Node,
    ref_des: []const u8,
    env: *Env,
    out: *env_mod.DecoupleBind,
) EvalError!void {
    const dc = form.asList().?;
    if (dc.len == 2 and std.mem.eql(u8, dc[1].asAtom() orelse "", "rail")) {
        out.rail = true;
        return;
    }
    if (dc.len < 3) {
        self.warnFmt(form.span, "(decouples …) on \"{s}\" — expected (decouples \"IC\" PIN) or (decouples rail)", .{ref_des});
        return;
    }
    const ic_val = try self.evalNode(dc[1], env);
    out.ic = ic_val.asString() orelse (dc[1].asAtom() orelse "");
    // PIN is kept RAW here and resolved later, in
    // `builders.resolveDecoupleTargets`, against the TARGET IC's pinout. It
    // cannot be resolved at this point: the pinout that gives the token meaning
    // belongs to the named IC, not to this cap (a cap has none), and the target
    // may be declared after the cap in the block, so it need not exist yet.
    // Resolving it here through `reverse_pinout` — the CAP's map — is what made
    // every function-name spelling silently degrade to the raw token.
    out.pin = ids.pinId(self, dc[2]) orelse "";
}

fn parseNear(
    self: *Evaluator,
    form: Node,
    ref_des: []const u8,
    env: *Env,
    pads: PartPads,
    out: *env_mod.NearBind,
) EvalError!void {
    const nc = form.asList().?;
    if (nc.len < 3) {
        self.warnFmt(form.span, "(near …) on \"{s}\" — expected (near \"REF\" PIN [(own PAD)])", .{ref_des});
        return;
    }
    const ref_val = try self.evalNode(nc[1], env);
    const target_ref = ref_val.asString() orelse (nc[1].asAtom() orelse "");
    const target_pin = ids.pinId(self, nc[2]) orelse "";
    if (target_ref.len == 0 or target_pin.len == 0) {
        self.warnFmt(form.span, "(near …) on \"{s}\" — expected (near \"REF\" PIN [(own PAD)])", .{ref_des});
        return;
    }
    var own: []const u8 = "";
    for (nc[3..]) |extra| {
        const oc = extra.asList() orelse {
            self.warnFmt(extra.span, "ignored token in (near …) on \"{s}\" — the only trailing form is (own PAD)", .{ref_des});
            continue;
        };
        if (oc.len != 2 or !std.mem.eql(u8, oc[0].asAtom() orelse "", "own")) {
            self.warnFmt(extra.span, "ignored sub-form in (near …) on \"{s}\" — the only trailing form is (own PAD)", .{ref_des});
            continue;
        }
        const raw = ids.pinId(self, oc[1]) orelse "";
        own = if (pads.pinout) |rp| (resolvePinName(self, rp, raw, oc[1].span) orelse raw) else raw;
        try requirePad(self, pads, oc[1].span, ref_des, .{ .form = "own", .raw = raw, .pad = own });
    }
    out.* = .{ .ref = target_ref, .pin = target_pin, .own = own };
}

/// Parse a `(strap-ok PIN "reason")` blessing into `strap_oks`. PIN resolves
/// like a `(pin …)` token (a function name maps through the pinout to its
/// physical pad); the reason is the author's sign-off the `strap_tied_to_rail`
/// ERC requires. A malformed form warns and is dropped.
fn parseStrapOk(
    self: *Evaluator,
    form: Node,
    ref_des: []const u8,
    env: *Env,
    pads: PartPads,
    strap_oks: *std.ArrayList(env_mod.StrapOk),
) EvalError!void {
    const sc = form.asList().?;
    if (sc.len < 3) {
        self.warnFmt(form.span, "(strap-ok …) on \"{s}\" — expected (strap-ok PIN \"reason\")", .{ref_des});
        return;
    }
    const raw = ids.pinId(self, sc[1]) orelse "";
    const pad = if (pads.pinout) |rp| (resolvePinName(self, rp, raw, sc[1].span) orelse raw) else raw;
    try requirePad(self, pads, sc[1].span, ref_des, .{ .form = "strap-ok", .raw = raw, .pad = pad });
    const reason = (try self.evalNode(sc[2], env)).asString() orelse "";
    try strap_oks.append(self.allocator, .{ .pin = pad, .reason = reason });
}

/// Parse a `(nc-ok PIN "reason")` blessing into `nc_oks`. PIN resolves like a
/// `(pin …)` token (a function name maps through the pinout to its physical
/// pad); the reason is the author's sign-off the `no_connect` ERC requires to
/// accept a deliberately-unconnected pad. A malformed form warns and is dropped.
fn parseNcOk(
    self: *Evaluator,
    form: Node,
    ref_des: []const u8,
    env: *Env,
    pads: PartPads,
    nc_oks: *std.ArrayList(env_mod.NcOk),
) EvalError!void {
    const sc = form.asList().?;
    if (sc.len < 3) {
        self.warnFmt(form.span, "(nc-ok …) on \"{s}\" — expected (nc-ok PIN \"reason\")", .{ref_des});
        return;
    }
    const raw = ids.pinId(self, sc[1]) orelse "";
    const pad = if (pads.pinout) |rp| (resolvePinName(self, rp, raw, sc[1].span) orelse raw) else raw;
    try requirePad(self, pads, sc[1].span, ref_des, .{ .form = "nc-ok", .raw = raw, .pad = pad });
    const reason = (try self.evalNode(sc[2], env)).asString() orelse "";
    try nc_oks.append(self.allocator, .{ .pin = pad, .reason = reason });
}

/// Parsed trailing annotations of a `(pin …)` form: `tail` is the count of
/// children before the annotations (the pin tokens + net name); the remaining
/// fields carry the optional `(i-typ …)/(i-max …)/(load …)` values.
pub const PinTail = struct { tail: usize, i_typ: ?f64 = null, i_max: ?f64 = null, load_label: []const u8 = "" };

/// Walk the trailing `(i-typ …)/(i-max …)/(load …)` annotations off the end of
/// a `(pin …)` form (they sit after the net name) into a `PinTail`. Shared by
/// `parsePinForm` (inline `(instance … (pin …))`) and `builders.processPinForm`
/// (`(pins …)` blocks) so the two parse paths can't drift.
pub fn parsePinTail(self: *Evaluator, pin_children: []const Node, env: *Env) EvalError!PinTail {
    var t = PinTail{ .tail = pin_children.len };
    while (t.tail > 0) {
        const last = pin_children[t.tail - 1];
        if (last.isForm("i-typ")) {
            const cc = last.asList().?;
            if (cc.len >= 2) t.i_typ = cc[1].asNumber();
            t.tail -= 1;
        } else if (last.isForm("i-max")) {
            const cc = last.asList().?;
            if (cc.len >= 2) t.i_max = cc[1].asNumber();
            t.tail -= 1;
        } else if (last.isForm("load")) {
            const cc = last.asList().?;
            if (cc.len >= 2) t.load_label = (try self.evalNode(cc[1], env)).asString() orelse (cc[1].asAtom() orelse "");
            t.tail -= 1;
        } else break;
    }
    return t;
}

/// Scan a pin form's tokens (the slice between the `pin` head and the net) for
/// `(as "FN" …)` assertions. `(as …)` only makes sense for a single-pin form,
/// so the asserted names are returned only when exactly one pin token is
/// present; otherwise an empty slice (the assertion is silently dropped).
pub fn scanAssertedFns(self: *Evaluator, tokens: []const Node, env: *Env) EvalError![]const []const u8 {
    var asserted_buf: std.ArrayList([]const u8) = .empty;
    var pin_count: usize = 0;
    for (tokens) |child| {
        if (child.isForm("as")) {
            const ac = child.asList().?;
            for (ac[1..]) |arg| {
                const val = try self.evalNode(arg, env);
                const name = val.asString() orelse (arg.asAtom() orelse "");
                if (name.len == 0) continue;
                asserted_buf.append(self.allocator, name) catch return EvalError.OutOfMemory;
            }
        } else {
            pin_count += 1;
        }
    }
    if (pin_count == 1) return asserted_buf.toOwnedSlice(self.allocator) catch &.{};
    return &.{};
}

/// Parse a single `(pin … "NET" [(i-typ X) (i-max Y) (as "FN")])` form on
/// an instance, expanding multi-pin shorthand and resolving each pin token
/// either as a physical pin ID or as a function name through the pinout
/// reverse map. Each resolved (pin, net) pair gets appended to `pin_nets`
/// with the optional asserted-function and current-annotation metadata.
pub fn parsePinForm(
    self: *Evaluator,
    form: Node,
    ref_des: []const u8,
    env: *Env,
    pin_nets: *std.ArrayList(PinNetDecl),
    pads: PartPads,
) EvalError!void {
    const pin_children = form.asList() orelse return;
    if (pin_children.len < 3) return;

    const t = try parsePinTail(self, pin_children, env);
    const tail = t.tail;
    const i_typ = t.i_typ;
    const i_max = t.i_max;
    const load_label = t.load_label;
    if (tail < 3) return;

    const net_val = try self.evalNode(pin_children[tail - 1], env);
    const net_name = net_val.asString() orelse return;

    const asserted_fns = try scanAssertedFns(self, pin_children[1 .. tail - 1], env);

    var first_pin = true;
    for (pin_children[1 .. tail - 1]) |pin_node| {
        if (pin_node.isForm("as")) continue;
        const raw = ids.pinId(self, pin_node) orelse continue;
        // Resolve: try as function name first (via pinout), fall back to physical pin ID
        const pn = if (pads.pinout) |pm| (resolvePinName(self, pm, raw, pin_node.span) orelse raw) else raw;
        try requirePad(self, pads, pin_node.span, ref_des, .{ .form = "pin", .raw = raw, .pad = pn });
        try pin_nets.append(self.allocator, .{
            .ref_des = ref_des,
            .pin = pn,
            .net = net_name,
            .asserted_fns = asserted_fns,
            .i_typ = if (first_pin) i_typ else null,
            .i_max = if (first_pin) i_max else null,
            .load_label = if (first_pin) load_label else "",
        });
        first_pin = false;
    }
}

/// Build an Instance from a Value (.component or .component_instance),
/// looking up cached footprint/symbol/properties. Unlike `buildInstance`, an
/// uncached component family is not an error — the returned instance's library
/// fields come back empty.
pub fn instanceFromValue(self: *Evaluator, val: Value, ref_des: []const u8, source_offset: u32, id: []const u8) ?Instance {
    const resolved = resolveComponent(self, val) orelse return null;
    return Instance{
        .ref_des = ref_des,
        .component = resolved.family,
        .value = resolved.value,
        .footprint = resolved.footprint,
        .symbol = resolved.symbol,
        .pinout = resolved.pinout,
        .properties = resolved.properties,
        .attrs = resolved.attrs,
        .typed_attrs = resolved.typed_attrs,
        .docs = resolved.docs,
        .requirements = resolved.requirements,
        .requirements_ignored = resolved.requirements_ignored,
        .electrical = resolved.electrical,
        .source_offset = source_offset,
        .id = id,
        .thermal = .{ .decl = resolved.thermal },
    };
}

/// Merge override properties into an instance, replacing matching keys.
pub fn mergeInstanceProperties(
    self: *Evaluator,
    inst: *Instance,
    overrides: []const env_mod.Property,
) std.mem.Allocator.Error!void {
    if (overrides.len == 0) return;
    var merged: std.ArrayList(env_mod.Property) = .empty;
    for (inst.properties) |cp| {
        var overridden = false;
        for (overrides) |ip| {
            if (std.mem.eql(u8, cp.key, ip.key)) {
                overridden = true;
                break;
            }
        }
        if (!overridden) try merged.append(self.allocator, cp);
    }
    for (overrides) |ip| try merged.append(self.allocator, ip);
    inst.properties = try merged.toOwnedSlice(self.allocator);
}

/// Parse trailing arguments: extract net names, properties, and optional note.
pub const TrailingArgs = struct {
    nets: std.ArrayList([]const u8),
    props: std.ArrayList(env_mod.Property),
    note: ?[]const u8,
};

/// Walk the trailing args of a `(series …)` form and bucket each child into
/// a net string, an inline `(key "value")` property, or a single `(note …)`
/// text. Used by both the named and auto-ref-des series forms so they share
/// one parser.
pub fn parseTrailingArgs(self: *Evaluator, children: []const Node, env: *Env) EvalError!TrailingArgs {
    var result = TrailingArgs{
        .nets = .empty,
        .props = .empty,
        .note = null,
    };
    for (children) |fc| {
        if (fc.isForm("id") or fc.isForm("ids")) continue;
        if (fc.asList()) |cl| {
            if (cl.len >= 2) {
                const k = cl[0].asAtom() orelse continue;
                if (std.mem.eql(u8, k, "note")) {
                    result.note = cl[1].asString();
                } else {
                    const v = cl[1].asString() orelse continue;
                    try result.props.append(self.allocator, .{ .key = k, .value = v });
                }
            }
        } else {
            const v = (try self.evalNode(fc, env)).asString() orelse continue;
            try result.nets.append(self.allocator, v);
        }
    }
    return result;
}

/// Get the component family name from a Value.
pub fn componentFamily(val: Value) []const u8 {
    return switch (val) {
        .component => |c| c,
        .component_instance => |ci| ci.family,
        else => "",
    };
}

/// Order two pad ids: numerically when both parse as integers (so "2" < "10"),
/// else lexicographically (a BGA "A1" / "B2"). Mirrors the placement optimizer's
/// `pinLess`; here it is the tie-break that makes a duplicated function name
/// resolve to the same pad on every run.
fn padLess(a: []const u8, b: []const u8) bool {
    const ai: ?i64 = std.fmt.parseInt(i64, a, 10) catch null;
    const bi: ?i64 = std.fmt.parseInt(i64, b, 10) catch null;
    if (ai != null and bi != null) return ai.? < bi.?;
    return std.mem.lessThan(u8, a, b);
}

/// Resolve a function name to a physical pin ID using the pinout map (which maps
/// pin_id → function_name, so this is a reverse lookup).
///
/// A real pinout names the SAME function on several pads — a USB-C receptacle
/// carries `VBUS` on four contacts, an MCU repeats an EXTI name across ports —
/// and the map is a hash table, so returning "the first match" returned whatever
/// the hash happened to place first: the same source could bind a different pad
/// after an unrelated edit shifted the map's layout. Every match is collected
/// and the LOWEST pad id wins, which is stable across any rehash, and the
/// ambiguity is reported at `span` with the fix (spell the pad) in the message
/// rather than silently picking one of N pads for the author.
pub fn resolvePinName(
    self: *Evaluator,
    pinout: *const std.StringHashMapUnmanaged([]const u8),
    name: []const u8,
    span: ast.Span,
) ?[]const u8 {
    const m = matchPinName(pinout, name) orelse return null;
    if (m.matches > 1) {
        self.warnFmt(span, "pin function '{s}' names {d} pads on this part (lowest '{s}', next '{s}') — using '{s}'; write the pad id instead to bind a different one", .{ name, m.matches, m.pad, m.second, m.pad });
    }
    return m.pad;
}

/// One reverse pinout lookup: the pad chosen for `name`, how many pads carry
/// that function, and the runner-up (for the ambiguity message). Split out of
/// `resolvePinName` so a caller holding no source span — a post-build pass, whose
/// instances no longer remember where they were written — can still resolve the
/// *same* pad without emitting a compiler-style warning pointing nowhere.
pub const PinMatch = struct {
    pad: []const u8,
    matches: usize,
    second: []const u8 = "",
};

/// Every pad whose function name is `name`, reduced to the lowest pad id.
/// Null when nothing matches.
pub fn matchPinName(pinout: *const std.StringHashMapUnmanaged([]const u8), name: []const u8) ?PinMatch {
    var best: ?[]const u8 = null;
    var second: ?[]const u8 = null;
    var matches: usize = 0;
    var iter = pinout.iterator();
    while (iter.next()) |entry| {
        if (!std.mem.eql(u8, entry.value_ptr.*, name)) continue;
        const pad = entry.key_ptr.*;
        matches += 1;
        if (best == null or padLess(pad, best.?)) {
            second = best;
            best = pad;
        } else if (second == null or padLess(pad, second.?)) {
            second = pad;
        }
    }
    return .{ .pad = best orelse return null, .matches = matches, .second = second orelse "" };
}

/// Evaluate a (series ...) form and emit instances + pin nets.
/// Supports both named and auto ref-des forms:
///   (series "REF" (comp) "NET1" "NET2")
///   (series (comp) "NET1" "NET2" "NET3" "NET4" ...) -- one instance per pair
pub fn evalSeriesForm(
    self: *Evaluator,
    form_children: []const Node,
    env: *Env,
    instances: *std.ArrayList(Instance),
    all_pin_nets: *std.ArrayList(PinNetDecl),
    note_list: *std.ArrayList(Note),
) EvalError!void {
    if (form_children.len < 4) return;
    const first_val = try self.evalNode(form_children[1], env);
    // Parse (id ...) from series form children
    const series_parsed_id = ids.parseId(form_children);

    if (first_val == .component or first_val == .component_instance) {
        // Auto ref-des: (series (comp) "NET1" "NET2" ...)
        const comp_offset = ids.componentSourceOffset(form_children[1]);
        // Stamp the series form's own (id) anchor. Under (hierarchical-ids) this
        // single uuid seeds every per-pair child's derived id; otherwise the
        // children get pinned tokens from the (ids …) sidecar keyed on
        // value#pair-index, so a net rename no longer rotates their ids.
        const series_id = series_parsed_id orelse blk: {
            const gen = try ids.generateId(self);
            try self.pending_ids.append(self.allocator, .{
                .form_offset = form_children[0].span.offset -| 1,
                .id = gen,
            });
            break :blk gen;
        };
        var sidecar = ids.parseChildIdSidecar(self, form_children);
        const series_value = if (resolveComponent(self, first_val)) |r| r.value else "";
        const ta = try parseTrailingArgs(self, form_children[2..], env);
        var ni: usize = 0;
        while (ni + 1 < ta.nets.items.len) : (ni += 2) {
            const ref = try ids.nextRefDes(self, ids.componentPrefix(componentFamily(first_val)));
            const child_key = try std.fmt.allocPrint(self.allocator, "{s}#{d}", .{ series_value, ni / 2 });
            // Same identity split as decouple: derive from the form uuid under
            // (hierarchical-ids), else take the token from the (ids …) sidecar.
            const child_id = if (self.hierarchical_ids)
                try ids.deriveChildId(self, series_id, child_key, 0)
            else
                try ids.getOrCreateChildId(self, &sidecar, child_key);
            var inst = instanceFromValue(self, first_val, ref, comp_offset, child_id) orelse continue;
            inst.origin_key = child_key; // stable structural key for hierarchical sub-block ids
            try instances.append(self.allocator, inst);
            try all_pin_nets.append(self.allocator, .{ .ref_des = ref, .pin = "1", .net = ta.nets.items[ni] });
            try all_pin_nets.append(self.allocator, .{ .ref_des = ref, .pin = "2", .net = ta.nets.items[ni + 1] });
        }
    } else {
        // Named ref-des: (series "REF" (comp) "NET1" "NET2")
        if (form_children.len < series_named_ref_min_arity) return;
        const s_ref = first_val.asString() orelse return;
        const s_comp_val = try self.evalNode(form_children[2], env);
        const s_comp_offset = ids.componentSourceOffset(form_children[2]);
        const s_id = series_parsed_id orelse try ids.generateId(self);
        if (series_parsed_id == null) {
            try self.pending_ids.append(self.allocator, .{
                .form_offset = form_children[0].span.offset -| 1,
                .id = s_id,
            });
        }
        const ta = try parseTrailingArgs(self, form_children[3..], env);
        if (ta.nets.items.len < 2) return;
        var s_inst = instanceFromValue(self, s_comp_val, s_ref, s_comp_offset, s_id) orelse return;
        s_inst.origin_key = s_ref; // stable source name for hierarchical sub-block ids
        try mergeInstanceProperties(self, &s_inst, ta.props.items);
        try ids.noteAuthoredRefDes(self, s_ref, form_children[0].span);
        try instances.append(self.allocator, s_inst);
        try all_pin_nets.append(self.allocator, .{ .ref_des = s_ref, .pin = "1", .net = ta.nets.items[0] });
        try all_pin_nets.append(self.allocator, .{ .ref_des = s_ref, .pin = "2", .net = ta.nets.items[1] });
        if (ta.note) |text| try note_list.append(self.allocator, .{ .ref_des = s_ref, .text = text });
    }
}

/// Evaluate `(fanout "COMMON" (comp) "NET1" "NET2" … [(id …)])` — place one
/// `comp` instance between the shared COMMON net and each listed target net.
/// A star of identical series elements (e.g. ferrite beads from one rail out
/// to several filtered rails), collapsing N `(series …)` lines into one. Each
/// branch auto-assigns a ref-des; child ids derive from the form id under
/// `(hierarchical-ids)`, else from the `(ids …)` sidecar keyed on value#index
/// — the same identity split `(series …)` uses for its per-pair children.
pub fn evalFanoutForm(
    self: *Evaluator,
    form_children: []const Node,
    env: *Env,
    instances: *std.ArrayList(Instance),
    all_pin_nets: *std.ArrayList(PinNetDecl),
) EvalError!void {
    if (form_children.len < 4) return;
    const common = (try self.evalNode(form_children[1], env)).asString() orelse return;
    const comp_val = try self.evalNode(form_children[2], env);
    if (comp_val != .component and comp_val != .component_instance) return;
    const comp_offset = ids.componentSourceOffset(form_children[2]);

    const fanout_id = ids.parseId(form_children) orelse blk: {
        const gen = try ids.generateId(self);
        try self.pending_ids.append(self.allocator, .{
            .form_offset = form_children[0].span.offset -| 1,
            .id = gen,
        });
        break :blk gen;
    };
    var sidecar = ids.parseChildIdSidecar(self, form_children);
    const value = if (resolveComponent(self, comp_val)) |r| r.value else "";
    const ta = try parseTrailingArgs(self, form_children[3..], env);

    for (ta.nets.items, 0..) |target_net, i| {
        const ref = try ids.nextRefDes(self, ids.componentPrefix(componentFamily(comp_val)));
        const child_key = try std.fmt.allocPrint(self.allocator, "{s}#{d}", .{ value, i });
        const child_id = if (self.hierarchical_ids)
            try ids.deriveChildId(self, fanout_id, child_key, 0)
        else
            try ids.getOrCreateChildId(self, &sidecar, child_key);
        var inst = instanceFromValue(self, comp_val, ref, comp_offset, child_id) orelse continue;
        inst.origin_key = child_key;
        try instances.append(self.allocator, inst);
        try all_pin_nets.append(self.allocator, .{ .ref_des = ref, .pin = "1", .net = common });
        try all_pin_nets.append(self.allocator, .{ .ref_des = ref, .pin = "2", .net = target_net });
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const parser_mod = @import("../sexpr/parser.zig");

// spec: eval/evaluator - hierarchical-ids derives series child ids from the form id instead of the (ids ...) sidecar
test "hierarchical series derives child ids from form id" {
    // page_allocator: evaluator-allocated keys/ids are intentionally never freed.
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    eval.hierarchical_ids = true;
    var env = Env.init(alloc, null);
    defer env.deinit();
    try eval.component_cache.put(alloc, "ind-2016", .{
        .name = "ind-2016",
        .symbol_name = "",
        .footprint_name = "",
        .is_family = true,
        .param_type = "",
    });

    const nodes = try parser_mod.parse(alloc, "(series (ind-2016 \"1uH\") \"VA\" \"VB\" (id abcd1234))");
    const form_children = nodes[0].asList().?;
    var instances: std.ArrayList(Instance) = .empty;
    var all_pin_nets: std.ArrayList(PinNetDecl) = .empty;
    var notes: std.ArrayList(Note) = .empty;

    try evalSeriesForm(&eval, form_children, &env, &instances, &all_pin_nets, &notes);

    try testing.expectEqual(@as(usize, 1), instances.items.len);
    const expected = try ids.deriveChildId(&eval, "abcd1234", "1uH#0", 0);
    try testing.expectEqualStrings(expected, instances.items[0].id);
    try testing.expectEqualStrings("1uH#0", instances.items[0].origin_key);
}

// spec: eval/design_block - fanout places one component from COMMON to each listed net
test "evalFanoutForm stars one component from common to each target net" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    eval.hierarchical_ids = true;
    var env = Env.init(alloc, null);
    defer env.deinit();
    try eval.component_cache.put(alloc, "ferrite-0402", .{
        .name = "ferrite-0402",
        .symbol_name = "",
        .footprint_name = "",
        .is_family = true,
        .param_type = "",
    });

    const nodes = try parser_mod.parse(alloc, "(fanout \"V1P8\" (ferrite-0402 \"600R\") \"VA\" \"VB\" \"VC\" (id abcd1234))");
    const form_children = nodes[0].asList().?;
    var instances: std.ArrayList(Instance) = .empty;
    var all_pin_nets: std.ArrayList(PinNetDecl) = .empty;

    try evalFanoutForm(&eval, form_children, &env, &instances, &all_pin_nets);

    // One component per target net, child key value#index.
    try testing.expectEqual(@as(usize, 3), instances.items.len);
    try testing.expectEqualStrings("600R#0", instances.items[0].origin_key);
    try testing.expectEqualStrings("600R#2", instances.items[2].origin_key);
    // Every branch ties pin 1 to the shared common net, pin 2 to its target.
    try testing.expectEqual(@as(usize, 6), all_pin_nets.items.len);
    try testing.expectEqualStrings("V1P8", all_pin_nets.items[0].net);
    try testing.expectEqualStrings("VA", all_pin_nets.items[1].net);
    try testing.expectEqualStrings("V1P8", all_pin_nets.items[2].net);
    try testing.expectEqualStrings("VC", all_pin_nets.items[5].net);
}

test "evalFanoutForm places one instance for the minimal 4-child form" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    eval.hierarchical_ids = true;
    var env = Env.init(alloc, null);
    defer env.deinit();
    try eval.component_cache.put(alloc, "ferrite-0402", .{
        .name = "ferrite-0402",
        .symbol_name = "",
        .footprint_name = "",
        .is_family = true,
        .param_type = "",
    });

    // Exactly 4 children — (fanout COMMON comp NET) — is the arity floor; the
    // `< 4` guard must let it through and place one branch (a `<= 4` flip drops it).
    const nodes = try parser_mod.parse(alloc, "(fanout \"V1P8\" (ferrite-0402 \"600R\") \"VA\")");
    const form_children = nodes[0].asList().?;
    var instances: std.ArrayList(Instance) = .empty;
    var all_pin_nets: std.ArrayList(PinNetDecl) = .empty;

    try evalFanoutForm(&eval, form_children, &env, &instances, &all_pin_nets);

    try testing.expectEqual(@as(usize, 1), instances.items.len);
    try testing.expectEqual(@as(usize, 2), all_pin_nets.items.len);
    try testing.expectEqualStrings("V1P8", all_pin_nets.items[0].net);
    try testing.expectEqualStrings("VA", all_pin_nets.items[1].net);
}

// spec: eval/instance - bare string arguments after the component bind physical pads 1, 2, and onward in order
test "instance positional nets bind consecutive physical pads" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();
    try eval.component_cache.put(alloc, "header-3", .{
        .name = "header-3",
        .symbol_name = "",
        .footprint_name = "header-3",
        .is_family = false,
        .param_type = "",
    });

    const nodes = try parser_mod.parse(alloc, "(instance \"J1\" header-3 \"VDD\" \"DATA\" \"GND\")");
    const res = try buildInstance(&eval, nodes[0].asList().?, &env);

    try testing.expectEqual(@as(usize, 3), res.pin_nets.len);
    for (res.pin_nets, 0..) |pin_net, i| {
        const expected_pad = try std.fmt.allocPrint(alloc, "{d}", .{i + 1});
        try testing.expectEqualStrings(expected_pad, pin_net.pin);
    }
    try testing.expectEqualStrings("VDD", res.pin_nets[0].net);
    try testing.expectEqualStrings("DATA", res.pin_nets[1].net);
    try testing.expectEqualStrings("GND", res.pin_nets[2].net);
}

// spec: eval/instance - positional nets coexist with legacy pin declarations and all instance metadata sub-forms
test "instance positional nets preserve explicit pins and metadata forms" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();
    try eval.component_cache.put(alloc, "cap-0402", .{
        .name = "cap-0402",
        .symbol_name = "",
        .footprint_name = "cap-0402",
        .is_family = true,
        .param_type = "",
    });

    const src = "(instance \"C1\" (cap-0402 \"100nF\") \"VDD\" (note \"local bypass\") \"GND\" (pin 7 \"SENSE\") (decouples \"U1\" 24) (dnp))";
    const nodes = try parser_mod.parse(alloc, src);
    const res = try buildInstance(&eval, nodes[0].asList().?, &env);

    try testing.expectEqual(@as(usize, 3), res.pin_nets.len);
    try testing.expectEqualStrings("1", res.pin_nets[0].pin);
    try testing.expectEqualStrings("VDD", res.pin_nets[0].net);
    try testing.expectEqualStrings("2", res.pin_nets[1].pin);
    try testing.expectEqualStrings("GND", res.pin_nets[1].net);
    try testing.expectEqualStrings("7", res.pin_nets[2].pin);
    try testing.expectEqualStrings("SENSE", res.pin_nets[2].net);
    try testing.expectEqual(@as(usize, 1), res.inline_notes.len);
    try testing.expectEqualStrings("local bypass", res.inline_notes[0].text);
    try testing.expectEqualStrings("U1", res.instance.bind.decouple.ic);
    try testing.expectEqualStrings("24", res.instance.bind.decouple.pin);
    try testing.expect(res.instance.dnp);
}

// spec: eval/instance - a pin function repeated on several pads resolves to the lowest pad and warns instead of picking by hash order
test "a duplicated pin function resolves to the lowest pad and warns" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();
    try eval.component_cache.put(alloc, "usb-c", .{
        .name = "usb-c",
        .symbol_name = "usbpin",
        .footprint_name = "",
        .is_family = false,
        .param_type = "",
    });
    // A USB-C receptacle carries VBUS on four contacts and GND on one. Insertion
    // order deliberately puts the LOWEST pad last, so "first hash match" cannot
    // accidentally be right.
    var pinout: std.StringHashMapUnmanaged([]const u8) = .empty;
    try pinout.put(alloc, "B9", "VBUS");
    try pinout.put(alloc, "B4", "VBUS");
    try pinout.put(alloc, "A9", "VBUS");
    try pinout.put(alloc, "A4", "VBUS");
    try pinout.put(alloc, "A1", "GND");
    try eval.symbol_pin_cache.put(alloc, "usbpin", pinout);

    const nodes = try parser_mod.parse(alloc, "(instance \"J1\" usb-c (pin VBUS \"VBUS\") (pin GND \"GND\"))");
    const res = try buildInstance(&eval, nodes[0].asList().?, &env);

    // Deterministic pick: the lowest pad id, not whichever the hash yields first.
    try testing.expectEqual(@as(usize, 2), res.pin_nets.len);
    try testing.expectEqualStrings("A4", res.pin_nets[0].pin);
    // The unambiguous function resolves silently.
    try testing.expectEqualStrings("A1", res.pin_nets[1].pin);

    // Exactly one warning, naming the function, the count and the chosen pad.
    try testing.expectEqual(@as(usize, 1), eval.warnings.items.len);
    const msg = eval.warnings.items[0].message;
    try testing.expect(std.mem.indexOf(u8, msg, "VBUS") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "4 pads") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "'A4'") != null);
}

// spec: eval/instance - numeric-aware pad ordering keeps a repeated function on the same pad across rehashes
test "padLess orders pad ids numerically then lexicographically" {
    // "2" < "10" numerically — a plain byte compare would say otherwise.
    try testing.expect(padLess("2", "10"));
    try testing.expect(!padLess("10", "2"));
    // BGA-style ids fall back to byte order.
    try testing.expect(padLess("A4", "A9"));
    try testing.expect(padLess("A9", "B4"));
    // A mixed pair is compared as text, so the answer is still total and stable.
    try testing.expect(padLess("10", "A1"));
}

// spec: eval/instance - (decouples "IC" PIN) binds a cap to a specific hub pad
test "decouples form sets the instance pin binding" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();
    try eval.component_cache.put(alloc, "cap-0402", .{
        .name = "cap-0402",
        .symbol_name = "",
        .footprint_name = "",
        .is_family = true,
        .param_type = "",
    });
    const src = "(instance \"C1\" (cap-0402 \"100nF\") (pin 1 \"VDD\") (pin 2 \"GND\") (decouples \"U1\" 24))";
    const nodes = try parser_mod.parse(alloc, src);
    const res = try buildInstance(&eval, nodes[0].asList().?, &env);
    try testing.expectEqualStrings("U1", res.instance.bind.decouple.ic);
    try testing.expectEqualStrings("24", res.instance.bind.decouple.pin);
    try testing.expect(!res.instance.bind.decouple.rail);
}

// spec: eval/instance - (decouples rail) opts a cap out of the per-pin-decoupling requirement
test "decouples rail sets the rail opt-out flag" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();
    try eval.component_cache.put(alloc, "cap-0402", .{
        .name = "cap-0402",
        .symbol_name = "",
        .footprint_name = "",
        .is_family = true,
        .param_type = "",
    });
    const src = "(instance \"C9\" (cap-0402 \"10uF\") (pin 1 \"VDD\") (pin 2 \"GND\") (decouples rail))";
    const nodes = try parser_mod.parse(alloc, src);
    const res = try buildInstance(&eval, nodes[0].asList().?, &env);
    try testing.expect(res.instance.bind.decouple.rail);
    try testing.expectEqualStrings("", res.instance.bind.decouple.pin);
}

/// A `(near …)` fixture: build `src` against a bare `res-0402` family.
fn nearFixture(alloc: std.mem.Allocator, eval: *Evaluator, env: *Env, src: []const u8) !InstanceResult {
    try eval.component_cache.put(alloc, "res-0402", .{
        .name = "res-0402",
        .symbol_name = "",
        .footprint_name = "",
        .is_family = true,
        .param_type = "",
    });
    const nodes = try parser_mod.parse(alloc, src);
    return buildInstance(eval, nodes[0].asList().?, env);
}

// spec: eval/instance - (near "REF" PIN) records the adjacency target with no own pad inferred at parse time
test "near form records the target ref and pin" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();
    const res = try nearFixture(alloc, &eval, &env, "(instance \"R_TAP\" (res-0402 \"1k\") (pin 1 \"GPIO10\") (pin 2 \"TAP\") (near \"U3\" 14))");
    try testing.expectEqualStrings("U3", res.instance.bind.near.ref);
    try testing.expectEqualStrings("14", res.instance.bind.near.pin);
    // The own leg is deliberately NOT guessed here: it is the leg sharing a net
    // with the target pad, which the netlist knows and one instance does not.
    try testing.expectEqualStrings("", res.instance.bind.near.own);
    // Pure adjacency — it must not read as a decoupling binding.
    try testing.expectEqualStrings("", res.instance.bind.decouple.pin);
    try testing.expect(!res.instance.bind.decouple.rail);
}

// spec: eval/instance - (near … (own PAD)) records which of the declaring part's own legs docks against the target
test "near form records an explicit own pad" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();
    const res = try nearFixture(alloc, &eval, &env, "(instance \"R_TAP\" (res-0402 \"1k\") (pin 1 \"VREF\") (pin 2 \"VREF\") (near \"U3\" 7 (own 2)))");
    try testing.expectEqualStrings("U3", res.instance.bind.near.ref);
    try testing.expectEqualStrings("7", res.instance.bind.near.pin);
    try testing.expectEqualStrings("2", res.instance.bind.near.own);
}

// spec: eval/instance - a (near …) missing its ref or pin warns and binds nothing rather than half a target
test "a malformed near form binds nothing" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();
    const res = try nearFixture(alloc, &eval, &env, "(instance \"R_TAP\" (res-0402 \"1k\") (pin 1 \"A\") (pin 2 \"B\") (near \"U3\"))");
    // Half a binding would place the part against a pad the author never named.
    try testing.expectEqualStrings("", res.instance.bind.near.ref);
    try testing.expectEqualStrings("", res.instance.bind.near.pin);
}

// spec: eval/instance - (strap-ok PIN "reason") records a blessed direct strap tie
test "strap-ok form records the pad and reason" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();
    try eval.component_cache.put(alloc, "somechip", .{
        .name = "somechip",
        .symbol_name = "",
        .footprint_name = "",
        .is_family = false,
        .param_type = "",
    });
    const src = "(instance \"U1\" somechip (pin 5 \"GND\") (strap-ok 5 \"ILIM->GND = default current limit\"))";
    const nodes = try parser_mod.parse(alloc, src);
    const res = try buildInstance(&eval, nodes[0].asList().?, &env);
    try testing.expectEqual(@as(usize, 1), res.instance.strap_oks.len);
    try testing.expectEqualStrings("5", res.instance.strap_oks[0].pin);
    try testing.expectEqualStrings("ILIM->GND = default current limit", res.instance.strap_oks[0].reason);
}

// spec: eval/instance - (power …) on an instance records the authored dissipation and the component's thermal envelope rides along
test "power form records watts and the component thermal envelope reaches the instance" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();
    try eval.component_cache.put(alloc, "somechip", .{
        .name = "somechip",
        .symbol_name = "",
        .footprint_name = "",
        .is_family = false,
        .param_type = "",
        .thermal = .{ .theta_ja = 40, .tj_max = 150 },
    });
    const src = "(instance \"U1\" somechip (pin 1 \"VDD\") (power (typ 0.8) (max 1.5)))";
    const nodes = try parser_mod.parse(alloc, src);
    const res = try buildInstance(&eval, nodes[0].asList().?, &env);
    try testing.expectEqual(@as(f64, 0.8), res.instance.thermal.power.?.typ.?);
    try testing.expectEqual(@as(f64, 1.5), res.instance.thermal.power.?.max.?);
    // The library envelope travels with the part, so the thermal analyzer
    // never has to re-query the evaluator's component cache.
    try testing.expectEqual(@as(f64, 40), res.instance.thermal.decl.?.theta_ja.?);
    try testing.expectEqual(@as(f64, 150), res.instance.thermal.decl.?.tj_max.?);
}

// spec: eval/instance - (nc-ok PIN "reason") records a blessed no-connect pad
test "nc-ok form records the pad and reason" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();
    try eval.component_cache.put(alloc, "somechip", .{
        .name = "somechip",
        .symbol_name = "",
        .footprint_name = "",
        .is_family = false,
        .param_type = "",
    });
    const src = "(instance \"U1\" somechip (pin 1 \"VDD\") (nc-ok 7 \"NC per datasheet — leave floating\"))";
    const nodes = try parser_mod.parse(alloc, src);
    const res = try buildInstance(&eval, nodes[0].asList().?, &env);
    try testing.expectEqual(@as(usize, 1), res.instance.nc_oks.len);
    try testing.expectEqualStrings("7", res.instance.nc_oks[0].pin);
    try testing.expectEqualStrings("NC per datasheet — leave floating", res.instance.nc_oks[0].reason);
}

// spec: eval/instance - (part …) on an instance wires its pins like top-level pins and records the part group
test "part form wires pins and records the part" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();
    try eval.component_cache.put(alloc, "ic8", .{
        .name = "ic8",
        .symbol_name = "",
        .footprint_name = "",
        .is_family = false,
        .param_type = "",
    });
    const src = "(instance \"U1\" ic8 (part \"A\" (pin 1 \"NET1\") (pin 2 \"NET2\")) (part \"B\" (pin 3 \"NET3\")))";
    const nodes = try parser_mod.parse(alloc, src);
    const res = try buildInstance(&eval, nodes[0].asList().?, &env);
    // Every part pin is wired exactly like a top-level pin (the IC connects).
    try testing.expectEqual(@as(usize, 3), res.pin_nets.len);
    // The instance records two parts, each tagged with its part name as group.
    try testing.expectEqual(@as(usize, 2), res.instance.parts.len);
    try testing.expectEqualStrings("A", res.instance.parts[0].name);
    try testing.expectEqual(@as(usize, 2), res.instance.parts[0].pins.len);
    try testing.expectEqualStrings("NET1", res.instance.parts[0].pins[0].net);
    try testing.expectEqualStrings("A", res.instance.parts[0].pins[0].group);
    try testing.expectEqualStrings("B", res.instance.parts[1].name);
    try testing.expectEqual(@as(usize, 1), res.instance.parts[1].pins.len);
}

// spec: eval/evaluator - a pinout-less instance wiring three or more pads warns that the pad numbers are unchecked
test "pinout-less multi-pad wiring warns; two-pad passive stays silent" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();
    // A 2-pin passive family (no lib/pinouts here → reverse_pinout null) wiring
    // exactly two pads must NOT warn: the ≥3-distinct-pad gate excludes it.
    try eval.component_cache.put(alloc, "cap-0402", .{
        .name = "cap-0402",
        .symbol_name = "",
        .footprint_name = "",
        .is_family = true,
        .param_type = "",
    });
    const psrc = "(instance \"C1\" (cap-0402 \"100nF\") (pin 1 \"VDD\") (pin 2 \"GND\"))";
    const pnodes = try parser_mod.parse(alloc, psrc);
    _ = try buildInstance(&eval, pnodes[0].asList().?, &env);
    try testing.expectEqual(@as(usize, 0), eval.warnings.items.len);

    // A pinout-less IC wiring three distinct pads warns exactly once, naming the component.
    try eval.component_cache.put(alloc, "wideband-amp", .{
        .name = "wideband-amp",
        .symbol_name = "",
        .footprint_name = "",
        .is_family = false,
        .param_type = "",
    });
    const usrc = "(instance \"U6\" wideband-amp (pin 1 \"A\") (pin 2 \"B\") (pin 3 \"C\"))";
    const unodes = try parser_mod.parse(alloc, usrc);
    _ = try buildInstance(&eval, unodes[0].asList().?, &env);
    try testing.expectEqual(@as(usize, 1), eval.warnings.items.len);
    try testing.expect(std.mem.indexOf(u8, eval.warnings.items[0].message, "wideband-amp") != null);
    try testing.expect(std.mem.indexOf(u8, eval.warnings.items[0].message, "no pinout") != null);
}

/// Build `src` against a cached component, for the sub-form / pad-existence
/// tests below. `pinout` (pad id → function name) is installed under the
/// component's symbol name when non-empty.
fn hardeningFixture(
    alloc: std.mem.Allocator,
    eval: *Evaluator,
    env: *Env,
    comp: evaluator_mod.Evaluator.ComponentData,
    src: []const u8,
) !InstanceResult {
    try eval.component_cache.put(alloc, comp.name, comp);
    const nodes = try parser_mod.parse(alloc, src);
    return buildInstance(eval, nodes[0].asList().?, env);
}

/// A cached component with no pinout and no footprint — an unknown pad set.
fn bareComponent(name: []const u8) evaluator_mod.Evaluator.ComponentData {
    return .{ .name = name, .symbol_name = "", .footprint_name = "", .is_family = false, .param_type = "" };
}

// spec: eval/instance - an instance sub-form within two edits of a real one is an error naming the spelling meant
test "a typo'd instance sub-form is rejected with a did-you-mean" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();
    const comp: evaluator_mod.Evaluator.ComponentData = .{
        .name = "cap-0402",
        .symbol_name = "",
        .footprint_name = "",
        .is_family = true,
        .param_type = "",
    };
    // Before this check `(decuples …)` became an inline BOM property and the
    // decoupling sign-off it promised was never declared.
    const src = "(instance \"C1\" (cap-0402 \"1uF\") (pin 1 \"VIN\") (pin 2 \"GND\") (decuples \"U1\" 1))";
    try testing.expectError(EvalError.InvalidForm, hardeningFixture(alloc, &eval, &env, comp, src));
    const msg = eval.last_error.?.message;
    try testing.expect(std.mem.indexOf(u8, msg, "unknown sub-form (decuples …)") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "did you mean (decouples …)?") != null);
}

// spec: eval/instance - an unknown sub-form head that is not a near-miss still becomes an inline property
test "a distant unknown sub-form head stays an inline property" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();
    const comp: evaluator_mod.Evaluator.ComponentData = .{
        .name = "cap-0402",
        .symbol_name = "",
        .footprint_name = "",
        .is_family = true,
        .param_type = "",
    };
    // Both keys are real corpus property keys; `(id …)` is a legal head that
    // reaches the same branch and must never read as a typo of `(pin …)`.
    const src = "(instance \"C1\" (cap-0402 \"1uF\") (pin 1 \"VIN\") (module-bypass \"yes\") (emi-couples \"shield\") (id abcd1234))";
    const res = try hardeningFixture(alloc, &eval, &env, comp, src);
    try testing.expectEqual(@as(usize, 2), res.instance.properties.len);
    try testing.expectEqualStrings("module-bypass", res.instance.properties[0].key);
    try testing.expectEqualStrings("emi-couples", res.instance.properties[1].key);
    try testing.expectEqualStrings("abcd1234", res.instance.id);
}

/// Install an 11-pad pinout under symbol `sym` and return the component that
/// uses it. Mirrors a real DFN part: numeric pads with function names.
fn pinoutComponent(alloc: std.mem.Allocator, eval: *Evaluator, sym: []const u8) !evaluator_mod.Evaluator.ComponentData {
    var pins: std.StringHashMapUnmanaged([]const u8) = .empty;
    const rows = [_][2][]const u8{
        .{ "1", "SYS" },   .{ "2", "BAT" },  .{ "3", "STAT2" }, .{ "4", "CE" },
        .{ "5", "GND" },   .{ "6", "TSMR" }, .{ "7", "ILIM" },  .{ "8", "ISET" },
        .{ "9", "STAT1" }, .{ "10", "IN" },  .{ "11", "EP" },
    };
    for (rows) |row| try pins.put(alloc, row[0], row[1]);
    try eval.symbol_pin_cache.put(alloc, sym, pins);
    return .{ .name = "charger", .symbol_name = sym, .footprint_name = "", .is_family = false, .param_type = "" };
}

// spec: eval/instance - a pad token outside the part's known pad set is an error carrying the pad count
test "a pin naming a pad the part does not have is rejected" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();
    const comp = try pinoutComponent(alloc, &eval, "charger-pins");

    try testing.expectError(EvalError.InvalidForm, hardeningFixture(alloc, &eval, &env, comp, "(instance \"U1\" charger (pin 1 \"VIN\") (pin 99 \"X\"))"));
    const msg = eval.last_error.?.message;
    try testing.expect(std.mem.indexOf(u8, msg, "this part has no pad 99") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "(11 pads)") != null);
    // A numeric pad is never hinted at with a function name: every short name
    // sits inside a two-edit budget of "99".
    try testing.expect(std.mem.indexOf(u8, msg, "did you mean") == null);

    // Multi-pin shorthand checks each token, and a function-name near-miss
    // does get a hint.
    try testing.expectError(EvalError.InvalidForm, hardeningFixture(alloc, &eval, &env, comp, "(instance \"U1\" charger (pin 1 2 STAT3 \"X\"))"));
    try testing.expect(std.mem.indexOf(u8, eval.last_error.?.message, "did you mean STAT2?") != null);

    // Every real pad — id or function name — still passes, inside (part …) too.
    _ = try hardeningFixture(alloc, &eval, &env, comp, "(instance \"U1\" charger (pin 1 2 \"VIN\") (pin ISET \"SET\") (part \"P\" (pin 11 \"GND\")))");
}

// spec: eval/instance - strap-ok, nc-ok and a (near …) own pad are held to the same pad set as (pin …)
test "the sign-off sub-forms reject a pad the part does not have" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();
    const comp = try pinoutComponent(alloc, &eval, "charger-pins-b");

    const bad = [_][]const u8{
        "(instance \"U1\" charger (pin 1 \"VIN\") (strap-ok 43 \"tied\"))",
        "(instance \"U1\" charger (pin 1 \"VIN\") (nc-ok 42 \"spare\"))",
        "(instance \"U1\" charger (pin 1 \"VIN\") (near \"U2\" 3 (own 99)))",
    };
    for (bad) |src| try testing.expectError(EvalError.InvalidForm, hardeningFixture(alloc, &eval, &env, comp, src));

    // The same three forms on real pads stay silent.
    const good = "(instance \"U1\" charger (pin 1 \"VIN\") (strap-ok 5 \"ILIM->GND\") (nc-ok 3 \"spare\") (near \"U2\" 3 (own 2)))";
    const res = try hardeningFixture(alloc, &eval, &env, comp, good);
    try testing.expectEqual(@as(usize, 1), res.instance.strap_oks.len);
    try testing.expectEqual(@as(usize, 1), res.instance.nc_oks.len);
    try testing.expectEqualStrings("2", res.instance.bind.near.own);
}

// spec: eval/instance - a part with neither a pinout nor a footprint has an unknown pad set and every pad token passes
test "a part with no pad record accepts any pad token" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();
    // No pinout, no footprint: no evidence either way, so no error — this is
    // the normal state of most passives and of newly imported parts.
    const res = try hardeningFixture(alloc, &eval, &env, bareComponent("mystery"), "(instance \"U9\" mystery (pin 1 \"A\") (pin 77 \"B\") (pin EPAD \"C\"))");
    try testing.expectEqual(@as(usize, 3), res.pin_nets.len);
}

// spec: eval/instance - a footprint's pad ids check the pads of a part that has no pinout file
test "footprint pads check a pinout-less part" {
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/footprints");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/footprints/r-0402.sexp",
        .data = "(footprint \"R\" (pad 1 smd rect (pos 0 0) (size 1 1)) (pad 2 smd rect (pos 1 0) (size 1 1)))",
    });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    var eval = Evaluator.init(alloc, root);
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();
    const comp: evaluator_mod.Evaluator.ComponentData = .{
        .name = "res-0402",
        .symbol_name = "",
        .footprint_name = "r-0402",
        .is_family = true,
        .param_type = "",
    };
    _ = try hardeningFixture(alloc, &eval, &env, comp, "(instance \"R1\" (res-0402 \"10k\") (pin 1 \"A\") (pin 2 \"B\"))");
    try testing.expectError(EvalError.InvalidForm, hardeningFixture(alloc, &eval, &env, comp, "(instance \"R2\" (res-0402 \"10k\") (pin 1 \"A\") (pin 3 \"B\"))"));
    try testing.expect(std.mem.indexOf(u8, eval.last_error.?.message, "no pad 3 (2 pads)") != null);
}
