//! ZIX tls h2 terminator
//!
//! ### file: src/zix/tls/h2_terminator.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Terminates TLS (1.3, or 1.2 as a fallback) in front of an h2 engine on a
//! blocking fd, requires ALPN h2, then hands the decrypted stream to a driver.
//!
//! ### note:
//!
//! Engine agnostic: the Http2 and gRPC TLS serve paths both pass their own
//! driver. A driver is any value with `drive(fd, conn, record_buf) void`, where
//! conn is the established TLS 1.3 or TLS 1.2 connection. RFC 7540 3.3: a
//! handshake that did not select h2 ends the connection.
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
const tlz = @import("tlz");
const Record = @import("h2_terminator/Record.zig");

const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

// --------------------------------------------------------- //
// Private:

const CONTENT_CHANGE_CIPHER_SPEC: u8 = @intFromEnum(tlz.ContentType.CHANGE_CIPHER_SPEC);
const CONTENT_ALERT: u8 = @intFromEnum(tlz.ContentType.ALERT);
const CONTENT_HANDSHAKE: u8 = @intFromEnum(tlz.ContentType.HANDSHAKE);
const CONTENT_APPLICATION_DATA: u8 = @intFromEnum(tlz.ContentType.APPLICATION_DATA);

/// Bytes of a record header (type, version, length).
const RECORD_HEADER_LEN: usize = 5;

/// Server handshake flight staging (certificate chain included).
const SERVER_FLIGHT_OUT_SIZE: usize = 8 * 1024;

/// HelloRetryRequest staging.
const HELLO_RETRY_OUT_SIZE: usize = 1024;

/// TLS 1.2 ClientKeyExchange copy, taken out before the record buffer is reused.
const CLIENT_KEY_EXCHANGE_SIZE: usize = 256;

/// TLS 1.2 server ChangeCipherSpec plus Finished staging.
const SERVER_FINISHED_OUT_SIZE: usize = 256;

const PssSalt = @FieldType(tlz.HandshakeOptions, "pss_salt");

/// The handshake error set of tlz.serverHandshake.
const HandshakeError = @typeInfo(
    @typeInfo(@TypeOf(tlz.serverHandshake)).@"fn".return_type.?,
).error_union.error_set;

