//! TLZ tls12 record
//!
//! ### file: src/tlz/src/tls12/record.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! TLS 1.2 record protection for the AES-128-GCM suites (RFC 5246 6.2, RFC 5288).
//!
//! ### note:
//!
//! Unlike TLS 1.3 `record.zig`: the nonce is a 4-byte salt ++ an 8-byte explicit
//! nonce sent on the wire, and the AAD is 13 bytes (seq ++ type ++ version ++ length).
//! The explicit nonce is the 64-bit sequence number.
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
const KeyMaterial = @import("prf/KeyMaterial.zig");

const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;

// --------------------------------------------------------- //
// Private:

const AAD_LENGTH = 13;
const HEADER_LEN = 5;
const VERSION_TLS_1_2: u16 = 0x0303;

/// 13-byte AEAD additional data (RFC 5246 6.2.3.3): seq ++ type ++ version ++ length.
fn buildAad(seq: u64, content_type: u8, plaintext_len: u16) [AAD_LENGTH]u8 {
    var aad: [AAD_LENGTH]u8 = undefined;
    std.mem.writeInt(u64, aad[0..8], seq, .big);
    aad[8] = content_type;
    std.mem.writeInt(u16, aad[9..11], VERSION_TLS_1_2, .big);
    std.mem.writeInt(u16, aad[11..13], plaintext_len, .big);

    return aad;
}

// --------------------------------------------------------- //
// Public:

pub const Error = error{
    Tlz_Tls12Record_BadRecord,
    Tlz_Tls12Record_AuthenticationFailed,
};

pub const KEY_LENGTH = KeyMaterial.KEY_LENGTH;
pub const SALT_LENGTH = KeyMaterial.SALT_LENGTH;
pub const EXPLICIT_NONCE_LENGTH = 8;
pub const TAG_LENGTH = Aes128Gcm.tag_length;

/// TLSPlaintext.length ceiling, 2^14 (RFC 5246 6.2.1).
pub const MAX_PLAINTEXT = 1 << 14;

/// Wire bytes one record costs beyond its plaintext: header, explicit nonce, tag.
pub const RECORD_OVERHEAD = HEADER_LEN + EXPLICIT_NONCE_LENGTH + TAG_LENGTH;

/// Encrypt one record. Wire layout: type ++ 0x0303 ++ length ++ explicit_nonce ++
/// ciphertext ++ tag.
///
/// Param:
/// out - []u8 (at least plaintext.len + RECORD_OVERHEAD bytes)
/// plaintext - []const u8 (at most MAX_PLAINTEXT bytes)
/// content_type - u8 (the record content type, carried in the clear)
/// key - [KEY_LENGTH]u8 (the write key)
/// salt - [SALT_LENGTH]u8 (the implicit write IV)
/// seq - u64 (the record sequence number, also the explicit nonce)
///
/// Return:
/// - []const u8 (the wire record, a view into `out`)
/// - empty when the plaintext is over MAX_PLAINTEXT or `out` is too small
pub fn protect(
    out: []u8,
    plaintext: []const u8,
    content_type: u8,
    key: [KEY_LENGTH]u8,
    salt: [SALT_LENGTH]u8,
    seq: u64,
) []const u8 {
    if (plaintext.len > MAX_PLAINTEXT) return out[0..0];
    if (out.len < plaintext.len + RECORD_OVERHEAD) return out[0..0];

    var nonce: [12]u8 = undefined;
    @memcpy(nonce[0..SALT_LENGTH], &salt);
    std.mem.writeInt(u64, nonce[SALT_LENGTH..][0..EXPLICIT_NONCE_LENGTH], seq, .big);

    const aad = buildAad(seq, content_type, @intCast(plaintext.len));
    const body_len = EXPLICIT_NONCE_LENGTH + plaintext.len + TAG_LENGTH;
    const ct_start = HEADER_LEN + EXPLICIT_NONCE_LENGTH;
    const ct = out[ct_start .. ct_start + plaintext.len];
    var tag: [TAG_LENGTH]u8 = undefined;

    out[0] = content_type;
    std.mem.writeInt(u16, out[1..3], VERSION_TLS_1_2, .big);
    std.mem.writeInt(u16, out[3..5], @intCast(body_len), .big);
    @memcpy(out[HEADER_LEN..ct_start], nonce[SALT_LENGTH..]);

    Aes128Gcm.encrypt(ct, &tag, plaintext, &aad, nonce, key);
    @memcpy(out[ct_start + plaintext.len ..][0..TAG_LENGTH], &tag);

    return out[0 .. HEADER_LEN + body_len];
}

