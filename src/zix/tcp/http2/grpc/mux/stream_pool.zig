//! ZIX Http2 Grpc mux stream_pool
//!
//! ### file: src/zix/tcp/http2/grpc/mux/stream_pool.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Per-worker freelist of gRPC streams for the mux path.
//!
//! ### note:
//!
//! The freelist is threadlocal: a stream is released on the worker that
//! acquired it. Buffers are kept across borrows, so the steady state does no
//! per-stream allocation.
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
const ServeOpts = @import("../ServeOpts.zig");
const Stream = @import("../Stream.zig");

// --------------------------------------------------------- //
// Private:

/// Idle streams of this worker, most recently released first.
threadlocal var free_list: ?*Stream = null;

/// Allocate a stream with buffers sized by opts.
fn allocFresh(opts: ServeOpts) Error!*Stream {
    const allocator = std.heap.smp_allocator;

    const stream = allocator.create(Stream) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_GrpcStreamPool_OutOfMemory,
    };
    errdefer allocator.destroy(stream);

    const body = allocator.alloc(u8, opts.max_body) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_GrpcStreamPool_OutOfMemory,
    };
    errdefer allocator.free(body);

    const scratch = allocator.alloc(u8, opts.max_header_scratch) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_GrpcStreamPool_OutOfMemory,
    };

    stream.* = .{
        .body = body,
        .header_scratch = scratch,
    };

    return stream;
}

/// Free a stream and both of its buffers.
fn destroy(stream: *Stream) void {
    const allocator = std.heap.smp_allocator;

    allocator.free(stream.body);
    allocator.free(stream.header_scratch);
    allocator.destroy(stream);
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 Grpc mux stream pool error
pub const Error = error {
    ZixHttp2_GrpcStreamPool_OutOfMemory,
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
/// - *Stream (reset, buffers at least as large as opts asks)
/// - error.ZixHttp2_GrpcStreamPool_OutOfMemory when a fresh stream can not be allocated
pub fn acquire(opts: ServeOpts) Error!*Stream {
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
/// stream - *Stream (a stream from acquire, not used after this call)
///
/// Return:
/// - void
pub fn release(stream: *Stream) void {
    // Copied out first: the reset below overwrites the fields it reads.
    const body = stream.body;
    const scratch = stream.header_scratch;

    stream.* = .{
        .body = body,
        .header_scratch = scratch,
        .next_free = free_list,
    };

    free_list = stream;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const StreamState = @import("../../stream_state.zig").StreamState;

const TEST_OPTS: ServeOpts = .{
    .max_body = 128,
    .max_header_scratch = 64,
};

test "zix http2 grpc mux: stream_pool, acquire sizes the buffers by opts" {
    const stream = try acquire(TEST_OPTS);
    defer release(stream);

    try std.testing.expect(stream.body.len >= 128);
    try std.testing.expect(stream.header_scratch.len >= 64);
}

test "zix http2 grpc mux: stream_pool, release then acquire reuses the same stream" {
    const first = try acquire(TEST_OPTS);
    first.open(7);
    first.header_count = 3;
    first.body_len = 99;
    first.end_headers = true;
    first.end_stream = true;
    release(first);

    const again = try acquire(TEST_OPTS);
    defer release(again);

    try std.testing.expectEqual(first, again);
    try std.testing.expectEqual(@as(u31, 0), again.id);
    try std.testing.expectEqual(StreamState.IDLE, again.state);
    try std.testing.expectEqual(@as(usize, 0), again.header_count);
    try std.testing.expectEqual(@as(usize, 0), again.body_len);
    try std.testing.expect(!again.end_headers);
    try std.testing.expect(!again.end_stream);
    try std.testing.expect(again.body.len >= 128);
}

test "zix http2 grpc mux: stream_pool, an acquired stream is off the freelist" {
    const stream = try acquire(TEST_OPTS);
    defer release(stream);

    try std.testing.expect(stream.next_free == null);
}

test "zix http2 grpc mux: stream_pool, a pooled stream too small is replaced" {
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

test "zix http2 grpc mux: stream_pool, two borrows are distinct streams" {
    const first = try acquire(TEST_OPTS);
    defer release(first);
    const second = try acquire(TEST_OPTS);
    defer release(second);

    try std.testing.expect(first != second);
}

