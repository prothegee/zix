//! TLZ dtls connection Connection
//!
//! ### file: src/tlz/src/dtls/connection/Connection.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! An established DTLS 1.2 server association: the keys, the send sequence, and the
//! receive replay window for epoch 1.
//!
//! ### note:
//!
//! The replay window is consulted BEFORE the AEAD and updated only after it, so a
//! forged record at a far-ahead sequence cannot slide the window and lock out real
//! traffic. A record from another epoch is reordering, not an error: it is dropped.
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
/// Next record sequence number this server sends in epoch 1. Starts at 1, after the
/// Finished that used 0.
server_seq: u48 = 1,
/// Replay window for epoch 1.
replay: record.AntiReplay = .{},

const Self = @This();

// --------------------------------------------------------- //
// Private:

fn recordError(err: record.Error) Error {
    @branchHint(.cold);

    return switch (err) {
        error.Tlz_DtlsRecord_Truncated => Error.Tlz_DtlsServerConnection_Truncated,
        error.Tlz_DtlsRecord_BadRecord => Error.Tlz_DtlsServerConnection_BadRecord,
        error.Tlz_DtlsRecord_AuthenticationFailed => {
            return Error.Tlz_DtlsServerConnection_AuthenticationFailed;
        },
    };
}

// --------------------------------------------------------- //
// Public:

/// What `writeAppData` can raise.
pub const WriteError = error{
    Tlz_DtlsServerConnection_BadRecord,
};

pub const Error = WriteError || error{
    Tlz_DtlsServerConnection_Truncated,
    Tlz_DtlsServerConnection_AuthenticationFailed,
};

/// Protect application data for the peer under the server write key.
///
/// Param:
/// plaintext - []const u8 (at most `record.MAX_PLAINTEXT` bytes)
/// out - []u8 (room for the protected record)
///
/// Return:
/// - []const u8 (the record, borrowing `out`)
/// - Error.Tlz_DtlsServerConnection_BadRecord when the plaintext or `out` does not fit
pub fn writeAppData(self: *Self, plaintext: []const u8, out: []u8) WriteError![]const u8 {
    const bytes = record.protect(
        out,
        plaintext,
        .APPLICATION_DATA,
        connection.EPOCH_APPLICATION,
        self.server_seq,
        self.km.server_write_key,
        self.km.server_write_iv,
    ) catch |err| switch (err) {
        error.Tlz_DtlsRecord_BadRecord => return WriteError.Tlz_DtlsServerConnection_BadRecord,
    };
    self.server_seq += 1;

    return bytes;
}

/// Open an application-data record from the peer.
///
/// Param:
/// bytes - []const u8 (one complete record, header included)
/// out - []u8 (destination for the plaintext)
///
/// Return:
/// - []const u8 (the plaintext, borrowing `out`)
/// - null when the record is a replay or belongs to another epoch, so discard it
/// - Error.Tlz_DtlsServerConnection_Truncated, BadRecord, AuthenticationFailed when
///   the record is malformed or fails authentication, also a discard
pub fn readAppData(self: *Self, bytes: []const u8, out: []u8) Error!?[]const u8 {
    const header = record.parseHeader(bytes) catch |err| return recordError(err);
    if (header.epoch != connection.EPOCH_APPLICATION) return null;
    if (!self.replay.isNew(header.sequence_number)) return null;

    const opened = record.deprotect(
        out,
        bytes,
        self.km.client_write_key,
        self.km.client_write_iv,
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

/// A client record sealed the way the peer would.
fn clientRecord(
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
        @splat(0x11),
        @splat(0x33),
    );
}

test "tlz dtls connection: Connection, readAppData opens a client record" {
    var conn = testConnection();
    var rec_buf: [128]u8 = undefined;
    var out: [128]u8 = undefined;

    const rec = try clientRecord(&rec_buf, "ping", connection.EPOCH_APPLICATION, 1);

    try std.testing.expectEqualStrings("ping", (try conn.readAppData(rec, &out)).?);
}

test "tlz dtls connection: Connection, writeAppData seals under the server key" {
    var conn = testConnection();
    var rec_buf: [128]u8 = undefined;
    var out: [128]u8 = undefined;

    const rec = try conn.writeAppData("pong", &rec_buf);
    const opened = try record.deprotect(&out, rec, @splat(0x22), @splat(0x44));

    try std.testing.expectEqualStrings("pong", opened.data);
    try std.testing.expectEqual(@as(u48, 1), opened.header.sequence_number);
    try std.testing.expectEqual(@as(u48, 2), conn.server_seq);
}

test "tlz dtls connection: Connection, a replayed record gives null" {
    var conn = testConnection();
    var rec_buf: [128]u8 = undefined;
    var out: [128]u8 = undefined;
    const rec = try clientRecord(&rec_buf, "ping", connection.EPOCH_APPLICATION, 1);

    _ = try conn.readAppData(rec, &out);

    try std.testing.expectEqual(@as(?[]const u8, null), try conn.readAppData(rec, &out));
}

test "tlz dtls connection: Connection, a record from epoch 0 gives null" {
    var conn = testConnection();
    var rec_buf: [128]u8 = undefined;
    var out: [128]u8 = undefined;

    const rec = try clientRecord(&rec_buf, "old", connection.EPOCH_HANDSHAKE, 9);

    try std.testing.expectEqual(@as(?[]const u8, null), try conn.readAppData(rec, &out));
}

test "tlz dtls connection: Connection, a forged record fails without moving the window" {
    var conn = testConnection();
    var rec_buf: [128]u8 = undefined;
    var out: [128]u8 = undefined;
    const rec = try clientRecord(&rec_buf, "ping", connection.EPOCH_APPLICATION, 500);
    rec_buf[rec.len - 1] ^= 0x01;

    try std.testing.expectError(
        Error.Tlz_DtlsServerConnection_AuthenticationFailed,
        conn.readAppData(rec, &out),
    );
    try std.testing.expectEqual(@as(u48, 0), conn.replay.highest);
}

test "tlz dtls connection: Connection, a stub record is truncated" {
    var conn = testConnection();
    var out: [64]u8 = undefined;

    try std.testing.expectError(
        Error.Tlz_DtlsServerConnection_Truncated,
        conn.readAppData(&[_]u8{ 23, 0xFE }, &out),
    );
}

test "tlz dtls connection: Connection, writeAppData into a small buffer is a bad record" {
    var conn = testConnection();
    var rec_buf: [8]u8 = undefined;

    try std.testing.expectError(
        WriteError.Tlz_DtlsServerConnection_BadRecord,
        conn.writeAppData("pong", &rec_buf),
    );
}

