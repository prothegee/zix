//! gRPC h2c client — unary and streaming calls.

const std = @import("std");
const h2 = @import("../Http2.zig");
const frm = @import("frame.zig");
const status_mod = @import("status.zig");
const GrpcClientConfig = @import("config.zig").GrpcClientConfig;

pub const GrpcStatus = status_mod.GrpcStatus;

// --------------------------------------------------------- //

/// Response event returned by recvResponse().
pub const GrpcClientResponse = union(enum) {
    data: []const u8,
    status: GrpcStatus,
};

// --------------------------------------------------------- //

/// gRPC h2c client. One TCP connection, sequential calls.
///
/// Usage:
/// ```zig
/// var client = try GrpcClient.connect(.{ .ip = "127.0.0.1", .port = 8083 }, io);
/// defer client.deinit();
/// const data = try client.unary("/pkg.Svc/Method", "application/grpc+proto", req, &buf);
/// ```
pub const GrpcClient = struct {
    const Self = @This();

    fd: std.posix.fd_t,
    next_sid: u31,
    hdec: h2.HpackDecoder,
    hdec_scratch: [4096]u8,
    resp_hdrs: [h2.MAX_HEADERS]h2.Header,
    resp_hdr_count: usize,
    payload_scratch: [65536 + 256]u8,

    // --------------------------------------------------------- //

    /// Connect to a gRPC h2c server and perform the HTTP/2 preface exchange.
    ///
    /// Return:
    /// - !Self
    /// - error.PortNotConfigured if config.port is 0
    pub fn connect(config: GrpcClientConfig, io: std.Io) !Self {
        if (config.port == 0) return error.PortNotConfigured;
        const addr = try std.Io.net.IpAddress.resolve(io, config.ip, config.port);
        const stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
        const fd = stream.socket.handle;

        if (comptime @import("builtin").target.os.tag != .windows) {
            std.posix.setsockopt(
                fd,
                std.posix.IPPROTO.TCP,
                std.posix.TCP.NODELAY,
                std.mem.asBytes(&@as(c_int, 1)),
            ) catch {};
        }

        try h2.fdWriteAll(fd, h2.PREFACE);
        try h2.sendSettings(fd, &.{
            .{ h2.SETTINGS_INITIAL_WINDOW_SIZE, 65535 },
            .{ h2.SETTINGS_MAX_FRAME_SIZE, 16384 },
        });

        return .{
            .fd = fd,
            .next_sid = 1,
            .hdec = h2.HpackDecoder.init(),
            .hdec_scratch = undefined,
            .resp_hdrs = undefined,
            .resp_hdr_count = 0,
            .payload_scratch = undefined,
        };
    }

    /// Close the underlying TCP connection.
    pub fn deinit(self: *Self) void {
        _ = std.posix.system.close(self.fd);
    }

    // --------------------------------------------------------- //

    /// Open a new h2 stream and send the initial gRPC request headers.
    ///
    /// Return:
    /// - !u31 (stream ID for subsequent sendMessage / recvResponse calls)
    pub fn openStream(self: *Self, path: []const u8, content_type: []const u8) !u31 {
        const sid = self.next_sid;
        self.next_sid += 2;

        var hbuf: [512]u8 = undefined;
        var enc = h2.HpackEncoder.init(&hbuf);
        try enc.writeHeader(":method", "POST");
        try enc.writeHeader(":path", path);
        try enc.writeHeader(":scheme", "http");
        try enc.writeHeader(":authority", "grpc");
        try enc.writeHeader("content-type", content_type);
        try enc.writeHeader("te", "trailers");
        const hblock = enc.encoded();

        try h2.writeFrameHeader(self.fd, .{
            .length = @intCast(hblock.len),
            .frame_type = h2.FT_HEADERS,
            .flags = h2.FLAG_END_HEADERS,
            .stream_id = sid,
        });
        try h2.fdWriteAll(self.fd, hblock);
        return sid;
    }

    /// Send one gRPC message on a stream. Does not set END_STREAM.
    pub fn sendMessage(self: *Self, sid: u31, data: []const u8) !void {
        var prefix: [5]u8 = undefined;
        frm.writeGrpcPrefix(&prefix, false, @intCast(data.len));
        try h2.writeFrameHeader(self.fd, .{
            .length = @intCast(5 + data.len),
            .frame_type = h2.FT_DATA,
            .flags = 0,
            .stream_id = sid,
        });
        try h2.fdWriteAll(self.fd, &prefix);
        try h2.fdWriteAll(self.fd, data);
    }

    /// Half-close the stream from the client side (empty DATA with END_STREAM).
    pub fn endStream(self: *Self, sid: u31) !void {
        try h2.writeFrameHeader(self.fd, .{
            .length = 0,
            .frame_type = h2.FT_DATA,
            .flags = h2.FLAG_END_STREAM,
            .stream_id = sid,
        });
    }

    // --------------------------------------------------------- //

    /// Receive the next event on the specified stream.
    /// Handles SETTINGS, WINDOW_UPDATE, and PING frames transparently.
    ///
    /// Return:
    /// - !GrpcClientResponse (.data for each gRPC response message, .status for the trailer)
    pub fn recvResponse(self: *Self, sid: u31, buf: []u8) !GrpcClientResponse {
        while (true) {
            const fh = try h2.readFrameHeader(self.fd);
            if (fh.length > self.payload_scratch.len) return error.FrameTooLarge;
            const payload = self.payload_scratch[0..fh.length];
            if (fh.length > 0) try h2.recvExact(self.fd, payload);

            switch (fh.frame_type) {
                h2.FT_SETTINGS => {
                    if ((fh.flags & h2.FLAG_ACK) == 0) try h2.sendSettingsAck(self.fd);
                },
                h2.FT_WINDOW_UPDATE => {},
                h2.FT_PING => {
                    if ((fh.flags & h2.FLAG_ACK) == 0) {
                        var p8: [8]u8 = undefined;
                        @memcpy(&p8, payload[0..8]);
                        try h2.sendPingAck(self.fd, p8);
                    }
                },
                h2.FT_HEADERS => {
                    if (fh.stream_id != sid) continue;
                    self.resp_hdr_count = try self.hdec.decode(
                        payload,
                        &self.resp_hdrs,
                        &self.hdec_scratch,
                    );
                    for (self.resp_hdrs[0..self.resp_hdr_count]) |hdr| {
                        if (std.mem.eql(u8, hdr.name, "grpc-status")) {
                            const code = std.fmt.parseInt(u8, hdr.value, 10) catch 2;
                            return .{ .status = @enumFromInt(code) };
                        }
                    }
                    if ((fh.flags & h2.FLAG_END_STREAM) != 0)
                        return .{ .status = GrpcStatus.OK };
                },
                h2.FT_DATA => {
                    if (fh.stream_id != sid) continue;
                    if (payload.len < 5) return error.TooShort;
                    const msg_len = std.mem.readInt(u32, payload[1..5], .big);
                    const msg_end = 5 + @as(usize, msg_len);
                    if (msg_end > payload.len) return error.TruncatedMessage;
                    const msg = payload[5..msg_end];
                    const to_copy = @min(msg.len, buf.len);
                    @memcpy(buf[0..to_copy], msg[0..to_copy]);
                    if ((fh.flags & h2.FLAG_END_STREAM) != 0)
                        return .{ .status = GrpcStatus.OK };
                    return .{ .data = buf[0..to_copy] };
                },
                h2.FT_GOAWAY => return error.ServerGoaway,
                h2.FT_RST_STREAM => return error.StreamReset,
                else => {},
            }
        }
    }

    // --------------------------------------------------------- //

    /// Unary call: send one message, receive one response.
    ///
    /// Return:
    /// - ![]const u8 (slice into buf containing the response message payload)
    pub fn unary(
        self: *Self,
        path: []const u8,
        content_type: []const u8,
        req_data: []const u8,
        buf: []u8,
    ) ![]const u8 {
        const sid = try self.openStream(path, content_type);
        try self.sendMessage(sid, req_data);
        try self.endStream(sid);

        var got_data: ?[]const u8 = null;
        while (true) {
            const resp = try self.recvResponse(sid, buf);
            switch (resp) {
                .data => |d| got_data = d,
                .status => |st| {
                    if (@intFromEnum(st) != 0) return error.GrpcError;
                    return got_data orelse &.{};
                },
            }
        }
    }
};

// --------------------------------------------------------- //

test "zix grpc: GrpcClient.connect port zero returns PortNotConfigured" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expectError(
        error.PortNotConfigured,
        GrpcClient.connect(.{ .ip = "127.0.0.1", .port = 0 }, io),
    );
}
