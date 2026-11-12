//! TLZ client ClientConnection
//!
//! ### file: src/tlz/src/client/ClientConnection.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The client side of an established TLS 1.3 connection: the application keys,
//! the per-direction sequence numbers, and the record read and write calls.
//!
//! ### note:
//!
//! The client writes under the client application key and reads under the server
//! one, the opposite of the server Connection.
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
const alert = @import("../alert.zig");

const KEY_LENGTH = record.KEY_LENGTH;
const IV_LENGTH = record.IV_LENGTH;

// --------------------------------------------------------- //
// Fields:

client_app_key: [KEY_LENGTH]u8,
client_app_iv: [IV_LENGTH]u8,
server_app_key: [KEY_LENGTH]u8,
server_app_iv: [IV_LENGTH]u8,
client_seq: u64 = 0,
server_seq: u64 = 0,

const Self = @This();

// --------------------------------------------------------- //
// Private:

fn recordError(err: record.Error) Error {
    @branchHint(.cold);

    return switch (err) {
        error.Tlz_Record_Overflow => Error.Tlz_ClientConnection_RecordOverflow,
        error.Tlz_Record_BadMac => Error.Tlz_ClientConnection_BadRecordMac,
        error.Tlz_Record_Decode => Error.Tlz_ClientConnection_Decode,
    };
}

// --------------------------------------------------------- //
// Public:

pub const Error = error{
    Tlz_ClientConnection_RecordOverflow,
    Tlz_ClientConnection_BadRecordMac,
    Tlz_ClientConnection_Decode,
};

/// Encrypt application data into one record under the client application key.
///
/// Param:
/// plaintext - []const u8 (at most `record.MAX_PLAINTEXT` bytes)
/// out - []u8 (at least `record.sealedLen(plaintext.len)` bytes)
///
/// Return:
/// - []const u8 (the wire record, a view into `out`, empty when it does not fit)
pub fn writeAppData(self: *Self, plaintext: []const u8, out: []u8) []const u8 {
    const rec = record.protect(
        out,
        plaintext,
        .APPLICATION_DATA,
        self.client_app_key,
        self.client_app_iv,
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
/// - Error.Tlz_ClientConnection_Decode when the inner type is not application_data
/// - Error.Tlz_ClientConnection_BadRecordMac or RecordOverflow from the record layer
pub fn readAppData(self: *Self, rec: []const u8, out: []u8) Error![]const u8 {
    const opened = record.deprotect(
        out,
        rec,
        self.server_app_key,
        self.server_app_iv,
        self.server_seq,
    ) catch |err| return recordError(err);
    self.server_seq += 1;

    if (opened.inner_type != .APPLICATION_DATA) return Error.Tlz_ClientConnection_Decode;

    return opened.data;
}

/// Emit an encrypted close_notify alert under the client application key.
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
    const rec = record.protect(
        out,
        &body,
        .ALERT,
        self.client_app_key,
        self.client_app_iv,
        self.client_seq,
    );
    self.client_seq += 1;

    return rec;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn testConnection() Self {
    return .{
        .client_app_key = @splat(0x24),
        .client_app_iv = @splat(0x68),
        .server_app_key = @splat(0x24),
        .server_app_iv = @splat(0x68),
    };
}

test "tlz client: ClientConnection, writeAppData round trips through readAppData" {
    var writer_side = testConnection();
    var reader_side = testConnection();
    var rec_buf: [128]u8 = undefined;
    var out: [128]u8 = undefined;

    const rec = writer_side.writeAppData("ping", &rec_buf);
    const data = try reader_side.readAppData(rec, &out);

    try std.testing.expectEqualSlices(u8, "ping", data);
    try std.testing.expectEqual(@as(u64, 1), writer_side.client_seq);
    try std.testing.expectEqual(@as(u64, 1), reader_side.server_seq);
}

test "tlz client: ClientConnection, readAppData on an alert record is decode" {
    var writer_side = testConnection();
    var reader_side = testConnection();
    var rec_buf: [128]u8 = undefined;
    var out: [128]u8 = undefined;

    const rec = writer_side.closeNotify(&rec_buf);

    try std.testing.expectError(
        Error.Tlz_ClientConnection_Decode,
        reader_side.readAppData(rec, &out),
    );
}

test "tlz client: ClientConnection, readAppData out of sequence is a bad MAC" {
    var writer_side = testConnection();
    var reader_side = testConnection();
    reader_side.server_seq = 5;
    var rec_buf: [128]u8 = undefined;
    var out: [128]u8 = undefined;

    const rec = writer_side.writeAppData("ping", &rec_buf);

    try std.testing.expectError(
        Error.Tlz_ClientConnection_BadRecordMac,
        reader_side.readAppData(rec, &out),
    );
}

test "tlz client: ClientConnection, closeNotify is a close_notify alert" {
    var conn = testConnection();
    var rec_buf: [64]u8 = undefined;
    var plain: [64]u8 = undefined;

    const rec = conn.closeNotify(&rec_buf);
    const opened = try record.deprotect(&plain, rec, @splat(0x24), @splat(0x68), 0);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 0 }, opened.data);
}

