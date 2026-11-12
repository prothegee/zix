//! TLZ tls12 client ClientConnection
//!
//! ### file: src/tlz/src/tls12/client/ClientConnection.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The client side of an established TLS 1.2 connection: the key material, the
//! per-direction sequence numbers, the server Finished check, and record I/O.
//!
//! ### note:
//!
//! The client writes under the client key and reads under the server key. Both
//! sequence numbers start at 1, after the Finished of each side at sequence 0.
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
const record = @import("../record.zig");
const prf = @import("../prf.zig");
const alert = @import("../../alert.zig");
const KeyMaterial = @import("../prf/KeyMaterial.zig");
const HandshakeType = @import("../../handshake/handshake_type.zig").HandshakeType;
const ContentType = @import("../../record/content_type.zig").ContentType;

// --------------------------------------------------------- //
// Fields:

km: KeyMaterial,
client_seq: u64 = 1,
server_seq: u64 = 1,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// A Finished message: type, u24 length, verify_data.
const FINISHED_MESSAGE_LENGTH = 4 + prf.VERIFY_DATA_LENGTH;

fn recordError(err: record.Error) Error {
    @branchHint(.cold);

    return switch (err) {
        error.Tlz_Tls12Record_BadRecord => Error.Tlz_Tls12ClientConnection_BadRecord,
        error.Tlz_Tls12Record_AuthenticationFailed => {
            return Error.Tlz_Tls12ClientConnection_AuthenticationFailed;
        },
    };
}

// --------------------------------------------------------- //
// Public:

pub const Error = error{
    Tlz_Tls12ClientConnection_BadRecord,
    Tlz_Tls12ClientConnection_AuthenticationFailed,
    Tlz_Tls12ClientConnection_UnexpectedMessage,
    Tlz_Tls12ClientConnection_ServerFinishedMismatch,
};

/// Encrypt application data into one record under the client write key.
///
/// Param:
/// plaintext - []const u8 (at most `record.MAX_PLAINTEXT` bytes)
/// out - []u8 (at least plaintext.len + `record.RECORD_OVERHEAD` bytes)
///
/// Return:
/// - []const u8 (the wire record, a view into `out`, empty when it does not fit)
pub fn writeAppData(self: *Self, plaintext: []const u8, out: []u8) []const u8 {
    const rec = record.protect(
        out,
        plaintext,
        @intFromEnum(ContentType.APPLICATION_DATA),
        self.km.client_write_key,
        self.km.client_write_iv,
        self.client_seq,
    );
    self.client_seq += 1;

    return rec;
}

/// Decrypt one server application record.
///
/// Param:
/// rec - []const u8 (one whole wire record)
/// out - []u8 (holds at least the ciphertext length)
///
/// Return:
/// - []const u8 (the plaintext, a view into `out`)
/// - Error.Tlz_Tls12ClientConnection_BadRecord on a short record
/// - Error.Tlz_Tls12ClientConnection_AuthenticationFailed on a wrong tag or sequence
pub fn readAppData(self: *Self, rec: []const u8, out: []u8) Error![]const u8 {
    const plain = record.deprotect(
        out,
        rec,
        self.km.server_write_key,
        self.km.server_write_iv,
        self.server_seq,
    ) catch |err| return recordError(err);
    self.server_seq += 1;

    return plain;
}

/// Emit an encrypted close_notify alert under the client write key (RFC 5246 7.2.1).
///
/// Param:
/// out - []u8 (at least 2 + `record.RECORD_OVERHEAD` bytes)
///
/// Return:
/// - []const u8 (the wire record, a view into `out`)
pub fn closeNotify(self: *Self, out: []u8) []const u8 {
    const body = [_]u8{
        alert.LEVEL_WARNING,
        0,
    };
    const rec = record.protect(
        out,
        &body,
        @intFromEnum(ContentType.ALERT),
        self.km.client_write_key,
        self.km.client_write_iv,
        self.client_seq,
    );
    self.client_seq += 1;

    return rec;
}

