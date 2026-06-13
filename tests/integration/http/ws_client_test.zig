//! Integration tests: WsConn send/recv frame protocol over a socketpair.

const std = @import("std");
const zix = @import("zix");

fn makePair() ![2]std.posix.fd_t {
    var fds: [2]i32 = undefined;
    const result = std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds);
    if (result != 0) return error.SocketPairFailed;
    return fds;
}

fn closefd(fd: std.posix.fd_t) void {
    _ = std.posix.system.close(fd);
}

// --------------------------------------------------------- //

test "zix integration: WsConn.send produces a masked frame (mask bit set)" {
    const fds = try makePair();
    defer closefd(fds[0]);
    defer closefd(fds[1]);

    const conn = zix.Http.WsConn{ .fd = fds[0] };
    try conn.send(.text, "hello");

    var raw: [64]u8 = undefined;
    const n = try std.posix.read(fds[1], &raw);

    try std.testing.expect(n >= 2);
    // RFC 6455 5.1: mask bit is bit 7 of the second byte.
    try std.testing.expect((raw[1] & 0x80) != 0);
}

test "zix integration: WsConn.send + recv text frame round-trip" {
    const fds = try makePair();
    defer closefd(fds[0]);
    defer closefd(fds[1]);

    const sender = zix.Http.WsConn{ .fd = fds[0] };
    try sender.send(.text, "world");

    // Read the raw masked frame from fds[1] and feed it back as an "unmasked server frame"
    // by decoding it manually into a new unmasked frame, then writing to a second pair.
    var raw: [64]u8 = undefined;
    const raw_len = try std.posix.read(fds[1], &raw);
    try std.testing.expect(raw_len >= 2);

    // Decode the masked client frame to get the payload.
    var payload_buf: [64]u8 = undefined;
    const parsed = zix.Http.WebSocket.parseFrame(raw[0..raw_len], &payload_buf);
    try std.testing.expect(parsed != null);
    try std.testing.expectEqualStrings("world", parsed.?.frame.payload);
}

test "zix integration: WsConn.recv reads an unmasked server frame" {
    const fds = try makePair();
    defer closefd(fds[0]);
    defer closefd(fds[1]);

    // Build an unmasked server-to-client frame using the existing WS helper.
    var frame_buf: [32]u8 = undefined;
    const frame_len = zix.Http.WebSocket.buildFrame(&frame_buf, .text, "ping");

    _ = std.posix.system.write(fds[1], frame_buf[0..frame_len].ptr, frame_len);

    const conn = zix.Http.WsConn{ .fd = fds[0] };
    var payload_buf: [64]u8 = undefined;
    const frame = try conn.recv(&payload_buf);

    try std.testing.expect(frame != null);
    try std.testing.expectEqual(zix.Http.WsOpcode.text, frame.?.opcode);
    try std.testing.expectEqualStrings("ping", frame.?.payload);
}

test "zix integration: WsConn.recv returns null on clean EOF before frame" {
    const fds = try makePair();
    defer closefd(fds[0]);

    closefd(fds[1]);

    const conn = zix.Http.WsConn{ .fd = fds[0] };
    var payload_buf: [64]u8 = undefined;
    const frame = try conn.recv(&payload_buf);

    try std.testing.expectEqual(null, frame);
}
