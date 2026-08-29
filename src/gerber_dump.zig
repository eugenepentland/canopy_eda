//! `netlisp gerber-dump` — the fabrication artwork of a saved layout, printed.
//!
//! Deterministic, UNSTAMPED CAM bytes for one saved board, on stdout, from the
//! production writers:
//!
//!   netlisp gerber-dump [--project-dir <dir>] [--layout <name>] [--digest]
//!                       <design>…
//!
//! It is READ-ONLY. It resolves the design, selects the saved layout exactly as
//! the fabrication endpoints do (`pcb_layout_page.fabViewFor` — the `?layout=`
//! selector, else the blessed ★/newest/any row), and writes each planned member
//! to stdout. It creates no archive, mints no release lock, and produces nothing
//! a fab could be handed: the fabrication-release gate still owns every question
//! about whether a board MAY ship. This answers only "what bytes does the writer
//! produce", which is the one question that gate never asks out loud.
//!
//! ## Why bytes and not counts
//!
//! Every existing gate over this area compares COUNTS — layer counts, violation
//! counts, region counts. The bug this surface exists for changed none of them:
//! an arc's direction was re-derived from its quantized endpoints, so a sliver
//! arc could emit as the complementary near-full turn — the same one arc, the
//! same one aperture, several millimetres of spurious copper. Nothing counts
//! that. The emitted bytes do:
//!
//!   netlisp gerber-dump barracuda > base.txt   # built from the base binary
//!   netlisp gerber-dump barracuda > cand.txt   # …and from the candidate
//!   diff -I '^#' base.txt cand.txt             # must be empty
//!
//! `scripts/corpus_diff.sh` runs exactly that over the whole board corpus,
//! beside `drc-dump` and `netlist-dump`.
//!
//! ## What makes it deterministic
//!
//! The writers are already deterministic when nothing hands them a clock. The
//! ONE per-run input a released package adds is `%TF.CreationDate`, which
//! `fab_package.compose` stamps from `clock.timestamp()` and passes as
//! `Meta.created`; this command passes no stamp, so the attribute is omitted
//! entirely (`export_gerber.Meta.created` documents that split — it is the same
//! one the review PDF uses for `/CreationDate`). Nothing else varies: the
//! `%TF.GenerationSoftware` line is a constant, the Gerber Job File's
//! `ProjectId` carries an empty GUID and revision, Excellon has no timestamp,
//! and the fabrication identity is a hash of the timestamp-free geometry.
//!
//! Wall time and the member count therefore go on `#`-prefixed lines, which
//! `diff -I '^#'` ignores. Everything else — the selected layout row, the
//! fabrication identity, every member's size and SHA-256, and the member bytes
//! themselves — is compared.
//!
//! ## What is dumped
//!
//! The members whose bytes are the board's manufactured geometry, in the order
//! `fab_package.compose` adds them to the archive: every planned Gerber layer
//! (`export_gerber.planLayers`), the Gerber Job File that ties them together,
//! and both Excellon drill files. Each carries the archive entry name it would
//! ship under. The assembly members a package also carries — centroid, BOM,
//! operator page, release evidence — are not artwork and are not dumped.
//!
//! `--digest` prints each member's banner (name, size, SHA-256) and omits the
//! bodies: a whole-corpus dump is tens of megabytes of Gerber, and the digests
//! alone already answer "did anything move" before a human reads what.
//!
//! ## Reading a diff
//!
//! The fabrication identity is dumped and STAMPED, exactly as a released
//! package does it: `fab_identity.build` hashes the timestamp-free geometry and
//! its `ID XXXXXXXX` text goes onto the silk. So any artwork change anywhere
//! moves the `fab-id` line AND both silk layers along with the layer that
//! actually changed. That coupling is the point — it is the one line that says
//! "the manufactured board is not the same board" — but it means the layer to
//! read first in a diff is the one that is NOT silk.

const std = @import("std");
const clock = @import("infra/clock.zig");
const export_fab = @import("export_fab.zig");
const export_gerber = @import("export_gerber.zig");
const fab_filename = @import("serve/fab_filename.zig");
const fab_identity = @import("fab_identity.zig");
const font = @import("font5x7.zig");
const geometry = @import("placement/geometry.zig");
const infra_fs = @import("infra/fs.zig");
const optimizer = @import("placement/optimizer.zig");
const pcb_layout_page = @import("serve/pcb_layout_page.zig");
const pour = @import("placement/pour.zig");

const ns_per_ms: f64 = 1_000_000.0;

