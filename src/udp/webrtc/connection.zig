//! zix WebRTC connection: one peer, and the four layers a datagram from it can belong to.
//!
//! What:
//! - The state machine that turns "a datagram arrived from this address" into "here is what goes
//!   back, and here is what the application has to know about". ICE answers checks, DTLS runs the
//!   handshake and then wraps everything, SCTP carries the association, and the channel layer turns
//!   it into messages.
//! - Owns no socket and reads no clock. Every entry point takes the time from the caller and hands
//!   back bytes, which is what makes a full exchange testable in memory with no port and no sleep.
//!
//! Note:
//! - One connection is one peer address. A peer that migrates to a new address is a new connection
//!   to this file, which is correct for ICE-lite: the address that answers checks is the pair, and
//!   a changed address is a new pair the peer has to nominate.
//! - The layers are built in the order the wire builds them. There is no SCTP association until
//!   the DTLS handshake finishes, because the keys that protect it do not exist before then.
//! - Errors from a peer are the peer's problem. A malformed SCTP packet, a check that fails
//!   authentication, and a handshake message out of order all leave the connection alive, because
//!   the alternative is letting anyone who can guess an address end someone else's session.

const std = @import("std");

const core = @import("core.zig");
const datachannel = @import("datachannel/peer.zig");
const demux = @import("demux.zig");
const dtls_cookie = @import("../../tls/dtls_cookie.zig");
const dtls_session = @import("dtls_session.zig");
const ice_credentials = @import("ice/credentials.zig");
const ice_lite = @import("ice/lite.zig");
const association = @import("sctp/association.zig");
const sctp_cookie = @import("sctp/cookie.zig");
const timer = @import("timer.zig");

const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const IpAddress = std.Io.net.IpAddress;

/// What a DTLS record adds around one SCTP packet: the header, the explicit nonce, and the tag.
pub const DTLS_OVERHEAD: usize = 13 + 8 + 16;

/// How many packets one received datagram may leave queued for sending.
///
/// Note:
/// - One datagram normally produces one, being the acknowledgement for the packet it carried.
///   Past this ceiling the rest are not built, and SCTP retransmits whatever went unacknowledged.
pub const MAX_QUEUED: usize = 8;

/// The random values one connection needs at birth.
///
/// Note:
/// - Taken from the caller rather than drawn here, so a test can pin them and the engine can draw
///   them from the one place that is allowed to reach for ambient state.
/// - `server_random` and `server_eph_secret` belong to exactly one handshake and are never reused
///   across connections.
pub const Secrets = struct {
    /// Signs the DTLS cookie that makes the first ClientHello stateless (RFC 6347 4.2.1).
    dtls_cookie: [dtls_cookie.SECRET_LEN]u8,
    /// Signs the SCTP state cookie, for the same reason one layer up (RFC 9260 5.1.3).
    sctp_cookie: [sctp_cookie.SECRET_LEN]u8,
    server_random: [32]u8,
    server_eph_secret: [32]u8,
    /// The association's initiate tag, which the peer echoes in every packet. Never zero.
    sctp_tag: u32,
    /// The first TSN the association will use.
    sctp_initial_tsn: u32,
};

/// What one connection is built with. Assembled by the engine from its config.
pub const Options = struct {
    /// This agent's ICE credentials, the pair every check is verified against. Borrowed.
    ice_ufrag: []const u8,
    ice_password: []const u8,
    /// The peer's ufrag, the second half of the USERNAME its checks carry. Borrowed. Null takes
    /// whatever the peer calls itself, which is what a peer that draws its own ufrag needs.
    peer_ice_ufrag: ?[]const u8,

    /// The certificate this server presents, DER encoded. Borrowed.
    certificate_der: []const u8,
    signing_key: EcdsaP256.KeyPair,
    max_handshake_fragment: usize = 1024,

    /// Largest datagram this connection sends.
    path_max_bytes: usize = 1200,
    /// Largest datagram this connection is handed.
    max_datagram_bytes: usize = 1500,

    outbound_streams: u16 = 128,
    inbound_streams: u16 = 128,
    max_channels: usize = 64,

    /// How long the peer may say nothing before the connection is dropped.
    peer_idle_ms: u32 = 30000,
    /// How long after the last authenticated check consent lapses (RFC 7675 5.1).
    consent_timeout_ms: u32 = 30000,
};

