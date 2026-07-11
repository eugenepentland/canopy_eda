//! Version diff: compare two evaluated revisions of a design.
//!
//! The server snapshots a design's `.sexp` into
//! `<project>/history/<name>/<timestamp>/<name>.sexp` before every mutation
//! (source save, MCP build, restore). `GET /api/diff/:name?from=<id>&to=<id|current>`
//! evaluates both revisions request-locally (nothing live is touched) and
//! diffs the resulting DesignBlocks: instances added/removed, value and
//! footprint changes, and per-net pin membership changes. `GET
//! /api/history/:name` lists the stored snapshot ids for the picker UI.

const std = @import("std");
const httpz = @import("httpz");
const json_writer = @import("../json_writer.zig");
const infra_fs = @import("../infra/fs.zig");
const paths = @import("../paths.zig");
const history = @import("history.zig");
const env_mod = @import("../eval/env.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;

/// Error set for the HTTP handlers in this module.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error || error{InvalidName};

/// Errors out of the pure diff (allocation only — evaluation happens before).
pub const DiffError = std.mem.Allocator.Error || error{InvalidName};

/// One instance in an added/removed list.
pub const InstanceEntry = struct {
    ref: []const u8,
    component: []const u8,
    value: []const u8,
};

/// One per-ref field change (component value or footprint).
pub const FieldChange = struct {
    ref: []const u8,
    old: []const u8,
    new: []const u8,
};

/// Pin-membership change on one net. Pins are `"REF.PIN"` strings.
pub const NetChange = struct {
    net: []const u8,
    pins_added: []const []const u8,
    pins_removed: []const []const u8,
};

/// The full structured diff between two design revisions.
pub const DesignDiff = struct {
    instances_added: []const InstanceEntry,
    instances_removed: []const InstanceEntry,
    value_changes: []const FieldChange,
    footprint_changes: []const FieldChange,
    net_changes: []const NetChange,
};

// ── Flattening ───────────────────────────────────────────────────────────

const FlatInst = struct {
    ref: []const u8,
    component: []const u8,
    value: []const u8,
    footprint: []const u8,
};

const FlatNet = struct {
    name: []const u8,
    /// "REF.PIN" strings, sorted.
    pins: [][]const u8,
};

/// Walk a design block plus every nested sub-block, prefixing refs and net
/// names with the sub-block path (`pwr/U1`) so identity is stable regardless
/// of how the evaluator renumbered either revision.
fn flatten(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    prefix: []const u8,
    insts: *std.StringHashMapUnmanaged(FlatInst),
    nets: *std.StringHashMapUnmanaged(std.ArrayList([]const u8)),
) DiffError!void {
    for (block.instances) |inst| {
        const ref = try prefixed(allocator, prefix, inst.ref_des);
        try insts.put(allocator, ref, .{
            .ref = ref,
            .component = inst.component,
            .value = inst.value,
            .footprint = inst.footprint,
        });
    }
    for (block.nets) |net| {
        const net_name = try prefixed(allocator, prefix, net.name);
        const gop = try nets.getOrPut(allocator, net_name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (net.pins) |pin| {
            const ref = try prefixed(allocator, prefix, pin.ref_des);
            const entry = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ ref, pin.pin });
            try gop.value_ptr.append(allocator, entry);
        }
    }
    for (block.sub_blocks) |sb| {
        const child_prefix = try prefixed(allocator, prefix, sb.name);
        try flatten(allocator, sb.block, child_prefix, insts, nets);
    }
}

