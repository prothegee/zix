//! TLZ openssl c
//!
//! ### file: src/tlz/src/openssl/c.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The single entry to the OpenSSL C API. Every other openssl file imports C through
//! this file, never through the translated module directly.
//!
//! ### note:
//!
//! The "openssl_c" module exists only when `build.zig` detected OpenSSL. When it was
//! not detected, `raw` is an empty namespace and nothing else in the openssl subtree
//! may be compiled.
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
const tlz_options = @import("tlz_options");

// --------------------------------------------------------- //
// Private:

/// The oldest supported OpenSSL: 3.0.0 (the 3.0 LTS line), as `OPENSSL_VERSION_NUMBER`.
const VERSION_FLOOR: c_long = 0x30000000;

comptime {
    if (ENABLED and raw.OPENSSL_VERSION_NUMBER < VERSION_FLOOR) {
        @compileError("tlz openssl binding requires OpenSSL 3.0 or newer.");
    }
}

// --------------------------------------------------------- //
// Public:

/// True when OpenSSL was detected at build time and the binding is compiled in.
pub const ENABLED: bool = tlz_options.openssl;

/// The translated OpenSSL headers (ssl.h, err.h, x509v3.h).
/// An empty namespace when OpenSSL was not detected.
pub const raw = if (ENABLED) @import("openssl_c") else struct {};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz openssl: c, ENABLED follows the build option" {
    try std.testing.expectEqual(tlz_options.openssl, ENABLED);
}

test "tlz openssl: c, raw is empty without OpenSSL" {
    if (ENABLED) return error.SkipZigTest;

    try std.testing.expect(!@hasDecl(raw, "SSL_CTX_new"));
}

test "tlz openssl: c, linked version meets the 3.0 floor" {
    if (!ENABLED) return error.SkipZigTest;

    try std.testing.expect(raw.OpenSSL_version_num() >= VERSION_FLOOR);
}

test "tlz openssl: c, header version meets the 3.0 floor" {
    if (!ENABLED) return error.SkipZigTest;

    try std.testing.expect(raw.OPENSSL_VERSION_NUMBER >= VERSION_FLOOR);
}

test "tlz openssl: c, SSL_CTX_new creates a context" {
    if (!ENABLED) return error.SkipZigTest;

    const ctx = raw.SSL_CTX_new(raw.TLS_method()) orelse return error.TestUnexpectedResult;
    defer raw.SSL_CTX_free(ctx);

    try std.testing.expect(raw.SSL_CTX_get_min_proto_version(ctx) >= 0);
}

