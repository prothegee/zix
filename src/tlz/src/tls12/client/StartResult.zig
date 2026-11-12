//! TLZ tls12 client StartResult
//!
//! ### file: src/tlz/src/tls12/client/StartResult.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What the TLS 1.2 client `start` produces: the ClientHello to send and the State
//! `finish` needs.
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
const State = @import("State.zig");

// --------------------------------------------------------- //
// Fields:

/// The ClientHello handshake message, a view into the caller's buffer.
client_hello: []const u8,
/// Carried into `finish`.
state: State,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz tls12 client: StartResult, keeps the ClientHello bytes" {
    const result: Self = .{
        .client_hello = "hello",
        .state = undefined,
    };

    try std.testing.expectEqualStrings("hello", result.client_hello);
}

test "tlz tls12 client: StartResult, empty ClientHello has no bytes" {
    const result: Self = .{
        .client_hello = &.{},
        .state = undefined,
    };

    try std.testing.expectEqual(@as(usize, 0), result.client_hello.len);
}