fn prefixed(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) DiffError![]const u8 {
    if (prefix.len == 0) return name;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ── Diff ─────────────────────────────────────────────────────────────────

/// Diff two evaluated design blocks. Instances are keyed by their flattened
/// ref path; nets by their flattened name. All output slices are allocated
/// from `allocator` (or borrow from the blocks, which the caller keeps alive).
pub fn diffBlocks(
    allocator: std.mem.Allocator,
    old_block: *const env_mod.DesignBlock,
    new_block: *const env_mod.DesignBlock,
) DiffError!DesignDiff {
    var old_insts: std.StringHashMapUnmanaged(FlatInst) = .empty;
    var old_nets: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    try flatten(allocator, old_block, "", &old_insts, &old_nets);
    var new_insts: std.StringHashMapUnmanaged(FlatInst) = .empty;
    var new_nets: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    try flatten(allocator, new_block, "", &new_insts, &new_nets);

    var added: std.ArrayList(InstanceEntry) = .empty;
    var removed: std.ArrayList(InstanceEntry) = .empty;
    var value_changes: std.ArrayList(FieldChange) = .empty;
    var fp_changes: std.ArrayList(FieldChange) = .empty;

    var new_it = new_insts.iterator();
    while (new_it.next()) |kv| {
        const ni = kv.value_ptr.*;
        const oi = old_insts.get(kv.key_ptr.*) orelse {
            try added.append(allocator, .{ .ref = ni.ref, .component = ni.component, .value = ni.value });
            continue;
        };
        if (!std.mem.eql(u8, oi.value, ni.value)) {
            try value_changes.append(allocator, .{ .ref = ni.ref, .old = oi.value, .new = ni.value });
        }
        if (!std.mem.eql(u8, oi.footprint, ni.footprint)) {
            try fp_changes.append(allocator, .{ .ref = ni.ref, .old = oi.footprint, .new = ni.footprint });
        }
    }
    var old_it = old_insts.iterator();
    while (old_it.next()) |kv| {
        if (new_insts.contains(kv.key_ptr.*)) continue;
        const oi = kv.value_ptr.*;
        try removed.append(allocator, .{ .ref = oi.ref, .component = oi.component, .value = oi.value });
    }

    var net_changes: std.ArrayList(NetChange) = .empty;
    var nn_it = new_nets.iterator();
    while (nn_it.next()) |kv| {
        const old_pins: []const []const u8 = if (old_nets.getPtr(kv.key_ptr.*)) |p| p.items else &.{};
        try appendNetChange(allocator, &net_changes, kv.key_ptr.*, old_pins, kv.value_ptr.items);
    }
    var on_it = old_nets.iterator();
    while (on_it.next()) |kv| {
        if (new_nets.contains(kv.key_ptr.*)) continue;
        try appendNetChange(allocator, &net_changes, kv.key_ptr.*, kv.value_ptr.items, &.{});
    }

    // Deterministic ordering for the UI and for tests.
    std.mem.sort(InstanceEntry, added.items, {}, lessByRef(InstanceEntry));
    std.mem.sort(InstanceEntry, removed.items, {}, lessByRef(InstanceEntry));
    std.mem.sort(FieldChange, value_changes.items, {}, lessByRef(FieldChange));
    std.mem.sort(FieldChange, fp_changes.items, {}, lessByRef(FieldChange));
    std.mem.sort(NetChange, net_changes.items, {}, struct {
        fn lt(_: void, a: NetChange, b: NetChange) bool {
            return std.mem.lessThan(u8, a.net, b.net);
        }
    }.lt);

    return .{
        .instances_added = try added.toOwnedSlice(allocator),
        .instances_removed = try removed.toOwnedSlice(allocator),
        .value_changes = try value_changes.toOwnedSlice(allocator),
        .footprint_changes = try fp_changes.toOwnedSlice(allocator),
        .net_changes = try net_changes.toOwnedSlice(allocator),
    };
}

fn lessByRef(comptime T: type) fn (void, T, T) bool {
    return struct {
        fn lt(_: void, a: T, b: T) bool {
            return std.mem.lessThan(u8, a.ref, b.ref);
        }
    }.lt;
}

/// Compute pins_added/pins_removed for one net and append a NetChange when
/// either is non-empty. Membership is set-based ("REF.PIN" strings).
fn appendNetChange(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(NetChange),
    net: []const u8,
    old_pins: []const []const u8,
    new_pins: []const []const u8,
) DiffError!void {
    var old_set: std.StringHashMapUnmanaged(void) = .empty;
    for (old_pins) |p| try old_set.put(allocator, p, {});
    var new_set: std.StringHashMapUnmanaged(void) = .empty;
    for (new_pins) |p| try new_set.put(allocator, p, {});

    var pins_added: std.ArrayList([]const u8) = .empty;
    for (new_pins) |p| {
        if (!old_set.contains(p)) try pins_added.append(allocator, p);
    }
    var pins_removed: std.ArrayList([]const u8) = .empty;
    for (old_pins) |p| {
        if (!new_set.contains(p)) try pins_removed.append(allocator, p);
    }
    if (pins_added.items.len == 0 and pins_removed.items.len == 0) return;
    std.mem.sort([]const u8, pins_added.items, {}, lessStr);
    std.mem.sort([]const u8, pins_removed.items, {}, lessStr);
    try out.append(allocator, .{
        .net = net,
        .pins_added = try pins_added.toOwnedSlice(allocator),
        .pins_removed = try pins_removed.toOwnedSlice(allocator),
    });
}

/// Serialize a DesignDiff as the API's JSON object.
pub fn writeDiffJson(w: anytype, diff: DesignDiff) std.mem.Allocator.Error!void {
    try w.writeAll("{\"instances_added\":[");
    for (diff.instances_added, 0..) |e, i| {
        if (i > 0) try w.writeAll(",");
        try writeInstanceEntry(w, e);
    }
    try w.writeAll("],\"instances_removed\":[");
    for (diff.instances_removed, 0..) |e, i| {
        if (i > 0) try w.writeAll(",");
        try writeInstanceEntry(w, e);
    }
    try w.writeAll("],\"value_changes\":[");
    for (diff.value_changes, 0..) |c, i| {
        if (i > 0) try w.writeAll(",");
        try writeFieldChange(w, c);
    }
    try w.writeAll("],\"footprint_changes\":[");
    for (diff.footprint_changes, 0..) |c, i| {
        if (i > 0) try w.writeAll(",");
        try writeFieldChange(w, c);
    }
    try w.writeAll("],\"net_changes\":[");
    for (diff.net_changes, 0..) |n, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"net\":");
        try json_writer.writeString(w, n.net);
        try w.writeAll(",\"pins_added\":[");
        for (n.pins_added, 0..) |p, j| {
            if (j > 0) try w.writeAll(",");
            try json_writer.writeString(w, p);
        }
        try w.writeAll("],\"pins_removed\":[");
        for (n.pins_removed, 0..) |p, j| {
            if (j > 0) try w.writeAll(",");
            try json_writer.writeString(w, p);
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}");
}