const Inner =
    Error ||
    HandshakeError ||
    tlz.Connection.Error ||
    tlz.Server12.Error ||
    tlz.Server12.Connection.Error;

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixTls_H2Terminator_EntropyUnavailable,
        => Error.ZixTls_H2Terminator_EntropyUnavailable,
        error.ZixTls_H2Terminator_Canceled => Error.ZixTls_H2Terminator_Canceled,
        error.ZixTls_H2Terminator_Closed => Error.ZixTls_H2Terminator_Closed,
        error.ZixTls_H2Terminator_ReadFailed => Error.ZixTls_H2Terminator_ReadFailed,
        error.ZixTls_H2Terminator_BrokenPipe => Error.ZixTls_H2Terminator_BrokenPipe,
        error.ZixTls_H2Terminator_RecordTooLarge => Error.ZixTls_H2Terminator_RecordTooLarge,
        error.ZixTls_H2Terminator_UnexpectedRecord => Error.ZixTls_H2Terminator_UnexpectedRecord,
        error.ZixTls_H2Terminator_PeerAlert => Error.ZixTls_H2Terminator_PeerAlert,
        error.ZixTls_H2Terminator_Tls12RequiresEcdsa,
        => Error.ZixTls_H2Terminator_Tls12RequiresEcdsa,
        error.ZixTls_H2Terminator_AlpnNotH2 => Error.ZixTls_H2Terminator_AlpnNotH2,
        error.ZixTls_H2Terminator_MissingKeyShare => Error.ZixTls_H2Terminator_MissingKeyShare,
        error.ZixTls_H2Terminator_BadKeyShare => Error.ZixTls_H2Terminator_BadKeyShare,
        error.ZixTls_H2Terminator_UnsupportedCipher,
        => Error.ZixTls_H2Terminator_UnsupportedCipher,
        error.ZixTls_H2Terminator_UnsupportedGroup => Error.ZixTls_H2Terminator_UnsupportedGroup,
        error.ZixTls_H2Terminator_NoCommonSignatureScheme,
        => Error.ZixTls_H2Terminator_NoCommonSignatureScheme,
        error.ZixTls_H2Terminator_NoApplicationProtocol,
        => Error.ZixTls_H2Terminator_NoApplicationProtocol,
        error.ZixTls_H2Terminator_HelloRetryRequestUnsupported,
        => Error.ZixTls_H2Terminator_HelloRetryRequestUnsupported,
        error.ZixTls_H2Terminator_HelloRetryGroupMismatch,
        => Error.ZixTls_H2Terminator_HelloRetryGroupMismatch,
        error.ZixTls_H2Terminator_UnsupportedTlsVersion,
        => Error.ZixTls_H2Terminator_UnsupportedTlsVersion,
        error.ZixTls_H2Terminator_MissingExtension,
        => Error.ZixTls_H2Terminator_MissingExtension,
        error.ZixTls_H2Terminator_HandshakeFailure,
        => Error.ZixTls_H2Terminator_HandshakeFailure,
        error.ZixTls_H2Terminator_IllegalParameter,
        => Error.ZixTls_H2Terminator_IllegalParameter,
        error.ZixTls_H2Terminator_DecodeError => Error.ZixTls_H2Terminator_DecodeError,
        error.ZixTls_H2Terminator_SignFailed => Error.ZixTls_H2Terminator_SignFailed,
        error.ZixTls_H2Terminator_InvalidKey => Error.ZixTls_H2Terminator_InvalidKey,
        error.ZixTls_H2Terminator_MessageTooLong => Error.ZixTls_H2Terminator_MessageTooLong,
        error.ZixTls_H2Terminator_PeerClosed => Error.ZixTls_H2Terminator_PeerClosed,
        error.ZixTls_H2Terminator_UnexpectedMessage,
        => Error.ZixTls_H2Terminator_UnexpectedMessage,
        error.ZixTls_H2Terminator_UnexpectedHandshakeMessage,
        => Error.ZixTls_H2Terminator_UnexpectedHandshakeMessage,
        error.ZixTls_H2Terminator_Decode => Error.ZixTls_H2Terminator_Decode,
        error.ZixTls_H2Terminator_RecordOverflow => Error.ZixTls_H2Terminator_RecordOverflow,
        error.ZixTls_H2Terminator_BadRecordMac => Error.ZixTls_H2Terminator_BadRecordMac,
        error.ZixTls_H2Terminator_Truncated => Error.ZixTls_H2Terminator_Truncated,
        error.ZixTls_H2Terminator_ClientFinishedMismatch,
        => Error.ZixTls_H2Terminator_ClientFinishedMismatch,
        error.ZixTls_H2Terminator_ClientCertificateMissing,
        => Error.ZixTls_H2Terminator_ClientCertificateMissing,
        error.ZixTls_H2Terminator_CertificateTooLarge,
        => Error.ZixTls_H2Terminator_CertificateTooLarge,
        error.ZixTls_H2Terminator_UnsupportedSignatureScheme,
        => Error.ZixTls_H2Terminator_UnsupportedSignatureScheme,
        error.ZixTls_H2Terminator_SignatureFailed,
        => Error.ZixTls_H2Terminator_SignatureFailed,
        error.ZixTls_H2Terminator_UnsupportedPeerKey,
        => Error.ZixTls_H2Terminator_UnsupportedPeerKey,
        error.ZixTls_H2Terminator_CertificateMalformed,
        => Error.ZixTls_H2Terminator_CertificateMalformed,
        error.ZixTls_H2Terminator_CertificateHasUnrecognizedObjectId,
        => Error.ZixTls_H2Terminator_CertificateHasUnrecognizedObjectId,
        error.ZixTls_H2Terminator_ClientHelloInvalid,
        => Error.ZixTls_H2Terminator_ClientHelloInvalid,
        error.ZixTls_H2Terminator_BadRecord => Error.ZixTls_H2Terminator_BadRecord,
        error.ZixTls_H2Terminator_AuthenticationFailed,
        => Error.ZixTls_H2Terminator_AuthenticationFailed,
        error.Tlz_Connection_MissingKeyShare => Error.ZixTls_H2Terminator_MissingKeyShare,
        error.Tlz_Connection_BadKeyShare => Error.ZixTls_H2Terminator_BadKeyShare,
        error.Tlz_Connection_UnsupportedCipher => Error.ZixTls_H2Terminator_UnsupportedCipher,
        error.Tlz_Connection_UnsupportedGroup => Error.ZixTls_H2Terminator_UnsupportedGroup,
        error.Tlz_Connection_NoCommonSignatureScheme,
        => Error.ZixTls_H2Terminator_NoCommonSignatureScheme,
        error.Tlz_Connection_NoApplicationProtocol,
        => Error.ZixTls_H2Terminator_NoApplicationProtocol,
        error.Tlz_Connection_HelloRetryRequestUnsupported,
        => Error.ZixTls_H2Terminator_HelloRetryRequestUnsupported,
        error.Tlz_Connection_HelloRetryGroupMismatch,
        => Error.ZixTls_H2Terminator_HelloRetryGroupMismatch,
        error.Tlz_Connection_UnsupportedTlsVersion,
        => Error.ZixTls_H2Terminator_UnsupportedTlsVersion,
        error.Tlz_Connection_MissingExtension => Error.ZixTls_H2Terminator_MissingExtension,
        error.Tlz_Connection_HandshakeFailure => Error.ZixTls_H2Terminator_HandshakeFailure,
        error.Tlz_Connection_IllegalParameter => Error.ZixTls_H2Terminator_IllegalParameter,
        error.Tlz_Connection_DecodeError => Error.ZixTls_H2Terminator_DecodeError,
        error.Tlz_Connection_SignFailed => Error.ZixTls_H2Terminator_SignFailed,
        error.Tlz_Connection_InvalidKey => Error.ZixTls_H2Terminator_InvalidKey,
        error.Tlz_Connection_MessageTooLong => Error.ZixTls_H2Terminator_MessageTooLong,
        error.Tlz_ServerConnection_PeerClosed => Error.ZixTls_H2Terminator_PeerClosed,
        error.Tlz_ServerConnection_UnexpectedMessage,
        => Error.ZixTls_H2Terminator_UnexpectedMessage,
        error.Tlz_ServerConnection_UnexpectedHandshakeMessage,
        => Error.ZixTls_H2Terminator_UnexpectedHandshakeMessage,
        error.Tlz_ServerConnection_Decode => Error.ZixTls_H2Terminator_Decode,
        error.Tlz_ServerConnection_RecordOverflow => Error.ZixTls_H2Terminator_RecordOverflow,
        error.Tlz_ServerConnection_BadRecordMac => Error.ZixTls_H2Terminator_BadRecordMac,
        error.Tlz_ServerConnection_Truncated => Error.ZixTls_H2Terminator_Truncated,
        error.Tlz_ServerConnection_ClientFinishedMismatch,
        => Error.ZixTls_H2Terminator_ClientFinishedMismatch,
        error.Tlz_ServerConnection_ClientCertificateMissing,
        => Error.ZixTls_H2Terminator_ClientCertificateMissing,
        error.Tlz_ServerConnection_CertificateTooLarge,
        => Error.ZixTls_H2Terminator_CertificateTooLarge,
        error.Tlz_ServerConnection_UnsupportedSignatureScheme,
        => Error.ZixTls_H2Terminator_UnsupportedSignatureScheme,
        error.Tlz_ServerConnection_SignatureFailed,
        => Error.ZixTls_H2Terminator_SignatureFailed,
        error.Tlz_ServerConnection_UnsupportedPeerKey,
        => Error.ZixTls_H2Terminator_UnsupportedPeerKey,
        error.Tlz_ServerConnection_CertificateMalformed,
        => Error.ZixTls_H2Terminator_CertificateMalformed,
        error.Tlz_ServerConnection_CertificateHasUnrecognizedObjectId,
        => Error.ZixTls_H2Terminator_CertificateHasUnrecognizedObjectId,
        error.Tlz_Tls12Connection_ClientHelloInvalid,
        => Error.ZixTls_H2Terminator_ClientHelloInvalid,
        error.Tlz_Tls12Connection_UnexpectedMessage,
        => Error.ZixTls_H2Terminator_UnexpectedMessage,
        error.Tlz_Tls12Connection_ClientFinishedMismatch,
        => Error.ZixTls_H2Terminator_ClientFinishedMismatch,
        error.Tlz_Tls12Connection_Truncated => Error.ZixTls_H2Terminator_Truncated,
        error.Tlz_Tls12Connection_BadKeyShare => Error.ZixTls_H2Terminator_BadKeyShare,
        error.Tlz_Tls12Connection_SignFailed => Error.ZixTls_H2Terminator_SignFailed,
        error.Tlz_Tls12Connection_BadRecord => Error.ZixTls_H2Terminator_BadRecord,
        error.Tlz_Tls12Connection_AuthenticationFailed,
        => Error.ZixTls_H2Terminator_AuthenticationFailed,
        error.Tlz_Tls12ServerConnection_BadRecord => Error.ZixTls_H2Terminator_BadRecord,
        error.Tlz_Tls12ServerConnection_AuthenticationFailed,
        => Error.ZixTls_H2Terminator_AuthenticationFailed,
    };
}

