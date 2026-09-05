//! Guarded push of an exported `.kicad_sch` hierarchy INTO the live KiCad
//! project directory a design already syncs its board to.
//!
//! A design that drives a real board declares `(kicad-pcb "<path>")`. The board
//! sync (`serve/sync.zig`) writes that `.kicad_pcb` in place; this writes the
//! schematic beside it, so the KiCad project holds both halves instead of the
//! empty eeschema stub KiCad creates with every new project.
//!
//! **Naming follows the KiCad project, not the netlisp design.** KiCad opens
//! `<project>.kicad_sch` for the project `<project>.kicad_pro`, so the root
//! sheet is named from the board's basename (`Board B Digital.kicad_pcb` →
//! `Board B Digital.kicad_sch`) and every child sheet carries that same stem as
//! its prefix (`Board B Digital-USB.kicad_sch`). The export is simply run with
//! the project stem as its design name, which is the one input that names the
//! root, the children, the `Sheetfile` links between them, and the
//! `<stem>.kicad_pro` sidecar — so all four agree by construction, and a second
//! netlisp design pushed into the same folder cannot collide.
//!
//! **Nothing is overwritten that a human might own.** An existing sheet is
//! replaceable only when it is netlisp's own output (`(generator "netlisp")`)
//! or an empty eeschema stub — a `(kicad_sch …)` carrying no placed symbol, no
//! sheet, no wire, no label, no graphic, i.e. nothing to lose. Anything else
//! refuses by name, and the refusal is a property of the whole push: no file is
//! written when any one of them would be. `force` overrides that policy.
//!
//! **A lock refuses unconditionally.** KiCad writes `~<file>.lck` (JSON, with
//! the holder's hostname/username) while a file is open. Writing under it
//! races a human's own save, so a lock refuses even with `force` — the fix is
//! to close KiCad, not to push harder.
//!
//! **The sidecars are all treated as someone else's.** The `.kicad_pro` and
//! `sym-lib-table` are written only when absent; a `sym-lib-table` that exists
//! without a `netlisp` row is reported with the exact line to add, never
//! rewritten. `fp-lib-table` is the board sync's domain and is not touched at
//! all. Only `netlisp.kicad_sym` — which netlisp generates from the same
//! writers the sheets use — is overwritten, with a backup.
//!
//! **Write order is validate-everything-then-rename.** The export self-checks
//! its own bytes, the plan reads every target off disk, and only then does the
//! commit run: every file lands as a `.netlisp-push-tmp` sibling first, and the
//! renames (plus the backup rolls) happen after the last temp is safely on
//! disk. A failure during phase one leaves the directory exactly as it was.
//!
//! Caveat worth repeating wherever this is offered to a user: KiCad escapes `/`
//! in net names, and netlisp's per-pin bypass stubs are deliberately labelled
//! as their rail, so a netlist KiCad generates from these sheets is NOT the
//! netlisp netlist. The pushed schematic is for reading and for KiCad's own
//! ERC — it must never drive "Update PCB from Schematic" on a synced board.

const std = @import("std");
const atomic_write = @import("infra/atomic_write.zig");
const infra_fs = @import("infra/fs.zig");
const log = @import("infra/log.zig");
const parser_mod = @import("sexpr/parser.zig");
const Node = @import("sexpr/ast.zig").Node;
const export_kicad_sch = @import("export_kicad_sch.zig");
const project_mod = @import("kicad_sch/project.zig");
const board_backup = @import("serve/board_backup.zig");

const DesignBlock = @import("eval/env.zig").DesignBlock;

/// Extension of a KiCad board file, stripped from the basename to get the
/// project stem.
const pcb_ext = ".kicad_pcb";
/// Longest existing sheet the classifier reads. A netlisp root on a big board
/// is a few hundred kilobytes; anything past this is certainly not a stub.
const max_sheet_bytes: usize = 64 * 1024 * 1024;
/// Longest lock file read when naming its holder.
const max_lock_bytes: usize = 4096;

/// Errors the push can raise beyond the exporter's own.
pub const PushError = export_kicad_sch.SchError || error{
    /// The design declares no `(kicad-pcb "<path>")`, so there is no project
    /// directory to push into.
    PcbPathUnset,
    /// The board path has no directory component, so there is nowhere to write.
    PcbPathNotInDirectory,
    /// A target file could not be read, staged, backed up, or renamed.
    PushWriteFailed,
};

/// What the push would do (or did) to one file in the project directory.
pub const Action = enum {
    /// The file does not exist; the push creates it.
    create,
    /// The file exists and is replaceable; the push backs it up and replaces it.
    overwrite,
    /// The file exists and belongs to the user; the push leaves it alone.
    keep,
    /// The file exists, belongs to the user, and needs a one-line edit the push
    /// will not make for them. `note` carries the exact line.
    advise,
    /// Not this tool's file at all (the `fp-lib-table` belongs to the board sync).
    skip,
    /// The file exists, is not replaceable, and blocks the whole push.
    refuse,

    /// The word this action is reported under on every surface — the CLI's op
    /// list, the JSON `action` field, and the viewer's confirm dialog.
    pub fn label(self: Action) []const u8 {
        return switch (self) {
            .create => "create",
            .overwrite => "overwrite",
            .keep => "keep",
            .advise => "advise",
            .skip => "skip",
            .refuse => "refuse",
        };
    }
};

