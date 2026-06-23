const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const env_mod = @import("env.zig");
const evaluator_mod = @import("evaluator.zig");
const Evaluator = evaluator_mod.Evaluator;
const EvalError = evaluator_mod.EvalError;
const ids = @import("ids.zig");
const PinNetDecl = evaluator_mod.PinNetDecl;

// ── Constants ─────────────────────────────────────────────────────
const SERIES_NAMED_REF_MIN_ARITY: usize = 5;

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
    datasheets: []const []const u8 = &.{},
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
    if (self.component_cache.get(family)) |cd| {
        return .{
            .family = family,
            .value = value,
            .footprint = cd.footprint_name,
            .symbol = cd.symbol_name,
            .pinout = cd.pinout_name,
            .properties = cd.properties,
            .attrs = attrs,
            .datasheets = cd.datasheets,
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
        .properties = &.{},
        .attrs = attrs,
    };
}

/// Evaluate an `(instance "REF" (component …) (pin …) …)` form into an
/// `InstanceResult`: the placed `Instance`, every inline pin-net declaration
/// it produced, and any `(note …)` annotations sitting inside the form. The
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
        .datasheets = resolved.datasheets,
        .requirements = resolved.requirements,
        .requirements_ignored = resolved.requirements_ignored,
        .electrical = resolved.electrical,
        .source_offset = comp_offset,
        .id = inst_id,
    };

    // Resolve pinout for reverse lookup (function_name -> pin_id)
    const reverse_pinout: ?*const std.StringHashMapUnmanaged([]const u8) = blk: {
        const comp_data = self.component_cache.get(inst.component);
        const pln = if (comp_data) |cd| (if (cd.pinout_name.len > 0) cd.pinout_name else cd.symbol_name) else inst.symbol;
        if (pln.len > 0) break :blk ids.getSymbolPins(self, pln);
        break :blk null;
    };

    // Parse inline pin declarations:
    //   (pin 1 "NET")               -- single pin
    //   (pin 3 4 5 6 7 "NET")       -- multiple pins on same net
    //   (connect FUNC "NET" ...)     -- connect by function name from pinout
    var pin_nets: std.ArrayListUnmanaged(PinNetDecl) = .empty;
    var parts: std.ArrayListUnmanaged(env_mod.Part) = .empty;
    var inline_notes: std.ArrayListUnmanaged(Note) = .empty;
    var inline_props: std.ArrayListUnmanaged(env_mod.Property) = .empty;
    var dnp_flag = false;
    var decouple_ic: []const u8 = "";
    var decouple_pin: []const u8 = "";
    var decouple_rail = false;

    const known_forms = [_][]const u8{ "pin", "part", "note", "bus", "id", "as", "dnp", "decouples" };

    for (args[2..]) |form| {
        if (form.isForm("note")) {
            const nc = form.asList().?;
            if (nc.len >= 2) {
                const nv = try self.evalNode(nc[1], env);
                if (nv.asString()) |text| {
                    try inline_notes.append(self.allocator, .{ .ref_des = ref_des, .text = text });
                }
            }
        } else if (form.isForm("pin")) {
            try parsePinForm(self, form, ref_des, env, &pin_nets, reverse_pinout);
        } else if (form.isForm("part")) {
            // Multi-part symbol: (part "Name" (row N) (col N) (pin …) …). Each
            // inner (pin …) wires exactly like a top-level pin (so the IC is
            // electrically connected), and the part is recorded on the instance
            // so the schematic renders one labelled box per function group.
            try parsePartForm(self, form, ref_des, env, &pin_nets, &parts, reverse_pinout);
        } else if (form.isForm("dnp")) {
            // (dnp) — mark Do Not Populate. Bare flag form (no value).
            dnp_flag = true;
        } else if (form.isForm("decouples")) {
            // (decouples "IC" PIN) — bind this cap's power leg to a specific hub
            // pad; (decouples rail) — opt out of the per-pin-decoupling lint.
            const dc = form.asList().?;
            if (dc.len == 2 and std.mem.eql(u8, dc[1].asAtom() orelse "", "rail")) {
                decouple_rail = true;
            } else if (dc.len >= 3) {
                const ic_val = try self.evalNode(dc[1], env);
                decouple_ic = ic_val.asString() orelse (dc[1].asAtom() orelse "");
                // Resolve PIN the same way (pin …) does: a function name maps
                // through the pinout to its physical pad, a number stays as-is —
                // so the binding matches the hub's physical pad id the placer uses.
                const raw = ids.pinId(self, dc[2]) orelse "";
                decouple_pin = if (reverse_pinout) |rp| (resolvePinName(self, rp, raw) orelse raw) else raw;
            } else {
                self.warnFmt(form.span, "(decouples …) on \"{s}\" — expected (decouples \"IC\" PIN) or (decouples rail)", .{ref_des});
            }
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
                                const resolved_pin = if (reverse_pinout) |rp| (resolvePinName(self, rp, bus_pin) orelse bus_pin) else bus_pin;
                                try pin_nets.append(self.allocator, .{ .ref_des = ref_des, .pin = resolved_pin, .net = net });
                            }
                            break;
                        }
                    }
                }
            }
        } else {
            // Unknown form -- treat as inline property: (key "value").
            // Shapes that can't become a property (bare tokens, 1-element
            // lists, non-string values) are silently dead — flag them,
            // except the documented-but-inert (row N)/(col N) grid hints.
            const fc = form.asList() orelse {
                self.warnFmt(form.span, "ignored bare token in (instance \"{s}\" …) body", .{ref_des});
                continue;
            };
            if (fc.len < 2) {
                self.warnFmt(form.span, "ignored sub-form in (instance \"{s}\" …) — properties need a value: (key \"value\")", .{ref_des});
                continue;
            }
            const key = fc[0].asAtom() orelse continue;
            if (!env_mod.containsString(&known_forms, key)) {
                const val = (try self.evalNode(fc[1], env)).asString() orelse {
                    if (!std.mem.eql(u8, key, "row") and !std.mem.eql(u8, key, "col")) {
                        self.warnFmt(form.span, "ignored sub-form ({s} …) in (instance \"{s}\" …) — property values must be strings", .{ key, ref_des });
                    }
                    continue;
                };
                try inline_props.append(self.allocator, .{ .key = key, .value = val });
            }
        }
    }

    var final_inst = inst;
    final_inst.dnp = dnp_flag;
    final_inst.decouple_ic = decouple_ic;
    final_inst.decouple_pin = decouple_pin;
    final_inst.decouple_rail = decouple_rail;
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
    pin_nets: *std.ArrayListUnmanaged(PinNetDecl),
    parts: *std.ArrayListUnmanaged(env_mod.Part),
    pinout: ?*const std.StringHashMapUnmanaged([]const u8),
) EvalError!void {
    const children = form.asList() orelse return;
    if (children.len < 2) return;
    const name_val = try self.evalNode(children[1], env);
    const name = name_val.asString() orelse (children[1].asAtom() orelse "");

    // Wire the part's pins through the same parser top-level pins use, then snapshot
    // the freshly-appended (pin, net) pairs into a Part (grouped by the part name).
    const before = pin_nets.items.len;
    for (children[2..]) |child| {
        if (child.isForm("pin")) try parsePinForm(self, child, ref_des, env, pin_nets, pinout);
    }
    var part_pins: std.ArrayListUnmanaged(env_mod.PartPin) = .empty;
    for (pin_nets.items[before..]) |pn| {
        try part_pins.append(self.allocator, .{ .pin = pn.pin, .net = pn.net, .group = name });
    }
    try parts.append(self.allocator, .{
        .name = name,
        .pins = part_pins.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
    });
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
    var asserted_buf: std.ArrayListUnmanaged([]const u8) = .empty;
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
    pin_nets: *std.ArrayListUnmanaged(PinNetDecl),
    pinout: ?*const std.StringHashMapUnmanaged([]const u8),
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
        const pn = if (pinout) |pm| (resolvePinName(self, pm, raw) orelse raw) else raw;
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
        .datasheets = resolved.datasheets,
        .requirements = resolved.requirements,
        .requirements_ignored = resolved.requirements_ignored,
        .electrical = resolved.electrical,
        .source_offset = source_offset,
        .id = id,
    };
}

