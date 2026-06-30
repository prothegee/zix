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
const varint = @import("../varint.zig");
const serverhello = @import("../serverhello.zig");
const flight = @import("../flight.zig");
const response = @import("../response.zig");
const request = @import("../request.zig");
const huffman = @import("../huffman.zig");
const transport_params = @import("../transport_params.zig");
const keyschedule = @import("../keyschedule.zig");
const demux = @import("../demux.zig");
const Connection = @import("../connection.zig").Connection;
const SendStream = @import("../connection.zig").SendStream;
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
    /// A client 1-RTT packet decrypted with the derived application keys (proves the 1-RTT key
    /// derivation is correct against the client, the request is now readable).
    request_opened,
};

/// Process one received datagram: demux it to a connection and decrypt by encryption level. A new
/// Initial opens a connection (keyed by the client's chosen DCID), Handshake / 1-RTT packets address
/// the connection by the Source Connection ID we issued (our_scid).
pub fn processDatagram(table: *ConnTable, data: []const u8, cid_len: usize, max_datagram_size: u64) Event {
    if (data.len == 0) return .ignored;

    if (data[0] & 0x80 != 0) {
        const hdr = packet.parseLongHeader(data) catch return .ignored;
        const dcid = demux.ConnId.fromSlice(hdr.dcid);

        const conn = findConn(table, &dcid) orelse blk: {
            if (hdr.packet_type != 0) return .demuxed;
            break :blk table.put(dcid, Connection.init(hdr.dcid, max_datagram_size)) orelse return .ignored;
        };
        conn.anti_amplification.onReceive(data.len);

        if (hdr.packet_type == 0) return openClientInitial(conn, data);

        // A client Handshake packet: decrypt with the derived client Handshake keys. Success proves
        // the handshake-secret derivation (transcript + ECDHE + key schedule) matches byte-exact.
        if (hdr.packet_type == 2 and conn.handshake_ready) {
            var hbuf: [2048]u8 = undefined;
            if (protection.openHandshake(data, conn.hs_keys.client, &hbuf)) |_| return .handshake_opened else |_| {}
        }

        return .demuxed;
    }

    // Short header (1-RTT): the Destination CID is the connection id we issued (cid_len bytes).
    if (data.len < 1 + cid_len) return .ignored;
    const dcid = demux.ConnId.fromSlice(data[1 .. 1 + cid_len]);
    const conn = findConn(table, &dcid) orelse return .demuxed;
    conn.anti_amplification.onReceive(data.len);

    if (conn.app_ready) {
        var sbuf: [2048]u8 = undefined;
        if (protection.openShort(data, conn.app_keys.client, conn.our_scid.len, &sbuf)) |opened| {
            if (conn.app_largest_received == null or opened.packet_number > conn.app_largest_received.?) {
                conn.app_largest_received = opened.packet_number;
            }

            // Copy the decrypted payload onto the connection so sendResponse walks every request stream
            // it carries without decrypting again. sbuf is stack-local to this call.
            const copied = @min(opened.payload.len, conn.app_payload_buf.len);
            @memcpy(conn.app_payload_buf[0..copied], opened.payload[0..copied]);
            conn.app_payload_len = copied;

            return .request_opened;
        } else |_| {}
    }

    return .demuxed;
}

/// Find a connection by the Destination Connection ID, falling back to the Source CID we issued
/// (our_scid) that the client uses as its Destination CID after ServerHello.
fn findConn(table: *ConnTable, dcid: *const demux.ConnId) ?*Connection {
    if (table.find(dcid)) |conn| return conn;

    for (0..table.count) |i| {
        if (table.values[i].server_hello_sent and table.values[i].our_scid.eql(dcid)) return &table.values[i];
    }

    return null;
}

