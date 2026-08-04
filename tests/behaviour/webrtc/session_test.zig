//! Behaviour tests: how a zix.Webrtc peer behaves as a session moves through it, and what it
//! refuses along the way.
//!
//! Note:
//! - Every peer here is driven with datagrams and a clock this file owns. No socket is opened and
//!   no time passes, so what these pin is the behaviour rather than the timing.

const std = @import("std");
const zix = @import("zix");

const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

const PEER_ADDRESS: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 41000 } };

const ANSWERER_UFRAG = "zixA";
const ANSWERER_PASSWORD = "answererpasswordaaaaaa";
const DIALER_UFRAG = "zixD";
const DIALER_PASSWORD = "dialerpasswordbbbbbbbb";

const CERTIFICATE_DER = [_]u8{ 0x30, 0x03, 0x01, 0x02, 0x03 };

// --------------------------------------------------------- //

fn signingKey() !EcdsaP256.KeyPair {
    var secret: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&secret, "0b76f7f1c7bf6e20029ddb566795e58da5ba63ffbdb914bf699bfbed3147d32c");

    return EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(secret));
}

fn answererOptions() !zix.Webrtc.ConnectionOptions {
    return .{
        .ice_ufrag = ANSWERER_UFRAG,
        .ice_password = ANSWERER_PASSWORD,
        .peer_ice_ufrag = DIALER_UFRAG,
        .certificate_der = &CERTIFICATE_DER,
        .signing_key = try signingKey(),
    };
}

fn answererSecrets() zix.Webrtc.Secrets {
    return .{
        .dtls_cookie = @splat(0x5A),
        .sctp_cookie = @splat(0x6B),
        .server_random = @splat(0x33),
        .server_eph_secret = @splat(0x22),
        .sctp_tag = 0x11223344,
        .sctp_initial_tsn = 1000,
    };
}

fn dialerOptions() zix.Webrtc.DialerOptions {
    return .{
        .local_ufrag = DIALER_UFRAG,
        .local_password = DIALER_PASSWORD,
        .peer_ufrag = ANSWERER_UFRAG,
        .peer_password = ANSWERER_PASSWORD,
        .transaction_id = @splat(0x77),
        .client_random = @splat(0x11),
        .client_eph_secret = @splat(0x44),
        .sctp_cookie = @splat(0x9C),
        .sctp_tag = 0x55667788,
        .sctp_initial_tsn = 5000,
    };
}

/// Move one datagram from the dialer to the answerer, if the dialer has one waiting.
fn stepToAnswerer(dialer: *zix.Webrtc.Dialer, answerer: *zix.Webrtc.Connection, now_ms: u64) !bool {
    var out: [1500]u8 = undefined;
    const datagram = (try dialer.nextOutbound(now_ms, &out)) orelse return false;

    var copy: [1500]u8 = undefined;
    @memcpy(copy[0..datagram.len], datagram);

    _ = try answerer.handle(copy[0..datagram.len], now_ms);

    return true;
}

// --------------------------------------------------------- //

test "zix behaviour: webrtc, a peer answers a connectivity check before anything is negotiated" {
    var answerer = try zix.Webrtc.Connection.init(std.testing.allocator, PEER_ADDRESS, try answererOptions(), answererSecrets(), 0);
    defer answerer.deinit();

    var dialer = try zix.Webrtc.Dialer.init(std.testing.allocator, dialerOptions(), 0);
    defer dialer.deinit();

    try std.testing.expect(try stepToAnswerer(&dialer, &answerer, 0));

    var out: [1500]u8 = undefined;
    const reply = (try answerer.nextOutbound(0, &out)).?;

    const parsed = try zix.Webrtc.stun.parse(reply);
    try std.testing.expectEqual(zix.Webrtc.stun.Class.SUCCESS_RESPONSE, parsed.class);

    // Nothing above ICE has started, so there is no association and no context to reply through.
    try std.testing.expect(!answerer.isEstablished());
    try std.testing.expect(answerer.context(0) == null);
}

test "zix behaviour: webrtc, the association only exists once the handshake finishes" {
    var answerer = try zix.Webrtc.Connection.init(std.testing.allocator, PEER_ADDRESS, try answererOptions(), answererSecrets(), 0);
    defer answerer.deinit();

    var dialer = try zix.Webrtc.Dialer.init(std.testing.allocator, dialerOptions(), 0);
    defer dialer.deinit();

    var secured = false;
    var rounds: usize = 0;

    while (rounds < 100 and !secured) : (rounds += 1) {
        _ = try stepToAnswerer(&dialer, &answerer, 0);

        var out: [1500]u8 = undefined;
        while (try answerer.nextOutbound(0, &out)) |datagram| {
            var copy: [1500]u8 = undefined;
            @memcpy(copy[0..datagram.len], datagram);

            const outcome = try dialer.handle(copy[0..datagram.len], 0);
            if (outcome.secured) secured = true;
        }
    }

    try std.testing.expect(secured);
    try std.testing.expect(answerer.isEstablished());
    try std.testing.expect(answerer.context(0) != null);
}

test "zix behaviour: webrtc, a peer that says nothing is dropped on its idle deadline" {
    var options = try answererOptions();
    options.peer_idle_ms = 5_000;

    var answerer = try zix.Webrtc.Connection.init(std.testing.allocator, PEER_ADDRESS, options, answererSecrets(), 0);
    defer answerer.deinit();

    try std.testing.expect(!answerer.tick(4_999).dead);
    try std.testing.expect(answerer.tick(5_000).dead);
}

test "zix behaviour: webrtc, every datagram pushes the idle deadline back" {
    var options = try answererOptions();
    options.peer_idle_ms = 5_000;

    var answerer = try zix.Webrtc.Connection.init(std.testing.allocator, PEER_ADDRESS, options, answererSecrets(), 0);
    defer answerer.deinit();

    var dialer = try zix.Webrtc.Dialer.init(std.testing.allocator, dialerOptions(), 0);
    defer dialer.deinit();

    _ = try stepToAnswerer(&dialer, &answerer, 4_000);

    // The check arrived at 4000, so the peer now has until 9000 rather than 5000.
    try std.testing.expect(!answerer.tick(5_000).dead);
    try std.testing.expect(answerer.tick(9_000).dead);
}

test "zix behaviour: webrtc, a dialer keeps asking until a check is answered" {
    var options = dialerOptions();
    options.check_interval_ms = 100;

    var dialer = try zix.Webrtc.Dialer.init(std.testing.allocator, options, 0);
    defer dialer.deinit();

    var out: [1500]u8 = undefined;
    var checks: usize = 0;

    // Nothing answers, so every interval produces one more check.
    var now_ms: u64 = 0;
    while (now_ms <= 500) : (now_ms += 100) {
        _ = try dialer.tick(now_ms);

        while (try dialer.nextOutbound(now_ms, &out)) |_| checks += 1;
    }

    try std.testing.expect(checks >= 5);
}
