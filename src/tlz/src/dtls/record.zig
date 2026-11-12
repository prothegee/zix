//! TLZ dtls record
//!
//! ### file: src/tlz/src/dtls/record.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! DTLS 1.2 record layer (RFC 6347 4.1) for the AES-128-GCM suites: header codec,
//! record protection, and plaintext records for epoch 0.
//!
//! ### note:
//!
//! The header is 13 bytes against TLS 1.2's 5: it carries a 2-byte epoch and a 6-byte
//! sequence number. The AAD keeps the TLS 1.2 layout, with epoch and sequence packed
//! into the 64-bit slot (RFC 6347 4.1.2.1). An invalid record is discarded, never
//! fatal (RFC 6347 4.1.2.7). The wire version counts down: DTLS 1.2 is 0xFEFD.
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

const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;

// --------------------------------------------------------- //
// Private:

const AAD_LEN: usize = 13;

/// 13-byte AEAD additional data: seq ++ type ++ version ++ plaintext length
/// (RFC 5246 6.2.3.3 with the DTLS sequence and version).
fn buildAad(combined: u64, content_type: ContentType, plaintext_len: u16) [AAD_LEN]u8 {
    var aad: [AAD_LEN]u8 = undefined;
    std.mem.writeInt(u64, aad[0..8], combined, .big);
    aad[8] = @intFromEnum(content_type);
    std.mem.writeInt(u16, aad[9..11], VERSION_DTLS_1_2, .big);
    std.mem.writeInt(u16, aad[11..13], plaintext_len, .big);

    return aad;
}

/// Read the 48-bit sequence number, which has no readInt-sized type on the wire.
fn readSequenceNumber(bytes: *const [6]u8) u48 {
    var value: u48 = 0;
    for (bytes) |byte| value = (value << 8) | byte;

    return value;
}

fn writeSequenceNumber(out: *[6]u8, sequence_number: u48) void {
    for (out, 0..) |*byte, i| byte.* = @truncate(sequence_number >> @intCast(8 * (5 - i)));
}

// --------------------------------------------------------- //
// Public:

pub const ContentType = @import("../record/content_type.zig").ContentType;
pub const Header = @import("record/Header.zig");
pub const Opened = @import("record/Opened.zig");
pub const RecordIterator = @import("record/RecordIterator.zig");
pub const AntiReplay = @import("record/AntiReplay.zig");

/// What `parseHeader` and `plaintextFragment` can raise.
pub const ParseError = error{
    Tlz_DtlsRecord_Truncated,
};

/// What `protect` and `writePlaintext` can raise.
pub const WriteError = error{
    Tlz_DtlsRecord_BadRecord,
};

pub const Error = ParseError || WriteError || error{
    Tlz_DtlsRecord_AuthenticationFailed,
};

/// DTLS 1.2 on the wire, the 1's complement of 1.2 (RFC 6347 4.1).
pub const VERSION_DTLS_1_2: u16 = 0xFEFD;

/// DTLS 1.0 on the wire. A server sends it in HelloVerifyRequest regardless of what it
/// will negotiate (RFC 6347 4.2.1), so a receiver must accept it.
pub const VERSION_DTLS_1_0: u16 = 0xFEFF;

/// Bytes before the fragment: type 1, version 2, epoch 2, sequence_number 6, length 2.
pub const HEADER_LEN: usize = 13;

/// Implicit part of the GCM nonce, the write_IV from the key block (RFC 5288).
pub const SALT_LEN: usize = 4;

/// Explicit nonce carried in each record body, ahead of the ciphertext.
pub const EXPLICIT_NONCE_LEN: usize = 8;

pub const TAG_LEN: usize = Aes128Gcm.tag_length;

/// Plaintext ceiling, 2^14 (RFC 6347 4.1, inherited from TLS 1.2).
pub const MAX_PLAINTEXT: usize = 1 << 14;

/// Largest record this file can protect or open. One record must fit one datagram
/// (RFC 6347 4.1.1), so this is a ceiling and not a target.
pub const MAX_RECORD_WIRE: usize = HEADER_LEN + EXPLICIT_NONCE_LEN + MAX_PLAINTEXT + TAG_LEN;

