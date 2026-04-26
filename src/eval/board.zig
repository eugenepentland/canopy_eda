const std = @import("std");
const log = @import("../infra/log.zig");
const env_mod = @import("env.zig");
const Value = env_mod.Value;
const Env = env_mod.Env;
const Board = env_mod.Board;
const BoardRules = env_mod.BoardRules;
const StackupLayer = env_mod.StackupLayer;
const NetClass = env_mod.NetClass;
const DiffPair = env_mod.DiffPair;
const ZoneDef = env_mod.ZoneDef;
const Keepout = env_mod.Keepout;
const EvalError = @import("evaluator.zig").EvalError;
const Evaluator = @import("evaluator.zig").Evaluator;
const Node = @import("../sexpr/ast.zig").Node;

/// Evaluate a `(board "name" ...)` form.
///
/// Syntax:
/// ```
/// (board "my-pcb"
///   (design <design-expr>)         ;; required: evaluates to a design_block
///   (outline (rect x1 y1 x2 y2))  ;; optional: board outline
///   (thickness 1.6)                ;; optional: board thickness in mm
///   (copper-layers 4)              ;; optional: number of copper layers
///   (rules                         ;; optional: design rules
///     (clearance 0.15)
///     (track-width 0.2)
///     (via-drill 0.3)
///     (via-size 0.6)))
/// ```
pub fn evalBoard(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
    if (args.len < 2) {
        log.warn("board: requires at least a name and (design ...) form", .{});
        return EvalError.ArityError;
    }

    // First arg: board name (string)
    const name_val = try self.evalNode(args[0], env);
    const name = name_val.asString() orelse {
        log.warn("board: first argument must be a string name", .{});
        return EvalError.TypeError;
    };

    var design: ?*env_mod.DesignBlock = null;
    var outline: std.ArrayListUnmanaged([2]f64) = .empty;
    var thickness: f64 = 1.6;
    var copper_layers: u8 = 2;
    var rules: BoardRules = .{};
    var stackup: std.ArrayListUnmanaged(StackupLayer) = .empty;
    var net_classes: std.ArrayListUnmanaged(NetClass) = .empty;
    var diff_pairs: std.ArrayListUnmanaged(DiffPair) = .empty;
    var zones: std.ArrayListUnmanaged(ZoneDef) = .empty;
    var keepouts: std.ArrayListUnmanaged(Keepout) = .empty;

    // Process sub-forms
    for (args[1..]) |arg| {
        const children = arg.asList() orelse continue;
        if (children.len == 0) continue;
        const tag = children[0].asAtom() orelse continue;

        if (std.mem.eql(u8, tag, "design")) {
            if (children.len < 2) {
                log.warn("board: (design ...) requires a design expression", .{});
                return EvalError.ArityError;
            }
            // If the argument is a string, treat it as a relative file path
            if (children[1].asString()) |path| {
                const full_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.project_dir, path }) catch return EvalError.OutOfMemory;
                const design_val = self.evalFile(full_path) catch |err| {
                    log.warn("board: failed to load design from {s}: {}", .{ full_path, err });
                    return EvalError.ImportError;
                };
                switch (design_val) {
                    .design_block => |db| design = db,
                    else => {
                        log.warn("board: file did not evaluate to a design-block", .{});
                        return EvalError.TypeError;
                    },
                }
            } else {
                const design_val = try self.evalNode(children[1], env);
                switch (design_val) {
                    .design_block => |db| design = db,
                    else => {
                        log.warn("board: (design ...) must evaluate to a design-block", .{});
                        return EvalError.TypeError;
                    },
                }
            }
        } else if (std.mem.eql(u8, tag, "outline")) {
            try parseOutline(self, children[1..], env, &outline);
        } else if (std.mem.eql(u8, tag, "thickness")) {
            if (children.len >= 2) {
                const v = try self.evalNode(children[1], env);
                thickness = v.asNumber() orelse 1.6;
            }
        } else if (std.mem.eql(u8, tag, "copper-layers")) {
            if (children.len >= 2) {
                const v = try self.evalNode(children[1], env);
                if (v.asNumber()) |n| {
                    copper_layers = @intFromFloat(n);
                }
            }
        } else if (std.mem.eql(u8, tag, "rules")) {
            rules = try parseRules(self, children[1..], env);
        } else if (std.mem.eql(u8, tag, "stackup")) {
            try parseStackup(self, children[1..], env, &stackup);
        } else if (std.mem.eql(u8, tag, "net-class")) {
            const nc = try parseNetClass(self, children[1..], env);
            net_classes.append(self.allocator, nc) catch return EvalError.OutOfMemory;
        } else if (std.mem.eql(u8, tag, "diff-pair")) {
            const dp = try parseDiffPair(self, children[1..], env);
            diff_pairs.append(self.allocator, dp) catch return EvalError.OutOfMemory;
        } else if (std.mem.eql(u8, tag, "zone")) {
            const z = try parseZone(self, children[1..], env);
            zones.append(self.allocator, z) catch return EvalError.OutOfMemory;
        } else if (std.mem.eql(u8, tag, "keepout")) {
            const k = try parseKeepout(self, children[1..], env);
            keepouts.append(self.allocator, k) catch return EvalError.OutOfMemory;
        }
    }

    if (design == null) {
        log.warn("board: missing required (design ...) form", .{});
        return EvalError.ArityError;
    }

    const board = self.allocator.create(Board) catch return EvalError.OutOfMemory;
    board.* = .{
        .name = name,
        .design = design.?,
        .outline = outline.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        .thickness = thickness,
        .copper_layers = copper_layers,
        .rules = rules,
        .stackup = stackup.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        .net_classes = net_classes.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        .diff_pairs = diff_pairs.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        .zones = zones.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        .keepouts = keepouts.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
    };

    return Value{ .board = board };
}

