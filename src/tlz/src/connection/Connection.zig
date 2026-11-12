//! TLZ connection Connection
//!
//! ### file: src/tlz/src/connection/Connection.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The server side of an established TLS 1.3 connection: the application and
//! client handshake keys, the sequence numbers, and the record read and write calls.
//!
//! ### note:
//!
//! Sans-I/O: every call takes bytes and returns bytes. The caller owns the socket.
//! The client handshake key stays live after the server flight, because the client
//! Finished (and under mTLS its Certificate and CertificateVerify) arrive under it.
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
const Reader = @import("../wire/Reader.zig");
const record = @import("../record.zig");
const alert = @import("../alert.zig");
const key_schedule = @import("../key_schedule.zig");
const certificate = @import("../crypto/certificate.zig");
const cert_verify = @import("../crypto/cert_verify.zig");
const Transcript = @import("../key_schedule/Transcript.zig");
const HandshakeMessage = @import("HandshakeMessage.zig");
const Opened = @import("../record/Opened.zig");
const ContentType = @import("../record/content_type.zig").ContentType;
const Alert = @import("../alert/description.zig").Alert;
const HandshakeType = @import("../handshake/handshake_type.zig").HandshakeType;

const Secret = key_schedule.Secret;
const HASH_LENGTH = key_schedule.HASH_LENGTH;
const KEY_LENGTH = record.KEY_LENGTH;
const IV_LENGTH = record.IV_LENGTH;

// --------------------------------------------------------- //
// Fields:

server_app_key: [KEY_LENGTH]u8,
server_app_iv: [IV_LENGTH]u8,
client_app_key: [KEY_LENGTH]u8,
client_app_iv: [IV_LENGTH]u8,
client_hs_key: [KEY_LENGTH]u8,
client_hs_iv: [IV_LENGTH]u8,
client_finished_key: Secret,
/// The running transcript at the server Finished. mTLS folds the client
/// Certificate and CertificateVerify into it before the client Finished is checked.
handshake_transcript: Transcript,
/// Sequence number for the client handshake key.
client_hs_seq: u64 = 0,
server_app_seq: u64 = 0,
client_app_seq: u64 = 0,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// Decrypt buffer for one split-framing client Certificate record. Caps the client
/// certificate size.
const CLIENT_CERT_RECORD_BUF: usize = 4096;

/// Decrypt buffer for one split-framing client CertificateVerify record.
const CLIENT_VERIFY_RECORD_BUF: usize = 2048;

/// Decrypt buffer for one coalesced client auth flight record.
const CLIENT_AUTH_FLIGHT_BUF: usize = 4096;

/// Decrypt buffer for the client Finished record.
const CLIENT_FINISHED_BUF: usize = 512;

/// The mTLS paths: this module's own errors plus what each callee can return.
const Inner = Error ||
    Reader.Error ||
    record.Error ||
    certificate.ParseError ||
    certificate.VerifyError ||
    cert_verify.PeerKeyError;

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.Tlz_WireReader_Truncated => error.Tlz_ServerConnection_Truncated,
        error.Tlz_Record_Overflow => error.Tlz_ServerConnection_RecordOverflow,
        error.Tlz_Record_BadMac => error.Tlz_ServerConnection_BadRecordMac,
        error.Tlz_Record_Decode => error.Tlz_ServerConnection_Decode,
        error.Tlz_Certificate_Truncated => error.Tlz_ServerConnection_Truncated,
        error.Tlz_Certificate_UnsupportedSignatureScheme => {
            return error.Tlz_ServerConnection_UnsupportedSignatureScheme;
        },
        error.Tlz_Certificate_SignatureFailed => error.Tlz_ServerConnection_SignatureFailed,
        error.Tlz_CertVerify_UnsupportedPeerKey => error.Tlz_ServerConnection_UnsupportedPeerKey,
        error.Tlz_CertVerify_Malformed => error.Tlz_ServerConnection_CertificateMalformed,
        error.Tlz_CertVerify_CertificateHasUnrecognizedObjectId => {
            return error.Tlz_ServerConnection_CertificateHasUnrecognizedObjectId;
        },
        error.Tlz_ServerConnection_PeerClosed,
        error.Tlz_ServerConnection_UnexpectedMessage,
        error.Tlz_ServerConnection_UnexpectedHandshakeMessage,
        error.Tlz_ServerConnection_Decode,
        error.Tlz_ServerConnection_RecordOverflow,
        error.Tlz_ServerConnection_BadRecordMac,
        error.Tlz_ServerConnection_Truncated,
        error.Tlz_ServerConnection_ClientFinishedMismatch,
        error.Tlz_ServerConnection_ClientCertificateMissing,
        error.Tlz_ServerConnection_CertificateTooLarge,
        error.Tlz_ServerConnection_UnsupportedSignatureScheme,
        error.Tlz_ServerConnection_SignatureFailed,
        error.Tlz_ServerConnection_UnsupportedPeerKey,
        error.Tlz_ServerConnection_CertificateMalformed,
        error.Tlz_ServerConnection_CertificateHasUnrecognizedObjectId,
        => |own| own,
    };
}

