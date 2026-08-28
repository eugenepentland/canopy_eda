//! The content fingerprint every copper memo keys on.
//!
//! Two memos now share it: `fill_cache` keys a WHOLE board (its reflective walk
//! over `Placement` + `RouteResult` + the user zones), and `pour` keys ONE fill
//! (the exact features that fill's raster consumed). They must agree on what a
//! fingerprint is, because a wrong answer from either is a silently wrong DRC
//! verdict — so the hasher, the two-hash width, and the reflective walk live
//! here once rather than being spelled twice.
//!
//! Two independent 64-bit hashes rather than one because a memo that answers
//! with the WRONG copper is a silently wrong DRC verdict, and 64 bits is not
//! enough margin against that failure mode — the route-space cache keys the same
//! way for the same reason.

const std = @import("std");

/// A 128-bit content fingerprint. Equality of two keys is the memo's entire
/// claim that two inputs are the same input.
pub const Key = struct {
    lo: u64,
    hi: u64,

    /// Do these two keys claim the same content? The whole memo rests on this
    /// answer, which is why the key is 128 bits wide rather than 64.
    pub fn eql(a: Key, b: Key) bool {
        return a.lo == b.lo and a.hi == b.hi;
    }
};

/// Two Wyhash states fed identical bytes through one small buffer. The buffer
/// is what makes a reflective walk affordable: per-scalar `update` calls cost
/// more in call overhead than in hashing, and a dense board's fingerprint is
/// hundreds of thousands of scalars.
pub const Fingerprint = struct {
    lo: std.hash.Wyhash = std.hash.Wyhash.init(0x243f6a8885a308d3),
    hi: std.hash.Wyhash = std.hash.Wyhash.init(0x13198a2e03707344),
    buf: [512]u8 = @splat(0),
    len: usize = 0,

    /// Fold raw bytes in. Everything else here reduces to this call, buffered
    /// so a walk of hundreds of thousands of scalars is not that many calls
    /// into the hash itself.
    pub fn add(self: *Fingerprint, bytes: []const u8) void {
        if (bytes.len > self.buf.len - self.len) self.flush();
        if (bytes.len > self.buf.len) {
            self.lo.update(bytes);
            self.hi.update(bytes);
            return;
        }
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    /// Fold one value of any fingerprintable type in (see `hashValue`).
    pub fn put(self: *Fingerprint, comptime T: type, value: T) void {
        hashValue(self, T, value);
    }

    /// Fold a discriminating marker in, so two adjacent runs of scalars from
    /// different feature kinds cannot alias into one another's bytes.
    pub fn tag(self: *Fingerprint, marker: u8) void {
        self.add(&[_]u8{marker});
    }

    fn flush(self: *Fingerprint) void {
        self.lo.update(self.buf[0..self.len]);
        self.hi.update(self.buf[0..self.len]);
        self.len = 0;
    }

    /// Close the fingerprint and read the 128-bit key it accumulated.
    pub fn final(self: *Fingerprint) Key {
        self.flush();
        return .{ .lo = self.lo.final(), .hi = self.hi.final() };
    }
};

/// A type whose in-memory bytes ARE its value — no pointer to follow, no
/// padding to read as garbage — so a slice of it folds in with one `add`
/// instead of one per element field. This is what keeps the polygon, label and
/// margin arrays, the overwhelming bulk of the input, cheap to fingerprint.
fn flatBytes(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int => @bitSizeOf(T) == @sizeOf(T) * 8,
        .float => true,
        .array => |a| flatBytes(a.child) and @sizeOf(T) == a.len * @sizeOf(a.child),
        else => false,
    };
}

