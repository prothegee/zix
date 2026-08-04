//! zix WebRTC in-process exchange: a whole session between a dialer and an answerer.
//!
//! What:
//! - Drives `zix.Webrtc.Dialer` against `zix.Webrtc.Connection` with datagrams handed between them
//!   in memory: ICE checks, the DTLS handshake, the SCTP association, the DCEP channel, and a
//!   message echoed back.
//! - No socket, no port, no sleep. The clock is a variable this file owns, so the whole exchange
//!   runs the same on every platform and finishes as fast as the machine can compute it.
//!
//! Note:
//! - This is the first time two independent zix instances have to agree on every byte. Every layer
//!   below was tested against itself, so anything the two disagree on shows up here and nowhere
//!   earlier.

const std = @import("std");
const zix = @import("zix");

const MAX_DATAGRAM: usize = 1500;
const MAX_IN_FLIGHT: usize = 16;

const ANSWERER_UFRAG = "zixA";
const ANSWERER_PASSWORD = "answererpasswordaaaaaa";
const DIALER_UFRAG = "zixD";
const DIALER_PASSWORD = "dialerpasswordbbbbbbbb";
const CHANNEL_LABEL = "echo";

const ANSWERER_ADDRESS: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 9084 } };
const CERTIFICATE_DER = [_]u8{ 0x30, 0x03, 0x01, 0x02, 0x03 };

const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

/// Datagrams travelling one way, copied out of the sender's buffers so the sender may reuse them.
const Bag = struct {
    bytes: [][MAX_DATAGRAM]u8,
    lens: []usize,
    count: usize,

    fn init(allocator: std.mem.Allocator) !Bag {
        return .{
            .bytes = try allocator.alloc([MAX_DATAGRAM]u8, MAX_IN_FLIGHT),
            .lens = try allocator.alloc(usize, MAX_IN_FLIGHT),
            .count = 0,
        };
    }

    fn deinit(self: *Bag, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.lens);
    }

    fn push(self: *Bag, datagram: []const u8) void {
        if (self.count >= MAX_IN_FLIGHT) return;
        if (datagram.len > MAX_DATAGRAM) return;

        @memcpy(self.bytes[self.count][0..datagram.len], datagram);
        self.lens[self.count] = datagram.len;
        self.count += 1;
    }

    fn at(self: *const Bag, index: usize) []const u8 {
        return self.bytes[index][0..self.lens[index]];
    }

    fn clear(self: *Bag) void {
        self.count = 0;
    }
};

