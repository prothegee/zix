//! TLZ crypto pem
//!
//! ### file: src/tlz/src/crypto/pem.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! PEM to DER decoding, plus raw private key extraction for ECDSA P-256 (SEC1) and
//! Ed25519 (PKCS#8).
//!
//! ### note:
//!
//! `pemToDer` strips the BEGIN and END armor lines and base64-decodes the body.
//! A PEM body above `MAX_PEM_BYTES` of base64 is refused.
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
const DerReader = @import("DerReader.zig");

// --------------------------------------------------------- //
// Private:

/// The key parse path: the DER cursor plus this module's own key error.
const KeyInner = KeyError || DerReader.Error;

/// Raw key size for both P-256 scalars and Ed25519 seeds.
const KEY_LEN: usize = 32;

fn ecdsaScalarInner(der: []const u8) KeyInner![KEY_LEN]u8 {
    var reader: DerReader = .{ .buf = der };

    try reader.expectTag(DerReader.TAG_SEQUENCE);
    _ = try reader.readLen();
    try reader.skipElement(DerReader.TAG_INTEGER);
    try reader.expectTag(DerReader.TAG_OCTET_STRING);
    if (try reader.readLen() != KEY_LEN) return error.Tlz_Pem_InvalidKey;

    var out: [KEY_LEN]u8 = undefined;
    @memcpy(&out, try reader.readBytes(KEY_LEN));

    return out;
}

fn ed25519SeedInner(der: []const u8) KeyInner![KEY_LEN]u8 {
    var reader: DerReader = .{ .buf = der };

    try reader.expectTag(DerReader.TAG_SEQUENCE);
    _ = try reader.readLen();
    try reader.skipElement(DerReader.TAG_INTEGER);
    try reader.skipElement(DerReader.TAG_SEQUENCE);
    try reader.expectTag(DerReader.TAG_OCTET_STRING);
    _ = try reader.readLen();
    try reader.expectTag(DerReader.TAG_OCTET_STRING);
    if (try reader.readLen() != KEY_LEN) return error.Tlz_Pem_InvalidKey;

    var out: [KEY_LEN]u8 = undefined;
    @memcpy(&out, try reader.readBytes(KEY_LEN));

    return out;
}

fn keyError(err: KeyInner) KeyError {
    @branchHint(.cold);

    return switch (err) {
        error.Tlz_DerReader_Malformed => error.Tlz_Pem_InvalidKey,
        error.Tlz_Pem_InvalidKey => |own| own,
    };
}

fn base64Error(err: std.base64.Error) DecodeError {
    @branchHint(.cold);

    return switch (err) {
        error.InvalidCharacter => error.Tlz_Pem_Invalid,
        error.InvalidPadding => error.Tlz_Pem_Invalid,
        error.NoSpaceLeft => error.Tlz_Pem_BufferTooSmall,
    };
}

// --------------------------------------------------------- //
// Public:

pub const Error = error{
    Tlz_Pem_Invalid,
    Tlz_Pem_InvalidKey,
    Tlz_Pem_BufferTooSmall,
};

/// The part of Error `pemToDer` can return.
pub const DecodeError = error{
    Tlz_Pem_Invalid,
    Tlz_Pem_BufferTooSmall,
};

/// The part of Error the key extractors can return.
pub const KeyError = error{
    Tlz_Pem_InvalidKey,
};

/// Base64 accumulation cap: the largest PEM certificate or key body accepted.
pub const MAX_PEM_BYTES: usize = 16384;

/// Decode a PEM document body to DER.
///
/// Param:
/// out - []u8 (the DER destination)
/// pem - []const u8 (the PEM text, armor lines included)
///
/// Return:
/// - []const u8 (the DER, a view into `out`)
/// - Error.Tlz_Pem_BufferTooSmall when the body or the DER does not fit
/// - Error.Tlz_Pem_Invalid when the body is not valid base64
pub fn pemToDer(out: []u8, pem: []const u8) DecodeError![]const u8 {
    var b64: [MAX_PEM_BYTES]u8 = undefined;
    var b64_len: usize = 0;

    var lines = std.mem.tokenizeScalar(u8, pem, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0 or std.mem.startsWith(u8, line, "-----")) continue;
        if (b64_len + line.len > b64.len) return error.Tlz_Pem_BufferTooSmall;

        @memcpy(b64[b64_len..][0..line.len], line);
        b64_len += line.len;
    }

    const decoder = std.base64.standard.Decoder;
    const body = b64[0..b64_len];
    const der_len = decoder.calcSizeForSlice(body) catch |err| return base64Error(err);
    if (der_len > out.len) return error.Tlz_Pem_BufferTooSmall;

    decoder.decode(out[0..der_len], body) catch |err| return base64Error(err);

    return out[0..der_len];
}

/// Extract the 32-byte private scalar from a SEC1 ECPrivateKey DER (RFC 5915):
/// SEQUENCE { INTEGER version, OCTET STRING privateKey(32), ... }.
///
/// Param:
/// der - []const u8 (the decoded key DER)
///
/// Return:
/// - [32]u8
/// - Error.Tlz_Pem_InvalidKey when the DER is malformed or the key is not 32 bytes
pub fn ecdsaScalarFromSec1(der: []const u8) KeyError![KEY_LEN]u8 {
    return ecdsaScalarInner(der) catch |err| keyError(err);
}

