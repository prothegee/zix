//! zix HTTP/3 server Handshake flight (RFC 9001 4 + RFC 8446 4.3 + RFC 9114 / RFC 9000 18.2).
//!
//! What:
//! - Builds the server's Handshake-level TLS flight (EncryptedExtensions, Certificate,
//!   CertificateVerify, Finished), feeds each message into the handshake transcript, wraps the whole
//!   flight in a CRYPTO frame, and seals it into a Handshake packet with the server Handshake keys.
//! - The EncryptedExtensions is hand-built here (not via src/tls) because QUIC needs two things the
//!   TLS record layer deliberately omits: ALPN "h3" and the quic_transport_parameters extension
//!   (0x39). curl validates original_destination_connection_id and initial_source_connection_id
//!   against what it observed, so those carry the client's first DCID and our SCID byte-exact.
//!
//! Note:
//! - The Certificate / CertificateVerify / Finished message builders are the existing, tested
//!   `src/tls/certificate.zig` (record-free). Only the framing changes: raw handshake bytes go into a
//!   CRYPTO frame instead of a TLS record.

const std = @import("std");

const crypto = @import("crypto.zig");
const protection = @import("protection.zig");
const varint = @import("varint.zig");
const ks = @import("../../tls/key_schedule.zig");
const certificate = @import("../../tls/certificate.zig");
const rsa = @import("../../tls/rsa.zig");

/// Append one integer transport parameter (RFC 9000 18.1): varint id, varint length, varint value.
fn putIntParam(buf: []u8, pos: *usize, id: u64, value: u64) void {
    pos.* += varint.write(buf[pos.*..], id);
    pos.* += varint.write(buf[pos.*..], varint.encodedLen(value));
    pos.* += varint.write(buf[pos.*..], value);
}

/// Append one byte-string transport parameter (RFC 9000 18.1): varint id, varint length, raw bytes.
fn putBytesParam(buf: []u8, pos: *usize, id: u64, value: []const u8) void {
    pos.* += varint.write(buf[pos.*..], id);
    pos.* += varint.write(buf[pos.*..], value.len);
    @memcpy(buf[pos.*..][0..value.len], value);
    pos.* += value.len;
}

/// The one-time connection-wide byte budget advertised in the handshake (initial_max_data, RFC 9000
/// 18.2) and the rolling window replenishMaxData keeps ahead of the client's consumption. One value
/// for both so a replenished grant always extends by exactly what the handshake promised.
pub const initial_max_data: u64 = 1048576;

/// Encode the QUIC transport parameters (RFC 9000 18.2). The connection-id params are validated by
/// the peer, so they MUST carry the client's first DCID and our SCID exactly.
fn encodeTransportParams(buf: []u8, original_dcid: []const u8, source_cid: []const u8, max_idle_ms: u64, max_streams: u64) usize {
    var pos: usize = 0;

    putBytesParam(buf, &pos, 0x00, original_dcid); // original_destination_connection_id
    putBytesParam(buf, &pos, 0x0f, source_cid); // initial_source_connection_id
    putIntParam(buf, &pos, 0x01, max_idle_ms); // max_idle_timeout
    putIntParam(buf, &pos, 0x04, initial_max_data); // initial_max_data
    putIntParam(buf, &pos, 0x05, 262144); // initial_max_stream_data_bidi_local
    putIntParam(buf, &pos, 0x06, 262144); // initial_max_stream_data_bidi_remote
    putIntParam(buf, &pos, 0x07, 262144); // initial_max_stream_data_uni
    putIntParam(buf, &pos, 0x08, max_streams); // initial_max_streams_bidi
    putIntParam(buf, &pos, 0x09, max_streams); // initial_max_streams_uni

    return pos;
}

/// Build the EncryptedExtensions handshake message (RFC 8446 4.3.1) carrying ALPN "h3" and the
/// quic_transport_parameters extension (RFC 9001 8.2). Returns the wire slice.
pub fn buildEncryptedExtensions(buf: []u8, original_dcid: []const u8, source_cid: []const u8, max_idle_ms: u64, max_streams: u64) []const u8 {
    var p: usize = 0;
    buf[p] = 0x08; // EncryptedExtensions handshake type
    p += 1;
    const msg_len_at = p;
    p += 3; // u24 length placeholder
    const exts_len_at = p;
    p += 2; // u16 extensions length placeholder
    const exts_start = p;

    // ALPN extension (0x0010): ProtocolNameList of one name, "h3".
    std.mem.writeInt(u16, buf[p..][0..2], 0x0010, .big);
    p += 2;
    const alpn_len_at = p;
    p += 2;
    const alpn_start = p;
    std.mem.writeInt(u16, buf[p..][0..2], 3, .big); // ProtocolNameList length
    p += 2;
    buf[p] = 2; // ProtocolName length
    p += 1;
    @memcpy(buf[p..][0..2], "h3");
    p += 2;
    std.mem.writeInt(u16, buf[alpn_len_at..][0..2], @intCast(p - alpn_start), .big);

    // quic_transport_parameters extension (0x0039).
    std.mem.writeInt(u16, buf[p..][0..2], 0x0039, .big);
    p += 2;
    const tp_len_at = p;
    p += 2;
    const tp_start = p;
    p += encodeTransportParams(buf[p..], original_dcid, source_cid, max_idle_ms, max_streams);
    std.mem.writeInt(u16, buf[tp_len_at..][0..2], @intCast(p - tp_start), .big);

    std.mem.writeInt(u16, buf[exts_len_at..][0..2], @intCast(p - exts_start), .big);

    const msg_len = p - (msg_len_at + 3);
    buf[msg_len_at] = @intCast((msg_len >> 16) & 0xff);
    buf[msg_len_at + 1] = @intCast((msg_len >> 8) & 0xff);
    buf[msg_len_at + 2] = @intCast(msg_len & 0xff);

    return buf[0..p];
}

