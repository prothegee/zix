//! TLZ tls12 connection Connection
//!
//! ### file: src/tlz/src/tls12/connection/Connection.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The server side of an established TLS 1.2 connection: the key material, the
//! per-direction sequence numbers, and the record read and write calls.
//!
//! ### note:
//!
//! Both sequence numbers start at 1. Sequence 0 was the Finished of each side.
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
const alert = @import("../../alert.zig");
const KeyMaterial = @import("../prf/KeyMaterial.zig");
const ContentType = @import("../../record/content_type.zig").ContentType;

// --------------------------------------------------------- //
// Fields:

km: KeyMaterial,
server_seq: u64 = 1,
client_seq: u64 = 1,

const Self = @This();

// --------------------------------------------------------- //
// Private:

fn recordError(err: record.Error) Error {
    @branchHint(.cold);

    return switch (err) {
        error.Tlz_Tls12Record_BadRecord => Error.Tlz_Tls12ServerConnection_BadRecord,
        error.Tlz_Tls12Record_AuthenticationFailed => {
            return Error.Tlz_Tls12ServerConnection_AuthenticationFailed;
        },
    };
}

// --------------------------------------------------------- //
// Public:

pub const Error = error{
    Tlz_Tls12ServerConnection_BadRecord,
    Tlz_Tls12ServerConnection_AuthenticationFailed,
};

/// Encrypt application data into one record under the server write key.
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
        self.km.server_write_key,
        self.km.server_write_iv,
        self.server_seq,
    );
    self.server_seq += 1;

    return rec;
}

/// Decrypt one client application record.
///
/// Param:
/// rec - []const u8 (one whole wire record)
/// out - []u8 (holds at least the ciphertext length)
///
/// Return:
/// - []const u8 (the plaintext, a view into `out`)
/// - Error.Tlz_Tls12ServerConnection_BadRecord on a short record
/// - Error.Tlz_Tls12ServerConnection_AuthenticationFailed on a wrong tag or sequence
pub fn readAppData(self: *Self, rec: []const u8, out: []u8) Error![]const u8 {
    const plain = record.deprotect(
        out,
        rec,
        self.km.client_write_key,
        self.km.client_write_iv,
        self.client_seq,
    ) catch |err| return recordError(err);
    self.client_seq += 1;

    return plain;
}

/// Emit an encrypted close_notify alert under the server write key (RFC 5246 7.2.1).
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
        self.km.server_write_key,
        self.km.server_write_iv,
        self.server_seq,
    );
    self.server_seq += 1;

    return rec;
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

/// A client record sealed the way the peer would, at `seq`.
fn clientRecord(out: []u8, plaintext: []const u8, seq: u64) []const u8 {
    return record.protect(out, plaintext, 23, @splat(0x11), @splat(0x33), seq);
}

test "tlz tls12 connection: Connection, readAppData opens a client record" {
    var conn = testConnection();
    var rec_buf: [128]u8 = undefined;
    var out: [128]u8 = undefined;

    const rec = clientRecord(&rec_buf, "ping", 1);
    const data = try conn.readAppData(rec, &out);

    try std.testing.expectEqualSlices(u8, "ping", data);
    try std.testing.expectEqual(@as(u64, 2), conn.client_seq);
}

test "tlz tls12 connection: Connection, writeAppData seals under the server key" {
    var conn = testConnection();
    var rec_buf: [128]u8 = undefined;
    var out: [128]u8 = undefined;

    const rec = conn.writeAppData("pong", &rec_buf);
    const data = try record.deprotect(&out, rec, @splat(0x22), @splat(0x44), 1);

    try std.testing.expectEqualSlices(u8, "pong", data);
    try std.testing.expectEqual(@as(u64, 2), conn.server_seq);
}

test "tlz tls12 connection: Connection, readAppData out of sequence fails" {
    var conn = testConnection();
    var rec_buf: [128]u8 = undefined;
    var out: [128]u8 = undefined;

    const rec = clientRecord(&rec_buf, "ping", 5);

    try std.testing.expectError(
        Error.Tlz_Tls12ServerConnection_AuthenticationFailed,
        conn.readAppData(rec, &out),
    );
}

test "tlz tls12 connection: Connection, readAppData on a short record is bad" {
    var conn = testConnection();
    var out: [64]u8 = undefined;

    try std.testing.expectError(
        Error.Tlz_Tls12ServerConnection_BadRecord,
        conn.readAppData(&[_]u8{ 23, 3, 3, 0, 0 }, &out),
    );
}

test "tlz tls12 connection: Connection, closeNotify is a close_notify alert" {
    var conn = testConnection();
    var rec_buf: [64]u8 = undefined;
    var out: [64]u8 = undefined;

    const rec = conn.closeNotify(&rec_buf);
    const body = try record.deprotect(&out, rec, @splat(0x22), @splat(0x44), 1);

    try std.testing.expectEqual(@as(u8, 21), rec[0]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 0 }, body);
}