/// Extract the 32-byte Ed25519 seed from a PKCS#8 PrivateKeyInfo DER (RFC 8410):
/// SEQUENCE { INTEGER version, SEQUENCE algorithm, OCTET STRING { OCTET STRING seed } }.
///
/// Param:
/// der - []const u8 (the decoded key DER)
///
/// Return:
/// - [32]u8
/// - Error.Tlz_Pem_InvalidKey when the DER is malformed or the seed is not 32 bytes
pub fn ed25519SeedFromPkcs8(der: []const u8) KeyError![KEY_LEN]u8 {
    return ed25519SeedInner(der) catch |err| keyError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const EC_KEY_PEM =
    \\-----BEGIN EC PRIVATE KEY-----
    \\MHcCAQEEIAt29/HHv24gAp3bVmeV5Y2lumP/vbkUv2mb++0xR9MsoAoGCCqGSM49
    \\AwEHoUQDQgAEwqASGymKyc04kgDnjZTnveHMfNgHR5X6tPkZeZ1A/cIxxakJkKyM
    \\YWauRy8z90/O0Jfy7be4oZdL5mpKsH8lOw==
    \\-----END EC PRIVATE KEY-----
;

const EC_SCALAR_HEX = "0b76f7f1c7bf6e20029ddb566795e58da5ba63ffbdb914bf699bfbed3147d32c";

const ED25519_KEY_PEM =
    \\-----BEGIN PRIVATE KEY-----
    \\MC4CAQAwBQYDK2VwBCIEIFwpJTm6t3wxIBTGVqlD12tSAhCajuDznWINyTQWWiiM
    \\-----END PRIVATE KEY-----
;

const ED25519_SEED_HEX = "5c292539bab77c312014c656a943d76b5202109a8ee0f39d620dc934165a288c";

test "tlz crypto: pem, SEC1 ECDSA key gives the 32-byte scalar" {
    var der_buf: [256]u8 = undefined;
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, EC_SCALAR_HEX);

    const der = try pemToDer(&der_buf, EC_KEY_PEM);
    const scalar = try ecdsaScalarFromSec1(der);

    try std.testing.expectEqualSlices(u8, &expected, &scalar);
}

test "tlz crypto: pem, PKCS#8 Ed25519 key gives the 32-byte seed" {
    var der_buf: [128]u8 = undefined;
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, ED25519_SEED_HEX);

    const der = try pemToDer(&der_buf, ED25519_KEY_PEM);
    const seed = try ed25519SeedFromPkcs8(der);

    try std.testing.expectEqualSlices(u8, &expected, &seed);
}

test "tlz crypto: pem, Ed25519 seed builds a key pair" {
    var der_buf: [128]u8 = undefined;
    const der = try pemToDer(&der_buf, ED25519_KEY_PEM);
    const seed = try ed25519SeedFromPkcs8(der);

    const key_pair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);

    try std.testing.expectEqual(@as(usize, 32), key_pair.public_key.toBytes().len);
}

test "tlz crypto: pem, CRLF line endings decode" {
    var der_buf: [128]u8 = undefined;
    const crlf_pem = "-----BEGIN PRIVATE KEY-----\r\n" ++
        "MC4CAQAwBQYDK2VwBCIEIFwpJTm6t3wxIBTGVqlD12tSAhCajuDznWINyTQWWiiM\r\n" ++
        "-----END PRIVATE KEY-----\r\n";

    const der = try pemToDer(&der_buf, crlf_pem);

    try std.testing.expectEqual(@as(usize, 48), der.len);
}

test "tlz crypto: pem, invalid base64 is invalid" {
    var der_buf: [64]u8 = undefined;

    try std.testing.expectError(Error.Tlz_Pem_Invalid, pemToDer(&der_buf, "!!!!"));
}

test "tlz crypto: pem, DER larger than the output is too small" {
    var der_buf: [16]u8 = undefined;

    try std.testing.expectError(
        Error.Tlz_Pem_BufferTooSmall,
        pemToDer(&der_buf, ED25519_KEY_PEM),
    );
}

test "tlz crypto: pem, body past MAX_PEM_BYTES is too small" {
    var der_buf: [64]u8 = undefined;
    const oversized = try std.testing.allocator.alloc(u8, MAX_PEM_BYTES + 4);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'A');

    try std.testing.expectError(Error.Tlz_Pem_BufferTooSmall, pemToDer(&der_buf, oversized));
}

test "tlz crypto: pem, armor only decodes to empty DER" {
    var der_buf: [16]u8 = undefined;

    const der = try pemToDer(&der_buf, "-----BEGIN X-----\n-----END X-----\n");

    try std.testing.expectEqual(@as(usize, 0), der.len);
}

test "tlz crypto: pem, ecdsaScalarFromSec1 on empty DER is an invalid key" {
    try std.testing.expectError(Error.Tlz_Pem_InvalidKey, ecdsaScalarFromSec1(&.{}));
}

test "tlz crypto: pem, ecdsaScalarFromSec1 with a short key is an invalid key" {
    const der = [_]u8{ 0x30, 0x08, 0x02, 0x01, 0x01, 0x04, 0x03, 0xaa, 0xbb, 0xcc };

    try std.testing.expectError(Error.Tlz_Pem_InvalidKey, ecdsaScalarFromSec1(&der));
}

test "tlz crypto: pem, ed25519SeedFromPkcs8 on a SEC1 key is an invalid key" {
    var der_buf: [256]u8 = undefined;
    const der = try pemToDer(&der_buf, EC_KEY_PEM);

    try std.testing.expectError(Error.Tlz_Pem_InvalidKey, ed25519SeedFromPkcs8(der));
}