/// Everything driving one connection can raise.
pub const Error = datachannel.Error || dtls_session.Error;

/// What one datagram, or one tick, did.
pub const Outcome = struct {
    /// The DTLS handshake completed, so the association exists from here on.
    established: bool = false,
    /// Messages may be waiting, see `nextEvent`.
    delivered: bool = false,
    /// The connection is finished and the engine should drop it.
    dead: bool = false,
};

/// One WebRTC peer.
///
/// Usage:
/// ```zig
/// var conn = try Connection.init(allocator, peer_address, options, secrets, now_ms);
/// defer conn.deinit();
///
/// _ = try conn.handle(datagram, now_ms);
///
/// var out: [1500]u8 = undefined;
/// while (try conn.nextOutbound(now_ms, &out)) |packet| try socket.send(packet);
/// while (try conn.nextEvent(now_ms)) |event| try handler(event, &conn.context(now_ms).?);
/// ```
pub const Connection = struct {
    allocator: std.mem.Allocator,
    /// Where this peer sits. One connection is one address.
    address: IpAddress,
    options: Options,
    secrets: Secrets,

    ice: ice_lite.Responder,
    dtls: dtls_session.Session,
    /// Heap-allocated so the channel layer's pointer into it survives this struct being moved.
    sctp: ?*association.Association,
    channels: ?datachannel.Peer,

    deadlines: timer.Deadlines,
    /// Outstanding SCTP chunks at the last look, for spotting an acknowledgement that took some
    /// off the list (RFC 9260 6.3.2 R3).
    outstanding: usize,

    /// The ICE response to the last check, waiting to go out.
    ice_reply: [ice_lite.MAX_RESPONSE_BYTES]u8,
    ice_reply_len: usize,

    /// Packets built while handling one datagram, already wrapped in DTLS, packed back to back.
    queue: []u8,
    queue_len: [MAX_QUEUED]usize,
    queue_count: usize,
    queue_used: usize,
    queue_taken: usize,
    queue_offset: usize,

    /// Where one SCTP packet is built before it is wrapped.
    scratch: []u8,

    dead: bool,

    /// Build a connection for a peer that has just been heard from.
    ///
    /// Param:
    /// allocator - std.mem.Allocator (owns the buffers and, later, the association)
    /// address - IpAddress (where the peer sits)
    /// options - Options (borrows every slice in it, which must outlive the connection)
    /// secrets - Secrets
    /// now_ms - u64 (monotonic milliseconds, when the idle deadline starts counting)
    ///
    /// Return:
    /// - Connection with nothing negotiated yet
    /// - error.OutOfMemory
    pub fn init(
        allocator: std.mem.Allocator,
        address: IpAddress,
        options: Options,
        secrets: Secrets,
        now_ms: u64,
    ) Error!Connection {
        var dtls = try dtls_session.Session.init(allocator, address, .{
            .certificate_der = options.certificate_der,
            .signing_key = options.signing_key,
            .cookie_secret = secrets.dtls_cookie,
            .server_random = secrets.server_random,
            .server_eph_secret = secrets.server_eph_secret,
            .max_fragment_len = options.max_handshake_fragment,
            .path_max_bytes = options.path_max_bytes,
        }, options.max_datagram_bytes);
        errdefer dtls.deinit();

        const queue = try allocator.alloc(u8, MAX_QUEUED * (options.path_max_bytes + DTLS_OVERHEAD));
        errdefer allocator.free(queue);

        const scratch = try allocator.alloc(u8, options.path_max_bytes);

        var deadlines: timer.Deadlines = .{};
        deadlines.armIn(.IDLE, now_ms, options.peer_idle_ms);

        return .{
            .allocator = allocator,
            .address = address,
            .options = options,
            .secrets = secrets,
            .ice = .{
                .local = .{ .ufrag = options.ice_ufrag, .password = options.ice_password },
                .remote_ufrag = options.peer_ice_ufrag,
            },
            .dtls = dtls,
            .sctp = null,
            .channels = null,
            .deadlines = deadlines,
            .outstanding = 0,
            .ice_reply = undefined,
            .ice_reply_len = 0,
            .queue = queue,
            .queue_len = @splat(0),
            .queue_count = 0,
            .queue_used = 0,
            .queue_taken = 0,
            .queue_offset = 0,
            .scratch = scratch,
            .dead = false,
        };
    }

    /// Free everything the connection holds.
    pub fn deinit(self: *Connection) void {
        if (self.channels) |*channels| channels.deinit();

        if (self.sctp) |sctp| {
            sctp.deinit();
            self.allocator.destroy(sctp);
        }

        self.dtls.deinit();
        self.allocator.free(self.queue);
        self.allocator.free(self.scratch);
    }

    /// Whether the engine should drop this peer.
    pub fn isDead(self: Connection) bool {
        return self.dead;
    }

    /// Whether the association is up and channels can carry messages.
    pub fn isEstablished(self: Connection) bool {
        return self.dtls.isEstablished();
    }

    /// When this connection next needs looking at, or null when it needs nothing.
    pub fn deadline(self: Connection) ?u64 {
        return self.deadlines.earliest();
    }

    /// Handle one datagram from this peer.
    ///
    /// Param:
    /// datagram - []const u8 (one received datagram)
    /// now_ms - u64 (monotonic milliseconds)
    ///
    /// Return:
    /// - Outcome
    /// - error.OutOfMemory, error.NoSpace
    pub fn handle(self: *Connection, datagram: []const u8, now_ms: u64) Error!Outcome {
        if (self.dead) return .{ .dead = true };

        self.resetQueue();
        self.deadlines.armIn(.IDLE, now_ms, self.options.peer_idle_ms);

        var outcome: Outcome = .{};

        switch (demux.classify(datagram)) {
            .STUN => self.onStun(datagram, now_ms),
            .DTLS => try self.onDtls(datagram, now_ms, &outcome),
            // Media is routed correctly and then dropped. Answering it is phase 12, and a peer
            // that was never offered media has no reason to send any.
            .RTP => {},
            else => {},
        }

        self.syncDeadlines(now_ms);
        outcome.dead = self.dead;

        return outcome;
    }

    /// Act on every deadline that has passed.
    ///
    /// Note:
    /// - Cheap to call on every loop pass. With nothing due it does nothing.
    ///
    /// Param:
    /// now_ms - u64 (monotonic milliseconds)
    ///
    /// Return:
    /// - Outcome
    pub fn tick(self: *Connection, now_ms: u64) Outcome {
        if (self.dead) return .{ .dead = true };

        while (self.deadlines.takeExpired(now_ms)) |kind| switch (kind) {
            .DTLS_RETRANSMIT => {
                _ = self.dtls.onTimeout(now_ms);

                if (self.dtls.state == .FAILED) self.dead = true;
            },
            .SCTP_RETRANSMIT => {
                if (self.sctp) |sctp| sctp.onRetransmitTimeout(now_ms);
            },
            // A peer that stopped proving it is there, or stopped speaking at all, is gone.
            .ICE_CONSENT, .IDLE => self.dead = true,
        };

        self.syncDeadlines(now_ms);

        return .{ .dead = self.dead };
    }

    /// The next datagram to send to this peer.
    ///
    /// Note:
    /// - Call in a loop until it returns null. The order is fixed: the ICE response first, then
    ///   the DTLS handshake, then what the association owes. Nothing later matters to a peer that
    ///   has not finished the step before it.
    ///
    /// Param:
    /// now_ms - u64 (monotonic milliseconds)
    /// out - []u8 (destination, at least path_max_bytes wide)
    ///
    /// Return:
    /// - ?[]const u8 (a datagram, borrowing out)
    /// - error.NoSpace when out cannot hold what was ready
    pub fn nextOutbound(self: *Connection, now_ms: u64, out: []u8) Error!?[]const u8 {
        if (self.ice_reply_len > 0) {
            const reply = self.ice_reply[0..self.ice_reply_len];
            self.ice_reply_len = 0;

            return try copyOut(reply, out);
        }

        if (self.dtls.nextOutbound(out)) |piece| return piece;

        if (self.takeQueued()) |packet| return try copyOut(packet, out);

        if (!self.dtls.isEstablished()) return null;

        if (self.channels) |*channels| {
            const packet = (try channels.nextOutbound(now_ms, self.scratch)) orelse return null;
            const wrapped = try self.dtls.writeAppData(packet, out);

            self.syncDeadlines(now_ms);

            return wrapped;
        }

        return null;
    }

    /// The next thing the application has to know about.
    ///
    /// Note:
    /// - Call in a loop until it returns null. A message payload is valid until the next call.
    ///
    /// Param:
    /// now_ms - u64 (monotonic milliseconds)
    ///
    /// Return:
    /// - ?core.Event
    pub fn nextEvent(self: *Connection, now_ms: u64) Error!?core.Event {
        if (self.channels) |*channels| {
            const event = (try channels.nextEvent(now_ms)) orelse return null;

            return switch (event) {
                .CHANNEL_OPEN => |identifier| .{ .CHANNEL_OPEN = identifier },
                .CHANNEL_CLOSED => |identifier| .{ .CHANNEL_CLOSED = identifier },
                .MESSAGE => |incoming| .{ .MESSAGE = .{
                    .channel = incoming.stream_identifier,
                    .kind = incoming.kind,
                    .payload = incoming.payload,
                } },
            };
        }

        return null;
    }

    /// The handle a handler answers this peer through, or null before the association exists.
    ///
    /// Param:
    /// now_ms - u64 (monotonic milliseconds)
    ///
    /// Return:
    /// - ?core.Context
    pub fn context(self: *Connection, now_ms: u64) ?core.Context {
        if (self.channels) |*channels| return .{
            .channels = channels,
            .address = self.address,
            .now_ms = now_ms,
        };

        return null;
    }

    /// Answer one datagram that demux routed to STUN.
    fn onStun(self: *Connection, datagram: []const u8, now_ms: u64) void {
        const outcome = self.ice.respond(datagram, &self.address, &self.ice_reply);

        self.ice_reply_len = if (outcome.reply) |reply| reply.len else 0;

        // A check that verified is the peer proving it is still there, which is the whole of
        // consent for a lite agent (RFC 7675 5.1).
        if (outcome.authenticated) self.deadlines.armIn(.ICE_CONSENT, now_ms, self.options.consent_timeout_ms);
    }

    /// Take one datagram that demux routed to DTLS, and everything it unwraps into.
    fn onDtls(self: *Connection, datagram: []const u8, now_ms: u64, outcome: *Outcome) Error!void {
        const result = try self.dtls.handle(datagram, now_ms);

        if (result.failed) {
            self.dead = true;

            return;
        }

        if (result.established) {
            try self.startAssociation();
            outcome.established = true;
        }

        if (self.channels == null) return;

        while (self.dtls.nextAppData()) |packet| {
            const sctp_outcome = self.channels.?.handle(packet, now_ms, self.scratch) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // Anything else is one malformed packet, and the association survives it.
                else => continue,
            };

            if (sctp_outcome.reply) |reply| try self.queueAppData(reply);
            if (sctp_outcome.delivered) outcome.delivered = true;
            if (sctp_outcome.aborted or sctp_outcome.closed) self.dead = true;
        }
    }

    /// Build the association and the channels over it, which the finished handshake now allows.
    fn startAssociation(self: *Connection) Error!void {
        const sctp = try self.allocator.create(association.Association);
        errdefer self.allocator.destroy(sctp);

        sctp.* = try association.Association.init(self.allocator, .{
            .outbound_streams = self.options.outbound_streams,
            .inbound_streams = self.options.inbound_streams,
            .path_max_bytes = self.options.path_max_bytes -| DTLS_OVERHEAD,
        }, self.secrets.sctp_cookie, .{
            .tag = self.secrets.sctp_tag,
            .initial_tsn = self.secrets.sctp_initial_tsn,
        });

        self.sctp = sctp;
        self.channels = datachannel.Peer.init(self.allocator, sctp, .{
            // zix answers the handshake, so it is always the DTLS server, and that is what decides
            // which identifiers it may open channels on (RFC 8832 6).
            .role = .DTLS_SERVER,
            .limits = .{ .max_channels = self.options.max_channels },
        });
    }

    /// Bring the deadline set in line with what the layers below are actually waiting on.
    fn syncDeadlines(self: *Connection, now_ms: u64) void {
        if (self.dtls.deadline()) |at_ms| {
            self.deadlines.arm(.DTLS_RETRANSMIT, at_ms);
        } else {
            self.deadlines.disarm(.DTLS_RETRANSMIT);
        }

        const sctp = self.sctp orelse return;
        const outstanding = sctp.send.count();

        // An acknowledgement that took chunks off the list restarts the timer rather than letting
        // the old deadline run out on data that already got through (RFC 9260 6.3.2 R3).
        if (outstanding < self.outstanding) self.deadlines.disarm(.SCTP_RETRANSMIT);
        self.outstanding = outstanding;

        if (outstanding == 0) {
            self.deadlines.disarm(.SCTP_RETRANSMIT);

            return;
        }

        if (!self.deadlines.isArmed(.SCTP_RETRANSMIT)) {
            self.deadlines.armIn(.SCTP_RETRANSMIT, now_ms, sctp.timer.timeout_ms);
        }
    }

    /// Wrap one SCTP packet and hold it until the outbound pump asks for it.
    fn queueAppData(self: *Connection, packet: []const u8) Error!void {
        if (self.queue_count >= MAX_QUEUED) return;

        const wrapped = try self.dtls.writeAppData(packet, self.queue[self.queue_used..]);

        self.queue_len[self.queue_count] = wrapped.len;
        self.queue_count += 1;
        self.queue_used += wrapped.len;
    }

    /// The next queued packet, or null when the batch is spent.
    fn takeQueued(self: *Connection) ?[]const u8 {
        if (self.queue_taken >= self.queue_count) return null;

        const len = self.queue_len[self.queue_taken];
        const packet = self.queue[self.queue_offset..][0..len];

        self.queue_taken += 1;
        self.queue_offset += len;

        return packet;
    }

    /// Start a fresh batch, because a new datagram is being handled.
    fn resetQueue(self: *Connection) void {
        self.queue_count = 0;
        self.queue_used = 0;
        self.queue_taken = 0;
        self.queue_offset = 0;
    }
};