pub const DumpError = export_gerber.Error || error{ GerberDumpUsage, UnresolvedBoard };

const Args = struct {
    project_dir: []const u8 = "projects/designs",
    /// The saved layout to fabricate, or null for the blessed selection the
    /// release endpoints default to.
    layout: ?[]const u8 = null,
    /// Print only the per-member banners (name, size, SHA-256), not the bytes.
    digest: bool = false,
    names: []const []const u8 = &.{},
};

fn parseArgs(arena: std.mem.Allocator, args: []const []const u8) DumpError!Args {
    var out: Args = .{};
    var names: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--project-dir") and i + 1 < args.len) {
            i += 1;
            out.project_dir = args[i];
        } else if (std.mem.eql(u8, a, "--layout") and i + 1 < args.len) {
            i += 1;
            out.layout = args[i];
        } else if (std.mem.eql(u8, a, "--digest")) {
            out.digest = true;
        } else if (std.mem.startsWith(u8, a, "--")) {
            return error.GerberDumpUsage;
        } else try names.append(arena, a);
    }
    if (names.items.len == 0) return error.GerberDumpUsage;
    out.names = names.items;
    return out;
}

/// The identity a board whose fabrication mark could not be placed dumps with:
/// no generated `ID XXXXXXXX` silk, and any stale adopted one dropped. That is
/// exactly the text set `fab_identity.build` hashes, so the artwork below stays
/// the artwork the digest is taken over even when the digest itself failed.
const unmarked: fab_identity.Mark = .{
    .short_hex = @splat('-'),
    .digest_hex = @splat('-'),
    .printed = false,
    .text = null,
};

/// A board's fabrication identity, or the reason it has none. A failure is
/// dumped as a compared line rather than swallowed: `NoSilkscreenSpace` on a
/// board that used to have room is a real regression in the silk solver, and a
/// dump that quietly fell back would compare equal through it.
const Identity = struct {
    mark: fab_identity.Mark,
    failure: ?[]const u8 = null,
};

fn identityFor(
    arena: std.mem.Allocator,
    view: pcb_layout_page.FabView,
    copper: export_gerber.Copper,
    frame: export_fab.Frame,
    edge: ?pour.EdgeField,
) Identity {
    const mark = fab_identity.build(arena, view.placement, copper, view.texts, frame, edge) catch |err|
        return .{ .mark = unmarked, .failure = @errorName(err) };
    return .{ .mark = mark };
}

/// Writes one dumped member: its banner, then (unless `--digest`) its bytes
/// between delimiters naming the board and the archive entry.
const Emitter = struct {
    w: *std.Io.Writer,
    name: []const u8,
    digest_only: bool,
    index: usize = 0,

    /// `file` is the archive entry name the member would ship under and
    /// `function` its `%TF.FileFunction` (`-` for the members that declare
    /// none), so a dumped member and a released one are the same file.
    fn member(self: *Emitter, file: []const u8, function: []const u8, bytes: []const u8) DumpError!void {
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        try self.w.print("{s} member {d} file={s} function={s} bytes={d} sha256={s}\n", .{
            self.name, self.index, file, function, bytes.len, &hex,
        });
        self.index += 1;
        if (self.digest_only) return;
        try self.w.print("=== BEGIN {s} {s}\n", .{ self.name, file });
        try self.w.writeAll(bytes);
        // Every writer here ends its output with a newline; the guard keeps the
        // closing delimiter on its own line whatever a future member does.
        if (bytes.len > 0 and bytes[bytes.len - 1] != '\n') try self.w.writeByte('\n');
        try self.w.print("=== END {s} {s}\n", .{ self.name, file });
    }
};

/// The archive entry name a planned layer ships under — the SAME rule
/// `fab_package.compose` applies, so a member dumped here can be matched
/// against the one in a downloaded package by name.
fn entryName(arena: std.mem.Allocator, prefix: []const u8, file: export_gerber.LayerFile) std.mem.Allocator.Error![]const u8 {
    if (file.exact_name) return file.suffix;
    return std.fmt.allocPrint(arena, "{s}-{s}", .{ prefix, file.suffix });
}

/// One board's members, resolved once. Every writer below reads the SAME
/// placement, copper, texts and frame: a package whose drill file and copper
/// file came from different views mis-stacks in CAM, and a dump assembled that
/// way would compare two boards rather than one.
const Board = struct {
    placement: optimizer.Placement,
    copper: export_gerber.Copper,
    /// The board texts to fabricate — authored silk plus at most one current
    /// identity mark, from `fab_identity.replaceAdoptedText`.
    texts: []const font.BoardText,
    frame: export_fab.Frame,
    layers: []const export_gerber.LayerFile,
    /// The sanitized package basename every member is named from.
    prefix: []const u8,
    /// The board-edge margin field every poured member shares.
    edge: ?pour.EdgeField = null,
};

