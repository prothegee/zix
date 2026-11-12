//! TLZ context Config
//!
//! ### file: src/tlz/src/context/Config.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Server TLS settings as the user writes them: certificate and key paths, ALPN,
//! version range, curves, and ciphers, plus the policy check `validate`.
//!
//! ### note:
//!
//! Curves and ciphers are allow-lists: a value tlz does not implement is a startup
//! error, never a silent no-op. Omitting the optional fields gives the secure
//! default (ECDHE with AEAD only).
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
const Version = @import("version.zig").Version;
const Alpn = @import("../alpn.zig").Alpn;
const NamedGroup = @import("../named_group.zig").NamedGroup;
const CipherSuite = @import("../cipher_suite.zig").CipherSuite;

// --------------------------------------------------------- //
// Fields:

/// PEM path to the end-entity certificate (ECDSA P-256, Ed25519, or RSA).
cert_path: []const u8,
/// PEM path to the private key matching `cert_path`.
key_path: []const u8,
/// ALPN protocols in server preference order. Empty means no ALPN.
alpn: []const Alpn = &.{},
/// Version floor (RFC 8446, RFC 5246). The default is a TLS 1.2 floor.
min_version: Version = .TLS_1_2,
/// Version ceiling. The default prefers TLS 1.3.
max_version: Version = .TLS_1_3,
/// ECDHE curves in server preference order.
curves: []const NamedGroup = DEFAULT_CURVES,
/// AEAD cipher suites in preference order, spanning TLS 1.3 and 1.2.
ciphers: []const CipherSuite = DEFAULT_CIPHERS,
/// Honor the server cipher order over the client order.
prefer_server_ciphers: bool = true,
/// HSTS max-age in seconds (RFC 6797). 0 turns it off.
hsts_max_age_s: u32 = 0,

const Self = @This();

// --------------------------------------------------------- //
// Private:

fn isImplementedCurve(curve: NamedGroup) bool {
    return curve == .X25519 or curve == .SECP256R1;
}

fn isImplementedCipher(cipher: CipherSuite) bool {
    return cipher == .AES_128_GCM_SHA256 or cipher == .ECDHE_ECDSA_AES128_GCM_SHA256;
}

fn contains(comptime T: type, list: []const T, value: T) bool {
    for (list) |item| {
        if (item == value) return true;
    }

    return false;
}

// --------------------------------------------------------- //
// Public:

pub const Error = error{
    Tlz_ContextConfig_NoCurves,
    Tlz_ContextConfig_NoCiphers,
    Tlz_ContextConfig_UnsupportedCurve,
    Tlz_ContextConfig_UnsupportedCipher,
    Tlz_ContextConfig_InvalidVersionRange,
    Tlz_ContextConfig_MissingCipherForVersion,
    Tlz_ContextConfig_MissingCurveForTls12,
};

/// The curves tlz implements, server preference order (X25519 first).
pub const DEFAULT_CURVES: []const NamedGroup = &.{
    .X25519,
    .SECP256R1,
};

/// The suites tlz implements: AES-128-GCM for TLS 1.3, ECDHE-ECDSA-AES128-GCM for 1.2.
pub const DEFAULT_CIPHERS: []const CipherSuite = &.{
    .AES_128_GCM_SHA256,
    .ECDHE_ECDSA_AES128_GCM_SHA256,
};

