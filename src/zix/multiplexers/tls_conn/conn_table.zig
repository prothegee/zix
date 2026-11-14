//! ZIX multiplexers tls connection table
//!
//! ### file: src/zix/multiplexers/tls_conn/conn_table.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Per-worker fd to connection map over a demand-paged pointer slab.
//!
//! ### note:
//!
//! Shared-nothing: one worker owns a connection for its whole lifetime.
//! Untouched slots cost no physical memory.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const slab = @import("../slab.zig");

// --------------------------------------------------------- //
// Public:

/// ZIX multiplexers connection table error
pub const Error = error {
    ZixMultiplexers_ConnTable_OutOfMemory,
    ZixMultiplexers_ConnTable_MapFailed,
};

/// The fd to connection table type for one engine connection type.
///
/// Param:
/// Conn - type (the engine's per-connection object)
/// max_fd - usize (slot count, indexed by fd)
/// free_conn - fn (releases one conn: payload, transport buffer, then the object)
///
/// Return:
/// - type
pub fn ConnTable(
    comptime Conn: type,
    comptime max_fd: usize,
    comptime free_conn: fn (*Conn) void,
) type {
    return struct {
        slots: []?*Conn,

        const Self = @This();

        pub fn init() Error!Self {
            const slots = slab.mapZeroedSlots(?*Conn, max_fd) catch |err| switch (err) {
                error.ZixUtils_Slab_OutOfMemory,
                => return Error.ZixMultiplexers_ConnTable_OutOfMemory,
                error.ZixUtils_Slab_MapFailed,
                => return Error.ZixMultiplexers_ConnTable_MapFailed,
            };

            return .{ .slots = slots };
        }

        /// Free every live connection, then unmap the slots.
        pub fn deinit(self: *Self) void {
            for (self.slots) |maybe| {
                if (maybe) |conn| free_conn(conn);
            }

            slab.unmapSlots(self.slots);
        }

        /// The connection on fd, or null when none or out of range.
        pub fn get(self: *Self, fd: std.posix.fd_t) ?*Conn {
            if (fd < 0) return null;

            const index: usize = @intCast(fd);
            if (index >= self.slots.len) return null;

            return self.slots[index];
        }

        /// Store conn at fd. The caller checked fd is in range.
        pub fn put(self: *Self, fd: std.posix.fd_t, conn: *Conn) void {
            self.slots[@intCast(fd)] = conn;
        }

        /// Free the connection at fd, if any, and empty the slot.
        pub fn drop(self: *Self, fd: std.posix.fd_t) void {
            if (fd < 0) return;

            const index: usize = @intCast(fd);
            if (index >= self.slots.len) return;

            if (self.slots[index]) |conn| free_conn(conn);
            self.slots[index] = null;
        }
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Probe = struct {
    id: u32,

    var freed: usize = 0;

    fn freeConn(conn: *Probe) void {
        freed += 1;
        std.testing.allocator.destroy(conn);
    }
};

const ProbeTable = ConnTable(Probe, 64, Probe.freeConn);

test "zix multiplexers: ConnTable, put then get returns the connection" {
    var table = try ProbeTable.init();
    defer table.deinit();

    const conn = try std.testing.allocator.create(Probe);
    conn.* = .{ .id = 7 };
    table.put(7, conn);

    try std.testing.expectEqual(conn, table.get(7).?);
}

test "zix multiplexers: ConnTable, empty slot is null" {
    var table = try ProbeTable.init();
    defer table.deinit();

    try std.testing.expectEqual(@as(?*Probe, null), table.get(8));
}

test "zix multiplexers: ConnTable, out of range fd is null" {
    var table = try ProbeTable.init();
    defer table.deinit();

    try std.testing.expectEqual(@as(?*Probe, null), table.get(9999));
    try std.testing.expectEqual(@as(?*Probe, null), table.get(-1));
}

test "zix multiplexers: ConnTable, drop frees through free_conn" {
    var table = try ProbeTable.init();
    defer table.deinit();

    Probe.freed = 0;
    const conn = try std.testing.allocator.create(Probe);
    conn.* = .{ .id = 3 };
    table.put(3, conn);
    table.drop(3);

    try std.testing.expectEqual(@as(?*Probe, null), table.get(3));
    try std.testing.expectEqual(@as(usize, 1), Probe.freed);
}

test "zix multiplexers: ConnTable, deinit frees live connections" {
    var table = try ProbeTable.init();

    Probe.freed = 0;
    const conn = try std.testing.allocator.create(Probe);
    conn.* = .{ .id = 5 };
    table.put(5, conn);
    table.deinit();

    try std.testing.expectEqual(@as(usize, 1), Probe.freed);
}

test "zix multiplexers: ConnTable, drop out of range is a no-op" {
    var table = try ProbeTable.init();
    defer table.deinit();

    Probe.freed = 0;
    table.drop(9999);
    table.drop(-1);

    try std.testing.expectEqual(@as(usize, 0), Probe.freed);
}

