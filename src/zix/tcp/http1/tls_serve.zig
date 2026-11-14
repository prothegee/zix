//! ZIX http1 tls serve
//!
//! ### file: src/zix/tcp/http1/tls_serve.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! https/1.1 serve path for the .ASYNC model: one task per connection runs the
//! TLS handshake, then a keep-alive request loop over the established session.
//!
//! ### note:
//!
//! A 1.3-capable client takes the TLS 1.3 path, a 1.2-only client takes the TLS
//! 1.2 path (ECDSA only), each bounded by the context min_version and max_version.
//! The handler writes into an in-memory sink. A response past that buffer, an
//! SSE stream, and a WebSocket all leave through the TLS stream sink, sealed one
//! write at a time. .EPOLL and .URING use tls_mux instead.
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
const tlz = @import("tlz");
const Config = @import("Config.zig");
const handler_mod = @import("handler.zig");
const HandlerFn = handler_mod.HandlerFn;
const head_mod = @import("head.zig");
const header = @import("header.zig");
const log = @import("log.zig");
const parser = @import("parser.zig");
const ParsedHead = @import("ParsedHead.zig");
const reader = @import("reader.zig");
const RespSink = @import("RespSink.zig");
const static = @import("static.zig");
const TlsStreamSink = @import("TlsStreamSink.zig");
const TlsPeers = @import("TlsPeers.zig");
const writer = @import("writer.zig");
const ws_pending = @import("websocket/pending.zig");
const ws_pump = @import("websocket/pump.zig");
const WsFrameFn = @import("websocket/frame_fn.zig").WsFrameFn;
const tls_feed = @import("tls_feed.zig");
const ConnCtx = @import("tls_serve/ConnCtx.zig");
const HandlerResult = @import("tls_serve/HandlerResult.zig");
const Record = @import("tls_serve/Record.zig");

const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

// --------------------------------------------------------- //
// Private:

const CONTENT_CHANGE_CIPHER_SPEC: u8 = @intFromEnum(tlz.ContentType.CHANGE_CIPHER_SPEC);
const CONTENT_ALERT: u8 = @intFromEnum(tlz.ContentType.ALERT);
const CONTENT_HANDSHAKE: u8 = @intFromEnum(tlz.ContentType.HANDSHAKE);
const CONTENT_APPLICATION_DATA: u8 = @intFromEnum(tlz.ContentType.APPLICATION_DATA);

/// Bytes of a record header (type, version, length).
const RECORD_HEADER_LEN: usize = 5;

/// Server handshake flight staging (TLS 1.3 and TLS 1.2).
const SERVER_FLIGHT_OUT_SIZE: usize = 8 * 1024;

/// HelloRetryRequest staging (RFC 8446 4.1.4).
const HELLO_RETRY_OUT_SIZE: usize = 1024;

/// ClientKeyExchange body copy (TLS 1.2).
const CLIENT_KEY_EXCHANGE_SIZE: usize = 256;

/// Server Finished staging (TLS 1.2).
const SERVER_FINISHED_OUT_SIZE: usize = 256;

/// One sealed record. A longer response leaves record by record through here.
const APP_DATA_ENCRYPT_OUT_SIZE: usize = tlz.sealedLen(tlz.MAX_PLAINTEXT);

/// One encrypted alert record (close_notify or a fatal alert after keys exist).
const ENCRYPTED_ALERT_SIZE: usize = 64;

/// Decrypted request plaintext: the largest request head over TLS.
const REQUEST_PLAIN_SIZE: usize = 17 * 1024;

/// Handler response staging. Not a ceiling: a larger response spills through
/// the TLS stream sink while it renders.
const RESPONSE_BUF_SIZE: usize = 64 * 1024;

/// WebSocket over TLS buffers: frame bytes, one decrypted record, the largest
/// unmasked payload, and the coalesced outbound frames.
const WS_ACC_SIZE: usize = 17 * 1024;
const WS_RECORD_PLAIN_SIZE: usize = 17 * 1024;
const WS_PAYLOAD_SIZE: usize = 16 * 1024;
const WS_OUT_SIZE: usize = 32 * 1024;

const BAD_REQUEST =
    "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const PAYLOAD_TOO_LARGE =
    "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const HEAD_TOO_LARGE =
    "HTTP/1.1 431 Request Header Fields Too Large\r\n" ++
    "Content-Length: 0\r\nConnection: close\r\n\r\n";
const MISDIRECTED =
    "HTTP/1.1 421 Misdirected Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
