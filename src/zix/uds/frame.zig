//! ZIX Uds frame
//!
//! ### file: src/zix/uds/frame.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Reads and writes one length-prefixed UDS frame:
//! [u32 payload length, 4 bytes, big-endian][payload bytes].
//!
//! ### note:
//!
//! Shared by the server echoHandler and the UDS client, so both ends use one
//! encode and decode path.
//! On ZixUds_Frame_TooLarge the payload is still unread in the stream, so the
//! caller must close the connection.
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

// --------------------------------------------------------- //
// Private:

fn readExact(reader: *std.Io.Reader, buf: []u8) Error!void {
    reader.readSliceAll(buf) catch |err| switch (err) {
        error.EndOfStream => return Error.ZixUds_Frame_Closed,
        error.ReadFailed => return Error.ZixUds_Frame_ReadFailed,
    };
}

fn writeBytes(writer: *std.Io.Writer, bytes: []const u8) Error!void {
    writer.writeAll(bytes) catch |err| switch (err) {
        error.WriteFailed => return Error.ZixUds_Frame_WriteFailed,
    };
}

// --------------------------------------------------------- //
// Public:

/// Size of the length header in bytes.
pub const HEADER_LEN: usize = 4;

/// Largest payload one frame can carry (the header is a u32).
pub const MAX_PAYLOAD_LEN: usize = std.math.maxInt(u32);

pub const Error = error {
    /// The peer closed the stream before a full header or payload arrived
    ZixUds_Frame_Closed,
    /// The underlying reader failed
    ZixUds_Frame_ReadFailed,
    /// The payload does not fit the caller buffer, or is above MAX_PAYLOAD_LEN
    ZixUds_Frame_TooLarge,
    /// The underlying writer failed
    ZixUds_Frame_WriteFailed,
};

/// Read one frame into buf.
///
/// Note:
/// - A zero-length payload is valid and returns an empty slice.
///
/// Param:
/// reader - *std.Io.Reader (stream reader, positioned at a frame header)
/// buf - []u8 (payload destination, its length is the max accepted payload)
///
/// Return:
/// - []u8 (the payload, a slice of buf)
/// - Error.ZixUds_Frame_Closed when the stream ends inside a frame
/// - Error.ZixUds_Frame_ReadFailed when the reader fails
/// - Error.ZixUds_Frame_TooLarge when the payload is longer than buf
pub fn readFrame(reader: *std.Io.Reader, buf: []u8) Error![]u8 {
    var header: [HEADER_LEN]u8 = undefined;
    try readExact(reader, &header);

    const len: usize = std.mem.readInt(u32, &header, .big);
    if (len > buf.len) return Error.ZixUds_Frame_TooLarge;

    try readExact(reader, buf[0..len]);

    return buf[0..len];
}

/// Write one frame (header then payload) and flush it.
///
/// Param:
/// writer - *std.Io.Writer (stream writer)
/// payload - []const u8 (bytes to send, at most MAX_PAYLOAD_LEN)
///
/// Return:
/// - void
/// - Error.ZixUds_Frame_TooLarge when payload is longer than MAX_PAYLOAD_LEN
/// - Error.ZixUds_Frame_WriteFailed when the writer fails
pub fn writeFrame(writer: *std.Io.Writer, payload: []const u8) Error!void {
    if (payload.len > MAX_PAYLOAD_LEN) return Error.ZixUds_Frame_TooLarge;

    var header: [HEADER_LEN]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(payload.len), .big);

    try writeBytes(writer, &header);
    try writeBytes(writer, payload);

    writer.flush() catch |err| switch (err) {
        error.WriteFailed => return Error.ZixUds_Frame_WriteFailed,
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const socket_pair = @import("../utils/socket/pair.zig");

fn testStream(fd: std.posix.fd_t) std.Io.net.Stream {
    return .{
        .socket = .{
            .handle = fd,
            .address = .{ .ip4 = .loopback(0) },
        },
    };
}

test "zix uds: frame, writeFrame puts a big-endian length header" {
    var out: [16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);

    try writeFrame(&writer, "hello");

    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 5 }, out[0..HEADER_LEN]);
    try std.testing.expectEqualStrings("hello", out[HEADER_LEN..writer.end]);
}

test "zix uds: frame, readFrame parses a big-endian length header" {
    var reader: std.Io.Reader = .fixed(&.{ 0, 0, 0, 3, 'a', 'b', 'c' });
    var buf: [8]u8 = undefined;

    const payload = try readFrame(&reader, &buf);

    try std.testing.expectEqualStrings("abc", payload);
}