/// Decrypt a client Initial with the DCID-derived client keys, feed its CRYPTO frames into the
/// Initial-level reassembly stream, and parse the ClientHello once it is contiguous (it spans two
/// Initials, so the prefix is incomplete until the second CRYPTO fragment arrives).
fn openClientInitial(conn: *Connection, data: []const u8) Event {
    var buf: [2048]u8 = undefined;
    const opened = protection.openInitial(data, conn.initial_client, &buf) catch return .decrypt_failed;

    feedInitialFrames(conn, opened.payload);

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

/// Effective worker count: the configured value, or one per available CPU when 0.
/// Uses the cgroup-allowed CPU mask (getAvailableCpuCount), so under a container or
/// taskset that pins the server to a core subset we never spawn more SO_REUSEPORT
/// workers than there are usable cores (which would oversubscribe and collapse).
pub fn effectiveWorkers(config: Http3ServerConfig) usize {
    if (config.workers != 0) return config.workers;

    return getAvailableCpuCount();
}

/// Pin the calling thread to the CPU slot assigned to worker_id, respecting the
/// cgroup-allowed CPU mask so we never select a CPU the container cannot use.
pub fn pinToCpu(worker_id: usize) void {
    const linux = std.os.linux;
    var cpu_set: linux.cpu_set_t = undefined;
    if (linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &cpu_set) != 0) return;

    var cpu_list: [256]u32 = undefined;
    var n_cpus: usize = 0;
    for (cpu_set, 0..) |word, word_idx| {
        var w = word;
        while (w != 0) : (w &= w - 1) {
            if (n_cpus < cpu_list.len) {
                cpu_list[n_cpus] = @intCast(word_idx * @bitSizeOf(usize) + @ctz(w));
                n_cpus += 1;
            }
        }
    }
    if (n_cpus == 0) return;

    const target = cpu_list[worker_id % n_cpus];
    var target_set: linux.cpu_set_t = std.mem.zeroes(linux.cpu_set_t);
    const cpu_word = target / @bitSizeOf(usize);
    const cpu_bit: u6 = @intCast(target % @bitSizeOf(usize));
    target_set[cpu_word] |= @as(usize, 1) << cpu_bit;

    linux.sched_setaffinity(0, &target_set) catch {};
}

/// Count CPUs available to this process via sched_getaffinity, respecting cgroup
/// and taskset restrictions. Falls back to std.Thread.getCpuCount when the syscall
/// fails. Used to default to one worker per available CPU so several workers are
/// never pinned to the same core under cgroup-limited bench environments.
pub fn getAvailableCpuCount() usize {
    const linux = std.os.linux;
    var cpu_set: linux.cpu_set_t = undefined;
    if (linux.sched_getaffinity(0, @sizeOf(linux.cpu_set_t), &cpu_set) != 0) {
        return std.Thread.getCpuCount() catch 1;
    }

    var count: usize = 0;
    for (cpu_set) |word| {
        count += @popCount(word);
    }

    return if (count == 0) 1 else count;
}

/// Spin up to `us` microseconds before the worker sleeps on the UDP socket (SO_BUSY_POLL), trading
/// CPU for lower recvmmsg wake-up latency on saturated benchmarks. us = 0 leaves it unset (no
/// syscall). Silent no-op when the kernel lacks SO_BUSY_POLL. Mirrors zix.Http1's setBusyPoll.
pub fn setBusyPoll(fd: std.posix.socket_t, us: u32) void {
    if (us == 0) return;

    const SO_BUSY_POLL: u32 = 46;
    std.posix.setsockopt(
        fd,
        std.posix.SOL.SOCKET,
        SO_BUSY_POLL,
        std.mem.asBytes(&@as(c_int, @intCast(us))),
    ) catch {};
}

