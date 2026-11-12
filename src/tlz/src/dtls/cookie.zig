//! TLZ dtls cookie
//!
//! ### file: src/tlz/src/dtls/cookie.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! DTLS stateless cookies for the HelloVerifyRequest exchange (RFC 6347 4.2.1):
//! the cookie sizes and the `Signer` that issues and checks them.
//!
//! ### note:
//!
//! Nothing is stored per client. The cookie is HMAC(secret, address ++ client
//! parameters), so verifying it is recomputing it. An invalid cookie is treated
//! exactly like no cookie at all (RFC 6347 4.2.1), never as an error.
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

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

// --------------------------------------------------------- //
// Public:

pub const Signer = @import("cookie/Signer.zig");

/// Cookie signing secret width, one SHA-256 block.
pub const SECRET_LEN: usize = 32;

/// Cookie width. HMAC-SHA256 output, used whole.
pub const COOKIE_LEN: usize = HmacSha256.mac_length;

/// Largest cookie DTLS 1.2 allows on the wire (RFC 6347 4.2.1). Earlier versions cap at 32.
pub const MAX_COOKIE_LEN: usize = 255;

/// One cookie as this server issues it.
pub const Cookie = [COOKIE_LEN]u8;

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz dtls: cookie, COOKIE_LEN is the HMAC-SHA256 width" {
    try std.testing.expectEqual(@as(usize, 32), COOKIE_LEN);
}

test "tlz dtls: cookie, COOKIE_LEN fits MAX_COOKIE_LEN" {
    try std.testing.expect(COOKIE_LEN <= MAX_COOKIE_LEN);
}

test "tlz dtls: cookie, SECRET_LEN is one SHA-256 block" {
    try std.testing.expectEqual(@as(usize, 32), SECRET_LEN);
}