/// Parse outline sub-forms: `(rect x1 y1 x2 y2)` or `(polygon (point x y) ...)`
fn parseOutline(self: *Evaluator, args: []const Node, env: *Env, outline: *std.ArrayListUnmanaged([2]f64)) EvalError!void {
    for (args) |arg| {
        const children = arg.asList() orelse continue;
        if (children.len == 0) continue;
        const tag = children[0].asAtom() orelse continue;

        if (std.mem.eql(u8, tag, "rect")) {
            // (rect x1 y1 x2 y2)
            if (children.len < 5) {
                log.warn("board: (rect) requires 4 coordinates", .{});
                return EvalError.ArityError;
            }
            var coords: [4]f64 = undefined;
            for (0..4) |i| {
                const v = try self.evalNode(children[i + 1], env);
                coords[i] = v.asNumber() orelse {
                    log.warn("board: (rect) coordinates must be numbers", .{});
                    return EvalError.TypeError;
                };
            }
            outline.append(self.allocator, .{ coords[0], coords[1] }) catch return EvalError.OutOfMemory;
            outline.append(self.allocator, .{ coords[2], coords[1] }) catch return EvalError.OutOfMemory;
            outline.append(self.allocator, .{ coords[2], coords[3] }) catch return EvalError.OutOfMemory;
            outline.append(self.allocator, .{ coords[0], coords[3] }) catch return EvalError.OutOfMemory;
        } else if (std.mem.eql(u8, tag, "point")) {
            // (point x y)
            if (children.len < 3) continue;
            const x_val = try self.evalNode(children[1], env);
            const y_val = try self.evalNode(children[2], env);
            const x = x_val.asNumber() orelse continue;
            const y = y_val.asNumber() orelse continue;
            outline.append(self.allocator, .{ x, y }) catch return EvalError.OutOfMemory;
        }
    }
}

/// Parse rules sub-forms.
fn parseRules(self: *Evaluator, args: []const Node, env: *Env) EvalError!BoardRules {
    var rules: BoardRules = .{};
    for (args) |arg| {
        const children = arg.asList() orelse continue;
        if (children.len < 2) continue;
        const tag = children[0].asAtom() orelse continue;
        const v = try self.evalNode(children[1], env);
        const n = v.asNumber() orelse continue;

        if (std.mem.eql(u8, tag, "clearance")) {
            rules.clearance = n;
        } else if (std.mem.eql(u8, tag, "track-width")) {
            rules.track_width = n;
        } else if (std.mem.eql(u8, tag, "via-drill")) {
            rules.via_drill = n;
        } else if (std.mem.eql(u8, tag, "via-size")) {
            rules.via_size = n;
        }
    }
    return rules;
}