/// One HTTP/3 worker: bind a UDP socket, own a CID table, and run the recv / demux / respond loop.
/// `reuse` sets SO_REUSEADDR + SO_REUSEPORT so several workers can bind the same port and the kernel
/// load-balances connections across them by 4-tuple (RC3 multicore). Each worker is shared-nothing:
/// its own socket, CID table, and send / recv batches, so no lock is taken on the hot path.
pub fn workerLoop(comptime handler: core.HandlerFn, config: Http3ServerConfig, reuse: bool, worker_id: usize) void {
    // Per-core mode (reuse == SO_REUSEPORT) pins this worker to its assigned CPU so the
    // kernel never migrates it and N workers never pile onto the same core under a
    // cgroup-limited cpuset. The single-worker mode (reuse == false) stays unpinned.
    if (reuse) pinToCpu(worker_id);

    const fd = datagram.open(config.ip, config.port, reuse) catch |err| {
        logSystem(config, "bind error: {}", .{err});
        return;
    };
    defer datagram.close(fd);

    setBusyPoll(fd, config.busy_poll_us);

    // Enlarge the kernel socket buffers so a burst arriving between recvmmsg batches is not dropped
    // (loss on a syscall-bound run shows up as retransmits). Capped by the host rmem_max / wmem_max.
    datagram.setSocketBuffers(fd, config.socket_rcvbuf, config.socket_sndbuf);

    const table = config.allocator.create(ConnTable) catch return;
    defer config.allocator.destroy(table);
    table.* = .{};

    var rx = datagram.RecvBatch.init(config.allocator, config.recv_batch, config.max_recv_buf) catch return;
    defer rx.deinit();

    var tx = datagram.SendBatch.init(config.allocator, config.send_batch, config.send_batch * config.max_recv_buf) catch return;
    defer tx.deinit();

    // GSO coalescing on the send path, only when requested and the kernel supports UDP_SEGMENT. The
    // prime case is a multi-packet static-h3 body to one peer collapsing into one sendmsg.
    tx.gso = config.gso_enabled and datagram.probeGso(fd);

    while (true) {
        const count = rx.recv(fd) catch continue;

        for (0..count) |i| {
            const dg = rx.get(i);
            switch (processDatagram(table, dg.data, config.cid_len, config.max_datagram_size)) {
                .client_hello => |n| {
                    logSystem(config, "decrypted client Initial, parsed ClientHello ({d} bytes)", .{n});
                    sendServerHello(table, dg.data, &tx, fd, dg.from, config);
                },
                .initial_opened => |pn| logSystem(config, "decrypted client Initial, packet number {d} (ClientHello incomplete)", .{pn}),
                .parse_alert => logSystem(config, "decrypted client Initial but ClientHello parse raised an alert", .{}),
                .decrypt_failed => logSystem(config, "long-header Initial failed to decrypt under the Initial keys", .{}),
                .handshake_opened => logSystem(config, "decrypted client Handshake packet (handshake keys correct, validated live)", .{}),
                .request_opened => {
                    logSystem(config, "decrypted client 1-RTT request (application keys correct, validated live)", .{});
                    sendResponse(handler, table, dg.data, &tx, fd, dg.from, config.cid_len, config);
                },
                else => {},
            }
        }
    }
}

/// The v1 single-worker recv loop on the calling thread (ASYNC / POOL / MIXED).
pub fn runSingle(comptime handler: core.HandlerFn, config: Http3ServerConfig) !void {
    if (!datagram.is_linux) {
        logSystem(config, "HTTP/3 requires the Linux datagram path", .{});
        return;
    }

    logSystem(config, "listening on {s}:{d} (single worker)", .{ config.ip, config.port });
    workerLoop(handler, config, false, 0);
}

/// Build and send the server's ServerHello Initial in reply to a decrypted ClientHello (handshake
/// step 2). Idempotent per connection: sent once, skipped on retransmits.
fn sendServerHello(table: *ConnTable, data: []const u8, tx: *datagram.SendBatch, fd: std.posix.socket_t, peer: std.posix.sockaddr.in6, config: Http3ServerConfig) void {
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

    // Record the client's flow control limits so the response path can serve bodies larger than one
    // packet without overrunning them (RFC 9000 4.1). Absent (a minimal client) leaves them at 0.
    if (transport_params.fromClientHello(client_hello)) |tp| {
        conn.client_max_data = tp.initial_max_data;
        conn.client_max_stream_data = tp.initial_max_stream_data_bidi_local;
    }

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

    // 1-RTT application keys, derived from the transcript through the server Finished (which the
    // flight just appended). The client addresses us by our_scid from here on.
    conn.app_keys = keyschedule.applicationKeys(conn.hs_keys.handshake_secret, conn.handshake_transcript.current());
    conn.peer_scid = demux.ConnId.fromSlice(hdr.scid);
    conn.app_ready = true;
}

/// Expand a request :path into a stable slice: Huffman-decoded into the connection scratch when the
/// client encoded it (the common case, curl / h2load encode :path), otherwise the literal slice into
/// the captured payload. Returns an empty path on a malformed Huffman code.
fn decodePath(conn: *Connection, req: request.DecodedRequest) []const u8 {
    if (req.path_huffman) {
        const len = huffman.decode(&conn.path_scratch, req.path) orelse return "";

        return conn.path_scratch[0..len];
    }

    return req.path;
}