/// Deprotect one client handshake record and advance the handshake sequence.
fn openHandshakeRecord(self: *Self, plain: []u8, rec: []const u8) Inner!Opened {
    const opened = try record.deprotect(
        plain,
        rec,
        self.client_hs_key,
        self.client_hs_iv,
        self.client_hs_seq,
    );
    self.client_hs_seq += 1;

    if (opened.inner_type != .HANDSHAKE) {
        return Error.Tlz_ServerConnection_UnexpectedHandshakeMessage;
    }

    return opened;
}

/// Read one length-prefixed handshake message at the cursor and check its type.
fn readHandshakeMessage(reader: *Reader, want: HandshakeType) Inner!HandshakeMessage {
    const start = reader.pos;

    const message_type = try reader.readU8();
    if (message_type != @intFromEnum(want)) {
        return Error.Tlz_ServerConnection_UnexpectedHandshakeMessage;
    }

    const length = try reader.readU24();
    const body = try reader.readBytes(length);

    return .{
        .full = reader.buf[start..reader.pos],
        .body = body,
    };
}

/// Read the whole decrypted record as one message of the wanted type.
fn singleMessage(data: []const u8, want: HandshakeType) Inner!HandshakeMessage {
    if (data.len < 4) return Error.Tlz_ServerConnection_UnexpectedHandshakeMessage;

    var reader: Reader = .{ .buf = data };

    return readHandshakeMessage(&reader, want);
}

/// Copy the client end-entity DER out of a Certificate message body.
fn copyClientDer(certificate_body: []const u8, out_der: []u8) Inner![]const u8 {
    const client_der = try certificate.parseEndEntityCertificate(certificate_body) orelse {
        return Error.Tlz_ServerConnection_ClientCertificateMissing;
    };
    if (client_der.len > out_der.len) return Error.Tlz_ServerConnection_CertificateTooLarge;

    @memcpy(out_der[0..client_der.len], client_der);

    return out_der[0..client_der.len];
}

/// Copy the client DER out of its Certificate message and fold the message.
fn foldClientCertificate(
    self: *Self,
    cert_msg: HandshakeMessage,
    out_der: []u8,
) Inner![]const u8 {
    const der = try copyClientDer(cert_msg.body, out_der);
    self.handshake_transcript.update(cert_msg.full);

    return der;
}

/// Check the client CertificateVerify over the transcript through the client
/// Certificate, then fold it.
fn foldClientCertificateVerify(
    self: *Self,
    der: []const u8,
    cert_verify_msg: HandshakeMessage,
) Inner!void {
    const transcript_through_cert = self.handshake_transcript.current();
    const public_key = try cert_verify.peerEcdsaP256PublicKey(der);

    try certificate.verifyClientCertificateVerify(
        cert_verify_msg.body,
        public_key,
        transcript_through_cert,
    );
    self.handshake_transcript.update(cert_verify_msg.full);
}

/// Compare a Finished body against the expected verify_data for the transcript now.
fn checkClientFinished(self: *const Self, verify_data: []const u8) Inner!void {
    if (verify_data.len < HASH_LENGTH) return Error.Tlz_ServerConnection_ClientFinishedMismatch;

    const expected = certificate.finishedVerifyData(
        self.client_finished_key,
        self.handshake_transcript.current(),
    );
    if (!std.mem.eql(u8, verify_data[0..HASH_LENGTH], &expected)) {
        return Error.Tlz_ServerConnection_ClientFinishedMismatch;
    }
}

fn verifyClientFinishedInner(self: *Self, rec: []const u8) Inner!void {
    var plain: [CLIENT_FINISHED_BUF]u8 = undefined;
    const opened = self.openHandshakeRecord(&plain, rec) catch |err| switch (err) {
        error.Tlz_ServerConnection_UnexpectedHandshakeMessage => {
            return Error.Tlz_ServerConnection_ClientFinishedMismatch;
        },
        else => return err,
    };
    if (opened.data.len < 4) return Error.Tlz_ServerConnection_ClientFinishedMismatch;

    try self.checkClientFinished(opened.data[4..]);
}

