//! ZIX utils pwhash pbkdf2
//!
//! ### file: src/zix/utils/pwhash/pbkdf2.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! PBKDF2-HMAC-SHA256 password hash and verification.
//! 
//! ### note:
//! 
//! The encoded form is `$pbkdf2-sha256$i=<rounds>$<salt>$<hash>`
//! with base64url no-pad fields.
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
// Private:

const SALT_LENGTH = 16;
const DERIVED_LENGTH = 32;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_PwhashPbkdf2_WeakParameters,
    ZixUtils_PwhashPbkdf2_OutputTooLong,
    ZixUtils_PwhashPbkdf2_InvalidEncoding,
    ZixUtils_PwhashPbkdf2_PasswordVerificationFailed,
    ZixUtils_PwhashPbkdf2_NoSpaceLeft,
};

/// Create a PBKDF2-HMAC-SHA256 password hash.
///
/// Note:
/// - For `rounds`, use 600_000 as the OWASP recommendation.
///
/// Param:
/// io - std.Io (source of the salt randomness)
/// allocator - std.mem.Allocator (kept for API symmetry, not used)
/// password - []const u8 (plain password)
/// rounds - u32 (iteration count, must be at least 1)
/// buf - []u8 (output buffer, caller owns it)
///
/// Return:
/// - []const u8 (the encoded hash, borrowed from buf)
/// - Error.ZixUtils_PwhashPbkdf2_WeakParameters when rounds is zero
/// - Error.ZixUtils_PwhashPbkdf2_OutputTooLong when the derived key is too long
/// - Error.ZixUtils_PwhashPbkdf2_NoSpaceLeft when buf is too small
pub fn hash(
    io: std.Io,
    allocator: std.mem.Allocator,
    password: []const u8,
    rounds: u32,
    buf: []u8,
) Error![]const u8 {
    _ = allocator;

    var salt: [SALT_LENGTH]u8 = undefined;
    io.random(&salt);

    var derived: [DERIVED_LENGTH]u8 = undefined;
    std.crypto.pwhash.pbkdf2(
        &derived,
        password,
        &salt,
        rounds,
        HmacSha256,
    ) catch |err| switch (err) {
        error.WeakParameters => return Error.ZixUtils_PwhashPbkdf2_WeakParameters,
        error.OutputTooLong => return Error.ZixUtils_PwhashPbkdf2_OutputTooLong,
    };

    const Encoder = std.base64.url_safe_no_pad.Encoder;
    var salt_b64: [Encoder.calcSize(SALT_LENGTH)]u8 = undefined;
    _ = Encoder.encode(&salt_b64, &salt);
    var hash_b64: [Encoder.calcSize(DERIVED_LENGTH)]u8 = undefined;
    _ = Encoder.encode(&hash_b64, &derived);

    return std.fmt.bufPrint(
        buf,
        "$pbkdf2-sha256$i={d}${s}${s}",
        .{ rounds, salt_b64, hash_b64 },
    ) catch |err| switch (err) {
        error.NoSpaceLeft => return Error.ZixUtils_PwhashPbkdf2_NoSpaceLeft,
    };
}

