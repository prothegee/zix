//! ZIX utils pwhash argon2
//!
//! ### file: src/zix/utils/pwhash/argon2.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Argon2 password hash and verification.
//! 
//! ### note:
//! 
//! Only PHC encoding is supported by argon2.
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
        error.OutOfMemory => Error.ZixUtils_PwhashArgon2_OutOfMemory,
        error.InvalidEncoding => Error.ZixUtils_PwhashArgon2_InvalidEncoding,
        error.NoSpaceLeft => Error.ZixUtils_PwhashArgon2_NoSpaceLeft,
        error.PasswordVerificationFailed =>
            Error.ZixUtils_PwhashArgon2_PasswordVerificationFailed,
        error.WeakParameters => Error.ZixUtils_PwhashArgon2_WeakParameters,
        error.AllocatorRequired => Error.ZixUtils_PwhashArgon2_AllocatorRequired,
        error.Canceled => Error.ZixUtils_PwhashArgon2_Canceled,
        else => Error.ZixUtils_PwhashArgon2_Failed,
    };
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_PwhashArgon2_OutOfMemory,
    ZixUtils_PwhashArgon2_InvalidEncoding,
    ZixUtils_PwhashArgon2_NoSpaceLeft,
    ZixUtils_PwhashArgon2_PasswordVerificationFailed,
    ZixUtils_PwhashArgon2_WeakParameters,
    ZixUtils_PwhashArgon2_AllocatorRequired,
    ZixUtils_PwhashArgon2_Canceled,
    ZixUtils_PwhashArgon2_Failed,
};

/// Create an argon2 password hash.
///
/// Param:
/// io - std.Io (the io the hash runs on)
/// allocator - std.mem.Allocator (used for the hash workspace)
/// password - []const u8 (plain password)
/// params - std.crypto.pwhash.argon2.Params (cost parameters)
/// encoding - std.crypto.pwhash.Encoding (only .phc is accepted)
/// buf - []u8 (output buffer, caller owns it)
///
/// Return:
/// - []const u8 (the encoded hash, borrowed from buf)
/// - Error.ZixUtils_PwhashArgon2_InvalidEncoding for a non-PHC encoding
/// - Error.ZixUtils_PwhashArgon2_NoSpaceLeft when buf is too small
/// - other members of Error when the hash fails
pub fn hash(
    io: std.Io,
    allocator: std.mem.Allocator,
    password: []const u8,
    params: std.crypto.pwhash.argon2.Params,
    encoding: std.crypto.pwhash.Encoding,
    buf: []u8,
) Error![]const u8 {
    return std.crypto.pwhash.argon2.strHash(
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

/// Verify an argon2 password hash.
///
/// Param:
/// io - std.Io (the io the verify runs on)
/// allocator - std.mem.Allocator (used for the verify workspace)
/// password_raw - []const u8 (plain password)
/// password_encoded - []const u8 (encoded hash to verify against)
///
/// Return:
/// - void on a match
/// - Error.ZixUtils_PwhashArgon2_PasswordVerificationFailed on a mismatch
/// - other members of Error when the encoded input is invalid
pub fn verify(
    io: std.Io,
    allocator: std.mem.Allocator,
    password_raw: []const u8,
    password_encoded: []const u8,
) Error!void {
    std.crypto.pwhash.argon2.strVerify(
        password_encoded,
        password_raw,
        .{ .allocator = allocator },
        io,
    ) catch |err| return mapError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils: pwhash argon2, hashes and verifies a password" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const password = "my sUp3r p4s5w0rd!";
    const mode = std.crypto.pwhash.Encoding.phc;

    var buf: [128]u8 = undefined;
    var params = std.crypto.pwhash.argon2.Params.sensitive_2id;
    params.t = 2;
    params.m = 2048;
    params.p = 1;

    const encoded = try hash(io, allocator, password, params, mode, &buf);
    try verify(io, allocator, password, encoded);
}

test "zix utils: pwhash argon2, rejects a wrong password" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const password = "my sUp3r p4s5w0rd!";

    var buf: [128]u8 = undefined;
    var params = std.crypto.pwhash.argon2.Params.sensitive_2id;
    params.t = 2;
    params.m = 2048;
    params.p = 1;

    const encoded = try hash(io, allocator, password, params, .phc, &buf);

    try std.testing.expectError(
        Error.ZixUtils_PwhashArgon2_PasswordVerificationFailed,
        verify(io, allocator, "wrong password", encoded),
    );
}

test "zix utils: pwhash argon2, rejects a crypt encoding" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var buf: [128]u8 = undefined;
    var params = std.crypto.pwhash.argon2.Params.sensitive_2id;
    params.t = 2;
    params.m = 2048;
    params.p = 1;

    try std.testing.expectError(
        Error.ZixUtils_PwhashArgon2_InvalidEncoding,
        hash(io, allocator, "password", params, .crypt, &buf),
    );
}

test "zix utils: pwhash argon2, rejects a short output buffer" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var buf: [8]u8 = undefined;
    var params = std.crypto.pwhash.argon2.Params.sensitive_2id;
    params.t = 2;
    params.m = 2048;
    params.p = 1;

    try std.testing.expectError(
        Error.ZixUtils_PwhashArgon2_NoSpaceLeft,
        hash(io, allocator, "password", params, .phc, &buf),
    );
}