/// One planned file operation. `name` is a bare filename in the project
/// directory — the push never writes into a subdirectory except `backups/`.
pub const FileOp = struct {
    name: []const u8,
    action: Action,
    /// Bytes that would be written. Zero for `keep` / `skip` / `refuse`.
    bytes: usize = 0,
    /// Why this action, in one clause a user can act on.
    note: []const u8 = "",
};

/// Where a design's schematic push lands, derived entirely from its
/// `(kicad-pcb "<path>")` declaration.
pub const Target = struct {
    /// The declared board path, verbatim.
    board_path: []const u8,
    /// Directory holding the board — the project directory written into.
    dir: []const u8,
    /// The KiCad project stem (`Board B Digital`), which names the root sheet,
    /// every child sheet's prefix, and the `.kicad_pro`.
    project: []const u8,
};

/// The full push decision: where it goes, what it would do to each file, and
/// whether anything blocks it.
pub const Plan = struct {
    target: Target,
    /// Root sheet filename (`<project>.kicad_sch`).
    root: []const u8,
    ops: []const FileOp,
    /// Non-null ⇒ nothing may be written; the sentence names the blocker.
    refusal: ?[]const u8 = null,

    /// Count of ops with the given action — the summary the surfaces report.
    pub fn count(self: Plan, action: Action) usize {
        var n: usize = 0;
        for (self.ops) |op| {
            if (op.action == action) n += 1;
        }
        return n;
    }
};

/// How to run the push.
pub const Options = struct {
    /// Report the plan without writing anything.
    dry_run: bool = false,
    /// Replace a sheet that is neither netlisp's nor an empty stub. Never
    /// overrides a lock file.
    force: bool = false,
    /// Passed straight through to the exporter.
    sch: export_kicad_sch.Options = .{},
};

/// The push's outcome: the plan it decided on, and whether it wrote.
pub const Result = struct {
    plan: Plan,
    written: bool,
};

// ── Target derivation ────────────────────────────────────────────────

/// Resolve where `block`'s schematic push lands. The project stem is the
/// board's basename with `.kicad_pcb` removed, so it matches the `.kicad_pro`
/// KiCad opens the project by.
pub fn targetFor(arena: std.mem.Allocator, block: *const DesignBlock) PushError!Target {
    const board_path = block.kicad_pcb_path orelse return error.PcbPathUnset;
    const dir = std.fs.path.dirname(board_path) orelse return error.PcbPathNotInDirectory;
    if (dir.len == 0) return error.PcbPathNotInDirectory;
    const base = std.fs.path.basename(board_path);
    const stem = if (std.mem.endsWith(u8, base, pcb_ext)) base[0 .. base.len - pcb_ext.len] else base;
    if (stem.len == 0) return error.PcbPathNotInDirectory;
    return .{
        .board_path = try arena.dupe(u8, board_path),
        .dir = try arena.dupe(u8, dir),
        .project = try arena.dupe(u8, stem),
    };
}

// ── Existing-file classification ─────────────────────────────────────

/// What an existing `.kicad_sch` on disk is, for the overwrite policy.
pub const Existing = enum {
    /// No file there.
    absent,
    /// A `(kicad_sch …)` with no drawable content — what KiCad writes for a
    /// brand-new project and what the real Board B project has carried since
    /// its board was imported. Nothing to lose.
    stub,
    /// `(generator "netlisp")` — a previous push, ours to replace.
    netlisp,
    /// Anything else, including a file that does not parse: someone's work.
    foreign,
};

/// Top-level forms inside `(kicad_sch …)` that mean the sheet DRAWS something.
/// Only the root's direct children are scanned, so the `(symbol …)` entries
/// nested inside `(lib_symbols …)` (a library copy, not a placement) and the
/// `(path …)` entries inside `(symbol_instances …)` never count.
const content_forms = [_][]const u8{
    "symbol",        "sheet",      "wire",     "bus",          "bus_entry",
    "junction",      "no_connect", "label",    "global_label", "hierarchical_label",
    "netclass_flag", "text",       "text_box", "polyline",     "rectangle",
    "circle",        "arc",        "bezier",   "image",        "table",
    "rule_area",
};

/// Classify the bytes of an existing sheet.
pub fn classify(arena: std.mem.Allocator, bytes: []const u8) Existing {
    if (std.mem.trim(u8, bytes, " \t\r\n").len == 0) return .stub;
    const nodes = parser_mod.parse(arena, bytes) catch return .foreign;
    if (nodes.len == 0) return .foreign;
    const root = nodes[0].asList() orelse return .foreign;
    if (root.len == 0) return .foreign;
    const head = root[0].asAtom() orelse return .foreign;
    if (!std.mem.eql(u8, head, "kicad_sch")) return .foreign;
    if (generatorIsNetlisp(root[1..])) return .netlisp;
    for (root[1..]) |child| {
        if (isContentForm(child)) return .foreign;
    }
    return .stub;
}

