//! zix WebRTC worker: the peers one dispatch worker holds, and the fixed order it answers them in.
//!
//! What:
//! - One worker's whole state: its peer table, the batch its replies are queued into, and where that
//!   batch sends. Every dispatch model builds one of these, so the three loops differ only in how
//!   they learn a datagram arrived.
//! - The drain order lives here and nowhere else: send what the peer owes, tell the application what
//!   arrived, then send what the application produced.
//!
//! Note:
//! - Reversing the last two loses a reply until the next datagram. connection.zig clears its
//!   outbound queue at the top of every handle, so a loop that feeds it several datagrams without
//!   draining between them drops the earlier replies.
//! - One batch carries every peer's replies for a wake, so a wake that answered four peers costs one
//!   send syscall on Linux. Off Linux the batch's portable sink sends them through std.Io one at a
//!   time, which is what the raw UDP engine already does there.
//! - Nothing here reads a clock. The caller passes the time in, which is what keeps a whole session
//!   testable with no socket and no waiting.

const std = @import("std");

const Config = @import("../config.zig");
const WebrtcServerConfig = Config.WebrtcServerConfig;
const common = @import("common.zig");
const connection = @import("../connection.zig");
const core = @import("../core.zig");
const datagram = @import("../../datagram.zig");
const table = @import("../table.zig");

const IpAddress = std.Io.net.IpAddress;

/// How many replies one worker queues before the batch is put on the wire to make room. Sized for a
/// wake that answered a handful of peers, each owing a handshake flight.
pub const SEND_BATCH: usize = 64;

/// Everything building a worker can raise.
pub const Error = error{OutOfMemory};