/// The most stream-data bytes one 1-RTT packet carries. Kept well under the 1500 path MTU once the
/// short header, packet number, STREAM frame header, and AEAD tag are accounted for.
/// Copy `dst.len` bytes of the logical response stream (the HTTP/3 prefix followed by the body) into
/// `dst`, starting at stream offset `off`. The prefix and body stay separate, so a large body is
/// never concatenated into one buffer.
fn copyStreamSlice(prefix: []const u8, body: []const u8, off: usize, dst: []u8) void {
    var written: usize = 0;
    var pos = off;

    if (pos < prefix.len) {
        const n = @min(dst.len, prefix.len - pos);
        @memcpy(dst[0..n], prefix[pos..][0..n]);
        written += n;
        pos += n;
    }

    if (written < dst.len) {
        const body_pos = pos - prefix.len;
        @memcpy(dst[written..], body[body_pos..][0 .. dst.len - written]);
    }
}

/// The total HTTP/3 stream length for a response: the prefix (HEADERS + DATA header) plus the body.
fn streamContentLen(status: u16, body: []const u8) usize {
    var buf: [32]u8 = undefined;
    const prefix_len = response.buildStreamPrefix(&buf, status, body.len) orelse 0;

    return prefix_len + body.len;
}

/// Take the pending ACK (consume it so only the first packet of a call carries it).
fn ackTake(ack_pending: *?u64) ?u64 {
    const value = ack_pending.*;
    ack_pending.* = null;

    return value;
}

/// Take the pending MAX_STREAMS credit (consume it so only one packet of a call carries it).
fn maxStreamsTake(max_streams_pending: *?u64) ?u64 {
    const value = max_streams_pending.*;
    max_streams_pending.* = null;

    return value;
}

/// Apply the flow control advertisements in a decrypted 1-RTT payload: MAX_DATA (0x10) raises the
/// connection-wide send limit, MAX_STREAM_DATA (0x11) raises a tracked stream's limit. A limit only
/// ever increases (RFC 9000 4.1), so a smaller value is ignored. Every other frame is walked past.
fn applyFlowControl(conn: *Connection, payload: []const u8) void {
    var pos: usize = 0;
    while (pos < payload.len) {
        const type_vi = varint.read(payload[pos..]) catch break;
        const frame_type = type_vi.value;

        if (request.isStreamFrameType(frame_type)) {
            const stream = request.parseStreamFrame(payload[pos..]) orelse break;
            pos += stream.consumed;
            continue;
        }

        if (frame_type == 0x10) {
            var p = pos + type_vi.len;
            const max = varint.read(payload[p..]) catch break;
            p += max.len;
            if (max.value > conn.client_max_data) conn.client_max_data = max.value;
            pos = p;
            continue;
        }

        if (frame_type == 0x11) {
            var p = pos + type_vi.len;
            const sid = varint.read(payload[p..]) catch break;
            p += sid.len;
            const max = varint.read(payload[p..]) catch break;
            p += max.len;
            if (conn.findSendStream(sid.value)) |stream| {
                if (max.value > stream.stream_limit) stream.stream_limit = max.value;
            }
            pos = p;
            continue;
        }

        const skipped = request.skipFrame(payload[pos..]) orelse break;
        pos += skipped;
    }
}