/// The two peers, the wire between them, and what the exchange has proved so far.
const Session = struct {
    allocator: std.mem.Allocator,
    dialer: zix.Webrtc.Dialer,
    answerer: zix.Webrtc.Connection,
    to_answerer: Bag,
    to_dialer: Bag,
    now_ms: u64,

    /// What the dialer sent, once it had a channel.
    sent: bool,
    /// What came back on it.
    echoed: [64]u8,
    echoed_len: usize,
    /// Whether the answerer saw the channel open from its side.
    answerer_saw_open: bool,
    /// Whether the answerer saw the message the dialer sent.
    answerer_saw_message: bool,

    fn init(allocator: std.mem.Allocator) !*Session {
        const session = try allocator.create(Session);
        errdefer allocator.destroy(session);

        session.* = .{
            .allocator = allocator,
            .dialer = try zix.Webrtc.Dialer.init(allocator, dialerOptions(), 0),
            .answerer = try zix.Webrtc.Connection.init(allocator, ANSWERER_ADDRESS, try answererOptions(), answererSecrets(), 0),
            .to_answerer = try Bag.init(allocator),
            .to_dialer = try Bag.init(allocator),
            .now_ms = 0,
            .sent = false,
            .echoed = undefined,
            .echoed_len = 0,
            .answerer_saw_open = false,
            .answerer_saw_message = false,
        };

        return session;
    }

    fn deinit(self: *Session) void {
        self.to_answerer.deinit(self.allocator);
        self.to_dialer.deinit(self.allocator);
        self.answerer.deinit();
        self.dialer.deinit();
        self.allocator.destroy(self);
    }

    /// Run until the dialer has its echo back, or until the round budget runs out.
    ///
    /// Return:
    /// - usize (rounds taken)
    fn run(self: *Session, max_rounds: usize) !usize {
        var rounds: usize = 0;

        while (rounds < max_rounds) : (rounds += 1) {
            if (self.echoed_len > 0) return rounds;

            const moved = try self.round();

            // Nothing moved, so the only thing that can advance the session is a deadline.
            if (moved == 0) {
                self.now_ms += 100;
                _ = try self.dialer.tick(self.now_ms);
                _ = self.answerer.tick(self.now_ms);
            }
        }

        return rounds;
    }

    /// One pass: everything the dialer has to say, then everything that came back.
    fn round(self: *Session) !usize {
        var moved: usize = 0;

        self.to_answerer.clear();
        try self.collectFromDialer();

        self.to_dialer.clear();
        for (0..self.to_answerer.count) |index| {
            _ = try self.answerer.handle(self.to_answerer.at(index), self.now_ms);
            moved += 1;

            try self.serveAnswerer();

            // The answerer starts a fresh batch on every datagram, so what it owes has to be taken
            // before the next one goes in.
            try self.collectFromAnswerer();
        }

        for (0..self.to_dialer.count) |index| {
            _ = try self.dialer.handle(self.to_dialer.at(index), self.now_ms);
            moved += 1;

            try self.serveDialer();
        }

        return moved;
    }

    fn collectFromDialer(self: *Session) !void {
        var out: [MAX_DATAGRAM]u8 = undefined;

        while (try self.dialer.nextOutbound(self.now_ms, &out)) |datagram| self.to_answerer.push(datagram);
    }

    fn collectFromAnswerer(self: *Session) !void {
        var out: [MAX_DATAGRAM]u8 = undefined;

        while (try self.answerer.nextOutbound(self.now_ms, &out)) |datagram| self.to_dialer.push(datagram);
    }

    /// The answerer's application: echo every message straight back.
    fn serveAnswerer(self: *Session) !void {
        while (try self.answerer.nextEvent(self.now_ms)) |event| switch (event) {
            .CHANNEL_OPEN => self.answerer_saw_open = true,
            .MESSAGE => |message| {
                self.answerer_saw_message = true;

                var ctx = self.answerer.context(self.now_ms) orelse continue;
                try ctx.send(message.channel, message.kind, message.payload);
            },
            .CHANNEL_CLOSED => {},
        };
    }

    /// The dialer's application: send once the channel opens, then keep what comes back.
    fn serveDialer(self: *Session) !void {
        while (try self.dialer.nextEvent(self.now_ms)) |event| switch (event) {
            .CHANNEL_OPEN => |identifier| {
                self.dialer.onChannelOpen(identifier);

                if (!self.sent) {
                    try self.dialer.send(.STRING, "hello over a data channel", self.now_ms);
                    self.sent = true;
                }
            },
            .MESSAGE => |message| {
                const len = @min(message.payload.len, self.echoed.len);
                @memcpy(self.echoed[0..len], message.payload[0..len]);
                self.echoed_len = len;
            },
            .CHANNEL_CLOSED => {},
        };
    }
};

fn signingKey() !EcdsaP256.KeyPair {
    var secret: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&secret, "0b76f7f1c7bf6e20029ddb566795e58da5ba63ffbdb914bf699bfbed3147d32c");

    return EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(secret));
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
        .channel_label = CHANNEL_LABEL,
    };
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

// --------------------------------------------------------------- //

test "zix webrtc: exchange, a dialer and an answerer carry a message end to end" {
    const session = try Session.init(std.testing.allocator);
    defer session.deinit();

    const rounds = try session.run(200);

    try std.testing.expect(session.dialer.isReady());
    try std.testing.expect(session.answerer.isEstablished());
    try std.testing.expect(session.answerer_saw_open);
    try std.testing.expect(session.answerer_saw_message);
    try std.testing.expectEqualStrings("hello over a data channel", session.echoed[0..session.echoed_len]);

    // The whole session is a handful of round trips, so a budget of 200 is slack and not a wait.
    try std.testing.expect(rounds < 100);
}

test "zix webrtc: exchange, the answerer nominates the pair the checks came from" {
    const session = try Session.init(std.testing.allocator);
    defer session.deinit();

    _ = try session.run(200);

    try std.testing.expect(session.answerer.ice.selected != null);
    try std.testing.expect(session.answerer.ice.selected.?.eql(&ANSWERER_ADDRESS));
}

test "zix webrtc: exchange, the channel lands on an even identifier because the dialer opened it" {
    const session = try Session.init(std.testing.allocator);
    defer session.deinit();

    _ = try session.run(200);

    const identifier = session.dialer.channelId().?;

    // RFC 8832 6: the side that took the DTLS client role opens on even identifiers.
    try std.testing.expectEqual(@as(u16, 0), identifier % 2);
}

test "zix webrtc: exchange, neither peer is left with a deadline it will never meet" {
    const session = try Session.init(std.testing.allocator);
    defer session.deinit();

    _ = try session.run(200);

    try std.testing.expect(!session.dialer.isDead());
    try std.testing.expect(!session.answerer.isDead());
}