/// Read exactly buf.len bytes.
fn readAll(fd: std.posix.fd_t, buf: []u8) Inner!void {
    var got: usize = 0;
    while (got < buf.len) {
        const count = std.posix.read(fd, buf[got..]) catch |err| switch (err) {
            else => return Error.ZixTls_H2Terminator_ReadFailed,
        };
        if (count == 0) return Error.ZixTls_H2Terminator_Closed;

        got += count;
    }
}

/// Best effort: the connection is ending either way, a failed write changes nothing.
fn writeBestEffort(fd: std.posix.fd_t, bytes: []const u8) void {
    writeAll(fd, bytes) catch |err| switch (err) {
        else => {},
    };
}

/// Send the plaintext fatal alert for a handshake error (no keys yet).
fn sendHandshakeAlert(fd: std.posix.fd_t, err: HandshakeError) void {
    var alert: [tlz.FATAL_RECORD_LEN]u8 = undefined;
    const bytes = tlz.alertRecordForError(&alert, err) orelse return;

    writeBestEffort(fd, bytes);
}

fn randomSecure(io: std.Io, buf: []u8) Inner!void {
    io.randomSecure(buf) catch |err| switch (err) {
        error.EntropyUnavailable => return Error.ZixTls_H2Terminator_EntropyUnavailable,
        error.Canceled => return Error.ZixTls_H2Terminator_Canceled,
    };
}