/// Sliding window width in records (RFC 6347 4.1.2.6).
pub const REPLAY_WINDOW_BITS: u48 = AntiReplay.REPLAY_WINDOW_BITS;

/// Read a record header. Does not touch the fragment.
///
/// Param:
/// bytes - []const u8 (start of a record, header first)
///
/// Return:
/// - Header
/// - Error.Tlz_DtlsRecord_Truncated when fewer than HEADER_LEN bytes are present
pub fn parseHeader(bytes: []const u8) ParseError!Header {
    if (bytes.len < HEADER_LEN) return ParseError.Tlz_DtlsRecord_Truncated;

    return .{
        .content_type = @enumFromInt(bytes[0]),
        .version = std.mem.readInt(u16, bytes[1..3], .big),
        .epoch = std.mem.readInt(u16, bytes[3..5], .big),
        .sequence_number = readSequenceNumber(bytes[5..11]),
        .length = std.mem.readInt(u16, bytes[11..13], .big),
    };
}

/// Write a record header into the first HEADER_LEN bytes of `out`.
///
/// Param:
/// out - []u8 (at least HEADER_LEN bytes)
/// header - Header (the fields to write)
///
/// Return:
/// - void
pub fn writeHeader(out: []u8, header: Header) void {
    out[0] = @intFromEnum(header.content_type);
    std.mem.writeInt(u16, out[1..3], header.version, .big);
    std.mem.writeInt(u16, out[3..5], header.epoch, .big);
    writeSequenceNumber(out[5..11], header.sequence_number);
    std.mem.writeInt(u16, out[11..13], header.length, .big);
}

/// The 64-bit value the AAD and the nonce use: epoch in the top 16 bits, sequence
/// number in the low 48, in wire order (RFC 6347 4.1.2.1).
///
/// Param:
/// epoch - u16 (the record epoch)
/// sequence_number - u48 (the record number inside the epoch)
///
/// Return:
/// - u64
pub fn combinedSequence(epoch: u16, sequence_number: u48) u64 {
    return (@as(u64, epoch) << 48) | @as(u64, sequence_number);
}

/// Protect one record (RFC 6347 4.1.2, AEAD as in TLS 1.2).
///
/// Note:
/// - The explicit nonce is the epoch and sequence number of this same record, which
///   keeps the nonce unique for the life of a key without extra state.
///
/// Param:
/// out - []u8 (needs HEADER_LEN + EXPLICIT_NONCE_LEN + plaintext.len + TAG_LEN)
/// plaintext - []const u8 (the fragment to protect)
/// content_type - ContentType (the record content type)
/// epoch - u16 (current cipher state)
/// sequence_number - u48 (this record's number inside the epoch)
/// key - [16]u8 (write key for this direction)
/// salt - [SALT_LEN]u8 (implicit write_IV for this direction)
///
/// Return:
/// - []const u8 (the record, borrowing `out`)
/// - Error.Tlz_DtlsRecord_BadRecord when the plaintext is over MAX_PLAINTEXT or `out`
///   is too small
pub fn protect(
    out: []u8,
    plaintext: []const u8,
    content_type: ContentType,
    epoch: u16,
    sequence_number: u48,
    key: [16]u8,
    salt: [SALT_LEN]u8,
) WriteError![]const u8 {
    const body_len = EXPLICIT_NONCE_LEN + plaintext.len + TAG_LEN;
    if (plaintext.len > MAX_PLAINTEXT) return WriteError.Tlz_DtlsRecord_BadRecord;
    if (out.len < HEADER_LEN + body_len) return WriteError.Tlz_DtlsRecord_BadRecord;

    const combined = combinedSequence(epoch, sequence_number);
    const aad = buildAad(combined, content_type, @intCast(plaintext.len));
    const ct_start = HEADER_LEN + EXPLICIT_NONCE_LEN;
    const ciphertext = out[ct_start..][0..plaintext.len];

    var nonce: [12]u8 = undefined;
    @memcpy(nonce[0..SALT_LEN], &salt);
    std.mem.writeInt(u64, nonce[SALT_LEN..][0..EXPLICIT_NONCE_LEN], combined, .big);

    var tag: [TAG_LEN]u8 = undefined;

    writeHeader(out, .{
        .content_type = content_type,
        .version = VERSION_DTLS_1_2,
        .epoch = epoch,
        .sequence_number = sequence_number,
        .length = @intCast(body_len),
    });
    @memcpy(out[HEADER_LEN..ct_start], nonce[SALT_LEN..]);

    Aes128Gcm.encrypt(ciphertext, &tag, plaintext, &aad, nonce, key);
    @memcpy(out[ct_start + plaintext.len ..][0..TAG_LEN], &tag);

    return out[0 .. HEADER_LEN + body_len];
}

