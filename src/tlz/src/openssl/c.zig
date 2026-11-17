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

/// The oldest supported OpenSSL, as `OPENSSL_VERSION_NUMBER`: 3.5.0 on the 3.x line.
/// Every 4.x release (floor 4.0.0) is above it.
const VERSION_FLOOR: c_long = 0x30500000;

comptime {
    if (ENABLED and raw.OPENSSL_VERSION_NUMBER < VERSION_FLOOR) {
        @compileError("tlz openssl binding requires OpenSSL 3.5 or newer (3.x), " ++
            "or 4.0 or newer (4.x).");
    }
}

// --------------------------------------------------------- //
// Public:

/// True when OpenSSL was detected at build time and the binding is compiled in.
pub const ENABLED: bool = tlz_options.openssl;

/// The translated OpenSSL headers (ssl.h, err.h, x509v3.h).
/// An empty namespace when OpenSSL was not detected.
pub const raw = if (ENABLED) @import("openssl_c") else struct {};

/// The OpenSSL major version of the headers: 3 or 4. 0 when OpenSSL was not detected.
/// The openssl files pick a call per major with it (see `client.zig`).
pub const VERSION_MAJOR: c_int = if (ENABLED) raw.OPENSSL_VERSION_MAJOR else 0;

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

test "tlz openssl: c, VERSION_MAJOR is 0 without OpenSSL" {
    if (ENABLED) return error.SkipZigTest;

    try std.testing.expectEqual(@as(c_int, 0), VERSION_MAJOR);
}

test "tlz openssl: c, linked version meets the 3.5 floor" {
    if (!ENABLED) return error.SkipZigTest;

    try std.testing.expect(raw.OpenSSL_version_num() >= VERSION_FLOOR);
}

test "tlz openssl: c, header version meets the 3.5 floor" {
    if (!ENABLED) return error.SkipZigTest;

    try std.testing.expect(raw.OPENSSL_VERSION_NUMBER >= VERSION_FLOOR);
}

test "tlz openssl: c, VERSION_MAJOR is a supported line" {
    if (!ENABLED) return error.SkipZigTest;

    try std.testing.expect(VERSION_MAJOR == 3 or VERSION_MAJOR == 4);
}

test "tlz openssl: c, VERSION_MAJOR matches the linked library" {
    if (!ENABLED) return error.SkipZigTest;

    try std.testing.expectEqual(
        @as(c_uint, @intCast(VERSION_MAJOR)),
        raw.OPENSSL_version_major(),
    );
}

test "tlz openssl: c, SSL_CTX_new creates a context" {
    if (!ENABLED) return error.SkipZigTest;

    const ctx = raw.SSL_CTX_new(raw.TLS_method()) orelse return error.TestUnexpectedResult;
    defer raw.SSL_CTX_free(ctx);

    try std.testing.expect(raw.SSL_CTX_get_min_proto_version(ctx) >= 0);
}