/// Copy bytes the caller has to own into the caller's buffer.
fn copyOut(bytes: []const u8, out: []u8) error{NoSpace}![]const u8 {
    if (out.len < bytes.len) return error.NoSpace;

    @memcpy(out[0..bytes.len], bytes);

    return out[0..bytes.len];
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

const ice_check = @import("ice/check.zig");
const stun_message = @import("stun/message.zig");

const TEST_ADDRESS: IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 41000 } };
const TEST_DER = [_]u8{ 0x30, 0x03, 0x01, 0x02, 0x03 };
const LOCAL_UFRAG = "zixL";
const LOCAL_PASSWORD = "zixlocalpasswordaaaaaa";
const PEER_UFRAG = "peer";
const PEER_PASSWORD = "peerpasswordbbbbbbbbbb";

fn testSigningKey() !EcdsaP256.KeyPair {
    var secret: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&secret, "0b76f7f1c7bf6e20029ddb566795e58da5ba63ffbdb914bf699bfbed3147d32c");

    return EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(secret));
}

fn testOptions() !Options {
    return .{
        .ice_ufrag = LOCAL_UFRAG,
        .ice_password = LOCAL_PASSWORD,
        .peer_ice_ufrag = PEER_UFRAG,
        .certificate_der = &TEST_DER,
        .signing_key = try testSigningKey(),
    };
}