/// Open one protected record.
///
/// Note:
/// - The epoch and sequence number come from the record itself, not from receiver
///   state, which is what lets a reordered record still verify.
/// - A failure here is not fatal. Discard the record and keep the association
///   (RFC 6347 4.1.2.7).
///
/// Param:
/// out - []u8 (destination for the plaintext, needs the ciphertext length)
/// bytes - []const u8 (one complete record, header included)
/// key - [16]u8 (read key for this direction)
/// salt - [SALT_LEN]u8 (implicit read_IV for this direction)
///
/// Return:
/// - Opened (header plus plaintext borrowing `out`)
/// - Error.Tlz_DtlsRecord_Truncated when the record is shorter than its length field
/// - Error.Tlz_DtlsRecord_BadRecord when the body cannot hold a nonce and a tag, the
///   plaintext is over MAX_PLAINTEXT, or `out` is too small
/// - Error.Tlz_DtlsRecord_AuthenticationFailed when the tag does not verify
pub fn deprotect(out: []u8, bytes: []const u8, key: [16]u8, salt: [SALT_LEN]u8) Error!Opened {
    const header = try parseHeader(bytes);
    if (bytes.len < HEADER_LEN + header.length) return ParseError.Tlz_DtlsRecord_Truncated;

    const body = bytes[HEADER_LEN..][0..header.length];
    if (body.len < EXPLICIT_NONCE_LEN + TAG_LEN) return WriteError.Tlz_DtlsRecord_BadRecord;

    const ciphertext = body[EXPLICIT_NONCE_LEN .. body.len - TAG_LEN];
    if (ciphertext.len > MAX_PLAINTEXT) return WriteError.Tlz_DtlsRecord_BadRecord;
    if (ciphertext.len > out.len) return WriteError.Tlz_DtlsRecord_BadRecord;

    var nonce: [12]u8 = undefined;
    @memcpy(nonce[0..SALT_LEN], &salt);
    @memcpy(nonce[SALT_LEN..], body[0..EXPLICIT_NONCE_LEN]);

    var tag: [TAG_LEN]u8 = undefined;
    @memcpy(&tag, body[body.len - TAG_LEN ..]);

    const combined = combinedSequence(header.epoch, header.sequence_number);
    const aad = buildAad(combined, header.content_type, @intCast(ciphertext.len));
    const plain = out[0..ciphertext.len];

    Aes128Gcm.decrypt(plain, ciphertext, tag, &aad, nonce, key) catch |err| switch (err) {
        error.AuthenticationFailed => return Error.Tlz_DtlsRecord_AuthenticationFailed,
    };

    return .{
        .header = header,
        .data = plain,
    };
}

/// Write an unprotected record (RFC 6347 4.1). Epoch 0 carries the handshake in the
/// clear until ChangeCipherSpec, so every flight before that goes out through here.
///
/// Param:
/// out - []u8 (needs HEADER_LEN + fragment.len)
/// content_type - ContentType (the record content type)
/// epoch - u16 (the record epoch)
/// sequence_number - u48 (this record's number inside the epoch)
/// fragment - []const u8 (the record body, as is)
///
/// Return:
/// - []const u8 (the record, borrowing `out`)
/// - Error.Tlz_DtlsRecord_BadRecord when the fragment is over MAX_PLAINTEXT or `out`
///   is too small
pub fn writePlaintext(
    out: []u8,
    content_type: ContentType,
    epoch: u16,
    sequence_number: u48,
    fragment: []const u8,
) WriteError![]const u8 {
    if (fragment.len > MAX_PLAINTEXT) return WriteError.Tlz_DtlsRecord_BadRecord;
    if (out.len < HEADER_LEN + fragment.len) return WriteError.Tlz_DtlsRecord_BadRecord;

    writeHeader(out, .{
        .content_type = content_type,
        .version = VERSION_DTLS_1_2,
        .epoch = epoch,
        .sequence_number = sequence_number,
        .length = @intCast(fragment.len),
    });
    @memcpy(out[HEADER_LEN..][0..fragment.len], fragment);

    return out[0 .. HEADER_LEN + fragment.len];
}