/// Reduce `value` to bytes and fold it in. A type this cannot reduce fails the
/// BUILD rather than going quietly unkeyed, so the next such field is a decision
/// somebody makes on purpose.
pub fn hashValue(fp: *Fingerprint, comptime T: type, value: T) void {
    switch (@typeInfo(T)) {
        .void => {},
        .bool => fp.add(&[_]u8{@intFromBool(value)}),
        .int => |i| {
            // Widened to a whole power-of-two byte width first: the storage of
            // a `u3` (an enum tag, say) has undefined padding bits, and folding
            // those in would make one board fingerprint differently per call.
            const wide: @Int(i.signedness, storageBits(i.bits)) = value;
            fp.add(std.mem.asBytes(&wide));
        },
        .float => fp.add(std.mem.asBytes(&value)[0 .. @bitSizeOf(T) / 8]),
        .@"enum" => |e| hashValue(fp, e.tag_type, @backingInt(value)),
        .optional => |o| if (value) |payload| {
            fp.add(&[_]u8{1});
            hashValue(fp, o.child, payload);
        } else fp.add(&[_]u8{0}),
        .array => |a| hashSlice(fp, a.child, &value),
        .@"struct" => |s| inline for (s.field_names, s.field_types) |name, Field| {
            hashValue(fp, Field, @field(value, name));
        },
        .@"union" => |u| {
            const Tag = u.tag_type orelse
                @compileError("content_key: untagged union " ++ @typeName(T) ++ " has no fingerprint");
            hashValue(fp, Tag, std.meta.activeTag(value));
            switch (value) {
                inline else => |payload| hashValue(fp, @TypeOf(payload), payload),
            }
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                hashValue(fp, usize, value.len);
                hashSlice(fp, p.child, value);
            },
            .one => hashValue(fp, p.child, value.*),
            else => @compileError(unkeyable(T)),
        },
        else => @compileError(unkeyable(T)),
    }
}

/// The smallest power-of-two byte width that holds `bits` — the widths for
/// which an integer's storage is exactly its value with no padding byte.
fn storageBits(comptime bits: u16) u16 {
    var whole: u16 = 8;
    while (whole < bits) whole *= 2;
    return whole;
}

/// The build-stopping message for a field this walk cannot reduce to bytes.
/// Deliberately a hard error: silently skipping it is how a memo would start
/// answering with a stale fill.
pub fn unkeyable(comptime T: type) []const u8 {
    return "content_key: " ++ @typeName(T) ++ " has no fingerprint — give it one, or name its" ++
        " field in the caller's skip list with the reason it cannot change the memoised result";
}

fn hashSlice(fp: *Fingerprint, comptime Child: type, items: []const Child) void {
    if (comptime flatBytes(Child)) return fp.add(std.mem.sliceAsBytes(items));
    for (items) |item| hashValue(fp, Child, item);
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: placement/fill-cache - the content fingerprint separates two values that differ in any fold-in and matches two independently built copies of one value
test "the fingerprint follows content, not identity" {
    const Nested = struct { name: []const u8, at: [2]f64, on: bool };
    const one = [_]Nested{ .{ .name = "GND", .at = .{ 1, 2 }, .on = true }, .{ .name = "VCC", .at = .{ 3, 4 }, .on = false } };
    // Separate storage, separate strings, identical content.
    const two = [_]Nested{ .{ .name = "GN" ++ "D", .at = .{ 1, 2 }, .on = true }, .{ .name = "VCC", .at = .{ 3, 4 }, .on = false } };
    var a: Fingerprint = .{};
    a.put([]const Nested, &one);
    var b: Fingerprint = .{};
    b.put([]const Nested, &two);
    try testing.expectEqual(a.final(), b.final());

    var moved: Fingerprint = .{};
    moved.put([]const Nested, &[_]Nested{ one[0], .{ .name = "VCC", .at = .{ 3.000001, 4 }, .on = false } });
    var again: Fingerprint = .{};
    again.put([]const Nested, &one);
    try testing.expect(!Key.eql(moved.final(), again.final()));
}

// spec: placement/fill-cache - a fingerprint tag separates two runs of otherwise identical scalars so adjacent feature kinds cannot alias
test "a tag separates two otherwise identical scalar runs" {
    var tagged: Fingerprint = .{};
    tagged.tag(7);
    tagged.put(f64, 1.5);
    var plain: Fingerprint = .{};
    plain.put(f64, 1.5);
    try testing.expect(!Key.eql(tagged.final(), plain.final()));
}
