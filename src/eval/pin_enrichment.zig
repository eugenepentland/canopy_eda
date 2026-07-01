//! Auto-fill `PinRef.asserted_fns` for pins whose pinout entry has exactly
//! one alt. When the user wires `(pin PN6 "FLASH_CLK")` without an `(as
//! …)` and the pinout file declares pin PN6 with a single alternative
//! (`XSPIM_P2_CLK`), there is only one possible function the wire could
//! be playing — so this pass treats the unique alt as if it had been
//! explicitly asserted. The ERC check (`erc.checkPinFunctions`) then
//! demands `as` only for genuinely ambiguous pins (≥ 2 alts).
//!
//! Runs once at the tail of `eval.design_block.evalDesignBlock`, so every
//! downstream consumer (schematic renderer, KiCad export, ERC itself)
//! sees the enriched `asserted_fns` without per-call-site plumbing.

const std = @import("std");
const env_mod = @import("env.zig");
const erc = @import("../erc.zig");

const Allocator = std.mem.Allocator;
const DesignBlock = env_mod.DesignBlock;
const Instance = env_mod.Instance;
const Net = env_mod.Net;
const PinRef = env_mod.PinRef;
const SubBlock = env_mod.SubBlock;

/// Walk every pin assignment in `block` (and nested sub-blocks) and fill
/// empty `asserted_fns` whenever the pin's pinout entry has exactly one
/// alt. `project_dir` is required to locate `lib/pinouts/*.sexp`; a
/// zero-length value is a no-op so unit tests that don't set up a
/// pinout fixture continue to work.
pub fn enrichPinFunctions(
    allocator: Allocator,
    block: *DesignBlock,
    project_dir: []const u8,
) Allocator.Error!void {
    if (project_dir.len == 0) return;

    var ref_to_symbol: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer ref_to_symbol.deinit(allocator);
    try collectRefToSymbol(allocator, block, &ref_to_symbol);

    var pinout_cache: std.StringHashMapUnmanaged(?std.StringHashMapUnmanaged(erc.PinoutEntry)) = .empty;
    defer pinout_cache.deinit(allocator);

    try enrichNetsRecursive(allocator, block, project_dir, &ref_to_symbol, &pinout_cache);
}

/// Enrich `block`'s nets then recurse into every nested sub-block. Module-in-
/// module designs (adcarray/power chains) nest deeper than one level, so the
/// walk must recurse — the header comment always promised "(and nested
/// sub-blocks)", but the old code stopped at depth 1, leaving nested pins'
/// `asserted_fns` empty (spurious `pin_function_required` ERC + lost render
/// annotations).
fn enrichNetsRecursive(
    allocator: Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    ref_to_symbol: *const std.StringHashMapUnmanaged([]const u8),
    pinout_cache: *std.StringHashMapUnmanaged(?std.StringHashMapUnmanaged(erc.PinoutEntry)),
) Allocator.Error!void {
    try enrichNets(allocator, block, project_dir, ref_to_symbol, pinout_cache);
    for (block.sub_blocks) |sb| {
        try enrichNetsRecursive(allocator, sb.block, project_dir, ref_to_symbol, pinout_cache);
    }
}

fn collectRefToSymbol(
    allocator: Allocator,
    block: *const DesignBlock,
    out: *std.StringHashMapUnmanaged([]const u8),
) Allocator.Error!void {
    for (block.instances) |inst| try putSymbol(allocator, inst, out);
    // Recurse: nested modules contribute their own ref→symbol entries, which
    // the enrichment pass needs to resolve pinouts for deeply-nested pins.
    for (block.sub_blocks) |sb| {
        try collectRefToSymbol(allocator, sb.block, out);
    }
}

fn putSymbol(
    allocator: Allocator,
    inst: Instance,
    out: *std.StringHashMapUnmanaged([]const u8),
) Allocator.Error!void {
    const lookup = if (inst.pinout.len > 0) inst.pinout else if (inst.symbol.len > 0) inst.symbol else inst.component;
    if (lookup.len == 0) return;
    if (inst.ref_des.len == 0) return;
    try out.put(allocator, inst.ref_des, lookup);
}