fn writeInstanceEntry(w: anytype, e: InstanceEntry) std.mem.Allocator.Error!void {
    try w.writeAll("{\"ref\":");
    try json_writer.writeString(w, e.ref);
    try w.writeAll(",\"component\":");
    try json_writer.writeString(w, e.component);
    try w.writeAll(",\"value\":");
    try json_writer.writeString(w, e.value);
    try w.writeAll("}");
}

fn writeFieldChange(w: anytype, c: FieldChange) std.mem.Allocator.Error!void {
    try w.writeAll("{\"ref\":");
    try json_writer.writeString(w, c.ref);
    try w.writeAll(",\"old\":");
    try json_writer.writeString(w, c.old);
    try w.writeAll(",\"new\":");
    try json_writer.writeString(w, c.new);
    try w.writeAll("}");
}

// ── HTTP handlers ────────────────────────────────────────────────────────

/// GET /api/history/:name — list stored snapshot ids (newest first) as
/// `{"snapshots":[{"id":…,"description":…}]}` for the History panel.
pub fn historyApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    const name = req.param("name") orelse {
        res.status = 404;
        res.body = "{\"error\":\"missing name\"}";
        return;
    };
    const snaps = history.listSnapshots(ctx.allocator, ctx.project_dir, name) catch {
        res.status = 500;
        res.body = "{\"error\":\"failed to list history\"}";
        return;
    };
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(ctx.allocator);
    try w.writeAll("{\"snapshots\":[");
    for (snaps, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"id\":");
        try json_writer.writeString(w, s.id);
        try w.writeAll(",\"description\":");
        try json_writer.writeString(w, s.description orelse "");
        try w.writeAll("}");
    }
    try w.writeAll("]}");
    res.body = buf.items;
}

