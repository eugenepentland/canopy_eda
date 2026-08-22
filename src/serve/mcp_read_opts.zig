//! Read-request options for the no-view-mode CLI PCB read tools
//! (`describe_pcb_layout`, `get_layout_progress`, `routability_preflight`, and
//! the shared `rough` default of `get_pcb_layout_image`), plus the guards that
//! keep the advertised `tools/list` schema honest about them. Split out of
//! `mcp_tools.zig` so the default `rough=false` semantics carry a focused test
//! without growing that file's size ratchet (the `mcp_flatten.zig` precedent).
//!
//! Every one of those input schemas is `additionalProperties:false`, so the two
//! sides have to agree in both directions: an argument a handler reads but its
//! schema omits is REFUSED by a validating client before it ever reaches the
//! code, and an argument a schema declares but no handler reads is a knob that
//! silently does nothing. The tests at the bottom hold both lines.

const std = @import("std");
const pcb_layout_page = @import("pcb_layout_page.zig");

fn optBool(args_val: ?std.json.Value, key: []const u8) ?bool {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return if (v == .bool) v.bool else null;
}

fn optString(args_val: ?std.json.Value, key: []const u8) ?[]const u8 {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// The request keys `describePcbOpts` reads.
const describe_keys = [_][]const u8{ "route", "layout", "regen", "rough", "sub", "pads" };

/// The request keys `placementSelectOpts` reads — which board to answer about,
/// and nothing else.
const select_keys = [_][]const u8{ "layout", "regen", "rough", "sub" };

/// Build the PngRequest for a `describe_pcb_layout` read. `rough` defaults OFF
/// so a no-arg read takes `solveForRequest`'s `want_default` path — the
/// design's starred (★) layout rendered VERBATIM (placeFromPoses), the same
/// precedence the /pcb-layout viewer and the HTTP png/describe endpoints use
/// (starred > cache > fresh). A `rough=true` default would instead seed a
/// *re-solve* from the auto cache, which `applyCached` rejects on any courtyard
/// overlap (normal right after a mutation) and drifts to the force-solver pose,
/// so a read-after-write stopped reflecting the mutation. An agent can still
/// ask for the rough seed explicitly with `rough:true`.
pub fn describePcbOpts(args_val: ?std.json.Value) pcb_layout_page.PngRequest {
    return .{
        .route = optBool(args_val, "route") orelse false,
        .layout = optString(args_val, "layout"),
        .regen = optBool(args_val, "regen") orelse false,
        .rough = optBool(args_val, "rough") orelse false,
        .sub = optString(args_val, "sub"),
        .pads = optBool(args_val, "pads") orelse false,
    };
}

/// Build the PngRequest for a PCB read that only ever SELECTS a board — it
/// never routes and emits no pad table (`get_layout_progress`,
/// `routability_preflight`). Same defaults as `describePcbOpts`, but reading
/// four keys instead of six, because the other two cannot change either answer:
/// `route` only suppresses `SolvedRequest.restored_routes` (the progress ladder
/// loads the shown layout's copper itself through `shownLayoutCopper`, and the
/// preflight runs no router at all — it reports `routed:false`), and `pads`
/// only feeds the describe facts' obstacle table. Reading them would oblige
/// both schemas to advertise knobs that do nothing; not reading them lets
/// `additionalProperties:false` refuse them, which is the honest answer.
///
/// `regen` / `rough` DO change the answer and so are declared on both tools:
/// each forces a fresh solve, and — through `shownSavedLayout` — drops the
/// persisted copper, so a rough-seeded progress read scores the seed's
/// placement rather than the blessed board's routing.
pub fn placementSelectOpts(args_val: ?std.json.Value) pcb_layout_page.PngRequest {
    return .{
        .layout = optString(args_val, "layout"),
        .regen = optBool(args_val, "regen") orelse false,
        .rough = optBool(args_val, "rough") orelse false,
        .sub = optString(args_val, "sub"),
    };
}

/// One CLI tool paired with the request keys the options builder its handler
/// calls reads out of the arguments object.
const SchemaReader = struct { tool: []const u8, keys: []const []const u8 };

/// Every tool whose handler builds its read options in this file. ADDING A
/// CALLER of either builder above MEANS ADDING ITS ROW HERE — the guard below
/// can only check the tools it is told about, and an unlisted caller reverts to
/// exactly the failure this file exists to prevent (a strict client refusing a
/// documented argument, or a schema advertising a dead one).
const schema_readers = [_]SchemaReader{
    .{ .tool = "describe_pcb_layout", .keys = &describe_keys },
    .{ .tool = "get_layout_progress", .keys = &select_keys },
    .{ .tool = "routability_preflight", .keys = &select_keys },
};

// spec: Web Server - A no-arg CLI PCB read defaults rough off to render the starred layout verbatim, not a re-solve
test "no-arg CLI PCB read defaults rough off (starred-verbatim path)" {
    // A no-arg describe/image read must leave rough OFF and everything else in
    // the default-read state: solveForRequest's want_default (the starred ★
    // layout rendered verbatim) is gated on `!rough` plus no layout/regen/
    // remaining/sub, so a rough=true default would re-solve from the auto cache
    // and drift a just-mutated pose to the force-solver's pick.
    const def = describePcbOpts(null);
    try std.testing.expect(!def.rough);
    try std.testing.expect(def.layout == null);
    try std.testing.expect(!def.regen);
    try std.testing.expect(!def.remaining);
    try std.testing.expect(def.sub == null);
    // An explicit rough:true is still honored — an agent can ask for the seed.
    const src = "{\"rough\":true}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, src, .{});
    defer parsed.deinit();
    try std.testing.expect(describePcbOpts(parsed.value).rough);
}

// spec: Web Server - A placement-selection PCB read honours the seed flags and ignores the route and pad-table flags
test "placementSelectOpts reads the seed flags and leaves route/pads off" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const def = placementSelectOpts(null);
    try std.testing.expect(!def.rough);
    try std.testing.expect(!def.regen);
    try std.testing.expect(def.layout == null);
    try std.testing.expect(def.sub == null);

    // The board-selecting flags are honoured: `rough:true` is what makes
    // get_layout_progress / routability_preflight answer about the ROUGH seed.
    const src = "{\"rough\":true,\"regen\":true,\"layout\":\"auto-91c\",\"sub\":\"pwr\",\"route\":true,\"pads\":true}";
    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena, src, .{});
    const got = placementSelectOpts(args);
    try std.testing.expect(got.rough);
    try std.testing.expect(got.regen);
    try std.testing.expectEqualStrings("auto-91c", got.layout.?);
    try std.testing.expectEqualStrings("pwr", got.sub.?);
    // …and route/pads are deliberately NOT read here: neither handler reads the
    // fields they set, so both schemas refuse them rather than advertise a
    // knob that cannot move the answer.
    try std.testing.expect(!got.route);
    try std.testing.expect(!got.pads);
}

