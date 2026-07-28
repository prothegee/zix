//! zix udp client

const std = @import("std");
const Config = @import("config.zig");
const UdpClientConfig = Config.UdpClientConfig;
const pkt = @import("packet.zig");
const win_io = @import("../utils/windows_io.zig");

/// poll event bit, mirrored locally: std.posix.POLL is not defined for Windows.
const POLL_IN: i16 = if (@import("builtin").target.os.tag == .windows) win_io.POLLIN else std.posix.POLL.IN;

/// Readiness gate shared by the recv timeout: AFD poll on Windows, posix poll elsewhere.
///
/// Return:
/// - true when the socket is readable
/// - false when the timeout elapsed first
fn pollReady(sock_fd: std.posix.fd_t, events: i16, timeout_ms: u32) !bool {
    if (comptime @import("builtin").target.os.tag == .windows) return win_io.pollReady(sock_fd, events, timeout_ms);

    var pfd = [1]std.posix.pollfd{.{ .fd = sock_fd, .events = events, .revents = 0 }};
    const ms: i32 = @intCast(@min(timeout_ms, @as(u32, std.math.maxInt(i32))));

    return try std.posix.poll(&pfd, ms) > 0;
}

/// UDP client typed to a user-defined extern struct packet.
///
/// Usage:
/// ```zig
/// const MyClient = zix.Udp.Client(MyPacket);
/// var client = try MyClient.init(config, io, .{});      // config-only
/// // set config.allow_args = true + pass args to read --bind-ip / --bind-port / --server-port
/// defer client.deinit();
/// try client.send(my_packet);
/// const fb = try client.receiveFeedback();
/// ```
///
/// Note:
/// - for a full concurrent send/receive loop example, see examples/udp_client.zig
pub fn UdpClient(comptime Packet: type) type {
    // RFC 768: max UDP payload = 65,535 - 8 (UDP header) - 20 (min IPv4 header) = 65,507 bytes.
    // Packets larger than this cannot be sent in a single datagram.
    if (@sizeOf(Packet) > 65_507) @compileError("Packet size exceeds maximum UDP payload of 65,507 bytes (RFC 768)");
    return struct {
        const Self = @This();
        const FB = pkt.FeedbackResult(Packet);

        config: UdpClientConfig,
        socket: std.Io.net.Socket,
        dest: std.Io.net.IpAddress,
        io: std.Io,

        // --------------------------------------------------------- //

        /// Initialize. When `config.allow_args` is set, `--bind-ip` / `--bind-port` / `--server-port`
        /// from `args` override the config, otherwise `args` is ignored. Binds the socket and resolves
        /// the server address.
        ///
        /// Param:
        /// config - UdpClientConfig
        /// io - std.Io
        /// args - process args, or `.{}` when not reading CLI
        ///
        /// Return:
        /// - error.PortNotConfigured if bind_port or server_port is zero
        pub fn init(config: UdpClientConfig, io: std.Io, args: anytype) !Self {
            var cfg = config;
            // The parse only compiles when args is a real std.process.Args. Passing `.{}` (no CLI)
            // skips it at comptime, so the empty case does not need a process.Args value.
            if (comptime @TypeOf(args) == std.process.Args) {
                if (cfg.allow_args) cfg = Config.applyClientArgs(cfg, args);
            }

            if (cfg.bind_port == 0 or cfg.server_port == 0) return error.PortNotConfigured;

            const bind_addr = try std.Io.net.IpAddress.parse(cfg.bind_ip, cfg.bind_port);
            const socket = try bind_addr.bind(io, .{ .mode = .dgram, .protocol = .udp });

            const dest = try std.Io.net.IpAddress.parse(cfg.ip, cfg.server_port);

            return .{ .config = cfg, .socket = socket, .dest = dest, .io = io };
        }

        /// Close the bound socket.
        pub fn deinit(self: *Self) void {
            self.socket.close(self.io);
        }

        /// Send a packet to the server. Applies endianness conversion before sending.
        pub fn send(self: *Self, packet_data: Packet) !void {
            const wire = pkt.toEndian(Packet, packet_data, self.config.endianness);
            try self.socket.send(self.io, &self.dest, std.mem.asBytes(&wire));
        }

        /// Blocking receive. Decodes the packet from wire endianness on receipt.
        ///
        /// Return:
        /// - error.RecvTimeout if recv_timeout_ms is set and no datagram arrives in time
        /// - error.UnexpectedPacketSize if the datagram size matches neither ACK/NACK nor Packet
        ///
        /// Note:
        /// - for a concurrent send/receive loop, see examples/udp_client.zig
        pub fn receiveFeedback(self: *Self) !FB {
            if (self.config.recv_timeout_ms > 0) {
                // std.Io.Threaded panics on EAGAIN, so gate with poll instead of SO_RCVTIMEO.
                if (!try pollReady(self.socket.handle, POLL_IN, self.config.recv_timeout_ms)) {
                    return error.RecvTimeout;
                }
            }

            var buf: [@sizeOf(Packet)]u8 = undefined;
            const msg = try self.socket.receive(self.io, &buf);
            if (msg.data.len == 1) {
                return if (msg.data[0] == 0x06) .ack else .nack;
            }
            if (msg.data.len == @sizeOf(Packet)) {
                const wire_pkt: Packet = std.mem.bytesToValue(Packet, &buf);
                return .{ .packet = pkt.fromEndian(Packet, wire_pkt, self.config.endianness) };
            }
            return error.UnexpectedPacketSize;
        }
    };
}

// --------------------------------------------------------- //

test "zix udp: UdpClient init rejects a zero port" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const Client = UdpClient(extern struct { value: u32 });
    try std.testing.expectError(error.PortNotConfigured, Client.init(.{ .ip = "127.0.0.1", .server_port = 0, .bind_port = 0 }, threaded.io(), .{}));
}

test "zix udp: pollReady, times out on silence and reports ready after a self-send" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 9356);
    var socket = try addr.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer socket.close(io);

    try std.testing.expectEqual(false, try pollReady(socket.handle, POLL_IN, 50));

    try socket.send(io, &addr, "x");

    try std.testing.expectEqual(true, try pollReady(socket.handle, POLL_IN, 1000));
}