/// True when the sheet declares `(generator "netlisp")`. KiCad writes the
/// generator as a quoted string; accept a bare atom too, since the reader is
/// liberal everywhere else.
fn generatorIsNetlisp(children: []const Node) bool {
    for (children) |child| {
        if (!child.isForm("generator")) continue;
        const list = child.asList() orelse continue;
        if (list.len < 2) continue;
        const val = list[1].asString() orelse (list[1].asAtom() orelse continue);
        if (std.mem.eql(u8, val, "netlisp")) return true;
    }
    return false;
}

fn isContentForm(node: Node) bool {
    const list = node.asList() orelse return false;
    if (list.len == 0) return false;
    const head = list[0].asAtom() orelse return false;
    for (content_forms) |name| {
        if (std.mem.eql(u8, head, name)) return true;
    }
    return false;
}

/// Read and classify the file at `dir`/`name`. A read failure other than
/// "not there" reads as `foreign`: an unreadable file is certainly not one we
/// have established is safe to replace.
fn classifyPath(arena: std.mem.Allocator, dir: []const u8, name: []const u8) Existing {
    const path = std.fs.path.join(arena, &.{ dir, name }) catch return .foreign;
    const bytes = infra_fs.cwd().readFileAlloc(arena, path, max_sheet_bytes) catch |e| switch (e) {
        error.FileNotFound => return .absent,
        else => return .foreign,
    };
    return classify(arena, bytes);
}

/// Whether a path exists at all (used for the sidecars, which are not sheets
/// and so are never classified).
fn exists(arena: std.mem.Allocator, dir: []const u8, name: []const u8) bool {
    const path = std.fs.path.join(arena, &.{ dir, name }) catch return true;
    infra_fs.cwd().access(path, .{}) catch return false;
    return true;
}

// ── Lock detection ───────────────────────────────────────────────────

/// A KiCad lock found in the project directory.
pub const Lock = struct {
    file: []const u8,
    hostname: []const u8 = "",
    username: []const u8 = "",
};

/// True for KiCad's `~<something>.lck` lock-file spelling.
pub fn isLockName(name: []const u8) bool {
    return name.len > 5 and name[0] == '~' and std.mem.endsWith(u8, name, ".lck");
}

/// The first KiCad lock file in `dir`, if any. KiCad writes one per open
/// document (`~Board.kicad_pcb.lck`, `~Board.kicad_sch.lck`), so ANY lock in
/// the project directory means a human has the project open — the push refuses
/// on all of them, not only on the files it would write.
pub fn findLock(arena: std.mem.Allocator, dir: []const u8) ?Lock {
    var d = infra_fs.cwd().openDir(dir, .{ .iterate = true }) catch return null;
    defer d.close();
    var it = d.iterate();
    var found: ?[]const u8 = null;
    while (it.next() catch return null) |entry| {
        if (entry.kind != .file) continue;
        if (!isLockName(entry.name)) continue;
        // Lowest name wins so the message is stable across directory orders.
        if (found) |f| {
            if (std.mem.lessThan(u8, f, entry.name)) continue;
        }
        found = arena.dupe(u8, entry.name) catch return null;
    }
    const name = found orelse return null;
    return readLock(arena, dir, name);
}

/// Fill in the lock's holder from its JSON body. A lock whose body cannot be
/// read still blocks — it just cannot say who holds it.
fn readLock(arena: std.mem.Allocator, dir: []const u8, name: []const u8) Lock {
    var lock = Lock{ .file = name };
    const path = std.fs.path.join(arena, &.{ dir, name }) catch return lock;
    const bytes = infra_fs.cwd().readFileAlloc(arena, path, max_lock_bytes) catch return lock;
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return lock;
    if (root != .object) return lock;
    lock.hostname = jsonStringField(root, "hostname");
    lock.username = jsonStringField(root, "username");
    return lock;
}