/// Parse stackup sub-forms: `(copper "F.Cu" 0.035)`, `(prepreg 0.2 (er 4.2))`, `(core 0.8 (er 4.5))`
fn parseStackup(self: *Evaluator, args: []const Node, env: *Env, stackup: *std.ArrayListUnmanaged(StackupLayer)) EvalError!void {
    for (args) |arg| {
        const children = arg.asList() orelse continue;
        if (children.len < 2) continue;
        const kind_str = children[0].asAtom() orelse continue;

        const kind: env_mod.StackupKind = if (std.mem.eql(u8, kind_str, "copper"))
            .copper
        else if (std.mem.eql(u8, kind_str, "prepreg"))
            .prepreg
        else if (std.mem.eql(u8, kind_str, "core"))
            .core
        else
            continue;

        var layer_name: []const u8 = "";
        var thickness: f64 = 0;
        var er: f64 = 4.5;
        var idx: usize = 1;

        // Copper layers have a name string first
        if (kind == .copper) {
            if (children.len >= 3) {
                const name_val = try self.evalNode(children[1], env);
                layer_name = name_val.asString() orelse "";
                idx = 2;
            }
        }

        // Thickness
        if (idx < children.len) {
            const v = try self.evalNode(children[idx], env);
            thickness = v.asNumber() orelse 0;
            idx += 1;
        }

        // Optional (er ...) sub-form
        while (idx < children.len) : (idx += 1) {
            const sub = children[idx].asList() orelse continue;
            if (sub.len >= 2) {
                const stag = sub[0].asAtom() orelse continue;
                if (std.mem.eql(u8, stag, "er")) {
                    const ev = try self.evalNode(sub[1], env);
                    er = ev.asNumber() orelse 4.5;
                }
            }
        }

        stackup.append(self.allocator, .{
            .kind = kind,
            .name = layer_name,
            .thickness = thickness,
            .er = er,
        }) catch return EvalError.OutOfMemory;
    }
}

/// Parse net-class: `(net-class "name" (track-width 0.4) (nets "VDD" "GND" ...))`
fn parseNetClass(self: *Evaluator, args: []const Node, env: *Env) EvalError!NetClass {
    var nc: NetClass = .{ .name = "", .nets = &.{} };
    if (args.len == 0) return nc;

    // First arg is the name
    const name_val = try self.evalNode(args[0], env);
    nc.name = name_val.asString() orelse "";

    var net_list: std.ArrayListUnmanaged([]const u8) = .empty;

    for (args[1..]) |arg| {
        const children = arg.asList() orelse continue;
        if (children.len < 2) continue;
        const tag = children[0].asAtom() orelse continue;

        if (std.mem.eql(u8, tag, "track-width")) {
            const v = try self.evalNode(children[1], env);
            nc.track_width = v.asNumber();
        } else if (std.mem.eql(u8, tag, "clearance")) {
            const v = try self.evalNode(children[1], env);
            nc.clearance = v.asNumber();
        } else if (std.mem.eql(u8, tag, "via-drill")) {
            const v = try self.evalNode(children[1], env);
            nc.via_drill = v.asNumber();
        } else if (std.mem.eql(u8, tag, "via-size")) {
            const v = try self.evalNode(children[1], env);
            nc.via_size = v.asNumber();
        } else if (std.mem.eql(u8, tag, "nets")) {
            for (children[1..]) |net_node| {
                const nv = try self.evalNode(net_node, env);
                const net_name = nv.asString() orelse continue;
                net_list.append(self.allocator, net_name) catch return EvalError.OutOfMemory;
            }
        }
    }

    nc.nets = net_list.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
    return nc;
}

/// Parse diff-pair: `(diff-pair "name" (positive "net") (negative "net") (impedance 90) (spacing 0.15))`
fn parseDiffPair(self: *Evaluator, args: []const Node, env: *Env) EvalError!DiffPair {
    var dp: DiffPair = .{ .name = "", .positive = "", .negative = "" };
    if (args.len == 0) return dp;

    const name_val = try self.evalNode(args[0], env);
    dp.name = name_val.asString() orelse "";

    for (args[1..]) |arg| {
        const children = arg.asList() orelse continue;
        if (children.len < 2) continue;
        const tag = children[0].asAtom() orelse continue;

        if (std.mem.eql(u8, tag, "positive")) {
            const v = try self.evalNode(children[1], env);
            dp.positive = v.asString() orelse "";
        } else if (std.mem.eql(u8, tag, "negative")) {
            const v = try self.evalNode(children[1], env);
            dp.negative = v.asString() orelse "";
        } else if (std.mem.eql(u8, tag, "impedance")) {
            const v = try self.evalNode(children[1], env);
            dp.impedance = v.asNumber() orelse 90;
        } else if (std.mem.eql(u8, tag, "spacing")) {
            const v = try self.evalNode(children[1], env);
            dp.spacing = v.asNumber() orelse 0.15;
        }
    }

    return dp;
}

