//! ZIX Http1 ConnRegistry
//!
//! ### file: src/zix/tcp/http1/ConnRegistry.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Registry of live connections for the timeout sweep.
//! 
//! ### note:
//! 
//! n/a
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
const ConnEntry = @import("ConnEntry.zig");

// --------------------------------------------------------- //
// Fields:

mutex: std.Io.Mutex = .init,
entries: std.ArrayListUnmanaged(*ConnEntry) = .empty,

const Self = @This();

// --------------------------------------------------------- //
// Private:

// Deadline helpers. Adjust the .raw shape if std.Io.Clock.Timestamp
// changes in a future Zig version.
fn pastDeadline(io: std.Io) std.Io.Clock.Timestamp {
    // "now" is already at or before the "now" that evict reads, so
    // the compare(.gte) inside evict will always be true.
    return std.Io.Clock.Timestamp.now(io, .real);
}

fn futureDeadline() std.Io.Clock.Timestamp {
    // maxInt keeps this far beyond any test runtime, so evict will
    // never trigger.
    return .{
        .raw = .{ .nanoseconds = std.math.maxInt(i96) },
        .clock = .real,
    };
}

fn makeEntry(fd: std.posix.socket_t, deadline: std.Io.Clock.Timestamp) ConnEntry {
    // Adjust if ConnEntry requires additional fields.
    return .{
        .fd = fd,
        .deadline = deadline,
        .done = .init(false),
    };
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http1 connection registry error
pub const Error = error {
    ZixHttp1_ConnRegistry_OutOfMemory,
    ZixHttp1_ConnRegistry_ShutdownFailed,
};

pub fn register(self: *Self, entry: *ConnEntry, io: std.Io) Error!void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    self.entries.append(std.heap.smp_allocator, entry) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp1_ConnRegistry_OutOfMemory,
    };
}

pub fn deregister(self: *Self, entry: *ConnEntry, io: std.Io) void {
    entry.done.store(true, .release);

    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    for (self.entries.items, 0..) |candidate, i| {
        if (candidate == entry) {
            _ = self.entries.swapRemove(i);
            break;
        }
    }
}

/// Shut down every registered connection past its deadline. The blocked
/// serve loop then sees EOF and tears the connection down normally.
pub fn evict(self: *Self, io: std.Io) Error!void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);

    var shutdown_failed = false;
    const now = std.Io.Clock.Timestamp.now(io, .real);
    for (self.entries.items) |entry| {
        if (entry.done.load(.acquire) or !now.compare(.gte, entry.deadline)) continue;

        const rc = std.posix.system.shutdown(entry.fd, std.posix.SHUT.RDWR);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            else => shutdown_failed = true,
        }
    }

    if (shutdown_failed) return Error.ZixHttp1_ConnRegistry_ShutdownFailed;
}

pub fn deinit(self: *Self) void {
    self.entries.deinit(std.heap.smp_allocator);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../utils/socket/pair.zig");

test "zix http1: ConnRegistry, register appends entry" {
    const io = std.testing.io;
    var registry: Self = .{};
    defer registry.deinit();

    var entry = makeEntry(0, pastDeadline(io));

    try registry.register(&entry, io);

    try std.testing.expectEqual(1, registry.entries.items.len);
    try std.testing.expectEqual(&entry, registry.entries.items[0]);
}

test "zix http1: ConnRegistry, register preserves insertion order" {
    const io = std.testing.io;
    var registry: Self = .{};
    defer registry.deinit();

    var entry_a = makeEntry(0, pastDeadline(io));
    var entry_b = makeEntry(0, pastDeadline(io));
    var entry_c = makeEntry(0, pastDeadline(io));

    try registry.register(&entry_a, io);
    try registry.register(&entry_b, io);
    try registry.register(&entry_c, io);

    try std.testing.expectEqual(3, registry.entries.items.len);
    try std.testing.expectEqual(&entry_a, registry.entries.items[0]);
    try std.testing.expectEqual(&entry_b, registry.entries.items[1]);
    try std.testing.expectEqual(&entry_c, registry.entries.items[2]);
}

test "zix http1: ConnRegistry, deregister completes the entry" {
    const io = std.testing.io;
    var registry: Self = .{};
    defer registry.deinit();

    var entry = makeEntry(0, pastDeadline(io));
    try registry.register(&entry, io);

    registry.deregister(&entry, io);

    try std.testing.expect(entry.done.load(.acquire));
    try std.testing.expectEqual(0, registry.entries.items.len);
}

test "zix http1: ConnRegistry, deregister leaves other entries intact" {
    const io = std.testing.io;
    var registry: Self = .{};
    defer registry.deinit();

    var entry_a = makeEntry(0, pastDeadline(io));
    var entry_b = makeEntry(0, pastDeadline(io));
    try registry.register(&entry_a, io);
    try registry.register(&entry_b, io);

    registry.deregister(&entry_a, io);

    try std.testing.expect(entry_a.done.load(.acquire));
    try std.testing.expect(!entry_b.done.load(.acquire));
    try std.testing.expectEqual(1, registry.entries.items.len);
    try std.testing.expectEqual(&entry_b, registry.entries.items[0]);
}

test "zix http1: ConnRegistry, deregister ignores an unknown entry" {
    const io = std.testing.io;
    var registry: Self = .{};
    defer registry.deinit();

    var entry = makeEntry(0, pastDeadline(io));
    var other = makeEntry(0, pastDeadline(io));
    try registry.register(&entry, io);

    registry.deregister(&other, io);

    try std.testing.expect(!entry.done.load(.acquire));
    try std.testing.expectEqual(1, registry.entries.items.len);
}

test "zix http1: ConnRegistry, evict shuts down a past-deadline entry" {
    const io = std.testing.io;
    var registry: Self = .{};
    defer registry.deinit();

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(io, &fds);
    defer _ = std.posix.system.close(fds[1]);
    defer _ = std.posix.system.close(fds[0]);

    var entry = makeEntry(fds[0], pastDeadline(io));
    try registry.register(&entry, io);

    try registry.evict(io);

    // The peer sees EOF after the local end is shut down.
    var buf: [1]u8 = undefined;
    const bytes_read = try std.posix.read(fds[1], &buf);

    try std.testing.expectEqual(0, bytes_read);
}

test "zix http1: ConnRegistry, evict skips a done entry" {
    const io = std.testing.io;
    var registry: Self = .{};
    defer registry.deinit();

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(io, &fds);
    defer _ = std.posix.system.close(fds[1]);
    defer _ = std.posix.system.close(fds[0]);

    var entry = makeEntry(fds[0], pastDeadline(io));
    entry.done.store(true, .release);
    try registry.register(&entry, io);

    try registry.evict(io);

    // No shutdown happened, so the peer stays idle (poll times out).
    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = fds[1], .events = std.posix.POLL.IN, .revents = 0 },
    };
    const ready = try std.posix.poll(&poll_fds, 10);

    try std.testing.expectEqual(0, ready);
}

test "zix http1: ConnRegistry, evict skips a future-deadline entry" {
    const io = std.testing.io;
    var registry: Self = .{};
    defer registry.deinit();

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(io, &fds);
    defer _ = std.posix.system.close(fds[1]);
    defer _ = std.posix.system.close(fds[0]);

    var entry = makeEntry(fds[0], futureDeadline());
    try registry.register(&entry, io);

    try registry.evict(io);

    // Deadline not reached, so shutdown was not called.
    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = fds[1], .events = std.posix.POLL.IN, .revents = 0 },
    };
    const ready = try std.posix.poll(&poll_fds, 10);

    try std.testing.expectEqual(0, ready);
}