const INTERNAL_ERROR =
    "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

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
        error.ZixHttp1_TlsServe_ResolveFailed => Error.ZixHttp1_TlsServe_ResolveFailed,
        error.ZixHttp1_TlsServe_ListenFailed => Error.ZixHttp1_TlsServe_ListenFailed,
        error.ZixHttp1_TlsServe_AcceptFailed => Error.ZixHttp1_TlsServe_AcceptFailed,
        error.ZixHttp1_TlsServe_EntropyUnavailable => Error.ZixHttp1_TlsServe_EntropyUnavailable,
        error.ZixHttp1_TlsServe_Canceled => Error.ZixHttp1_TlsServe_Canceled,
        error.ZixHttp1_TlsServe_Closed => Error.ZixHttp1_TlsServe_Closed,
        error.ZixHttp1_TlsServe_HeaderTooLarge => Error.ZixHttp1_TlsServe_HeaderTooLarge,
        error.ZixHttp1_TlsServe_ReadFailed => Error.ZixHttp1_TlsServe_ReadFailed,
        error.ZixHttp1_TlsServe_SetBufFailed => Error.ZixHttp1_TlsServe_SetBufFailed,
        error.ZixHttp1_TlsServe_BrokenPipe => Error.ZixHttp1_TlsServe_BrokenPipe,
        error.ZixHttp1_TlsServe_HeadBuild => Error.ZixHttp1_TlsServe_HeadBuild,
        error.ZixHttp1_TlsServe_RecordTooLarge => Error.ZixHttp1_TlsServe_RecordTooLarge,
        error.ZixHttp1_TlsServe_UnexpectedRecord => Error.ZixHttp1_TlsServe_UnexpectedRecord,
        error.ZixHttp1_TlsServe_PeerAlert => Error.ZixHttp1_TlsServe_PeerAlert,
        error.ZixHttp1_TlsServe_Tls12RequiresEcdsa => Error.ZixHttp1_TlsServe_Tls12RequiresEcdsa,
        error.ZixHttp1_TlsServe_RecordSealFailed => Error.ZixHttp1_TlsServe_RecordSealFailed,
        error.ZixHttp1_TlsServe_InvalidRequest => Error.ZixHttp1_TlsServe_InvalidRequest,
        error.ZixHttp1_TlsServe_UnknownMethod => Error.ZixHttp1_TlsServe_UnknownMethod,
        error.ZixHttp1_TlsServe_ResponseTooLarge => Error.ZixHttp1_TlsServe_ResponseTooLarge,
        error.ZixHttp1_TlsServe_StreamingNotSupported,
        => Error.ZixHttp1_TlsServe_StreamingNotSupported,
        error.ZixHttp1_TlsServe_WsFrameTooLarge => Error.ZixHttp1_TlsServe_WsFrameTooLarge,
        error.ZixHttp1_TlsServe_MissingKeyShare => Error.ZixHttp1_TlsServe_MissingKeyShare,
        error.ZixHttp1_TlsServe_BadKeyShare => Error.ZixHttp1_TlsServe_BadKeyShare,
        error.ZixHttp1_TlsServe_UnsupportedCipher => Error.ZixHttp1_TlsServe_UnsupportedCipher,
        error.ZixHttp1_TlsServe_UnsupportedGroup => Error.ZixHttp1_TlsServe_UnsupportedGroup,
        error.ZixHttp1_TlsServe_NoCommonSignatureScheme,
        => Error.ZixHttp1_TlsServe_NoCommonSignatureScheme,
        error.ZixHttp1_TlsServe_NoApplicationProtocol,
        => Error.ZixHttp1_TlsServe_NoApplicationProtocol,
        error.ZixHttp1_TlsServe_HelloRetryRequestUnsupported,
        => Error.ZixHttp1_TlsServe_HelloRetryRequestUnsupported,
        error.ZixHttp1_TlsServe_HelloRetryGroupMismatch,
        => Error.ZixHttp1_TlsServe_HelloRetryGroupMismatch,
        error.ZixHttp1_TlsServe_UnsupportedTlsVersion,
        => Error.ZixHttp1_TlsServe_UnsupportedTlsVersion,
        error.ZixHttp1_TlsServe_MissingExtension => Error.ZixHttp1_TlsServe_MissingExtension,
        error.ZixHttp1_TlsServe_HandshakeFailure => Error.ZixHttp1_TlsServe_HandshakeFailure,
        error.ZixHttp1_TlsServe_IllegalParameter => Error.ZixHttp1_TlsServe_IllegalParameter,
        error.ZixHttp1_TlsServe_DecodeError => Error.ZixHttp1_TlsServe_DecodeError,
        error.ZixHttp1_TlsServe_SignFailed => Error.ZixHttp1_TlsServe_SignFailed,
        error.ZixHttp1_TlsServe_InvalidKey => Error.ZixHttp1_TlsServe_InvalidKey,
        error.ZixHttp1_TlsServe_MessageTooLong => Error.ZixHttp1_TlsServe_MessageTooLong,
        error.ZixHttp1_TlsServe_PeerClosed => Error.ZixHttp1_TlsServe_PeerClosed,
        error.ZixHttp1_TlsServe_UnexpectedMessage => Error.ZixHttp1_TlsServe_UnexpectedMessage,
        error.ZixHttp1_TlsServe_UnexpectedHandshakeMessage,
        => Error.ZixHttp1_TlsServe_UnexpectedHandshakeMessage,
        error.ZixHttp1_TlsServe_Decode => Error.ZixHttp1_TlsServe_Decode,
        error.ZixHttp1_TlsServe_RecordOverflow => Error.ZixHttp1_TlsServe_RecordOverflow,
        error.ZixHttp1_TlsServe_BadRecordMac => Error.ZixHttp1_TlsServe_BadRecordMac,
        error.ZixHttp1_TlsServe_Truncated => Error.ZixHttp1_TlsServe_Truncated,
        error.ZixHttp1_TlsServe_ClientFinishedMismatch,
        => Error.ZixHttp1_TlsServe_ClientFinishedMismatch,
        error.ZixHttp1_TlsServe_ClientCertificateMissing,
        => Error.ZixHttp1_TlsServe_ClientCertificateMissing,
        error.ZixHttp1_TlsServe_CertificateTooLarge,
        => Error.ZixHttp1_TlsServe_CertificateTooLarge,
        error.ZixHttp1_TlsServe_UnsupportedSignatureScheme,
        => Error.ZixHttp1_TlsServe_UnsupportedSignatureScheme,
        error.ZixHttp1_TlsServe_SignatureFailed => Error.ZixHttp1_TlsServe_SignatureFailed,
        error.ZixHttp1_TlsServe_UnsupportedPeerKey => Error.ZixHttp1_TlsServe_UnsupportedPeerKey,
        error.ZixHttp1_TlsServe_CertificateMalformed,
        => Error.ZixHttp1_TlsServe_CertificateMalformed,
        error.ZixHttp1_TlsServe_CertificateHasUnrecognizedObjectId,
        => Error.ZixHttp1_TlsServe_CertificateHasUnrecognizedObjectId,
        error.ZixHttp1_TlsServe_ClientHelloInvalid => Error.ZixHttp1_TlsServe_ClientHelloInvalid,
        error.ZixHttp1_TlsServe_BadRecord => Error.ZixHttp1_TlsServe_BadRecord,
        error.ZixHttp1_TlsServe_AuthenticationFailed,
        => Error.ZixHttp1_TlsServe_AuthenticationFailed,
        error.Tlz_Connection_MissingKeyShare => Error.ZixHttp1_TlsServe_MissingKeyShare,
        error.Tlz_Connection_BadKeyShare => Error.ZixHttp1_TlsServe_BadKeyShare,
        error.Tlz_Connection_UnsupportedCipher => Error.ZixHttp1_TlsServe_UnsupportedCipher,
        error.Tlz_Connection_UnsupportedGroup => Error.ZixHttp1_TlsServe_UnsupportedGroup,
        error.Tlz_Connection_NoCommonSignatureScheme,
        => Error.ZixHttp1_TlsServe_NoCommonSignatureScheme,
        error.Tlz_Connection_NoApplicationProtocol,
        => Error.ZixHttp1_TlsServe_NoApplicationProtocol,
        error.Tlz_Connection_HelloRetryRequestUnsupported,
        => Error.ZixHttp1_TlsServe_HelloRetryRequestUnsupported,
        error.Tlz_Connection_HelloRetryGroupMismatch,
        => Error.ZixHttp1_TlsServe_HelloRetryGroupMismatch,
        error.Tlz_Connection_UnsupportedTlsVersion,
        => Error.ZixHttp1_TlsServe_UnsupportedTlsVersion,
        error.Tlz_Connection_MissingExtension => Error.ZixHttp1_TlsServe_MissingExtension,
        error.Tlz_Connection_HandshakeFailure => Error.ZixHttp1_TlsServe_HandshakeFailure,
        error.Tlz_Connection_IllegalParameter => Error.ZixHttp1_TlsServe_IllegalParameter,
        error.Tlz_Connection_DecodeError => Error.ZixHttp1_TlsServe_DecodeError,
        error.Tlz_Connection_SignFailed => Error.ZixHttp1_TlsServe_SignFailed,
        error.Tlz_Connection_InvalidKey => Error.ZixHttp1_TlsServe_InvalidKey,
        error.Tlz_Connection_MessageTooLong => Error.ZixHttp1_TlsServe_MessageTooLong,
        error.Tlz_ServerConnection_PeerClosed => Error.ZixHttp1_TlsServe_PeerClosed,
        error.Tlz_ServerConnection_UnexpectedMessage,
        => Error.ZixHttp1_TlsServe_UnexpectedMessage,
        error.Tlz_ServerConnection_UnexpectedHandshakeMessage,
        => Error.ZixHttp1_TlsServe_UnexpectedHandshakeMessage,
        error.Tlz_ServerConnection_Decode => Error.ZixHttp1_TlsServe_Decode,
        error.Tlz_ServerConnection_RecordOverflow => Error.ZixHttp1_TlsServe_RecordOverflow,
        error.Tlz_ServerConnection_BadRecordMac => Error.ZixHttp1_TlsServe_BadRecordMac,
        error.Tlz_ServerConnection_Truncated => Error.ZixHttp1_TlsServe_Truncated,
        error.Tlz_ServerConnection_ClientFinishedMismatch,
        => Error.ZixHttp1_TlsServe_ClientFinishedMismatch,
        error.Tlz_ServerConnection_ClientCertificateMissing,
        => Error.ZixHttp1_TlsServe_ClientCertificateMissing,
        error.Tlz_ServerConnection_CertificateTooLarge,
        => Error.ZixHttp1_TlsServe_CertificateTooLarge,
        error.Tlz_ServerConnection_UnsupportedSignatureScheme,
        => Error.ZixHttp1_TlsServe_UnsupportedSignatureScheme,
        error.Tlz_ServerConnection_SignatureFailed => Error.ZixHttp1_TlsServe_SignatureFailed,
        error.Tlz_ServerConnection_UnsupportedPeerKey,
        => Error.ZixHttp1_TlsServe_UnsupportedPeerKey,
        error.Tlz_ServerConnection_CertificateMalformed,
        => Error.ZixHttp1_TlsServe_CertificateMalformed,
        error.Tlz_ServerConnection_CertificateHasUnrecognizedObjectId,
        => Error.ZixHttp1_TlsServe_CertificateHasUnrecognizedObjectId,
        error.Tlz_Tls12Connection_ClientHelloInvalid,
        => Error.ZixHttp1_TlsServe_ClientHelloInvalid,
        error.Tlz_Tls12Connection_UnexpectedMessage => Error.ZixHttp1_TlsServe_UnexpectedMessage,
        error.Tlz_Tls12Connection_ClientFinishedMismatch,
        => Error.ZixHttp1_TlsServe_ClientFinishedMismatch,
        error.Tlz_Tls12Connection_Truncated => Error.ZixHttp1_TlsServe_Truncated,
        error.Tlz_Tls12Connection_BadKeyShare => Error.ZixHttp1_TlsServe_BadKeyShare,
        error.Tlz_Tls12Connection_SignFailed => Error.ZixHttp1_TlsServe_SignFailed,
        error.Tlz_Tls12Connection_BadRecord => Error.ZixHttp1_TlsServe_BadRecord,
        error.Tlz_Tls12Connection_AuthenticationFailed,
        => Error.ZixHttp1_TlsServe_AuthenticationFailed,
        error.Tlz_Tls12ServerConnection_BadRecord => Error.ZixHttp1_TlsServe_BadRecord,
        error.Tlz_Tls12ServerConnection_AuthenticationFailed,
        => Error.ZixHttp1_TlsServe_AuthenticationFailed,
    };
}