/// Decrypt one record into `out` and check its tag.
///
/// Param:
/// out - []u8 (holds at least the ciphertext length)
/// rec - []const u8 (one whole wire record, header included)
/// key - [KEY_LENGTH]u8 (the peer write key)
/// salt - [SALT_LENGTH]u8 (the peer implicit write IV)
/// seq - u64 (the expected receive sequence number)
///
/// Return:
/// - []const u8 (the plaintext, a view into `out`)
/// - Error.Tlz_Tls12Record_BadRecord when the record is too short or `out` is too small
/// - Error.Tlz_Tls12Record_AuthenticationFailed when the tag does not match
pub fn deprotect(
    out: []u8,
    rec: []const u8,
    key: [KEY_LENGTH]u8,
    salt: [SALT_LENGTH]u8,
    seq: u64,
) Error![]const u8 {
    if (rec.len < HEADER_LEN + EXPLICIT_NONCE_LENGTH + TAG_LENGTH) {
        return Error.Tlz_Tls12Record_BadRecord;
    }

    const content_type = rec[0];
    const body = rec[HEADER_LEN..];
    const ct = body[EXPLICIT_NONCE_LENGTH .. body.len - TAG_LENGTH];
    if (ct.len > out.len or ct.len > MAX_PLAINTEXT) return Error.Tlz_Tls12Record_BadRecord;

    var nonce: [12]u8 = undefined;
    @memcpy(nonce[0..SALT_LENGTH], &salt);
    @memcpy(nonce[SALT_LENGTH..], body[0..EXPLICIT_NONCE_LENGTH]);

    var tag: [TAG_LENGTH]u8 = undefined;
    @memcpy(&tag, body[body.len - TAG_LENGTH ..]);

    const aad = buildAad(seq, content_type, @intCast(ct.len));

    Aes128Gcm.decrypt(out[0..ct.len], ct, tag, &aad, nonce, key) catch |err| switch (err) {
        error.AuthenticationFailed => return Error.Tlz_Tls12Record_AuthenticationFailed,
    };

    return out[0..ct.len];
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const TEST_KEY: [KEY_LENGTH]u8 = @splat(0xAB);
const TEST_SALT = [SALT_LENGTH]u8{
    0xDE,
    0xAD,
    0xBE,
    0xEF,
};

test "tlz tls12: record, AAD byte layout follows RFC 5246 6.2.3.3" {
    const aad = buildAad(0x0102030405060708, 23, 0x0014);
    const expected = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        23,   0x03, 0x03, 0x00, 0x14,
    };

    try std.testing.expectEqualSlices(u8, &expected, &aad);
}

test "tlz tls12: record, protect round trips through deprotect" {
    var rec_buf: [256]u8 = undefined;
    var plain_buf: [256]u8 = undefined;

    const rec = protect(&rec_buf, "hello tls 1.2 record", 23, TEST_KEY, TEST_SALT, 7);
    const opened = try deprotect(&plain_buf, rec, TEST_KEY, TEST_SALT, 7);

    try std.testing.expectEqualSlices(u8, "hello tls 1.2 record", opened);
}

