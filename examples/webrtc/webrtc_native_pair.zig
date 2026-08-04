// Usage:
// zig build example-webrtc_datachannel_echo
// zig build example-webrtc_native_pair
// ./zig-out/bin/webrtc_datachannel_echo &
// ./zig-out/bin/webrtc_native_pair
//
// The dialing half of a native WebRTC pair: no browser, no SDP, and no signalling server. It runs
// the whole session against webrtc_datachannel_echo over a real loopback socket, in the order the
// wire builds it:
//
//   ICE connectivity check -> DTLS handshake -> SCTP association -> data channel -> one message
//
// zix's own engine answers, it never dials, so this side is a zix.Webrtc.Dialer. Both halves are
// sans-I/O: they take datagrams and a clock, and hand back datagrams. This file is the socket and
// the clock, and nothing else.
//
// It exits 0 when the message came back byte for byte, and non-zero otherwise, so it doubles as a
// check you can run by hand.

const std = @import("std");
const zix = @import("zix");

const socket_poll = zix.utils.socket_poll;
const secure_random = zix.utils.secure_random;

// --------------------------------------------------------- //

const PEER_IP: []const u8 = "127.0.0.1";
const PEER_PORT: u16 = 9083;
const BIND_PORT: u16 = 9084;

// The same four strings webrtc_datachannel_echo was given, standing in for an SDP exchange.
const LOCAL_UFRAG: []const u8 = "zixdialer";
const LOCAL_PASSWORD: []const u8 = "zixdialerpasswordbbbbbb";
const PEER_UFRAG: []const u8 = "zixanswer";
const PEER_PASSWORD: []const u8 = "zixanswerpasswordaaaaaa";

const CHANNEL_LABEL: []const u8 = "echo";
const MESSAGE: []const u8 = "hello over a data channel";

const MAX_DATAGRAM: usize = 1500;
/// How long the whole session may take before this side gives up.
const SESSION_TIMEOUT_MS: u32 = 10000;
/// Longest this side parks in poll with nothing due.
const POLL_CEILING_MS: u32 = 100;

// --------------------------------------------------------- //

/// Milliseconds since the loop started, which is the only clock any layer below needs.
fn elapsedMs(start: std.Io.Clock.Timestamp, now: std.Io.Clock.Timestamp) u64 {
    const raw = std.Io.Clock.Timestamp.durationTo(start, now).raw.toMilliseconds();

    if (raw <= 0) return 0;

    return @intCast(raw);
}

/// The random values one session is born with. Fresh every run, never reused.
fn drawOptions() zix.Webrtc.DialerOptions {
    var transaction_id: [12]u8 = undefined;
    var client_random: [32]u8 = undefined;
    var client_eph_secret: [32]u8 = undefined;
    var sctp_cookie: [32]u8 = undefined;

    secure_random.fill(&transaction_id);
    secure_random.fill(&client_random);
    secure_random.fill(&client_eph_secret);
    secure_random.fill(&sctp_cookie);

    // An initiate tag of zero is what a packet carrying an INIT uses, so it can never be an
    // endpoint's own (RFC 9260 3.1).
    const tag = secure_random.int(u32);

    return .{
        .local_ufrag = LOCAL_UFRAG,
        .local_password = LOCAL_PASSWORD,
        .peer_ufrag = PEER_UFRAG,
        .peer_password = PEER_PASSWORD,
        .transaction_id = transaction_id,
        .client_random = client_random,
        .client_eph_secret = client_eph_secret,
        .sctp_cookie = sctp_cookie,
        .sctp_tag = if (tag == 0) 1 else tag,
        .sctp_initial_tsn = secure_random.int(u32),
        .channel_label = CHANNEL_LABEL,
        .setup_timeout_ms = SESSION_TIMEOUT_MS,
    };
}

/// Run one whole session and check the message came back unchanged.
fn dial(io: std.Io, allocator: std.mem.Allocator) !void {
    const local = try std.Io.net.IpAddress.parse("0.0.0.0", BIND_PORT);
    const socket = try local.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer socket.close(io);

    const peer = try std.Io.net.IpAddress.parse(PEER_IP, PEER_PORT);
    const start = std.Io.Clock.Timestamp.now(io, .awake);

    var dialer = try zix.Webrtc.Dialer.init(allocator, drawOptions(), 0);
    defer dialer.deinit();

    var sent = false;
    var echo: [MAX_DATAGRAM]u8 = undefined;
    var echo_len: usize = 0;

    var out: [MAX_DATAGRAM]u8 = undefined;
    var recv_buf: [MAX_DATAGRAM]u8 = undefined;

    while (echo_len == 0) {
        var now_ms = elapsedMs(start, std.Io.Clock.Timestamp.now(io, .awake));

        while (try dialer.nextOutbound(now_ms, &out)) |datagram| try socket.send(io, &peer, datagram);

        const ready = try socket_poll.waitReady(socket.handle, socket_poll.READABLE, POLL_CEILING_MS);
        now_ms = elapsedMs(start, std.Io.Clock.Timestamp.now(io, .awake));

        if (ready) {
            const message = try socket.receive(io, &recv_buf);
            _ = try dialer.handle(message.data, now_ms);

            while (try dialer.nextEvent(now_ms)) |event| switch (event) {
                .CHANNEL_OPEN => |channel| {
                    dialer.onChannelOpen(channel);

                    if (!sent) {
                        try dialer.send(.STRING, MESSAGE, now_ms);
                        sent = true;
                    }
                },
                .MESSAGE => |incoming| {
                    echo_len = @min(incoming.payload.len, echo.len);
                    @memcpy(echo[0..echo_len], incoming.payload[0..echo_len]);
                },
                .CHANNEL_CLOSED => {},
            };
        }

        _ = try dialer.tick(now_ms);

        if (dialer.isDead()) return error.SessionFailed;
    }

    if (!std.mem.eql(u8, echo[0..echo_len], MESSAGE)) return error.EchoMismatch;
}

pub fn main(process: std.process.Init) !void {
    try dial(process.io, std.heap.smp_allocator);

    std.log.info("native pair: the message came back on the data channel", .{});
}
