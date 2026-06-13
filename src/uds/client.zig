//! zix uds client

const std = @import("std");
const Config = @import("config.zig");
const UdsClientConfig = Config.UdsClientConfig;

// --------------------------------------------------------- //

fn applySocketTimeout(sock_fd: std.posix.fd_t, recv_ms: u32, send_ms: u32) void {
    if (recv_ms == 0 and send_ms == 0) return;

    if (recv_ms > 0) {
        const recv_tv = std.posix.timeval{ .sec = @intCast(recv_ms / 1000), .usec = @intCast((recv_ms % 1000) * 1000) };
        std.posix.setsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&recv_tv)) catch {};
    }

    if (send_ms > 0) {
        const send_tv = std.posix.timeval{ .sec = @intCast(send_ms / 1000), .usec = @intCast((send_ms % 1000) * 1000) };
        std.posix.setsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&send_tv)) catch {};
    }
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

        std.debug.print("zix uds client: connected to {s}\n", .{config.path});

        return .{ .stream = stream, .config = config };
    }

    /// Close the connection.
    pub fn deinit(self: *Self, io: std.Io) void {
        self.stream.close(io);
    }

    /// Send a message as a length-prefixed frame.
    /// Frame format: [u32 payload_len, 4 bytes, native LE] [payload bytes]
    pub fn sendMsg(self: *Self, io: std.Io, msg: []const u8) !void {
        var write_buf: [4096]u8 = undefined;
        var writer = self.stream.writer(io, &write_buf);

        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u32, &hdr, @intCast(msg.len), .little);
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
            var pfd = [1]std.posix.pollfd{.{
                .fd = self.stream.socket.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            const ms: i32 = @intCast(@min(self.config.recv_timeout_ms, @as(u32, std.math.maxInt(i32))));
            const ready = try std.posix.poll(&pfd, ms);
            if (ready == 0) return error.RecvTimeout;
        }

        var read_buf: [4096]u8 = undefined;
        var reader = self.stream.reader(io, &read_buf);

        var hdr: [4]u8 = undefined;
        var n: usize = 0;
        while (n < 4) {
            const got = reader.interface.readSliceShort(hdr[n..]) catch return error.ConnectionClosed;
            if (got == 0) return error.ConnectionClosed;
            n += got;
        }

        const len = std.mem.readInt(u32, &hdr, .little);
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

test "zix test: applySocketTimeout uds, zero ms is a no-op on real socket" {
    const linux = std.os.linux;
    const sock_fd: std.posix.fd_t = @intCast(linux.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0));
    try std.testing.expect(sock_fd > 0);
    defer _ = linux.close(sock_fd);

    applySocketTimeout(sock_fd, 0, 0);

    var recv_tv: std.posix.timeval = undefined;
    var opt_len: std.posix.socklen_t = @sizeOf(std.posix.timeval);
    _ = linux.getsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, @ptrCast(&recv_tv), &opt_len);
    try std.testing.expectEqual(@as(isize, 0), recv_tv.sec);
    try std.testing.expectEqual(@as(i64, 0), recv_tv.usec);
}

test "zix test: applySocketTimeout uds, sets SO_RCVTIMEO on real socket" {
    const linux = std.os.linux;
    const sock_fd: std.posix.fd_t = @intCast(linux.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0));
    try std.testing.expect(sock_fd > 0);
    defer _ = linux.close(sock_fd);

    applySocketTimeout(sock_fd, 2500, 0);

    var recv_tv: std.posix.timeval = undefined;
    var opt_len: std.posix.socklen_t = @sizeOf(std.posix.timeval);
    _ = linux.getsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, @ptrCast(&recv_tv), &opt_len);
    try std.testing.expectEqual(@as(isize, 2), recv_tv.sec);
    try std.testing.expectEqual(@as(i64, 500_000), recv_tv.usec);
}

test "zix test: applySocketTimeout uds, sets SO_SNDTIMEO on real socket" {
    const linux = std.os.linux;
    const sock_fd: std.posix.fd_t = @intCast(linux.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0));
    try std.testing.expect(sock_fd > 0);
    defer _ = linux.close(sock_fd);

    applySocketTimeout(sock_fd, 0, 1000);

    var send_tv: std.posix.timeval = undefined;
    var opt_len: std.posix.socklen_t = @sizeOf(std.posix.timeval);
    _ = linux.getsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, @ptrCast(&send_tv), &opt_len);
    try std.testing.expectEqual(@as(isize, 1), send_tv.sec);
    try std.testing.expectEqual(@as(i64, 0), send_tv.usec);
}

test "zix test: applySocketTimeout uds, short timeout does not fire when data arrives immediately" {
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer {
        _ = std.os.linux.close(fds[0]);
        _ = std.os.linux.close(fds[1]);
    }

    applySocketTimeout(fds[0], 50, 0);

    const written: usize = @intCast(std.os.linux.write(fds[1], "hello".ptr, 5));
    try std.testing.expectEqual(@as(usize, 5), written);

    var buf: [8]u8 = undefined;
    const n: usize = @intCast(std.os.linux.read(fds[0], &buf, buf.len));
    try std.testing.expect(n > 0);
    try std.testing.expectEqualSlices(u8, "hello", buf[0..n]);
}
