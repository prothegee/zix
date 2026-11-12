//! TLZ context
//!
//! ### file: src/tlz/src/context.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The server TLS context namespace: the Context, its Config, the Version range,
//! and the curve and cipher sets tlz implements.
//!
//! ### note:
//!
//! Only names live here. The behavior is in `context/Context.zig` (loading) and
//! `context/Config.zig` (policy check).
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

pub const Context = @import("context/Context.zig");
pub const Config = @import("context/Config.zig");
pub const Version = @import("context/version.zig").Version;

/// The curves tlz implements, the secure default for Config.curves.
pub const DEFAULT_CURVES = Config.DEFAULT_CURVES;

/// The cipher suites tlz implements, the secure default for Config.ciphers.
pub const DEFAULT_CIPHERS = Config.DEFAULT_CIPHERS;

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const NamedGroup = @import("named_group.zig").NamedGroup;
const CipherSuite = @import("cipher_suite.zig").CipherSuite;

test "tlz: context, DEFAULT_CURVES puts X25519 first" {
    try std.testing.expectEqual(@as(usize, 2), DEFAULT_CURVES.len);
    try std.testing.expectEqual(NamedGroup.X25519, DEFAULT_CURVES[0]);
}

test "tlz: context, DEFAULT_CIPHERS cover TLS 1.3 and TLS 1.2" {
    try std.testing.expectEqual(CipherSuite.AES_128_GCM_SHA256, DEFAULT_CIPHERS[0]);
    try std.testing.expectEqual(CipherSuite.ECDHE_ECDSA_AES128_GCM_SHA256, DEFAULT_CIPHERS[1]);
}

test "tlz: context, Context.Config is the same Config" {
    try std.testing.expect(Context.Config == Config);
}

