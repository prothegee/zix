//! zix uds client

const std = @import("std");
const Config = @import("config.zig");
const UdsClientConfig = Config.UdsClientConfig;

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
        const ua = try std.Io.net.UnixAddress.init(config.path);
        const stream = try ua.connect(io);
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
        var wbuf: [4096]u8 = undefined;
        var wtr = self.stream.writer(io, &wbuf);

        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u32, &hdr, @intCast(msg.len), .little);
        try wtr.interface.writeAll(&hdr);
        try wtr.interface.writeAll(msg);
        try wtr.interface.flush();
    }

    /// Receive a length-prefixed frame into buf.
    ///
    /// Return:
    /// - payload slice on success
    /// - error.MessageTooLarge if the frame payload exceeds buf.len
    /// - error.ConnectionClosed if the server closed the connection
    pub fn recvMsg(self: *Self, io: std.Io, buf: []u8) ![]u8 {
        var rbuf: [4096]u8 = undefined;
        var rdr = self.stream.reader(io, &rbuf);

        var hdr: [4]u8 = undefined;
        var n: usize = 0;
        while (n < 4) {
            const got = rdr.interface.readSliceShort(hdr[n..]) catch return error.ConnectionClosed;
            if (got == 0) return error.ConnectionClosed;
            n += got;
        }

        const len = std.mem.readInt(u32, &hdr, .little);
        if (len > buf.len) return error.MessageTooLarge;

        n = 0;
        while (n < len) {
            const got = rdr.interface.readSliceShort(buf[n..len]) catch return error.ConnectionClosed;
            if (got == 0) return error.ConnectionClosed;
            n += got;
        }
        return buf[0..len];
    }
};
