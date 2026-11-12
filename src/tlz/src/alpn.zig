//! TLZ alpn
//!
//! ### file: src/tlz/src/alpn.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! ALPN protocols tlz can negotiate over TLS (RFC 7301).
//!
//! ### note:
//!
//! The set is closed. h3 is QUIC ALPN, a different layer, so it is not listed.
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
// Public:

/// One protocol the server can select.
pub const Alpn = enum(u8) {
    HTTP_1_1,
    H2,

    /// The ProtocolName bytes carried in the ALPN extension.
    ///
    /// Return:
    /// - []const u8
    pub fn token(self: Alpn) []const u8 {
        return switch (self) {
            .HTTP_1_1 => "http/1.1",
            .H2 => "h2",
        };
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz: alpn, HTTP_1_1 token is http/1.1" {
    try std.testing.expectEqualStrings("http/1.1", Alpn.HTTP_1_1.token());
}

test "tlz: alpn, H2 token is h2" {
    try std.testing.expectEqualStrings("h2", Alpn.H2.token());
}

test "tlz: alpn, every token fits one ProtocolName length byte" {
    for (std.enums.values(Alpn)) |protocol| {
        const len = protocol.token().len;

        try std.testing.expect(len > 0 and len <= 255);
    }
}

