//! zix tcp client

const std = @import("std");
const Config = @import("config.zig");
const TcpClientConfig = Config.TcpClientConfig;

// --------------------------------------------------------- //

/// TCP stream client.
///
/// Usage:
///   var client = try TcpClient.connect(config, io);
///   defer client.deinit(io);
///   try client.sendMsg(io, "hello");
///   var buf: [4096]u8 = undefined;
///   const reply = try client.recvMsg(io, &buf);
pub const TcpClient = struct {
    const Self = @This();

    stream: std.Io.net.Stream,
    config: TcpClientConfig,

    // --------------------------------------------------------- //

    /// Connect to the server at config.ip:config.port.
    /// Returns error.PortNotConfigured if config.port is 0.
    pub fn connect(config: TcpClientConfig, io: std.Io) !Self {
        if (config.port == 0) return error.PortNotConfigured;
        const addr = try std.Io.net.IpAddress.resolve(io, config.ip, config.port);
        const stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
        std.debug.print("zix tcp client: connected to {s}:{d}\n", .{ config.ip, config.port });
        return .{ .stream = stream, .config = config };
    }

    /// Connect with CLI arg overrides for --ip and --port.
    /// Falls back to config defaults when args are absent.
    pub fn connectArgs(config: TcpClientConfig, io: std.Io, args: anytype) !Self {
        var cfg = config;
        var it = std.process.Args.Iterator.init(args);
        _ = it.skip();
        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--ip")) {
                if (it.next()) |val| cfg.ip = val;
            } else if (std.mem.eql(u8, arg, "--port")) {
                if (it.next()) |val| cfg.port = std.fmt.parseInt(u16, val, 10) catch cfg.port;
            }
        }
        return Self.connect(cfg, io);
    }

    /// Close the connection.
    pub fn deinit(self: *Self, io: std.Io) void {
        self.stream.close(io);
    }

    /// Send a message as a length-prefixed frame.
    /// Frame format: [u32 payload_len, 4 bytes, big-endian] [payload bytes]
    /// Returns error.MessageTooLarge if msg.len exceeds config.max_msg_len.
    pub fn sendMsg(self: *Self, io: std.Io, msg: []const u8) !void {
        if (msg.len > self.config.max_msg_len) return error.MessageTooLarge;
        var wbuf: [4096 + 4]u8 = undefined;
        var wtr = self.stream.writer(io, &wbuf);
        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u32, &hdr, @intCast(msg.len), .big);
        try wtr.interface.writeAll(&hdr);
        try wtr.interface.writeAll(msg);
        try wtr.interface.flush();
    }

    /// Receive a length-prefixed frame into buf. Returns the payload slice.
    /// Returns error.MessageTooLarge if the frame payload exceeds buf.len.
    /// Returns error.ConnectionClosed if the server closed the connection.
    pub fn recvMsg(self: *Self, io: std.Io, buf: []u8) ![]u8 {
        var rbuf: [4096 + 4]u8 = undefined;
        var rdr = self.stream.reader(io, &rbuf);
        const len = rdr.interface.takeVarInt(u32, .big, 4) catch return error.ConnectionClosed;
        if (len > buf.len) return error.MessageTooLarge;
        rdr.interface.readSliceAll(buf[0..len]) catch return error.ConnectionClosed;
        return buf[0..len];
    }
};
