//! TLZ record
//!
//! ### file: src/tlz/src/record.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! TLS 1.3 record protection (RFC 8446 section 5): AEAD protect and deprotect,
//! the per-record nonce, and the record size limits.
//!
//! ### note:
//!
//! - AES-128-GCM only (the mandatory suite, RFC 8446 9.1).
//! - Speed depends on the build CPU target. std.crypto picks the AES-GCM backend at
//!   comptime: the fast path needs the `aes` and `pclmul` CPU features
//!   (`x86_64_v3` does not include them). Without them the software path is about
//!   40x slower. Build with `-Dcpu=native` or `-Dcpu=x86_64_v3+aes+pclmul`.
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
const ContentType = @import("record/content_type.zig").ContentType;
const Opened = @import("record/Opened.zig");

const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;

// --------------------------------------------------------- //
// Private:

/// legacy_record_version on every TLS 1.3 record (RFC 8446 5.1).
const legacy_record_version: u16 = 0x0303;

/// The record header: content type, version, length.
const HEADER_LEN = 5;

// --------------------------------------------------------- //
// Public:

pub const Error = error{
    Tlz_Record_Overflow,
    Tlz_Record_BadMac,
    Tlz_Record_Decode,
};

pub const KEY_LENGTH = 16;
pub const IV_LENGTH = 12;
pub const TAG_LENGTH = Aes128Gcm.tag_length;

/// TLSPlaintext.length ceiling, 2^14 (RFC 8446 5.1).
pub const MAX_PLAINTEXT = 1 << 14;

/// TLSCiphertext.length ceiling, 2^14 + 256. Above it is record_overflow (RFC 8446 5.2).
pub const MAX_CIPHERTEXT = MAX_PLAINTEXT + 256;

/// Read staging for one on-wire record: the header plus the largest TLSCiphertext,
/// rounded up so any single record fits in one buffer.
pub const MAX_RECORD_WIRE = 17 * 1024;

/// Wire bytes one record costs beyond its plaintext: the header, the inner content
/// type, and the AEAD tag.
pub const RECORD_OVERHEAD = HEADER_LEN + 1 + TAG_LENGTH;

/// Per-record nonce: the static iv XOR the 64-bit sequence number, right-aligned
/// (RFC 8446 5.3).
///
/// Param:
/// iv - [IV_LENGTH]u8 (the static iv)
/// sequence - u64 (the record sequence number for this key)
///
/// Return:
/// - [IV_LENGTH]u8
pub fn nonce(iv: [IV_LENGTH]u8, sequence: u64) [IV_LENGTH]u8 {
    var out = iv;
    var sequence_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &sequence_bytes, sequence, .big);

    for (sequence_bytes, 0..) |byte, i| out[IV_LENGTH - 8 + i] ^= byte;

    return out;
}

/// Wire bytes needed to seal `plaintext_len` bytes, counting every record it takes.
///
/// Note:
/// - An empty plaintext is still one record, since the inner content type has to travel.
///
/// Param:
/// plaintext_len - usize (the bytes to seal)
///
/// Return:
/// - usize (what an output buffer must hold)
pub fn sealedLen(plaintext_len: usize) usize {
    const records = if (plaintext_len == 0)
        1
    else
        (plaintext_len + MAX_PLAINTEXT - 1) / MAX_PLAINTEXT;

    return plaintext_len + records * RECORD_OVERHEAD;
}