fn verifyClientCertFlightInner(
    self: *Self,
    cert_record: []const u8,
    cert_verify_record: []const u8,
    out_der: []u8,
) Inner![]const u8 {
    var cert_plain: [CLIENT_CERT_RECORD_BUF]u8 = undefined;
    const cert_opened = try self.openHandshakeRecord(&cert_plain, cert_record);
    const cert_msg = try singleMessage(cert_opened.data, .CERTIFICATE);
    const der = try self.foldClientCertificate(cert_msg, out_der);

    var verify_plain: [CLIENT_VERIFY_RECORD_BUF]u8 = undefined;
    const verify_opened = try self.openHandshakeRecord(&verify_plain, cert_verify_record);
    const cert_verify_msg = try singleMessage(verify_opened.data, .CERTIFICATE_VERIFY);
    try self.foldClientCertificateVerify(der, cert_verify_msg);

    return der;
}

fn verifyClientAuthFlightInner(
    self: *Self,
    flight_record: []const u8,
    out_der: []u8,
) Inner![]const u8 {
    var plain: [CLIENT_AUTH_FLIGHT_BUF]u8 = undefined;
    const opened = try self.openHandshakeRecord(&plain, flight_record);

    var reader: Reader = .{ .buf = opened.data };
    const cert_msg = try readHandshakeMessage(&reader, .CERTIFICATE);
    const der = try self.foldClientCertificate(cert_msg, out_der);

    const cert_verify_msg = try readHandshakeMessage(&reader, .CERTIFICATE_VERIFY);
    try self.foldClientCertificateVerify(der, cert_verify_msg);

    // The Finished binds the transcript through the CertificateVerify
    const finished_msg = try readHandshakeMessage(&reader, .FINISHED);
    try self.checkClientFinished(finished_msg.body);
    self.handshake_transcript.update(finished_msg.full);

    return der;
}

/// Seal one plaintext under the server application key and advance its sequence.
fn sealServer(
    self: *Self,
    out: []u8,
    plaintext: []const u8,
    inner_type: ContentType,
) []const u8 {
    const rec = record.protect(
        out,
        plaintext,
        inner_type,
        self.server_app_key,
        self.server_app_iv,
        self.server_app_seq,
    );
    self.server_app_seq += 1;

    return rec;
}

// --------------------------------------------------------- //
// Public:

pub const Error = error{
    Tlz_ServerConnection_PeerClosed,
    Tlz_ServerConnection_UnexpectedMessage,
    Tlz_ServerConnection_UnexpectedHandshakeMessage,
    Tlz_ServerConnection_Decode,
    Tlz_ServerConnection_RecordOverflow,
    Tlz_ServerConnection_BadRecordMac,
    Tlz_ServerConnection_Truncated,
    Tlz_ServerConnection_ClientFinishedMismatch,
    Tlz_ServerConnection_ClientCertificateMissing,
    Tlz_ServerConnection_CertificateTooLarge,
    Tlz_ServerConnection_UnsupportedSignatureScheme,
    Tlz_ServerConnection_SignatureFailed,
    Tlz_ServerConnection_UnsupportedPeerKey,
    Tlz_ServerConnection_CertificateMalformed,
    Tlz_ServerConnection_CertificateHasUnrecognizedObjectId,
};

/// Encrypt application data into one record under the server application key.
///
/// Param:
/// plaintext - []const u8 (at most `record.MAX_PLAINTEXT` bytes)
/// out - []u8 (at least `record.sealedLen(plaintext.len)` bytes)
///
/// Return:
/// - []const u8 (the wire record, a view into `out`, empty when it does not fit)
pub fn writeAppData(self: *Self, plaintext: []const u8, out: []u8) []const u8 {
    return self.sealServer(out, plaintext, .APPLICATION_DATA);
}

/// Encrypt two slices as one application record: the gather form of `writeAppData`,
/// so a small header prefix and a large payload need no copy into one buffer.
///
/// Param:
/// head - []const u8 (the first slice)
/// tail - []const u8 (the second slice)
/// out - []u8 (at least `record.sealedLen(head.len + tail.len)` bytes)
///
/// Return:
/// - []const u8 (the wire record, a view into `out`, empty when it does not fit)
pub fn writeAppData2(self: *Self, head: []const u8, tail: []const u8, out: []u8) []const u8 {
    const rec = record.protect2(
        out,
        head,
        tail,
        .APPLICATION_DATA,
        self.server_app_key,
        self.server_app_iv,
        self.server_app_seq,
    );
    self.server_app_seq += 1;

    return rec;
}

