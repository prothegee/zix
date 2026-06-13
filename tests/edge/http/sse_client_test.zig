//! Edge tests: SseStream boundary conditions and SSE field parsing edge cases.

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

test "zix edge: SseStream.next skips comment lines" {
    const fds = try makePair();
    defer closefd(fds[0]);
    defer closefd(fds[1]);

    // Comment before the actual event.
    _ = std.posix.system.write(fds[1], ": keepalive\ndata: real\n\n", ": keepalive\ndata: real\n\n".len);

    var stream = zix.Http.SseStream{
        .fd = fds[0],
        .read_buf = undefined,
        .read_len = 0,
        .read_pos = 0,
    };

    var buf: [256]u8 = undefined;
    const event = try stream.next(&buf);

    try std.testing.expect(event != null);
    try std.testing.expectEqualStrings("real", event.?.data);
}

test "zix edge: SseStream.next skips empty dispatch before first data" {
    const fds = try makePair();
    defer closefd(fds[0]);
    defer closefd(fds[1]);

    // Empty dispatch (blank line before any field), then a real event.
    _ = std.posix.system.write(fds[1], "\ndata: second\n\n", "\ndata: second\n\n".len);

    var stream = zix.Http.SseStream{
        .fd = fds[0],
        .read_buf = undefined,
        .read_len = 0,
        .read_pos = 0,
    };

    var buf: [256]u8 = undefined;
    const event = try stream.next(&buf);

    try std.testing.expect(event != null);
    try std.testing.expectEqualStrings("second", event.?.data);
}

test "zix edge: SseStream.next retry field with invalid value is null" {
    const fds = try makePair();
    defer closefd(fds[0]);
    defer closefd(fds[1]);

    _ = std.posix.system.write(fds[1], "retry: notanumber\ndata: x\n\n", "retry: notanumber\ndata: x\n\n".len);

    var stream = zix.Http.SseStream{
        .fd = fds[0],
        .read_buf = undefined,
        .read_len = 0,
        .read_pos = 0,
    };

    var buf: [256]u8 = undefined;
    const event = try stream.next(&buf);

    try std.testing.expect(event != null);
    try std.testing.expectEqual(null, event.?.retry);
}

test "zix edge: SseStream.next data line with no colon value is empty string" {
    const fds = try makePair();
    defer closefd(fds[0]);
    defer closefd(fds[1]);

    _ = std.posix.system.write(fds[1], "data:\n\n", "data:\n\n".len);

    var stream = zix.Http.SseStream{
        .fd = fds[0],
        .read_buf = undefined,
        .read_len = 0,
        .read_pos = 0,
    };

    var buf: [256]u8 = undefined;
    const event = try stream.next(&buf);

    try std.testing.expect(event != null);
    try std.testing.expectEqualStrings("", event.?.data);
}

test "zix edge: SseClientConfig defaults" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();

    const cfg = zix.Http.SseClientConfig{ .io = threaded.io() };
    try std.testing.expectEqual(@as(u32, 0), cfg.connect_timeout_ms);
}

test "zix edge: SseClient.open, https:// returns TlsNotSupported" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();

    const client = zix.Http.SseClient.init(.{ .io = threaded.io() });
    try std.testing.expectError(error.TlsNotSupported, client.open("https://example.com/events"));
}

test "zix edge: SseClient.open, non-http scheme returns InvalidUrl" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();

    const client = zix.Http.SseClient.init(.{ .io = threaded.io() });
    try std.testing.expectError(error.InvalidUrl, client.open("ftp://example.com/events"));
}