/// Read exactly buf.len bytes.
fn readAll(fd: std.posix.fd_t, buf: []u8) Inner!void {
    var got: usize = 0;
    while (got < buf.len) {
        const count = reader.readOnceFD(fd, buf[got..]) catch |err| switch (err) {
            error.ZixHttp1_Reader_Closed => return Error.ZixHttp1_TlsServe_Closed,
            error.ZixHttp1_Reader_HeaderTooLarge,
            => return Error.ZixHttp1_TlsServe_HeaderTooLarge,
            error.ZixHttp1_Reader_ReadFailed => return Error.ZixHttp1_TlsServe_ReadFailed,
            error.ZixHttp1_Reader_SetBufFailed => return Error.ZixHttp1_TlsServe_SetBufFailed,
        };
        if (count == 0) return Error.ZixHttp1_TlsServe_Closed;

        got += count;
    }
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) Inner!void {
    writer.writeAllDirectFD(fd, bytes) catch |err| switch (err) {
        error.ZixHttp1_Writer_BrokenPipe => return Error.ZixHttp1_TlsServe_BrokenPipe,
        error.ZixHttp1_Writer_HeadBuild => return Error.ZixHttp1_TlsServe_HeadBuild,
    };
}

/// Best effort: the connection is ending either way, a failed write changes nothing.
fn writeBestEffort(fd: std.posix.fd_t, bytes: []const u8) void {
    writeAll(fd, bytes) catch |err| switch (err) {
        else => {},
    };
}

fn readRecord(fd: std.posix.fd_t, buf: []u8) Inner!Record {
    try readAll(fd, buf[0..RECORD_HEADER_LEN]);

    const length = std.mem.readInt(u16, buf[3..5], .big);
    if (RECORD_HEADER_LEN + length > buf.len) return Error.ZixHttp1_TlsServe_RecordTooLarge;

    try readAll(fd, buf[RECORD_HEADER_LEN .. RECORD_HEADER_LEN + length]);

    return .{
        .content_type = buf[0],
        .full = buf[0 .. RECORD_HEADER_LEN + length],
        .body = buf[RECORD_HEADER_LEN .. RECORD_HEADER_LEN + length],
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
        error.EntropyUnavailable => return Error.ZixHttp1_TlsServe_EntropyUnavailable,
        error.Canceled => return Error.ZixHttp1_TlsServe_Canceled,
    };
}

/// Whether a read error is the peer close_notify (TLS 1.3 inner alert).
fn isPeerClosed(err: anytype) bool {
    if (comptime @TypeOf(err) == tlz.Connection.Error) {
        return err == error.Tlz_ServerConnection_PeerClosed;
    }

    return false;
}

/// Whether a read error is a post-handshake handshake message (RFC 8446 5.1).
fn isUnexpectedMessage(err: anytype) bool {
    if (comptime @TypeOf(err) == tlz.Connection.Error) {
        return err == error.Tlz_ServerConnection_UnexpectedMessage;
    }

    return false;
}

/// Encrypt plaintext and send it as however many records it takes.
///
/// Note:
/// - writeAppData seals ONE record of at most tlz.MAX_PLAINTEXT bytes. A longer
///   payload would seal nothing, so the split lives here.
/// - Generic over the connection, so TLS 1.3 and TLS 1.2 share it.
///
/// Param:
/// conn - anytype (the established connection, TLS 1.3 or TLS 1.2)
/// fd - std.posix.fd_t (the connection socket)
/// plaintext - []const u8 (response bytes, empty sends nothing)
/// enc - []u8 (staging for one sealed record)
///
/// Return:
/// - void
/// - Error.ZixHttp1_TlsServe_RecordSealFailed when enc cannot hold one record
/// - the write error when the socket rejects a record
fn sendAppData(conn: anytype, fd: std.posix.fd_t, plaintext: []const u8, enc: []u8) Inner!void {
    if (plaintext.len == 0) return;

    var rest = plaintext;
    while (true) {
        const take = @min(rest.len, tlz.MAX_PLAINTEXT);
        const sealed = conn.writeAppData(rest[0..take], enc);
        if (sealed.len == 0) return Error.ZixHttp1_TlsServe_RecordSealFailed;

        try writeAll(fd, sealed);
        rest = rest[take..];

        if (rest.len == 0) return;
    }
}

/// Seal and send one status-only answer, then close_notify. Best effort.
fn answerAndClose(conn: anytype, fd: std.posix.fd_t, answer: []const u8, enc: []u8) void {
    var close_buf: [ENCRYPTED_ALERT_SIZE]u8 = undefined;

    writeBestEffort(fd, conn.writeAppData(answer, enc));
    writeBestEffort(fd, conn.closeNotify(&close_buf));
}

fn closeNotify(conn: anytype, fd: std.posix.fd_t) void {
    var close_buf: [ENCRYPTED_ALERT_SIZE]u8 = undefined;

    writeBestEffort(fd, conn.closeNotify(&close_buf));
}

/// Stream sink state over one connection type: write seals plaintext and sends
/// it straight to the socket.
fn StreamSinkFor(comptime Conn: type) type {
    return struct {
        conn: Conn,
        fd: std.posix.fd_t,
        enc: []u8,

        fn write(ctx_ptr: *anyopaque, plaintext: []const u8) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));

            sendAppData(self.conn, self.fd, plaintext, self.enc) catch |err| switch (err) {
                else => return false,
            };

            return true;
        }
    };
}

/// Drive a WebSocket over the established session: read a record, decrypt,
/// pump every complete frame. Replies leave through the TLS stream sink.
fn serveWsTls(
    conn: anytype,
    fd: std.posix.fd_t,
    on_frame: WsFrameFn,
    record_buf: []u8,
) Inner!void {
    var acc: [WS_ACC_SIZE]u8 = undefined;
    var acc_len: usize = 0;
    var plain_temp: [WS_RECORD_PLAIN_SIZE]u8 = undefined;
    var payload_buf: [WS_PAYLOAD_SIZE]u8 = undefined;
    var out_buf: [WS_OUT_SIZE]u8 = undefined;

    while (true) {
        const rec = readRecord(fd, record_buf) catch |err| {
            if (err == error.ZixHttp1_TlsServe_Closed) return;

            return err;
        };
        if (rec.content_type == CONTENT_ALERT) return;
        if (rec.content_type != CONTENT_APPLICATION_DATA) {
            return Error.ZixHttp1_TlsServe_UnexpectedRecord;
        }

        const plain = conn.readAppData(rec.full, &plain_temp) catch |err| {
            if (isPeerClosed(err)) return;

            return err;
        };
        if (acc_len + plain.len > acc.len) return Error.ZixHttp1_TlsServe_WsFrameTooLarge;

        @memcpy(acc[acc_len..][0..plain.len], plain);
        acc_len += plain.len;

        const result = ws_pump.pump(fd, acc[0..acc_len], &payload_buf, &out_buf, on_frame);

        const remaining = acc_len - result.consumed;
        if (remaining > 0) {
            std.mem.copyForwards(u8, acc[0..remaining], acc[result.consumed..acc_len]);
        }
        acc_len = remaining;

        if (result.close) return;
    }
}

