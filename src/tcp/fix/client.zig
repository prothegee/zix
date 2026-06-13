//! zix fix client: FIX 4.x session client.

const std = @import("std");
const core = @import("core.zig");
const FixClientConfig = @import("config.zig").FixClientConfig;

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

/// FIX 4.x session client.
///
/// Usage:
/// ```zig
/// var client = try FixClient.connect(.{
///     .ip = "127.0.0.1", .port = 9500,
///     .comp_id = "CLIENT", .target_comp_id = "SERVER",
/// }, io);
/// defer client.deinit(io);
/// try client.logon(io, 30);
/// try client.sendMessage(io, "D", &extra_fields);
/// const raw = try client.recvMessage(io);
/// try client.logout(io);
/// ```
pub const FixClient = struct {
    const Self = @This();

    stream: std.Io.net.Stream,
    comp_id: []const u8,
    target_comp_id: []const u8,
    seq_out: u32,
    recv_buf: [core.MAX_MSG_SIZE * 2]u8,
    recv_len: usize,
    recv_timeout_ms: u32,

    // --------------------------------------------------------- //

    /// Connect to a FIX server.
    ///
    /// Return:
    /// - error.PortNotConfigured if config.port is 0
    pub fn connect(config: FixClientConfig, io: std.Io) !Self {
        if (config.port == 0) return error.PortNotConfigured;

        const addr = try std.Io.net.IpAddress.resolve(io, config.ip, config.port);
        const stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });

        return .{
            .stream = stream,
            .comp_id = config.comp_id,
            .target_comp_id = config.target_comp_id,
            .seq_out = 1,
            .recv_buf = undefined,
            .recv_len = 0,
            .recv_timeout_ms = config.recv_timeout_ms,
        };
    }

    /// Close the TCP connection.
    pub fn deinit(self: *Self, io: std.Io) void {
        self.stream.close(io);
    }

    // --------------------------------------------------------- //

    /// Send Logon (35=A) and wait for the server's Logon response.
    /// heart_bt_int: HeartBtInt value in seconds (tag 108).
    pub fn logon(self: *Self, io: std.Io, heart_bt_int: u16) !void {
        var hbt_buf: [8]u8 = undefined;
        const hbt_str = std.fmt.bufPrint(&hbt_buf, "{d}", .{heart_bt_int}) catch return error.InvalidHeartbeatInterval;
        const extra = [_]core.BuildField{
            .{ .tag = .EncryptMethod, .value = "0" },
            .{ .tag = .HeartBtInt, .value = hbt_str },
        };

        try self.sendMessage(io, core.MsgType.Logon, &extra);

        const raw = try self.recvMessage(io);
        var fields: [core.MAX_FIELDS]core.Field = undefined;
        const field_count = try core.parseFields(raw, &fields);
        const msg_type = core.getField(fields[0..field_count], .MsgType) orelse return error.MissingMsgType;
        if (!std.mem.eql(u8, msg_type, core.MsgType.Logon)) return error.ExpectedLogon;
    }

    /// Send Logout (35=5) and wait for the server's Logout response.
    pub fn logout(self: *Self, io: std.Io) !void {
        try self.sendMessage(io, core.MsgType.Logout, &.{});

        const raw = try self.recvMessage(io);
        var fields: [core.MAX_FIELDS]core.Field = undefined;
        const field_count = try core.parseFields(raw, &fields);
        const msg_type = core.getField(fields[0..field_count], .MsgType) orelse return error.MissingMsgType;
        if (!std.mem.eql(u8, msg_type, core.MsgType.Logout)) return error.ExpectedLogout;
    }

    /// Build and send a FIX message. Increments the outgoing sequence number.
    pub fn sendMessage(self: *Self, io: std.Io, msg_type: []const u8, extra: []const core.BuildField) !void {
        var out_buf: [core.MAX_MSG_SIZE]u8 = undefined;
        const n = try core.buildMessage(&out_buf, self.comp_id, self.target_comp_id, self.seq_out, msg_type, extra);
        self.seq_out += 1;

        var wr_buf: [core.MAX_MSG_SIZE]u8 = undefined;
        var writer = self.stream.writer(io, &wr_buf);
        try writer.interface.writeAll(out_buf[0..n]);
        try writer.interface.flush();
    }

    /// Receive the next complete FIX message.
    ///
    /// Return:
    /// - slice into the internal buffer (valid until the next recvMessage call)
    /// - error.RecvTimeout if recv_timeout_ms is set and no data arrives in time
    /// - error.ConnectionClosed if the peer closes the connection before a full message arrives
    pub fn recvMessage(self: *Self, io: std.Io) ![]const u8 {
        _ = io;
        const fd = self.stream.socket.handle;

        while (true) {
            if (core.findMessageEnd(self.recv_buf[0..self.recv_len])) |end| {
                const msg = self.recv_buf[0..end];
                const remaining = self.recv_len - end;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, self.recv_buf[0..remaining], self.recv_buf[end..self.recv_len]);
                }
                self.recv_len = remaining;
                return msg;
            }

            if (self.recv_len >= self.recv_buf.len) return error.MessageTooLarge;

            if (self.recv_timeout_ms > 0) {
                var pfd = [1]std.posix.pollfd{.{
                    .fd = fd,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                }};
                const ms: i32 = @intCast(@min(self.recv_timeout_ms, @as(u32, std.math.maxInt(i32))));
                const ready = try std.posix.poll(&pfd, ms);
                if (ready == 0) return error.RecvTimeout;
            }

            const n = try std.posix.read(fd, self.recv_buf[self.recv_len..]);
            if (n == 0) return error.ConnectionClosed;
            self.recv_len += n;
        }
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix fix: FixClient.connect port zero returns PortNotConfigured" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expectError(
        error.PortNotConfigured,
        FixClient.connect(.{
            .ip = "127.0.0.1",
            .port = 0,
            .comp_id = "CLIENT",
            .target_comp_id = "SERVER",
        }, io),
    );
}

