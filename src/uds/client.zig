//! zix uds client

const std = @import("std");
const Config = @import("config.zig");
const UdsClientConfig = Config.UdsClientConfig;

/// Scratch buffer size backing the stream reader and writer for one framed message.
const STREAM_BUF_SIZE: usize = 4096;

// --------------------------------------------------------- //

/// Poll fd for the given event with a millisecond timeout.
///
/// Return:
/// - true when the event is ready
/// - false when the timeout elapsed first
fn pollReady(sock_fd: std.posix.fd_t, events: i16, timeout_ms: u32) !bool {
    var pfd = [1]std.posix.pollfd{.{ .fd = sock_fd, .events = events, .revents = 0 }};
    const ms: i32 = @intCast(@min(timeout_ms, @as(u32, std.math.maxInt(i32))));

    return try std.posix.poll(&pfd, ms) > 0;
}

// --------------------------------------------------------- //

/// UDS stream client.
///
/// Usage:
/// ```zig
/// var client = try UdsClient.connect(config, io);
/// defer client.deinit(io);
/// try client.sendMsg(io, "hello");
/// var buf: [4096]u8 = undefined;
/// const reply = try client.recvMsg(io, &buf);
/// ```
pub const UdsClient = struct {
    const Self = @This();

    stream: std.Io.net.Stream,
    config: UdsClientConfig,

    // --------------------------------------------------------- //

    /// Connect to the server at config.path.
    pub fn connect(config: UdsClientConfig, io: std.Io) !Self {
        if (!std.Io.net.has_unix_sockets) @compileError("UDS not supported on this platform");

        const unix_addr = try std.Io.net.UnixAddress.init(config.path);
        const stream = try unix_addr.connect(io);

        return .{ .stream = stream, .config = config };
    }

    /// Close the connection.
    pub fn deinit(self: *Self, io: std.Io) void {
        self.stream.close(io);
    }

    /// Send a message as a length-prefixed frame.
    /// Frame format: [u32 payload_len, 4 bytes, big-endian] [payload bytes]
    ///
    /// Return:
    /// - void on success
    /// - error.SendTimeout if send_timeout_ms is set and the socket is not writable in time
    pub fn sendMsg(self: *Self, io: std.Io, msg: []const u8) !void {
        if (self.config.send_timeout_ms > 0) {
            // std.Io.Threaded panics on EAGAIN, so use poll instead of SO_SNDTIMEO.
            if (!try pollReady(self.stream.socket.handle, std.posix.POLL.OUT, self.config.send_timeout_ms)) {
                return error.SendTimeout;
            }
        }

        var write_buf: [STREAM_BUF_SIZE]u8 = undefined;
        var writer = self.stream.writer(io, &write_buf);

        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u32, &hdr, @intCast(msg.len), .big);
        try writer.interface.writeAll(&hdr);
        try writer.interface.writeAll(msg);
        try writer.interface.flush();
    }

    /// Receive a length-prefixed frame into buf.
    ///
    /// Return:
    /// - payload slice on success
    /// - error.RecvTimeout if recv_timeout_ms is set and no data arrives in time
    /// - error.MessageTooLarge if the frame payload exceeds buf.len
    /// - error.ConnectionClosed if the server closed the connection
    pub fn recvMsg(self: *Self, io: std.Io, buf: []u8) ![]u8 {
        if (self.config.recv_timeout_ms > 0) {
            // std.Io.Threaded panics on EAGAIN, so use poll instead of SO_RCVTIMEO.
            if (!try pollReady(self.stream.socket.handle, std.posix.POLL.IN, self.config.recv_timeout_ms)) {
                return error.RecvTimeout;
            }
        }

        var read_buf: [STREAM_BUF_SIZE]u8 = undefined;
        var reader = self.stream.reader(io, &read_buf);

        var hdr: [4]u8 = undefined;
        var n: usize = 0;
        while (n < 4) {
            const got = reader.interface.readSliceShort(hdr[n..]) catch return error.ConnectionClosed;
            if (got == 0) return error.ConnectionClosed;
            n += got;
        }

        const len = std.mem.readInt(u32, &hdr, .big);
        if (len > buf.len) return error.MessageTooLarge;

        n = 0;
        while (n < len) {
            const got = reader.interface.readSliceShort(buf[n..len]) catch return error.ConnectionClosed;
            if (got == 0) return error.ConnectionClosed;
            n += got;
        }

        return buf[0..len];
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: UdsClient.sendMsg writes big-endian length header" {
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[1]);

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client = UdsClient{
        .stream = .{ .socket = .{ .handle = fds[0], .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } } } },
        .config = .{ .path = "/dev/null" },
    };
    defer _ = std.os.linux.close(fds[0]);

    try client.sendMsg(io, "hello");

    var wire: [9]u8 = undefined;
    const n: usize = @intCast(std.os.linux.read(fds[1], &wire, wire.len));

    try std.testing.expectEqual(@as(usize, 9), n);
    try std.testing.expectEqual(@as(u8, 0), wire[0]);
    try std.testing.expectEqual(@as(u8, 0), wire[1]);
    try std.testing.expectEqual(@as(u8, 0), wire[2]);
    try std.testing.expectEqual(@as(u8, 5), wire[3]);
    try std.testing.expectEqualSlices(u8, "hello", wire[4..9]);
}