/// Send as much of a large response stream as the client's flow control now permits, fragmenting it
/// into STREAM frames across 1-RTT packets (RFC 9000 19.8) and advancing the stream's sent offset.
/// The connection's first response packet carries HANDSHAKE_DONE + the server control SETTINGS, and
/// the first packet sent this call carries the pending ACK. A completed stream frees its slot. Returns
/// true when at least one packet was sent.
fn pumpStream(conn: *Connection, stream: *SendStream, tx: *datagram.SendBatch, fd: std.posix.socket_t, peer: std.posix.sockaddr.in6, ack_pending: *?u64, max_streams_pending: *?u64, config: Http3ServerConfig) bool {
    var prefix_buf: [32]u8 = undefined;
    const prefix_len = response.buildStreamPrefix(&prefix_buf, stream.status, stream.body.len) orelse {
        stream.active = false;
        return false;
    };
    const prefix = prefix_buf[0..prefix_len];

    // The reachable offset: the stream's own flow limit, capped by the connection-wide remaining credit.
    const conn_remaining = if (conn.client_max_data > conn.conn_data_sent) conn.client_max_data - conn.conn_data_sent else 0;
    const limit = @min(stream.content_len, @min(stream.stream_limit, stream.sent + conn_remaining));
    if (limit <= stream.sent) return false;

    var sent_any = false;
    while (stream.sent < limit) {
        const chunk = @min(config.max_stream_chunk, limit - stream.sent);
        const is_last = (stream.sent + chunk == stream.content_len); // FIN only when fully sent

        var payload: [1500]u8 = undefined;
        var p: usize = 0;

        if (!conn.first_response_sent) {
            payload[p] = 0x1e; // HANDSHAKE_DONE
            p += 1;

            // Server control stream (id 3): stream type 0x00 then an empty SETTINGS frame.
            payload[p] = 0x0a; // STREAM | LEN
            p += 1;
            p += varint.write(payload[p..], 3);
            p += varint.write(payload[p..], 3);
            payload[p] = 0x00;
            payload[p + 1] = 0x04;
            payload[p + 2] = 0x00;
            p += 3;

            conn.first_response_sent = true;
        }

        if (ackTake(ack_pending)) |largest| p += response.buildAck(payload[p..], largest);

        if (maxStreamsTake(max_streams_pending)) |granted| p += response.buildMaxStreams(payload[p..], granted);

        // STREAM frame on the request stream: type OFF | LEN (| FIN), id, offset, length, then data.
        payload[p] = 0x0e | @as(u8, if (is_last) 0x01 else 0x00);
        p += 1;
        p += varint.write(payload[p..], stream.stream_id);
        p += varint.write(payload[p..], stream.sent);
        p += varint.write(payload[p..], chunk);
        copyStreamSlice(prefix, stream.body, stream.sent, payload[p..][0..chunk]);
        p += chunk;

        sealAndQueue(conn, tx, fd, peer, payload[0..p]);
        stream.sent += chunk;
        conn.conn_data_sent += chunk;
        sent_any = true;
    }

    if (stream.complete()) {
        stream.active = false;
        logSystem(config, "stream {d} fully sent ({d} bytes)", .{ stream.stream_id, stream.content_len });
    }

    return sent_any;
}

/// Seal a 1-RTT payload into a short packet and queue it for sending, flushing the batch first when
/// it is full so the reply is never dropped.
fn sealAndQueue(conn: *Connection, tx: *datagram.SendBatch, fd: std.posix.socket_t, peer: std.posix.sockaddr.in6, payload: []const u8) void {
    var out: [2048]u8 = undefined;
    const reply = protection.sealShort(&out, conn.app_keys.server, conn.peer_scid.slice(), conn.app_pn, payload) catch return;
    conn.app_pn += 1;

    if (tx.queue(peer, reply)) return;

    tx.flush(fd) catch return;
    _ = tx.queue(peer, reply);
}