test "zix uds: frame, roundtrip keeps the payload" {
    var out: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);
    try writeFrame(&writer, "zix uds frame");

    var reader: std.Io.Reader = .fixed(out[0..writer.end]);
    var buf: [64]u8 = undefined;

    const payload = try readFrame(&reader, &buf);

    try std.testing.expectEqualStrings("zix uds frame", payload);
}

test "zix uds: frame, readFrame reads back-to-back frames in order" {
    var reader: std.Io.Reader = .fixed(&.{ 0, 0, 0, 1, 'x', 0, 0, 0, 2, 'y', 'z' });
    var buf: [8]u8 = undefined;

    try std.testing.expectEqualStrings("x", try readFrame(&reader, &buf));
    try std.testing.expectEqualStrings("yz", try readFrame(&reader, &buf));
}

test "zix uds: frame, zero-length payload returns an empty slice" {
    var reader: std.Io.Reader = .fixed(&.{ 0, 0, 0, 0 });
    var buf: [4]u8 = undefined;

    const payload = try readFrame(&reader, &buf);

    try std.testing.expectEqual(@as(usize, 0), payload.len);
}

test "zix uds: frame, writeFrame with an empty payload writes only the header" {
    var out: [8]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);

    try writeFrame(&writer, "");

    try std.testing.expectEqual(HEADER_LEN, writer.end);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, out[0..HEADER_LEN]);
}

test "zix uds: frame, payload equal to buf length is accepted" {
    var reader: std.Io.Reader = .fixed(&.{ 0, 0, 0, 2, 'o', 'k' });
    var buf: [2]u8 = undefined;

    const payload = try readFrame(&reader, &buf);

    try std.testing.expectEqualStrings("ok", payload);
}

test "zix uds: frame, payload one past buf length is TooLarge" {
    var reader: std.Io.Reader = .fixed(&.{ 0, 0, 0, 3, 'a', 'b', 'c' });
    var buf: [2]u8 = undefined;

    try std.testing.expectError(Error.ZixUds_Frame_TooLarge, readFrame(&reader, &buf));
}

test "zix uds: frame, u32 max length header is TooLarge for a small buf" {
    var reader: std.Io.Reader = .fixed(&.{ 0xff, 0xff, 0xff, 0xff });
    var buf: [16]u8 = undefined;

    try std.testing.expectError(Error.ZixUds_Frame_TooLarge, readFrame(&reader, &buf));
}

test "zix uds: frame, empty stream is Closed" {
    var reader: std.Io.Reader = .fixed(&.{});
    var buf: [8]u8 = undefined;

    try std.testing.expectError(Error.ZixUds_Frame_Closed, readFrame(&reader, &buf));
}

test "zix uds: frame, truncated header is Closed" {
    var reader: std.Io.Reader = .fixed(&.{ 0, 0 });
    var buf: [8]u8 = undefined;

    try std.testing.expectError(Error.ZixUds_Frame_Closed, readFrame(&reader, &buf));
}

test "zix uds: frame, truncated payload is Closed" {
    var reader: std.Io.Reader = .fixed(&.{ 0, 0, 0, 4, 'a', 'b' });
    var buf: [8]u8 = undefined;

    try std.testing.expectError(Error.ZixUds_Frame_Closed, readFrame(&reader, &buf));
}

test "zix uds: frame, writer without room is WriteFailed" {
    var out: [6]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);

    try std.testing.expectError(Error.ZixUds_Frame_WriteFailed, writeFrame(&writer, "hello"));
}

test "zix uds: frame, writeFrame past MAX_PAYLOAD_LEN is TooLarge" {
    if (comptime @sizeOf(usize) <= @sizeOf(u32)) return error.SkipZigTest;

    // The length check runs before any byte is touched, so the pointer is
    // never read.
    const fake_ptr: [*]const u8 = @ptrFromInt(4096);
    const payload = fake_ptr[0 .. MAX_PAYLOAD_LEN + 1];
    var out: [8]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);

    try std.testing.expectError(Error.ZixUds_Frame_TooLarge, writeFrame(&writer, payload));
    try std.testing.expectEqual(@as(usize, 0), writer.end);
}

test "zix uds: frame, roundtrip over a socket pair" {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;

    var fds: [2]std.posix.fd_t = undefined;
    try socket_pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const io = std.testing.io;
    const left = testStream(fds[0]);
    const right = testStream(fds[1]);

    var write_buf: [64]u8 = undefined;
    var stream_writer = left.writer(io, &write_buf);
    try writeFrame(&stream_writer.interface, "over the wire");

    var read_buf: [64]u8 = undefined;
    var stream_reader = right.reader(io, &read_buf);
    var payload_buf: [64]u8 = undefined;

    const payload = try readFrame(&stream_reader.interface, &payload_buf);

    try std.testing.expectEqualStrings("over the wire", payload);
}