test "zix test: applySocketTimeout fix, zero ms is a no-op on real socket" {
    const linux = std.os.linux;
    const sock_fd: std.posix.fd_t = @intCast(linux.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0));
    try std.testing.expect(sock_fd > 0);
    defer _ = linux.close(sock_fd);

    applySocketTimeout(sock_fd, 0, 0);

    var recv_tv: std.posix.timeval = undefined;
    var opt_len: std.posix.socklen_t = @sizeOf(std.posix.timeval);
    _ = linux.getsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, @ptrCast(&recv_tv), &opt_len);
    try std.testing.expectEqual(@as(isize, 0), recv_tv.sec);
    try std.testing.expectEqual(@as(i64, 0), recv_tv.usec);
}

test "zix test: applySocketTimeout fix, sets SO_RCVTIMEO on real socket" {
    const linux = std.os.linux;
    const sock_fd: std.posix.fd_t = @intCast(linux.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0));
    try std.testing.expect(sock_fd > 0);
    defer _ = linux.close(sock_fd);

    applySocketTimeout(sock_fd, 1500, 0);

    var recv_tv: std.posix.timeval = undefined;
    var opt_len: std.posix.socklen_t = @sizeOf(std.posix.timeval);
    _ = linux.getsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, @ptrCast(&recv_tv), &opt_len);
    try std.testing.expectEqual(@as(isize, 1), recv_tv.sec);
    try std.testing.expectEqual(@as(i64, 500_000), recv_tv.usec);
}

test "zix fix: FixClient.recvMessage reassembles message split across two reads" {
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(
        @as(usize, 0),
        std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds),
    );
    defer {
        _ = std.os.linux.close(fds[0]);
        _ = std.os.linux.close(fds[1]);
    }

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var out_buf: [core.MAX_MSG_SIZE]u8 = undefined;
    const extra = [_]core.BuildField{
        .{ .tag = .EncryptMethod, .value = "0" },
        .{ .tag = .HeartBtInt, .value = "30" },
    };
    const msg_len = try core.buildMessage(&out_buf, "SERVER", "CLIENT", 1, core.MsgType.Logon, &extra);
    const full_msg = out_buf[0..msg_len];

    const half = msg_len / 2;

    var client = FixClient{
        .stream = .{ .socket = .{
            .handle = fds[0],
            .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } },
        } },
        .comp_id = "CLIENT",
        .target_comp_id = "SERVER",
        .seq_out = 1,
        .recv_buf = undefined,
        .recv_len = 0,
        .recv_timeout_ms = 0,
    };
    @memcpy(client.recv_buf[0..half], full_msg[0..half]);
    client.recv_len = half;

    _ = std.os.linux.write(fds[1], full_msg[half..].ptr, msg_len - half);

    const msg = try client.recvMessage(io);

    try std.testing.expectEqualSlices(u8, full_msg, msg);
}

test "zix test: applySocketTimeout fix, short timeout does not fire when data arrives immediately" {
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    defer {
        _ = std.os.linux.close(fds[0]);
        _ = std.os.linux.close(fds[1]);
    }

    applySocketTimeout(fds[0], 50, 0);

    const written: usize = @intCast(std.os.linux.write(fds[1], "ping".ptr, 4));
    try std.testing.expectEqual(@as(usize, 4), written);

    var buf: [8]u8 = undefined;
    const n: usize = @intCast(std.os.linux.read(fds[0], &buf, buf.len));
    try std.testing.expect(n > 0);
    try std.testing.expectEqualSlices(u8, "ping", buf[0..n]);
}