// ── Advertised-schema guards ──────────────────────────────────────────
//
// These parse the same `tools_list_result.json` the server returns for
// `tools/list`, so they judge exactly what a client validates against.

/// (test helper) The `inputSchema` object advertised for `tool`.
fn schemaFor(arena: std.mem.Allocator, tool: []const u8) !std.json.ObjectMap {
    const mcp_tools = @import("mcp_tools.zig");
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, mcp_tools.tools_list_result, .{});
    for (root.object.get("tools").?.array.items) |t| {
        if (std.mem.eql(u8, t.object.get("name").?.string, tool))
            return t.object.get("inputSchema").?.object;
    }
    return error.ToolNotAdvertised;
}

/// (test helper) `"<tool>.<key>"` naming the first option a handler here reads
/// that its tool's strict schema does not declare, else `""`. Walked in a
/// helper so the test body keeps one assertion and no branching.
fn firstUndeclaredOption(arena: std.mem.Allocator) ![]const u8 {
    for (schema_readers) |r| {
        const schema = try schemaFor(arena, r.tool);
        // A schema that stopped being closed no longer refuses anything, so the
        // premise of this guard is gone — say so rather than pass on a
        // technicality.
        const ap = schema.get("additionalProperties") orelse std.json.Value{ .bool = true };
        if (ap != .bool or ap.bool)
            return std.fmt.allocPrint(arena, "{s} (not additionalProperties:false)", .{r.tool});
        const props = schema.get("properties").?.object;
        for (r.keys) |key| {
            if (props.get(key) == null)
                return std.fmt.allocPrint(arena, "{s}.{s}", .{ r.tool, key });
        }
    }
    return "";
}

// spec: Web Server - every option a PCB read handler honours is declared in that tool's strict input schema
test "every PCB read tool's schema declares the options its handler reads" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Each schema is `additionalProperties:false`, so an argument the handler
    // reads but the schema omits is REFUSED by a strict client before it ever
    // reaches this code — which is what happened to `pads` on
    // describe_pcb_layout (the obstacle-set flag a close_open_nets remedy
    // string tells agents to pass) and to `rough`/`regen` on the two
    // placement-selection tools.
    try std.testing.expectEqualStrings("", try firstUndeclaredOption(arena));

    // And a flag really does reach the request: declared but unread would be
    // the same lie in the other direction.
    const args = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"pads\":true}", .{});
    try std.testing.expect(describePcbOpts(args).pads);
    try std.testing.expect(!describePcbOpts(null).pads);
}

/// (test helper) True when a JSON Schema `type` value admits a bare string —
/// either `"string"` or a union like `["array","string"]`.
fn typeAdmitsString(v: std.json.Value) bool {
    return switch (v) {
        .string => |s| std.mem.eql(u8, s, "string"),
        .array => |a| blk: {
            for (a.items) |t| {
                if (t == .string and std.mem.eql(u8, t.string, "string")) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

/// (test helper) `"<tool>.<property>"` naming the first advertised property
/// whose description promises a comma-separated string while its declared
/// `type` admits only an array, else `""`.
fn firstCommaTypeMismatch(arena: std.mem.Allocator) ![]const u8 {
    const mcp_tools = @import("mcp_tools.zig");
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, mcp_tools.tools_list_result, .{});
    for (root.object.get("tools").?.array.items) |t| {
        const schema = t.object.get("inputSchema") orelse continue;
        const props = (schema.object.get("properties") orelse continue).object;
        var it = props.iterator();
        while (it.next()) |e| {
            const p = e.value_ptr.*;
            const desc = if (p.object.get("description")) |d| d.string else "";
            if (std.ascii.findIgnoreCase(desc, "comma") == null) continue;
            const ty = p.object.get("type") orelse return error.PropertyHasNoType;
            if (!typeAdmitsString(ty))
                return std.fmt.allocPrint(arena, "{s}.{s}", .{ t.object.get("name").?.string, e.key_ptr.* });
        }
    }
    return "";
}

// spec: Web Server - a tool property that documents a comma-separated string declares string among its schema types
test "a comma-separated-string property declares string in its type" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `jsonStrList` / `mcpArgStrList` take an array OR a comma-separated
    // string, and these properties' own descriptions say so — but a
    // `"type":"array"` declaration contradicts that sentence, and a validating
    // client enforces the declaration, not the prose. Generic on purpose: the
    // next property documented that way cannot drift either.
    try std.testing.expectEqualStrings("", try firstCommaTypeMismatch(arena));
}
