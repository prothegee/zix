//! TLZ dtls client State
//!
//! ### file: src/tlz/src/dtls/client/State.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Carried between the two DTLS client steps: the random, the ephemeral scalar, the
//! running transcript, the record sequence, and the cookie-bearing ClientHello.
//!
//! ### note:
//!
//! The cookie-bearing ClientHello body is kept because it opens the transcript.
//! `hello_len` 0 means no such hello has been written yet.
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
const client = @import("../client.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

// --------------------------------------------------------- //
// Fields:

client_random: [32]u8,
client_eph_scalar: [32]u8,
transcript: Sha256,
/// Next record sequence number in epoch 0.
next_record_seq: u48,
max_fragment_len: usize,
hello_body: [client.MAX_HELLO_BODY]u8,
hello_len: usize,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// The kept cookie-bearing ClientHello body.
///
/// Return:
/// - []const u8 (empty before a cookie hello is written)
pub fn helloBody(self: *const Self) []const u8 {
    return self.hello_body[0..self.hello_len];
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn testState() Self {
    return .{
        .client_random = @splat(0x11),
        .client_eph_scalar = @splat(0x44),
        .transcript = Sha256.init(.{}),
        .next_record_seq = 0,
        .max_fragment_len = 1024,
        .hello_body = @splat(0xAB),
        .hello_len = 0,
    };
}

test "tlz dtls client: State, helloBody is empty before a cookie hello" {
    const state = testState();

    try std.testing.expectEqual(@as(usize, 0), state.helloBody().len);
}

test "tlz dtls client: State, helloBody covers hello_len bytes" {
    var state = testState();
    state.hello_len = 3;

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAB, 0xAB, 0xAB }, state.helloBody());
}

