//! ZIX Http1 ServeOpts
//!
//! ### file: src/zix/tcp/http1/ServeOpts.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Per-connection serving knobs passed to the keep-alive loop.
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

// --------------------------------------------------------- //
// Fields:

nodelay: bool = true,
handler_timeout_ms: u32 = 0,
large_body_recv_buf: usize = 0,
max_recv_buf: usize = BUF_SIZE,
max_request_body: usize = 2 * 1024 * 1024,

// --------------------------------------------------------- //
// Public:

/// Default shared per-connection scratch size: the blocking-loop receive
/// buffer, the chunked-body reader, and the TLS payload buffers all use it.
pub const BUF_SIZE: usize = 1 * 1024;

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1: ServeOpts, applies defaults" {
    const opts: @This() = .{};

    try std.testing.expect(opts.nodelay);
    try std.testing.expectEqual(BUF_SIZE, opts.max_recv_buf);
    try std.testing.expectEqual(@as(u32, 0), opts.handler_timeout_ms);
    try std.testing.expectEqual(@as(usize, 0), opts.large_body_recv_buf);
    try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), opts.max_request_body);
}

test "zix http1: ServeOpts, accepts an explicit buffer size" {
    const opts: @This() = .{
        .max_recv_buf = 64 * 1024,
        .max_request_body = 1024,
    };

    try std.testing.expectEqual(@as(usize, 64 * 1024), opts.max_recv_buf);
    try std.testing.expectEqual(@as(usize, 1024), opts.max_request_body);
}

