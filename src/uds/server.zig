//! zix uds server

const std = @import("std");
const Config = @import("config.zig");
const UdsServerConfig = Config.UdsServerConfig;
const Logger = @import("../logger/logger.zig").Logger;

fn applyConnTimeout(sock_fd: std.posix.fd_t, recv_ms: u32, send_ms: u32) void {
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

/// UDS stream server. Accepts connections and dispatches each via io.concurrent.
///
/// Usage:
/// ```zig
/// var server = try UdsServer.init(config);
/// defer server.deinit();
/// try server.run(io, echoHandler);  // built-in echo handler
/// try server.run(io, myHandler);    // custom handler
/// ```
pub const UdsServer = struct {
    const Self = @This();

    config: UdsServerConfig,

    // --------------------------------------------------------- //

    /// Initialize the server.
    ///
    /// Return:
    /// - !Self
    /// - error.PathEmpty if config.path is empty
    pub fn init(config: UdsServerConfig) !Self {
        if (!std.Io.net.has_unix_sockets) @compileError("UDS not supported on this platform");
        if (config.path.len == 0) return error.PathEmpty;

        return .{ .config = config };
    }

    /// No-op: resources are released inside run() via defer.
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Listen and serve using a comptime handler.
    /// handler(stream, io) is called for each accepted connection.
    /// The handler owns stream and must call stream.close(io) before returning.
    pub fn run(self: *Self, io: std.Io, comptime handler: fn (std.Io.net.Stream, std.Io) void) !void {
        if (!std.Io.net.has_unix_sockets) @compileError("UDS not supported on this platform");

        // Remove stale socket from a previous run before binding.
        std.Io.Dir.deleteFileAbsolute(io, self.config.path) catch {};

        const unix_addr = try std.Io.net.UnixAddress.init(self.config.path);
        var net_server = try unix_addr.listen(io, .{ .kernel_backlog = self.config.backlog });
        defer {
            net_server.deinit(io);
            std.Io.Dir.deleteFileAbsolute(io, self.config.path) catch {};
        }

        if (self.config.logger) |lg| lg.system(.INFO, "uds", "listening on {s}", .{self.config.path});

        const ConnTask = struct {
            stream: std.Io.net.Stream,
            io: std.Io,
            logger: ?*Logger,
        };

        const dispatch = struct {
            fn call(task: ConnTask) void {
                if (task.logger) |lg| lg.system(.INFO, "uds", "connection accepted", .{});
                handler(task.stream, task.io);
            }
        }.call;

        while (true) {
            const stream = net_server.accept(io) catch |err| {
                if (self.config.logger) |lg| lg.system(.WARN, "uds", "accept error: {}", .{err});
                continue;
            };
            applyConnTimeout(stream.socket.handle, self.config.recv_timeout_ms, self.config.send_timeout_ms);

            const task = ConnTask{ .stream = stream, .io = io, .logger = self.config.logger };
            if (io.concurrent(dispatch, .{task})) |_| {} else |_| {
                dispatch(task);
            }
        }
    }
};

// --------------------------------------------------------- //

// Default handler: reads length-prefixed frames and echoes each back unchanged.
// Frame format: [u32 payload_len, 4 bytes, native LE] [payload bytes]
// Payloads larger than 4096 bytes close the connection.
pub fn echoHandler(stream: std.Io.net.Stream, io: std.Io) void {
    defer stream.close(io);

    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var payload_buf: [4096]u8 = undefined;

    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    while (true) {
        // Read 4-byte length header
        var hdr: [4]u8 = undefined;
        var n: usize = 0;
        while (n < 4) {
            const got = reader.interface.readSliceShort(hdr[n..]) catch return;
            if (got == 0) return;
            n += got;
        }

        const len = std.mem.readInt(u32, &hdr, .little);
        if (len > payload_buf.len) return;

        // Read payload
        n = 0;
        while (n < len) {
            const got = reader.interface.readSliceShort(payload_buf[n..len]) catch return;
            if (got == 0) return;
            n += got;
        }

        // Echo: header + payload
        writer.interface.writeAll(&hdr) catch return;
        writer.interface.writeAll(payload_buf[0..len]) catch return;
        writer.interface.flush() catch return;
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: UdsServer init, empty path returns PathEmpty" {
    try std.testing.expectError(
        error.PathEmpty,
        UdsServer.init(.{ .path = "", .allocator = std.testing.allocator }),
    );
}

test "zix test: UdsServer init, valid path succeeds" {
    var server = try UdsServer.init(.{ .path = "/tmp/zix_test.sock", .allocator = std.testing.allocator });
    server.deinit();
}

test "zix test: UdsServer init, timeout fields default to zero" {
    const server = try UdsServer.init(.{ .path = "/tmp/zix_test.sock", .allocator = std.testing.allocator });
    try std.testing.expectEqual(@as(u32, 0), server.config.recv_timeout_ms);
    try std.testing.expectEqual(@as(u32, 0), server.config.send_timeout_ms);
}

test "zix test: UdsServer init, timeout fields stored from config" {
    const server = try UdsServer.init(.{
        .path = "/tmp/zix_test.sock",
        .allocator = std.testing.allocator,
        .recv_timeout_ms = 5000,
        .send_timeout_ms = 3000,
    });
    try std.testing.expectEqual(@as(u32, 5000), server.config.recv_timeout_ms);
    try std.testing.expectEqual(@as(u32, 3000), server.config.send_timeout_ms);
}

test "zix test: applyConnTimeout uds, zero ms is no-op on real socket" {
    const linux = std.os.linux;
    const sock_fd: std.posix.fd_t = @intCast(linux.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0));
    try std.testing.expect(sock_fd > 0);
    defer _ = linux.close(sock_fd);

    applyConnTimeout(sock_fd, 0, 0);

    var recv_tv: std.posix.timeval = undefined;
    var opt_len: std.posix.socklen_t = @sizeOf(std.posix.timeval);
    _ = linux.getsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, @ptrCast(&recv_tv), &opt_len);
    try std.testing.expectEqual(@as(isize, 0), recv_tv.sec);
    try std.testing.expectEqual(@as(i64, 0), recv_tv.usec);
}

test "zix test: applyConnTimeout uds, sets SO_RCVTIMEO on real socket" {
    const linux = std.os.linux;
    const sock_fd: std.posix.fd_t = @intCast(linux.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0));
    try std.testing.expect(sock_fd > 0);
    defer _ = linux.close(sock_fd);

    applyConnTimeout(sock_fd, 2500, 0);

    var recv_tv: std.posix.timeval = undefined;
    var opt_len: std.posix.socklen_t = @sizeOf(std.posix.timeval);
    _ = linux.getsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, @ptrCast(&recv_tv), &opt_len);
    try std.testing.expectEqual(@as(isize, 2), recv_tv.sec);
    try std.testing.expectEqual(@as(i64, 500_000), recv_tv.usec);
}

test "zix test: applyConnTimeout uds, sets SO_SNDTIMEO on real socket" {
    const linux = std.os.linux;
    const sock_fd: std.posix.fd_t = @intCast(linux.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0));
    try std.testing.expect(sock_fd > 0);
    defer _ = linux.close(sock_fd);

    applyConnTimeout(sock_fd, 0, 1000);

    var send_tv: std.posix.timeval = undefined;
    var opt_len: std.posix.socklen_t = @sizeOf(std.posix.timeval);
    _ = linux.getsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, @ptrCast(&send_tv), &opt_len);
    try std.testing.expectEqual(@as(isize, 1), send_tv.sec);
    try std.testing.expectEqual(@as(i64, 0), send_tv.usec);
}
