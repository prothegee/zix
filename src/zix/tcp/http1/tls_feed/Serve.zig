//! ZIX http1 tls feed serve
//!
//! ### file: src/zix/tcp/http1/tls_feed/Serve.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The parts of a serve decision the TLS path needs to dispatch one request.
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

/// Body bytes available in the buffer. 0 for a body counted off the wire.
body_len: usize,
/// Body bytes counted for this request, which bodyReceived() answers.
received: u64,
/// Buffer bytes this request consumes, so the remainder slides to the front.
request_len: usize,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1: Serve, keeps the three lengths" {
    const serve: Self = .{
        .body_len = 4,
        .received = 4,
        .request_len = 40,
    };

    try std.testing.expectEqual(@as(usize, 4), serve.body_len);
    try std.testing.expectEqual(@as(u64, 4), serve.received);
    try std.testing.expectEqual(@as(usize, 40), serve.request_len);
}

test "zix http1: Serve, a drained body has no buffered bytes" {
    const serve: Self = .{
        .body_len = 0,
        .received = 190000,
        .request_len = 60,
    };

    try std.testing.expectEqual(@as(usize, 0), serve.body_len);
    try std.testing.expect(serve.received > serve.request_len);
}