/// The body of an unprotected record, bounds-checked against its own length field.
///
/// Param:
/// bytes - []const u8 (one complete record, header included)
///
/// Return:
/// - []const u8 (the fragment, borrowing `bytes`)
/// - Error.Tlz_DtlsRecord_Truncated when the record is shorter than its length field
pub fn plaintextFragment(bytes: []const u8) ParseError![]const u8 {
    const header = try parseHeader(bytes);
    if (bytes.len < HEADER_LEN + header.length) return ParseError.Tlz_DtlsRecord_Truncated;

    return bytes[HEADER_LEN..][0..header.length];
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const TEST_KEY: [16]u8 = @splat(0xAB);
const TEST_SALT = [SALT_LEN]u8{
    0xDE,
    0xAD,
    0xBE,
    0xEF,
};

test "tlz dtls: record, header is 13 bytes in wire order" {
    var buf: [HEADER_LEN]u8 = undefined;
    const expected = [_]u8{
        22,   0xFE, 0xFD, 0x00, 0x01, 0x00, 0x01,
        0x02, 0x03, 0x04, 0x05, 0x00, 0x10,
    };

    writeHeader(&buf, .{
        .content_type = .HANDSHAKE,
        .version = VERSION_DTLS_1_2,
        .epoch = 1,
        .sequence_number = 0x0102030405,
        .length = 0x0010,
    });

    try std.testing.expectEqualSlices(u8, &expected, &buf);
}

test "tlz dtls: record, parseHeader reads what writeHeader wrote" {
    var buf: [HEADER_LEN]u8 = undefined;

    writeHeader(&buf, .{
        .content_type = .HANDSHAKE,
        .version = VERSION_DTLS_1_2,
        .epoch = 1,
        .sequence_number = 0x0102030405,
        .length = 0x0010,
    });
    const header = try parseHeader(&buf);

    try std.testing.expectEqual(ContentType.HANDSHAKE, header.content_type);
    try std.testing.expectEqual(VERSION_DTLS_1_2, header.version);
    try std.testing.expectEqual(@as(u16, 1), header.epoch);
    try std.testing.expectEqual(@as(u48, 0x0102030405), header.sequence_number);
    try std.testing.expectEqual(@as(u16, 0x0010), header.length);
}

test "tlz dtls: record, the 48-bit sequence number spans its full range" {
    const cases = [_]u48{ 0, 1, 255, 256, 0xFFFFFF, 0xFFFFFFFFFFFF };

    for (cases) |sequence_number| {
        var buf: [HEADER_LEN]u8 = undefined;

        writeHeader(&buf, .{
            .content_type = .APPLICATION_DATA,
            .version = VERSION_DTLS_1_2,
            .epoch = 0xFFFF,
            .sequence_number = sequence_number,
            .length = 0,
        });
        const header = try parseHeader(&buf);

        try std.testing.expectEqual(sequence_number, header.sequence_number);
        try std.testing.expectEqual(@as(u16, 0xFFFF), header.epoch);
    }
}

test "tlz dtls: record, parseHeader on a stub is truncated" {
    try std.testing.expectError(Error.Tlz_DtlsRecord_Truncated, parseHeader(&[_]u8{ 22, 0xFE }));
}

test "tlz dtls: record, AAD packs epoch and sequence into the TLS sequence slot" {
    const aad = buildAad(combinedSequence(1, 0x020304050607), .APPLICATION_DATA, 0x0014);
    const expected = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
        0x07, 23,   0xFE, 0xFD, 0x00, 0x14,
    };

    try std.testing.expectEqualSlices(u8, &expected, &aad);
}

test "tlz dtls: record, combinedSequence puts the epoch on top" {
    const combined = combinedSequence(1, 0x020304050607);

    try std.testing.expectEqual(@as(u64, 0x0001020304050607), combined);
    try std.testing.expectEqual(@as(u64, 0), combinedSequence(0, 0));
}

