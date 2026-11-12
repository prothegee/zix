//! TLZ connection HandshakeResult
//!
//! ### file: src/tlz/src/connection/HandshakeResult.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What a server handshake produces: the post-handshake connection, the bytes to
//! send, and the selected ALPN protocol.
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
const Connection = @import("Connection.zig");
const Alpn = @import("../alpn.zig").Alpn;

// --------------------------------------------------------- //
// Fields:

/// The established connection keys.
connection: Connection,
/// ServerHello record, ChangeCipherSpec, then the encrypted flight.
to_send: []const u8,
/// The ALPN protocol selected, null when ALPN was not used.
alpn: ?Alpn = null,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz connection: HandshakeResult, ALPN defaults to null" {
    const result: Self = .{
        .connection = undefined,
        .to_send = &.{},
    };

    try std.testing.expect(result.alpn == null);
}

test "tlz connection: HandshakeResult, keeps the selected ALPN" {
    const result: Self = .{
        .connection = undefined,
        .to_send = &.{},
        .alpn = .H2,
    };

    try std.testing.expectEqual(Alpn.H2, result.alpn.?);
}