fn jsonStringField(root: std.json.Value, key: []const u8) []const u8 {
    const v = root.object.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

/// The refusal sentence for a held lock.
fn lockRefusal(arena: std.mem.Allocator, lock: Lock) std.mem.Allocator.Error![]const u8 {
    if (lock.hostname.len == 0 and lock.username.len == 0) {
        return std.fmt.allocPrint(
            arena,
            "KiCad has this project open ({s}) — close it before pushing the schematic",
            .{lock.file},
        );
    }
    return std.fmt.allocPrint(
        arena,
        "KiCad has this project open ({s}, held by {s}@{s}) — close it before pushing the schematic",
        .{ lock.file, lock.username, lock.hostname },
    );
}

// ── Planning ─────────────────────────────────────────────────────────

/// The `sym-lib-table` row that makes `netlisp:<part>` symbols resolve. Quoted
/// verbatim in the `advise` note, so a user with their own table can paste it.
pub const sym_lib_row = "\t(lib (name \"netlisp\")(type \"KiCad\")" ++
    "(uri \"${KIPRJMOD}/netlisp.kicad_sym\")(options \"\")(descr \"Symbols exported by netlisp\"))";

/// Decide what the push would do to every file, reading each target off disk.
/// Never writes. `out` must have been exported with `target.project` as its
/// design name, so its filenames are the ones this plans for.
pub fn planFor(
    arena: std.mem.Allocator,
    target: Target,
    out: export_kicad_sch.Output,
    force: bool,
) PushError!Plan {
    var ops: std.ArrayList(FileOp) = .empty;
    var blocked: ?[]const u8 = null;

    // Every `name` is duped onto `arena`: `out` is owned by the caller's
    // general allocator and is freed as soon as the push returns, while the
    // plan outlives it on every surface (a JSON body, a printed op list).
    for (out.files) |f| {
        var op = try planSheet(arena, target.dir, f, force);
        if (op.action == .refuse and blocked == null) blocked = try refusalFor(arena, target.dir, f.name);
        op.name = try arena.dupe(u8, f.name);
        try ops.append(arena, op);
    }
    for (out.sidecars) |f| {
        var op = planSidecar(arena, target.dir, f);
        op.name = try arena.dupe(u8, f.name);
        try ops.append(arena, op);
    }

    // A held lock outranks everything, including `force`: writing under it
    // races the human who has the file open.
    if (findLock(arena, target.dir)) |lock| blocked = try lockRefusal(arena, lock);

    return .{
        .target = target,
        .root = if (ops.items.len > 0 and out.files.len > 0) ops.items[0].name else "",
        .ops = ops.items,
        .refusal = blocked,
    };
}

/// Policy for one emitted sheet: absent → create; netlisp's own or an empty
/// stub → overwrite; anything else → refuse, unless `force`.
fn planSheet(
    arena: std.mem.Allocator,
    dir: []const u8,
    f: export_kicad_sch.SchFile,
    force: bool,
) PushError!FileOp {
    return switch (classifyPath(arena, dir, f.name)) {
        .absent => .{ .name = f.name, .action = .create, .bytes = f.bytes.len },
        .netlisp => .{
            .name = f.name,
            .action = .overwrite,
            .bytes = f.bytes.len,
            .note = "previous netlisp push",
        },
        .stub => .{
            .name = f.name,
            .action = .overwrite,
            .bytes = f.bytes.len,
            .note = "empty eeschema stub (no symbols, sheets, wires or labels)",
        },
        .foreign => if (force) .{
            .name = f.name,
            .action = .overwrite,
            .bytes = f.bytes.len,
            .note = "hand-drawn schematic, replaced because --force was given",
        } else .{
            .name = f.name,
            .action = .refuse,
            .note = "existing schematic was not generated by netlisp and is not an empty stub",
        },
    };
}

fn refusalFor(arena: std.mem.Allocator, dir: []const u8, name: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{s}/{s} is an existing schematic netlisp did not generate — " ++
            "it is neither an empty eeschema stub nor a previous push, so nothing was written " ++
            "(pass force to replace it; a backup is rolled either way)",
        .{ dir, name },
    );
}

/// Policy for one project sidecar. Three of the four belong to the user or to
/// the board sync; only `netlisp.kicad_sym` is ours to rewrite.
fn planSidecar(arena: std.mem.Allocator, dir: []const u8, f: export_kicad_sch.SchFile) FileOp {
    if (std.mem.eql(u8, f.name, project_mod.fp_lib_table_file)) {
        return .{ .name = f.name, .action = .skip, .note = "footprint table belongs to the board sync" };
    }
    const present = exists(arena, dir, f.name);
    if (std.mem.eql(u8, f.name, project_mod.sym_lib_file)) {
        return .{
            .name = f.name,
            .action = if (present) .overwrite else .create,
            .bytes = f.bytes.len,
            .note = if (present) "netlisp-generated symbol library" else "",
        };
    }
    if (!present) return .{ .name = f.name, .action = .create, .bytes = f.bytes.len };
    if (std.mem.eql(u8, f.name, project_mod.sym_lib_table_file)) return planSymLibTable(arena, dir, f);
    return .{ .name = f.name, .action = .keep, .note = "existing project file left untouched" };
}

/// An existing `sym-lib-table` is never rewritten. If it already names the
/// `netlisp` library the push has nothing to do; if it does not, the exact row
/// to add is reported so the user makes the edit themselves.
fn planSymLibTable(arena: std.mem.Allocator, dir: []const u8, f: export_kicad_sch.SchFile) FileOp {
    const path = std.fs.path.join(arena, &.{ dir, f.name }) catch
        return .{ .name = f.name, .action = .keep, .note = "existing table left untouched" };
    const bytes = infra_fs.cwd().readFileAlloc(arena, path, max_lock_bytes * 64) catch
        return .{ .name = f.name, .action = .keep, .note = "existing table left untouched (unreadable)" };
    if (std.mem.indexOf(u8, bytes, "\"" ++ project_mod.sym_lib_name ++ "\"") != null) {
        return .{ .name = f.name, .action = .keep, .note = "already names the netlisp library" };
    }
    return .{
        .name = f.name,
        .action = .advise,
        .note = "add this row so netlisp: symbols resolve: " ++ sym_lib_row,
    };
}

// ── Committing ───────────────────────────────────────────────────────