fn enrichNets(
    allocator: Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    ref_to_symbol: *const std.StringHashMapUnmanaged([]const u8),
    pinout_cache: *std.StringHashMapUnmanaged(?std.StringHashMapUnmanaged(erc.PinoutEntry)),
) Allocator.Error!void {
    // `block.nets` is typed `[]const Net` but the slice was freshly
    // allocated by `design_block.evalDesignBlock` and nothing else holds
    // a reference yet — safe to drop the const so we can rewrite each
    // net's `pins` slice header in place.
    const nets_mut: []Net = @constCast(block.nets);
    for (nets_mut) |*net| {
        var rewritten: ?[]PinRef = null;
        for (net.pins, 0..) |pin, i| {
            if (pin.asserted_fns.len > 0) continue;
            const alt = try resolveUniqueAlt(allocator, pin, ref_to_symbol, pinout_cache, project_dir) orelse continue;

            if (rewritten == null) rewritten = try allocator.dupe(PinRef, net.pins);
            const fns = try allocator.alloc([]const u8, 1);
            fns[0] = alt;
            rewritten.?[i].asserted_fns = fns;
        }
        if (rewritten) |buf| net.pins = buf;
    }
}

fn resolveUniqueAlt(
    allocator: Allocator,
    pin: PinRef,
    ref_to_symbol: *const std.StringHashMapUnmanaged([]const u8),
    pinout_cache: *std.StringHashMapUnmanaged(?std.StringHashMapUnmanaged(erc.PinoutEntry)),
    project_dir: []const u8,
) Allocator.Error!?[]const u8 {
    const symbol = ref_to_symbol.get(pin.ref_des) orelse return null;
    const gop = try pinout_cache.getOrPut(allocator, symbol);
    if (!gop.found_existing) {
        const path = std.fmt.allocPrint(allocator, "{s}/lib/pinouts/{s}.sexp", .{ project_dir, symbol }) catch {
            gop.value_ptr.* = null;
            return null;
        };
        gop.value_ptr.* = erc.loadPinoutMap(allocator, path);
    }
    const map = gop.value_ptr.* orelse return null;
    const entry = map.get(pin.pin) orelse return null;
    if (entry.alts.len != 1) return null;
    return entry.alts[0];
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

// spec: eval/pin_enrichment - Fills a pin's asserted_fns with the unique alt when the pinout has exactly one alternative
test "enrichPinFunctions fills single-alt pins" {
    // Arena owns every allocation the enrichment pass makes (parsed pinout
    // AST, owned alt slices, dup'd PinRef buffer, asserted_fns slice) plus
    // the test fixture itself. Production uses page_allocator so leaks
    // there are harmless; the test allocator demands explicit free, and
    // arena_cleanup is the lowest-noise option.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("lib/pinouts");
    try tmp.dir.writeFile(.{ .sub_path = "lib/pinouts/chip.sexp", .data = 
        \\(pinout "chip"
        \\  (pin A1 "PA1" (alt "SPI1_MOSI" io))
        \\  (pin A2 "PA2" (alt "TIM1_CH1" io) (alt "GPIO" io))
        \\)
    });
    const project_dir = try tmp.dir.realpathAlloc(a, ".");

    const insts = try a.alloc(env_mod.Instance, 1);
    insts[0] = .{
        .ref_des = "U1",
        .component = "chip",
        .value = "",
        .footprint = "",
        .symbol = "",
        .pinout = "chip",
        .properties = &.{},
        .attrs = &.{},
        .source_offset = 0,
        .id = "00000001",
    };
    const pins_a1 = try a.alloc(PinRef, 1);
    pins_a1[0] = .{ .ref_des = "U1", .pin = "A1" };
    const pins_a2 = try a.alloc(PinRef, 1);
    pins_a2[0] = .{ .ref_des = "U1", .pin = "A2" };
    const nets = try a.alloc(Net, 2);
    nets[0] = .{ .name = "MOSI", .pins = pins_a1 };
    nets[1] = .{ .name = "AMBIG", .pins = pins_a2 };

    var block: DesignBlock = .{
        .name = "test",
        .instances = insts,
        .nets = nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    try enrichPinFunctions(a, &block, project_dir);

    try testing.expectEqual(@as(usize, 1), block.nets[0].pins[0].asserted_fns.len);
    try testing.expectEqualStrings("SPI1_MOSI", block.nets[0].pins[0].asserted_fns[0]);
    try testing.expectEqual(@as(usize, 0), block.nets[1].pins[0].asserted_fns.len);
}