/// Serve requests over an established session until the client closes.
///
/// Note:
/// - Generic over the connection so TLS 1.3 and TLS 1.2 share one loop.
/// - Ends cleanly on a hangup, a client close_notify, or Connection: close.
/// - A peer that hangs up mid-request gets a 400, because a bare close reads
///   the same as a crash.
fn serveRequests(
    fd: std.posix.fd_t,
    handler_fn: HandlerFn,
    ctx: *const tlz.Context,
    conn: anytype,
    record_buf: []u8,
    io: std.Io,
    max_request_body: usize,
) Inner!void {
    var request_plain: [REQUEST_PLAIN_SIZE]u8 = undefined;
    var response_buf: [RESPONSE_BUF_SIZE]u8 = undefined;
    var encrypt_buf: [APP_DATA_ENCRYPT_OUT_SIZE]u8 = undefined;

    // Request bytes across records: a head can span two records.
    var acc: [REQUEST_PLAIN_SIZE]u8 = undefined;
    var state: tls_feed.State = .{};

    const Stream = StreamSinkFor(@TypeOf(conn));
    var stream_state: Stream = .{
        .conn = conn,
        .fd = fd,
        .enc = &encrypt_buf,
    };
    var stream_sink: TlsStreamSink = .{
        .ctx = &stream_state,
        .writeFn = Stream.write,
        .fd = fd,
    };
    const prev_stream = writer.tl_tls_stream;
    writer.tl_tls_stream = &stream_sink;
    defer writer.tl_tls_stream = prev_stream;

    while (true) {
        const request_rec = readRecord(fd, record_buf) catch |err| {
            if (err == error.ZixHttp1_TlsServe_Closed) {
                if (state.inFlight()) {
                    writeBestEffort(fd, conn.writeAppData(BAD_REQUEST, &encrypt_buf));
                }

                return;
            }

            return err;
        };
        if (request_rec.content_type == CONTENT_ALERT) return;
        if (request_rec.content_type != CONTENT_APPLICATION_DATA) {
            return Error.ZixHttp1_TlsServe_UnexpectedRecord;
        }

        const plaintext = conn.readAppData(request_rec.full, &request_plain) catch |err| {
            if (isPeerClosed(err)) {
                if (state.inFlight()) {
                    writeBestEffort(fd, conn.writeAppData(BAD_REQUEST, &encrypt_buf));
                }

                return;
            }

            if (comptime @hasDecl(@TypeOf(conn.*), "encryptedAlert")) {
                if (isUnexpectedMessage(err)) {
                    var alert_buf: [ENCRYPTED_ALERT_SIZE]u8 = undefined;
                    writeBestEffort(fd, conn.encryptedAlert(.UNEXPECTED_MESSAGE, &alert_buf));
                }
            }

            return err;
        };

        var rest = plaintext;
        while (true) {
            if (state.drain > 0) {
                rest = state.takeDrain(rest);
                if (state.drain > 0) break;

                state.releaseParked();
            } else {
                if (rest.len == 0) break;

                if (state.headOverflowed(acc.len)) {
                    answerAndClose(conn, fd, HEAD_TOO_LARGE, &encrypt_buf);

                    return;
                }

                rest = state.fill(&acc, rest);
            }

            while (state.filled > 0) {
                const parsed = parser.parseHead(acc[0..state.filled]) catch |err| switch (err) {
                    error.ZixHttp1_Parser_IncompleteHeader => break,
                    error.ZixHttp1_Parser_InvalidRequest => {
                        return Error.ZixHttp1_TlsServe_InvalidRequest;
                    },
                    error.ZixHttp1_Parser_UnknownMethod => {
                        return Error.ZixHttp1_TlsServe_UnknownMethod;
                    },
                };
                const head = parsed.head;

                const step = state.classify(
                    parsed.body_offset,
                    @intCast(head.content_length),
                    acc.len,
                    max_request_body,
                );
                const serve = switch (step) {
                    .SERVE => |decided| decided,
                    .WAIT => break,
                    .REFUSE_BODY => {
                        answerAndClose(conn, fd, PAYLOAD_TOO_LARGE, &encrypt_buf);

                        return;
                    },
                    .REFUSE_HEAD => {
                        answerAndClose(conn, fd, HEAD_TOO_LARGE, &encrypt_buf);

                        return;
                    },
                };

                const body = acc[parsed.body_offset..][0..serve.body_len];
                if (serve.received > 0) {
                    handler_mod.tl_body_info = .{
                        .received = serve.received,
                        .complete = true,
                    };
                }

                // RFC 9110 7.4: a Host this certificate does not cover is misdirected.
                if (hostFromHead(acc[0..parsed.body_offset])) |host_raw| {
                    tlz.verifyCertIdentity(ctx.cert_der, stripPort(host_raw)) catch |err| {
                        switch (err) {
                            else => {
                                answerAndClose(conn, fd, MISDIRECTED, &encrypt_buf);

                                return;
                            },
                        }
                    };
                }

                stream_sink.wrote = false;
                const result = runHandlerToBuffer(
                    handler_fn,
                    &head,
                    body,
                    fd,
                    &response_buf,
                    io,
                    &stream_sink,
                ) catch |err| switch (err) {
                    else => {
                        // A failed upgrade leaves a handoff nothing will run.
                        _ = ws_pending.take();

                        // Nothing reached the wire yet, so it can still carry a status.
                        if (!stream_sink.wrote) {
                            answerAndClose(conn, fd, INTERNAL_ERROR, &encrypt_buf);
                        }

                        return;
                    },
                };

                state.consume(&acc, serve.request_len);

                if (ws_pending.take()) |handoff| {
                    // WebSocket.serve left its 101 in the buffer, serveTls streamed it.
                    if (!result.streamed) try sendAppData(conn, fd, result.bytes, &encrypt_buf);

                    // A TLS peer, so a broadcast from any thread is sealed with this
                    // session. Best effort: unregistered, the echo path still works.
                    TlsPeers.shared.register(fd, io, &stream_state, Stream.write) catch |err| {
                        switch (err) {
                            else => {},
                        }
                    };

                    serveWsTls(conn, fd, handoff.on_frame, record_buf) catch |err| switch (err) {
                        // The WebSocket ends here either way.
                        else => {},
                    };
                    TlsPeers.shared.unregister(fd);
                    closeNotify(conn, fd);

                    return;
                }

                if (result.streamed) {
                    // The stream owns the rest of the connection.
                    closeNotify(conn, fd);

                    return;
                }

                try sendAppData(conn, fd, result.bytes, &encrypt_buf);

                if (!head.keep_alive) {
                    closeNotify(conn, fd);

                    return;
                }
            }
        }
    }
}