/// The ECDSA key a TLS 1.2 handshake signs with. Ed25519 and RSA are 1.3 only.
fn tls12Key(ctx: *const tlz.Context) Inner!EcdsaP256.KeyPair {
    return switch (ctx.signing_key) {
        .ecdsa_p256 => |key_pair| key_pair,
        else => Error.ZixTls_H2Terminator_Tls12RequiresEcdsa,
    };
}

/// TLS 1.2 path (RFC 5246 + 5288, ECDHE-ECDSA): two-phase handshake, ALPN h2,
/// then the driver. Reached only when the client did not offer TLS 1.3, or the
/// context caps the version at TLS 1.2.
fn serveConnTls12(
    fd: std.posix.fd_t,
    ctx: *const tlz.Context,
    key_pair: EcdsaP256.KeyPair,
    client_hello: []const u8,
    ephemeral_secret: [32]u8,
    server_random: [32]u8,
    driver: anytype,
) Inner!void {
    var flight_out: [SERVER_FLIGHT_OUT_SIZE]u8 = undefined;
    const flight = try tlz.Server12.serverFlight1(.{
        .certificate_der = ctx.cert_der,
        .signing_key = key_pair,
        .server_eph_secret = ephemeral_secret,
        .server_random = server_random,
        .alpn_prefs = ctx.alpn,
    }, client_hello, &flight_out);
    try writeAll(fd, flight.to_send);
    var state = flight.state;

    // RFC 7540 3.3: h2 over TLS needs ALPN to have selected h2.
    if (state.alpn != .H2) return Error.ZixTls_H2Terminator_AlpnNotH2;

    var record_buf: [tlz.MAX_RECORD_WIRE]u8 = undefined;

    // ClientKeyExchange, copied out before record_buf is reused.
    const key_exchange_rec = try readRecord(fd, &record_buf);
    if (key_exchange_rec.content_type != CONTENT_HANDSHAKE) {
        return Error.ZixTls_H2Terminator_UnexpectedRecord;
    }

    var key_exchange_buf: [CLIENT_KEY_EXCHANGE_SIZE]u8 = undefined;
    if (key_exchange_rec.body.len > key_exchange_buf.len) {
        return Error.ZixTls_H2Terminator_RecordTooLarge;
    }

    @memcpy(key_exchange_buf[0..key_exchange_rec.body.len], key_exchange_rec.body);
    const client_key_exchange = key_exchange_buf[0..key_exchange_rec.body.len];

    // Skip ChangeCipherSpec, then the encrypted client Finished.
    const finished_rec = while (true) {
        const rec = try readRecord(fd, &record_buf);
        if (rec.content_type == CONTENT_CHANGE_CIPHER_SPEC) continue;
        if (rec.content_type == CONTENT_ALERT) return Error.ZixTls_H2Terminator_PeerAlert;
        if (rec.content_type != CONTENT_HANDSHAKE) {
            return Error.ZixTls_H2Terminator_UnexpectedRecord;
        }

        break rec;
    };

    var finish_out: [SERVER_FINISHED_OUT_SIZE]u8 = undefined;
    const finish = try tlz.Server12.serverFinish(
        &state,
        client_key_exchange,
        finished_rec.full,
        &finish_out,
    );
    try writeAll(fd, finish.to_send);
    var conn = finish.connection;

    driver.drive(fd, &conn, &record_buf);
}

