//! Edge tests: what a zix.Webrtc peer does with input it did not ask for.
//!
//! Note:
//! - Every datagram here is one anybody who knows the address can send. The rule the whole file
//!   pins is that none of them ends a session: an unauthenticated stranger must not be able to
//!   drop a peer that is doing everything right.

const std = @import("std");
const zix = @import("zix");

const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

const PEER_ADDRESS: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 41000 } };

const ANSWERER_UFRAG = "zixA";
const ANSWERER_PASSWORD = "answererpasswordaaaaaa";
const DIALER_UFRAG = "zixD";

const CERTIFICATE_DER = [_]u8{ 0x30, 0x03, 0x01, 0x02, 0x03 };

// --------------------------------------------------------- //

fn signingKey() !EcdsaP256.KeyPair {
    var secret: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&secret, "0b76f7f1c7bf6e20029ddb566795e58da5ba63ffbdb914bf699bfbed3147d32c");

    return EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(secret));
}

fn options() !zix.Webrtc.ConnectionOptions {
    return .{
        .ice_ufrag = ANSWERER_UFRAG,
        .ice_password = ANSWERER_PASSWORD,
        .peer_ice_ufrag = DIALER_UFRAG,
        .certificate_der = &CERTIFICATE_DER,
        .signing_key = try signingKey(),
    };
}

fn secrets() zix.Webrtc.Secrets {
    return .{
        .dtls_cookie = @splat(0x5A),
        .sctp_cookie = @splat(0x6B),
        .server_random = @splat(0x33),
        .server_eph_secret = @splat(0x22),
        .sctp_tag = 0x11223344,
        .sctp_initial_tsn = 1000,
    };
}

fn openPeer() !zix.Webrtc.Connection {
    return zix.Webrtc.Connection.init(std.testing.allocator, PEER_ADDRESS, try options(), secrets(), 0);
}

// --------------------------------------------------------- //

test "zix edge: webrtc, a peer survives every first byte there is" {
    var peer = try openPeer();
    defer peer.deinit();

    // One datagram per first byte, which covers all six RFC 7983 7 ranges plus everything between.
    for (0..256) |leading| {
        const datagram = [_]u8{ @intCast(leading), 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00 };
        const outcome = try peer.handle(&datagram, 1000);

        try std.testing.expect(!outcome.dead);
    }

    try std.testing.expect(!peer.isDead());
    try std.testing.expect(!peer.isEstablished());
}

test "zix edge: webrtc, an empty datagram is dropped and changes nothing" {
    var peer = try openPeer();
    defer peer.deinit();

    const outcome = try peer.handle(&[_]u8{}, 1000);

    try std.testing.expect(!outcome.dead);
    try std.testing.expect(!outcome.established);
    try std.testing.expect(!outcome.delivered);

    var out: [1500]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), try peer.nextOutbound(1000, &out));
}

test "zix edge: webrtc, a dtls record whose length runs off the end is not read past" {
    var peer = try openPeer();
    defer peer.deinit();

    // Content type 22 (handshake), version DTLS 1.2, epoch 0, sequence 0, length 0xFFFF, no body.
    const truncated = [_]u8{ 22, 0xFE, 0xFD, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF };

    const outcome = try peer.handle(&truncated, 1000);
    try std.testing.expect(!outcome.dead);
    try std.testing.expect(!outcome.established);
}

test "zix edge: webrtc, a stun message with the right first byte and nothing else is refused" {
    var peer = try openPeer();
    defer peer.deinit();

    // The demux routes on byte 0 alone, so this reaches the STUN layer and is rejected there.
    const not_stun = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xde, 0xad, 0xbe, 0xef, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

    const outcome = try peer.handle(&not_stun, 1000);
    try std.testing.expect(!outcome.dead);

    var out: [1500]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), try peer.nextOutbound(1000, &out));
}

test "zix edge: webrtc, application data before the handshake finishes goes nowhere" {
    var peer = try openPeer();
    defer peer.deinit();

    // Content type 23 (application data) at epoch 1, with a body that decrypts to nothing because
    // there are no keys yet.
    const body: [8]u8 = @splat(0xAB);
    const early = [_]u8{ 23, 0xFE, 0xFD, 0, 1, 0, 0, 0, 0, 0, 0, 0, 8 } ++ body;

    const outcome = try peer.handle(&early, 1000);

    try std.testing.expect(!outcome.dead);
    try std.testing.expect(!outcome.delivered);
}

test "zix edge: webrtc, the same garbage a thousand times still leaves the peer alive" {
    var peer = try openPeer();
    defer peer.deinit();

    const garbage = [_]u8{ 22, 0xFE, 0xFD, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 1, 2, 3, 4 };

    for (0..1000) |_| _ = try peer.handle(&garbage, 1000);

    try std.testing.expect(!peer.isDead());

    // The idle deadline was pushed back by every one of them, so it has not run out either.
    try std.testing.expect(!peer.tick(1000).dead);
}

test "zix edge: webrtc, a dialer refuses a response carrying somebody else's transaction" {
    const dialer_options: zix.Webrtc.DialerOptions = .{
        .local_ufrag = DIALER_UFRAG,
        .local_password = "dialerpasswordbbbbbbbb",
        .peer_ufrag = ANSWERER_UFRAG,
        .peer_password = ANSWERER_PASSWORD,
        .transaction_id = @splat(0x77),
        .client_random = @splat(0x11),
        .client_eph_secret = @splat(0x44),
        .sctp_cookie = @splat(0x9C),
        .sctp_tag = 0x55667788,
        .sctp_initial_tsn = 5000,
    };

    var dialer = try zix.Webrtc.Dialer.init(std.testing.allocator, dialer_options, 0);
    defer dialer.deinit();

    var peer = try openPeer();
    defer peer.deinit();

    // Take the dialer's own check, answer it properly, then hand back the answer to a dialer that
    // asked with a different transaction identifier.
    var out: [1500]u8 = undefined;
    const check = (try dialer.nextOutbound(0, &out)).?;

    var copy: [1500]u8 = undefined;
    @memcpy(copy[0..check.len], check);
    _ = try peer.handle(copy[0..check.len], 0);

    var reply_buf: [1500]u8 = undefined;
    const reply = (try peer.nextOutbound(0, &reply_buf)).?;

    var stranger_options = dialer_options;
    stranger_options.transaction_id = @splat(0x11);

    var stranger = try zix.Webrtc.Dialer.init(std.testing.allocator, stranger_options, 0);
    defer stranger.deinit();

    var reply_copy: [1500]u8 = undefined;
    @memcpy(reply_copy[0..reply.len], reply);
    _ = try stranger.handle(reply_copy[0..reply.len], 0);

    // It was never that dialer's answer, so nothing moved on.
    try std.testing.expect(!stranger.isReady());
    try std.testing.expect(!stranger.isDead());
}