/// Build and send the HTTP/3 responses for the 1-RTT payload captured on the connection. A connection
/// multiplexes many requests, each on its own client bidi stream, and one packet can coalesce several:
/// a small response goes out in one packet, a large one is registered as a send stream and fragmented
/// across packets within the client's flow control, resumed as MAX_STREAM_DATA / MAX_DATA arrive. A
/// packet carrying no work is acknowledged so the client stops retransmitting.
fn sendResponse(handler: core.HandlerFn, table: *ConnTable, data: []const u8, tx: *datagram.SendBatch, fd: std.posix.socket_t, peer: std.posix.sockaddr.in6, cid_len: usize, config: Http3ServerConfig) void {
    if (data.len < 1 + cid_len) return;

    const dcid = demux.ConnId.fromSlice(data[1 .. 1 + cid_len]);
    const conn = findConn(table, &dcid) orelse return;
    if (!conn.app_ready) return;

    const payload_view = conn.app_payload_buf[0..conn.app_payload_len];

    // The ACK rides the first packet sent this call (a response, a stream chunk, or a bare ACK).
    var ack_pending: ?u64 = conn.app_largest_received;

    var reqs: [request.max_requests_per_packet]request.StreamRequest = undefined;
    const count = request.parseRequests(payload_view, &reqs);

    // Extend the client's request-stream credit before it runs out (RFC 9000 4.6): find the highest
    // bidi request stream this packet opened and decide whether a MAX_STREAMS must ride a reply. Without
    // it the connection stalls at the one-time handshake allowance. Rides the first reply, like the ACK.
    var highest_bidi_id: ?u64 = null;
    for (reqs[0..count]) |stream_req| {
        if (stream_req.stream_id % 4 != 0) continue;
        if (highest_bidi_id == null or stream_req.stream_id > highest_bidi_id.?) highest_bidi_id = stream_req.stream_id;
    }
    var max_streams_pending: ?u64 = if (highest_bidi_id) |hid| conn.replenishBidiStreams(hid, config.max_streams) else null;

    for (reqs[0..count]) |stream_req| {
        // A retransmit of a request already being streamed: leave its progress, the pump continues it.
        if (conn.findSendStream(stream_req.stream_id) != null) continue;

        var req = core.Request{ .method = stream_req.request.method, .path = decodePath(conn, stream_req.request) };
        var res = core.Response{};
        handler(&req, &res);

        // HANDSHAKE_DONE + the server control SETTINGS ride the connection's first response only, and a
        // due MAX_STREAMS rides the first reply this call sends (cleared once a packet carries it).
        const framing = response.Framing{
            .handshake_done = !conn.first_response_sent,
            .control = !conn.first_response_sent,
            .max_streams_bidi = max_streams_pending,
        };

        var payload: [2048]u8 = undefined;
        if (response.buildResponse(&payload, stream_req.stream_id, res.status, res.body, ackTake(&ack_pending), framing)) |payload_len| {
            // The whole response fits one packet (the common small-body case).
            sealAndQueue(conn, tx, fd, peer, payload[0..payload_len]);
            conn.first_response_sent = true;
            max_streams_pending = null;
            logSystem(config, "sent 1-RTT response on stream {d}: HTTP/3 status {d}", .{ stream_req.stream_id, res.status });
        } else if (conn.reserveSendStream(stream_req.stream_id)) |slot| {
            // The body spans more than one packet: register it, the pump below sends within flow control.
            slot.* = .{
                .active = true,
                .stream_id = stream_req.stream_id,
                .status = res.status,
                .body = res.body,
                .content_len = streamContentLen(res.status, res.body),
                .sent = 0,
                .stream_limit = conn.client_max_stream_data,
            };
        } else {
            // No free send slot: answer 500 so the stream completes rather than stalling.
            const len = response.buildResponse(&payload, stream_req.stream_id, 500, "", ackTake(&ack_pending), framing) orelse continue;
            sealAndQueue(conn, tx, fd, peer, payload[0..len]);
            conn.first_response_sent = true;
            max_streams_pending = null;
        }
    }

    // Apply this packet's flow control advertisements after registering requests, so a MAX_STREAM_DATA
    // that rides the same packet as the request it unblocks is applied to the just-registered stream.
    applyFlowControl(conn, payload_view);

    // Pump every active large stream: new ones, and ones this packet's MAX_STREAM_DATA just unblocked.
    // A due MAX_STREAMS rides the first pumped packet when no small reply above already carried it.
    for (&conn.send_streams) |*stream| {
        if (stream.active) _ = pumpStream(conn, stream, tx, fd, peer, &ack_pending, &max_streams_pending, config);
    }

    // A trailing packet for anything no reply carried: the ACK (a bare ACK / flow-control packet that
    // made no progress), and a still-due MAX_STREAMS (this packet's requests were all retransmits, so no
    // reply was built to ride it). Either keeps the client unblocked.
    const trailing_ack = ackTake(&ack_pending);
    const trailing_max_streams = maxStreamsTake(&max_streams_pending);
    if (trailing_ack != null or trailing_max_streams != null) {
        var payload: [64]u8 = undefined;
        var p: usize = 0;
        if (trailing_ack) |largest| p += response.buildAck(payload[p..], largest);
        if (trailing_max_streams) |granted| p += response.buildMaxStreams(payload[p..], granted);
        if (p != 0) sealAndQueue(conn, tx, fd, peer, payload[0..p]);
    }

    tx.flush(fd) catch {};
}

