//! ZIX Http1 TLS peer slot
//!
//! ### file: src/zix/tcp/http1/TlsPeerSlot.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One fd entry of the TLS peer registry: the lock that serializes writes on
//! the connection, and the function that seals and sends.
//!
//! ### note:
//!
//! All zero bytes is a valid empty, unlocked slot, so the registry maps its
//! slots zeroed.
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

// --------------------------------------------------------- //
// Fields:

/// Serializes every seal and write on this connection: the owner and any
/// broadcaster take it.
lock: std.Io.Mutex = .init,
/// The io the owner registered with, used for the futex wait.
io: std.Io = undefined,
/// The concrete connection state behind write_fn.
ctx: ?*anyopaque = null,
/// Seal and send plaintext on this connection. The caller holds lock.
write_fn: ?WriteFn = null,
/// Set while a TLS connection is registered on this fd.
active: std.atomic.Value(bool) = .init(false),
/// Set while fd is a TLS socket at all, registered or not. A write to it that
/// no TLS writer takes is refused, never sent as plaintext.
tls: std.atomic.Value(bool) = .init(false),

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Seal and send plaintext. False when the connection is gone.
pub const WriteFn = *const fn (ctx: *anyopaque, plaintext: []const u8) bool;

/// Take the slot lock.
pub fn acquire(self: *Self) void {
    self.lock.lockUncancelable(self.io);
}

/// Drop the slot lock.
pub fn release(self: *Self) void {
    self.lock.unlock(self.io);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1: TlsPeerSlot, all zero bytes is an empty unlocked slot" {
    var bytes: [@sizeOf(Self)]u8 align(@alignOf(Self)) = @splat(0);
    const slot: *Self = @ptrCast(&bytes);

    try std.testing.expect(!slot.active.load(.acquire));
    try std.testing.expect(slot.lock.tryLock());
}

test "zix http1: TlsPeerSlot, acquire then release unlocks" {
    var slot: Self = .{ .io = std.testing.io };

    slot.acquire();
    try std.testing.expect(!slot.lock.tryLock());

    slot.release();
    try std.testing.expect(slot.lock.tryLock());
}

