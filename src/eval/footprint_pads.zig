//! The set of pad ids a `lib/footprints/<name>.sexp` defines.
//!
//! `lib/pinouts/` gives a part's pad → function map, but only the parts that
//! have a pinout file — every passive, connector and mechanical part is
//! described by its footprint alone. The pad-existence check in
//! `instance.zig` needs both, so this loader reads the *ids* out of a
//! footprint's `(pad ID …)` forms and nothing else: no geometry, no
//! courtyard, no polygons.
//!
//! Ids go through `ids.pinId`, the same normalizer `(pin …)` tokens and
//! `lib/pinouts` entries use, so `(pad 01 …)` and `(pin 01 …)` agree on the
//! spelling `1`.
//!
//! Results are cached on the evaluator by footprint name: one read per
//! distinct footprint per build, however many instances place it. A missing
//! or unparseable file caches an EMPTY set, which every caller must read as
//! "this footprint's pads are unknown" — never as "this footprint has no
//! pads".

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const ids = @import("ids.zig");
const infra_fs = @import("../infra/fs.zig");
const lib_limits = @import("../lib_limits.zig");
const parser_mod = @import("../sexpr/parser.zig");
const Evaluator = @import("evaluator.zig").Evaluator;

/// Pad ids of one footprint, as a set. Empty means "unknown" (see the module
/// header), which is why callers test `count() > 0` before trusting a miss.
pub const PadIds = std.StringHashMapUnmanaged(void);

const path_fmt = "{s}/lib/footprints/{s}.sexp";

/// The pad ids of `fp_name`, loading and caching the footprint on first ask.
/// Null when the name is empty; an empty set when the file is missing or is
/// not a `(footprint …)` form.
pub fn get(self: *Evaluator, fp_name: []const u8) ?*const PadIds {
    if (fp_name.len == 0) return null;
    if (self.footprint_pad_cache.getPtr(fp_name)) |cached| return cached;
    const loaded = load(self, fp_name);
    self.footprint_pad_cache.put(self.allocator, fp_name, loaded) catch return null;
    return self.footprint_pad_cache.getPtr(fp_name);
}

/// Read `<project_dir>/lib/footprints/<fp_name>.sexp` and collect every
/// `(pad ID …)` id. Any failure yields the empty set rather than an error:
/// a part whose footprint this project does not carry must not fail a build
/// that never needed the geometry.
fn load(self: *Evaluator, fp_name: []const u8) PadIds {
    var pads: PadIds = .empty;
    const path = std.fmt.allocPrint(self.allocator, path_fmt, .{ self.project_dir, fp_name }) catch return pads;
    defer self.allocator.free(path);
    const source = infra_fs.cwd().readFileAlloc(self.allocator, path, lib_limits.max_footprint_bytes) catch return pads;
    const nodes = parser_mod.parse(self.allocator, source) catch return pads;
    if (nodes.len == 0 or !nodes[0].isForm("footprint")) return pads;
    const children = nodes[0].asList() orelse return pads;
    for (children) |child| appendPadId(self, child, &pads);
    return pads;
}

/// Record one `(pad ID …)` form's id in `pads`. Non-pad children and pads
/// whose id token is unreadable are skipped.
fn appendPadId(self: *Evaluator, child: ast.Node, pads: *PadIds) void {
    if (!child.isForm("pad")) return;
    const cl = child.asList() orelse return;
    if (cl.len < 2) return;
    const id = ids.pinId(self, cl[1]) orelse return;
    pads.put(self.allocator, id, {}) catch return;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Build an evaluator rooted at a temp dir holding one footprint file.
fn evaluatorWithFootprint(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8, body: []const u8) !Evaluator {
    try tmp.dir.createDirPath(std.testing.io, "lib/footprints");
    const sub = try std.fmt.allocPrint(alloc, "lib/footprints/{s}.sexp", .{name});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub, .data = body });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    return Evaluator.init(alloc, root);
}

// spec: eval/footprint-pads - a footprint's pad ids load as a set with numeric and alphanumeric ids normalized alike
test "footprint pad ids load and normalize" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var eval = try evaluatorWithFootprint(std.heap.page_allocator, &tmp, "j-mag",
        \\(footprint "J_MAG"
        \\  (pad 01 thru rect (pos 0 0) (size 1 1))
        \\  (pad 2 thru circle (pos 1 0) (size 1 1))
        \\  (pad SH1 thru circle (pos 2 0) (size 1 1))
        \\  (courtyard (rect -1 -1 1 1)))
    );
    defer eval.deinit();

    const pads = footprintPads(&eval, "j-mag");
    try testing.expectEqual(@as(u32, 3), pads.count());
    try testing.expect(pads.contains("1")); // (pad 01 …) normalizes like (pin 01 …)
    try testing.expect(pads.contains("2"));
    try testing.expect(pads.contains("SH1"));
    try testing.expect(!pads.contains("P1"));
}

// spec: eval/footprint-pads - a missing or padless footprint yields an empty set that reads as unknown rather than as zero pads
test "missing footprint yields an empty pad set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var eval = try evaluatorWithFootprint(std.heap.page_allocator, &tmp, "outline", "(footprint \"OUTLINE\" (courtyard (rect -1 -1 1 1)))");
    defer eval.deinit();

    try testing.expectEqual(@as(u32, 0), footprintPads(&eval, "outline").count());
    try testing.expectEqual(@as(u32, 0), footprintPads(&eval, "not-in-this-library").count());
    try testing.expect(get(&eval, "") == null);
}

// spec: eval/footprint-pads - a footprint is read once and served from the evaluator cache afterwards
test "footprint pads are cached per name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var eval = try evaluatorWithFootprint(std.heap.page_allocator, &tmp, "r-0402", "(footprint \"R\" (pad 1 smd rect (pos 0 0) (size 1 1)) (pad 2 smd rect (pos 1 0) (size 1 1)))");
    defer eval.deinit();

    const first = get(&eval, "r-0402").?;
    try testing.expectEqual(@as(u32, 1), eval.footprint_pad_cache.count());
    try testing.expectEqual(first, get(&eval, "r-0402").?);
    try testing.expectEqual(@as(u32, 1), eval.footprint_pad_cache.count());
}

fn footprintPads(eval: *Evaluator, name: []const u8) *const PadIds {
    return get(eval, name).?;
}