/// Check the server Finished record, sealed under the server key at sequence 0.
///
/// Param:
/// finished_record - []const u8 (the encrypted server Finished record)
/// expected - [prf.VERIFY_DATA_LENGTH]u8 (from `FinishResult.expected_server_finished`)
///
/// Return:
/// - void when the verify_data matches
/// - Error.Tlz_Tls12ClientConnection_UnexpectedMessage when it is not a Finished
/// - Error.Tlz_Tls12ClientConnection_ServerFinishedMismatch on a wrong verify_data
/// - Error.Tlz_Tls12ClientConnection_AuthenticationFailed when the record fails
pub fn verifyServerFinished(
    self: *const Self,
    finished_record: []const u8,
    expected: [prf.VERIFY_DATA_LENGTH]u8,
) Error!void {
    var plain: [64]u8 = undefined;
    const msg = record.deprotect(
        &plain,
        finished_record,
        self.km.server_write_key,
        self.km.server_write_iv,
        0,
    ) catch |err| return recordError(err);

    if (msg.len < FINISHED_MESSAGE_LENGTH) {
        return Error.Tlz_Tls12ClientConnection_UnexpectedMessage;
    }

    if (msg[0] != @intFromEnum(HandshakeType.FINISHED)) {
        return Error.Tlz_Tls12ClientConnection_UnexpectedMessage;
    }

    if (!std.mem.eql(u8, msg[4..FINISHED_MESSAGE_LENGTH], &expected)) {
        return Error.Tlz_Tls12ClientConnection_ServerFinishedMismatch;
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn testConnection() Self {
    return .{
        .km = .{
            .client_write_key = @splat(0x11),
            .server_write_key = @splat(0x22),
            .client_write_iv = @splat(0x33),
            .server_write_iv = @splat(0x44),
        },
    };
}

/// A record sealed the way the server would, at `seq`.
fn serverRecord(out: []u8, plaintext: []const u8, content_type: u8, seq: u64) []const u8 {
    return record.protect(out, plaintext, content_type, @splat(0x22), @splat(0x44), seq);
}

fn finishedMessage(verify_data: [prf.VERIFY_DATA_LENGTH]u8) [FINISHED_MESSAGE_LENGTH]u8 {
    var msg: [FINISHED_MESSAGE_LENGTH]u8 = undefined;
    msg[0] = @intFromEnum(HandshakeType.FINISHED);
    msg[1] = 0;
    msg[2] = 0;
    msg[3] = prf.VERIFY_DATA_LENGTH;
    @memcpy(msg[4..], &verify_data);

    return msg;
}

test "tlz tls12 client: ClientConnection, readAppData opens a server record" {
    var conn = testConnection();
    var rec_buf: [128]u8 = undefined;
    var out: [128]u8 = undefined;

    const rec = serverRecord(&rec_buf, "pong", 23, 1);
    const data = try conn.readAppData(rec, &out);

    try std.testing.expectEqualSlices(u8, "pong", data);
    try std.testing.expectEqual(@as(u64, 2), conn.server_seq);
}

test "tlz tls12 client: ClientConnection, writeAppData seals under the client key" {
    var conn = testConnection();
    var rec_buf: [128]u8 = undefined;
    var out: [128]u8 = undefined;

    const rec = conn.writeAppData("ping", &rec_buf);
    const data = try record.deprotect(&out, rec, @splat(0x11), @splat(0x33), 1);

    try std.testing.expectEqualSlices(u8, "ping", data);
}

test "tlz tls12 client: ClientConnection, readAppData out of sequence fails" {
    var conn = testConnection();
    var rec_buf: [128]u8 = undefined;
    var out: [128]u8 = undefined;

    const rec = serverRecord(&rec_buf, "pong", 23, 9);

    try std.testing.expectError(
        Error.Tlz_Tls12ClientConnection_AuthenticationFailed,
        conn.readAppData(rec, &out),
    );
}

test "tlz tls12 client: ClientConnection, readAppData on a short record is bad" {
    var conn = testConnection();
    var out: [64]u8 = undefined;

    try std.testing.expectError(
        Error.Tlz_Tls12ClientConnection_BadRecord,
        conn.readAppData(&[_]u8{ 23, 3, 3, 0, 0 }, &out),
    );
}

test "tlz tls12 client: ClientConnection, closeNotify is a close_notify alert" {
    var conn = testConnection();
    var rec_buf: [64]u8 = undefined;
    var out: [64]u8 = undefined;

    const rec = conn.closeNotify(&rec_buf);
    const body = try record.deprotect(&out, rec, @splat(0x11), @splat(0x33), 1);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 0 }, body);
}

test "tlz tls12 client: ClientConnection, verifyServerFinished accepts the match" {
    const conn = testConnection();
    const verify_data: [prf.VERIFY_DATA_LENGTH]u8 = @splat(0x5A);
    const msg = finishedMessage(verify_data);
    var rec_buf: [64]u8 = undefined;

    const rec = serverRecord(&rec_buf, &msg, 22, 0);

    try conn.verifyServerFinished(rec, verify_data);
}

test "tlz tls12 client: ClientConnection, verifyServerFinished on wrong data is a mismatch" {
    const conn = testConnection();
    const msg = finishedMessage(@splat(0x5A));
    var rec_buf: [64]u8 = undefined;

    const rec = serverRecord(&rec_buf, &msg, 22, 0);

    try std.testing.expectError(
        Error.Tlz_Tls12ClientConnection_ServerFinishedMismatch,
        conn.verifyServerFinished(rec, @splat(0x00)),
    );
}

test "tlz tls12 client: ClientConnection, verifyServerFinished on another type is unexpected" {
    const conn = testConnection();
    var msg = finishedMessage(@splat(0x5A));
    msg[0] = @intFromEnum(HandshakeType.CERTIFICATE);
    var rec_buf: [64]u8 = undefined;

    const rec = serverRecord(&rec_buf, &msg, 22, 0);

    try std.testing.expectError(
        Error.Tlz_Tls12ClientConnection_UnexpectedMessage,
        conn.verifyServerFinished(rec, @splat(0x5A)),
    );
}

test "tlz tls12 client: ClientConnection, verifyServerFinished on a short body is unexpected" {
    const conn = testConnection();
    var rec_buf: [64]u8 = undefined;

    const rec = serverRecord(&rec_buf, &[_]u8{ 20, 0, 0, 0 }, 22, 0);

    try std.testing.expectError(
        Error.Tlz_Tls12ClientConnection_UnexpectedMessage,
        conn.verifyServerFinished(rec, @splat(0x5A)),
    );
}