test "tlz dtls: record, protect round trips through deprotect" {
    const plaintext = "hello dtls 1.2 record";
    var wire: [128]u8 = undefined;
    var plain: [128]u8 = undefined;

    const bytes = try protect(&wire, plaintext, .APPLICATION_DATA, 1, 42, TEST_KEY, TEST_SALT);
    const opened = try deprotect(&plain, bytes, TEST_KEY, TEST_SALT);

    try std.testing.expectEqualStrings(plaintext, opened.data);
    try std.testing.expectEqual(ContentType.APPLICATION_DATA, opened.header.content_type);
    try std.testing.expectEqual(@as(u16, 1), opened.header.epoch);
    try std.testing.expectEqual(@as(u48, 42), opened.header.sequence_number);
}

test "tlz dtls: record, the explicit nonce is the record's own epoch and sequence" {
    var wire: [128]u8 = undefined;

    const bytes = try protect(&wire, "abc", .APPLICATION_DATA, 1, 42, TEST_KEY, TEST_SALT);
    const nonce = std.mem.readInt(u64, bytes[HEADER_LEN..][0..8], .big);

    try std.testing.expectEqual(combinedSequence(1, 42), nonce);
    try std.testing.expectEqual(HEADER_LEN + EXPLICIT_NONCE_LEN + 3 + TAG_LEN, bytes.len);
}

test "tlz dtls: record, an empty fragment is a legal record" {
    var wire: [64]u8 = undefined;
    var plain: [64]u8 = undefined;

    const bytes = try protect(&wire, "", .CHANGE_CIPHER_SPEC, 0, 0, TEST_KEY, TEST_SALT);
    const opened = try deprotect(&plain, bytes, TEST_KEY, TEST_SALT);

    try std.testing.expectEqual(@as(usize, 0), opened.data.len);
    try std.testing.expectEqual(ContentType.CHANGE_CIPHER_SPEC, opened.header.content_type);
}

test "tlz dtls: record, protect over MAX_PLAINTEXT is a bad record" {
    var wire: [64]u8 = undefined;
    const big: [MAX_PLAINTEXT + 1]u8 = @splat(0);

    try std.testing.expectError(
        Error.Tlz_DtlsRecord_BadRecord,
        protect(&wire, &big, .APPLICATION_DATA, 0, 0, TEST_KEY, TEST_SALT),
    );
}

test "tlz dtls: record, protect into a small buffer is a bad record" {
    var wire: [HEADER_LEN + EXPLICIT_NONCE_LEN + TAG_LEN]u8 = undefined;

    try std.testing.expectError(
        Error.Tlz_DtlsRecord_BadRecord,
        protect(&wire, "abc", .APPLICATION_DATA, 0, 0, TEST_KEY, TEST_SALT),
    );
}

test "tlz dtls: record, tampering any authenticated byte fails authentication" {
    var wire: [128]u8 = undefined;
    var plain: [128]u8 = undefined;
    const bytes = try protect(&wire, "payload", .APPLICATION_DATA, 2, 9, TEST_KEY, TEST_SALT);
    const length = bytes.len;
    const offsets = [_]usize{ 0, 3, 5, 10, HEADER_LEN, HEADER_LEN + 9, length - 1 };

    for (offsets) |offset| {
        wire[offset] ^= 0x01;
        try std.testing.expectError(
            Error.Tlz_DtlsRecord_AuthenticationFailed,
            deprotect(&plain, wire[0..length], TEST_KEY, TEST_SALT),
        );
        wire[offset] ^= 0x01;
    }

    _ = try deprotect(&plain, wire[0..length], TEST_KEY, TEST_SALT);
}

test "tlz dtls: record, a wrong key fails authentication" {
    var wire: [128]u8 = undefined;
    var plain: [128]u8 = undefined;
    const bytes = try protect(&wire, "payload", .APPLICATION_DATA, 1, 1, TEST_KEY, TEST_SALT);

    try std.testing.expectError(
        Error.Tlz_DtlsRecord_AuthenticationFailed,
        deprotect(&plain, bytes, @splat(0xCD), TEST_SALT),
    );
}