/// Write the plan. Every file is staged under a `.netlisp-push-tmp` sibling
/// first; only once every temp is on disk are the backups rolled and the temps
/// renamed into place. A failure in the staging phase removes the temps and
/// leaves the directory byte-identical.
pub fn commit(arena: std.mem.Allocator, plan: Plan, out: export_kicad_sch.Output) PushError!void {
    if (plan.refusal != null) return;
    var staged: std.ArrayList(StagedFile) = .empty;
    // Every path out of here that has not committed a transaction unlinks its
    // temporary; `abandon` is a no-op on one `promote` already published, so
    // the same defer covers the success path.
    defer for (staged.items) |f| f.writer.abandon();

    // The directory may not exist yet when the declared board has never been
    // written (a design pointed at a project folder still to be created).
    infra_fs.cwd().makePath(plan.target.dir) catch return error.PushWriteFailed;

    for (plan.ops) |op| {
        if (!writes(op.action)) continue;
        const bytes = bytesFor(out, op.name) orelse continue;
        try staged.append(arena, try stage(arena, plan.target.dir, op.name, bytes));
    }
    for (staged.items) |f| try promote(arena, plan.target.dir, f);
}

/// The two actions that put bytes on disk.
fn writes(action: Action) bool {
    return action == .create or action == .overwrite;
}

/// The emitted bytes for a filename, searching sheets then sidecars.
fn bytesFor(out: export_kicad_sch.Output, name: []const u8) ?[]const u8 {
    for (out.files) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.bytes;
    }
    for (out.sidecars) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.bytes;
    }
    return null;
}

/// One file's staged replacement, open from the staging phase until the promote
/// phase publishes it.
///
/// The writer is heap-allocated rather than held by value: `Staged` owns the
/// buffer its file writer points into, so it must not be moved once `begin` has
/// succeeded, and an `ArrayList` of them relocates on growth.
const StagedFile = struct { name: []const u8, writer: *atomic_write.Staged };

/// Phase one: the bytes land in a sibling temporary of the target, held open
/// (not yet published) until every file in the push has staged.
///
/// This is the tree's shared staged writer rather than a private
/// `<name>.netlisp-push-tmp` + rename, so the temporary is randomly named — two
/// pushes into one project directory can no longer write into each other's
/// staging file — and an abandoned transaction unlinks it instead of relying on
/// an unwind path to find it by name.
fn stage(arena: std.mem.Allocator, dir: []const u8, name: []const u8, bytes: []const u8) PushError!StagedFile {
    const path = try std.fs.path.join(arena, &.{ dir, name });
    const writer = arena.create(atomic_write.Staged) catch return error.PushWriteFailed;
    writer.* = .{};
    errdefer writer.abandon();
    writer.begin(path) catch return error.PushWriteFailed;
    writer.write(bytes) catch return error.PushWriteFailed;
    return .{ .name = name, .writer = writer };
}

/// Phase two: roll a backup of whatever is there, then publish the staged bytes
/// over it (flush, fsync, rename). The fsync moved here from the staging phase,
/// which is the order durability actually wants: the bytes reach the disk
/// immediately before the rename that makes them visible.
fn promote(arena: std.mem.Allocator, dir: []const u8, file: StagedFile) PushError!void {
    const dest = try std.fs.path.join(arena, &.{ dir, file.name });
    board_backup.rollBackup(arena, dest) catch return error.PushWriteFailed;
    file.writer.commit() catch return error.PushWriteFailed;
}

// ── The whole push ───────────────────────────────────────────────────

/// Export `block`'s schematic under its KiCad project's name and push it into
/// the project directory the design's `(kicad-pcb …)` names.
///
/// `gpa` owns the exported bytes (freed before this returns); everything in the
/// returned `Result` lives on `arena`. The order is deliberate and is the whole
/// safety argument: the export self-checks first, the plan reads every target
/// off disk second, and only a plan with no refusal reaches `commit`.
pub fn run(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    opts: Options,
) PushError!Result {
    const target = try targetFor(arena, block);
    // The project stem, not the design name: it is the single input that names
    // the root sheet, every child, the Sheetfile links and the .kicad_pro.
    const out = try export_kicad_sch.exportSch(gpa, block, project_dir, target.project, opts.sch);
    defer out.deinit(gpa);

    const plan = try planFor(arena, target, out, opts.force);
    if (plan.refusal != null or opts.dry_run) return .{ .plan = plan, .written = false };
    try commit(arena, plan, out);
    return .{ .plan = plan, .written = true };
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

/// A real KiCad-10 empty project schematic, byte-for-byte the shape the live
/// Board B project has carried since its board was imported.
const stub_sheet =
    \\(kicad_sch (version 20250114) (generator "eeschema") (generator_version "9.0")
    \\  (paper "A4")
    \\  (lib_symbols)
    \\  (symbol_instances)
    \\)
;

/// A sheet netlisp wrote — same shape, our generator tag.
const netlisp_sheet =
    \\(kicad_sch (version 20260306) (generator "netlisp") (generator_version "10.0")
    \\  (paper "A4")
    \\  (lib_symbols)
    \\)
;

/// A hand-drawn sheet: eeschema's generator AND one placed symbol.
const drawn_sheet =
    \\(kicad_sch (version 20250114) (generator "eeschema") (generator_version "9.0")
    \\  (paper "A4")
    \\  (lib_symbols (symbol "Device:R" (pin_numbers hide)))
    \\  (symbol (lib_id "Device:R") (at 100 100 0) (uuid "abc"))
    \\)
;

// spec: kicad_sch_push - An existing sheet is replaceable only when it is netlisp-generated or an empty eeschema stub; a hand-drawn sheet or an unparseable file is foreign
test "kicad-sch push: the overwrite classifier separates stub, netlisp and hand-drawn sheets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectEqual(Existing.stub, classify(a, stub_sheet));
    try testing.expectEqual(Existing.netlisp, classify(a, netlisp_sheet));
    try testing.expectEqual(Existing.foreign, classify(a, drawn_sheet));
    // An empty file holds nothing, so it reads as a stub; junk and a
    // non-schematic s-expression are foreign, never silently replaceable.
    try testing.expectEqual(Existing.stub, classify(a, "  \n\t "));
    try testing.expectEqual(Existing.foreign, classify(a, "(kicad_pcb (version 20241229))"));
    // A netlisp sheet stays replaceable however much it draws — the generator
    // tag is checked before the content scan.
    try testing.expectEqual(
        Existing.netlisp,
        classify(a, "(kicad_sch (generator \"netlisp\") (symbol (lib_id \"x\")))"),
    );
}