/// Dump every planned Gerber layer, in plan order.
fn dumpLayers(arena: std.mem.Allocator, emit: *Emitter, board: Board) DumpError!void {
    for (board.layers) |file| {
        var bytes: std.Io.Writer.Allocating = .init(arena);
        // No `.created`: that is the one per-run input a released package adds,
        // and omitting it is what makes this dump comparable across runs. The
        // shared `.edge` is a pure seeding optimisation the CAM preview already
        // asserts is byte-identical to seeding each fill independently.
        try export_gerber.writeLayer(&bytes.writer, arena, board.placement, board.copper, board.texts, board.frame, file.layer, .{
            .function = file.function,
            .edge = board.edge,
        });
        try emit.member(try entryName(arena, board.prefix, file), file.function, bytes.written());
    }
}

/// Dump the Gerber Job File and both Excellon drills — the rest of the members
/// whose bytes are geometry rather than assembly paperwork.
fn dumpJobAndDrills(arena: std.mem.Allocator, emit: *Emitter, board: Board) DumpError!void {
    var job: std.Io.Writer.Allocating = .init(arena);
    try export_gerber.writeJobFile(&job.writer, board.placement, board.layers, board.prefix);
    const job_name = try std.fmt.allocPrint(arena, "{s}-{s}", .{ board.prefix, export_gerber.job_file_suffix });
    try emit.member(job_name, "-", job.written());

    const copper_layers = board.placement.rules.layerStack().stackCount();
    const drills = [_]struct { class: export_fab.DrillClass, suffix: []const u8, function: []const u8 }{
        .{ .class = .plated, .suffix = export_gerber.plated_drill_suffix, .function = "Plated,PTH" },
        .{ .class = .non_plated, .suffix = export_gerber.non_plated_drill_suffix, .function = "NonPlated,NPTH" },
    };
    for (drills) |drill| {
        var bytes: std.Io.Writer.Allocating = .init(arena);
        try export_fab.excellonDrill(&bytes.writer, arena, board.placement.parts, board.copper.vias, .{
            .class = drill.class,
            .copper_layers = copper_layers,
        }, board.frame);
        const file = try std.fmt.allocPrint(arena, "{s}-{s}", .{ board.prefix, drill.suffix });
        try emit.member(file, drill.function, bytes.written());
    }
}

fn writeIdentity(w: *std.Io.Writer, name: []const u8, identity: Identity) DumpError!void {
    if (identity.failure) |err| {
        try w.print("{s} fab-id ERROR {s}\n", .{ name, err });
        return;
    }
    // `part=` is last because an authored board part number may carry spaces.
    try w.print("{s} fab-id id={s} sha256={s} printed={} part={s}\n", .{
        name,
        &identity.mark.short_hex,
        &identity.mark.digest_hex,
        identity.mark.printed,
        identity.mark.part_number,
    });
}

fn dumpOne(
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    args: Args,
    name: []const u8,
) DumpError!bool {
    const t0 = clock.nanoTimestamp();
    // The same selection the fabrication endpoints make, through the same
    // function: the named `--layout` row, else the blessed ★/newest/any one.
    // Reaching for a different selector is how a dump ends up comparing a board
    // nobody would ever fabricate.
    const view = pcb_layout_page.fabViewFor(alloc, args.project_dir, name, args.layout) catch |err| {
        try w.print("# {s} UNRESOLVED {s}\n", .{ name, @errorName(err) });
        return false;
    };
    // Which board was dumped is a claim, not commentary: a selector that starts
    // choosing a different saved row must show up as a difference.
    try w.print("{s} layout name={s} from_saved={} evidence_complete={}\n", .{
        name, view.selection.name, view.selection.from_saved, view.selection.evidence_complete,
    });

    const copper = export_gerber.Copper{
        .tracks = view.routed.tracks,
        .arcs = view.routed.arcs,
        .rf_paths = view.routed.rf_port_outcomes,
        .vias = view.routed.vias,
        .zones = view.zones,
        .silk_keepouts = view.silk_keepouts,
    };
    const frame = export_fab.frameFor(view.placement);
    // Every poured member rasterizes the same outline on the same lattice, so
    // the board-edge field is seeded once for all of them — exactly as the CAM
    // preview and the fabrication identity do.
    const edge = pour.sharedEdgeField(alloc, view.placement) catch null;
    const identity = identityFor(alloc, view, copper, frame, edge);
    try writeIdentity(w, name, identity);

    const board = Board{
        .placement = view.placement,
        .copper = copper,
        .texts = try fab_identity.replaceAdoptedText(alloc, view.texts, identity.mark),
        .frame = frame,
        .layers = try export_gerber.planLayers(alloc, view.placement),
        .prefix = fab_filename.prefix(name),
        .edge = edge,
    };
    var emit = Emitter{ .w = w, .name = name, .digest_only = args.digest };
    try dumpLayers(alloc, &emit, board);
    try dumpJobAndDrills(alloc, &emit, board);

    try w.print("# {s} members={d} layers={d} ms={d:.1}\n", .{
        name, emit.index, board.layers.len, @as(f64, @floatFromInt(clock.nanoTimestamp() - t0)) / ns_per_ms,
    });
    return true;
}

