//! zix fix client — FIX 4.x session client.

const std = @import("std");
const core = @import("core.zig");
const FixClientConfig = @import("config.zig").FixClientConfig;

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
        const nf = try core.parseFields(raw, &fields);
        const msg_type = core.getField(fields[0..nf], .MsgType) orelse return error.MissingMsgType;
        if (!std.mem.eql(u8, msg_type, core.MsgType.Logon)) return error.ExpectedLogon;
    }

    /// Send Logout (35=5) and wait for the server's Logout response.
    pub fn logout(self: *Self, io: std.Io) !void {
        try self.sendMessage(io, core.MsgType.Logout, &.{});
        const raw = try self.recvMessage(io);
        var fields: [core.MAX_FIELDS]core.Field = undefined;
        const nf = try core.parseFields(raw, &fields);
        const msg_type = core.getField(fields[0..nf], .MsgType) orelse return error.MissingMsgType;
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
    pub fn recvMessage(self: *Self, io: std.Io) ![]const u8 {
        var rd_buf: [core.MAX_MSG_SIZE]u8 = undefined;
        var reader = self.stream.reader(io, &rd_buf);
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
            const b = try reader.interface.takeByte();
            self.recv_buf[self.recv_len] = b;
            self.recv_len += 1;
        }
    }
};

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
