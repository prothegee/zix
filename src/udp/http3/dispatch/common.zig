//! zix HTTP/3 dispatch helpers, shared by the per-model run files.
//!
//! What:
//! - The v1 single-worker recv loop: bind one UDP socket, receive datagrams in recvmmsg batches,
//!   parse the QUIC header to extract the Destination Connection ID, and demux to a per-connection
//!   slot (creating one for a new Initial). One worker owns the whole CID table, so connection
//!   migration is just a new peer address on an existing CID, no cross-core routing (ADR-049 phase 3).
//!
//! Note:
//! - Driving the TLS-over-QUIC handshake on the demuxed connection (decrypt the Initial, run the
//!   src/tls handshake over the CRYPTO stream, install Handshake / 1-RTT keys, answer requests
//!   through `handler`) is the live-handshake step layered on this recv / demux substrate.

const std = @import("std");
const builtin = @import("builtin");

const Config = @import("../config.zig");
const Http3ServerConfig = Config.Http3ServerConfig;
const core = @import("../core.zig");
const datagram = @import("../../datagram.zig");
const packet = @import("../packet.zig");
const protection = @import("../protection.zig");
const frame = @import("../frame.zig");
const serverhello = @import("../serverhello.zig");
const flight = @import("../flight.zig");
const demux = @import("../demux.zig");
const Connection = @import("../connection.zig").Connection;
const tls_handshake = @import("../../../tls/handshake.zig");

/// Maximum connections one v1 worker tracks. The table is heap-allocated, each Connection is large.
pub const max_connections = 256;

/// The CID-keyed connection table one worker owns.
pub const ConnTable = demux.Table(Connection, max_connections);

/// Emit a server lifecycle message through the configured logger, or stderr in Debug.
pub fn logSystem(config: Http3ServerConfig, comptime fmt: []const u8, args: anytype) void {
    if (config.logger) |lg| {
        lg.system(.INFO, "http3", fmt, args);
        return;
    }

    if (comptime builtin.mode == .Debug) std.debug.print("zix http3: " ++ fmt ++ "\n", args);
}

/// What processing one datagram produced, for the recv loop to log (step 1 observability).
pub const Event = union(enum) {
    /// Not a parseable QUIC packet, or the table was full.
    ignored,
    /// Demuxed to a connection (short header, or a long header that is not an Initial).
    demuxed,
    /// A long-header Initial that failed to decrypt under the Initial keys.
    decrypt_failed,
    /// An Initial decrypted: the recovered packet number, no complete ClientHello yet.
    initial_opened: u64,
    /// A complete ClientHello decoded from the reassembled CRYPTO stream: its byte length.
    client_hello: usize,
    /// An Initial decrypted but the ClientHello failed to parse (a TLS alert condition).
    parse_alert,
    /// A client Handshake-level packet decrypted with the derived Handshake keys (proves the
    /// handshake-secret derivation is correct against the client).
    handshake_opened,
};

/// Process one received datagram: parse the QUIC header, demux by Destination Connection ID, create a
/// connection for a new Initial, account anti-amplification, and (step 1) decrypt a client Initial and
/// reassemble its CRYPTO stream into a ClientHello.
pub fn processDatagram(table: *ConnTable, data: []const u8, cid_len: usize) Event {
    if (data.len == 0) return .ignored;

    const is_long = data[0] & 0x80 != 0;
    const dcid_slice = if (is_long) blk: {
        const hdr = packet.parseLongHeader(data) catch return .ignored;
        break :blk hdr.dcid;
    } else blk: {
        const hdr = packet.parseShortHeader(data, cid_len) catch return .ignored;
        break :blk hdr.dcid;
    };

    const dcid = demux.ConnId.fromSlice(dcid_slice);
    const conn = table.find(&dcid) orelse table.put(dcid, Connection.init(dcid_slice, 1200)) orelse return .ignored;
    conn.anti_amplification.onReceive(data.len);

    if (!is_long) return .demuxed;

    const hdr = packet.parseLongHeader(data) catch return .demuxed;

    // A client Handshake packet: decrypt with the derived client Handshake keys. Success proves the
    // handshake-secret derivation (transcript + ECDHE + key schedule) matches the client byte-exact.
    if (hdr.packet_type == 2) {
        if (conn.handshake_ready) {
            var hbuf: [2048]u8 = undefined;
            if (protection.openHandshake(data, conn.hs_keys.client, &hbuf)) |_| {
                return .handshake_opened;
            } else |_| {}
        }

        return .demuxed;
    }

    if (hdr.packet_type != 0) return .demuxed;

    // Step 1: decrypt the client Initial with the DCID-derived client keys, feed its CRYPTO frames
    // into the Initial-level reassembly stream, and parse the ClientHello once it is contiguous.
    var buf: [2048]u8 = undefined;
    const opened = protection.openInitial(data, conn.initial_client, &buf) catch return .decrypt_failed;

    feedInitialFrames(conn, opened.payload);

    // Parse only once the full ClientHello handshake message is contiguous: byte 0 is the
    // CLIENT_HELLO type (0x01) and bytes 1..4 are its 24-bit length. curl's ClientHello spans two
    // Initials, so the prefix is incomplete until the second CRYPTO fragment arrives.
    const handshake_bytes = conn.crypto_initial.readable();
    if (handshake_bytes.len >= 4 and handshake_bytes[0] == 0x01) {
        const declared = (@as(usize, handshake_bytes[1]) << 16) | (@as(usize, handshake_bytes[2]) << 8) | handshake_bytes[3];
        if (handshake_bytes.len >= 4 + declared) {
            const message = handshake_bytes[0 .. 4 + declared];
            return switch (tls_handshake.parseClientHello(message)) {
                .ok => .{ .client_hello = message.len },
                .alert => .parse_alert,
            };
        }
    }

    return .{ .initial_opened = opened.packet_number };
}