fn testSecrets() Secrets {
    return .{
        .dtls_cookie = @splat(0x5A),
        .sctp_cookie = @splat(0x6B),
        .server_random = @splat(0x33),
        .server_eph_secret = @splat(0x44),
        .sctp_tag = 0x11223344,
        .sctp_initial_tsn = 1000,
    };
}

/// One ICE connectivity check, the shape a controlling full agent sends.
fn testCheck(out: []u8, use_candidate: bool) ![]const u8 {
    var username_buf: [ice_credentials.MAX_USERNAME_LEN]u8 = undefined;
    const username = try ice_credentials.writeUsername(&username_buf, LOCAL_UFRAG, PEER_UFRAG);

    return try ice_check.writeRequest(out, .{
        .transaction_id = @splat(0x77),
        .username = username,
        .password = LOCAL_PASSWORD,
        .priority = 100,
        .role = .CONTROLLING,
        .tiebreaker = 42,
        .use_candidate = use_candidate,
    });
}

test "zix webrtc: connection, a fresh peer has nothing negotiated and only an idle deadline" {
    var conn = try Connection.init(std.testing.allocator, TEST_ADDRESS, try testOptions(), testSecrets(), 1000);
    defer conn.deinit();

    try std.testing.expect(!conn.isDead());
    try std.testing.expect(!conn.isEstablished());
    try std.testing.expectEqual(@as(?u64, 1000 + 30000), conn.deadline());
    try std.testing.expect(conn.context(1000) == null);

    var out: [1500]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), try conn.nextOutbound(1000, &out));
    try std.testing.expectEqual(@as(?core.Event, null), try conn.nextEvent(1000));
}

