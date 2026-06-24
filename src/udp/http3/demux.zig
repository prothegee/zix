//! zix HTTP/3 connection-id demux (the v1 single-worker CID table).
//!
//! What:
//! - A QUIC connection is keyed by its Destination Connection ID, not by a socket. The v1 engine runs
//!   one recv worker that owns this table: every datagram for every connection arrives here, so a
//!   4-tuple change (connection migration) is just a new peer address on an existing CID, with no
//!   cross-core routing needed. Per-core CID sharding is v2 (ADR-049 phase 3).
//!
//! Note:
//! - The table is a fixed-capacity linear scan. It is the v1 single-worker structure, sized for one
//!   worker's connections. A hashed / per-core variant follows with the steering work.

const std = @import("std");

/// A QUIC connection ID, up to 20 bytes (RFC 9000 17.2).
pub const ConnId = struct {
    bytes: [20]u8 = undefined,
    len: u8 = 0,

    /// Build a ConnId from a byte slice, truncating at the 20-byte version-1 maximum.
    pub fn fromSlice(source: []const u8) ConnId {
        var id = ConnId{ .len = @intCast(@min(source.len, 20)) };
        @memcpy(id.bytes[0..id.len], source[0..id.len]);

        return id;
    }

    /// The connection ID bytes.
    pub fn slice(self: *const ConnId) []const u8 {
        return self.bytes[0..self.len];
    }

    /// Whether two connection IDs are byte-equal.
    pub fn eql(self: *const ConnId, other: *const ConnId) bool {
        return self.len == other.len and std.mem.eql(u8, self.slice(), other.slice());
    }
};

/// A fixed-capacity CID-keyed table of `T`, owned by one recv worker. Returns null on overflow rather
/// than allocating, so the caller can apply an admission policy.
pub fn Table(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        ids: [capacity]ConnId = undefined,
        values: [capacity]T = undefined,
        count: usize = 0,

        /// Find the value owned by `id`, or null.
        pub fn find(self: *Self, id: *const ConnId) ?*T {
            for (0..self.count) |i| {
                if (self.ids[i].eql(id)) return &self.values[i];
            }

            return null;
        }

        /// Insert a value under `id`. Returns the stored slot, or null when the table is full.
        pub fn put(self: *Self, id: ConnId, value: T) ?*T {
            if (self.count >= capacity) return null;

            self.ids[self.count] = id;
            self.values[self.count] = value;
            self.count += 1;

            return &self.values[self.count - 1];
        }
    };
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

test "zix test: ConnId build, slice, and equality" {
    const a = ConnId.fromSlice(&[_]u8{ 1, 2, 3, 4 });
    const b = ConnId.fromSlice(&[_]u8{ 1, 2, 3, 4 });
    const c = ConnId.fromSlice(&[_]u8{ 1, 2, 3, 5 });

    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, a.slice());
    try std.testing.expect(a.eql(&b));
    try std.testing.expect(!a.eql(&c));
}

test "zix test: CID table put and find" {
    var table = Table(u32, 4){};
    const id1 = ConnId.fromSlice(&[_]u8{ 0xaa, 0xbb });
    const id2 = ConnId.fromSlice(&[_]u8{ 0xcc, 0xdd });

    _ = table.put(id1, 100);
    _ = table.put(id2, 200);

    try std.testing.expectEqual(@as(u32, 100), table.find(&id1).?.*);
    try std.testing.expectEqual(@as(u32, 200), table.find(&id2).?.*);

    const missing = ConnId.fromSlice(&[_]u8{0xff});
    try std.testing.expect(table.find(&missing) == null);
}
