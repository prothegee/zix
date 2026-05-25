//! zix udp client

const std = @import("std");
const Config = @import("config.zig");
const UdpClientConfig = Config.UdpClientConfig;
const PortMode = Config.PortMode;
const pkt = @import("packet.zig");

// --------------------------------------------------------- //

/// UDP client typed to a user-defined extern struct packet.
///
/// Usage:
/// ```zig
/// const MyClient = zix.Udp.Client(MyPacket);
/// var client = try MyClient.init(config, io);           // REQUIRED mode
/// var client = try MyClient.initArgs(config, io, args); // CONFIGURABLE mode
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

        /// Initialize in REQUIRED mode — bind_port and server_port must be set non-zero in config.
        /// Binds the socket and resolves the server address.
        ///
        /// Return:
        /// - error.PortNotConfigured if bind_port or server_port is zero
        pub fn init(config: UdpClientConfig, io: std.Io) !Self {
            if (config.bind_port == 0 or config.server_port == 0) return error.PortNotConfigured;
            const bind_addr = try std.Io.net.IpAddress.parse("127.0.0.1", config.bind_port);
            const socket = try bind_addr.bind(io, .{ .mode = .dgram, .protocol = .udp });
            const dest = try std.Io.net.IpAddress.parse(config.server_ip, config.server_port);
            std.debug.print("zix udp client: bound 127.0.0.1:{d} -> {s}:{d}\n", .{ config.bind_port, config.server_ip, config.server_port });
            return .{ .config = config, .socket = socket, .dest = dest, .io = io };
        }

        /// Initialize in CONFIGURABLE mode — reads --bind-port and --server-port from CLI args.
        /// Falls back to config defaults if args are absent.
        pub fn initArgs(config: UdpClientConfig, io: std.Io, args: anytype) !Self {
            var cfg = config;
            var it = std.process.Args.Iterator.init(args);
            _ = it.skip(); // skip argv[0]
            while (it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--bind-port")) {
                    if (it.next()) |val| {
                        cfg.bind_port = std.fmt.parseInt(u16, val, 10) catch cfg.bind_port;
                    }
                } else if (std.mem.eql(u8, arg, "--server-port")) {
                    if (it.next()) |val| {
                        cfg.server_port = std.fmt.parseInt(u16, val, 10) catch cfg.server_port;
                    }
                }
            }
            return init(cfg, io);
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

        /// Blocking receive — returns the next FeedbackResult from the server.
        /// Decodes the packet from wire endianness on receipt.
        ///
        /// Return:
        /// - error.UnexpectedPacketSize if the datagram size matches neither ACK/NACK nor Packet
        ///
        /// Note:
        /// - for a concurrent send/receive loop, see examples/udp_client.zig
        pub fn receiveFeedback(self: *Self) !FB {
            var buf: [@sizeOf(Packet)]u8 = undefined;
            const msg = try self.socket.receive(self.io, &buf);
            if (msg.data.len == 1) {
                return if (msg.data[0] == 0x06) .ack else .nack;
            }
            if (msg.data.len == @sizeOf(Packet)) {
                const wire_pkt: Packet = @bitCast(buf);
                return .{ .packet = pkt.fromEndian(Packet, wire_pkt, self.config.endianness) };
            }
            return error.UnexpectedPacketSize;
        }
    };
}
