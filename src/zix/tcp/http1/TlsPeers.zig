//! ZIX Http1 TLS peers
//!
//! ### file: src/zix/tcp/http1/TlsPeers.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Process-wide fd to TLS connection registry, so a write to another TLS
//! connection (WebSocket broadcast) is sealed with that connection session.
//!
//! ### note:
//!
//! Every write to a registered fd, from the owner or from another thread, runs
//! under the slot lock: one session, one record sequence, one writer at a time.
//! A connection unregisters before its fd closes, so a reused fd never reaches
//! a freed session.
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
const TlsPeerSlot = @import("TlsPeerSlot.zig");
const slab = @import("../../multiplexers/slab.zig");

// --------------------------------------------------------- //
// Fields:

/// One slot per fd, mapped zeroed on the first register.
slots: []TlsPeerSlot = &.{},
/// Set once slots is mapped.
ready: std.atomic.Value(bool) = .init(false),
/// Guards the one-time mapping.
mapping: std.atomic.Value(bool) = .init(false),

const Self = @This();

// --------------------------------------------------------- //
// Private:

const MAX_FD: usize = 1 << 16;

fn slotFor(self: *Self, fd: std.posix.fd_t) ?*TlsPeerSlot {
    if (!self.ready.load(.acquire)) return null;
    if (fd < 0) return null;

    const index: usize = @intCast(fd);
    if (index >= self.slots.len) return null;

    return &self.slots[index];
}

