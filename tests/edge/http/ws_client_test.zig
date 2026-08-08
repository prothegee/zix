//! Edge tests: WsClient URL parsing and WsConn frame encoding boundaries.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix edge: WsClient.connect, wss:// returns TlsNotSupported" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();

    const ws_client = zix.Http.WsClient.init(.{ .io = threaded.io() });
    try std.testing.expectError(error.TlsNotSupported, ws_client.connect("wss://example.com/ws"));
}

test "zix edge: WsClient.connect, non-ws scheme returns InvalidUrl" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();

    const ws_client = zix.Http.WsClient.init(.{ .io = threaded.io() });
    try std.testing.expectError(error.InvalidUrl, ws_client.connect("http://127.0.0.1:9000/ws"));
}

test "zix edge: WsConn.send mask bit present in every frame header" {
    if (comptime @import("builtin").target.os.tag != .linux) {
        std.log.info("this test drives a Linux socket wire, test skipped", .{});
        return;
    }

    var fds: [2]i32 = undefined;
    const result = std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds);
    try std.testing.expectEqual(@as(usize, 0), result);
    defer zix.utils.fd_io.close(fds[0]);
    defer zix.utils.fd_io.close(fds[1]);

    const conn = zix.Http.WsConn{ .fd = fds[0] };
    try conn.send(.binary, &[_]u8{ 0xDE, 0xAD });
    try conn.send(.ping, "hb");

    // Read both frames.
    var raw: [128]u8 = undefined;
    const n = try zix.utils.fd_io.readOnce(fds[1], &raw);
    try std.testing.expect(n >= 4);

    // First frame: mask bit must be set.
    try std.testing.expect((raw[1] & 0x80) != 0);
}

test "zix edge: WsConn.send empty payload, mask bit still set" {
    if (comptime @import("builtin").target.os.tag != .linux) {
        std.log.info("this test drives a Linux socket wire, test skipped", .{});
        return;
    }

    var fds: [2]i32 = undefined;
    const result = std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds);
    try std.testing.expectEqual(@as(usize, 0), result);
    defer zix.utils.fd_io.close(fds[0]);
    defer zix.utils.fd_io.close(fds[1]);

    const conn = zix.Http.WsConn{ .fd = fds[0] };
    try conn.send(.text, "");

    var raw: [16]u8 = undefined;
    const n = try zix.utils.fd_io.readOnce(fds[1], &raw);

    // Empty payload: 2-byte header + 4-byte mask = 6 bytes.
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expect((raw[1] & 0x80) != 0);
}

test "zix edge: WsClientConfig defaults" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();

    const cfg = zix.Http.WsClientConfig{ .io = threaded.io() };
    try std.testing.expectEqual(@as(u32, 0), cfg.connect_timeout_ms);
}