/// Build and seal the server Handshake flight into a Handshake packet (RFC 9001 4).
///
/// Param:
/// out - []u8 (destination for the sealed Handshake packet)
/// server_keys - crypto.AesKeys (the server Handshake key / iv / hp)
/// server_traffic - crypto.Secret (the server handshake-traffic secret, for the Finished key)
/// dcid - []const u8 (the client's Source Connection ID, our reply Destination CID)
/// scid - []const u8 (our Source Connection ID)
/// transcript - *ks.Transcript (through ClientHello + ServerHello, continued by this flight)
/// cert_der - []const u8 (the server certificate DER from the TLS context)
/// signing_key - certificate.SigningKey (the certificate's signing key)
/// original_dcid - []const u8 (the client's first Initial DCID, for the transport parameter)
/// source_cid - []const u8 (our SCID, for the transport parameter)
/// max_idle_ms - u64 (idle timeout transport parameter)
/// max_streams - u64 (stream limit transport parameter)
///
/// Return:
/// - []const u8 (the sealed Handshake packet), or null on a builder / signing error
pub fn buildHandshakeFlight(
    out: []u8,
    server_keys: crypto.AesKeys,
    server_traffic: crypto.Secret,
    dcid: []const u8,
    scid: []const u8,
    transcript: *ks.Transcript,
    cert_der: []const u8,
    signing_key: certificate.SigningKey,
    original_dcid: []const u8,
    source_cid: []const u8,
    max_idle_ms: u64,
    max_streams: u64,
) ?[]const u8 {
    var flight: [4096]u8 = undefined;
    var fp: usize = 0;

    var ee_buf: [512]u8 = undefined;
    const ee = buildEncryptedExtensions(&ee_buf, original_dcid, source_cid, max_idle_ms, max_streams);
    @memcpy(flight[fp..][0..ee.len], ee);
    fp += ee.len;
    transcript.update(ee);

    var cert_buf: [2048]u8 = undefined;
    const cert = certificate.buildCertificate(&cert_buf, cert_der);
    @memcpy(flight[fp..][0..cert.len], cert);
    fp += cert.len;
    transcript.update(cert);

    var cv_buf: [600]u8 = undefined;
    const pss_salt: [rsa.pss_salt_len]u8 = @splat(0); // ignored for ECDSA / Ed25519
    const cert_verify = certificate.buildCertificateVerify(&cv_buf, signing_key, transcript.current(), pss_salt) catch return null;
    @memcpy(flight[fp..][0..cert_verify.len], cert_verify);
    fp += cert_verify.len;
    transcript.update(cert_verify);

    var fin_buf: [128]u8 = undefined;
    const finished = certificate.buildFinished(&fin_buf, certificate.finishedKey(server_traffic), transcript.current());
    @memcpy(flight[fp..][0..finished.len], finished);
    fp += finished.len;
    transcript.update(finished);

    // Wrap the whole flight in a CRYPTO frame at offset 0 (RFC 9000 19.6).
    var frame_buf: [4200]u8 = undefined;
    var cfp: usize = 0;
    frame_buf[cfp] = 0x06;
    cfp += 1;
    cfp += varint.write(frame_buf[cfp..], 0);
    cfp += varint.write(frame_buf[cfp..], fp);
    @memcpy(frame_buf[cfp..][0..fp], flight[0..fp]);
    cfp += fp;

    return protection.sealHandshake(out, server_keys, dcid, scid, 0, frame_buf[0..cfp]) catch null;
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

fn h(comptime text: []const u8) [text.len / 2]u8 {
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;

    return out;
}

test "zix http3: transport parameters carry the validated connection ids" {
    var buf: [256]u8 = undefined;
    const dcid = h("8394c8f03e515708");
    const scid = h("c0ffee00");
    const len = encodeTransportParams(&buf, &dcid, &scid, 30000, 128);
    const params = buf[0..len];

    // original_destination_connection_id (0x00): id, length 8, then the DCID bytes.
    try std.testing.expectEqual(@as(u8, 0x00), params[0]);
    try std.testing.expectEqual(@as(u8, 8), params[1]);
    try std.testing.expectEqualSlices(u8, &dcid, params[2..10]);

    // initial_source_connection_id (0x0f) follows: id, length 4, then the SCID bytes.
    try std.testing.expectEqual(@as(u8, 0x0f), params[10]);
    try std.testing.expectEqual(@as(u8, 4), params[11]);
    try std.testing.expectEqualSlices(u8, &scid, params[12..16]);
}

test "zix http3: EncryptedExtensions carries ALPN h3 and transport parameters" {
    var buf: [512]u8 = undefined;
    const ee = buildEncryptedExtensions(&buf, &h("8394c8f03e515708"), &h("c0ffee00"), 30000, 128);

    // EncryptedExtensions handshake type, and the 24-bit length matches the remaining bytes.
    try std.testing.expectEqual(@as(u8, 0x08), ee[0]);
    const declared = (@as(usize, ee[1]) << 16) | (@as(usize, ee[2]) << 8) | ee[3];
    try std.testing.expectEqual(ee.len - 4, declared);

    // The "h3" ALPN token and the 0x0039 transport-parameters extension id both appear.
    try std.testing.expect(std.mem.indexOf(u8, ee, "h3") != null);
    try std.testing.expect(std.mem.indexOf(u8, ee, &[_]u8{ 0x00, 0x39 }) != null);
}