/// Handshake one connection (TLS 1.3, HelloRetryRequest, or the TLS 1.2
/// fallback), check ALPN h2, then run the driver.
fn serveConn(
    fd: std.posix.fd_t,
    ctx: *const tlz.Context,
    io: std.Io,
    driver: anytype,
) Inner!void {
    var record_buf: [tlz.MAX_RECORD_WIRE]u8 = undefined;

    const hello_rec = try readRecord(fd, &record_buf);
    if (hello_rec.content_type != CONTENT_HANDSHAKE) {
        return Error.ZixTls_H2Terminator_UnexpectedRecord;
    }

    var ephemeral_secret: [32]u8 = undefined;
    var server_random: [32]u8 = undefined;
    var pss_salt: PssSalt = undefined;
    try randomSecure(io, &ephemeral_secret);
    try randomSecure(io, &server_random);
    try randomSecure(io, &pss_salt);

    const opts = ctx.handshakeOptions(ephemeral_secret, server_random, pss_salt);

    if (!ctx.allowsTls13()) {
        return serveConnTls12(
            fd,
            ctx,
            try tls12Key(ctx),
            hello_rec.body,
            ephemeral_secret,
            server_random,
            driver,
        );
    }

    // HelloRetryRequest: the client picked a group it sent no key_share for.
    var handshake_out: [SERVER_FLIGHT_OUT_SIZE]u8 = undefined;
    var retry_out: [HELLO_RETRY_OUT_SIZE]u8 = undefined;
    var retry_state: ?tlz.RetryState = null;
    var second_hello: []const u8 = &.{};

    if (tlz.serverHelloRetry(opts, hello_rec.body, &retry_out)) |maybe_retry| {
        if (maybe_retry) |retry| {
            try writeAll(fd, retry.to_send);

            const second_rec = try readRecord(fd, &record_buf);
            if (second_rec.content_type != CONTENT_HANDSHAKE) {
                return Error.ZixTls_H2Terminator_UnexpectedRecord;
            }

            retry_state = retry.state;
            second_hello = second_rec.body;
        }
    } else |err| {
        // A 1.2 client falls through to serverHandshake below.
        if (err != error.Tlz_Connection_UnsupportedTlsVersion) {
            sendHandshakeAlert(fd, err);

            return err;
        }
    }

    const result = if (retry_state) |retry|
        try tlz.serverHandshakeAfterRetry(retry, second_hello, &handshake_out)
    else
        tlz.serverHandshake(opts, hello_rec.body, &handshake_out) catch |err| {
            if (err != error.Tlz_Connection_UnsupportedTlsVersion) {
                sendHandshakeAlert(fd, err);

                return err;
            }

            // No 1.3 offer: the client is TLS 1.2 only. Honor the floor.
            if (!ctx.allowsTls12()) {
                sendHandshakeAlert(fd, err);

                return err;
            }

            return serveConnTls12(
                fd,
                ctx,
                try tls12Key(ctx),
                hello_rec.body,
                ephemeral_secret,
                server_random,
                driver,
            );
        };

    try writeAll(fd, result.to_send);
    var conn = result.connection;

    // RFC 7540 3.3: h2 over TLS needs ALPN to have selected h2.
    if (result.alpn != .H2) return Error.ZixTls_H2Terminator_AlpnNotH2;

    // Client ChangeCipherSpec (skipped), then Finished. An alert means the peer aborted.
    while (true) {
        const rec = try readRecord(fd, &record_buf);
        if (rec.content_type == CONTENT_CHANGE_CIPHER_SPEC) continue;
        if (rec.content_type == CONTENT_ALERT) return Error.ZixTls_H2Terminator_PeerAlert;
        if (rec.content_type != CONTENT_APPLICATION_DATA) {
            return Error.ZixTls_H2Terminator_UnexpectedRecord;
        }

        try conn.verifyClientFinished(rec.full);
        break;
    }

    driver.drive(fd, &conn, &record_buf);
}

// --------------------------------------------------------- //
// Public:

/// ZIX tls h2 terminator error
pub const Error = error {
    ZixTls_H2Terminator_EntropyUnavailable,
    ZixTls_H2Terminator_Canceled,
    ZixTls_H2Terminator_Closed,
    ZixTls_H2Terminator_ReadFailed,
    ZixTls_H2Terminator_BrokenPipe,
    ZixTls_H2Terminator_RecordTooLarge,
    ZixTls_H2Terminator_UnexpectedRecord,
    ZixTls_H2Terminator_PeerAlert,
    ZixTls_H2Terminator_Tls12RequiresEcdsa,
    ZixTls_H2Terminator_AlpnNotH2,
    ZixTls_H2Terminator_MissingKeyShare,
    ZixTls_H2Terminator_BadKeyShare,
    ZixTls_H2Terminator_UnsupportedCipher,
    ZixTls_H2Terminator_UnsupportedGroup,
    ZixTls_H2Terminator_NoCommonSignatureScheme,
    ZixTls_H2Terminator_NoApplicationProtocol,
    ZixTls_H2Terminator_HelloRetryRequestUnsupported,
    ZixTls_H2Terminator_HelloRetryGroupMismatch,
    ZixTls_H2Terminator_UnsupportedTlsVersion,
    ZixTls_H2Terminator_MissingExtension,
    ZixTls_H2Terminator_HandshakeFailure,
    ZixTls_H2Terminator_IllegalParameter,
    ZixTls_H2Terminator_DecodeError,
    ZixTls_H2Terminator_SignFailed,
    ZixTls_H2Terminator_InvalidKey,
    ZixTls_H2Terminator_MessageTooLong,
    ZixTls_H2Terminator_PeerClosed,
    ZixTls_H2Terminator_UnexpectedMessage,
    ZixTls_H2Terminator_UnexpectedHandshakeMessage,
    ZixTls_H2Terminator_Decode,
    ZixTls_H2Terminator_RecordOverflow,
    ZixTls_H2Terminator_BadRecordMac,
    ZixTls_H2Terminator_Truncated,
    ZixTls_H2Terminator_ClientFinishedMismatch,
    ZixTls_H2Terminator_ClientCertificateMissing,
    ZixTls_H2Terminator_CertificateTooLarge,
    ZixTls_H2Terminator_UnsupportedSignatureScheme,
    ZixTls_H2Terminator_SignatureFailed,
    ZixTls_H2Terminator_UnsupportedPeerKey,
    ZixTls_H2Terminator_CertificateMalformed,
    ZixTls_H2Terminator_CertificateHasUnrecognizedObjectId,
    ZixTls_H2Terminator_ClientHelloInvalid,
    ZixTls_H2Terminator_BadRecord,
    ZixTls_H2Terminator_AuthenticationFailed,
};

/// Read one whole TLS record (header plus payload) from a blocking fd.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// buf - []u8 (holds the record, tlz.MAX_RECORD_WIRE fits any record)
///
/// Return:
/// - Record (slices into buf)
/// - Error.ZixTls_H2Terminator_RecordTooLarge when the record does not fit buf
/// - Error.ZixTls_H2Terminator_Closed when the peer closed mid-record
/// - Error.ZixTls_H2Terminator_ReadFailed on a read error
pub fn readRecord(fd: std.posix.fd_t, buf: []u8) Error!Record {
    if (buf.len < RECORD_HEADER_LEN) return Error.ZixTls_H2Terminator_RecordTooLarge;

    readAll(fd, buf[0..RECORD_HEADER_LEN]) catch |err| return innerError(err);

    const length = std.mem.readInt(u16, buf[3..5], .big);
    if (RECORD_HEADER_LEN + length > buf.len) return Error.ZixTls_H2Terminator_RecordTooLarge;

    const body = buf[RECORD_HEADER_LEN .. RECORD_HEADER_LEN + length];
    readAll(fd, body) catch |err| return innerError(err);

    return .{
        .content_type = buf[0],
        .full = buf[0 .. RECORD_HEADER_LEN + length],
        .body = body,
    };
}

/// Write all of bytes to a blocking fd, retrying short writes.
///
/// Return:
/// - void when every byte was accepted
/// - Error.ZixTls_H2Terminator_BrokenPipe on a write error or a peer that left
pub fn writeAll(fd: std.posix.fd_t, bytes: []const u8) Error!void {
    var rest = bytes;

    while (rest.len > 0) {
        const rc = std.posix.system.write(fd, rest.ptr, rest.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const written: usize = @intCast(rc);
                if (written == 0) return Error.ZixTls_H2Terminator_BrokenPipe;

                rest = rest[written..];
            },
            .INTR => continue,
            else => return Error.ZixTls_H2Terminator_BrokenPipe,
        }
    }
}