test "zix webrtc: connection, an authenticated check is answered and refreshes consent" {
    var conn = try Connection.init(std.testing.allocator, TEST_ADDRESS, try testOptions(), testSecrets(), 0);
    defer conn.deinit();

    var check_buf: [256]u8 = undefined;
    const check = try testCheck(&check_buf, true);

    _ = try conn.handle(check, 5000);

    var out: [1500]u8 = undefined;
    const reply = (try conn.nextOutbound(5000, &out)).?;

    const parsed = try stun_message.parse(reply);
    try std.testing.expectEqual(stun_message.Class.SUCCESS_RESPONSE, parsed.class);
    try std.testing.expectEqual(stun_message.Method.BINDING, parsed.method);

    try std.testing.expectEqual(@as(?u64, 5000 + 30000), conn.deadlines.deadline(.ICE_CONSENT));
    try std.testing.expect(conn.ice.selected != null);

    // One response per check, and nothing else waiting behind it.
    try std.testing.expectEqual(@as(?[]const u8, null), try conn.nextOutbound(5000, &out));
}

test "zix webrtc: connection, a check with the wrong password is refused without consent" {
    var conn = try Connection.init(std.testing.allocator, TEST_ADDRESS, try testOptions(), testSecrets(), 0);
    defer conn.deinit();

    var username_buf: [ice_credentials.MAX_USERNAME_LEN]u8 = undefined;
    const username = try ice_credentials.writeUsername(&username_buf, LOCAL_UFRAG, PEER_UFRAG);

    var check_buf: [256]u8 = undefined;
    const check = try ice_check.writeRequest(&check_buf, .{
        .transaction_id = @splat(0x77),
        .username = username,
        .password = PEER_PASSWORD,
        .priority = 100,
        .role = .CONTROLLING,
        .tiebreaker = 42,
    });

    _ = try conn.handle(check, 5000);

    var out: [1500]u8 = undefined;
    const reply = (try conn.nextOutbound(5000, &out)).?;

    const parsed = try stun_message.parse(reply);
    try std.testing.expectEqual(stun_message.Class.ERROR_RESPONSE, parsed.class);
    try std.testing.expect(!conn.deadlines.isArmed(.ICE_CONSENT));
}

