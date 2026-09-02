//! `YYYY-MM-DDTHH-MM-SS` — the one wall-clock stamp netlisp puts in a
//! filename.
//!
//! It is filesystem-safe (no `:`) and lexicographically sortable, which is the
//! whole point: history snapshot ids and board-backup filenames are ordered by
//! sorting their names, so any two producers of a stamp MUST agree on the
//! format down to the separator. They were two copies of the same
//! `std.time.epoch` arithmetic, one taking an epoch-second argument and the
//! other reading the clock itself — a divergence in either would have silently
//! misordered a prune.

const std = @import("std");
const clock = @import("../infra/clock.zig");

/// Render `epoch_sec` (UTC) as the sortable stamp. Caller owns the result.
pub fn fromEpochSeconds(allocator: std.mem.Allocator, epoch_sec: u64) std.mem.Allocator.Error![]u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_sec };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_sec = es.getDaySeconds();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}-{d:0>2}-{d:0>2}", .{
        @as(u32, year_day.year),
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        day_sec.getHoursIntoDay(),
        day_sec.getMinutesIntoHour(),
        day_sec.getSecondsIntoMinute(),
    });
}

/// The stamp for right now. A clock reading before the epoch (an unset RTC)
/// stamps as the epoch rather than wrapping into a far-future name that would
/// sort ahead of every real one.
pub fn now(allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
    const sec = clock.timestamp();
    return fromEpochSeconds(allocator, if (sec < 0) 0 else @intCast(sec));
}
