//! zix WebRTC dispatch substrate: everything the loops share, and no loop of its own (ADR-043).
//!
//! What:
//! - The parts of running a WebRTC server that are not the loop: binding the socket, drawing the
//!   randomness a connection needs, reading the clock, and the fixed order in which one peer is
//!   drained after something happened to it.
//! - This is the only place in the engine that reaches for ambient state. Everything under
//!   connection.zig takes its clock and its randomness from the caller, which is what keeps a full
//!   exchange testable in memory.
//!
//! Note:
//! - The drain order is fixed and shared, so every dispatch model answers a peer the same way:
//!   send what is owed, then tell the application what arrived, then send what the application
//!   produced. Reversing the last two loses a reply until the next datagram.

const std = @import("std");

const Config = @import("../config.zig");
const WebrtcServerConfig = Config.WebrtcServerConfig;
const connection = @import("../connection.zig");
const core = @import("../core.zig");
const table = @import("../table.zig");
const secure_random = @import("../../../utils/secure_random.zig");

const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

/// Emit a server lifecycle line.
///
/// Note:
/// - Silent without a logger. A server that writes to stderr on its own is one a test cannot run
///   quietly, and the caller who wants these lines is the caller who passed a logger.
pub fn logSystem(config: WebrtcServerConfig, comptime fmt: []const u8, args: anytype) void {
    const logger = config.logger orelse return;

    logger.system(.INFO, "webrtc", fmt, args);
}

/// Draw the random values one connection is born with.
///
/// Note:
/// - An SCTP initiate tag of zero is the value a packet carrying an INIT uses, so it can never be
///   an endpoint's own tag (RFC 9260 3.1). Drawing one is possible, so it is corrected here.
///
/// Return:
/// - connection.Secrets
pub fn drawSecrets() connection.Secrets {
    var secrets: connection.Secrets = undefined;

    secure_random.fill(&secrets.dtls_cookie);
    secure_random.fill(&secrets.sctp_cookie);
    secure_random.fill(&secrets.server_random);
    secure_random.fill(&secrets.server_eph_secret);

    const tag = secure_random.int(u32);
    secrets.sctp_tag = if (tag == 0) 1 else tag;
    secrets.sctp_initial_tsn = secure_random.int(u32);

    return secrets;
}

/// The P-256 key pair out of the TLS context, or null when there is no context or its key is a
/// kind the one DTLS 1.2 suite cannot sign with.
///
/// Param:
/// config - WebrtcServerConfig
///
/// Return:
/// - ?EcdsaP256.KeyPair
pub fn ecdsaKey(config: WebrtcServerConfig) ?EcdsaP256.KeyPair {
    const tls = config.tls orelse return null;

    return switch (tls.signing_key) {
        .ecdsa_p256 => |pair| pair,
        else => null,
    };
}

/// Build the per-connection options out of the server config.
///
/// Note:
/// - Every slice is borrowed from the config, so the config has to outlive the server. That is the
///   same contract every other zix engine holds its caller to.
/// - Call only after run() has checked the config. A context with no usable key is rejected there,
///   before the socket is bound.
///
/// Param:
/// config - WebrtcServerConfig
///
/// Return:
/// - connection.Options
pub fn optionsFrom(config: WebrtcServerConfig) connection.Options {
    return .{
        .ice_ufrag = config.ice_ufrag,
        .ice_password = config.ice_password,
        .peer_ice_ufrag = config.peer_ice_ufrag,
        .certificate_der = if (config.tls) |tls| tls.cert_der else "",
        .signing_key = ecdsaKey(config).?,
        .max_handshake_fragment = config.max_handshake_fragment,
        .path_max_bytes = config.path_max_bytes,
        .max_datagram_bytes = config.max_recv_buf,
        .outbound_streams = config.outbound_streams,
        .inbound_streams = config.inbound_streams,
        .max_channels = config.max_channels,
        .peer_idle_ms = config.peer_idle_ms,
    };
}

/// How wide the outbound scratch buffer has to be for one datagram.
pub fn sendBufBytes(config: WebrtcServerConfig) usize {
    return @max(config.max_recv_buf, config.path_max_bytes + connection.DTLS_OVERHEAD + 64);
}

/// Milliseconds between two readings of the same clock, never negative.
///
/// Param:
/// start - std.Io.Clock.Timestamp (the loop's own zero point)
/// now - std.Io.Clock.Timestamp
///
/// Return:
/// - u64
pub fn elapsedMs(start: std.Io.Clock.Timestamp, now: std.Io.Clock.Timestamp) u64 {
    const raw = std.Io.Clock.Timestamp.durationTo(start, now).raw.toMilliseconds();

    if (raw <= 0) return 0;

    return @intCast(raw);
}