/// Decrypt one client application record and classify its inner type (RFC 8446 5.1).
///
/// Param:
/// rec - []const u8 (one whole wire record)
/// out - []u8 (holds at least the ciphertext length)
///
/// Return:
/// - []const u8 (the plaintext, a view into `out`) for application_data
/// - Error.Tlz_ServerConnection_PeerClosed for an alert (close_notify or fatal)
/// - Error.Tlz_ServerConnection_UnexpectedMessage for a post-handshake handshake
///   message (renegotiation or KeyUpdate, neither supported)
/// - Error.Tlz_ServerConnection_Decode for any other inner type
/// - Error.Tlz_ServerConnection_BadRecordMac or RecordOverflow from the record layer
pub fn readAppData(self: *Self, rec: []const u8, out: []u8) Error![]const u8 {
    const opened = record.deprotect(
        out,
        rec,
        self.client_app_key,
        self.client_app_iv,
        self.client_app_seq,
    ) catch |err| return innerError(err);
    self.client_app_seq += 1;

    return switch (opened.inner_type) {
        .APPLICATION_DATA => opened.data,
        .ALERT => Error.Tlz_ServerConnection_PeerClosed,
        .HANDSHAKE => Error.Tlz_ServerConnection_UnexpectedMessage,
        else => Error.Tlz_ServerConnection_Decode,
    };
}

/// Emit an encrypted close_notify alert (level warning, description 0).
///
/// Param:
/// out - []u8 (at least `record.sealedLen(2)` bytes)
///
/// Return:
/// - []const u8 (the wire record, a view into `out`)
pub fn closeNotify(self: *Self, out: []u8) []const u8 {
    const body = [_]u8{
        alert.LEVEL_WARNING,
        0,
    };

    return self.sealServer(out, &body, .ALERT);
}

/// Emit an encrypted fatal alert under the server application key (RFC 8446 6),
/// e.g. unexpected_message to reject a post-handshake renegotiation.
///
/// Param:
/// desc - Alert (the description to send)
/// out - []u8 (at least `record.sealedLen(2)` bytes)
///
/// Return:
/// - []const u8 (the wire record, a view into `out`)
pub fn encryptedAlert(self: *Self, desc: Alert, out: []u8) []const u8 {
    const body = [_]u8{
        alert.LEVEL_FATAL,
        @intFromEnum(desc),
    };

    return self.sealServer(out, &body, .ALERT);
}

/// Deprotect and check the client Finished record (RFC 8446 4.4.4) under the
/// client handshake key.
///
/// Param:
/// rec - []const u8 (the encrypted client Finished record)
///
/// Return:
/// - void when the verify_data matches
/// - Error.Tlz_ServerConnection_ClientFinishedMismatch (the decrypt_error condition)
/// - Error.Tlz_ServerConnection_BadRecordMac or RecordOverflow from the record layer
pub fn verifyClientFinished(self: *Self, rec: []const u8) Error!void {
    self.verifyClientFinishedInner(rec) catch |err| return innerError(err);
}

/// mTLS, split framing: process the client Certificate then CertificateVerify, each
/// in its own record (RFC 8446 4.4.2, 4.4.3), ahead of the client Finished.
///
/// Note:
/// - The trust decision is the caller's: run cert_verify on the returned DER.
///
/// Param:
/// cert_record - []const u8 (the encrypted client Certificate record)
/// cert_verify_record - []const u8 (the encrypted client CertificateVerify record)
/// out_der - []u8 (where the returned DER is copied)
///
/// Return:
/// - []const u8 (the client end-entity DER, a view into `out_der`)
/// - Error.Tlz_ServerConnection_ClientCertificateMissing on an empty certificate_list
/// - Error.Tlz_ServerConnection_UnexpectedHandshakeMessage on a wrong message
/// - Error.Tlz_ServerConnection_SignatureFailed when the CertificateVerify fails
pub fn verifyClientCertFlight(
    self: *Self,
    cert_record: []const u8,
    cert_verify_record: []const u8,
    out_der: []u8,
) Error![]const u8 {
    return self.verifyClientCertFlightInner(
        cert_record,
        cert_verify_record,
        out_der,
    ) catch |err| innerError(err);
}