/// Terminate TLS on fd, then serve the decrypted h2 stream through driver.
///
/// Note:
/// - A rejected ClientHello gets its fatal alert in the clear (no keys yet).
/// - The driver owns the connection until it returns. The caller closes fd.
///
/// Param:
/// fd - std.posix.fd_t (the accepted, blocking socket, owned by the caller)
/// ctx - *const tlz.Context (loaded cert, key, ALPN, and version policy)
/// io - std.Io (the CSPRNG for the handshake randoms)
/// driver - anytype (its drive(fd, conn, record_buf) runs the h2 engine)
///
/// Return:
/// - void once the driver returned
/// - Error.ZixTls_H2Terminator_AlpnNotH2 when the handshake did not select h2
/// - any other member when the handshake failed
pub fn serveConnTls(
    fd: std.posix.fd_t,
    ctx: *const tlz.Context,
    io: std.Io,
    driver: anytype,
) Error!void {
    return serveConn(fd, ctx, io, driver) catch |err| innerError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../utils/socket/pair.zig");

const CERT_PATH = "examples/certs/ecdsa_p256_cert.pem";
const KEY_PATH = "examples/certs/ecdsa_p256_key.pem";

/// Echoes one decrypted record back sealed, then sends close_notify.
const EchoDriver = struct {
    drove: *bool,

    pub fn drive(self: EchoDriver, fd: std.posix.fd_t, conn: anytype, record_buf: []u8) void {
        self.drove.* = true;

        const rec = readRecord(fd, record_buf) catch return;
        var plain: [tlz.MAX_PLAINTEXT]u8 = undefined;
        const got = conn.readAppData(rec.full, &plain) catch return;

        var sealed: [tlz.sealedLen(tlz.MAX_PLAINTEXT)]u8 = undefined;
        writeBestEffort(fd, conn.writeAppData(got, &sealed));

        var close_buf: [64]u8 = undefined;
        writeBestEffort(fd, conn.closeNotify(&close_buf));
    }
};

const TestServer = struct {
    fn run(fd: std.posix.fd_t, ctx: *const tlz.Context, drove: *bool, result: *?Error) void {
        serveConnTls(fd, ctx, std.testing.io, EchoDriver{ .drove = drove }) catch |err| {
            result.* = err;
        };

        _ = std.posix.system.close(fd);
    }
};

/// Write one plaintext handshake record carrying message.
fn writeHandshakeRecord(fd: std.posix.fd_t, message: []const u8) !void {
    var rec: [600]u8 = undefined;
    rec[0] = CONTENT_HANDSHAKE;
    std.mem.writeInt(u16, rec[1..3], 0x0303, .big);
    std.mem.writeInt(u16, rec[3..5], @intCast(message.len), .big);
    @memcpy(rec[RECORD_HEADER_LEN..][0..message.len], message);

    try writeAll(fd, rec[0 .. RECORD_HEADER_LEN + message.len]);
}

fn testContext(alpn: []const tlz.Alpn) !tlz.Context {
    return tlz.Context.init(std.testing.allocator, std.testing.io, .{
        .cert_path = CERT_PATH,
        .key_path = KEY_PATH,
        .alpn = alpn,
    });
}

test "zix tls: h2_terminator, ALPN h2 hands the stream to the driver" {
    var ctx = try testContext(&.{.H2});
    defer ctx.deinit();

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    var drove = false;
    var server_error: ?Error = null;
    const thread = try std.Thread.spawn(.{}, TestServer.run, .{
        fds[1],
        &ctx,
        &drove,
        &server_error,
    });

    var hello_buf: [512]u8 = undefined;
    const started = try tlz.Client.start(.{
        .client_random = @splat(0x11),
        .ephemeral_secret = @splat(0x42),
        .alpn = &.{.H2},
    }, &hello_buf);
    var state = started.state;
    try writeHandshakeRecord(fds[0], started.client_hello);

    var flight_buf: [4096]u8 = undefined;
    var flight_len: usize = 0;
    for (0..3) |_| {
        const rec = try readRecord(fds[0], flight_buf[flight_len..]);
        flight_len += rec.full.len;
    }

    var fin_buf: [256]u8 = undefined;
    var finished = try tlz.Client.finish(&state, flight_buf[0..flight_len], &fin_buf);
    try writeAll(fds[0], finished.client_finished);

    var enc: [256]u8 = undefined;
    try writeAll(fds[0], finished.connection.writeAppData("ping", &enc));

    var rec_buf: [tlz.MAX_RECORD_WIRE]u8 = undefined;
    const reply = try readRecord(fds[0], &rec_buf);
    var plain: [64]u8 = undefined;
    const echoed = try finished.connection.readAppData(reply.full, &plain);

    thread.join();

    try std.testing.expectEqual(tlz.Alpn.H2, finished.alpn.?);
    try std.testing.expectEqualStrings("ping", echoed);
    try std.testing.expect(drove);
    try std.testing.expect(server_error == null);
}

test "zix tls: h2_terminator, no ALPN offer is AlpnNotH2" {
    var ctx = try testContext(&.{.H2});
    defer ctx.deinit();

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    var drove = false;
    var server_error: ?Error = null;
    const thread = try std.Thread.spawn(.{}, TestServer.run, .{
        fds[1],
        &ctx,
        &drove,
        &server_error,
    });

    var hello_buf: [512]u8 = undefined;
    const started = try tlz.Client.start(.{
        .client_random = @splat(0x11),
        .ephemeral_secret = @splat(0x42),
    }, &hello_buf);
    try writeHandshakeRecord(fds[0], started.client_hello);

    thread.join();

    try std.testing.expect(!drove);
    try std.testing.expectEqual(Error.ZixTls_H2Terminator_AlpnNotH2, server_error.?);
}

test "zix tls: h2_terminator, a TLS 1.2 client without ALPN h2 is AlpnNotH2" {
    var ctx = try testContext(&.{.H2});
    defer ctx.deinit();

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    var drove = false;
    var server_error: ?Error = null;
    const thread = try std.Thread.spawn(.{}, TestServer.run, .{
        fds[1],
        &ctx,
        &drove,
        &server_error,
    });

    var hello_buf: [512]u8 = undefined;
    const started = tlz.Client12.start(.{
        .client_random = @splat(0x21),
        .ephemeral_secret = @splat(0x43),
    }, &hello_buf);
    try writeHandshakeRecord(fds[0], started.client_hello);

    thread.join();

    try std.testing.expect(!drove);
    try std.testing.expectEqual(Error.ZixTls_H2Terminator_AlpnNotH2, server_error.?);
}

test "zix tls: h2_terminator, a TLS 1.2 client under a TLS 1.3 floor is refused" {
    var ctx = try tlz.Context.init(std.testing.allocator, std.testing.io, .{
        .cert_path = CERT_PATH,
        .key_path = KEY_PATH,
        .alpn = &.{.H2},
        .min_version = .TLS_1_3,
    });
    defer ctx.deinit();

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    var drove = false;
    var server_error: ?Error = null;
    const thread = try std.Thread.spawn(.{}, TestServer.run, .{
        fds[1],
        &ctx,
        &drove,
        &server_error,
    });

    var hello_buf: [512]u8 = undefined;
    const started = tlz.Client12.start(.{
        .client_random = @splat(0x21),
        .ephemeral_secret = @splat(0x43),
    }, &hello_buf);
    try writeHandshakeRecord(fds[0], started.client_hello);

    thread.join();

    try std.testing.expect(!drove);
    try std.testing.expectEqual(Error.ZixTls_H2Terminator_UnsupportedTlsVersion, server_error.?);
}

test "zix tls: h2_terminator, a first record that is not a handshake is UnexpectedRecord" {
    var ctx = try testContext(&.{.H2});
    defer ctx.deinit();

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    var drove = false;
    var server_error: ?Error = null;
    const thread = try std.Thread.spawn(.{}, TestServer.run, .{
        fds[1],
        &ctx,
        &drove,
        &server_error,
    });

    try writeAll(fds[0], "\x17\x03\x03\x00\x01x");

    thread.join();

    try std.testing.expect(!drove);
    try std.testing.expectEqual(Error.ZixTls_H2Terminator_UnexpectedRecord, server_error.?);
}

test "zix tls: h2_terminator, a peer that closes before the hello is Closed" {
    var ctx = try testContext(&.{.H2});
    defer ctx.deinit();

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);

    var drove = false;
    var server_error: ?Error = null;
    const thread = try std.Thread.spawn(.{}, TestServer.run, .{
        fds[1],
        &ctx,
        &drove,
        &server_error,
    });

    _ = std.posix.system.close(fds[0]);

    thread.join();

    try std.testing.expectEqual(Error.ZixTls_H2Terminator_Closed, server_error.?);
}