test "zix webrtc: connection, a first client hello brings a cookie back" {
    var conn = try Connection.init(std.testing.allocator, TEST_ADDRESS, try testOptions(), testSecrets(), 0);
    defer conn.deinit();

    var hello_buf: [768]u8 = undefined;
    const hello = try testClientHello(&hello_buf, "", 0);

    const outcome = try conn.handle(hello, 1000);
    try std.testing.expect(!outcome.established);
    try std.testing.expect(!outcome.dead);

    var out: [1500]u8 = undefined;
    try std.testing.expect((try conn.nextOutbound(1000, &out)) != null);

    // The cookie exchange keeps no state, so only the idle deadline is running.
    try std.testing.expect(!conn.deadlines.isArmed(.DTLS_RETRANSMIT));
}

test "zix webrtc: connection, an idle peer is dropped once its deadline passes" {
    var conn = try Connection.init(std.testing.allocator, TEST_ADDRESS, try testOptions(), testSecrets(), 0);
    defer conn.deinit();

    try std.testing.expect(!conn.tick(29_999).dead);
    try std.testing.expect(conn.tick(30_000).dead);
    try std.testing.expect(conn.isDead());

    // A dead connection answers nothing further.
    const outcome = try conn.handle(&[_]u8{ 0, 1, 0, 0 }, 30_001);
    try std.testing.expect(outcome.dead);
}