/// TLS 1.2 path (RFC 5246 + 5288, ECDHE-ECDSA): two-phase handshake, then the
/// same keep-alive loop as TLS 1.3.
fn serveConnTls12(
    fd: std.posix.fd_t,
    handler_fn: HandlerFn,
    ctx: *const tlz.Context,
    key_pair: EcdsaP256.KeyPair,
    client_hello: []const u8,
    ephemeral_secret: [32]u8,
    server_random: [32]u8,
    io: std.Io,
    max_request_body: usize,
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

    var record_buf: [tlz.MAX_RECORD_WIRE]u8 = undefined;

    // ClientKeyExchange, copied out before record_buf is reused.
    const key_exchange_rec = try readRecord(fd, &record_buf);
    if (key_exchange_rec.content_type != CONTENT_HANDSHAKE) {
        return Error.ZixHttp1_TlsServe_UnexpectedRecord;
    }

    var key_exchange_buf: [CLIENT_KEY_EXCHANGE_SIZE]u8 = undefined;
    if (key_exchange_rec.body.len > key_exchange_buf.len) {
        return Error.ZixHttp1_TlsServe_RecordTooLarge;
    }

    @memcpy(key_exchange_buf[0..key_exchange_rec.body.len], key_exchange_rec.body);
    const client_key_exchange = key_exchange_buf[0..key_exchange_rec.body.len];

    // Skip ChangeCipherSpec, then the encrypted client Finished.
    const finished_rec = while (true) {
        const rec = try readRecord(fd, &record_buf);
        if (rec.content_type == CONTENT_CHANGE_CIPHER_SPEC) continue;
        if (rec.content_type == CONTENT_ALERT) return Error.ZixHttp1_TlsServe_PeerAlert;
        if (rec.content_type != CONTENT_HANDSHAKE) {
            return Error.ZixHttp1_TlsServe_UnexpectedRecord;
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

    try serveRequests(fd, handler_fn, ctx, &conn, &record_buf, io, max_request_body);
}

/// The ECDSA key a TLS 1.2 handshake signs with. Ed25519 and RSA are 1.3 only.
fn tls12Key(ctx: *const tlz.Context) Inner!EcdsaP256.KeyPair {
    return switch (ctx.signing_key) {
        .ecdsa_p256 => |key_pair| key_pair,
        else => Error.ZixHttp1_TlsServe_Tls12RequiresEcdsa,
    };
}

/// Drive one connection: handshake, then the keep-alive request loop.
fn serveConnTls(
    fd: std.posix.fd_t,
    handler_fn: HandlerFn,
    ctx: *const tlz.Context,
    io: std.Io,
    max_request_body: usize,
) Inner!void {
    var record_buf: [tlz.MAX_RECORD_WIRE]u8 = undefined;

    const hello_rec = try readRecord(fd, &record_buf);
    if (hello_rec.content_type != CONTENT_HANDSHAKE) {
        return Error.ZixHttp1_TlsServe_UnexpectedRecord;
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
            handler_fn,
            ctx,
            try tls12Key(ctx),
            hello_rec.body,
            ephemeral_secret,
            server_random,
            io,
            max_request_body,
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
                return Error.ZixHttp1_TlsServe_UnexpectedRecord;
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
                handler_fn,
                ctx,
                try tls12Key(ctx),
                hello_rec.body,
                ephemeral_secret,
                server_random,
                io,
                max_request_body,
            );
        };
    try writeAll(fd, result.to_send);
    var conn = result.connection;

    // Client ChangeCipherSpec (skipped), then Finished. An alert means the peer aborted.
    while (true) {
        const rec = try readRecord(fd, &record_buf);
        if (rec.content_type == CONTENT_CHANGE_CIPHER_SPEC) continue;
        if (rec.content_type == CONTENT_ALERT) return Error.ZixHttp1_TlsServe_PeerAlert;
        if (rec.content_type != CONTENT_APPLICATION_DATA) {
            return Error.ZixHttp1_TlsServe_UnexpectedRecord;
        }

        try conn.verifyClientFinished(rec.full);
        break;
    }

    try serveRequests(fd, handler_fn, ctx, &conn, &record_buf, io, max_request_body);
}

/// One connection task: set the per-thread knobs, serve, close.
fn connWorker(conn_ctx: ConnCtx) void {
    head_mod.setDateHeader(conn_ctx.send_date_header);
    static.setStatic(conn_ctx.public_dir, conn_ctx.io);
    header.setMaxResponseHeaders(conn_ctx.max_response_headers);
    handler_mod.setAccessLogger(conn_ctx.logger);

    defer conn_ctx.stream.close(conn_ctx.io);

    // A TLS socket from now on: no write to fd may go out as plaintext. Cleared
    // before the close above, so a reused fd starts clean.
    const fd = conn_ctx.stream.socket.handle;
    TlsPeers.shared.mark(fd);
    defer TlsPeers.shared.unregister(fd);

    serveConnTls(
        fd,
        conn_ctx.handler,
        conn_ctx.ctx,
        conn_ctx.io,
        conn_ctx.max_request_body,
    ) catch |err| {
        // DEBUG, not WARN: a scanner on a public port would otherwise flood the log.
        const logger = conn_ctx.logger orelse return;
        const name = @errorName(innerError(err));

        logger.system(.DEBUG, "http1", "tls connection ended: {s}", .{name});
    };
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http1 TLS serve error
pub const Error = error {
    ZixHttp1_TlsServe_ResolveFailed,
    ZixHttp1_TlsServe_ListenFailed,
    ZixHttp1_TlsServe_AcceptFailed,
    ZixHttp1_TlsServe_EntropyUnavailable,
    ZixHttp1_TlsServe_Canceled,
    ZixHttp1_TlsServe_Closed,
    ZixHttp1_TlsServe_HeaderTooLarge,
    ZixHttp1_TlsServe_ReadFailed,
    ZixHttp1_TlsServe_SetBufFailed,
    ZixHttp1_TlsServe_BrokenPipe,
    ZixHttp1_TlsServe_HeadBuild,
    ZixHttp1_TlsServe_RecordTooLarge,
    ZixHttp1_TlsServe_UnexpectedRecord,
    ZixHttp1_TlsServe_PeerAlert,
    ZixHttp1_TlsServe_Tls12RequiresEcdsa,
    ZixHttp1_TlsServe_RecordSealFailed,
    ZixHttp1_TlsServe_InvalidRequest,
    ZixHttp1_TlsServe_UnknownMethod,
    ZixHttp1_TlsServe_ResponseTooLarge,
    ZixHttp1_TlsServe_StreamingNotSupported,
    ZixHttp1_TlsServe_WsFrameTooLarge,
    ZixHttp1_TlsServe_MissingKeyShare,
    ZixHttp1_TlsServe_BadKeyShare,
    ZixHttp1_TlsServe_UnsupportedCipher,
    ZixHttp1_TlsServe_UnsupportedGroup,
    ZixHttp1_TlsServe_NoCommonSignatureScheme,
    ZixHttp1_TlsServe_NoApplicationProtocol,
    ZixHttp1_TlsServe_HelloRetryRequestUnsupported,
    ZixHttp1_TlsServe_HelloRetryGroupMismatch,
    ZixHttp1_TlsServe_UnsupportedTlsVersion,
    ZixHttp1_TlsServe_MissingExtension,
    ZixHttp1_TlsServe_HandshakeFailure,
    ZixHttp1_TlsServe_IllegalParameter,
    ZixHttp1_TlsServe_DecodeError,
    ZixHttp1_TlsServe_SignFailed,
    ZixHttp1_TlsServe_InvalidKey,
    ZixHttp1_TlsServe_MessageTooLong,
    ZixHttp1_TlsServe_PeerClosed,
    ZixHttp1_TlsServe_UnexpectedMessage,
    ZixHttp1_TlsServe_UnexpectedHandshakeMessage,
    ZixHttp1_TlsServe_Decode,
    ZixHttp1_TlsServe_RecordOverflow,
    ZixHttp1_TlsServe_BadRecordMac,
    ZixHttp1_TlsServe_Truncated,
    ZixHttp1_TlsServe_ClientFinishedMismatch,
    ZixHttp1_TlsServe_ClientCertificateMissing,
    ZixHttp1_TlsServe_CertificateTooLarge,
    ZixHttp1_TlsServe_UnsupportedSignatureScheme,
    ZixHttp1_TlsServe_SignatureFailed,
    ZixHttp1_TlsServe_UnsupportedPeerKey,
    ZixHttp1_TlsServe_CertificateMalformed,
    ZixHttp1_TlsServe_CertificateHasUnrecognizedObjectId,
    ZixHttp1_TlsServe_ClientHelloInvalid,
    ZixHttp1_TlsServe_BadRecord,
    ZixHttp1_TlsServe_AuthenticationFailed,
};

/// Listen and serve https/1.1, one task per connection.
///
/// Note:
/// - The cert, key, and policy are already loaded and checked in ctx, so the
///   accept loop does no per-connection PEM work.
/// - A failed accept drops that connection and keeps accepting.
///
/// Param:
/// config - Config (listen address, knobs)
/// handler_fn - HandlerFn
/// ctx - *const tlz.Context (borrowed, must outlive the server)
///
/// Return:
/// - void (never returns on success)
/// - Error.ZixHttp1_TlsServe_ResolveFailed or ListenFailed when the bind fails
pub fn runTls(config: Config, handler_fn: HandlerFn, ctx: *const tlz.Context) Error!void {
    const io = config.io;
    const address = std.Io.net.IpAddress.resolve(io, config.ip, config.port) catch |err| {
        switch (err) {
            else => return Error.ZixHttp1_TlsServe_ResolveFailed,
        }
    };
    var server = address.listen(io, .{
        .mode = .stream,
        .reuse_address = true,
        .kernel_backlog = config.kernel_backlog,
    }) catch |err| switch (err) {
        else => return Error.ZixHttp1_TlsServe_ListenFailed,
    };
    defer server.deinit(io);

    log.logSystem(config, .INFO, "listening on {s}:{d} (https/1.1)", .{
        config.ip,
        config.port,
    });

    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            else => continue,
        };
        const conn_ctx: ConnCtx = .{
            .stream = stream,
            .handler = handler_fn,
            .ctx = ctx,
            .io = io,
            .public_dir = config.public_dir,
            .max_response_headers = config.max_response_headers.value(),
            .max_request_body = config.max_request_body,
            .send_date_header = config.send_date_header,
            .logger = config.logger,
        };

        _ = io.async(connWorker, .{conn_ctx});
    }
}

