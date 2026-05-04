//! zix udp namespace aggregator

const config = @import("config.zig");
const packet = @import("packet.zig");

// --------------------------------------------------------- //

pub const PortMode = config.PortMode;
pub const Endianness = config.Endianness;
pub const ServerConfig = config.UdpServerConfig;
pub const ClientConfig = config.UdpClientConfig;
pub const FeedbackResult = packet.FeedbackResult;
pub const toEndian = packet.toEndian;
pub const fromEndian = packet.fromEndian;

// --------------------------------------------------------- //

/// UDP server typed to the user's extern struct packet.
/// Example: const MyServer = zix.Udp.Server(MyPacket);
pub fn Server(comptime Packet: type) type {
    return @import("server.zig").UdpServer(Packet);
}

/// UDP client typed to the user's extern struct packet.
/// Example: const MyClient = zix.Udp.Client(MyPacket);
pub fn Client(comptime Packet: type) type {
    return @import("client.zig").UdpClient(Packet);
}
