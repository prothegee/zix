//! Client side of the datagram demo rows: the udp forward and the webrtc media
//! pair.
//!
//! Both prove the same thing from different heights. The udp check sends one
//! typed packet and waits for the echo. The media check runs a whole webrtc
//! session, so ICE, DTLS, SCTP, and a data channel message all have to cross
//! the same per-flow forward.

const std = @import("std");
const zix = @import("zix");

const webrtc_client = @import("runner_webrtc_client");

/// The packet both the demo upstream and this check use. extern struct so the
/// layout is fixed, and it must match examples/proxies/udp.zig exactly.
const Packet = extern struct {
    id: [16]u8,
    packet_type: i32,
    register: u32,
    position: [3]f64,
};

const UdpClient = zix.Udp.Client(Packet);

/// Local port the udp check binds. Outside the demo range so it never collides
/// with a site or an upstream.
const UDP_BIND_PORT: u16 = 9126;
/// Local port the media dialer binds, for the same reason.
const MEDIA_BIND_PORT: u16 = 9127;
/// Longest the udp check waits for its echo.
const UDP_RECV_TIMEOUT_MS: u32 = 4000;
/// Message the data channel must carry back unchanged.
const MEDIA_MESSAGE: []const u8 = "zixer runner media";

// --------------------------------------------------------- //

/// udp forward: one typed packet out, the same packet back. The upstream
/// echoes to the sender it sees, which is zixer's own per-flow socket.
pub fn runUdp(io: std.Io, port: u16) !void {
    var client = try UdpClient.init(.{
        .ip = "127.0.0.1",
        .server_port = port,
        .bind_port = UDP_BIND_PORT,
        .allow_args = false,
        .endianness = .LITTLE,
        .recv_timeout_ms = UDP_RECV_TIMEOUT_MS,
    }, io, &.{});
    defer client.deinit();

    var id: [16]u8 = @splat(0);
    _ = std.fmt.bufPrint(&id, "runner", .{}) catch {};

    const sent = Packet{
        .id = id,
        .packet_type = 7,
        .register = 42,
        .position = .{ 1.5, -2.5, 3.5 },
    };
    try client.send(sent);

    const feedback = try client.receiveFeedback();
    switch (feedback) {
        .packet => |echoed| {
            if (echoed.packet_type != sent.packet_type) return error.EchoMismatch;
            if (echoed.register != sent.register) return error.EchoMismatch;
            if (echoed.position[0] != sent.position[0]) return error.EchoMismatch;
            if (!std.mem.eql(u8, &echoed.id, &sent.id)) return error.EchoMismatch;
        },
        else => return error.UnexpectedFeedback,
    }
}

/// webrtc media: a whole session against the answering peer behind the
/// forward, ending in one data channel message that must come back unchanged.
pub fn runRtcMedia(io: std.Io, port: u16) !void {
    var echo_buf: [512]u8 = undefined;
    const echo = try webrtc_client.echoOnce(io, "127.0.0.1", port, MEDIA_BIND_PORT, MEDIA_MESSAGE, &echo_buf);

    if (!std.mem.eql(u8, echo, MEDIA_MESSAGE)) return error.EchoMismatch;
}