/// Run the handler with a response sink installed and return what is staged.
///
/// Note:
/// - spill keeps out a staging buffer, not a ceiling: a response past out
///   leaves through the TLS stream sink while it renders. The returned bytes are
///   only the tail still staged. null keeps out as a hard limit.
/// - A handler that calls beginStream detaches the sink. With a TLS stream
///   armed it streamed already, reported as streamed.
///
/// Param:
/// handler_fn - HandlerFn (the route handler)
/// head - *const ParsedHead (the parsed request head)
/// body - []const u8 (the request body, empty when none)
/// fd - std.posix.fd_t (the connection, req.fd for the handler)
/// out - []u8 (response staging)
/// io - std.Io (handed to the handler)
/// spill - ?*TlsStreamSink (where a response past out goes, null caps at out)
///
/// Return:
/// - HandlerResult (the staged tail, or streamed)
/// - Error.ZixHttp1_TlsServe_ResponseTooLarge when the response outgrew out
/// - Error.ZixHttp1_TlsServe_StreamingNotSupported when no TLS stream is armed
pub fn runHandlerToBuffer(
    handler_fn: HandlerFn,
    head: *const ParsedHead,
    body: []const u8,
    fd: std.posix.fd_t,
    out: []u8,
    io: std.Io,
    spill: ?*TlsStreamSink,
) Error!HandlerResult {
    var sink: RespSink = .{
        .fd = fd,
        .buf = out,
        .spill = spill,
    };
    const prev = writer.tl_resp_sink;
    writer.tl_resp_sink = &sink;
    defer writer.tl_resp_sink = prev;

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    handler_mod.invokeHandler(handler_fn, head, body, fd, io, arena.allocator());

    if (writer.tl_resp_sink != &sink) {
        if (writer.tl_tls_stream != null) {
            return .{
                .bytes = &.{},
                .streamed = true,
            };
        }

        return Error.ZixHttp1_TlsServe_StreamingNotSupported;
    }

    if (sink.failed) return Error.ZixHttp1_TlsServe_ResponseTooLarge;

    return .{ .bytes = out[sink.off..sink.len] };
}

/// The Host header value (RFC 9112 3.2) from a request head.
///
/// Return:
/// - []const u8 (the trimmed value)
/// - null when there is no Host header
pub fn hostFromHead(head: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();

    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (std.ascii.eqlIgnoreCase(name, "host")) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }

    return null;
}

/// Strip the port from a Host value: [::1]:443 to ::1, localhost:443 to
/// localhost. A bare host or a bare IPv6 literal is left as is.
pub fn stripPort(host: []const u8) []const u8 {
    if (host.len == 0) return host;

    if (host[0] == '[') {
        if (std.mem.indexOfScalar(u8, host, ']')) |close| return host[1..close];

        return host;
    }

    // One colon means host:port. A bare IPv6 literal has several.
    if (std.mem.indexOfScalar(u8, host, ':')) |first| {
        if (std.mem.lastIndexOfScalar(u8, host, ':').? == first) return host[0..first];
    }

    return host;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../utils/socket/pair.zig");

const CERT_PATH = "examples/certs/ecdsa_p256_cert.pem";
const KEY_PATH = "examples/certs/ecdsa_p256_key.pem";
const ED25519_CERT_PATH = "examples/certs/ed25519_cert.pem";
const ED25519_KEY_PATH = "examples/certs/ed25519_key.pem";

const MULTI_RECORD_BODY_LEN: usize = 40000;

const TestServer = struct {
    fn run(
        fd: std.posix.fd_t,
        handler_fn: HandlerFn,
        ctx: *const tlz.Context,
        result: *?Error,
    ) void {
        serveConnTls(fd, handler_fn, ctx, std.testing.io, 0) catch |err| {
            result.* = innerError(err);
        };

        _ = std.posix.system.close(fd);
    }
};

/// One client end over a socketpair with the server on its own thread.
const TestClient = struct {
    fd: std.posix.fd_t,
    thread: std.Thread,
    finished: tlz.Client.FinishResult,
    server_error: ?Error = null,

    fn deinit(self: *TestClient) void {
        _ = std.posix.system.close(self.fd);
        self.thread.join();
    }

    fn send(self: *TestClient, plaintext: []const u8) !void {
        var enc: [4096]u8 = undefined;

        try writeAll(self.fd, self.finished.connection.writeAppData(plaintext, &enc));
    }

    fn recv(self: *TestClient, rec_buf: []u8, plain: []u8) ![]const u8 {
        const rec = try readRecord(self.fd, rec_buf);

        return self.finished.connection.readAppData(rec.full, plain);
    }
};

fn testContext(cert_path: []const u8, key_path: []const u8) !tlz.Context {
    return tlz.Context.init(std.testing.allocator, std.testing.io, .{
        .cert_path = cert_path,
        .key_path = key_path,
    });
}

/// Start the server thread and run the client handshake against it.
fn connectClient(client: *TestClient, handler_fn: HandlerFn, ctx: *const tlz.Context) !void {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);

    client.* = .{
        .fd = fds[0],
        .thread = undefined,
        .finished = undefined,
    };
    client.thread = try std.Thread.spawn(
        .{},
        TestServer.run,
        .{ fds[1], handler_fn, ctx, &client.server_error },
    );

    var hello_buf: [512]u8 = undefined;
    const started = try tlz.Client.start(.{
        .client_random = @splat(0x11),
        .ephemeral_secret = @splat(0x42),
    }, &hello_buf);
    var state = started.state;

    var hello_rec: [600]u8 = undefined;
    hello_rec[0] = CONTENT_HANDSHAKE;
    std.mem.writeInt(u16, hello_rec[1..3], 0x0303, .big);
    std.mem.writeInt(u16, hello_rec[3..5], @intCast(started.client_hello.len), .big);
    @memcpy(hello_rec[RECORD_HEADER_LEN..][0..started.client_hello.len], started.client_hello);
    try writeAll(client.fd, hello_rec[0 .. RECORD_HEADER_LEN + started.client_hello.len]);

    var flight_buf: [4096]u8 = undefined;
    var flight_len: usize = 0;
    for (0..3) |_| {
        const rec = try readRecord(client.fd, flight_buf[flight_len..]);
        flight_len += rec.full.len;
    }

    var fin_buf: [256]u8 = undefined;
    client.finished = try tlz.Client.finish(&state, flight_buf[0..flight_len], &fin_buf);
    try writeAll(client.fd, client.finished.client_finished);
}