/// CLI entry: `netlisp gerber-dump [--project-dir <dir>] [--layout <name>]
/// [--digest] <design>…`.
pub fn cmdGerberDump(allocator: std.mem.Allocator, args: []const []const u8) DumpError!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const parsed = try parseArgs(arena_state.allocator(), args);

    var buf: [64 * 1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(infra_fs.currentIo(), &buf);
    try runParsed(allocator, &fw.interface, parsed);
}

fn runParsed(allocator: std.mem.Allocator, w: *std.Io.Writer, parsed: Args) DumpError!void {
    var unresolved: usize = 0;
    for (parsed.names) |name| {
        // A per-board arena: a poured barracuda-class package holds hundreds of
        // megabytes of artwork, and a corpus dump must peak at one board's worth
        // rather than the sum of them.
        var board_state = std.heap.ArenaAllocator.init(allocator);
        defer board_state.deinit();
        if (!try dumpOne(board_state.allocator(), w, parsed, name)) unresolved += 1;
        try w.flush();
    }
    try w.flush();
    // A board that never resolved emitted no artwork at all, so its comparison
    // proved nothing. Failing here is what stops a corpus run from reading a
    // wrong `--project-dir` or a renamed board as "no differences".
    if (unresolved > 0) return error.UnresolvedBoard;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: gerber-dump - the CLI parses the project dir, the saved-layout selector and the digest-only flag with positionals as design names
test "gerber-dump CLI parses flags and positionals" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = try parseArgs(arena, &.{ "--project-dir", "p", "--layout", "star", "--digest", "barracuda", "cyclops" });
    try testing.expectEqualStrings("p", parsed.project_dir);
    try testing.expectEqualStrings("star", parsed.layout.?);
    try testing.expect(parsed.digest);
    try testing.expectEqual(@as(usize, 2), parsed.names.len);
    // A dump naming no board, or carrying an unknown flag, is a usage error
    // rather than a silent empty dump that would "pass" any diff.
    try testing.expectError(error.GerberDumpUsage, parseArgs(arena, &.{"--digest"}));
    try testing.expectError(error.GerberDumpUsage, parseArgs(arena, &.{ "--wat", "b" }));
    const bare = try parseArgs(arena, &.{"b"});
    try testing.expectEqualStrings("projects/designs", bare.project_dir);
    try testing.expect(bare.layout == null);
    try testing.expect(!bare.digest);
}

/// A minimal complete board: one through-hole part inside an authored outline,
/// so every planned member — copper, mask, paste, silk, profile, job file and
/// both drills — has something real to emit. Arena-owned, because a `Placement`
/// holds a MUTABLE part slice that must outlive the view built around it.
fn testView(arena: std.mem.Allocator) std.mem.Allocator.Error!pcb_layout_page.FabView {
    const pads = try arena.dupe(geometry.Pad, &[_]geometry.Pad{.{
        .number = "1",
        .x = 0,
        .y = 0,
        .w = 1.2,
        .h = 1.2,
        .thru = true,
        .drill = 0.7,
    }});
    const parts = try arena.dupe(optimizer.Part, &[_]optimizer.Part{.{
        .ref_des = "J1",
        .kind = .hub,
        .hw = 1,
        .hh = 1,
        .pads = pads,
        .fallback = false,
        .x = 5,
        .y = 5,
    }});
    return .{
        .placement = .{
            .parts = parts,
            .links = &.{},
            .loops = &.{},
            .stubs = &.{},
            .instances = &.{},
            .nets = &.{},
            .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
            .minx = 0,
            .miny = 0,
            .maxx = 10,
            .maxy = 10,
            .generated = false,
            .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
        },
        .selection = .{ .from_saved = true, .name = "fixture", .evidence_complete = true },
    };
}

