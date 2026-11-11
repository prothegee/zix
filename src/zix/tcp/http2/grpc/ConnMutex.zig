//! ZIX Http2 Grpc ConnMutex
//!
//! ### file: src/zix/tcp/http2/grpc/ConnMutex.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Ref-counted write spinlock for one connection, so frames from the read
//! loop and from server-streaming threads never interleave.
//!
//! ### note:
//!
//! Heap-allocated by create. The last release frees it, so a streaming thread
//! may outlive the read loop that created it.
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

locked: std.atomic.Value(bool) = .init(false),
refs: std.atomic.Value(u32) = .init(1),
/// Server-streaming calls writing on this connection now. The unary path
/// takes the lock only while this is above 0.
active_streaming: std.atomic.Value(u32) = .init(0),

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 Grpc conn mutex error
pub const Error = error {
    ZixHttp2_GrpcConnMutex_OutOfMemory,
};

/// Allocate a mutex with one reference.
///
/// Return:
/// - *Self (freed by the last release)
/// - error.ZixHttp2_GrpcConnMutex_OutOfMemory when the allocation failed
pub fn create() Error!*Self {
    const self = std.heap.smp_allocator.create(Self) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_GrpcConnMutex_OutOfMemory,
    };
    self.* = .{};

    return self;
}

/// Spin until the lock is held.
pub fn lock(self: *Self) void {
    while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

pub fn unlock(self: *Self) void {
    self.locked.store(false, .release);
}

/// Add one reference.
pub fn retain(self: *Self) void {
    _ = self.refs.fetchAdd(1, .monotonic);
}

/// Drop one reference, freeing the mutex on the last one.
pub fn release(self: *Self) void {
    if (self.refs.fetchSub(1, .acq_rel) == 1) {
        std.heap.smp_allocator.destroy(self);
    }
}

/// Whether a server-streaming call may be writing on this connection now.
pub fn streamingActive(self: *const Self) bool {
    return self.active_streaming.load(.acquire) > 0;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 grpc: ConnMutex, create starts unlocked with one reference" {
    const mutex = try create();
    defer mutex.release();

    try std.testing.expect(!mutex.locked.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), mutex.refs.load(.acquire));
    try std.testing.expect(!mutex.streamingActive());
}

test "zix http2 grpc: ConnMutex, lock then unlock frees the lock" {
    const mutex = try create();
    defer mutex.release();

    mutex.lock();
    try std.testing.expect(mutex.locked.load(.acquire));

    mutex.unlock();
    try std.testing.expect(!mutex.locked.load(.acquire));
}

test "zix http2 grpc: ConnMutex, retain adds a reference" {
    const mutex = try create();
    mutex.retain();

    try std.testing.expectEqual(@as(u32, 2), mutex.refs.load(.acquire));

    mutex.release();
    try std.testing.expectEqual(@as(u32, 1), mutex.refs.load(.acquire));

    mutex.release();
}

test "zix http2 grpc: ConnMutex, streamingActive follows the counter" {
    const mutex = try create();
    defer mutex.release();

    _ = mutex.active_streaming.fetchAdd(1, .monotonic);
    try std.testing.expect(mutex.streamingActive());

    _ = mutex.active_streaming.fetchSub(1, .acq_rel);
    try std.testing.expect(!mutex.streamingActive());
}

