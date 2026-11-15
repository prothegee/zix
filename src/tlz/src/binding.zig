//! TLZ binding
//!
//! ### file: src/tlz/src/binding.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The TLS backend a context or a client runs on: native (pure std.crypto) or the
//! system OpenSSL, chosen at compile time.
//!
//! ### note:
//!
//! Choosing `.OPENSSL` on a build where OpenSSL was not detected is a build error,
//! never a runtime error. `.DEFAULT` always builds.
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
const openssl_c = @import("openssl/c.zig");

// --------------------------------------------------------- //
// Public:

/// One TLS backend. `DEFAULT` is native.
pub const Binding = enum(u8) {
    DEFAULT,
    OPENSSL,
};

/// The backend is compiled into this build.
///
/// Param:
/// binding - Binding (the backend to check)
///
/// Return:
/// - true for `.DEFAULT`
/// - true for `.OPENSSL` only when OpenSSL was detected at build time
pub fn isBuilt(comptime binding: Binding) bool {
    return switch (binding) {
        .DEFAULT => true,
        .OPENSSL => openssl_c.ENABLED,
    };
}

/// Stop the build with a clear message when the backend is not compiled in.
///
/// Param:
/// binding - Binding (the backend the caller chose)
///
/// Return:
/// - void (a build error when `isBuilt(binding)` is false)
pub fn requireBuilt(comptime binding: Binding) void {
    if (!isBuilt(binding)) {
        @compileError("tlz: Binding.OPENSSL needs OpenSSL at build time. " ++
            "Install the libssl dev package so `pkg-config openssl` finds it.");
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz: binding, DEFAULT is the zero value" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Binding.DEFAULT));
}

test "tlz: binding, OPENSSL follows DEFAULT" {
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Binding.OPENSSL));
}

test "tlz: binding, isBuilt DEFAULT is always true" {
    try std.testing.expect(comptime isBuilt(.DEFAULT));
}

test "tlz: binding, isBuilt OPENSSL follows the build option" {
    try std.testing.expectEqual(openssl_c.ENABLED, comptime isBuilt(.OPENSSL));
}

test "tlz: binding, requireBuilt DEFAULT compiles" {
    comptime requireBuilt(.DEFAULT);
}

test "tlz: binding, requireBuilt OPENSSL compiles when OpenSSL is built" {
    if (openssl_c.ENABLED) {
        comptime requireBuilt(.OPENSSL);
    } else {
        return error.SkipZigTest;
    }
}

