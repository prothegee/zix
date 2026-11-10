//! ZIX http1 websocket send
//!
//! ### file: src/zix/tcp/http1/websocket/send.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Send one server frame to a connection, or the same frame to many
//! connections.
//!
//! ### note:
//!
//! During a pump pass, a frame to the pumped connection is staged in the
//! send sink and goes out with the rest of the pass. A frame to any other
//! connection is written right away.
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
const writer = @import("../writer.zig");
const frame = @import("frame.zig");
const Opcode = @import("opcode.zig").Opcode;
const WsSendSink = @import("WsSendSink.zig");

// --------------------------------------------------------- //
// Private:

/// Largest frame built in one stack buffer and sent with one write. A larger
/// frame writes the header, then the payload, to skip a big copy.
const INLINE_CAP: usize = 4096;

fn writeOut(fd: std.posix.fd_t, bytes: []const u8) Error!void {
    writer.writeAllFD(fd, bytes) catch |err| switch (err) {
        error.ZixHttp1_Writer_BrokenPipe => return Error.ZixHttp1_WebSocketSend_BrokenPipe,
        error.ZixHttp1_Writer_HeadBuild => return Error.ZixHttp1_WebSocketSend_HeadBuild,
    };
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http1 WebSocket send error
pub const Error = error {
    ZixHttp1_WebSocketSend_BrokenPipe,
    ZixHttp1_WebSocketSend_HeadBuild,
};

/// Send sink of the pump pass running on this thread. Set by the pump.
pub threadlocal var tl_send_sink: ?*WsSendSink = null;

/// Build one server frame and send it to fd.
///
/// Param:
/// fd - std.posix.fd_t
/// opcode - Opcode
/// payload - []const u8
///
/// Return:
/// - void
/// - error.ZixHttp1_WebSocketSend_BrokenPipe when the peer is gone
pub fn sendFD(fd: std.posix.fd_t, opcode: Opcode, payload: []const u8) Error!void {
    var header: [frame.MAX_HEADER]u8 = undefined;

    if (tl_send_sink) |sink| {
        if (sink.fd == fd) {
            const header_len = frame.buildHeader(&header, opcode, payload.len);

            sink.append(header[0..header_len]);
            sink.append(payload);
            if (sink.failed) return Error.ZixHttp1_WebSocketSend_BrokenPipe;

            return;
        }
    }

    if (payload.len + frame.MAX_HEADER <= INLINE_CAP) {
        var buf: [INLINE_CAP]u8 = undefined;
        const len = frame.buildFrame(&buf, opcode, payload);

        return writeOut(fd, buf[0..len]);
    }

    const header_len = frame.buildHeader(&header, opcode, payload.len);

    try writeOut(fd, header[0..header_len]);
    try writeOut(fd, payload);
}

/// Build one server frame and write it to every fd in conns. The frame is
/// built once, whatever the number of connections.
///
/// Note:
/// - A failed write (dead peer) is skipped. The engine closes that fd on its
///   next event.
/// - The caller owns the conns list (for example a room). The engine keeps no
///   room registry.
///
/// Param:
/// conns - []const std.posix.fd_t (target connections)
/// opcode - Opcode
/// payload - []const u8
///
/// Usage:
/// ```zig
/// // inside a frame callback, send a chat line to the room
/// zix.Http1.WebSocket.broadcast(room_fds, .text, payload);
/// ```
pub fn broadcast(conns: []const std.posix.fd_t, opcode: Opcode, payload: []const u8) void {
    var header: [frame.MAX_HEADER]u8 = undefined;

    if (payload.len + frame.MAX_HEADER <= INLINE_CAP) {
        var buf: [INLINE_CAP]u8 = undefined;
        const len = frame.buildFrame(&buf, opcode, payload);

        for (conns) |fd| {
            // Best effort: a dead member must not stop the others.
            writeOut(fd, buf[0..len]) catch |err| switch (err) {
                error.ZixHttp1_WebSocketSend_BrokenPipe,
                error.ZixHttp1_WebSocketSend_HeadBuild,
                => continue,
            };
        }

        return;
    }

    const header_len = frame.buildHeader(&header, opcode, payload.len);

    for (conns) |fd| {
        // Best effort: a dead member must not stop the others.
        writeOut(fd, header[0..header_len]) catch |err| switch (err) {
            error.ZixHttp1_WebSocketSend_BrokenPipe,
            error.ZixHttp1_WebSocketSend_HeadBuild,
            => continue,
        };
        writeOut(fd, payload) catch |err| switch (err) {
            error.ZixHttp1_WebSocketSend_BrokenPipe,
            error.ZixHttp1_WebSocketSend_HeadBuild,
            => continue,
        };
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../../utils/socket/pair.zig");
const reader = @import("../reader.zig");

fn testReadExact(fd: std.posix.fd_t, out: []u8) !void {
    var got: usize = 0;
    while (got < out.len) {
        const n = try reader.readOnceFD(fd, out[got..]);
        if (n == 0) return error.TestReadClosed;
        got += n;
    }
}

test "zix http1 websocket: send, sendFD writes one text frame" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try sendFD(fds[0], .text, "hi");

    var out: [4]u8 = undefined;
    try testReadExact(fds[1], &out);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x02, 'h', 'i' }, &out);
}

