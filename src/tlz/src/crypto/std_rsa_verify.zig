//! TLZ crypto std_rsa_verify
//!
//! ### file: src/tlz/src/crypto/std_rsa_verify.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! std's RSA signature verify (RFC 8017), called the same way on every supported
//! toolchain. Used as the independent check a peer runs on a tlz signature.
//!
//! ### note:
//!
//! Zig 0.16 takes the signature by value, zig 0.17 by pointer. The branch the
//! running toolchain does not have never reaches the compiler, the condition is
//! comptime. The file goes away once only one toolchain is supported.
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
const builtin = @import("builtin");

const StdRsa = std.crypto.Certificate.rsa;

// --------------------------------------------------------- //
// Private:

/// std takes an RSA signature as a pointer rather than by value.
const SIG_BY_POINTER: bool = builtin.zig_version.minor != 16;

/// std's verify failures, the same set for PSS and PKCS#1 v1.5.
const StdVerifyError = StdRsa.PSSSignature.VerifyError || StdRsa.PKCS1v1_5Signature.VerifyError;

fn verifyError(err: StdVerifyError) Error {
    @branchHint(.cold);

    return switch (err) {
        error.InvalidSignature => Error.Tlz_StdRsaVerify_InvalidSignature,
        error.MessageTooLong => Error.Tlz_StdRsaVerify_MessageTooLong,
    };
}

// --------------------------------------------------------- //
// Public:

pub const Error = error{
    Tlz_StdRsaVerify_InvalidSignature,
    Tlz_StdRsaVerify_MessageTooLong,
};

/// std's PSS verifier can be called on this toolchain.
///
/// Note:
/// - True on Zig 0.16 and on Zig 0.17.0, which fixed the earlier PSS verify panic.
///   Kept so callers that check it keep compiling.
pub const PSS_USABLE: bool = true;

/// Verify an RSASSA-PSS signature through std (RFC 8017 8.1.2).
///
/// Param:
/// modulus_len - usize (comptime, key size in bytes, 256 for RSA-2048)
/// sig - *const [modulus_len]u8 (the signature, exactly one modulus wide)
/// msg - []const u8 (the signed content)
/// public_key - StdRsa.PublicKey (the key to check against)
/// Hash - type (comptime, the PSS hash, e.g. std.crypto.hash.sha2.Sha256)
///
/// Return:
/// - void when the signature verifies
/// - Error.Tlz_StdRsaVerify_InvalidSignature when it does not
/// - Error.Tlz_StdRsaVerify_MessageTooLong when the signature is not below the modulus
pub fn verifyPss(
    comptime modulus_len: usize,
    sig: *const [modulus_len]u8,
    msg: []const u8,
    public_key: StdRsa.PublicKey,
    comptime Hash: type,
) Error!void {
    const signature = if (SIG_BY_POINTER) sig else sig.*;

    StdRsa.PSSSignature.concatVerify(
        modulus_len,
        signature,
        &.{msg},
        public_key,
        Hash,
    ) catch |err| return verifyError(err);
}

/// Verify an RSASSA-PKCS1-v1_5 signature through std (RFC 8017 8.2.2).
///
/// Param:
/// modulus_len - usize (comptime, key size in bytes, 256 for RSA-2048)
/// sig - *const [modulus_len]u8 (the signature, exactly one modulus wide)
/// msg - []const u8 (the signed content)
/// public_key - StdRsa.PublicKey (the key to check against)
/// Hash - type (comptime, the digest the signature names)
///
/// Return:
/// - void when the signature verifies
/// - Error.Tlz_StdRsaVerify_InvalidSignature when it does not
/// - Error.Tlz_StdRsaVerify_MessageTooLong when the signature is not below the modulus
pub fn verifyPkcs1v15(
    comptime modulus_len: usize,
    sig: *const [modulus_len]u8,
    msg: []const u8,
    public_key: StdRsa.PublicKey,
    comptime Hash: type,
) Error!void {
    const signature = if (SIG_BY_POINTER) sig else sig.*;

    StdRsa.PKCS1v1_5Signature.verify(
        modulus_len,
        signature,
        msg,
        public_key,
        Hash,
    ) catch |err| return verifyError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz crypto: std_rsa_verify, signature passing follows the toolchain" {
    const on_016 = builtin.zig_version.minor == 16;

    try std.testing.expectEqual(!on_016, SIG_BY_POINTER);
}

test "tlz crypto: std_rsa_verify, PSS_USABLE is true on supported toolchains" {
    try std.testing.expect(PSS_USABLE);
}

test "tlz crypto: std_rsa_verify, verifyError maps InvalidSignature" {
    try std.testing.expectEqual(
        Error.Tlz_StdRsaVerify_InvalidSignature,
        verifyError(error.InvalidSignature),
    );
}

test "tlz crypto: std_rsa_verify, verifyError maps MessageTooLong" {
    try std.testing.expectEqual(
        Error.Tlz_StdRsaVerify_MessageTooLong,
        verifyError(error.MessageTooLong),
    );
}