test "zix tls: h2_terminator, readRecord past the buffer is RecordTooLarge" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try writeAll(fds[0], "\x17\x03\x03\x00\x40");

    var small: [16]u8 = undefined;

    try std.testing.expectError(
        Error.ZixTls_H2Terminator_RecordTooLarge,
        readRecord(fds[1], &small),
    );
}

test "zix tls: h2_terminator, readRecord splits header and body" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try writeAll(fds[0], "\x16\x03\x03\x00\x03abc");

    var buf: [64]u8 = undefined;
    const rec = try readRecord(fds[1], &buf);

    try std.testing.expectEqual(CONTENT_HANDSHAKE, rec.content_type);
    try std.testing.expectEqualStrings("abc", rec.body);
    try std.testing.expectEqual(@as(usize, 8), rec.full.len);
}

test "zix tls: h2_terminator, writeAll on a closed fd is BrokenPipe" {
    try std.testing.expectError(Error.ZixTls_H2Terminator_BrokenPipe, writeAll(-1, "x"));
}

test "zix tls: h2_terminator, innerError keeps the condition name" {
    try std.testing.expectEqual(
        Error.ZixTls_H2Terminator_NoApplicationProtocol,
        innerError(error.Tlz_Connection_NoApplicationProtocol),
    );
    try std.testing.expectEqual(
        Error.ZixTls_H2Terminator_BadRecord,
        innerError(error.Tlz_Tls12ServerConnection_BadRecord),
    );
}