/// Protect two plaintext slices as one record: AEAD-seal (head || tail || inner type).
/// The gather form saves the caller a copy when a small prefix (a frame header)
/// goes in front of a large payload.
///
/// Note:
/// - One record only, so head.len + tail.len is at most `MAX_PLAINTEXT`. The seal
///   reads from a fixed record-sized stack buffer, so a longer input is refused,
///   never written.
///
/// Param:
/// out - []u8 (holds at least sealedLen(head.len + tail.len) bytes)
/// head - []const u8 (the first plaintext slice)
/// tail - []const u8 (the second plaintext slice)
/// inner_type - ContentType (the true content type, travels inside the AEAD)
/// key - [KEY_LENGTH]u8 (the AES-128-GCM key)
/// iv - [IV_LENGTH]u8 (the static iv)
/// sequence - u64 (the record sequence number for this key)
///
/// Return:
/// - []const u8 (the wire record, a view into `out`)
/// - empty when the plaintext exceeds `MAX_PLAINTEXT` or `out` is too small
pub fn protect2(
    out: []u8,
    head: []const u8,
    tail: []const u8,
    inner_type: ContentType,
    key: [KEY_LENGTH]u8,
    iv: [IV_LENGTH]u8,
    sequence: u64,
) []const u8 {
    const plaintext_len = head.len + tail.len;
    if (plaintext_len > MAX_PLAINTEXT) return out[0..0];

    const inner_len = plaintext_len + 1;
    const record_len = inner_len + TAG_LENGTH;
    if (out.len < HEADER_LEN + record_len) return out[0..0];

    out[0] = @intFromEnum(ContentType.APPLICATION_DATA);
    std.mem.writeInt(u16, out[1..3], legacy_record_version, .big);
    std.mem.writeInt(u16, out[3..5], @intCast(record_len), .big);

    var inner: [MAX_PLAINTEXT + 1]u8 = undefined;
    @memcpy(inner[0..head.len], head);
    @memcpy(inner[head.len..][0..tail.len], tail);
    inner[plaintext_len] = @intFromEnum(inner_type);

    const sealed = out[HEADER_LEN .. HEADER_LEN + inner_len];
    var tag: [TAG_LENGTH]u8 = undefined;
    Aes128Gcm.encrypt(
        sealed,
        &tag,
        inner[0..inner_len],
        out[0..HEADER_LEN],
        nonce(iv, sequence),
        key,
    );
    @memcpy(out[HEADER_LEN + inner_len ..][0..TAG_LENGTH], &tag);

    return out[0 .. HEADER_LEN + record_len];
}

/// Protect one plaintext as one record. Same bytes as `protect2` with an empty tail.
///
/// Param:
/// out - []u8 (holds at least sealedLen(plaintext.len) bytes)
/// plaintext - []const u8 (the bytes to protect, at most `MAX_PLAINTEXT`)
/// inner_type - ContentType (the true content type, travels inside the AEAD)
/// key - [KEY_LENGTH]u8 (the AES-128-GCM key)
/// iv - [IV_LENGTH]u8 (the static iv)
/// sequence - u64 (the record sequence number for this key)
///
/// Return:
/// - []const u8 (the wire record, a view into `out`)
/// - empty when the plaintext exceeds `MAX_PLAINTEXT` or `out` is too small
pub fn protect(
    out: []u8,
    plaintext: []const u8,
    inner_type: ContentType,
    key: [KEY_LENGTH]u8,
    iv: [IV_LENGTH]u8,
    sequence: u64,
) []const u8 {
    return protect2(out, plaintext, &.{}, inner_type, key, iv, sequence);
}

