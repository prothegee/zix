//! ZIX Http2 Grpc frame prefix
//!
//! ### file: src/zix/tcp/http2/grpc/frame/prefix.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Read and write the 5-byte gRPC message prefix (compress flag, then a
//! 4-byte big-endian message length).
//!
//! ### note:
//!
//! Any non-zero compress byte reads as compressed.
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

const GrpcPrefix = @import("GrpcPrefix.zig");

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 Grpc frame prefix error
pub const Error = error {
    ZixHttp2_GrpcPrefix_TooShort,
};

/// gRPC prefix size: 1 compress flag byte plus 4 message length bytes.
pub const PREFIX_LEN: usize = 5;

/// Parse the gRPC prefix at the start of body.
///
/// Param:
/// body - []const u8 (gRPC body, starting at a prefix)
///
/// Return:
/// - GrpcPrefix
/// - error.ZixHttp2_GrpcPrefix_TooShort when body is shorter than PREFIX_LEN
pub fn readGrpcPrefix(body: []const u8) Error!GrpcPrefix {
    if (body.len < PREFIX_LEN) return Error.ZixHttp2_GrpcPrefix_TooShort;

    const msg_len = std.mem.readInt(u32, body[1..PREFIX_LEN], .big);

    return .{
        .compress = body[0] != 0,
        .msg_len = msg_len,
    };
}

/// Write a gRPC prefix into buf.
///
/// Param:
/// buf - *[PREFIX_LEN]u8 (destination)
/// compress - bool (true writes compress flag 1)
/// msg_len - u32 (message payload length)
pub fn writeGrpcPrefix(buf: *[PREFIX_LEN]u8, compress: bool, msg_len: u32) void {
    buf[0] = if (compress) 1 else 0;
    std.mem.writeInt(u32, buf[1..PREFIX_LEN], msg_len, .big);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 grpc frame: prefix, round trip keeps the message length" {
    var buf: [PREFIX_LEN]u8 = undefined;
    writeGrpcPrefix(&buf, false, 42);

    const prefix = try readGrpcPrefix(&buf);

    try std.testing.expect(!prefix.compress);
    try std.testing.expectEqual(@as(u32, 42), prefix.msg_len);
}

test "zix http2 grpc frame: prefix, round trip keeps the compress flag" {
    var buf: [PREFIX_LEN]u8 = undefined;
    writeGrpcPrefix(&buf, true, 0);

    const prefix = try readGrpcPrefix(&buf);

    try std.testing.expect(prefix.compress);
}

test "zix http2 grpc frame: prefix, length is big-endian" {
    var buf: [PREFIX_LEN]u8 = undefined;
    writeGrpcPrefix(&buf, false, 0x0102_0304);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2, 3, 4 }, &buf);
}

test "zix http2 grpc frame: prefix, max u32 length round trips" {
    var buf: [PREFIX_LEN]u8 = undefined;
    writeGrpcPrefix(&buf, false, std.math.maxInt(u32));

    const prefix = try readGrpcPrefix(&buf);

    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), prefix.msg_len);
}

test "zix http2 grpc frame: prefix, any non-zero flag byte reads as compressed" {
    const body = [_]u8{ 0xFF, 0, 0, 0, 0 };

    const prefix = try readGrpcPrefix(&body);

    try std.testing.expect(prefix.compress);
}

test "zix http2 grpc frame: prefix, reads only the first 5 bytes" {
    const body = [_]u8{ 0, 0, 0, 0, 3, 'a', 'b', 'c' };

    const prefix = try readGrpcPrefix(&body);

    try std.testing.expectEqual(@as(u32, 3), prefix.msg_len);
}

test "zix http2 grpc frame: prefix, 4 bytes is TooShort" {
    const body = [_]u8{ 0, 0, 0, 0 };

    try std.testing.expectError(Error.ZixHttp2_GrpcPrefix_TooShort, readGrpcPrefix(&body));
}

test "zix http2 grpc frame: prefix, empty body is TooShort" {
    try std.testing.expectError(Error.ZixHttp2_GrpcPrefix_TooShort, readGrpcPrefix(""));
}

