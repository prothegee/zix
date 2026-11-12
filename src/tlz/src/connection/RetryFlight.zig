//! TLZ connection RetryFlight
//!
//! ### file: src/tlz/src/connection/RetryFlight.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! A HelloRetryRequest flight to send, plus the state to resume from when the
//! second ClientHello arrives.
//!
//! ### note:
//!
//! `to_send` is a view into the caller's output buffer.
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
const RetryState = @import("RetryState.zig");

// --------------------------------------------------------- //
// Fields:

/// The HelloRetryRequest record plus a ChangeCipherSpec.
to_send: []const u8,
/// What `serverHandshakeAfterRetry` resumes from.
state: RetryState,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz connection: RetryFlight, keeps the bytes to send" {
    const bytes = [_]u8{ 22, 3, 3, 0, 0 };
    const flight: Self = .{
        .to_send = &bytes,
        .state = .{
            .opts = .{
                .certificate_der = &.{},
                .signing_key = .{ .rsa = .{} },
                .ephemeral_secret = @splat(0),
                .server_random = @splat(0),
            },
            .transcript = .init(),
            .group = .X25519,
        },
    };

    try std.testing.expectEqualSlices(u8, &bytes, flight.to_send);
}

