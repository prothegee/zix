//! zix HTTP/3 QUIC packet protection, the receive (open) path (RFC 9001 5.3 / 5.4).
//!
//! What:
//! - Removes header protection and AEAD-decrypts a received long-header Initial packet, the first
//!   step of the handshake: a server opens the client's Initial with the DCID-derived client keys
//!   (crypto.zig), recovers the packet number, and returns the decrypted frame payload (CRYPTO +
//!   PADDING) for the frame parser.
//! - The send (seal) primitives live in crypto.zig. This module is the inverse: sample the
//!   ciphertext, compute the header-protection mask, unmask the first byte and packet number, then
//!   open the AEAD with the unprotected header as associated data.
//!
//! Note:
//! - The first received Initial has no prior largest packet number, so the recovered number is the
//!   truncated wire value. Multi-packet recovery uses packet.decodePacketNumber once a largest is
//!   tracked on the connection.

const std = @import("std");

const crypto = @import("crypto.zig");
const packet = @import("packet.zig");
const varint = @import("varint.zig");

const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;

/// The errors opening a packet can raise.
pub const OpenError = error{
    /// The packet is shorter than the header, sample, and tag require.
    Truncated,
    /// Not a long-header Initial packet.
    NotInitial,
    /// Not a long-header Handshake packet.
    NotHandshake,
    /// The unprotected header did not fit the working buffer (an implausibly long token).
    HeaderTooLong,
    /// AEAD authentication failed: a forged, corrupted, or wrong-key packet.
    Decrypt,
};

/// A decrypted packet: the recovered packet number and the plaintext frame payload (a slice into the
/// caller-provided output buffer).
pub const Opened = struct {
    packet_number: u64,
    payload: []const u8,
};

/// The packet-number offset for a long-header Initial (RFC 9000 17.2): the byte index where the
/// protected packet number begins, after the Token Length + Token and the Length field.
fn initialPnOffset(data: []const u8, hdr: packet.LongHeader) OpenError!usize {
    var pos = data.len - hdr.rest.len;

    const token = varint.read(data[pos..]) catch return error.Truncated;
    pos += token.len + @as(usize, @intCast(token.value));
    if (pos > data.len) return error.Truncated;

    const length = varint.read(data[pos..]) catch return error.Truncated;
    pos += length.len;

    return pos;
}

/// Open a long-header Initial packet (RFC 9001 5.3 / 5.4). `keys` are the Initial keys for the
/// sender direction (the client keys when a server opens a client Initial).
///
/// Param:
/// data - []const u8 (the received datagram bytes for one Initial packet)
/// keys - crypto.AesKeys (the Initial key / iv / hp for the sending peer)
/// out - []u8 (destination for the decrypted frame payload, must hold the ciphertext length)
///
/// Return:
/// - Opened (recovered packet number plus the decrypted payload)
/// - OpenError on a malformed or unauthenticated packet
pub fn openInitial(data: []const u8, keys: crypto.AesKeys, out: []u8) OpenError!Opened {
    const hdr = packet.parseLongHeader(data) catch return error.Truncated;
    if (hdr.packet_type != 0) return error.NotInitial;

    const pn_offset = try initialPnOffset(data, hdr);

    return openLongHeaderAt(data, keys, out, pn_offset);
}

/// The packet-number offset for a long-header Handshake packet (RFC 9000 17.2): after the Length
/// field. Unlike an Initial there is no Token Length / Token.
fn handshakePnOffset(data: []const u8, hdr: packet.LongHeader) OpenError!usize {
    var pos = data.len - hdr.rest.len;

    const length = varint.read(data[pos..]) catch return error.Truncated;
    pos += length.len;

    return pos;
}

/// Open a long-header Handshake packet (RFC 9001 5.3 / 5.4). `keys` are the Handshake keys for the
/// sending direction (the client handshake keys when a server opens a client Handshake packet).
pub fn openHandshake(data: []const u8, keys: crypto.AesKeys, out: []u8) OpenError!Opened {
    const hdr = packet.parseLongHeader(data) catch return error.Truncated;
    if (hdr.packet_type != 2) return error.NotHandshake;

    const pn_offset = try handshakePnOffset(data, hdr);

    return openLongHeaderAt(data, keys, out, pn_offset);
}

