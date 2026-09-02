//! Republishing a design's `.layouts.json` sidecar with user-save semantics.
//!
//! Two non-editor writers land a whole layout list — the history/git backfill
//! recovering lost boards, and the `import-kicad-layout` seam claiming the star
//! for a routed KiCad board — and each had its own copy of the transaction.
//! Every line of it is load-bearing and none of it is obvious:
//!
//!   * the rev read, the row merge and the rename are ONE hold on the sidecar
//!     lock. Without that, a concurrent editor save lands between the read and
//!     the rename and this pass republishes `rev + 1` over it — the lost update
//!     the lock exists to stop. The readers used inside take no lock of their
//!     own, so calling them under the hold cannot re-enter it.
//!   * `rev` is bumped, which 409s any editor tab still holding the old one
//!     instead of letting it clobber what was just written.
//!   * the optimizer cache slot rides along unchanged.
//!   * the file is replaced by tmp→rename, so a reader sees the old or the new
//!     sidecar whole, never a prefix.
//!
//! The rows are produced by a caller callback rather than passed in, because a
//! writer that MERGES with the sidecar's current contents has to read them
//! inside the same hold — passing a finished list would put that read outside
//! it and reintroduce the lost update.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const paths = @import("../paths.zig");
const page = @import("pcb_layout_page.zig");
const history = @import("history.zig");
const sidecar_store = @import("../layout_sidecar_store.zig");

/// How a publish differs between its callers. Everything else about the
/// transaction is fixed: differing on the rest is what the two copies did.
pub const Options = struct {
    /// Roll the sidecar being replaced into `history/` first, so the write is
    /// itself undoable from the design's history. Callers whose own source is
    /// the system of record (a KiCad board being imported) leave it off: the
    /// board they came from is the recovery path.
    snapshot_previous: bool = false,
};

/// Publish the design's layout sidecar at `rev + 1`.
///
/// `rows(ctx, alloc)` is called INSIDE the hold and returns the full list to
/// write, or null to abandon the publish (leaving the sidecar untouched).
/// Returns false when any step failed, in which case nothing was replaced.
pub fn publish(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    opts: Options,
    ctx: anytype,
    comptime rows: anytype,
) bool {
    const path = paths.designSiblingPath(alloc, project_dir, name, page.layouts_ext) catch return false;
    defer alloc.free(path);

    const guard = sidecar_store.lockSidecar(name, null);
    defer guard.unlock();
    if (opts.snapshot_previous) _ = history.snapshotLayouts(alloc, project_dir, name, path) catch null;
    const rev = page.readLayoutRev(alloc, project_dir, name, null);
    const cache = page.readCacheSlot(alloc, project_dir, name);
    const layouts = rows(ctx, alloc) orelse return false;

    var aw: std.Io.Writer.Allocating = .init(alloc);
    page.writeLayoutsFileJsonRev(&aw.writer, layouts, cache, rev + 1) catch return false;
    writeFileAtomic(path, aw.written()) catch return false;
    return true;
}

/// Atomic tmp→rename write, so a reader always sees the old or new file whole.
fn writeFileAtomic(path: []const u8, data: []const u8) !void {
    var write_buf: [4096]u8 = undefined;
    var atomic = try infra_fs.cwd().atomicFile(path, .{ .write_buffer = &write_buf });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(data);
    try atomic.finish();
}
