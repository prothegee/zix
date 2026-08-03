// Usage:
// zig build example-webrtc_datachannel_echo
// ./zig-out/bin/webrtc_datachannel_echo
//
// A WebRTC data channel echo server. One UDP port carries everything: ICE connectivity checks,
// the DTLS handshake, the SCTP association, and the channels over it (RFC 7983 7).
//
// zix answers, it never dials. The ICE agent is lite, so the peer sends the checks and this side
// replies to them, and the DTLS role is always server.
//
// The ICE credentials are fixed here because there is no signalling channel yet: a browser learns
// them from an SDP offer, and this example is talked to by webrtc_native_pair, which is told the
// same four strings.
//
// Pair it with:
//   ./zig-out/bin/webrtc_native_pair

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

const SERVER_IP: []const u8 = "127.0.0.1";
const SERVER_PORT: u16 = 9083;

// The credentials both halves are told, standing in for the SDP exchange a browser would do.
const LOCAL_UFRAG: []const u8 = "zixanswer";
const LOCAL_PASSWORD: []const u8 = "zixanswerpasswordaaaaaa";
const PEER_UFRAG: []const u8 = "zixdialer";

const CERT_PATH: []const u8 = "examples/certs/ecdsa_p256_cert.pem";
const KEY_PATH: []const u8 = "examples/certs/ecdsa_p256_key.pem";

// --------------------------------------------------------- //

// Echo every message straight back on the channel it arrived on. The payload is borrowed for the
// length of this call, and send copies it, so nothing here has to be kept.
fn onEvent(event: zix.Webrtc.Event, ctx: *zix.Webrtc.Context) !void {
    switch (event) {
        .CHANNEL_OPEN => |channel| std.log.info("channel {d} open", .{channel}),
        .CHANNEL_CLOSED => |channel| std.log.info("channel {d} closed", .{channel}),
        .MESSAGE => |message| try ctx.send(message.channel, message.kind, message.payload),
    }
}

pub fn main(process: std.process.Init) !void {
    const io = process.io;
    const allocator = std.heap.smp_allocator;

    // The certificate and the key that signs the ServerKeyExchange. WebRTC has no cleartext mode,
    // and the one DTLS 1.2 suite this engine implements is ECDHE-ECDSA, so the key has to be P-256.
    var tls = try zix.Tls.Context.init(allocator, io, .{
        .cert_path = CERT_PATH,
        .key_path = KEY_PATH,
    });
    defer tls.deinit();

    var server = zix.Webrtc.Server.init(onEvent, .{
        .io = io,
        .allocator = allocator,
        .ip = SERVER_IP,
        .port = SERVER_PORT,
        .dispatch_model = .ASYNC, // the only model this engine runs today
        .ice_ufrag = LOCAL_UFRAG,
        .ice_password = LOCAL_PASSWORD,
        .peer_ice_ufrag = PEER_UFRAG,
        .tls = &tls,
    });
    defer server.deinit();

    std.log.info("webrtc echo listening on {s}:{d}", .{ SERVER_IP, SERVER_PORT });

    try server.run();
}