fn okHandler(
    _: *@import("Request.zig"),
    res: *@import("Response.zig"),
    _: *@import("Context.zig"),
) anyerror!void {
    try res.sendRaw("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
}

fn multiRecordHandler(
    _: *@import("Request.zig"),
    res: *@import("Response.zig"),
    _: *@import("Context.zig"),
) anyerror!void {
    var body: [MULTI_RECORD_BODY_LEN]u8 = undefined;
    for (&body, 0..) |*byte, index| byte.* = @intCast('!' + index % 90);

    try res.send(&body);
}

fn sseHandler(
    req: *@import("Request.zig"),
    _: *@import("Response.zig"),
    _: *@import("Context.zig"),
) anyerror!void {
    writer.beginStream();
    try writer.writeAllFD(req.fd, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n");
    try writer.writeAllFD(req.fd, "data: hello\n\n");
}

fn lateStreamHandler(
    req: *@import("Request.zig"),
    _: *@import("Response.zig"),
    _: *@import("Context.zig"),
) anyerror!void {
    try writer.writeAllFD(req.fd, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n");
    writer.beginStream();
    try writer.writeAllFD(req.fd, "data: hello\n\n");
}

/// A body of the size named by the n query parameter, non-repeating.
fn sizedHandler(
    req: *@import("Request.zig"),
    res: *@import("Response.zig"),
    _: *@import("Context.zig"),
) anyerror!void {
    const raw = req.queryParam("n") orelse "16";
    const want = try std.fmt.parseInt(usize, raw, 10);

    var body: [8 * 1024]u8 = undefined;
    const len = @min(want, body.len);
    for (body[0..len], 0..) |*byte, index| byte.* = @intCast('!' + index % 90);

    try res.send(body[0..len]);
}

/// Capture stream: a streaming handler's writes land here. refuse stands in
/// for a connection that is already gone.
const CaptureStream = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,
    refuse: bool = false,

    fn write(ctx_ptr: *anyopaque, plaintext: []const u8) bool {
        const self: *CaptureStream = @ptrCast(@alignCast(ctx_ptr));
        if (self.refuse or self.len + plaintext.len > self.buf.len) return false;

        @memcpy(self.buf[self.len..][0..plaintext.len], plaintext);
        self.len += plaintext.len;

        return true;
    }
};

/// Render a sized response and return what the peer would see: the spilled
/// bytes, then the staged tail.
fn renderSized(
    want: usize,
    out: []u8,
    capture: *CaptureStream,
    spill: ?*TlsStreamSink,
    seen: []u8,
) ![]const u8 {
    var req_buf: [128]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "GET /sized?n={d} HTTP/1.1\r\nHost: x\r\n\r\n", .{
        want,
    });
    const parsed = try parser.parseHead(req);

    head_mod.setDateHeader(false);
    defer head_mod.setDateHeader(true);

    const result = try runHandlerToBuffer(
        sizedHandler,
        &parsed.head,
        "",
        -1,
        out,
        std.testing.io,
        spill,
    );

    @memcpy(seen[0..capture.len], capture.buf[0..capture.len]);
    @memcpy(seen[capture.len..][0..result.bytes.len], result.bytes);

    return seen[0 .. capture.len + result.bytes.len];
}

test "zix http1: tls_serve, stripPort strips host:port" {
    try std.testing.expectEqualStrings("localhost", stripPort("localhost:9060"));
    try std.testing.expectEqualStrings("127.0.0.1", stripPort("127.0.0.1:443"));
}

test "zix http1: tls_serve, stripPort keeps a bare host" {
    try std.testing.expectEqualStrings("localhost", stripPort("localhost"));
    try std.testing.expectEqualStrings("", stripPort(""));
}

test "zix http1: tls_serve, stripPort unwraps bracketed IPv6" {
    try std.testing.expectEqualStrings("::1", stripPort("[::1]:443"));
    try std.testing.expectEqualStrings("[::1", stripPort("[::1"));
}

test "zix http1: tls_serve, stripPort keeps a bare IPv6 literal" {
    try std.testing.expectEqualStrings("::1", stripPort("::1"));
}

test "zix http1: tls_serve, hostFromHead extracts the Host header" {
    const head =
        "GET / HTTP/1.1\r\nUser-Agent: x\r\nHost: localhost:9060\r\nAccept: */*\r\n\r\n";

    try std.testing.expectEqualStrings("localhost:9060", hostFromHead(head).?);
}

test "zix http1: tls_serve, hostFromHead without Host is null" {
    try std.testing.expect(hostFromHead("GET / HTTP/1.1\r\nAccept: */*\r\n\r\n") == null);
}

test "zix http1: tls_serve, readRecord past the buffer is RecordTooLarge" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try writeAll(fds[1], "\x17\x03\x03\x01\x00");

    var buf: [64]u8 = undefined;

    try std.testing.expectError(
        Error.ZixHttp1_TlsServe_RecordTooLarge,
        readRecord(fds[0], &buf),
    );
}

test "zix http1: tls_serve, readRecord on a closed peer is Closed" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    _ = std.posix.system.close(fds[1]);

    var buf: [64]u8 = undefined;

    try std.testing.expectError(Error.ZixHttp1_TlsServe_Closed, readRecord(fds[0], &buf));
}

test "zix http1: tls_serve, keep-alive serves many requests on one session" {
    var ctx = try testContext(CERT_PATH, KEY_PATH);
    defer ctx.deinit();

    var client: TestClient = undefined;
    try connectClient(&client, okHandler, &ctx);
    defer client.deinit();

    const requests = [_][]const u8{
        "GET /a HTTP/1.1\r\nHost: localhost\r\n\r\n",
        "GET /b HTTP/1.1\r\nHost: localhost\r\n\r\n",
        "GET /c HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
    };
    for (requests) |request| {
        try client.send(request);

        var rec_buf: [1024]u8 = undefined;
        var plain: [1024]u8 = undefined;
        const response = try client.recv(&rec_buf, &plain);

        try std.testing.expect(std.mem.indexOf(u8, response, "200 OK") != null);
    }
}