// spec: kicad_sch_push - The lib_symbols block and the symbol_instances block never make a stub look drawn, because only the root sheet's direct children are scanned
test "kicad-sch push: a stub's library and instance blocks do not count as content" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // `lib_symbols` holds `(symbol …)` children — a library copy, not a
    // placement. Reading them as content would make every KiCad stub foreign.
    const with_lib =
        \\(kicad_sch (version 20250114) (generator "eeschema")
        \\  (lib_symbols (symbol "Device:R" (symbol "Device:R_0_1")))
        \\  (symbol_instances (path "/abc" (reference "R1") (unit 1)))
        \\)
    ;
    try testing.expectEqual(Existing.stub, classify(a, with_lib));
    // One placed wire is enough to make it someone's drawing.
    const with_wire =
        \\(kicad_sch (version 20250114) (generator "eeschema")
        \\  (lib_symbols)
        \\  (wire (pts (xy 0 0) (xy 10 0)))
        \\)
    ;
    try testing.expectEqual(Existing.foreign, classify(a, with_wire));
}

// spec: kicad_sch_push - The push names its root sheet and every child from the KiCad project the board path belongs to, not from the netlisp design name
test "kicad-sch push: the target derives from the declared board path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const block = emptyBlockForTest("/mnt/nas/Board B/Board B Digital/Board B Digital.kicad_pcb");
    const t = try targetFor(a, &block);
    try testing.expectEqualStrings("/mnt/nas/Board B/Board B Digital", t.dir);
    try testing.expectEqualStrings("Board B Digital", t.project);

    // A design with no (kicad-pcb …) has nowhere to push.
    const bare = emptyBlockForTest(null);
    try testing.expectError(error.PcbPathUnset, targetFor(a, &bare));
    // A bare filename has no directory to write into.
    const loose = emptyBlockForTest("board.kicad_pcb");
    try testing.expectError(error.PcbPathNotInDirectory, targetFor(a, &loose));
}

// spec: kicad_sch_push - A KiCad lock file in the project directory refuses the push by name, whoever holds it and whatever force says
test "kicad-sch push: a lock file is found and named" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    try testing.expect(findLock(a, dir) == null);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "~Board.kicad_pcb.lck",
        .data = "{\"hostname\":\"kicad-box\",\"username\":\"eugene\"}",
    });
    const lock = findLock(a, dir).?;
    try testing.expectEqualStrings("~Board.kicad_pcb.lck", lock.file);
    try testing.expectEqualStrings("kicad-box", lock.hostname);
    try testing.expectEqualStrings("eugene", lock.username);
    const msg = try lockRefusal(a, lock);
    try testing.expect(std.mem.indexOf(u8, msg, "eugene@kicad-box") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "~Board.kicad_pcb.lck") != null);
    // The spelling test is what keeps an ordinary project file from reading as
    // a lock.
    try testing.expect(isLockName("~Board.kicad_sch.lck"));
    try testing.expect(!isLockName("Board.kicad_sch"));
    try testing.expect(!isLockName("~notalock"));
}

/// A `DesignBlock` with nothing in it but a board declaration — enough for
/// `targetFor`, which reads only `kicad_pcb_path`.
fn emptyBlockForTest(pcb: ?[]const u8) DesignBlock {
    return .{
        .name = "demo",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .kicad_pcb_path = pcb,
    };
}