/// Dump one fixture board the way `dumpOne` does, into a caller-owned buffer.
fn dumpFixture(arena: std.mem.Allocator, w: *std.Io.Writer, digest_only: bool) !void {
    const view = try testView(arena);
    const copper = export_gerber.Copper{};
    const frame = export_fab.frameFor(view.placement);
    const edge = pour.sharedEdgeField(arena, view.placement) catch null;
    const identity = identityFor(arena, view, copper, frame, edge);
    try writeIdentity(w, "fixture", identity);
    const board = Board{
        .placement = view.placement,
        .copper = copper,
        .texts = try fab_identity.replaceAdoptedText(arena, view.texts, identity.mark),
        .frame = frame,
        .layers = try export_gerber.planLayers(arena, view.placement),
        .prefix = fab_filename.prefix("fixture"),
        .edge = edge,
    };
    var emit = Emitter{ .w = w, .name = "fixture", .digest_only = digest_only };
    try dumpLayers(arena, &emit, board);
    try dumpJobAndDrills(arena, &emit, board);
}

// spec: gerber-dump - two dumps of one board are byte-identical, and the creation-date stamp a released package carries is absent from the compared output
test "a dumped board reproduces byte for byte and carries no clock" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var first: std.Io.Writer.Allocating = .init(arena);
    var second: std.Io.Writer.Allocating = .init(arena);
    try dumpFixture(arena, &first.writer, false);
    try dumpFixture(arena, &second.writer, false);
    try testing.expectEqualStrings(first.written(), second.written());

    // The one per-run input a released package adds is `%TF.CreationDate`
    // (`fab_package.compose` stamps it from the clock). This command passes no
    // stamp, so the attribute must not appear at all.
    try testing.expect(std.mem.indexOf(u8, first.written(), "CreationDate") == null);
    // Every member is delimited and digested, and the profile layer is present.
    try testing.expect(std.mem.indexOf(u8, first.written(), "=== BEGIN fixture ") != null);
    try testing.expect(std.mem.indexOf(u8, first.written(), "=== END fixture ") != null);
    try testing.expect(std.mem.indexOf(u8, first.written(), "function=Profile,NP") != null);
    try testing.expect(std.mem.indexOf(u8, first.written(), export_gerber.job_file_suffix) != null);
    try testing.expect(std.mem.indexOf(u8, first.written(), export_gerber.plated_drill_suffix) != null);
    try testing.expect(std.mem.indexOf(u8, first.written(), "M02*") != null);
}

// spec: gerber-dump - every line of the dumped artwork is compared while the command's per-run numbers stay on #-prefixed lines, and --digest keeps every member banner while dropping the bodies
test "the artwork is all compared and --digest keeps every banner" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    try dumpFixture(arena, &out.writer, false);
    var it = std.mem.splitScalar(u8, out.written(), '\n');
    while (it.next()) |line| try testing.expect(line.len == 0 or line[0] != '#');

    // `--digest` drops the bodies and keeps every banner, so the digests alone
    // still answer "did anything move" over a whole corpus.
    var digested: std.Io.Writer.Allocating = .init(arena);
    try dumpFixture(arena, &digested.writer, true);
    try testing.expect(digested.written().len < out.written().len);
    try testing.expect(std.mem.indexOf(u8, digested.written(), "=== BEGIN") == null);
    try testing.expectEqual(
        std.mem.count(u8, out.written(), " sha256="),
        std.mem.count(u8, digested.written(), " sha256="),
    );
}

// spec: gerber-dump - a board that fails to resolve marks the run UNRESOLVED and the command fails, so a corpus differential can never read a vacuous pass as green
test "an unresolvable board fails the gerber dump instead of passing vacuously" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = try parseArgs(arena, &.{ "--project-dir", "/nonexistent-netlisp-project", "no-such-board" });
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.UnresolvedBoard, runParsed(testing.allocator, &out.writer, parsed));
    try testing.expect(std.mem.indexOf(u8, out.written(), "# no-such-board UNRESOLVED") != null);
    // The only line a failed board produced is the ignored one, so the error —
    // not an empty comparison — is what the run reports.
    var it = std.mem.splitScalar(u8, out.written(), '\n');
    while (it.next()) |line| try testing.expect(line.len == 0 or line[0] == '#');
}