test "zix http1: tls_serve, Connection: close ends with close_notify then EOF" {
    var ctx = try testContext(CERT_PATH, KEY_PATH);
    defer ctx.deinit();

    var client: TestClient = undefined;
    try connectClient(&client, okHandler, &ctx);
    defer client.deinit();

    try client.send("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

    var rec_buf: [1024]u8 = undefined;
    var plain: [1024]u8 = undefined;
    _ = try client.recv(&rec_buf, &plain);

    const tail = try readRecord(client.fd, &rec_buf);
    try std.testing.expectEqual(CONTENT_APPLICATION_DATA, tail.content_type);
    try std.testing.expectError(Error.ZixHttp1_TlsServe_Closed, readRecord(client.fd, &rec_buf));
}

test "zix http1: tls_serve, a response past one record arrives whole" {
    var ctx = try testContext(CERT_PATH, KEY_PATH);
    defer ctx.deinit();

    var client: TestClient = undefined;
    try connectClient(&client, multiRecordHandler, &ctx);
    defer client.deinit();

    try client.send("GET /big HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

    const response = try std.testing.allocator.alloc(u8, MULTI_RECORD_BODY_LEN + 4096);
    defer std.testing.allocator.free(response);

    var rec_buf: [tlz.MAX_RECORD_WIRE]u8 = undefined;
    var plain: [tlz.MAX_PLAINTEXT + 1]u8 = undefined;
    var filled: usize = 0;
    var records: usize = 0;
    var body_start: ?usize = null;
    while (true) {
        const opened = try client.recv(&rec_buf, &plain);
        @memcpy(response[filled..][0..opened.len], opened);
        filled += opened.len;
        records += 1;

        if (body_start == null) {
            const mark = std.mem.indexOf(u8, response[0..filled], "\r\n\r\n");
            if (mark) |at| body_start = at + 4;
        }
        if (body_start) |start| {
            if (filled - start >= MULTI_RECORD_BODY_LEN) break;
        }
    }

    const body = response[body_start.?..filled];
    try std.testing.expectEqual(MULTI_RECORD_BODY_LEN, body.len);
    try std.testing.expect(records >= 3);
    for (body, 0..) |byte, index| {
        try std.testing.expectEqual(@as(u8, @intCast('!' + index % 90)), byte);
    }
}

test "zix http1: tls_serve, a Host outside the certificate gets 421" {
    var ctx = try testContext(CERT_PATH, KEY_PATH);
    defer ctx.deinit();

    var client: TestClient = undefined;
    try connectClient(&client, okHandler, &ctx);
    defer client.deinit();

    try client.send("GET / HTTP/1.1\r\nHost: other.example\r\n\r\n");

    var rec_buf: [1024]u8 = undefined;
    var plain: [1024]u8 = undefined;
    const response = try client.recv(&rec_buf, &plain);

    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 421"));
}

test "zix http1: tls_serve, a hangup mid-request gets 400" {
    var ctx = try testContext(CERT_PATH, KEY_PATH);
    defer ctx.deinit();

    var client: TestClient = undefined;
    try connectClient(&client, okHandler, &ctx);
    defer client.deinit();

    try client.send("GET / HTTP/1.1\r\nHost: local");
    _ = std.os.linux.shutdown(client.fd, std.os.linux.SHUT.WR);

    var rec_buf: [1024]u8 = undefined;
    var plain: [1024]u8 = undefined;
    const response = try client.recv(&rec_buf, &plain);

    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 400"));
}

test "zix http1: tls_serve, a non-handshake first record is UnexpectedRecord" {
    var ctx = try testContext(CERT_PATH, KEY_PATH);
    defer ctx.deinit();

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try writeAll(fds[1], "\x17\x03\x03\x00\x01x");

    const result = serveConnTls(fds[0], okHandler, &ctx, std.testing.io, 0);

    try std.testing.expectError(error.ZixHttp1_TlsServe_UnexpectedRecord, result);
}

test "zix http1: tls_serve, TLS 1.2 with an Ed25519 key is Tls12RequiresEcdsa" {
    var ctx = try testContext(ED25519_CERT_PATH, ED25519_KEY_PATH);
    defer ctx.deinit();

    try std.testing.expectError(error.ZixHttp1_TlsServe_Tls12RequiresEcdsa, tls12Key(&ctx));
}

test "zix http1: tls_serve, innerError keeps the condition name" {
    try std.testing.expectEqual(
        Error.ZixHttp1_TlsServe_PeerClosed,
        innerError(error.Tlz_ServerConnection_PeerClosed),
    );
    try std.testing.expectEqual(
        Error.ZixHttp1_TlsServe_BadRecord,
        innerError(error.Tlz_Tls12ServerConnection_BadRecord),
    );
}

test "zix http1: tls_serve, runHandlerToBuffer streams when the TLS stream is armed" {
    var capture: CaptureStream = .{};
    var stream_sink: TlsStreamSink = .{
        .ctx = &capture,
        .writeFn = CaptureStream.write,
        .fd = -1,
    };
    writer.tl_tls_stream = &stream_sink;
    defer writer.tl_tls_stream = null;

    const req = "GET /events HTTP/1.1\r\nHost: x\r\n\r\n";
    const parsed = try parser.parseHead(req);
    var out: [4096]u8 = undefined;

    const result = try runHandlerToBuffer(
        sseHandler,
        &parsed.head,
        "",
        -1,
        &out,
        std.testing.io,
        &stream_sink,
    );
    const wire = capture.buf[0..capture.len];

    try std.testing.expect(result.streamed);
    try std.testing.expect(std.mem.indexOf(u8, wire, "text/event-stream") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "data: hello") != null);
}

test "zix http1: tls_serve, runHandlerToBuffer without a TLS stream is StreamingNotSupported" {
    const req = "GET /events HTTP/1.1\r\nHost: x\r\n\r\n";
    const parsed = try parser.parseHead(req);
    var out: [4096]u8 = undefined;

    const result = runHandlerToBuffer(
        sseHandler,
        &parsed.head,
        "",
        -1,
        &out,
        std.testing.io,
        null,
    );

    try std.testing.expectError(Error.ZixHttp1_TlsServe_StreamingNotSupported, result);
}

test "zix http1: tls_serve, runHandlerToBuffer spills past its staging buffer" {
    var capture: CaptureStream = .{};
    var stream_sink: TlsStreamSink = .{
        .ctx = &capture,
        .writeFn = CaptureStream.write,
        .fd = -1,
    };

    var out: [256]u8 = undefined;
    var seen: [1024]u8 = undefined;
    const response = try renderSized(600, &out, &capture, &stream_sink, &seen);

    const mark = std.mem.indexOf(u8, response, "\r\n\r\n").?;
    const body = response[mark + 4 ..];

    try std.testing.expect(stream_sink.wrote);
    try std.testing.expect(std.mem.indexOf(u8, response, "Content-Length: 600\r\n") != null);
    try std.testing.expectEqual(@as(usize, 600), body.len);
    for (body, 0..) |byte, index| {
        try std.testing.expectEqual(@as(u8, @intCast('!' + index % 90)), byte);
    }
}

test "zix http1: tls_serve, runHandlerToBuffer leaves a fitting response staged" {
    var capture: CaptureStream = .{};
    var stream_sink: TlsStreamSink = .{
        .ctx = &capture,
        .writeFn = CaptureStream.write,
        .fd = -1,
    };

    var out: [4096]u8 = undefined;
    var seen: [4096]u8 = undefined;
    const response = try renderSized(64, &out, &capture, &stream_sink, &seen);

    try std.testing.expect(!stream_sink.wrote);
    try std.testing.expectEqual(@as(usize, 0), capture.len);
    try std.testing.expect(std.mem.indexOf(u8, response, "Content-Length: 64\r\n") != null);
}

test "zix http1: tls_serve, runHandlerToBuffer without a spill caps at its buffer" {
    var capture: CaptureStream = .{};
    var out: [256]u8 = undefined;
    var seen: [1024]u8 = undefined;

    try std.testing.expectError(
        Error.ZixHttp1_TlsServe_ResponseTooLarge,
        renderSized(600, &out, &capture, null, &seen),
    );
}

test "zix http1: tls_serve, beginStream carries the bytes staged before it" {
    var capture: CaptureStream = .{};
    var stream_sink: TlsStreamSink = .{
        .ctx = &capture,
        .writeFn = CaptureStream.write,
        .fd = -1,
    };
    writer.tl_tls_stream = &stream_sink;
    defer writer.tl_tls_stream = null;

    const req = "GET /events HTTP/1.1\r\nHost: x\r\n\r\n";
    const parsed = try parser.parseHead(req);
    var out: [4096]u8 = undefined;

    const result = try runHandlerToBuffer(
        lateStreamHandler,
        &parsed.head,
        "",
        -1,
        &out,
        std.testing.io,
        &stream_sink,
    );
    const wire = capture.buf[0..capture.len];

    try std.testing.expect(result.streamed);
    try std.testing.expect(std.mem.startsWith(u8, wire, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, wire, "data: hello\n\n"));
}

test "zix http1: tls_serve, runHandlerToBuffer reports a spill that cannot reach the peer" {
    var capture: CaptureStream = .{ .refuse = true };
    var stream_sink: TlsStreamSink = .{
        .ctx = &capture,
        .writeFn = CaptureStream.write,
        .fd = -1,
    };

    var out: [256]u8 = undefined;
    var seen: [1024]u8 = undefined;

    try std.testing.expectError(
        Error.ZixHttp1_TlsServe_ResponseTooLarge,
        renderSized(600, &out, &capture, &stream_sink, &seen),
    );
    try std.testing.expect(stream_sink.failed);
    try std.testing.expect(!stream_sink.wrote);
}