/// The peers one dispatch worker holds, and how they are answered.
///
/// Usage:
/// ```zig
/// var worker = try Worker.initDescriptor(config, fd);
/// defer worker.deinit();
///
/// worker.serve(handler, address, datagram, now_ms);
/// worker.flush();
/// ```
pub const Worker = struct {
    config: WebrtcServerConfig,
    /// The per-connection options every peer this worker opens is built with.
    options: connection.Options,
    peers: table.Table,
    /// Replies waiting to go out, for every peer this worker holds.
    tx: datagram.SendBatch,
    /// Scratch for one outbound datagram, on its way from a peer into the batch.
    out: []u8,
    /// Where the batch flushes. Ignored when the batch carries a portable sink.
    fd: std.posix.socket_t,

    /// Build a worker that sends through a raw descriptor, which is the two Linux models.
    ///
    /// Param:
    /// config - WebrtcServerConfig (already validated by the server)
    /// fd - std.posix.socket_t (the bound socket this worker receives and replies on)
    ///
    /// Return:
    /// - Worker
    /// - error.OutOfMemory
    pub fn initDescriptor(config: WebrtcServerConfig, fd: std.posix.socket_t) Error!Worker {
        return build(config, fd, null);
    }

    /// Build a worker that sends through a std.Io socket, which is the portable model.
    ///
    /// Param:
    /// config - WebrtcServerConfig (already validated by the server)
    /// socket - std.Io.net.Socket (the bound socket this worker receives and replies on)
    ///
    /// Return:
    /// - Worker
    /// - error.OutOfMemory
    pub fn initSocket(config: WebrtcServerConfig, socket: std.Io.net.Socket) Error!Worker {
        return build(config, socket.handle, .{ .socket = socket, .io = config.io });
    }

    /// Free the peers and the buffers.
    pub fn deinit(self: *Worker) void {
        self.peers.deinit();
        self.tx.deinit();
        self.config.allocator.free(self.out);
    }

    /// Give one datagram to the peer it came from, opening that peer when the address is new.
    ///
    /// Note:
    /// - A datagram from an unknown address past the table's ceiling is dropped, which reads to that
    ///   peer as a connectivity check nobody answered. It retransmits and gets in once a slot frees.
    ///
    /// Param:
    /// handler - comptime core.HandlerFn
    /// address - IpAddress (who sent it)
    /// bytes - []const u8 (the datagram, borrowed for this call)
    /// now_ms - u64 (monotonic milliseconds)
    ///
    /// Return:
    /// - void
    pub fn serve(self: *Worker, comptime handler: core.HandlerFn, address: IpAddress, bytes: []const u8, now_ms: u64) void {
        const peer = self.peers.find(address) orelse open: {
            const opened = self.peers.acquire(address, self.options, common.drawSecrets(), now_ms) catch |err| {
                common.logSystem(self.config, "could not open a peer: {s}", .{@errorName(err)});

                return;
            };

            break :open opened orelse {
                common.logSystem(self.config, "peer table is full ({d}), dropping a datagram from a new address", .{self.peers.live});

                return;
            };
        };

        const outcome = peer.handle(bytes, now_ms) catch |err| {
            common.logSystem(self.config, "peer raised {s}", .{@errorName(err)});

            return;
        };

        if (outcome.dead) {
            _ = self.peers.release(address);

            return;
        }

        if (outcome.established) common.logSystem(self.config, "peer completed the dtls handshake", .{});

        self.drainPeer(handler, peer, now_ms);
    }

    /// Give every peer its due deadlines, drain what that produced, and let go of the finished.
    ///
    /// Param:
    /// handler - comptime core.HandlerFn
    /// now_ms - u64 (monotonic milliseconds)
    ///
    /// Return:
    /// - void
    pub fn sweep(self: *Worker, comptime handler: core.HandlerFn, now_ms: u64) void {
        var walk = self.peers.iterator();
        while (walk.next()) |peer| {
            const outcome = peer.tick(now_ms);

            if (outcome.dead) continue;

            self.drainPeer(handler, peer, now_ms);
        }

        const dropped = self.peers.dropDead();

        if (dropped > 0) common.logSystem(self.config, "dropped {d} peer(s), {d} still held", .{ dropped, self.peers.live });
    }

    /// Put everything queued on the wire.
    ///
    /// Note:
    /// - A failed send clears the batch rather than retrying it. UDP promises no delivery, and every
    ///   layer above this one already retransmits what it cannot lose.
    pub fn flush(self: *Worker) void {
        if (self.tx.count == 0) return;

        self.tx.flush(self.fd) catch |err| {
            common.logSystem(self.config, "send batch failed: {s}", .{@errorName(err)});

            self.tx.reset();
        };
    }

    /// How long this worker may wait for the next datagram.
    ///
    /// Note:
    /// - The soonest deadline any peer holds, capped by the tick interval. With no peers at all it
    ///   is the tick interval, so a bound socket with nobody on it still wakes up regularly rather
    ///   than parking forever.
    ///
    /// Param:
    /// now_ms - u64 (monotonic milliseconds)
    ///
    /// Return:
    /// - u32 (milliseconds)
    pub fn waitMs(self: *Worker, now_ms: u64) u32 {
        const soonest = self.peers.earliestDeadline() orelse return self.config.tick_interval_ms;

        if (soonest <= now_ms) return 0;

        return @intCast(@min(soonest - now_ms, @as(u64, self.config.tick_interval_ms)));
    }

    /// True when a peer's deadline has come and the sweep is owed a pass.
    ///
    /// Param:
    /// now_ms - u64 (monotonic milliseconds)
    ///
    /// Return:
    /// - bool
    pub fn sweepDue(self: *Worker, now_ms: u64) bool {
        const soonest = self.peers.earliestDeadline() orelse return false;

        return soonest <= now_ms;
    }

    /// Answer one peer: send what it owes, tell the application what arrived, then send what the
    /// application produced.
    ///
    /// Note:
    /// - Two queue passes, and both are needed. The first carries acknowledgements and handshake
    ///   flights. The second carries whatever the handler queued, which does not exist until the
    ///   handler has run.
    fn drainPeer(self: *Worker, comptime handler: core.HandlerFn, peer: *connection.Connection, now_ms: u64) void {
        self.queueOutbound(peer, now_ms);

        while (peer.nextEvent(now_ms) catch null) |event| {
            var ctx = peer.context(now_ms) orelse break;

            handler(event, &ctx) catch |err| common.logSystem(self.config, "handler returned {s}", .{@errorName(err)});
        }

        self.queueOutbound(peer, now_ms);
    }

    /// Move everything one peer has waiting into the batch.
    fn queueOutbound(self: *Worker, peer: *connection.Connection, now_ms: u64) void {
        const destination = datagram.ipToSockaddr6(peer.address);

        while (peer.nextOutbound(now_ms, self.out) catch null) |packet| {
            if (self.tx.queue(destination, packet)) continue;

            // The batch is full: put it on the wire, then take the reply that did not fit.
            self.flush();

            if (!self.tx.queue(destination, packet)) {
                common.logSystem(self.config, "dropped a {d} byte reply the send batch could not hold", .{packet.len});
            }
        }
    }

    /// The shared construction both entry points end in.
    fn build(config: WebrtcServerConfig, fd: std.posix.socket_t, portable: ?datagram.PortableSink) Error!Worker {
        const datagram_bytes = common.sendBufBytes(config);

        var peers = try table.Table.init(config.allocator, config.max_peers);
        errdefer peers.deinit();

        var tx = try datagram.SendBatch.init(config.allocator, SEND_BATCH, SEND_BATCH * datagram_bytes);
        errdefer tx.deinit();

        tx.portable = portable;

        const out = try config.allocator.alloc(u8, datagram_bytes);

        return .{
            .config = config,
            .options = common.optionsFrom(config),
            .peers = peers,
            .tx = tx,
            .out = out,
            .fd = fd,
        };
    }
};

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