/// Parse the frames of a decrypted Initial payload, feeding CRYPTO frame data into the connection's
/// Initial-level reassembly stream. PADDING and other frames are skipped for step 1.
fn feedInitialFrames(conn: *Connection, payload: []const u8) void {
    var pos: usize = 0;
    while (pos < payload.len) {
        const parsed = frame.parseFrame(payload[pos..]) catch break;
        switch (parsed.frame) {
            .crypto => |c| conn.crypto_initial.insert(@intCast(c.offset), c.data),
            else => {},
        }

        if (parsed.len == 0) break;
        pos += parsed.len;
    }
}

/// The v1 single-worker recv loop on the calling thread (ASYNC / POOL / MIXED).
pub fn runSingle(comptime handler: core.HandlerFn, config: Http3ServerConfig) !void {
    _ = handler;

    if (!datagram.is_linux) {
        logSystem(config, "HTTP/3 requires the Linux datagram path", .{});
        return;
    }

    const fd = datagram.open(config.ip, config.port, false) catch |err| {
        logSystem(config, "bind error: {}", .{err});
        return;
    };
    defer datagram.close(fd);

    const table = config.allocator.create(ConnTable) catch return;
    defer config.allocator.destroy(table);
    table.* = .{};

    var rx = datagram.RecvBatch.init(config.allocator, config.recv_batch, config.max_recv_buf) catch return;
    defer rx.deinit();

    var tx = datagram.SendBatch.init(config.allocator, config.send_batch, config.send_batch * config.max_recv_buf) catch return;
    defer tx.deinit();

    logSystem(config, "listening on {s}:{d} (v1 single worker)", .{ config.ip, config.port });

    while (true) {
        const count = rx.recv(fd) catch continue;

        for (0..count) |i| {
            const dg = rx.get(i);
            switch (processDatagram(table, dg.data, config.cid_len)) {
                .client_hello => |n| {
                    logSystem(config, "decrypted client Initial, parsed ClientHello ({d} bytes)", .{n});
                    sendServerHello(table, dg.data, &tx, fd, dg.from, config);
                },
                .initial_opened => |pn| logSystem(config, "decrypted client Initial, packet number {d} (ClientHello incomplete)", .{pn}),
                .parse_alert => logSystem(config, "decrypted client Initial but ClientHello parse raised an alert", .{}),
                .decrypt_failed => logSystem(config, "long-header Initial failed to decrypt under the Initial keys", .{}),
                .handshake_opened => logSystem(config, "decrypted client Handshake packet (handshake keys correct, validated live)", .{}),
                else => {},
            }
        }
    }
}