/// mTLS, coalesced framing: the client Certificate, CertificateVerify, and Finished
/// in one encrypted record, as common stacks send them.
///
/// Param:
/// flight_record - []const u8 (one encrypted record with the three messages)
/// out_der - []u8 (where the returned DER is copied)
///
/// Return:
/// - []const u8 (the client end-entity DER, a view into `out_der`)
/// - Error.Tlz_ServerConnection_ClientCertificateMissing on an empty certificate_list
/// - Error.Tlz_ServerConnection_UnexpectedHandshakeMessage on a wrong message
/// - Error.Tlz_ServerConnection_ClientFinishedMismatch when the Finished fails
pub fn verifyClientAuthFlight(
    self: *Self,
    flight_record: []const u8,
    out_der: []u8,
) Error![]const u8 {
    return self.verifyClientAuthFlightInner(flight_record, out_der) catch |err| innerError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Inbound = @import("../alert/Inbound.zig");

fn testConnection(key_byte: u8, iv_byte: u8) Self {
    return .{
        .server_app_key = @splat(key_byte),
        .server_app_iv = @splat(iv_byte),
        .client_app_key = @splat(key_byte),
        .client_app_iv = @splat(iv_byte),
        .client_hs_key = @splat(key_byte),
        .client_hs_iv = @splat(iv_byte),
        .client_finished_key = @splat(0x77),
        .handshake_transcript = .init(),
    };
}

test "tlz connection: Connection, readAppData returns application data" {
    var conn = testConnection(0xAB, 0xCD);
    var rec_buf: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    const key: [KEY_LENGTH]u8 = @splat(0xAB);
    const rec = record.protect(&rec_buf, "hello", .APPLICATION_DATA, key, @splat(0xCD), 0);

    const data = try conn.readAppData(rec, &out);

    try std.testing.expectEqualSlices(u8, "hello", data);
    try std.testing.expectEqual(@as(u64, 1), conn.client_app_seq);
}

test "tlz connection: Connection, readAppData on a handshake record is unexpected" {
    var conn = testConnection(0xAB, 0xCD);
    var rec_buf: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    const body = [_]u8{ 1, 0, 0, 0 };
    const rec = record.protect(&rec_buf, &body, .HANDSHAKE, @splat(0xAB), @splat(0xCD), 0);

    try std.testing.expectError(
        Error.Tlz_ServerConnection_UnexpectedMessage,
        conn.readAppData(rec, &out),
    );
}

test "tlz connection: Connection, readAppData on an alert record is peer closed" {
    var conn = testConnection(0xAB, 0xCD);
    var rec_buf: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    const body = [_]u8{ 1, 0 };
    const rec = record.protect(&rec_buf, &body, .ALERT, @splat(0xAB), @splat(0xCD), 0);

    try std.testing.expectError(
        Error.Tlz_ServerConnection_PeerClosed,
        conn.readAppData(rec, &out),
    );
}

test "tlz connection: Connection, readAppData on an unknown inner type is decode" {
    var conn = testConnection(0xAB, 0xCD);
    var rec_buf: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    const rec = record.protect(&rec_buf, "x", @enumFromInt(0x18), @splat(0xAB), @splat(0xCD), 0);

    try std.testing.expectError(Error.Tlz_ServerConnection_Decode, conn.readAppData(rec, &out));
}

test "tlz connection: Connection, readAppData with the wrong key is a bad MAC" {
    var conn = testConnection(0xAB, 0xCD);
    var rec_buf: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    const rec = record.protect(&rec_buf, "x", .APPLICATION_DATA, @splat(0x01), @splat(0xCD), 0);

    try std.testing.expectError(
        Error.Tlz_ServerConnection_BadRecordMac,
        conn.readAppData(rec, &out),
    );
}

test "tlz connection: Connection, writeAppData2 round trips through readAppData" {
    var server = testConnection(0x24, 0x68);
    var client = testConnection(0x24, 0x68);
    const prefix = "\x00\x00\x05\x00\x01\x00\x00\x00\x03";
    const payload = "abcde";
    var rec_buf: [256]u8 = undefined;
    var out: [256]u8 = undefined;

    const rec = server.writeAppData2(prefix, payload, &rec_buf);
    const data = try client.readAppData(rec, &out);

    try std.testing.expectEqual(@as(u64, 1), server.server_app_seq);
    try std.testing.expectEqualSlices(u8, prefix ++ payload, data);
}

test "tlz connection: Connection, writeAppData advances the server sequence" {
    var conn = testConnection(0x24, 0x68);
    var rec_buf: [64]u8 = undefined;

    _ = conn.writeAppData("a", &rec_buf);
    _ = conn.writeAppData("b", &rec_buf);

    try std.testing.expectEqual(@as(u64, 2), conn.server_app_seq);
}

test "tlz connection: Connection, encryptedAlert is a fatal alert record" {
    var conn = testConnection(0x11, 0x22);
    var out: [64]u8 = undefined;
    var plain: [64]u8 = undefined;

    const rec = conn.encryptedAlert(.UNEXPECTED_MESSAGE, &out);
    const opened = try record.deprotect(&plain, rec, @splat(0x11), @splat(0x22), 0);
    const inbound = try Inbound.parse(opened.data);

    try std.testing.expectEqual(ContentType.ALERT, opened.inner_type);
    try std.testing.expect(inbound.isFatal());
    try std.testing.expectEqual(@intFromEnum(Alert.UNEXPECTED_MESSAGE), inbound.description);
}

test "tlz connection: Connection, closeNotify is a close_notify alert record" {
    var conn = testConnection(0x11, 0x22);
    var out: [64]u8 = undefined;
    var plain: [64]u8 = undefined;

    const rec = conn.closeNotify(&out);
    const opened = try record.deprotect(&plain, rec, @splat(0x11), @splat(0x22), 0);
    const inbound = try Inbound.parse(opened.data);

    try std.testing.expect(inbound.isCloseNotify());
}

test "tlz connection: Connection, verifyClientFinished accepts the right verify_data" {
    var conn = testConnection(0x31, 0x32);
    var finished_buf: [64]u8 = undefined;
    var rec_buf: [128]u8 = undefined;
    const finished = certificate.buildFinished(
        &finished_buf,
        conn.client_finished_key,
        conn.handshake_transcript.current(),
    );
    const rec = record.protect(&rec_buf, finished, .HANDSHAKE, @splat(0x31), @splat(0x32), 0);

    try conn.verifyClientFinished(rec);
}

test "tlz connection: Connection, verifyClientFinished rejects a wrong verify_data" {
    var conn = testConnection(0x31, 0x32);
    var finished_buf: [64]u8 = undefined;
    var rec_buf: [128]u8 = undefined;
    const finished = certificate.buildFinished(&finished_buf, @splat(0x01), @splat(0x02));
    const rec = record.protect(&rec_buf, finished, .HANDSHAKE, @splat(0x31), @splat(0x32), 0);

    try std.testing.expectError(
        Error.Tlz_ServerConnection_ClientFinishedMismatch,
        conn.verifyClientFinished(rec),
    );
}

test "tlz connection: Connection, verifyClientFinished on a short body is a mismatch" {
    var conn = testConnection(0x31, 0x32);
    var rec_buf: [128]u8 = undefined;
    const body = [_]u8{ 20, 0, 0 };
    const rec = record.protect(&rec_buf, &body, .HANDSHAKE, @splat(0x31), @splat(0x32), 0);

    try std.testing.expectError(
        Error.Tlz_ServerConnection_ClientFinishedMismatch,
        conn.verifyClientFinished(rec),
    );
}

test "tlz connection: Connection, verifyClientCertFlight on a non-certificate is unexpected" {
    var conn = testConnection(0x31, 0x32);
    var rec_buf: [128]u8 = undefined;
    var der_buf: [64]u8 = undefined;
    const body = [_]u8{ 20, 0, 0, 0 };
    const rec = record.protect(&rec_buf, &body, .HANDSHAKE, @splat(0x31), @splat(0x32), 0);

    try std.testing.expectError(
        Error.Tlz_ServerConnection_UnexpectedHandshakeMessage,
        conn.verifyClientCertFlight(rec, rec, &der_buf),
    );
}

test "tlz connection: Connection, verifyClientAuthFlight with an empty list is missing" {
    var conn = testConnection(0x31, 0x32);
    var rec_buf: [128]u8 = undefined;
    var der_buf: [64]u8 = undefined;
    const body = [_]u8{ 11, 0, 0, 4, 0, 0, 0, 0 };
    const rec = record.protect(&rec_buf, &body, .HANDSHAKE, @splat(0x31), @splat(0x32), 0);

    try std.testing.expectError(
        Error.Tlz_ServerConnection_ClientCertificateMissing,
        conn.verifyClientAuthFlight(rec, &der_buf),
    );
}