/// Verify a PBKDF2-HMAC-SHA256 password hash.
///
/// Param:
/// allocator - std.mem.Allocator (kept for API symmetry, not used)
/// password_raw - []const u8 (plain password)
/// password_encoded - []const u8 (encoded hash to verify against)
///
/// Return:
/// - void on a match
/// - Error.ZixUtils_PwhashPbkdf2_PasswordVerificationFailed on a mismatch
/// - Error.ZixUtils_PwhashPbkdf2_InvalidEncoding on a malformed encoded hash
/// - Error.ZixUtils_PwhashPbkdf2_WeakParameters when the stored rounds is zero
pub fn verify(
    allocator: std.mem.Allocator,
    password_raw: []const u8,
    password_encoded: []const u8,
) Error!void {
    _ = allocator;

    var parts = std.mem.splitScalar(u8, password_encoded, '$');

    const prefix = parts.next() orelse return Error.ZixUtils_PwhashPbkdf2_InvalidEncoding;
    if (prefix.len != 0) return Error.ZixUtils_PwhashPbkdf2_InvalidEncoding;

    const scheme = parts.next() orelse return Error.ZixUtils_PwhashPbkdf2_InvalidEncoding;
    if (!std.mem.eql(u8, scheme, "pbkdf2-sha256")) {
        return Error.ZixUtils_PwhashPbkdf2_InvalidEncoding;
    }

    const rounds_str = parts.next() orelse return Error.ZixUtils_PwhashPbkdf2_InvalidEncoding;
    if (!std.mem.startsWith(u8, rounds_str, "i=")) {
        return Error.ZixUtils_PwhashPbkdf2_InvalidEncoding;
    }

    const rounds = std.fmt.parseInt(u32, rounds_str[2..], 10) catch |err| switch (err) {
        else => return Error.ZixUtils_PwhashPbkdf2_InvalidEncoding,
    };

    const salt_b64 = parts.next() orelse return Error.ZixUtils_PwhashPbkdf2_InvalidEncoding;
    const hash_b64 = parts.next() orelse return Error.ZixUtils_PwhashPbkdf2_InvalidEncoding;
    if (parts.next() != null) return Error.ZixUtils_PwhashPbkdf2_InvalidEncoding;

    const Decoder = std.base64.url_safe_no_pad.Decoder;
    var salt: [SALT_LENGTH]u8 = undefined;
    Decoder.decode(&salt, salt_b64) catch |err| switch (err) {
        else => return Error.ZixUtils_PwhashPbkdf2_InvalidEncoding,
    };

    var expected: [DERIVED_LENGTH]u8 = undefined;
    Decoder.decode(&expected, hash_b64) catch |err| switch (err) {
        else => return Error.ZixUtils_PwhashPbkdf2_InvalidEncoding,
    };

    var derived: [DERIVED_LENGTH]u8 = undefined;
    std.crypto.pwhash.pbkdf2(
        &derived,
        password_raw,
        &salt,
        rounds,
        HmacSha256,
    ) catch |err| switch (err) {
        error.WeakParameters => return Error.ZixUtils_PwhashPbkdf2_WeakParameters,
        error.OutputTooLong => return Error.ZixUtils_PwhashPbkdf2_OutputTooLong,
    };

    if (!std.crypto.timing_safe.eql([DERIVED_LENGTH]u8, derived, expected)) {
        return Error.ZixUtils_PwhashPbkdf2_PasswordVerificationFailed;
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils: pwhash pbkdf2, hashes and verifies a password" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const password = "my sUp3r p4s5w0rd!";
    const rounds = 1_000;

    var buf: [128]u8 = undefined;
    const encoded = try hash(io, allocator, password, rounds, &buf);

    try std.testing.expect(std.mem.startsWith(u8, encoded, "$pbkdf2-sha256$i=1000$"));
    try verify(allocator, password, encoded);
}

test "zix utils: pwhash pbkdf2, rejects a wrong password" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var buf: [128]u8 = undefined;
    const encoded = try hash(io, allocator, "my sUp3r p4s5w0rd!", 1_000, &buf);

    try std.testing.expectError(
        Error.ZixUtils_PwhashPbkdf2_PasswordVerificationFailed,
        verify(allocator, "wrong password", encoded),
    );
}

test "zix utils: pwhash pbkdf2, rejects zero rounds" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var buf: [128]u8 = undefined;

    try std.testing.expectError(
        Error.ZixUtils_PwhashPbkdf2_WeakParameters,
        hash(io, allocator, "password", 0, &buf),
    );
}

test "zix utils: pwhash pbkdf2, rejects a malformed encoded hash" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        Error.ZixUtils_PwhashPbkdf2_InvalidEncoding,
        verify(allocator, "password", "not-a-hash"),
    );
    try std.testing.expectError(
        Error.ZixUtils_PwhashPbkdf2_InvalidEncoding,
        verify(allocator, "password", "$pbkdf2-sha256$i=x$salt$hash"),
    );
}

test "zix utils: pwhash pbkdf2, rejects a short output buffer" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var buf: [8]u8 = undefined;

    try std.testing.expectError(
        Error.ZixUtils_PwhashPbkdf2_NoSpaceLeft,
        hash(io, allocator, "password", 1_000, &buf),
    );
}

