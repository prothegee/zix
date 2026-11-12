//! TLZ dtls client ServerFlight
//!
//! ### file: src/tlz/src/dtls/client/ServerFlight.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The four messages a DTLS server sends in flight 4, bodies only with their
//! handshake headers stripped.
//!
//! ### note:
//!
//! Every slice borrows the caller's reassembly buffers.
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

server_hello: []const u8,
certificate: []const u8,
key_exchange: []const u8,
hello_done: []const u8,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz dtls client: ServerFlight, holds the four bodies in order" {
    const flight: Self = .{
        .server_hello = "hello",
        .certificate = "cert",
        .key_exchange = "ske",
        .hello_done = "",
    };

    try std.testing.expectEqualStrings("hello", flight.server_hello);
    try std.testing.expectEqualStrings("ske", flight.key_exchange);
    try std.testing.expectEqual(@as(usize, 0), flight.hello_done.len);
}

