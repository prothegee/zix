//! ZIX http1 tls feed step
//!
//! ### file: src/zix/tcp/http1/tls_feed/step.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What the TLS path must do with the request at the front of its buffer.
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
const Serve = @import("Serve.zig");

// --------------------------------------------------------- //
// Public:

/// One feed decision.
pub const Step = union(enum) {
    /// Serve it with these lengths.
    SERVE: Serve,
    /// Not all here yet. Keep reading.
    WAIT,
    /// The declared body is past what the server accepts. Answer 413 and close.
    REFUSE_BODY,
    /// The head alone does not fit the buffer. Answer 431 and close.
    REFUSE_HEAD,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1: step, SERVE carries its lengths" {
    const step: Step = .{
        .SERVE = .{
            .body_len = 1,
            .received = 1,
            .request_len = 2,
        },
    };

    try std.testing.expectEqual(@as(usize, 2), step.SERVE.request_len);
}

test "zix http1: step, WAIT has no payload" {
    const step: Step = .WAIT;

    try std.testing.expect(step == .WAIT);
}