/// Bind the UDP socket every model receives on.
///
/// Param:
/// config - WebrtcServerConfig
///
/// Return:
/// - std.Io.net.Socket, bound and ready to receive
/// - whatever resolve or bind raised
pub fn bindSocket(config: WebrtcServerConfig) !std.Io.net.Socket {
    const address = try std.Io.net.IpAddress.resolve(config.io, config.ip, config.port);
    const socket = try address.bind(config.io, .{ .mode = .dgram, .protocol = .udp });

    setSocketBuffers(socket.handle, config.socket_rcvbuf, config.socket_sndbuf);

    return socket;
}

/// Ask the kernel for larger socket buffers.
///
/// Note:
/// - Best effort. A kernel that clamps the request or refuses it leaves the default in place,
///   which is a slower server rather than a broken one.
pub fn setSocketBuffers(handle: std.posix.socket_t, rcvbuf: usize, sndbuf: usize) void {
    if (rcvbuf > 0) {
        const want = std.mem.toBytes(@as(c_int, @intCast(@min(rcvbuf, std.math.maxInt(c_int)))));
        std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, &want) catch {};
    }

    if (sndbuf > 0) {
        const want = std.mem.toBytes(@as(c_int, @intCast(@min(sndbuf, std.math.maxInt(c_int)))));
        std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, &want) catch {};
    }
}

/// Drain one peer after something happened to it: send what it owes, hand the application what
/// arrived, then send what the application produced.
///
/// Note:
/// - Two send passes, and both are needed. The first carries acknowledgements and handshake
///   flights. The second carries whatever the handler queued, which does not exist until the
///   handler has run.
///
/// Param:
/// handler - comptime core.HandlerFn
/// peer - *connection.Connection
/// now_ms - u64 (monotonic milliseconds)
/// socket - std.Io.net.Socket
/// config - WebrtcServerConfig
/// out - []u8 (scratch for one datagram, sized by sendBufBytes)
///
/// Return:
/// - void
pub fn drainPeer(
    comptime handler: core.HandlerFn,
    peer: *connection.Connection,
    now_ms: u64,
    socket: std.Io.net.Socket,
    config: WebrtcServerConfig,
    out: []u8,
) void {
    flushPeer(peer, now_ms, socket, config, out);

    while (peer.nextEvent(now_ms) catch null) |event| {
        var ctx = peer.context(now_ms) orelse break;

        handler(event, &ctx) catch |err| logSystem(config, "handler returned {s}", .{@errorName(err)});
    }

    flushPeer(peer, now_ms, socket, config, out);
}

/// Send everything one peer has waiting.
pub fn flushPeer(
    peer: *connection.Connection,
    now_ms: u64,
    socket: std.Io.net.Socket,
    config: WebrtcServerConfig,
    out: []u8,
) void {
    while (peer.nextOutbound(now_ms, out) catch null) |packet| {
        socket.send(config.io, &peer.address, packet) catch |err| {
            logSystem(config, "send to peer failed: {s}", .{@errorName(err)});

            return;
        };
    }
}

/// Give every peer its due deadlines, drain whatever that produced, and let go of the finished.
///
/// Param:
/// handler - comptime core.HandlerFn
/// peers - *table.Table
/// now_ms - u64 (monotonic milliseconds)
/// socket - std.Io.net.Socket
/// config - WebrtcServerConfig
/// out - []u8
///
/// Return:
/// - void
pub fn sweepPeers(
    comptime handler: core.HandlerFn,
    peers: *table.Table,
    now_ms: u64,
    socket: std.Io.net.Socket,
    config: WebrtcServerConfig,
    out: []u8,
) void {
    var walk = peers.iterator();
    while (walk.next()) |peer| {
        const outcome = peer.tick(now_ms);

        if (outcome.dead) continue;

        drainPeer(handler, peer, now_ms, socket, config, out);
    }

    const dropped = peers.dropDead();
    if (dropped > 0) logSystem(config, "dropped {d} peer(s), {d} still held", .{ dropped, peers.live });
}

