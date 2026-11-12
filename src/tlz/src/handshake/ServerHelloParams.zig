//! TLZ handshake ServerHelloParams
//!
//! ### file: src/tlz/src/handshake/ServerHelloParams.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What the server picked for its ServerHello (RFC 8446 section 4.1.3): the cipher
//! suite, the key exchange group, and the server key share bytes.
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
const CipherSuite = @import("../cipher_suite.zig").CipherSuite;
const NamedGroup = @import("../named_group.zig").NamedGroup;

// --------------------------------------------------------- //
// Fields:

/// The negotiated cipher suite.
cipher: CipherSuite,
/// The negotiated key exchange group.
group: NamedGroup,
/// The server public key share, borrowed from the caller.
key_exchange: []const u8,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz handshake: ServerHelloParams, keeps the negotiated fields" {
    const share = [_]u8{ 1, 2, 3 };
    const params: Self = .{
        .cipher = .AES_128_GCM_SHA256,
        .group = .X25519,
        .key_exchange = &share,
    };

    try std.testing.expectEqual(CipherSuite.AES_128_GCM_SHA256, params.cipher);
    try std.testing.expectEqual(NamedGroup.X25519, params.group);
    try std.testing.expectEqualSlices(u8, &share, params.key_exchange);
}

test "tlz handshake: ServerHelloParams, empty key share is allowed" {
    const params: Self = .{
        .cipher = .AES_128_GCM_SHA256,
        .group = .SECP256R1,
        .key_exchange = &.{},
    };

    try std.testing.expectEqual(@as(usize, 0), params.key_exchange.len);
}