test "zix test: UdsClient.recvMsg parses big-endian length header" {
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const frame = [_]u8{ 0, 0, 0, 5, 'w', 'o', 'r', 'l', 'd' };
    _ = std.os.linux.write(fds[1], &frame, frame.len);

    var client = UdsClient{
        .stream = .{ .socket = .{ .handle = fds[0], .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } } } },
        .config = .{ .path = "/dev/null" },
    };

    var buf: [32]u8 = undefined;
    const reply = try client.recvMsg(io, &buf);

    try std.testing.expectEqualSlices(u8, "world", reply);
}

test "zix test: UdsClient.recvMsg does not time out when data arrives immediately" {
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer {
        _ = std.os.linux.close(fds[0]);
        _ = std.os.linux.close(fds[1]);
    }

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const frame = [_]u8{ 0, 0, 0, 5, 'h', 'e', 'l', 'l', 'o' };
    _ = std.os.linux.write(fds[1], &frame, frame.len);

    var client = UdsClient{
        .stream = .{ .socket = .{ .handle = fds[0], .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } } } },
        .config = .{ .path = "/dev/null", .recv_timeout_ms = 50 },
    };

    var buf: [8]u8 = undefined;
    const reply = try client.recvMsg(io, &buf);
    try std.testing.expectEqualSlices(u8, "hello", reply);
}

test "zix test: UdsClient.recvMsg returns error.RecvTimeout when nothing arrives" {
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer {
        _ = std.os.linux.close(fds[0]);
        _ = std.os.linux.close(fds[1]);
    }

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client = UdsClient{
        .stream = .{ .socket = .{ .handle = fds[0], .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } } } },
        .config = .{ .path = "/dev/null", .recv_timeout_ms = 50 },
    };

    var buf: [8]u8 = undefined;
    try std.testing.expectError(error.RecvTimeout, client.recvMsg(io, &buf));
}

test "zix test: UdsClient.sendMsg succeeds within send_timeout_ms when the peer drains" {
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer {
        _ = std.os.linux.close(fds[0]);
        _ = std.os.linux.close(fds[1]);
    }

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client = UdsClient{
        .stream = .{ .socket = .{ .handle = fds[0], .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } } } },
        .config = .{ .path = "/dev/null", .send_timeout_ms = 50 },
    };

    try client.sendMsg(io, "hello");

    var wire: [9]u8 = undefined;
    const n: usize = @intCast(std.os.linux.read(fds[1], &wire, wire.len));
    try std.testing.expectEqual(@as(usize, 9), n);
}

test "zix test: UdsClient.sendMsg returns error.SendTimeout when the peer's buffer is full" {
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer {
        _ = std.os.linux.close(fds[0]);
        _ = std.os.linux.close(fds[1]);
    }

    // Fill fds[0]'s send buffer so poll(POLLOUT) reports not-ready: switch to
    // non-blocking, write until the kernel refuses more (the peer never
    // reads), then restore blocking mode for the client under test.
    const linux = std.os.linux;
    const flags = linux.fcntl(fds[0], std.posix.F.GETFL, 0);
    const nonblock_bit: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = linux.fcntl(fds[0], std.posix.F.SETFL, flags | @as(usize, nonblock_bit));

    var chunk: [4096]u8 = undefined;
    while (std.posix.errno(linux.write(fds[0], &chunk, chunk.len)) == .SUCCESS) {}

    _ = linux.fcntl(fds[0], std.posix.F.SETFL, flags);

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client = UdsClient{
        .stream = .{ .socket = .{ .handle = fds[0], .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } } } },
        .config = .{ .path = "/dev/null", .send_timeout_ms = 50 },
    };

    try std.testing.expectError(error.SendTimeout, client.sendMsg(io, "hello"));
}