/// GET /api/diff/:name?from=<id>&to=<id|current> — evaluate both revisions
/// request-locally (live state untouched) and return the structured diff.
/// `to` defaults to `current` (the working file under src/).
pub fn diffApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    const name = req.param("name") orelse {
        res.status = 404;
        res.body = "{\"error\":\"missing name\"}";
        return;
    };
    const qs = req.query() catch {
        res.status = 400;
        res.body = "{\"error\":\"invalid query\"}";
        return;
    };
    const from_id = qs.get("from") orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing from=<snapshot id>\"}";
        return;
    };
    const to_id = qs.get("to") orelse "current";

    const from_path = (try revisionPath(ctx.allocator, ctx.project_dir, name, from_id)) orelse {
        res.status = 400;
        res.body = "{\"error\":\"invalid or unknown 'from' version\"}";
        return;
    };
    const to_path = (try revisionPath(ctx.allocator, ctx.project_dir, name, to_id)) orelse {
        res.status = 400;
        res.body = "{\"error\":\"invalid or unknown 'to' version\"}";
        return;
    };

    // Two independent evaluators: nothing shared, nothing cached into the
    // live server state. Blocks stay alive until the response is built
    // (page_allocator-backed, same lifecycle as every other handler eval).
    var old_eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer old_eval.deinit();
    const old_block = evalRevision(&old_eval, from_path) orelse {
        res.status = 400;
        res.body = "{\"error\":\"'from' version failed to evaluate\"}";
        return;
    };
    var new_eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer new_eval.deinit();
    const new_block = evalRevision(&new_eval, to_path) orelse {
        res.status = 400;
        res.body = "{\"error\":\"'to' version failed to evaluate\"}";
        return;
    };

    const diff = try diffBlocks(ctx.allocator, old_block, new_block);

    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(ctx.allocator);
    try w.writeAll("{\"name\":");
    try json_writer.writeString(w, name);
    try w.writeAll(",\"from\":");
    try json_writer.writeString(w, from_id);
    try w.writeAll(",\"to\":");
    try json_writer.writeString(w, to_id);
    try w.writeAll(",\"diff\":");
    try writeDiffJson(w, diff);
    try w.writeAll("}");
    res.body = buf.items;
}

/// Resolve a version id to a source path: `current` → the working file under
/// src/; otherwise a snapshot under `history/<name>/<id>/`. Null when the id
/// is malformed (path traversal) or the snapshot file doesn't exist.
fn revisionPath(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    id: []const u8,
) (std.mem.Allocator.Error || error{InvalidName})!?[]const u8 {
    if (std.mem.eql(u8, id, "current")) {
        return try paths.designSourcePath(allocator, project_dir, name);
    }
    if (id.len == 0) return null;
    for (id) |c| if (c == '/' or c == '\\' or c == 0) return null;
    if (std.mem.indexOf(u8, id, "..") != null) return null;
    if (std.mem.indexOfAny(u8, name, "/\\") != null or std.mem.indexOf(u8, name, "..") != null) return null;
    const path = try std.fmt.allocPrint(allocator, "{s}/history/{s}/{s}/{s}.sexp", .{ project_dir, name, id, name });
    infra_fs.cwd().access(path, .{}) catch {
        allocator.free(path);
        return null;
    };
    return path;
}

/// Evaluate one revision file into its design block, or null on any failure.
fn evalRevision(eval: *Evaluator, path: []const u8) ?*env_mod.DesignBlock {
    const result = eval.evalFile(path) catch return null;
    return switch (result) {
        .design_block => |b| b,
        else => null,
    };
}

// ── Tests ────────────────────────────────────────────────────────────────

const test_cap_family =
    \\(component-family "cap-0402"
    \\  (description "test cap")
    \\  (symbol generic-cap)
    \\  (footprint c-0402)
    \\  (parameter "value" capacitance))
;

fn evalTestSource(eval: *Evaluator, source: []const u8) !*env_mod.DesignBlock {
    const result = try eval.evalSource(source);
    return switch (result) {
        .design_block => |b| b,
        else => error.TestNotADesign,
    };
}