/// Remove header protection and AEAD-decrypt a long-header packet whose packet number begins at
/// `pn_offset`. Shared by `openInitial` and `openHandshake`.
fn openLongHeaderAt(data: []const u8, keys: crypto.AesKeys, out: []u8, pn_offset: usize) OpenError!Opened {
    // Header-protection sample: 16 bytes starting at pn_offset + 4 (RFC 9001 5.4.2).
    const sample_offset = pn_offset + 4;
    if (data.len < sample_offset + 16) return error.Truncated;

    var sample: [16]u8 = undefined;
    @memcpy(&sample, data[sample_offset .. sample_offset + 16]);
    const mask = crypto.headerMaskAes(keys.hp, sample);

    // Unmask the first byte (long header: low 4 bits) to learn the packet-number length.
    const first = data[0] ^ (mask[0] & 0x0f);
    const pn_len: usize = @as(usize, first & 0x03) + 1;

    const header_len = pn_offset + pn_len;
    if (data.len < header_len + Aes128Gcm.tag_length) return error.Truncated;

    // Rebuild the unprotected header for the AEAD associated data: the unmasked first byte and the
    // unmasked packet-number bytes, the rest copied verbatim.
    var hdr_buf: [256]u8 = undefined;
    if (header_len > hdr_buf.len) return error.HeaderTooLong;
    @memcpy(hdr_buf[0..header_len], data[0..header_len]);
    hdr_buf[0] = first;

    var truncated_pn: u64 = 0;
    for (0..pn_len) |i| {
        const b = data[pn_offset + i] ^ mask[1 + i];
        hdr_buf[pn_offset + i] = b;
        truncated_pn = (truncated_pn << 8) | b;
    }

    // First Initial: no prior largest, so the recovered number is the truncated value.
    const full_pn = truncated_pn;

    const nonce = crypto.aeadNonce(keys.iv, full_pn);
    const ciphertext = data[header_len .. data.len - Aes128Gcm.tag_length];
    if (ciphertext.len > out.len) return error.Truncated;

    var tag: [Aes128Gcm.tag_length]u8 = undefined;
    @memcpy(&tag, data[data.len - Aes128Gcm.tag_length ..]);

    Aes128Gcm.decrypt(out[0..ciphertext.len], ciphertext, tag, hdr_buf[0..header_len], nonce, keys.key) catch return error.Decrypt;

    return .{ .packet_number = full_pn, .payload = out[0..ciphertext.len] };
}

/// Seal an outgoing long-header Initial packet (RFC 9001 5.3 / 5.4, the send path). Builds the
/// unprotected long header (Initial, version 1, the given DCID / SCID, empty token), AEAD-encrypts
/// `payload` (the frames) with the unprotected header as associated data, then applies header
/// protection. `keys` are the Initial keys for the sending direction (the server keys when a server
/// sends to a client).
///
/// Param:
/// out - []u8 (destination for the whole packet, must be large enough for header + payload + tag)
/// keys - crypto.AesKeys (the Initial key / iv / hp for this sender)
/// dcid - []const u8 (Destination Connection ID, the peer's chosen SCID)
/// scid - []const u8 (our Source Connection ID)
/// packet_number - u32 (this packet's number in the Initial space)
/// payload - []const u8 (the frame bytes: CRYPTO, ACK, PADDING)
///
/// Return:
/// - []const u8 (the protected packet, a slice into `out`)
pub fn sealInitial(out: []u8, keys: crypto.AesKeys, dcid: []const u8, scid: []const u8, packet_number: u32, payload: []const u8) OpenError![]const u8 {
    const pn_len: usize = if (packet_number <= 0xff) 1 else if (packet_number <= 0xffff) 2 else 4;

    var pos: usize = 0;
    // First byte: long form (0x80) | fixed bit (0x40) | Initial type (0x00 << 4) | pn length - 1.
    out[pos] = 0xc0 | @as(u8, @intCast(pn_len - 1));
    pos += 1;
    std.mem.writeInt(u32, out[pos..][0..4], 1, .big);
    pos += 4;
    out[pos] = @intCast(dcid.len);
    pos += 1;
    @memcpy(out[pos..][0..dcid.len], dcid);
    pos += dcid.len;
    out[pos] = @intCast(scid.len);
    pos += 1;
    @memcpy(out[pos..][0..scid.len], scid);
    pos += scid.len;
    pos += varint.write(out[pos..], 0); // empty Token Length
    pos += varint.write(out[pos..], pn_len + payload.len + Aes128Gcm.tag_length); // Length

    const pn_offset = pos;
    var pn_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &pn_bytes, packet_number, .big);
    @memcpy(out[pos..][0..pn_len], pn_bytes[4 - pn_len ..]);
    pos += pn_len;

    const header_len = pos;
    if (header_len + payload.len + Aes128Gcm.tag_length > out.len) return error.Truncated;

    // AEAD-seal the payload with the unprotected header as associated data (RFC 9001 5.3).
    const nonce = crypto.aeadNonce(keys.iv, packet_number);
    var tag: [Aes128Gcm.tag_length]u8 = undefined;
    Aes128Gcm.encrypt(out[header_len .. header_len + payload.len], &tag, payload, out[0..header_len], nonce, keys.key);
    @memcpy(out[header_len + payload.len ..][0..Aes128Gcm.tag_length], &tag);

    const packet_len = header_len + payload.len + Aes128Gcm.tag_length;

    // Header protection: sample 16 bytes at pn_offset + 4, mask, protect the first byte + pn bytes.
    const sample_offset = pn_offset + 4;
    if (packet_len < sample_offset + 16) return error.Truncated;

    var sample: [16]u8 = undefined;
    @memcpy(&sample, out[sample_offset .. sample_offset + 16]);
    const mask = crypto.headerMaskAes(keys.hp, sample);
    out[0] ^= mask[0] & 0x0f;
    for (0..pn_len) |i| out[pn_offset + i] ^= mask[1 + i];

    return out[0..packet_len];
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