test "zix webrtc: connection, silence after a nominated check lapses consent" {
    var conn = try Connection.init(std.testing.allocator, TEST_ADDRESS, try testOptions(), testSecrets(), 0);
    defer conn.deinit();

    var check_buf: [256]u8 = undefined;
    _ = try conn.handle(try testCheck(&check_buf, true), 1000);

    try std.testing.expect(!conn.tick(30_999).dead);
    try std.testing.expect(conn.tick(31_000).dead);
}

test "zix webrtc: connection, media is routed and then left alone until it is answered" {
    var conn = try Connection.init(std.testing.allocator, TEST_ADDRESS, try testOptions(), testSecrets(), 0);
    defer conn.deinit();

    const rtp_packet = [_]u8{ 0x80, 0x60, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 };
    const outcome = try conn.handle(&rtp_packet, 1000);

    try std.testing.expect(!outcome.dead);
    try std.testing.expect(!outcome.delivered);

    var out: [1500]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), try conn.nextOutbound(1000, &out));
}

test "zix webrtc: connection, a datagram outside every known range is dropped" {
    var conn = try Connection.init(std.testing.allocator, TEST_ADDRESS, try testOptions(), testSecrets(), 0);
    defer conn.deinit();

    const outcome = try conn.handle(&[_]u8{ 200, 200, 200 }, 1000);

    try std.testing.expect(!outcome.dead);
    try std.testing.expect(!outcome.established);
}

const dtls_handshake = @import("../../tls/dtls_handshake.zig");
const dtls_hello = @import("../../tls/dtls_hello.zig");
const dtls_record = @import("../../tls/dtls_record.zig");
const dtls_connection = @import("../../tls/dtls_connection.zig");

/// One plaintext ClientHello record, with or without a cookie.
fn testClientHello(out: []u8, cookie: []const u8, record_seq: u48) ![]const u8 {
    var body_buf: [512]u8 = undefined;
    const body = try dtls_hello.writeClientHelloBody(
        &body_buf,
        dtls_record.VERSION_DTLS_1_2,
        @splat(0x11),
        "",
        cookie,
        &.{dtls_connection.CIPHER_ECDHE_ECDSA_AES128_GCM_SHA256},
    );

    var message_buf: [640]u8 = undefined;
    var fragmenter: dtls_handshake.Fragmenter = .{
        .msg_type = .CLIENT_HELLO,
        .message_seq = if (cookie.len == 0) 0 else 1,
        .body = body,
        .max_fragment_len = body.len,
    };
    const message = fragmenter.next(&message_buf).?;

    return try dtls_record.writePlaintext(out, .HANDSHAKE, dtls_connection.EPOCH_HANDSHAKE, record_seq, message);
}
