//! ZIX Http2 mux stream_pool
//!
//! ### file: src/zix/tcp/http2/mux/stream_pool.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Per-worker freelist of MuxStream, borrowed while a stream is open.
//!
//! ### note:
//!
//! - The freelist is a threadlocal: one per worker, no locks. Stream memory
//!   tracks concurrent streams on a worker, not connections * max_streams.
//! - A stream is never freed once pooled. It lives until its worker exits.
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
const MuxStream = @import("MuxStream.zig");
const ServeOpts = @import("../ServeOpts.zig");

// --------------------------------------------------------- //
// Private:

/// Idle streams of this worker, most recently released first.
threadlocal var free_list: ?*MuxStream = null;

/// Allocate a stream with buffers sized by opts.
fn allocFresh(opts: ServeOpts) Error!*MuxStream {
    const allocator = std.heap.smp_allocator;

    const stream = allocator.create(MuxStream) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_StreamPool_OutOfMemory,
    };
    errdefer allocator.destroy(stream);

    const body = allocator.alloc(u8, opts.max_body) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_StreamPool_OutOfMemory,
    };
    errdefer allocator.free(body);

    const scratch = allocator.alloc(u8, opts.max_header_scratch) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_StreamPool_OutOfMemory,
    };

    stream.* = .{
        .body = body,
        .header_scratch = scratch,
    };

    return stream;
}

/// Free a stream and both of its buffers.
fn destroy(stream: *MuxStream) void {
    const allocator = std.heap.smp_allocator;

    allocator.free(stream.body);
    allocator.free(stream.header_scratch);
    allocator.destroy(stream);
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 mux stream pool error
pub const Error = error {
    ZixHttp2_StreamPool_OutOfMemory,
};

/// Borrow a clean stream, growing the pool when the freelist is empty.
///
/// Note:
/// - A pooled stream smaller than opts asks for is dropped and replaced. That
///   only happens with mixed serve options on one worker.
///
/// Param:
/// opts - ServeOpts (max_body and max_header_scratch size the buffers)
///
/// Return:
/// - *MuxStream (reset, buffers at least as large as opts asks)
/// - error.ZixHttp2_StreamPool_OutOfMemory when a fresh stream can not be allocated
pub fn acquire(opts: ServeOpts) Error!*MuxStream {
    if (free_list) |stream| {
        free_list = stream.next_free;
        stream.next_free = null;

        const fits =
            stream.body.len >= opts.max_body and
            stream.header_scratch.len >= opts.max_header_scratch;
        if (fits) return stream;

        destroy(stream);
    }

    return allocFresh(opts);
}

/// Return a stream to the pool, reset, buffers kept for the next borrow.
///
/// Param:
/// stream - *MuxStream (a stream from acquire, not used after this call)
///
/// Return:
/// - void
pub fn release(stream: *MuxStream) void {
    stream.reset();
    stream.next_free = free_list;

    free_list = stream;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const StreamState = @import("../stream_state.zig").StreamState;

const TEST_OPTS: ServeOpts = .{
    .max_body = 128,
    .max_header_scratch = 64,
};

test "zix http2 mux: stream_pool, acquire sizes the buffers by opts" {
    const stream = try acquire(TEST_OPTS);
    defer release(stream);

    try std.testing.expect(stream.body.len >= 128);
    try std.testing.expect(stream.header_scratch.len >= 64);
}

test "zix http2 mux: stream_pool, release then acquire reuses the same stream" {
    const first = try acquire(TEST_OPTS);
    first.id = 7;
    first.state = .OPEN;
    first.body_len = 99;
    first.pending_body = "parked";
    first.send_window = 12;
    release(first);

    const again = try acquire(TEST_OPTS);
    defer release(again);

    try std.testing.expectEqual(first, again);
    try std.testing.expectEqual(@as(u31, 0), again.id);
    try std.testing.expectEqual(StreamState.IDLE, again.state);
    try std.testing.expectEqual(@as(usize, 0), again.body_len);
    try std.testing.expect(!again.isParked());
    try std.testing.expect(again.body.len >= 128);
}

test "zix http2 mux: stream_pool, a pooled stream too small is replaced" {
    const small = try acquire(TEST_OPTS);
    release(small);

    const larger: ServeOpts = .{
        .max_body = 4096,
        .max_header_scratch = 64,
    };
    const stream = try acquire(larger);
    defer release(stream);

    try std.testing.expect(stream.body.len >= 4096);
}

test "zix http2 mux: stream_pool, two borrows are distinct streams" {
    const first = try acquire(TEST_OPTS);
    defer release(first);
    const second = try acquire(TEST_OPTS);
    defer release(second);

    try std.testing.expect(first != second);
}