// spec: serve/design_diff - diffBlocks reports added/removed instances, value changes, and net pin changes between two revisions
test "diffBlocks on two inline revisions" {
    // Production lifecycle: evaluator file/AST memory is never freed, so use
    // page_allocator like the other evaluator tests.
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("lib/components");
    try tmp.dir.writeFile(.{ .sub_path = "lib/components/cap-0402.sexp", .data = test_cap_family });
    const project = try tmp.dir.realpathAlloc(alloc, ".");

    var old_eval = Evaluator.init(alloc, project);
    defer old_eval.deinit();
    const old_block = try evalTestSource(&old_eval,
        \\(design-block "Rev A"
        \\  (instance "C1" (cap-0402 "100nF")
        \\    (pin 1 "VDD")
        \\    (pin 2 "GND"))
        \\  (instance "C2" (cap-0402 "1uF")
        \\    (pin 1 "VDD")
        \\    (pin 2 "GND")))
    );

    var new_eval = Evaluator.init(alloc, project);
    defer new_eval.deinit();
    const new_block = try evalTestSource(&new_eval,
        \\(design-block "Rev B"
        \\  (instance "C1" (cap-0402 "220nF")
        \\    (pin 1 "VDD")
        \\    (pin 2 "GND"))
        \\  (instance "C3" (cap-0402 "10nF")
        \\    (pin 1 "VIN")
        \\    (pin 2 "GND")))
    );

    const diff = try diffBlocks(alloc, old_block, new_block);

    try std.testing.expectEqual(@as(usize, 1), diff.instances_added.len);
    try std.testing.expectEqualStrings("C3", diff.instances_added[0].ref);
    try std.testing.expectEqualStrings("cap-0402", diff.instances_added[0].component);
    try std.testing.expectEqualStrings("10nF", diff.instances_added[0].value);

    try std.testing.expectEqual(@as(usize, 1), diff.instances_removed.len);
    try std.testing.expectEqualStrings("C2", diff.instances_removed[0].ref);

    try std.testing.expectEqual(@as(usize, 1), diff.value_changes.len);
    try std.testing.expectEqualStrings("C1", diff.value_changes[0].ref);
    try std.testing.expectEqualStrings("100nF", diff.value_changes[0].old);
    try std.testing.expectEqualStrings("220nF", diff.value_changes[0].new);

    try std.testing.expectEqual(@as(usize, 0), diff.footprint_changes.len);

    // VDD lost C2.1; GND swapped C2.2 for C3.2; VIN gained C3.1.
    try std.testing.expectEqual(@as(usize, 3), diff.net_changes.len);
    try std.testing.expectEqualStrings("GND", diff.net_changes[0].net);
    try std.testing.expectEqual(@as(usize, 1), diff.net_changes[0].pins_added.len);
    try std.testing.expectEqualStrings("C3.2", diff.net_changes[0].pins_added[0]);
    try std.testing.expectEqualStrings("C2.2", diff.net_changes[0].pins_removed[0]);
    try std.testing.expectEqualStrings("VDD", diff.net_changes[1].net);
    try std.testing.expectEqual(@as(usize, 0), diff.net_changes[1].pins_added.len);
    try std.testing.expectEqualStrings("C2.1", diff.net_changes[1].pins_removed[0]);
    try std.testing.expectEqualStrings("VIN", diff.net_changes[2].net);
    try std.testing.expectEqualStrings("C3.1", diff.net_changes[2].pins_added[0]);
}

// spec: serve/design_diff - identical revisions produce an empty diff
test "diffBlocks identical revisions is empty" {
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("lib/components");
    try tmp.dir.writeFile(.{ .sub_path = "lib/components/cap-0402.sexp", .data = test_cap_family });
    const project = try tmp.dir.realpathAlloc(alloc, ".");

    const source =
        \\(design-block "Rev"
        \\  (instance "C1" (cap-0402 "100nF")
        \\    (pin 1 "VDD")
        \\    (pin 2 "GND")))
    ;
    var a_eval = Evaluator.init(alloc, project);
    defer a_eval.deinit();
    const a = try evalTestSource(&a_eval, source);
    var b_eval = Evaluator.init(alloc, project);
    defer b_eval.deinit();
    const b = try evalTestSource(&b_eval, source);

    const diff = try diffBlocks(alloc, a, b);
    try std.testing.expectEqual(@as(usize, 0), diff.instances_added.len);
    try std.testing.expectEqual(@as(usize, 0), diff.instances_removed.len);
    try std.testing.expectEqual(@as(usize, 0), diff.value_changes.len);
    try std.testing.expectEqual(@as(usize, 0), diff.footprint_changes.len);
    try std.testing.expectEqual(@as(usize, 0), diff.net_changes.len);
}