const Tls = @import("../../../tls/Tls.zig");
const dialer = @import("../dialer.zig");
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

/// Mutable because Tls.Context owns its certificate bytes, so the field is not const.
var test_certificate_der = [_]u8{ 0x30, 0x03, 0x01, 0x02, 0x03 };

fn noopHandler(_: core.Event, _: *core.Context) !void {}

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
        .max_peers = 4,
    };
}

fn testAddress(port: u16) IpAddress {
    return .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } };
}

/// A datagram socket on whatever port the kernel has free, so a worker in a test is built the way
/// the portable model builds one rather than on a descriptor that is not a socket.
///
/// Note:
/// - std.posix.socket_t is a pointer on Windows, so there is no portable stand-in value to pass
///   instead. A real socket is also what lets these tests flush without minding where it goes.
fn testSocket(io: std.Io) !std.Io.net.Socket {
    const local = try std.Io.net.IpAddress.parse("127.0.0.1", 0);

    return local.bind(io, .{ .mode = .dgram, .protocol = .udp });
}

test "zix webrtc: worker, a new worker holds nobody and waits the tick interval" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    var tls = try testContext(std.testing.allocator);
    var config = testConfig(threaded.io(), std.testing.allocator, &tls);
    config.tick_interval_ms = 250;

    const socket = try testSocket(threaded.io());
    defer socket.close(threaded.io());

    var worker = try Worker.initSocket(config, socket);
    defer worker.deinit();

    try std.testing.expectEqual(@as(usize, 0), worker.peers.live);
    try std.testing.expectEqual(@as(u32, 250), worker.waitMs(1_000));
    try std.testing.expect(!worker.sweepDue(1_000));
}

test "zix webrtc: worker, a deadline already passed means no waiting and a sweep is owed" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    var tls = try testContext(std.testing.allocator);
    const config = testConfig(threaded.io(), std.testing.allocator, &tls);

    const socket = try testSocket(threaded.io());
    defer socket.close(threaded.io());

    var worker = try Worker.initSocket(config, socket);
    defer worker.deinit();

    _ = (try worker.peers.acquire(testAddress(5000), worker.options, common.drawSecrets(), 0)).?;

    // The peer's idle deadline sits at 30 seconds, so before then the wait is capped by the tick
    // interval, and after it there is nothing left to wait for.
    try std.testing.expectEqual(config.tick_interval_ms, worker.waitMs(0));
    try std.testing.expect(!worker.sweepDue(0));

    try std.testing.expectEqual(@as(u32, 0), worker.waitMs(30_000));
    try std.testing.expect(worker.sweepDue(30_000));
}