/// Build and send the server's ServerHello Initial in reply to a decrypted ClientHello (handshake
/// step 2). Idempotent per connection: sent once, skipped on retransmits.
fn sendServerHello(table: *ConnTable, data: []const u8, tx: *datagram.SendBatch, fd: std.posix.socket_t, peer: std.posix.sockaddr.in, config: Http3ServerConfig) void {
    const hdr = packet.parseLongHeader(data) catch return;
    if (hdr.packet_type != 0) return;

    const dcid = demux.ConnId.fromSlice(hdr.dcid);
    const conn = table.find(&dcid) orelse return;
    if (conn.server_hello_sent) return;

    const handshake_bytes = conn.crypto_initial.readable();
    if (handshake_bytes.len < 4 or handshake_bytes[0] != 0x01) return;

    const declared = (@as(usize, handshake_bytes[1]) << 16) | (@as(usize, handshake_bytes[2]) << 8) | handshake_bytes[3];
    if (handshake_bytes.len < 4 + declared) return;

    const client_hello = handshake_bytes[0 .. 4 + declared];
    const hello = switch (tls_handshake.parseClientHello(client_hello)) {
        .ok => |parsed| parsed,
        .alert => return,
    };

    // Choose our Source Connection ID (the client will use it as its Destination CID) and the fresh
    // per-connection randoms.
    const cid_len: usize = @min(config.cid_len, 20);
    var scid_bytes: [20]u8 = undefined;
    _ = std.os.linux.getrandom(&scid_bytes, cid_len, 0);
    conn.our_scid = demux.ConnId.fromSlice(scid_bytes[0..cid_len]);

    var server_random: [32]u8 = undefined;
    _ = std.os.linux.getrandom(&server_random, server_random.len, 0);
    var ephemeral: [32]u8 = undefined;
    _ = std.os.linux.getrandom(&ephemeral, ephemeral.len, 0);

    var out: [1500]u8 = undefined;
    const built = serverhello.buildServerHelloInitial(&out, &hello, client_hello, conn.initial_server, hdr.scid, conn.our_scid.slice(), server_random, ephemeral) orelse {
        logSystem(config, "ServerHello not built (no X25519 share or negotiation declined)", .{});
        return;
    };

    conn.handshake_shared = built.shared;
    conn.hs_keys = built.keys;
    conn.handshake_transcript = built.transcript;
    conn.handshake_ready = true;
    conn.server_hello_sent = true;

    _ = tx.queue(peer, built.packet);
    tx.flush(fd) catch {};
    logSystem(config, "sent ServerHello Initial ({d} bytes), Handshake keys derived", .{built.packet.len});

    // Handshake flight: EncryptedExtensions (ALPN h3 + transport params) + Certificate +
    // CertificateVerify + Finished, sealed into a Handshake packet with the server Handshake keys.
    const tls_ctx = config.tls orelse return;
    const opts = tls_ctx.handshakeOptions(ephemeral, server_random, @splat(0));

    var flight_out: [1500]u8 = undefined;
    const flight_packet = flight.buildHandshakeFlight(
        &flight_out,
        conn.hs_keys.server,
        conn.hs_keys.server_traffic,
        hdr.scid,
        conn.our_scid.slice(),
        &conn.handshake_transcript,
        opts.certificate_der,
        opts.signing_key,
        conn.dcid.slice(),
        conn.our_scid.slice(),
        config.max_idle_ms,
        config.max_streams,
    ) orelse {
        logSystem(config, "Handshake flight not built", .{});
        return;
    };

    _ = tx.queue(peer, flight_packet);
    tx.flush(fd) catch {};
    logSystem(config, "sent Handshake flight ({d} bytes): EE + Cert + CertVerify + Finished", .{flight_packet.len});
}

/// EPOLL / URING fold to the v1 single worker with a logged notice. Per-core SO_REUSEPORT CID
/// steering is v2 (ADR-049 phase 3): plain SO_REUSEPORT routes by 4-tuple and breaks under
/// connection migration, so it is not used until CID-aware steering lands.
pub fn runPerCore(comptime handler: core.HandlerFn, config: Http3ServerConfig) !void {
    logSystem(config, "EPOLL/URING per-core CID steering is v2 (ADR-049 phase 3), folding to the v1 single worker", .{});

    return runSingle(handler, config);
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

fn noopHandler(_: *const core.Request, _: *core.Response) void {}

test "zix test: processDatagram demuxes a long-header Initial by DCID" {
    var table = ConnTable{};

    // A crafted Initial long header: 0xc3, version 1, 8-byte DCID, 4-byte SCID, one payload byte.
    const initial = [_]u8{ 0xc3, 0x00, 0x00, 0x00, 0x01, 0x08, 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08, 0x04, 0x11, 0x22, 0x33, 0x44, 0x00 };
    _ = processDatagram(&table, &initial, 8);

    const dcid = demux.ConnId.fromSlice(&[_]u8{ 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08 });
    try std.testing.expectEqual(@as(usize, 1), table.count);
    try std.testing.expect(table.find(&dcid) != null);

    // A second datagram for the same connection reuses the slot, not a new one.
    _ = processDatagram(&table, &initial, 8);
    try std.testing.expectEqual(@as(usize, 1), table.count);

    // The anti-amplification budget reflects both received datagrams.
    try std.testing.expectEqual(@as(u64, 40), table.find(&dcid).?.anti_amplification.received);
}