test "tlz dtls: record, a wrong salt fails authentication" {
    var wire: [128]u8 = undefined;
    var plain: [128]u8 = undefined;
    const bytes = try protect(&wire, "payload", .APPLICATION_DATA, 1, 1, TEST_KEY, TEST_SALT);

    try std.testing.expectError(
        Error.Tlz_DtlsRecord_AuthenticationFailed,
        deprotect(&plain, bytes, TEST_KEY, @splat(0x01)),
    );
}

test "tlz dtls: record, deprotect on a stub is truncated" {
    var plain: [128]u8 = undefined;

    try std.testing.expectError(
        Error.Tlz_DtlsRecord_Truncated,
        deprotect(&plain, &[_]u8{ 23, 0xFE }, TEST_KEY, TEST_SALT),
    );
}

test "tlz dtls: record, deprotect past the datagram is truncated" {
    var wire: [128]u8 = undefined;
    var plain: [128]u8 = undefined;
    const bytes = try protect(&wire, "payload", .APPLICATION_DATA, 0, 0, TEST_KEY, TEST_SALT);

    try std.testing.expectError(
        Error.Tlz_DtlsRecord_Truncated,
        deprotect(&plain, bytes[0 .. bytes.len - 1], TEST_KEY, TEST_SALT),
    );
}

test "tlz dtls: record, a body without room for nonce and tag is a bad record" {
    var plain: [128]u8 = undefined;
    var stub: [HEADER_LEN + 8]u8 = @splat(0);

    writeHeader(&stub, .{
        .content_type = .APPLICATION_DATA,
        .version = VERSION_DTLS_1_2,
        .epoch = 0,
        .sequence_number = 0,
        .length = 8,
    });

    try std.testing.expectError(
        Error.Tlz_DtlsRecord_BadRecord,
        deprotect(&plain, &stub, TEST_KEY, TEST_SALT),
    );
}

test "tlz dtls: record, deprotect into a small buffer is a bad record" {
    var wire: [128]u8 = undefined;
    var plain: [2]u8 = undefined;
    const bytes = try protect(&wire, "payload", .APPLICATION_DATA, 0, 0, TEST_KEY, TEST_SALT);

    try std.testing.expectError(
        Error.Tlz_DtlsRecord_BadRecord,
        deprotect(&plain, bytes, TEST_KEY, TEST_SALT),
    );
}

test "tlz dtls: record, writePlaintext carries epoch 0 in the clear" {
    var wire: [64]u8 = undefined;

    const bytes = try writePlaintext(&wire, .HANDSHAKE, 0, 3, "flight");
    const header = try parseHeader(bytes);

    try std.testing.expectEqual(HEADER_LEN + 6, bytes.len);
    try std.testing.expectEqual(@as(u16, 0), header.epoch);
    try std.testing.expectEqual(@as(u48, 3), header.sequence_number);
    try std.testing.expectEqualStrings("flight", try plaintextFragment(bytes));
}

test "tlz dtls: record, a ChangeCipherSpec record is one byte of body" {
    var wire: [64]u8 = undefined;

    const ccs = try writePlaintext(&wire, .CHANGE_CIPHER_SPEC, 0, 4, &[_]u8{1});

    try std.testing.expectEqual(HEADER_LEN + 1, ccs.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{1}, try plaintextFragment(ccs));
}

test "tlz dtls: record, writePlaintext into a small buffer is a bad record" {
    var wire: [HEADER_LEN + 2]u8 = undefined;

    try std.testing.expectError(
        Error.Tlz_DtlsRecord_BadRecord,
        writePlaintext(&wire, .HANDSHAKE, 0, 0, "flight"),
    );
}

test "tlz dtls: record, plaintextFragment past the datagram is truncated" {
    var wire: [64]u8 = undefined;
    const bytes = try writePlaintext(&wire, .HANDSHAKE, 0, 3, "flight");

    try std.testing.expectError(
        Error.Tlz_DtlsRecord_Truncated,
        plaintextFragment(bytes[0 .. bytes.len - 1]),
    );
}

test "tlz dtls: record, MAX_RECORD_WIRE covers the largest record" {
    try std.testing.expectEqual(@as(usize, 13 + 8 + 16384 + 16), MAX_RECORD_WIRE);
}

