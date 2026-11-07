//! ZIX utils pwhash bcrypt
//!
//! ### file: src/zix/utils/pwhash/bcrypt.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Bcrypt password hash and verification.
//! 
//! ### note:
//! 
//! Verification does not silently truncate passwords past 72 bytes.
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

fn mapError(err: std.crypto.pwhash.Error) Error {
    return switch (err) {
        error.OutOfMemory => Error.ZixUtils_PwhashBcrypt_OutOfMemory,
        error.InvalidEncoding => Error.ZixUtils_PwhashBcrypt_InvalidEncoding,
        error.NoSpaceLeft => Error.ZixUtils_PwhashBcrypt_NoSpaceLeft,
        error.PasswordVerificationFailed =>
            Error.ZixUtils_PwhashBcrypt_PasswordVerificationFailed,
        error.WeakParameters => Error.ZixUtils_PwhashBcrypt_WeakParameters,
        error.AllocatorRequired => Error.ZixUtils_PwhashBcrypt_AllocatorRequired,
        error.Canceled => Error.ZixUtils_PwhashBcrypt_Canceled,
        else => Error.ZixUtils_PwhashBcrypt_Failed,
    };
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_PwhashBcrypt_OutOfMemory,
    ZixUtils_PwhashBcrypt_InvalidEncoding,
    ZixUtils_PwhashBcrypt_NoSpaceLeft,
    ZixUtils_PwhashBcrypt_PasswordVerificationFailed,
    ZixUtils_PwhashBcrypt_WeakParameters,
    ZixUtils_PwhashBcrypt_AllocatorRequired,
    ZixUtils_PwhashBcrypt_Canceled,
    ZixUtils_PwhashBcrypt_Failed,
};

/// Create a bcrypt password hash.
///
/// Param:
/// io - std.Io (the io the hash runs on)
/// allocator - std.mem.Allocator (used for the hash workspace)
/// password - []const u8 (plain password)
/// params - std.crypto.pwhash.bcrypt.Params (cost parameters)
/// encoding - std.crypto.pwhash.Encoding (crypt or PHC)
/// buf - []u8 (output buffer, caller owns it)
///
/// Return:
/// - []const u8 (the encoded hash, borrowed from buf)
/// - Error.ZixUtils_PwhashBcrypt_NoSpaceLeft when buf is too small
/// - other members of Error when the hash fails
pub fn hash(
    io: std.Io,
    allocator: std.mem.Allocator,
    password: []const u8,
    params: std.crypto.pwhash.bcrypt.Params,
    encoding: std.crypto.pwhash.Encoding,
    buf: []u8,
) Error![]const u8 {
    return std.crypto.pwhash.bcrypt.strHash(
        password,
        .{
            .allocator = allocator,
            .params = params,
            .encoding = encoding,
        },
        buf,
        io,
    ) catch |err| return mapError(err);
}

/// Verify a bcrypt password hash.
///
/// Param:
/// allocator - std.mem.Allocator (used for the verify workspace)
/// password_raw - []const u8 (plain password)
/// password_encoded - []const u8 (encoded hash to verify against)
///
/// Return:
/// - void on a match
/// - Error.ZixUtils_PwhashBcrypt_PasswordVerificationFailed on a mismatch
/// - other members of Error when the encoded input is invalid
pub fn verify(
    allocator: std.mem.Allocator,
    password_raw: []const u8,
    password_encoded: []const u8,
) Error!void {
    std.crypto.pwhash.bcrypt.strVerify(
        password_encoded,
        password_raw,
        .{
            .allocator = allocator,
            .silently_truncate_password = false,
        },
    ) catch |err| return mapError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils: pwhash bcrypt, hashes and verifies a password" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const password = "my sUp3r p4s5w0rd!";
    const encoding = std.crypto.pwhash.Encoding.crypt;

    var buf: [128]u8 = undefined;
    const params = std.crypto.pwhash.bcrypt.Params.owasp;

    const encoded = try hash(io, allocator, password, params, encoding, &buf);
    try verify(allocator, password, encoded);
}

test "zix utils: pwhash bcrypt, rejects a wrong password" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const password = "my sUp3r p4s5w0rd!";

    var buf: [128]u8 = undefined;
    const params = std.crypto.pwhash.bcrypt.Params.owasp;

    const encoded = try hash(io, allocator, password, params, .crypt, &buf);

    try std.testing.expectError(
        Error.ZixUtils_PwhashBcrypt_PasswordVerificationFailed,
        verify(allocator, "wrong password", encoded),
    );
}

test "zix utils: pwhash bcrypt, rejects a short output buffer" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var buf: [8]u8 = undefined;
    const params = std.crypto.pwhash.bcrypt.Params.owasp;

    try std.testing.expectError(
        Error.ZixUtils_PwhashBcrypt_NoSpaceLeft,
        hash(io, allocator, "password", params, .crypt, &buf),
    );
}

test "zix utils: pwhash bcrypt, rejects a malformed encoded hash" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        Error.ZixUtils_PwhashBcrypt_InvalidEncoding,
        verify(allocator, "password", "not-a-hash"),
    );
}