fn h(comptime text: []const u8) [text.len / 2]u8 {
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;

    return out;
}

test "zix test: open the RFC 9001 A.2 protected client Initial" {
    // Build the byte-exact A.2 protected packet via the seal path, then open it back.
    const dcid = h("8394c8f03e515708");
    const secrets = crypto.initialSecrets(&dcid);
    const client_keys = crypto.AesKeys.fromSecret(secrets.client);

    const header = h("c300000001088394c8f03e5157080000449e00000002");
    const pn_offset: usize = 18;
    const pn_length: usize = 4;

    const crypto_frame = h("060040f1010000ed0303ebf8fa56f12939b9584a3896472ec40bb863cfd3e868" ++
        "04fe3a47f06a2b69484c000004130113020100" ++ "00c000000010000e00000b6578" ++
        "616d706c652e636f6dff01000100000a00080006001d00170018001000070005" ++
        "04616c706e000500050100000000003300260024001d00209370b2c9caa47fba" ++
        "baf4559fedba753de171fa71f50f1ce15d43e994ec74d748002b000302030400" ++
        "0d0010000e0403050306030203080408050806002d00020101001c0002400100" ++
        "3900320408ffffffffffffffff05048000ffff07048000ffff08011001048000" ++
        "75300901100f088394c8f03e5157080604" ++ "8000ffff");

    var payload: [1162]u8 = undefined;
    @memset(&payload, 0);
    @memcpy(payload[0..crypto_frame.len], &crypto_frame);

    const nonce = crypto.aeadNonce(client_keys.iv, 2);
    var ciphertext: [1162]u8 = undefined;
    var tag: [Aes128Gcm.tag_length]u8 = undefined;
    Aes128Gcm.encrypt(&ciphertext, &tag, &payload, &header, nonce, client_keys.key);

    var sample: [16]u8 = undefined;
    @memcpy(&sample, ciphertext[0..16]);
    const mask = crypto.headerMaskAes(client_keys.hp, sample);

    var protected_packet: [header.len + 1162 + Aes128Gcm.tag_length]u8 = undefined;
    @memcpy(protected_packet[0..header.len], &header);
    protected_packet[0] ^= mask[0] & 0x0f;
    for (0..pn_length) |i| protected_packet[pn_offset + i] ^= mask[1 + i];
    @memcpy(protected_packet[header.len .. header.len + 1162], &ciphertext);
    @memcpy(protected_packet[header.len + 1162 ..], &tag);

    // Open it back with the same client keys.
    var out: [2048]u8 = undefined;
    const opened = try openInitial(&protected_packet, client_keys, &out);

    try std.testing.expectEqual(@as(u64, 2), opened.packet_number);
    try std.testing.expectEqualSlices(u8, &crypto_frame, opened.payload[0..crypto_frame.len]);
}

test "zix test: sealInitial then openInitial round-trips the payload" {
    const dcid = h("8394c8f03e515708");
    const secrets = crypto.initialSecrets(&dcid);
    const server_keys = crypto.AesKeys.fromSecret(secrets.server);

    // A server Initial carrying a small CRYPTO frame (a stand-in ServerHello body) plus PADDING to
    // reach the header-protection sample length.
    var payload: [64]u8 = undefined;
    @memset(&payload, 0);
    const frame_bytes = h("0600200200006c0303") ++ h("aabbccddeeff");
    @memcpy(payload[0..frame_bytes.len], &frame_bytes);

    var out: [256]u8 = undefined;
    const sealed = try sealInitial(&out, server_keys, &dcid, &h("c0ffee00"), 0, &payload);

    var recovered: [256]u8 = undefined;
    const opened = try openInitial(sealed, server_keys, &recovered);

    try std.testing.expectEqual(@as(u64, 0), opened.packet_number);
    try std.testing.expectEqualSlices(u8, &payload, opened.payload[0..payload.len]);
}

test "zix test: openInitial rejects a tampered packet" {
    const dcid = h("8394c8f03e515708");
    const secrets = crypto.initialSecrets(&dcid);
    const client_keys = crypto.AesKeys.fromSecret(secrets.client);

    var tampered: [200]u8 = undefined;
    @memset(&tampered, 0);
    tampered[0] = 0xc3;
    std.mem.writeInt(u32, tampered[1..5], 1, .big);
    tampered[5] = 8;
    @memcpy(tampered[6..14], &dcid);
    tampered[14] = 0; // scid len
    tampered[15] = 0; // token len
    _ = varint.write(tampered[16..18], 178); // length: pn(4) + 158 payload + 16 tag
    var out: [256]u8 = undefined;

    // Random ciphertext under the real keys does not authenticate.
    try std.testing.expectError(error.Decrypt, openInitial(&tampered, client_keys, &out));
}