test "tlz tls12: record, explicit nonce is the sequence number" {
    var rec_buf: [256]u8 = undefined;

    const rec = protect(&rec_buf, "abc", 23, TEST_KEY, TEST_SALT, 7);

    try std.testing.expectEqual(@as(u8, 23), rec[0]);
    try std.testing.expectEqual(@as(u64, 7), std.mem.readInt(u64, rec[5..13], .big));
    try std.testing.expectEqual(@as(usize, 3 + RECORD_OVERHEAD), rec.len);
}

test "tlz tls12: record, tampered tag fails authentication" {
    var rec_buf: [128]u8 = undefined;
    var plain_buf: [128]u8 = undefined;

    const rec = protect(&rec_buf, "abc", 23, TEST_KEY, TEST_SALT, 0);
    rec_buf[rec.len - 1] ^= 0x01;

    try std.testing.expectError(
        Error.Tlz_Tls12Record_AuthenticationFailed,
        deprotect(&plain_buf, rec, TEST_KEY, TEST_SALT, 0),
    );
}

test "tlz tls12: record, wrong sequence fails authentication" {
    var rec_buf: [128]u8 = undefined;
    var plain_buf: [128]u8 = undefined;

    const rec = protect(&rec_buf, "abc", 23, TEST_KEY, TEST_SALT, 1);

    try std.testing.expectError(
        Error.Tlz_Tls12Record_AuthenticationFailed,
        deprotect(&plain_buf, rec, TEST_KEY, TEST_SALT, 2),
    );
}

test "tlz tls12: record, short record is a bad record" {
    const short = [_]u8{ 23, 0x03, 0x03, 0x00, 0x04, 1, 2, 3, 4 };
    var plain_buf: [64]u8 = undefined;

    try std.testing.expectError(
        Error.Tlz_Tls12Record_BadRecord,
        deprotect(&plain_buf, &short, TEST_KEY, TEST_SALT, 0),
    );
}

test "tlz tls12: record, deprotect into a small buffer is a bad record" {
    var rec_buf: [128]u8 = undefined;
    var plain_buf: [2]u8 = undefined;

    const rec = protect(&rec_buf, "abcdef", 23, TEST_KEY, TEST_SALT, 0);

    try std.testing.expectError(
        Error.Tlz_Tls12Record_BadRecord,
        deprotect(&plain_buf, rec, TEST_KEY, TEST_SALT, 0),
    );
}

test "tlz tls12: record, protect into a small buffer is empty" {
    var rec_buf: [RECORD_OVERHEAD + 2]u8 = undefined;

    const rec = protect(&rec_buf, "abc", 23, TEST_KEY, TEST_SALT, 0);

    try std.testing.expectEqual(@as(usize, 0), rec.len);
}

test "tlz tls12: record, empty plaintext round trips" {
    var rec_buf: [64]u8 = undefined;
    var plain_buf: [64]u8 = undefined;

    const rec = protect(&rec_buf, "", 21, TEST_KEY, TEST_SALT, 3);
    const opened = try deprotect(&plain_buf, rec, TEST_KEY, TEST_SALT, 3);

    try std.testing.expectEqual(@as(usize, 0), opened.len);
}

test "tlz tls12: record, AEAD matches NIST AES-128-GCM test case 4" {
    var key: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&key, "feffe9928665731c6d6a8f9467308308");
    var nonce: [12]u8 = undefined;
    _ = try std.fmt.hexToBytes(&nonce, "cafebabefacedbaddecaf888");
    var aad: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&aad, "feedfacedeadbeeffeedfacedeadbeefabaddad2");
    var plaintext: [60]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &plaintext,
        "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72" ++
            "1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39",
    );
    var expected_ct: [60]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_ct,
        "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e" ++
            "21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091",
    );
    var expected_tag: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_tag, "5bc94fbc3221a5db94fae95ae7121a47");
    var ct: [60]u8 = undefined;
    var tag: [16]u8 = undefined;

    Aes128Gcm.encrypt(&ct, &tag, &plaintext, &aad, nonce, key);

    try std.testing.expectEqualSlices(u8, &expected_ct, &ct);
    try std.testing.expectEqualSlices(u8, &expected_tag, &tag);
}