/// The exporter's output shape, stubbed: a root sheet, one child, and the four
/// sidecars under the names `project.sidecars` really emits. Planning reads
/// only names and byte lengths, so a stub is the whole input it needs — and it
/// keeps the policy tests free of a full design evaluation.
fn fakeOutputForTest() export_kicad_sch.Output {
    const files = &[_]export_kicad_sch.SchFile{
        .{ .name = "Board.kicad_sch", .bytes = netlisp_sheet },
        .{ .name = "Board-Core.kicad_sch", .bytes = netlisp_sheet },
    };
    const sidecars = &[_]export_kicad_sch.SchFile{
        .{ .name = project_mod.sym_lib_table_file, .bytes = "(sym_lib_table)\n" },
        .{ .name = project_mod.fp_lib_table_file, .bytes = "(fp_lib_table)\n" },
        .{ .name = "Board.kicad_pro", .bytes = "{}\n" },
        .{ .name = project_mod.sym_lib_file, .bytes = "(kicad_symbol_lib)\n" },
    };
    return .{ .files = files, .sidecars = sidecars };
}

/// Plan a push into `tmp` with the stub output above.
fn planInTmp(a: std.mem.Allocator, tmp: *std.testing.TmpDir, force: bool) !Plan {
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const target = Target{
        .board_path = try std.fs.path.join(a, &.{ dir, "Board.kicad_pcb" }),
        .dir = dir,
        .project = "Board",
    };
    return planFor(a, target, fakeOutputForTest(), force);
}

/// The planned action for one filename.
fn actionOf(plan: Plan, name: []const u8) ?Action {
    for (plan.ops) |op| {
        if (std.mem.eql(u8, op.name, name)) return op.action;
    }
    return null;
}

/// The planned note for one filename.
fn noteOf(plan: Plan, name: []const u8) []const u8 {
    for (plan.ops) |op| {
        if (std.mem.eql(u8, op.name, name)) return op.note;
    }
    return "";
}

// spec: kicad_sch_push - A missing sheet is created, a netlisp or stub sheet is overwritten, and a hand-drawn sheet refuses the whole push unless force is given
test "kicad-sch push: the overwrite policy matrix" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Nothing on disk: both sheets are creates and nothing blocks.
    const fresh = try planInTmp(a, &tmp, false);
    try testing.expectEqual(Action.create, actionOf(fresh, "Board.kicad_sch").?);
    try testing.expectEqual(Action.create, actionOf(fresh, "Board-Core.kicad_sch").?);
    try testing.expect(fresh.refusal == null);

    // The real-world case: KiCad's empty stub as the root, a previous push as
    // the child. Both replaceable.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Board.kicad_sch", .data = stub_sheet });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Board-Core.kicad_sch", .data = netlisp_sheet });
    const known = try planInTmp(a, &tmp, false);
    try testing.expectEqual(Action.overwrite, actionOf(known, "Board.kicad_sch").?);
    try testing.expectEqual(Action.overwrite, actionOf(known, "Board-Core.kicad_sch").?);
    try testing.expect(known.refusal == null);

    // A hand-drawn child blocks the ENTIRE push, and the refusal names it.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Board-Core.kicad_sch", .data = drawn_sheet });
    const blocked = try planInTmp(a, &tmp, false);
    try testing.expectEqual(Action.refuse, actionOf(blocked, "Board-Core.kicad_sch").?);
    try testing.expect(std.mem.indexOf(u8, blocked.refusal.?, "Board-Core.kicad_sch") != null);

    // …and force is the documented override.
    const forced = try planInTmp(a, &tmp, true);
    try testing.expectEqual(Action.overwrite, actionOf(forced, "Board-Core.kicad_sch").?);
    try testing.expect(forced.refusal == null);
}

// spec: kicad_sch_push - A lock file blocks the push even with force, because writing under it races the human who has the project open
test "kicad-sch push: a lock refuses a plan that force would otherwise allow" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Board.kicad_sch", .data = drawn_sheet });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "~Board.kicad_sch.lck",
        .data = "{\"hostname\":\"kicad-box\",\"username\":\"eugene\"}",
    });

    const forced = try planInTmp(a, &tmp, true);
    try testing.expect(forced.refusal != null);
    try testing.expect(std.mem.indexOf(u8, forced.refusal.?, "has this project open") != null);
}

