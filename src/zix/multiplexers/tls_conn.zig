//! ZIX multiplexers tls connection
//!
//! ### file: src/zix/multiplexers/tls_conn.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Shared TLS connection machinery for the multiplexed serve paths: the byte
//! transport, the fd to connection table, and the EPOLLOUT re-arm.
//!
//! ### note:
//!
//! Engine loops stay per engine. They feed this module instead of each owning
//! a copy of the transport.
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
const builtin = @import("builtin");

const linux = std.os.linux;

// --------------------------------------------------------- //
// Public:

/// Inbound ciphertext read staging (may hold several records per read).
pub const READ_STAGING_SIZE: usize = 32 * 1024;

/// Event data tag for TLS connections in a dual-listener loop (bit 63). No fd
/// and no user-space pointer has it set, so a loop that keys cleartext
/// connections by pointer can still route TLS events. TLS-only workers register
/// plain fds (tag 0).
pub const TLS_EVENT_TAG: u64 = 1 << 63;

/// First size of the per-connection outbound ciphertext buffer, grown on demand.
pub const WRITE_BUF_INITIAL: usize = 16 * 1024;

/// The TLS byte transport of one multiplexed connection.
pub const Transport = @import("tls_conn/Transport.zig");

/// The fd to connection table type for one engine connection type.
pub const ConnTable = @import("tls_conn/conn_table.zig").ConnTable;

/// Re-arm a connection's epoll registration with or without EPOLLOUT, keeping
/// the data word it was registered with.
///
/// Note:
/// - Best effort: a failed re-arm leaves the old registration, and the next
///   event on the connection retries.
///
/// Param:
/// epfd - std.posix.fd_t (the worker epoll instance)
/// fd - std.posix.fd_t (the connection)
/// data - u64 (the registered data word, tag included)
/// on - bool (ask for EPOLLOUT)
pub fn armOut(epfd: std.posix.fd_t, fd: std.posix.fd_t, data: u64, on: bool) void {
    var flags: u32 = linux.EPOLL.IN | linux.EPOLL.RDHUP;
    if (on) flags |= linux.EPOLL.OUT;

    var event = linux.epoll_event{
        .events = flags,
        .data = .{ .u64 = data },
    };
    const rc = linux.epoll_ctl(epfd, linux.EPOLL.CTL_MOD, fd, &event);

    switch (std.posix.errno(rc)) {
        else => {},
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix multiplexers: tls_conn, TLS_EVENT_TAG sits above any fd" {
    try std.testing.expect(TLS_EVENT_TAG > std.math.maxInt(u31));
}

test "zix multiplexers: tls_conn, TLS_EVENT_TAG sits above any user-space pointer" {
    try std.testing.expect(TLS_EVENT_TAG > (1 << 57));
}

test "zix multiplexers: tls_conn, armOut keeps the data word" {
    if (comptime builtin.os.tag != .linux) return;

    const epfd: std.posix.fd_t = @intCast(linux.epoll_create1(linux.EPOLL.CLOEXEC));
    defer _ = linux.close(epfd);

    var fds: [2]std.posix.fd_t = undefined;
    try @import("../utils/socket/pair.zig").open(std.testing.io, &fds);
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    var add = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .u64 = TLS_EVENT_TAG | 9 },
    };
    _ = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, fds[0], &add);

    armOut(epfd, fds[0], TLS_EVENT_TAG | 9, true);

    var events: [1]linux.epoll_event = undefined;
    const ready = linux.epoll_wait(epfd, &events, 1, 0);

    try std.testing.expectEqual(@as(usize, 1), ready);
    try std.testing.expectEqual(TLS_EVENT_TAG | 9, events[0].data.u64);
    try std.testing.expect(events[0].events & linux.EPOLL.OUT != 0);
}

test "zix multiplexers: tls_conn, armOut on a bad fd is a no-op" {
    if (comptime builtin.os.tag != .linux) return;

    armOut(-1, -1, 0, true);
}