/// Merge override properties into an instance, replacing matching keys.
pub fn mergeInstanceProperties(
    self: *Evaluator,
    inst: *Instance,
    overrides: []const env_mod.Property,
) std.mem.Allocator.Error!void {
    if (overrides.len == 0) return;
    var merged: std.ArrayListUnmanaged(env_mod.Property) = .empty;
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
    nets: std.ArrayListUnmanaged([]const u8),
    props: std.ArrayListUnmanaged(env_mod.Property),
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

/// Resolve a function name to a physical pin ID using the pinout map.
/// The pinout maps pin_id -> function_name, so we need reverse lookup.
pub fn resolvePinName(self: *Evaluator, pinout: *const std.StringHashMapUnmanaged([]const u8), name: []const u8) ?[]const u8 {
    _ = self;
    // Reverse lookup: find the pin_id whose function_name matches
    var iter = pinout.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.*, name)) {
            return entry.key_ptr.*;
        }
    }
    return null;
}

/// Evaluate a (series ...) form and emit instances + pin nets.
/// Supports both named and auto ref-des forms:
///   (series "REF" (comp) "NET1" "NET2")
///   (series (comp) "NET1" "NET2" "NET3" "NET4" ...) -- one instance per pair
pub fn evalSeriesForm(
    self: *Evaluator,
    form_children: []const Node,
    env: *Env,
    instances: *std.ArrayListUnmanaged(Instance),
    all_pin_nets: *std.ArrayListUnmanaged(PinNetDecl),
    note_list: *std.ArrayListUnmanaged(Note),
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
        if (form_children.len < SERIES_NAMED_REF_MIN_ARITY) return;
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
        ids.registerRefDes(self, s_ref);
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
    instances: *std.ArrayListUnmanaged(Instance),
    all_pin_nets: *std.ArrayListUnmanaged(PinNetDecl),
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
    var instances: std.ArrayListUnmanaged(Instance) = .empty;
    var all_pin_nets: std.ArrayListUnmanaged(PinNetDecl) = .empty;
    var notes: std.ArrayListUnmanaged(Note) = .empty;

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
    var instances: std.ArrayListUnmanaged(Instance) = .empty;
    var all_pin_nets: std.ArrayListUnmanaged(PinNetDecl) = .empty;

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
    try testing.expectEqualStrings("U1", res.instance.decouple_ic);
    try testing.expectEqualStrings("24", res.instance.decouple_pin);
    try testing.expect(!res.instance.decouple_rail);
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
    try testing.expect(res.instance.decouple_rail);
    try testing.expectEqualStrings("", res.instance.decouple_pin);
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
