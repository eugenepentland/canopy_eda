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
};

pub const Property = struct {
    key: []const u8,
    value: []const u8,
};

pub const Instance = struct {
    ref_des: []const u8,
    component: []const u8,
    value: []const u8,
    footprint: []const u8,
    symbol: []const u8,
    /// Component properties (manufacturer, mpn, etc.)
    properties: []const Property = &.{},
    /// Schematic-level attributes (e.g., "np0", "x7r" for dielectric type)
    attrs: []const []const u8 = &.{},
    /// Optional multi-part breakdown. Empty = single-part (render as one hub).
    parts: []const Part = &.{},
    /// Byte offset of the component family name in the source file.
    source_offset: u32 = 0,
    /// Stable UUID for PCB identity tracking (assigned by identity module, not from source).
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
    /// Named calculation blocks.
    calcs: []const CalcBlock = &.{},
};

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
};

/// Assertion result.
pub const AssertionResult = struct {
    passed: bool,
    message: []const u8,
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

test "env get and put" {
    const alloc = std.testing.allocator;
    var env = Env.init(alloc, null);
    defer env.deinit();

    try env.put("x", .{ .number = 42.0 });
    const v = env.get("x").?;
    try std.testing.expectEqual(@as(f64, 42.0), v.asNumber().?);
    try std.testing.expect(env.get("y") == null);
}

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
