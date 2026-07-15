//! Read-request options for the no-view-mode MCP PCB read tools
//! (`describe_pcb_layout`, and the shared `rough` default of
//! `get_pcb_layout_image`). Split out of `mcp_tools.zig` so the default
//! `rough=false` semantics carry a focused test without growing that file's
//! size ratchet (the `mcp_flatten.zig` precedent).

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
    };
}

// spec: Web Server - A no-arg MCP PCB read defaults rough off to render the starred layout verbatim, not a re-solve
test "no-arg MCP PCB read defaults rough off (starred-verbatim path)" {
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