/// One SO_REUSEPORT worker per core (EPOLL / URING). Each worker binds the same UDP port and owns a
/// CID table, so the kernel load-balances connections across cores by 4-tuple. A client keeps a
/// stable 4-tuple per connection (no active migration), so every packet of a connection lands on the
/// same worker, no cross-core routing needed. CID-aware steering (for connection migration) is a
/// later phase (ADR-049 phase 3): plain 4-tuple routing breaks only when a peer migrates address.
pub fn runPerCore(comptime handler: core.HandlerFn, config: Http3ServerConfig) !void {
    if (!datagram.is_linux) {
        logSystem(config, "HTTP/3 requires the Linux datagram path", .{});
        return;
    }

    const want = effectiveWorkers(config);
    logSystem(config, "listening on {s}:{d} ({d} workers, SO_REUSEPORT)", .{ config.ip, config.port, want });

    const threads = try config.allocator.alloc(std.Thread, want);
    defer config.allocator.free(threads);

    var spawned: usize = 0;
    for (0..want) |i| {
        threads[i] = std.Thread.spawn(.{ .stack_size = config.worker_stack_size_bytes }, workerLoop, .{ handler, config, true, i }) catch break;
        spawned += 1;
    }

    for (threads[0..spawned]) |t| t.join();
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

fn noopHandler(_: *const core.Request, _: *core.Response) void {}

test "zix test: processDatagram demuxes a long-header Initial by DCID" {
    var table = ConnTable{};

    // A crafted Initial long header: 0xc3, version 1, 8-byte DCID, 4-byte SCID, one payload byte.
    const initial = [_]u8{ 0xc3, 0x00, 0x00, 0x00, 0x01, 0x08, 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08, 0x04, 0x11, 0x22, 0x33, 0x44, 0x00 };
    _ = processDatagram(&table, &initial, 8, 1200);

    const dcid = demux.ConnId.fromSlice(&[_]u8{ 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08 });
    try std.testing.expectEqual(@as(usize, 1), table.count);
    try std.testing.expect(table.find(&dcid) != null);

    // A second datagram for the same connection reuses the slot, not a new one.
    _ = processDatagram(&table, &initial, 8, 1200);
    try std.testing.expectEqual(@as(usize, 1), table.count);

    // The anti-amplification budget reflects both received datagrams.
    try std.testing.expectEqual(@as(u64, 40), table.find(&dcid).?.anti_amplification.received);
}

test "zix test: copyStreamSlice spans the prefix and body boundary" {
    const prefix = "PRE"; // 3 bytes of HTTP/3 prefix
    const body = "0123456789";

    // A slice from offset 1 across the prefix end into the body: "RE0123".
    var dst: [6]u8 = undefined;
    copyStreamSlice(prefix, body, 1, &dst);
    try std.testing.expectEqualStrings("RE0123", &dst);

    // A slice fully inside the body (offset past the prefix).
    var dst2: [4]u8 = undefined;
    copyStreamSlice(prefix, body, 5, &dst2);
    try std.testing.expectEqualStrings("2345", &dst2);
}

test "zix test: applyFlowControl raises the connection and stream limits" {
    const dcid = [_]u8{ 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08 };
    var conn = Connection.init(&dcid, 1200);
    conn.send_streams[0] = .{ .active = true, .stream_id = 0, .stream_limit = 1000 };

    // MAX_DATA (0x10) = 5000 then MAX_STREAM_DATA (0x11) for stream 0 = 9000.
    const payload = [_]u8{ 0x10, 0x53, 0x88, 0x11, 0x00, 0x63, 0x28 };
    applyFlowControl(&conn, &payload);

    try std.testing.expectEqual(@as(u64, 5000), conn.client_max_data);
    try std.testing.expectEqual(@as(u64, 9000), conn.send_streams[0].stream_limit);

    // A smaller advertisement never lowers an existing limit (RFC 9000 4.1).
    const lower = [_]u8{ 0x11, 0x00, 0x40, 0x64 }; // MAX_STREAM_DATA stream 0 = 100
    applyFlowControl(&conn, &lower);
    try std.testing.expectEqual(@as(u64, 9000), conn.send_streams[0].stream_limit);
}

test "zix test: getAvailableCpuCount returns at least 1" {
    try std.testing.expect(getAvailableCpuCount() >= 1);
}

test "zix test: effectiveWorkers honors an explicit count and caps at available CPUs" {
    const base = Http3ServerConfig{ .allocator = std.testing.allocator, .io = undefined, .ip = "127.0.0.1", .port = 0, .dispatch_model = .ASYNC };

    // an explicit worker count passes through unchanged
    var explicit = base;
    explicit.workers = 3;
    try std.testing.expectEqual(@as(usize, 3), effectiveWorkers(explicit));

    // workers = 0 defaults to the cpuset-aware count, never zero
    try std.testing.expect(effectiveWorkers(base) >= 1);
    try std.testing.expectEqual(getAvailableCpuCount(), effectiveWorkers(base));
}

test "zix test: pinToCpu is a no-op-safe call for any worker_id" {
    // The process keeps its original affinity mask, so pinning to a derived slot must not crash
    // for an out-of-range worker_id (the modulo keeps it inside the available set).
    pinToCpu(0);
    pinToCpu(999);
}