/// Map the slots once. Concurrent callers wait for the first one.
fn ensureMapped(self: *Self) Error!void {
    if (self.ready.load(.acquire)) return;

    while (self.mapping.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
    defer self.mapping.store(false, .release);

    if (self.ready.load(.acquire)) return;

    self.slots = slab.mapZeroedSlots(TlsPeerSlot, MAX_FD) catch |err| switch (err) {
        error.ZixUtils_Slab_OutOfMemory => return Error.ZixHttp1_TlsPeers_OutOfMemory,
        error.ZixUtils_Slab_MapFailed => return Error.ZixHttp1_TlsPeers_MapFailed,
    };
    self.ready.store(true, .release);
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http1 TLS peers error
pub const Error = error {
    ZixHttp1_TlsPeers_OutOfMemory,
    ZixHttp1_TlsPeers_MapFailed,
    ZixHttp1_TlsPeers_FdOutOfRange,
};

/// The process-wide registry. Rooms span worker threads, so one table serves all.
pub var shared: Self = .{};

/// Register a TLS connection on fd, so writes to fd from any thread are sealed
/// with its session under its lock.
///
/// Param:
/// fd - std.posix.fd_t (the connection socket)
/// io - std.Io (the owner io, used for the lock wait)
/// ctx - *anyopaque (the connection state behind write_fn)
/// write_fn - TlsPeerSlot.WriteFn (seal and send, called with the lock held)
///
/// Return:
/// - void
/// - Error.ZixHttp1_TlsPeers_FdOutOfRange past the table
/// - Error.ZixHttp1_TlsPeers_OutOfMemory or MapFailed on the first call
pub fn register(
    self: *Self,
    fd: std.posix.fd_t,
    io: std.Io,
    ctx: *anyopaque,
    write_fn: TlsPeerSlot.WriteFn,
) Error!void {
    try self.ensureMapped();

    const slot = self.slotFor(fd) orelse return Error.ZixHttp1_TlsPeers_FdOutOfRange;

    slot.io = io;
    slot.acquire();
    defer slot.release();

    slot.ctx = ctx;
    slot.write_fn = write_fn;
    slot.active.store(true, .release);
}

/// Mark fd as a TLS socket from accept on, before it has a registered writer.
///
/// Note:
/// - Best effort: when the table cannot be mapped the mark is skipped.
pub fn mark(self: *Self, fd: std.posix.fd_t) void {
    self.ensureMapped() catch |err| switch (err) {
        else => return,
    };

    const slot = self.slotFor(fd) orelse return;

    slot.tls.store(true, .release);
}

/// Whether fd is a TLS socket (marked or registered).
pub fn isTls(self: *Self, fd: std.posix.fd_t) bool {
    const slot = self.slotFor(fd) orelse return false;

    return slot.tls.load(.acquire) or slot.active.load(.acquire);
}

/// Remove the connection on fd and its TLS mark. Waits for a write in
/// progress, so the connection state can be freed right after. Call before fd
/// closes, so a reused fd starts clean.
pub fn unregister(self: *Self, fd: std.posix.fd_t) void {
    const slot = self.slotFor(fd) orelse return;

    slot.tls.store(false, .release);
    if (!slot.active.load(.acquire)) return;

    slot.acquire();
    defer slot.release();

    slot.active.store(false, .release);
    slot.ctx = null;
    slot.write_fn = null;
}

/// Whether a TLS connection is registered on fd.
pub fn has(self: *Self, fd: std.posix.fd_t) bool {
    const slot = self.slotFor(fd) orelse return false;

    return slot.active.load(.acquire);
}

/// Lock the slot of a registered connection, for owner work that touches the
/// session or the staged ciphertext outside write.
///
/// Return:
/// - *TlsPeerSlot (locked, call release)
/// - null when fd is not registered
pub fn acquire(self: *Self, fd: std.posix.fd_t) ?*TlsPeerSlot {
    const slot = self.slotFor(fd) orelse return null;
    if (!slot.active.load(.acquire)) return null;

    slot.acquire();
    if (!slot.active.load(.acquire)) {
        slot.release();

        return null;
    }

    return slot;
}

/// Seal and send plaintext on the connection registered on fd.
///
/// Return:
/// - true when sent
/// - false when the connection refused the write
/// - null when fd is not registered
pub fn write(self: *Self, fd: std.posix.fd_t, bytes: []const u8) ?bool {
    const slot = self.acquire(fd) orelse return null;
    defer slot.release();

    return slot.write_fn.?(slot.ctx.?, bytes);
}

/// Unmap the slots. Only for a registry that no thread uses any more.
pub fn deinit(self: *Self) void {
    if (!self.ready.load(.acquire)) return;

    slab.unmapSlots(self.slots);
    self.slots = &.{};
    self.ready.store(false, .release);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Collector = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    fn write(ctx: *anyopaque, plaintext: []const u8) bool {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        if (self.len + plaintext.len > self.buf.len) return false;

        @memcpy(self.buf[self.len..][0..plaintext.len], plaintext);
        self.len += plaintext.len;

        return true;
    }
};

const Counter = struct {
    value: usize = 0,

    fn write(ctx: *anyopaque, plaintext: []const u8) bool {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        const before = self.value;
        std.atomic.spinLoopHint();
        self.value = before + plaintext.len;

        return true;
    }
};

fn hammer(peers: *Self, fd: std.posix.fd_t, rounds: usize) void {
    for (0..rounds) |_| _ = peers.write(fd, "x");
}

test "zix http1: TlsPeers, an empty registry knows no fd" {
    var peers: Self = .{};

    try std.testing.expect(!peers.has(5));
    try std.testing.expect(peers.write(5, "x") == null);
}

test "zix http1: TlsPeers, write reaches the registered connection" {
    var peers: Self = .{};
    defer peers.deinit();

    var collector: Collector = .{};
    try peers.register(7, std.testing.io, &collector, Collector.write);

    try std.testing.expect(peers.has(7));
    try std.testing.expectEqual(@as(?bool, true), peers.write(7, "hello"));
    try std.testing.expectEqualStrings("hello", collector.buf[0..collector.len]);
}

test "zix http1: TlsPeers, unregister stops routing" {
    var peers: Self = .{};
    defer peers.deinit();

    var collector: Collector = .{};
    try peers.register(7, std.testing.io, &collector, Collector.write);
    peers.unregister(7);

    try std.testing.expect(!peers.has(7));
    try std.testing.expect(peers.write(7, "late") == null);
    try std.testing.expectEqual(@as(usize, 0), collector.len);
}

test "zix http1: TlsPeers, an fd past the table is FdOutOfRange" {
    var peers: Self = .{};
    defer peers.deinit();

    var collector: Collector = .{};

    try std.testing.expectError(
        Error.ZixHttp1_TlsPeers_FdOutOfRange,
        peers.register(MAX_FD, std.testing.io, &collector, Collector.write),
    );
}

test "zix http1: TlsPeers, acquire on an unknown fd is null" {
    var peers: Self = .{};
    defer peers.deinit();

    var collector: Collector = .{};
    try peers.register(3, std.testing.io, &collector, Collector.write);

    try std.testing.expect(peers.acquire(4) == null);
    try std.testing.expect(peers.acquire(-1) == null);
}

test "zix http1: TlsPeers, writes from two threads never interleave" {
    var peers: Self = .{};
    defer peers.deinit();

    var counter: Counter = .{};
    try peers.register(9, std.testing.io, &counter, Counter.write);

    const rounds: usize = 20000;
    const first = try std.Thread.spawn(.{}, hammer, .{ &peers, 9, rounds });
    const second = try std.Thread.spawn(.{}, hammer, .{ &peers, 9, rounds });
    first.join();
    second.join();

    try std.testing.expectEqual(rounds * 2, counter.value);
}

test "zix http1: TlsPeers, a marked fd is TLS before it registers" {
    var peers: Self = .{};
    defer peers.deinit();

    peers.mark(11);

    try std.testing.expect(peers.isTls(11));
    try std.testing.expect(!peers.has(11));
    try std.testing.expect(peers.write(11, "x") == null);
}

test "zix http1: TlsPeers, unregister clears the TLS mark" {
    var peers: Self = .{};
    defer peers.deinit();

    peers.mark(12);
    peers.unregister(12);

    try std.testing.expect(!peers.isTls(12));
}