/// How long the loop may wait for the next datagram.
///
/// Note:
/// - The soonest deadline any peer holds, capped by the tick interval. With no peers at all it is
///   the tick interval, so a bound socket with nobody on it still wakes up regularly rather than
///   parking forever.
///
/// Param:
/// peers - *table.Table
/// now_ms - u64 (monotonic milliseconds)
/// config - WebrtcServerConfig
///
/// Return:
/// - u32 (milliseconds)
pub fn waitMs(peers: *table.Table, now_ms: u64, config: WebrtcServerConfig) u32 {
    const soonest = peers.earliestDeadline() orelse return config.tick_interval_ms;

    if (soonest <= now_ms) return 0;

    return @intCast(@min(soonest - now_ms, @as(u64, config.tick_interval_ms)));
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

const Tls = @import("../../../tls/Tls.zig");

/// Mutable because Tls.Context owns its certificate bytes, so the field is not const.
var test_certificate_der = [_]u8{ 0x30, 0x03, 0x01, 0x02, 0x03 };

/// A context carrying just the two fields this engine reads, so a test needs no certificate file.
fn testContext(allocator: std.mem.Allocator) !Tls.Context {
    var secret: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&secret, "0b76f7f1c7bf6e20029ddb566795e58da5ba63ffbdb914bf699bfbed3147d32c");

    return .{
        .allocator = allocator,
        .cert_der = &test_certificate_der,
        .signing_key = .{ .ecdsa_p256 = try EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(secret)) },
        .alpn = &.{},
        .curves = &.{},
        .ciphers = &.{},
        .min_version = .TLS_1_3,
        .max_version = .TLS_1_3,
        .prefer_server_ciphers = false,
        .hsts_max_age_s = 0,
    };
}

fn testConfig(io: std.Io, allocator: std.mem.Allocator, tls: *Tls.Context) WebrtcServerConfig {
    return .{
        .io = io,
        .allocator = allocator,
        .ip = "127.0.0.1",
        .port = 9083,
        .dispatch_model = .ASYNC,
        .ice_ufrag = "zixL",
        .ice_password = "zixlocalpasswordaaaaaa",
        .peer_ice_ufrag = "peer",
        .tls = tls,
    };
}

test "zix webrtc: dispatch common, options carry the config through unchanged" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    var tls = try testContext(std.testing.allocator);
    var config = testConfig(threaded.io(), std.testing.allocator, &tls);
    config.path_max_bytes = 1100;
    config.max_channels = 8;
    config.peer_idle_ms = 12_000;

    const options = optionsFrom(config);

    try std.testing.expectEqualStrings("zixL", options.ice_ufrag);
    try std.testing.expectEqualStrings("peer", options.peer_ice_ufrag);
    try std.testing.expectEqual(@as(usize, 1100), options.path_max_bytes);
    try std.testing.expectEqual(@as(usize, 8), options.max_channels);
    try std.testing.expectEqual(@as(u32, 12_000), options.peer_idle_ms);
    try std.testing.expectEqual(config.max_recv_buf, options.max_datagram_bytes);
}

test "zix webrtc: dispatch common, the send buffer always holds a wrapped path-sized packet" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    var tls = try testContext(std.testing.allocator);
    var config = testConfig(threaded.io(), std.testing.allocator, &tls);
    config.max_recv_buf = 512;
    config.path_max_bytes = 1200;

    try std.testing.expect(sendBufBytes(config) >= config.path_max_bytes + connection.DTLS_OVERHEAD);
}

test "zix webrtc: dispatch common, drawn secrets never carry a zero initiate tag" {
    for (0..64) |_| {
        const secrets = drawSecrets();

        try std.testing.expect(secrets.sctp_tag != 0);
    }
}

test "zix webrtc: dispatch common, drawn secrets differ between connections" {
    const first = drawSecrets();
    const second = drawSecrets();

    try std.testing.expect(!std.mem.eql(u8, &first.server_random, &second.server_random));
    try std.testing.expect(!std.mem.eql(u8, &first.dtls_cookie, &second.dtls_cookie));
}

test "zix webrtc: dispatch common, an unread clock reports no time passed" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const start = std.Io.Clock.Timestamp.now(threaded.io(), .awake);

    try std.testing.expectEqual(@as(u64, 0), elapsedMs(start, start));
}

test "zix webrtc: dispatch common, an empty table waits the tick interval" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    var tls = try testContext(std.testing.allocator);
    var config = testConfig(threaded.io(), std.testing.allocator, &tls);
    config.tick_interval_ms = 250;

    var peers = try table.Table.init(std.testing.allocator, 4);
    defer peers.deinit();

    try std.testing.expectEqual(@as(u32, 250), waitMs(&peers, 1_000, config));
}

test "zix webrtc: dispatch common, a deadline already passed means no waiting at all" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    var tls = try testContext(std.testing.allocator);
    const config = testConfig(threaded.io(), std.testing.allocator, &tls);

    var peers = try table.Table.init(std.testing.allocator, 4);
    defer peers.deinit();

    _ = (try peers.acquire(.{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 5000 } }, optionsFrom(config), drawSecrets(), 0)).?;

    // The peer's idle deadline sits at 30 seconds, so before then the wait is capped by the tick
    // interval, and after it there is nothing left to wait for.
    try std.testing.expectEqual(config.tick_interval_ms, waitMs(&peers, 0, config));
    try std.testing.expectEqual(@as(u32, 0), waitMs(&peers, 30_000, config));
}