test "zix webrtc: worker, a connectivity check is answered into the send batch" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    var tls = try testContext(std.testing.allocator);
    const config = testConfig(threaded.io(), std.testing.allocator, &tls);

    const socket = try testSocket(threaded.io());
    defer socket.close(threaded.io());

    var worker = try Worker.initSocket(config, socket);
    defer worker.deinit();

    var peer = try dialer.Dialer.init(std.testing.allocator, .{
        .local_ufrag = "peer",
        .local_password = "peerpasswordbbbbbbbbbb",
        .peer_ufrag = "zixL",
        .peer_password = "zixlocalpasswordaaaaaa",
        .transaction_id = @splat(0x77),
        .client_random = @splat(0x11),
        .client_eph_secret = @splat(0x44),
        .sctp_cookie = @splat(0x9C),
        .sctp_tag = 0x55667788,
        .sctp_initial_tsn = 5000,
    }, 0);
    defer peer.deinit();

    var send_buf: [1500]u8 = undefined;
    const check = (try peer.nextOutbound(0, &send_buf)).?;

    worker.serve(noopHandler, testAddress(5000), check, 0);

    // The peer is now held, and its success response is queued rather than already sent.
    try std.testing.expectEqual(@as(usize, 1), worker.peers.live);
    try std.testing.expectEqual(@as(usize, 1), worker.tx.count);
}

test "zix webrtc: worker, a datagram nobody can parse still opens the peer and queues nothing" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    var tls = try testContext(std.testing.allocator);
    const config = testConfig(threaded.io(), std.testing.allocator, &tls);

    const socket = try testSocket(threaded.io());
    defer socket.close(threaded.io());

    var worker = try Worker.initSocket(config, socket);
    defer worker.deinit();

    worker.serve(noopHandler, testAddress(5000), &[_]u8{ 22, 0xFE, 0xFD, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 1, 2, 3, 4 }, 0);

    try std.testing.expectEqual(@as(usize, 1), worker.peers.live);
    try std.testing.expectEqual(@as(usize, 0), worker.tx.count);
}

test "zix webrtc: worker, a table at its ceiling drops the stranger and keeps the peers it has" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    var tls = try testContext(std.testing.allocator);
    var config = testConfig(threaded.io(), std.testing.allocator, &tls);
    config.max_peers = 2;

    const socket = try testSocket(threaded.io());
    defer socket.close(threaded.io());

    var worker = try Worker.initSocket(config, socket);
    defer worker.deinit();

    const garbage = [_]u8{ 22, 0xFE, 0xFD, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 1, 2, 3, 4 };

    worker.serve(noopHandler, testAddress(5000), &garbage, 0);
    worker.serve(noopHandler, testAddress(5001), &garbage, 0);
    worker.serve(noopHandler, testAddress(5002), &garbage, 0);

    try std.testing.expectEqual(@as(usize, 2), worker.peers.live);
    try std.testing.expect(worker.peers.find(testAddress(5000)) != null);
    try std.testing.expect(worker.peers.find(testAddress(5002)) == null);
}

test "zix webrtc: worker, the sweep lets go of a peer that stopped speaking" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    var tls = try testContext(std.testing.allocator);
    var config = testConfig(threaded.io(), std.testing.allocator, &tls);
    config.peer_idle_ms = 5_000;

    const socket = try testSocket(threaded.io());
    defer socket.close(threaded.io());

    var worker = try Worker.initSocket(config, socket);
    defer worker.deinit();

    _ = (try worker.peers.acquire(testAddress(5000), worker.options, common.drawSecrets(), 0)).?;

    worker.sweep(noopHandler, 4_999);
    try std.testing.expectEqual(@as(usize, 1), worker.peers.live);

    worker.sweep(noopHandler, 5_000);
    try std.testing.expectEqual(@as(usize, 0), worker.peers.live);
}