/// Deprotect a wire record: AEAD-open into `out`, strip the zero padding and the
/// inner content type (RFC 8446 5.2, 5.4).
///
/// Param:
/// out - []u8 (holds at least the ciphertext length)
/// record - []const u8 (one whole wire record, header included)
/// key - [KEY_LENGTH]u8 (the AES-128-GCM key)
/// iv - [IV_LENGTH]u8 (the static iv)
/// sequence - u64 (the record sequence number for this key)
///
/// Return:
/// - Opened (`data` is a view into `out`)
/// - Error.Tlz_Record_Overflow when the ciphertext exceeds `MAX_CIPHERTEXT`
/// - Error.Tlz_Record_BadMac when the AEAD tag does not verify
/// - Error.Tlz_Record_Decode when the record is truncated or all zero
pub fn deprotect(
    out: []u8,
    record: []const u8,
    key: [KEY_LENGTH]u8,
    iv: [IV_LENGTH]u8,
    sequence: u64,
) Error!Opened {
    if (record.len < HEADER_LEN + TAG_LENGTH) return Error.Tlz_Record_Decode;

    const header = record[0..HEADER_LEN];
    const body = record[HEADER_LEN..];
    if (body.len > MAX_CIPHERTEXT) return Error.Tlz_Record_Overflow;

    const ciphertext = body[0 .. body.len - TAG_LENGTH];
    var tag: [TAG_LENGTH]u8 = undefined;
    @memcpy(&tag, body[body.len - TAG_LENGTH ..]);

    const plaintext = out[0..ciphertext.len];
    Aes128Gcm.decrypt(
        plaintext,
        ciphertext,
        tag,
        header,
        nonce(iv, sequence),
        key,
    ) catch |err| switch (err) {
        error.AuthenticationFailed => return Error.Tlz_Record_BadMac,
    };

    var end = plaintext.len;
    while (end > 0 and plaintext[end - 1] == 0) end -= 1;
    if (end == 0) return Error.Tlz_Record_Decode;

    return .{
        .inner_type = @enumFromInt(plaintext[end - 1]),
        .data = plaintext[0 .. end - 1],
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const TEST_KEY_HEX = "3fce516009c21727d0f2e4e86ee403bc";
const TEST_IV_HEX = "5d313eb2671276ee13000b30";

fn testKey() ![KEY_LENGTH]u8 {
    var key: [KEY_LENGTH]u8 = undefined;
    _ = try std.fmt.hexToBytes(&key, TEST_KEY_HEX);

    return key;
}

fn testIv() ![IV_LENGTH]u8 {
    var iv: [IV_LENGTH]u8 = undefined;
    _ = try std.fmt.hexToBytes(&iv, TEST_IV_HEX);

    return iv;
}

test "tlz: nonce, sequence zero keeps the iv" {
    const iv = try testIv();

    try std.testing.expectEqualSlices(u8, &iv, &nonce(iv, 0));
}

test "tlz: nonce, sequence XORs the low bytes only" {
    const iv: [IV_LENGTH]u8 = @splat(0);

    const out = nonce(iv, 0x0102);

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x02 },
        &out,
    );
}

test "tlz: sealedLen, empty plaintext is still one record" {
    try std.testing.expectEqual(RECORD_OVERHEAD, sealedLen(0));
}

test "tlz: sealedLen, one byte is one record" {
    try std.testing.expectEqual(1 + RECORD_OVERHEAD, sealedLen(1));
}

test "tlz: sealedLen, exactly MAX_PLAINTEXT stays one record" {
    try std.testing.expectEqual(MAX_PLAINTEXT + RECORD_OVERHEAD, sealedLen(MAX_PLAINTEXT));
}

test "tlz: sealedLen, one past MAX_PLAINTEXT needs two records" {
    try std.testing.expectEqual(
        MAX_PLAINTEXT + 1 + 2 * RECORD_OVERHEAD,
        sealedLen(MAX_PLAINTEXT + 1),
    );
}

test "tlz: sealedLen, 64 KiB is four records" {
    try std.testing.expectEqual(65536 + 4 * RECORD_OVERHEAD, sealedLen(65536));
}

test "tlz: protect, outer type is application_data" {
    const key = try testKey();
    const iv = try testIv();
    var record_buf: [256]u8 = undefined;

    const rec = protect(&record_buf, "hello", .HANDSHAKE, key, iv, 0);

    try std.testing.expectEqual(@as(u8, 23), rec[0]);
}

test "tlz: protect, round trips through deprotect" {
    const key = try testKey();
    const iv = try testIv();
    const message = "hello over tls 1.3";
    var record_buf: [256]u8 = undefined;
    var plain_buf: [256]u8 = undefined;

    const rec = protect(&record_buf, message, .APPLICATION_DATA, key, iv, 0);
    const opened = try deprotect(&plain_buf, rec, key, iv, 0);

    try std.testing.expectEqual(ContentType.APPLICATION_DATA, opened.inner_type);
    try std.testing.expectEqualSlices(u8, message, opened.data);
}

