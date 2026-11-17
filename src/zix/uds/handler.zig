//! ZIX Uds handler
//!
//! ### file: src/zix/uds/handler.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The UDS connection handler contract (HandlerFn) and the default echoHandler.
//!
//! ### note:
//!
//! A handler only receives the stream and io, never the server config.
//! echoHandler keeps its own buffer sizes, independent of
//! ServerConfig.max_recv_buf.
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
const frame = @import("frame.zig");

// --------------------------------------------------------- //
// Private:

/// Reader and writer buffer size in bytes. It only sets how often the socket is
/// read or written, not the frame limit.
const IO_BUF_SIZE: usize = 4 * 1024;

/// Largest payload echoHandler accepts. A larger frame closes the connection.
const MAX_PAYLOAD: usize = 4 * 1024;

// --------------------------------------------------------- //
// Public:

/// Connection handler contract. The server calls it once per accepted
/// connection, the handler owns the stream and must close it.
pub const HandlerFn = fn (std.Io.net.Stream, std.Io) void;

/// Default handler: reads length-prefixed frames and writes each one back.
///
/// Note:
/// - Runs until the peer closes, a read or write fails, or a frame is larger
///   than MAX_PAYLOAD. The stream is closed on return.
///
/// Param:
/// stream - std.Io.net.Stream (accepted connection, owned by this handler)
/// io - std.Io (io backend of the server)
///
/// Return:
/// - void
pub fn echoHandler(stream: std.Io.net.Stream, io: std.Io) void {
    defer stream.close(io);

    var read_buf: [IO_BUF_SIZE]u8 = undefined;
    var write_buf: [IO_BUF_SIZE]u8 = undefined;
    var payload_buf: [MAX_PAYLOAD]u8 = undefined;

    var stream_reader = stream.reader(io, &read_buf);
    var stream_writer = stream.writer(io, &write_buf);

    while (true) {
        const payload = frame.readFrame(
            &stream_reader.interface,
            &payload_buf,
        ) catch |err| switch (err) {
            // Peer closed, read failed, or frame too large: end the connection.
            else => return,
        };

        frame.writeFrame(&stream_writer.interface, payload) catch |err| switch (err) {
            // Peer gone or write failed: end the connection.
            else => return,
        };
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const socket_pair = @import("../utils/socket/pair.zig");

const TestEcho = struct {
    client: std.Io.net.Stream,
    thread: std.Thread,
};

fn testStream(fd: std.posix.fd_t) std.Io.net.Stream {
    return .{
        .socket = .{
            .handle = fd,
            .address = .{ .ip4 = .loopback(0) },
        },
    };
}

/// Start echoHandler on one end of a socket pair. The handler closes its end,
/// the caller closes the client end after join.
fn testStartEcho() !TestEcho {
    var fds: [2]std.posix.fd_t = undefined;
    try socket_pair.open(std.testing.io, &fds);

    const thread = try std.Thread.spawn(.{}, echoHandler, .{
        testStream(fds[1]),
        std.testing.io,
    });

    return .{
        .client = testStream(fds[0]),
        .thread = thread,
    };
}

fn testStopEcho(echo: TestEcho) void {
    echo.client.close(std.testing.io);
    echo.thread.join();
}

/// Send one frame and read the echo into out.
fn testRoundtrip(client: std.Io.net.Stream, payload: []const u8, out: []u8) ![]u8 {
    var write_buf: [IO_BUF_SIZE]u8 = undefined;
    var stream_writer = client.writer(std.testing.io, &write_buf);
    try frame.writeFrame(&stream_writer.interface, payload);

    var read_buf: [IO_BUF_SIZE]u8 = undefined;
    var stream_reader = client.reader(std.testing.io, &read_buf);

    return frame.readFrame(&stream_reader.interface, out);
}

test "zix uds: handler, echoHandler matches HandlerFn" {
    const handler: HandlerFn = echoHandler;

    try std.testing.expect(@TypeOf(handler) == HandlerFn);
}

test "zix uds: handler, IO_BUF_SIZE is 4 KiB" {
    try std.testing.expectEqual(@as(usize, 4 * 1024), IO_BUF_SIZE);
}

test "zix uds: handler, MAX_PAYLOAD is 4 KiB" {
    try std.testing.expectEqual(@as(usize, 4 * 1024), MAX_PAYLOAD);
}

test "zix uds: handler, echoHandler echoes one frame" {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;

    const echo = try testStartEcho();
    defer testStopEcho(echo);

    var out: [64]u8 = undefined;

    const reply = try testRoundtrip(echo.client, "hello", &out);

    try std.testing.expectEqualStrings("hello", reply);
}

test "zix uds: handler, echoHandler echoes frames in order" {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;

    const echo = try testStartEcho();
    defer testStopEcho(echo);

    var out: [64]u8 = undefined;

    try std.testing.expectEqualStrings("one", try testRoundtrip(echo.client, "one", &out));
    try std.testing.expectEqualStrings("two", try testRoundtrip(echo.client, "two", &out));
}

test "zix uds: handler, echoHandler echoes a zero-length frame" {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;

    const echo = try testStartEcho();
    defer testStopEcho(echo);

    var out: [8]u8 = undefined;

    const reply = try testRoundtrip(echo.client, "", &out);

    try std.testing.expectEqual(@as(usize, 0), reply.len);
}

test "zix uds: handler, echoHandler echoes a payload at MAX_PAYLOAD" {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;

    const echo = try testStartEcho();
    defer testStopEcho(echo);

    var payload: [MAX_PAYLOAD]u8 = @splat('z');
    var out: [MAX_PAYLOAD]u8 = undefined;

    const reply = try testRoundtrip(echo.client, &payload, &out);

    try std.testing.expectEqualSlices(u8, &payload, reply);
}

test "zix uds: handler, echoHandler closes past MAX_PAYLOAD" {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;

    const echo = try testStartEcho();
    defer testStopEcho(echo);

    var payload: [MAX_PAYLOAD + 1]u8 = @splat('z');
    var out: [MAX_PAYLOAD + 1]u8 = undefined;

    const result = testRoundtrip(echo.client, &payload, &out);

    // Unread bytes at close can surface as a reset instead of a clean EOF.
    if (result) |_| {
        return error.TestExpectedClose;
    } else |err| switch (err) {
        error.ZixUds_Frame_Closed, error.ZixUds_Frame_ReadFailed => {},
        else => return err,
    }
}

test "zix uds: handler, echoHandler returns when the peer closes first" {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;

    const echo = try testStartEcho();

    testStopEcho(echo);
}

test "zix uds: handler, echoHandler returns on a truncated header" {
    if (comptime builtin.target.os.tag == .windows) return error.SkipZigTest;

    const echo = try testStartEcho();
    defer testStopEcho(echo);

    var write_buf: [8]u8 = undefined;
    var stream_writer = echo.client.writer(std.testing.io, &write_buf);
    try stream_writer.interface.writeAll(&.{ 0, 0 });
    try stream_writer.interface.flush();
}

