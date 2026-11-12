//! TLZ client StartResult
//!
//! ### file: src/tlz/src/client/StartResult.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What `start` produces: the ClientHello to send and the state `finish` needs.
//!
//! ### note:
//!
//! `client_hello` is a view into the caller's output buffer.
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
const State = @import("State.zig");

// --------------------------------------------------------- //
// Fields:

/// The ClientHello message, without the record header.
client_hello: []const u8,
/// Carried into `finish`.
state: State,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz client: StartResult, keeps the ClientHello bytes" {
    const bytes = [_]u8{ 1, 0, 0, 0 };
    const result: Self = .{
        .client_hello = &bytes,
        .state = .{
            .ephemeral_secret = @splat(0),
            .transcript = .init(),
        },
    };

    try std.testing.expectEqualSlices(u8, &bytes, result.client_hello);
}

