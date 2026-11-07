//! ZIX utils pwhash scrypt
//!
//! ### file: src/zix/utils/pwhash/scrypt.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Scrypt password hash and verification.
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

// --------------------------------------------------------- //
// Private:

fn mapError(err: std.crypto.pwhash.Error) Error {
    return switch (err) {
        error.OutOfMemory => Error.ZixUtils_PwhashScrypt_OutOfMemory,
        error.InvalidEncoding => Error.ZixUtils_PwhashScrypt_InvalidEncoding,
        error.NoSpaceLeft => Error.ZixUtils_PwhashScrypt_NoSpaceLeft,
        error.PasswordVerificationFailed =>
            Error.ZixUtils_PwhashScrypt_PasswordVerificationFailed,
        error.WeakParameters => Error.ZixUtils_PwhashScrypt_WeakParameters,
        error.AllocatorRequired => Error.ZixUtils_PwhashScrypt_AllocatorRequired,
        error.Canceled => Error.ZixUtils_PwhashScrypt_Canceled,
        else => Error.ZixUtils_PwhashScrypt_Failed,
    };
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_PwhashScrypt_OutOfMemory,
    ZixUtils_PwhashScrypt_InvalidEncoding,
    ZixUtils_PwhashScrypt_NoSpaceLeft,
    ZixUtils_PwhashScrypt_PasswordVerificationFailed,
    ZixUtils_PwhashScrypt_WeakParameters,
    ZixUtils_PwhashScrypt_AllocatorRequired,
    ZixUtils_PwhashScrypt_Canceled,
    ZixUtils_PwhashScrypt_Failed,
};

/// Create a scrypt password hash.
///
/// Param:
/// io - std.Io (the io the hash runs on)
/// allocator - std.mem.Allocator (used for the hash workspace)
/// password - []const u8 (plain password)
/// params - std.crypto.pwhash.scrypt.Params (cost parameters)
/// encoding - std.crypto.pwhash.Encoding (crypt or PHC)
/// buf - []u8 (output buffer, caller owns it)
///
/// Return:
/// - []const u8 (the encoded hash, borrowed from buf)
/// - Error.ZixUtils_PwhashScrypt_NoSpaceLeft when buf is too small
/// - other members of Error when the hash fails
pub fn hash(
    io: std.Io,
    allocator: std.mem.Allocator,
    password: []const u8,
    params: std.crypto.pwhash.scrypt.Params,
    encoding: std.crypto.pwhash.Encoding,
    buf: []u8,
) Error![]const u8 {
    return std.crypto.pwhash.scrypt.strHash(
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

/// Verify a scrypt password hash.
///
/// Param:
/// allocator - std.mem.Allocator (used for the verify workspace)
/// password_raw - []const u8 (plain password)
/// password_encoded - []const u8 (encoded hash to verify against)
///
/// Return:
/// - void on a match
/// - Error.ZixUtils_PwhashScrypt_PasswordVerificationFailed on a mismatch
/// - other members of Error when the encoded input is invalid
pub fn verify(
    allocator: std.mem.Allocator,
    password_raw: []const u8,
    password_encoded: []const u8,
) Error!void {
    std.crypto.pwhash.scrypt.strVerify(
        password_encoded,
        password_raw,
        .{ .allocator = allocator },
    ) catch |err| return mapError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils: pwhash scrypt, hashes and verifies a password" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const password = "my sUp3r p4s5w0rd!";

    var buf: [128]u8 = undefined;
    var params = std.crypto.pwhash.scrypt.Params.sensitive;
    params.ln = 2;
    params.r = 2048;
    params.p = 1;

    const encoded = try hash(io, allocator, password, params, .phc, &buf);
    try verify(allocator, password, encoded);
}

test "zix utils: pwhash scrypt, rejects a wrong password" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const password = "my sUp3r p4s5w0rd!";

    var buf: [128]u8 = undefined;
    var params = std.crypto.pwhash.scrypt.Params.sensitive;
    params.ln = 2;
    params.r = 2048;
    params.p = 1;

    const encoded = try hash(io, allocator, password, params, .phc, &buf);

    try std.testing.expectError(
        Error.ZixUtils_PwhashScrypt_PasswordVerificationFailed,
        verify(allocator, "wrong password", encoded),
    );
}

test "zix utils: pwhash scrypt, rejects a short output buffer" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var buf: [8]u8 = undefined;
    var params = std.crypto.pwhash.scrypt.Params.sensitive;
    params.ln = 2;
    params.r = 2048;
    params.p = 1;

    try std.testing.expectError(
        Error.ZixUtils_PwhashScrypt_NoSpaceLeft,
        hash(io, allocator, "password", params, .phc, &buf),
    );
}

test "zix utils: pwhash scrypt, rejects a malformed encoded hash" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        Error.ZixUtils_PwhashScrypt_InvalidEncoding,
        verify(allocator, "password", "not-a-hash"),
    );
}