test "tlz: protect, empty plaintext round trips" {
    const key = try testKey();
    const iv = try testIv();
    var record_buf: [64]u8 = undefined;
    var plain_buf: [64]u8 = undefined;

    const rec = protect(&record_buf, "", .ALERT, key, iv, 3);
    const opened = try deprotect(&plain_buf, rec, key, iv, 3);

    try std.testing.expectEqual(ContentType.ALERT, opened.inner_type);
    try std.testing.expectEqual(@as(usize, 0), opened.data.len);
}

test "tlz: protect, refuses plaintext past MAX_PLAINTEXT" {
    const key = try testKey();
    const iv = try testIv();

    const oversized = try std.testing.allocator.alloc(u8, MAX_PLAINTEXT + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');

    const out = try std.testing.allocator.alloc(u8, sealedLen(MAX_PLAINTEXT + 1));
    defer std.testing.allocator.free(out);

    const rec = protect(out, oversized, .APPLICATION_DATA, key, iv, 0);

    try std.testing.expectEqual(@as(usize, 0), rec.len);
}

test "tlz: protect, accepts exactly MAX_PLAINTEXT" {
    const key = try testKey();
    const iv = try testIv();

    const payload = try std.testing.allocator.alloc(u8, MAX_PLAINTEXT);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');

    const out = try std.testing.allocator.alloc(u8, sealedLen(MAX_PLAINTEXT));
    defer std.testing.allocator.free(out);

    const rec = protect(out, payload, .APPLICATION_DATA, key, iv, 0);

    try std.testing.expectEqual(sealedLen(MAX_PLAINTEXT), rec.len);
}

test "tlz: protect, refuses an output one byte too small" {
    const key = try testKey();
    const iv = try testIv();
    const message = "needs room for header and tag";
    var tight: [sealedLen(message.len) - 1]u8 = undefined;

    const rec = protect(&tight, message, .APPLICATION_DATA, key, iv, 0);

    try std.testing.expectEqual(@as(usize, 0), rec.len);
}

test "tlz: protect, fills an output of exact size" {
    const key = try testKey();
    const iv = try testIv();
    const message = "needs room for header and tag";
    var exact: [sealedLen(message.len)]u8 = undefined;

    const rec = protect(&exact, message, .APPLICATION_DATA, key, iv, 0);

    try std.testing.expectEqual(exact.len, rec.len);
}

test "tlz: protect2, equals protect on the concatenation" {
    const key = try testKey();
    const iv = try testIv();
    const prefix = "\x00\x00\x05\x00\x01\x00\x00\x00\x03";
    const payload = "abcde";
    var gathered_buf: [256]u8 = undefined;
    var ref_buf: [256]u8 = undefined;

    const gathered = protect2(&gathered_buf, prefix, payload, .APPLICATION_DATA, key, iv, 7);
    const ref = protect(&ref_buf, prefix ++ payload, .APPLICATION_DATA, key, iv, 7);

    try std.testing.expectEqualSlices(u8, ref, gathered);
}

test "tlz: protect2, round trips through deprotect" {
    const key = try testKey();
    const iv = try testIv();
    const prefix = "\x00\x00\x05\x00\x01\x00\x00\x00\x03";
    const payload = "abcde";
    var gathered_buf: [256]u8 = undefined;
    var plain_buf: [256]u8 = undefined;

    const gathered = protect2(&gathered_buf, prefix, payload, .APPLICATION_DATA, key, iv, 7);
    const opened = try deprotect(&plain_buf, gathered, key, iv, 7);

    try std.testing.expectEqualSlices(u8, prefix ++ payload, opened.data);
}

test "tlz: protect2, refuses a gather past MAX_PLAINTEXT" {
    const key = try testKey();
    const iv = try testIv();

    const tail = try std.testing.allocator.alloc(u8, MAX_PLAINTEXT);
    defer std.testing.allocator.free(tail);
    @memset(tail, 'y');

    const out = try std.testing.allocator.alloc(u8, sealedLen(MAX_PLAINTEXT + 8));
    defer std.testing.allocator.free(out);

    const rec = protect2(out, "prefix", tail, .APPLICATION_DATA, key, iv, 0);

    try std.testing.expectEqual(@as(usize, 0), rec.len);
}

test "tlz: protect2, accepts a gather of exactly MAX_PLAINTEXT" {
    const key = try testKey();
    const iv = try testIv();

    const tail = try std.testing.allocator.alloc(u8, MAX_PLAINTEXT - "prefix".len);
    defer std.testing.allocator.free(tail);
    @memset(tail, 'y');

    const out = try std.testing.allocator.alloc(u8, sealedLen(MAX_PLAINTEXT));
    defer std.testing.allocator.free(out);

    const rec = protect2(out, "prefix", tail, .APPLICATION_DATA, key, iv, 0);

    try std.testing.expectEqual(sealedLen(MAX_PLAINTEXT), rec.len);
}

test "tlz: deprotect, tampered tag is a bad MAC" {
    const key = try testKey();
    const iv = try testIv();
    var record_buf: [256]u8 = undefined;
    var plain_buf: [256]u8 = undefined;

    const rec = protect(&record_buf, "data", .APPLICATION_DATA, key, iv, 0);
    record_buf[rec.len - 1] ^= 0x01;

    try std.testing.expectError(
        Error.Tlz_Record_BadMac,
        deprotect(&plain_buf, record_buf[0..rec.len], key, iv, 0),
    );
}

test "tlz: deprotect, wrong sequence is a bad MAC" {
    const key = try testKey();
    const iv = try testIv();
    var record_buf: [256]u8 = undefined;
    var plain_buf: [256]u8 = undefined;

    const rec = protect(&record_buf, "data", .APPLICATION_DATA, key, iv, 0);

    try std.testing.expectError(
        Error.Tlz_Record_BadMac,
        deprotect(&plain_buf, rec, key, iv, 1),
    );
}

test "tlz: deprotect, ciphertext past MAX_CIPHERTEXT is an overflow" {
    const key = try testKey();
    const iv = try testIv();
    var plain_buf: [256]u8 = undefined;
    var oversize: [HEADER_LEN + MAX_CIPHERTEXT + 1]u8 = @splat(0);

    oversize[0] = 23;
    std.mem.writeInt(u16, oversize[1..3], legacy_record_version, .big);
    std.mem.writeInt(u16, oversize[3..5], MAX_CIPHERTEXT + 1, .big);

    try std.testing.expectError(
        Error.Tlz_Record_Overflow,
        deprotect(&plain_buf, &oversize, key, iv, 0),
    );
}

test "tlz: deprotect, record shorter than header and tag is a decode error" {
    const key = try testKey();
    const iv = try testIv();
    var plain_buf: [64]u8 = undefined;
    const short: [HEADER_LEN + TAG_LENGTH - 1]u8 = @splat(0);

    try std.testing.expectError(
        Error.Tlz_Record_Decode,
        deprotect(&plain_buf, &short, key, iv, 0),
    );
}

test "tlz: deprotect, all zero inner is a decode error" {
    const key = try testKey();
    const iv = try testIv();
    var record_buf: [64]u8 = undefined;
    var plain_buf: [64]u8 = undefined;

    const rec = protect2(&record_buf, "\x00\x00", "", @enumFromInt(0), key, iv, 0);

    try std.testing.expectError(
        Error.Tlz_Record_Decode,
        deprotect(&plain_buf, rec, key, iv, 0),
    );
}

test "tlz: deprotect, zero padding is stripped" {
    const key = try testKey();
    const iv = try testIv();
    var record_buf: [64]u8 = undefined;
    var plain_buf: [64]u8 = undefined;

    // inner type HANDSHAKE(22) followed by three bytes of zero padding
    const rec = protect2(&record_buf, "ok\x16\x00\x00", "", @enumFromInt(0), key, iv, 0);
    const opened = try deprotect(&plain_buf, rec, key, iv, 0);

    try std.testing.expectEqual(ContentType.HANDSHAKE, opened.inner_type);
    try std.testing.expectEqualSlices(u8, "ok", opened.data);
}