// spec: kicad_sch_push - The push creates an absent .kicad_pro and sym-lib-table, keeps either when it exists, reports the row to add to a sym-lib-table with no netlisp entry, and never touches the fp-lib-table
test "kicad-sch push: the sidecar policy is create-when-absent, keep, advise, skip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Nothing there: the project file and the table are created, the footprint
    // table is skipped whether it exists or not, the symbol library is ours.
    const fresh = try planInTmp(a, &tmp, false);
    try testing.expectEqual(Action.create, actionOf(fresh, "Board.kicad_pro").?);
    try testing.expectEqual(Action.create, actionOf(fresh, "sym-lib-table").?);
    try testing.expectEqual(Action.skip, actionOf(fresh, "fp-lib-table").?);
    // The symbol library is ours either way, but an absent one reads as a
    // create — "overwrite" on a file that is not there reads as a threat.
    try testing.expectEqual(Action.create, actionOf(fresh, "netlisp.kicad_sym").?);

    // A real project: an existing .kicad_pro is never touched, and a table that
    // already names the library needs nothing.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Board.kicad_pro", .data = "{\"board\":{}}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fp-lib-table", .data = "(fp_lib_table)" });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "sym-lib-table",
        .data = "(sym_lib_table\n\t(lib (name \"netlisp\")(type \"KiCad\")(uri \"x\"))\n)",
    });
    const known = try planInTmp(a, &tmp, false);
    try testing.expectEqual(Action.keep, actionOf(known, "Board.kicad_pro").?);
    try testing.expectEqual(Action.keep, actionOf(known, "sym-lib-table").?);
    try testing.expectEqual(Action.skip, actionOf(known, "fp-lib-table").?);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "netlisp.kicad_sym", .data = "(kicad_symbol_lib)" });
    const relib = try planInTmp(a, &tmp, false);
    try testing.expectEqual(Action.overwrite, actionOf(relib, "netlisp.kicad_sym").?);

    // A user's own table with no netlisp row is REPORTED, never rewritten —
    // and the note carries the exact line to paste.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "sym-lib-table",
        .data = "(sym_lib_table\n\t(lib (name \"mylib\")(type \"KiCad\")(uri \"y\"))\n)",
    });
    const advised = try planInTmp(a, &tmp, false);
    try testing.expectEqual(Action.advise, actionOf(advised, "sym-lib-table").?);
    try testing.expect(std.mem.indexOf(u8, noteOf(advised, "sym-lib-table"), sym_lib_row) != null);
    try testing.expect(advised.refusal == null);
}

// spec: kicad_sch_push - Committing writes every sheet and creatable sidecar, rolls a timestamped backup of what it replaced, and leaves the fp-lib-table and an existing .kicad_pro alone
test "kicad-sch push: commit writes the plan and backs up what it replaced" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Board.kicad_sch", .data = stub_sheet });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Board.kicad_pro", .data = "{\"mine\":true}" });

    const plan = try planInTmp(a, &tmp, false);
    try commit(a, plan, fakeOutputForTest());

    // The stub root is now the pushed sheet, the child was created, the
    // user's project file is untouched, and no fp-lib-table appeared.
    try testing.expectEqualStrings(netlisp_sheet, try tmp.dir.readFileAlloc(std.testing.io, "Board.kicad_sch", a, .limited64(4096)));
    try testing.expectEqualStrings(netlisp_sheet, try tmp.dir.readFileAlloc(std.testing.io, "Board-Core.kicad_sch", a, .limited64(4096)));
    try testing.expectEqualStrings("{\"mine\":true}", try tmp.dir.readFileAlloc(std.testing.io, "Board.kicad_pro", a, .limited64(4096)));
    try testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(std.testing.io, "fp-lib-table", a, .limited64(4096)));
    // The replaced stub is recoverable from the same backups/ folder the board
    // sync rolls into, and no staging file survived.
    try testing.expect(try backupHoldsStub(a, tmp.dir));
    try testing.expect(!try anyTempLeftBehind(tmp.dir));
}

/// (test helper) True when `backups/` holds a copy of the pre-push stub.
fn backupHoldsStub(a: std.mem.Allocator, dir: std.Io.Dir) !bool {
    var bdir = dir.openDir(std.testing.io, "backups", .{ .iterate = true }) catch return false;
    defer bdir.close(std.testing.io);
    var it = bdir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "Board.kicad_sch.bak-")) continue;
        const got = try bdir.readFileAlloc(std.testing.io, entry.name, a, .limited64(4096));
        return std.mem.eql(u8, got, stub_sheet);
    }
    return false;
}

/// (test helper) True when a staging file survived the push.
///
/// `infra/atomic_write.zig` stages into `AtomicFile`'s temporary, whose
/// basename is a random `u64` printed as 16 lowercase hex digits with no
/// extension — a shape no file this push publishes can wear. A committed or
/// abandoned transaction unlinks it; one that leaked is what this finds.
fn anyTempLeftBehind(dir: std.Io.Dir) !bool {
    var it = dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        if (entry.name.len != 16) continue;
        for (entry.name) |c| {
            if (!std.ascii.isHex(c)) break;
        } else return true;
    }
    return false;
}

// spec: kicad_sch_push - A refused plan writes nothing at all, so one blocked sheet can never leave a torn set of sheets behind
test "kicad-sch push: a refused plan leaves the directory byte-identical" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // The ROOT is fine (a stub) and the CHILD is hand-drawn: a per-file policy
    // would have replaced the root before discovering the block.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Board.kicad_sch", .data = stub_sheet });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Board-Core.kicad_sch", .data = drawn_sheet });

    const plan = try planInTmp(a, &tmp, false);
    try testing.expect(plan.refusal != null);
    try commit(a, plan, fakeOutputForTest());

    try testing.expectEqualStrings(stub_sheet, try tmp.dir.readFileAlloc(std.testing.io, "Board.kicad_sch", a, .limited64(4096)));
    try testing.expectEqualStrings(drawn_sheet, try tmp.dir.readFileAlloc(std.testing.io, "Board-Core.kicad_sch", a, .limited64(4096)));
    try testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(std.testing.io, "sym-lib-table", a, .limited64(4096)));
    try testing.expect(!try anyTempLeftBehind(tmp.dir));
}