/// Check the policy without I/O: every curve, cipher, and version in it must be one
/// tlz can serve.
///
/// Return:
/// - void when the policy can be honored
/// - Error.Tlz_ContextConfig_NoCurves or NoCiphers on an empty list
/// - Error.Tlz_ContextConfig_UnsupportedCurve or UnsupportedCipher on an unknown value
/// - Error.Tlz_ContextConfig_InvalidVersionRange when min is above max
/// - Error.Tlz_ContextConfig_MissingCipherForVersion when an allowed version has no suite
/// - Error.Tlz_ContextConfig_MissingCurveForTls12 when TLS 1.2 is allowed without secp256r1
pub fn validate(self: Self) Error!void {
    if (self.curves.len == 0) return Error.Tlz_ContextConfig_NoCurves;
    if (self.ciphers.len == 0) return Error.Tlz_ContextConfig_NoCiphers;

    for (self.curves) |curve| {
        if (!isImplementedCurve(curve)) return Error.Tlz_ContextConfig_UnsupportedCurve;
    }

    for (self.ciphers) |cipher| {
        if (!isImplementedCipher(cipher)) return Error.Tlz_ContextConfig_UnsupportedCipher;
    }

    if (@intFromEnum(self.min_version) > @intFromEnum(self.max_version)) {
        return Error.Tlz_ContextConfig_InvalidVersionRange;
    }

    // Each allowed version needs its suite, and TLS 1.2 ECDHE needs secp256r1
    const has_tls13_suite = contains(CipherSuite, self.ciphers, .AES_128_GCM_SHA256);
    if (self.max_version == .TLS_1_3 and !has_tls13_suite) {
        return Error.Tlz_ContextConfig_MissingCipherForVersion;
    }

    if (self.min_version == .TLS_1_2) {
        if (!contains(CipherSuite, self.ciphers, .ECDHE_ECDSA_AES128_GCM_SHA256)) {
            return Error.Tlz_ContextConfig_MissingCipherForVersion;
        }

        if (!contains(NamedGroup, self.curves, .SECP256R1)) {
            return Error.Tlz_ContextConfig_MissingCurveForTls12;
        }
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz context: Config, default policy validates" {
    const config: Self = .{
        .cert_path = "c",
        .key_path = "k",
    };

    try config.validate();
}

test "tlz context: Config, unsupported curve is rejected" {
    const config: Self = .{
        .cert_path = "c",
        .key_path = "k",
        .curves = &.{ .X25519, @enumFromInt(0x4588) },
    };

    try std.testing.expectError(Error.Tlz_ContextConfig_UnsupportedCurve, config.validate());
}

test "tlz context: Config, unsupported cipher is rejected" {
    const config: Self = .{
        .cert_path = "c",
        .key_path = "k",
        .ciphers = &.{
            .AES_128_GCM_SHA256,
            .CHACHA20_POLY1305_SHA256,
            .ECDHE_ECDSA_AES128_GCM_SHA256,
        },
    };

    try std.testing.expectError(Error.Tlz_ContextConfig_UnsupportedCipher, config.validate());
}

test "tlz context: Config, empty curves are rejected" {
    const config: Self = .{
        .cert_path = "c",
        .key_path = "k",
        .curves = &.{},
    };

    try std.testing.expectError(Error.Tlz_ContextConfig_NoCurves, config.validate());
}

test "tlz context: Config, empty ciphers are rejected" {
    const config: Self = .{
        .cert_path = "c",
        .key_path = "k",
        .ciphers = &.{},
    };

    try std.testing.expectError(Error.Tlz_ContextConfig_NoCiphers, config.validate());
}

test "tlz context: Config, inverted version range is rejected" {
    const config: Self = .{
        .cert_path = "c",
        .key_path = "k",
        .min_version = .TLS_1_3,
        .max_version = .TLS_1_2,
    };

    try std.testing.expectError(Error.Tlz_ContextConfig_InvalidVersionRange, config.validate());
}

test "tlz context: Config, TLS 1.3 only without its suite is rejected" {
    const config: Self = .{
        .cert_path = "c",
        .key_path = "k",
        .min_version = .TLS_1_3,
        .max_version = .TLS_1_3,
        .ciphers = &.{.ECDHE_ECDSA_AES128_GCM_SHA256},
    };

    try std.testing.expectError(
        Error.Tlz_ContextConfig_MissingCipherForVersion,
        config.validate(),
    );
}

test "tlz context: Config, TLS 1.2 floor without secp256r1 is rejected" {
    const config: Self = .{
        .cert_path = "c",
        .key_path = "k",
        .curves = &.{.X25519},
    };

    try std.testing.expectError(Error.Tlz_ContextConfig_MissingCurveForTls12, config.validate());
}

test "tlz context: Config, TLS 1.3 only policy validates" {
    const config: Self = .{
        .cert_path = "c",
        .key_path = "k",
        .min_version = .TLS_1_3,
        .max_version = .TLS_1_3,
        .ciphers = &.{.AES_128_GCM_SHA256},
        .curves = &.{.X25519},
    };

    try config.validate();
}

test "tlz context: Config, TLS 1.2 only policy validates" {
    const config: Self = .{
        .cert_path = "c",
        .key_path = "k",
        .min_version = .TLS_1_2,
        .max_version = .TLS_1_2,
        .ciphers = &.{.ECDHE_ECDSA_AES128_GCM_SHA256},
        .curves = &.{.SECP256R1},
    };

    try config.validate();
}

