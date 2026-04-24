const std = @import("std");

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
    /// A board definition (design + physical parameters)
    board: *Board,
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

pub const ModuleDef = struct {
    name: []const u8,
    params: []const []const u8,
    body: []const @import("../sexpr/ast.zig").Node,
    /// Import scope from the module file
    imports: *Env,
};

/// A pin reference in a net.
pub const PinRef = struct {
    ref_des: []const u8,
    pin: []const u8,
    /// Alternate function the user explicitly asserted via `(as "FN")`. Empty when not asserted.
    asserted_fn: []const u8 = "",
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
};

/// A note annotation.
pub const Note = struct {
    ref_des: []const u8,
    text: []const u8,
};

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

pub const Property = struct {
    key: []const u8,
    value: []const u8,
};

pub const Instance = struct {
    ref_des: []const u8,
    /// Descriptive label from source (e.g., "stm32", "flash"). Empty for auto-named passives.
    label: []const u8 = "",
    component: []const u8,
    value: []const u8,
    footprint: []const u8,
    symbol: []const u8,
    /// Pinout lookup key for lib/pinouts/*.sexp (falls back to symbol/component when unset).
    pinout: []const u8 = "",
    /// Component properties (manufacturer, mpn, etc.)
    properties: []const Property = &.{},
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
};

/// A sub-block reference.
pub const SubBlock = struct {
    name: []const u8,
    block: *DesignBlock,
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
    /// Whether this port is optional (no ERC error if unconnected).
    optional: bool = false,
};

/// A named calculation block with computed values.
pub const CalcBlock = struct {
    name: []const u8,
    /// Computed results as key-value pairs for display.
    results: []const CalcResult = &.{},
};

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
    /// Design notes shown at the bottom of the section.
    notes: []const []const u8 = &.{},
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
};

/// Block diagram placement role for sections.
pub const BlockRole = enum { auto, input, output };

/// A net-tie pair: merge net `b` into net `a`.
pub const NetTie = struct { a: []const u8, b: []const u8 };

/// The result of evaluating a design-block form.
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
};

/// A board definition: a design-block plus physical PCB parameters.
pub const Board = struct {
    name: []const u8,
    design: *DesignBlock,
    /// Board outline as a list of (x, y) points in mm. Rectangle shorthand
    /// produces 4 corner points.
    outline: []const [2]f64 = &.{},
    /// Board thickness in mm (default 1.6).
    thickness: f64 = 1.6,
    /// Copper layers (default 2).
    copper_layers: u8 = 2,
    /// Design rules.
    rules: BoardRules = .{},
    /// Layer stackup definition.
    stackup: []const StackupLayer = &.{},
    /// Net class overrides.
    net_classes: []const NetClass = &.{},
    /// Differential pair definitions.
    diff_pairs: []const DiffPair = &.{},
    /// Zone (copper pour) definitions.
    zones: []const ZoneDef = &.{},
    /// Keepout areas.
    keepouts: []const Keepout = &.{},
};

/// PCB design rules.
pub const BoardRules = struct {
    clearance: f64 = 0.15,
    track_width: f64 = 0.2,
    via_drill: f64 = 0.3,
    via_size: f64 = 0.6,
};

pub const StackupKind = enum { copper, prepreg, core };

/// A layer in the board stackup.
pub const StackupLayer = struct {
    kind: StackupKind,
    name: []const u8 = "",
    thickness: f64,
    er: f64 = 4.5,
};

/// Net class with per-class rule overrides.
pub const NetClass = struct {
    name: []const u8,
    track_width: ?f64 = null,
    clearance: ?f64 = null,
    via_drill: ?f64 = null,
    via_size: ?f64 = null,
    nets: []const []const u8 = &.{},
};

/// Differential pair definition.
pub const DiffPair = struct {
    name: []const u8,
    positive: []const u8,
    negative: []const u8,
    impedance: f64 = 90,
    spacing: f64 = 0.15,
};

/// Zone (copper pour) definition — design intent only.
pub const ZoneDef = struct {
    name: []const u8,
    layer: []const u8,
    thermal_gap: f64 = 0.3,
    thermal_width: f64 = 0.25,
};

/// Keepout area.
pub const Keepout = struct {
    name: []const u8,
    outline: []const [2]f64,
    no_tracks: bool = false,
    no_vias: bool = false,
    no_pours: bool = false,
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
