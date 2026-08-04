//! The dialing half of a WebRTC session, over a real socket, for the test runners.
//!
//! What:
//! - Drives `zix.Webrtc.Dialer` against a running zix answerer: ICE connectivity check, DTLS
//!   handshake, SCTP association, data channel, one message, and the echo back. This file is the
//!   socket and the clock, and the dialer is everything else.
//! - One entry point, `echoOnce`. Every runner that needs a WebRTC session uses it, so the wire
//!   check and the all-runner check exercise the same code path.
//!
//! Note:
//! - The dialer is sans-I/O: datagrams and a monotonic clock in, datagrams out. That is why this
//!   file is short, and why the same session runs with no socket at all in the in-process suite.
//! - The four ICE credentials are the ones webrtc_datachannel_echo was built with. There is no
//!   signalling channel yet, so both halves are told the same strings at compile time.

const std = @import("std");
const zix = @import("zix");

const socket_poll = zix.utils.socket_poll;
const secure_random = zix.utils.secure_random;

/// The credentials the echo example was built with, standing in for an SDP exchange.
pub const LOCAL_UFRAG: []const u8 = "zixdialer";
pub const LOCAL_PASSWORD: []const u8 = "zixdialerpasswordbbbbbb";
pub const PEER_UFRAG: []const u8 = "zixanswer";
pub const PEER_PASSWORD: []const u8 = "zixanswerpasswordaaaaaa";

/// The label the channel is opened with.
pub const CHANNEL_LABEL: []const u8 = "echo";

const MAX_DATAGRAM: usize = 1500;
/// How long the whole session may take before the dialer gives up.
const SESSION_TIMEOUT_MS: u32 = 8000;
/// Longest the loop parks in poll with nothing due.
const POLL_CEILING_MS: u32 = 100;

/// Milliseconds since the session started, which is the only clock the dialer needs.
fn elapsedMs(start: std.Io.Clock.Timestamp, now: std.Io.Clock.Timestamp) u64 {
    const raw = std.Io.Clock.Timestamp.durationTo(start, now).raw.toMilliseconds();

    if (raw <= 0) return 0;

    return @intCast(raw);
}

/// The random values one session is born with, fresh per run.
fn dialerOptions() zix.Webrtc.DialerOptions {
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

/// Run one whole session and bring back what the answerer echoed.
///
/// Param:
/// io - std.Io
/// server_ip - []const u8 (where the answerer listens)
/// server_port - u16
/// bind_port - u16 (this side's port, unique per runner so two checks never collide)
/// message - []const u8 (sent once the channel opens)
/// out - []u8 (destination for the echo)
///
/// Return:
/// - []const u8 (the echo, borrowing out)
/// - error.SessionTimeout when the dialer gave up before a channel opened
pub fn echoOnce(
    io: std.Io,
    server_ip: []const u8,
    server_port: u16,
    bind_port: u16,
    message: []const u8,
    out: []u8,
) ![]const u8 {
    const local = try std.Io.net.IpAddress.parse("127.0.0.1", bind_port);
    const socket = try local.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer socket.close(io);

    const server = try std.Io.net.IpAddress.parse(server_ip, server_port);
    const start = std.Io.Clock.Timestamp.now(io, .awake);

    var dialer = try zix.Webrtc.Dialer.init(std.heap.smp_allocator, dialerOptions(), 0);
    defer dialer.deinit();

    var sent = false;
    var echo_len: usize = 0;

    var send_buf: [MAX_DATAGRAM]u8 = undefined;
    var recv_buf: [MAX_DATAGRAM]u8 = undefined;

    while (echo_len == 0) {
        var now_ms = elapsedMs(start, std.Io.Clock.Timestamp.now(io, .awake));

        while (try dialer.nextOutbound(now_ms, &send_buf)) |datagram| try socket.send(io, &server, datagram);

        // Readiness first, then a plain receive: a timed std.Io receive needs the Io to run the
        // receive and a timer concurrently, which the Windows backend cannot do for a socket.
        const ready = try socket_poll.waitReady(socket.handle, socket_poll.READABLE, POLL_CEILING_MS);
        now_ms = elapsedMs(start, std.Io.Clock.Timestamp.now(io, .awake));

        if (ready) {
            const received = try socket.receive(io, &recv_buf);
            _ = try dialer.handle(received.data, now_ms);

            while (try dialer.nextEvent(now_ms)) |event| switch (event) {
                .CHANNEL_OPEN => |channel| {
                    dialer.onChannelOpen(channel);

                    if (!sent) {
                        try dialer.send(.STRING, message, now_ms);
                        sent = true;
                    }
                },
                .MESSAGE => |incoming| {
                    echo_len = @min(incoming.payload.len, out.len);
                    @memcpy(out[0..echo_len], incoming.payload[0..echo_len]);
                },
                .CHANNEL_CLOSED => {},
            };
        }

        _ = try dialer.tick(now_ms);

        if (dialer.isDead()) return error.SessionTimeout;
    }

    return out[0..echo_len];
}