test "zix http1 websocket: send, sendFD writes a frame past the inline cap" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const payload: [INLINE_CAP]u8 = @splat('x');
    try sendFD(fds[0], .binary, &payload);

    var out: [4 + INLINE_CAP]u8 = undefined;
    try testReadExact(fds[1], &out);

    try std.testing.expectEqual(@as(u8, 0x82), out[0]);
    try std.testing.expectEqual(@as(u8, 126), out[1]);
    try std.testing.expectEqual(@as(u8, 'x'), out[out.len - 1]);
}

test "zix http1 websocket: send, sendFD stages into the sink of the same fd" {
    var buf: [16]u8 = undefined;
    var sink: WsSendSink = .{
        .fd = 5,
        .buf = &buf,
    };
    tl_send_sink = &sink;
    defer tl_send_sink = null;

    try sendFD(5, .text, "ok");

    try std.testing.expectEqual(@as(usize, 4), sink.len);
}

test "zix http1 websocket: send, sendFD to another fd skips the sink" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var buf: [16]u8 = undefined;
    var sink: WsSendSink = .{
        .fd = -1,
        .buf = &buf,
    };
    tl_send_sink = &sink;
    defer tl_send_sink = null;

    try sendFD(fds[0], .text, "ok");

    var out: [4]u8 = undefined;
    try testReadExact(fds[1], &out);

    try std.testing.expectEqual(@as(usize, 0), sink.len);
    try std.testing.expectEqualStrings("ok", out[2..]);
}

test "zix http1 websocket: send, sendFD reports a broken pipe" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    _ = std.posix.system.close(fds[1]);

    try std.testing.expectError(
        Error.ZixHttp1_WebSocketSend_BrokenPipe,
        sendFD(fds[0], .text, "hi"),
    );
}

test "zix http1 websocket: send, broadcast reaches every connection" {
    var first: [2]std.posix.fd_t = undefined;
    var second: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &first);
    defer _ = std.posix.system.close(first[0]);
    defer _ = std.posix.system.close(first[1]);
    try pair.open(std.testing.io, &second);
    defer _ = std.posix.system.close(second[0]);
    defer _ = std.posix.system.close(second[1]);

    broadcast(&[_]std.posix.fd_t{ first[0], second[0] }, .text, "room");

    var out_first: [6]u8 = undefined;
    var out_second: [6]u8 = undefined;
    try testReadExact(first[1], &out_first);
    try testReadExact(second[1], &out_second);

    try std.testing.expectEqualStrings("room", out_first[2..]);
    try std.testing.expectEqualSlices(u8, &out_first, &out_second);
}

test "zix http1 websocket: send, broadcast skips a dead connection" {
    var dead: [2]std.posix.fd_t = undefined;
    var live: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &dead);
    defer _ = std.posix.system.close(dead[0]);
    _ = std.posix.system.close(dead[1]);
    try pair.open(std.testing.io, &live);
    defer _ = std.posix.system.close(live[0]);
    defer _ = std.posix.system.close(live[1]);

    broadcast(&[_]std.posix.fd_t{ dead[0], live[0] }, .text, "up");

    var out: [4]u8 = undefined;
    try testReadExact(live[1], &out);

    try std.testing.expectEqualStrings("up", out[2..]);
}

test "zix http1 websocket: send, broadcast writes a frame past the inline cap" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const payload: [INLINE_CAP]u8 = @splat('y');
    broadcast(&[_]std.posix.fd_t{fds[0]}, .binary, &payload);

    var out: [4 + INLINE_CAP]u8 = undefined;
    try testReadExact(fds[1], &out);

    try std.testing.expectEqual(@as(u8, 126), out[1]);
    try std.testing.expectEqual(@as(u8, 'y'), out[out.len - 1]);
}

