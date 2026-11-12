//! TLZ dtls client ClientConnection
//!
//! ### file: src/tlz/src/dtls/client/ClientConnection.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! An established DTLS 1.2 association from the client side: the keys, the send
//! sequence, and the receive replay window for epoch 1.
//!
//! ### note:
//!
//! The mirror of `connection/Connection.zig`: this side writes with the client keys
//! and reads with the server keys. The server Finished is an epoch 1 record at
//! sequence 0, so `readRecord` is also what opens it.
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
const connection = @import("../connection.zig");
const KeyMaterial = @import("../../tls12/prf/KeyMaterial.zig");

// --------------------------------------------------------- //
// Fields:

km: KeyMaterial,
/// Next record sequence number this client sends in epoch 1. Starts at 1, after the
/// Finished that used 0.
client_seq: u48 = 1,
/// Replay window for epoch 1.
replay: record.AntiReplay = .{},

const Self = @This();

// --------------------------------------------------------- //
// Private:

fn recordError(err: record.Error) Error {
    @branchHint(.cold);

    return switch (err) {
        error.Tlz_DtlsRecord_Truncated => Error.Tlz_DtlsClientConnection_Truncated,
        error.Tlz_DtlsRecord_BadRecord => Error.Tlz_DtlsClientConnection_BadRecord,
        error.Tlz_DtlsRecord_AuthenticationFailed => {
            return Error.Tlz_DtlsClientConnection_AuthenticationFailed;
        },
    };
}

// --------------------------------------------------------- //
// Public:

/// What `writeAppData` can raise.
pub const WriteError = error{
    Tlz_DtlsClientConnection_BadRecord,
};

pub const Error = WriteError || error{
    Tlz_DtlsClientConnection_Truncated,
    Tlz_DtlsClientConnection_AuthenticationFailed,
};

/// Protect application data for the peer under the client write key.
///
/// Param:
/// plaintext - []const u8 (at most `record.MAX_PLAINTEXT` bytes)
/// out - []u8 (room for the protected record)
///
/// Return:
/// - []const u8 (the record, borrowing `out`)
/// - Error.Tlz_DtlsClientConnection_BadRecord when the plaintext or `out` does not fit
pub fn writeAppData(self: *Self, plaintext: []const u8, out: []u8) WriteError![]const u8 {
    const bytes = record.protect(
        out,
        plaintext,
        .APPLICATION_DATA,
        connection.EPOCH_APPLICATION,
        self.client_seq,
        self.km.client_write_key,
        self.km.client_write_iv,
    ) catch |err| switch (err) {
        error.Tlz_DtlsRecord_BadRecord => return WriteError.Tlz_DtlsClientConnection_BadRecord,
    };
    self.client_seq += 1;

    return bytes;
}

/// Open an epoch 1 record from the peer. The caller tells a Finished from app data
/// by what it expects next.
///
/// Param:
/// bytes - []const u8 (one complete record, header included)
/// out - []u8 (destination for the plaintext)
///
/// Return:
/// - []const u8 (the plaintext, borrowing `out`)
/// - null when the record is a replay or belongs to another epoch, so discard it
/// - Error.Tlz_DtlsClientConnection_Truncated, BadRecord, AuthenticationFailed when
///   the record is malformed or fails authentication
pub fn readRecord(self: *Self, bytes: []const u8, out: []u8) Error!?[]const u8 {
    const header = record.parseHeader(bytes) catch |err| return recordError(err);
    if (header.epoch != connection.EPOCH_APPLICATION) return null;
    if (!self.replay.isNew(header.sequence_number)) return null;

    const opened = record.deprotect(
        out,
        bytes,
        self.km.server_write_key,
        self.km.server_write_iv,
    ) catch |err| return recordError(err);
    self.replay.accept(header.sequence_number);

    return opened.data;
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

/// A server record sealed the way the peer would.
fn serverRecord(
    out: []u8,
    plaintext: []const u8,
    epoch: u16,
    seq: u48,
) record.WriteError![]const u8 {
    return record.protect(
        out,
        plaintext,
        .APPLICATION_DATA,
        epoch,
        seq,
        @splat(0x22),
        @splat(0x44),
    );
}

test "tlz dtls client: ClientConnection, readRecord opens a server record" {
    var conn = testConnection();
    var rec_buf: [128]u8 = undefined;
    var out: [128]u8 = undefined;

    const rec = try serverRecord(&rec_buf, "pong", connection.EPOCH_APPLICATION, 0);

    try std.testing.expectEqualStrings("pong", (try conn.readRecord(rec, &out)).?);
}

test "tlz dtls client: ClientConnection, writeAppData seals under the client key" {
    var conn = testConnection();
    var rec_buf: [128]u8 = undefined;
    var out: [128]u8 = undefined;

    const rec = try conn.writeAppData("ping", &rec_buf);
    const opened = try record.deprotect(&out, rec, @splat(0x11), @splat(0x33));

    try std.testing.expectEqualStrings("ping", opened.data);
    try std.testing.expectEqual(@as(u48, 1), opened.header.sequence_number);
    try std.testing.expectEqual(@as(u48, 2), conn.client_seq);
}

test "tlz dtls client: ClientConnection, a replayed record gives null" {
    var conn = testConnection();
    var rec_buf: [128]u8 = undefined;
    var out: [128]u8 = undefined;
    const rec = try serverRecord(&rec_buf, "once only", connection.EPOCH_APPLICATION, 1);

    _ = try conn.readRecord(rec, &out);

    try std.testing.expectEqual(@as(?[]const u8, null), try conn.readRecord(rec, &out));
}

test "tlz dtls client: ClientConnection, a record from epoch 0 gives null" {
    var conn = testConnection();
    var rec_buf: [128]u8 = undefined;
    var out: [128]u8 = undefined;

    const rec = try serverRecord(&rec_buf, "old", connection.EPOCH_HANDSHAKE, 3);

    try std.testing.expectEqual(@as(?[]const u8, null), try conn.readRecord(rec, &out));
}

test "tlz dtls client: ClientConnection, a forged record fails authentication" {
    var conn = testConnection();
    var rec_buf: [128]u8 = undefined;
    var out: [128]u8 = undefined;
    const rec = try serverRecord(&rec_buf, "pong", connection.EPOCH_APPLICATION, 2);
    rec_buf[rec.len - 1] ^= 0x01;

    try std.testing.expectError(
        Error.Tlz_DtlsClientConnection_AuthenticationFailed,
        conn.readRecord(rec, &out),
    );
}

test "tlz dtls client: ClientConnection, a stub record is truncated" {
    var conn = testConnection();
    var out: [64]u8 = undefined;

    try std.testing.expectError(
        Error.Tlz_DtlsClientConnection_Truncated,
        conn.readRecord(&[_]u8{ 23, 0xFE }, &out),
    );
}

test "tlz dtls client: ClientConnection, writeAppData into a small buffer is a bad record" {
    var conn = testConnection();
    var rec_buf: [8]u8 = undefined;

    try std.testing.expectError(
        WriteError.Tlz_DtlsClientConnection_BadRecord,
        conn.writeAppData("ping", &rec_buf),
    );
}