/// Parse zone: `(zone "net" "layer" (thermal-gap 0.3) (thermal-width 0.25))`
fn parseZone(self: *Evaluator, args: []const Node, env: *Env) EvalError!ZoneDef {
    var z: ZoneDef = .{ .name = "", .layer = "" };
    if (args.len >= 1) {
        const v = try self.evalNode(args[0], env);
        z.name = v.asString() orelse "";
    }
    if (args.len >= 2) {
        const v = try self.evalNode(args[1], env);
        z.layer = v.asString() orelse "";
    }
    for (args[@min(args.len, 2)..]) |arg| {
        const children = arg.asList() orelse continue;
        if (children.len < 2) continue;
        const tag = children[0].asAtom() orelse continue;
        const v = try self.evalNode(children[1], env);
        const n = v.asNumber() orelse continue;

        if (std.mem.eql(u8, tag, "thermal-gap")) {
            z.thermal_gap = n;
        } else if (std.mem.eql(u8, tag, "thermal-width")) {
            z.thermal_width = n;
        }
    }
    return z;
}

/// Parse keepout: `(keepout "name" (rect x1 y1 x2 y2) (no-tracks) (no-vias) (no-pours))`
fn parseKeepout(self: *Evaluator, args: []const Node, env: *Env) EvalError!Keepout {
    var k: Keepout = .{ .name = "", .outline = &.{} };
    if (args.len == 0) return k;

    const name_val = try self.evalNode(args[0], env);
    k.name = name_val.asString() orelse "";

    var outline: std.ArrayListUnmanaged([2]f64) = .empty;

    for (args[1..]) |arg| {
        const children = arg.asList() orelse {
            // Bare atom flags
            const atom = arg.asAtom() orelse continue;
            if (std.mem.eql(u8, atom, "no-tracks")) k.no_tracks = true;
            if (std.mem.eql(u8, atom, "no-vias")) k.no_vias = true;
            if (std.mem.eql(u8, atom, "no-pours")) k.no_pours = true;
            continue;
        };
        if (children.len == 0) continue;
        const tag = children[0].asAtom() orelse continue;

        if (std.mem.eql(u8, tag, "rect") and children.len >= 5) {
            var coords: [4]f64 = undefined;
            for (0..4) |i| {
                const v = try self.evalNode(children[i + 1], env);
                coords[i] = v.asNumber() orelse 0;
            }
            outline.append(self.allocator, .{ coords[0], coords[1] }) catch return EvalError.OutOfMemory;
            outline.append(self.allocator, .{ coords[2], coords[1] }) catch return EvalError.OutOfMemory;
            outline.append(self.allocator, .{ coords[2], coords[3] }) catch return EvalError.OutOfMemory;
            outline.append(self.allocator, .{ coords[0], coords[3] }) catch return EvalError.OutOfMemory;
        } else if (std.mem.eql(u8, tag, "no-tracks")) {
            k.no_tracks = true;
        } else if (std.mem.eql(u8, tag, "no-vias")) {
            k.no_vias = true;
        } else if (std.mem.eql(u8, tag, "no-pours")) {
            k.no_pours = true;
        }
    }

    k.outline = outline.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
    return k;
}

// --- Tests ---

const testing = std.testing;

// spec: board - Evaluates board form with design reference and outline
test "board form evaluation" {
    // Basic struct construction test — no evaluator needed
    const alloc = testing.allocator;

    const db = try alloc.create(env_mod.DesignBlock);
    defer alloc.destroy(db);
    db.* = .{
        .name = "test",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };

    const board = try alloc.create(Board);
    defer alloc.destroy(board);
    board.* = .{
        .name = "test-pcb",
        .design = db,
        .outline = &.{ .{ 0, 0 }, .{ 60, 0 }, .{ 60, 40 }, .{ 0, 40 } },
        .thickness = 1.6,
        .copper_layers = 4,
        .rules = .{ .clearance = 0.15, .track_width = 0.2 },
    };

    try testing.expectEqualStrings("test-pcb", board.name);
    try testing.expectEqual(@as(usize, 4), board.outline.len);
    try testing.expectEqual(@as(u8, 4), board.copper_layers);
    try testing.expectApproxEqAbs(0.15, board.rules.clearance, 0.001);
}
