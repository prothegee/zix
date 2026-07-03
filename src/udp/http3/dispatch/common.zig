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
const linux = std.os.linux;

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
const flow = @import("../flow.zig");
const close = @import("../close.zig");
const recovery = @import("../recovery.zig");
const Connection = @import("../connection.zig").Connection;
const SendStream = @import("../connection.zig").SendStream;
const SentRangeInfo = @import("../connection.zig").SentRangeInfo;
const max_sent_ranges = @import("../connection.zig").max_sent_ranges;
const tls_handshake = @import("../../../tls/handshake.zig");

/// Maximum connections one v1 worker tracks. The table is heap-allocated, each Connection is large.
pub const max_connections = 256;

/// The CID-keyed connection table one worker owns.
pub const ConnTable = demux.Table(Connection, max_connections);

/// One coalesced 1-RTT response packet's payload budget. Several small responses pack into one packet
/// (one AEAD seal, one short header) up to this, instead of a packet per response. Kept under
/// max_datagram_size (1200) once the short header and the AEAD tag are added, so the packed packet is
/// still one unfragmented datagram.
const COALESCE_PAYLOAD_MAX: usize = 1100;

/// The largest 1-RTT datagram the response path will ever emit, a compile-time ceiling. It bounds the
/// pump's per-packet scratch buffer and the send-batch slot size, so the runtime datagram size (the
/// smaller of config.max_datagram_size and the client's advertised max_udp_payload_size) can never
/// outgrow the buffers. 16 KiB fragments a ~63 KiB static response into 4 datagrams instead of 53 at
/// the 1200 minimum, cutting the per-packet header / AEAD / ACK work that dominates a big-response run.
pub const max_send_datagram_size: usize = 16 * 1024;

/// Bytes held back inside a datagram for the short header, packet number, STREAM frame header, the AEAD
/// tag, and the small control frames the first response packet coalesces (HANDSHAKE_DONE, SETTINGS, an
/// ACK, MAX_STREAMS). The stream-data chunk per packet is the datagram size minus this, so a sealed
/// packet always fits its datagram with room to spare.
const per_packet_frame_reserve: usize = 160;

/// The send-batch slot size for the configured datagram size: one sealed 1-RTT packet at the datagram
/// size (clamped to the ceiling) plus the seal overhead. Reused by every send-batch allocation site so
/// the batch backing grows with config.max_datagram_size instead of the recv MTU (which stays small,
/// since inbound datagrams are requests and ACKs).
pub fn sendSlotSize(config: Http3ServerConfig) usize {
    return @min(@as(usize, @intCast(config.max_datagram_size)), max_send_datagram_size) + protection.short_seal_overhead_max;
}

/// The send-batch backing size for one worker: send_batch slots at the configured datagram size.
pub fn sendBufBytes(config: Http3ServerConfig) usize {
    return config.send_batch * sendSlotSize(config);
}

/// Emit a server lifecycle message through the configured logger, or stderr in Debug.
pub fn logSystem(config: Http3ServerConfig, comptime fmt: []const u8, args: anytype) void {
    if (config.logger) |lg| {
        lg.system(.INFO, "http3", fmt, args);
        return;
    }

    if (comptime builtin.mode == .Debug) std.debug.print("zix http3: " ++ fmt ++ "\n", args);
}

/// What processing one datagram produced, for the recv loop to log.
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
pub fn processDatagram(table: *ConnTable, data: []const u8, cid_len: usize, max_datagram_size: u64, initial_window_packets: usize) Event {
    if (data.len == 0) return .ignored;

    if (data[0] & 0x80 != 0) {
        const hdr = packet.parseLongHeader(data) catch return .ignored;
        const dcid = demux.ConnId.fromSlice(hdr.dcid);

        const conn = findConn(table, &dcid) orelse blk: {
            if (hdr.packet_type != 0) return .demuxed;
            break :blk table.put(dcid, Connection.init(hdr.dcid, max_datagram_size, initial_window_packets)) orelse return .ignored;
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
        // Reconstruct the truncated packet number against the largest 1-RTT number decoded so far
        // (null before the first), so decryption keeps working past packet 256 (RFC 9000 A.3).
        const largest_pn: ?u64 = if (conn.ack.have_largest) conn.ack.largest_pn else null;
        if (protection.openShort(data, conn.app_keys.client, conn.our_scid.len, largest_pn, &sbuf)) |opened| {
            conn.ack.record(opened.packet_number);

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

/// Find a connection by the Destination Connection ID. After ServerHello the client addresses the
/// connection by the Source CID the server issued (our_scid), which sendServerHello adds to the demux
/// index as an alias, so both the original client DCID and our_scid resolve here in O(1).
fn findConn(table: *ConnTable, dcid: *const demux.ConnId) ?*Connection {
    return table.find(dcid);
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
/// Initial-level reassembly stream. PADDING and other frames are skipped.
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

/// The single-worker HTTP/3 recv loop (ASYNC / POOL / MIXED): bind one UDP socket, own a CID table, and
/// run the blocking recvmmsg / demux / respond loop on the calling thread. `reuse` sets SO_REUSEPORT so
/// several per-core workers can bind the same port (runMulti), and a per-core worker pins to its CPU.
/// The single-worker mode (reuse == false) stays unpinned. Shared-nothing, no lock.
pub fn workerLoop(comptime handler: core.HandlerFn, config: Http3ServerConfig, reuse: bool, worker_id: usize) void {
    if (reuse) pinToCpu(worker_id);

    const fd = datagram.open(config.ip, config.port, reuse) catch |err| {
        logSystem(config, "bind error: {}", .{err});
        return;
    };
    defer datagram.close(fd);

    setBusyPoll(fd, config.busy_poll_us);
    datagram.setSocketBuffers(fd, config.socket_rcvbuf, config.socket_sndbuf);

    const table = config.allocator.create(ConnTable) catch return;
    defer config.allocator.destroy(table);
    table.* = .{};

    var rx = datagram.RecvBatch.init(config.allocator, config.recv_batch, config.max_recv_buf) catch return;
    defer rx.deinit();

    var tx = datagram.SendBatch.init(config.allocator, config.send_batch, sendBufBytes(config)) catch return;
    defer tx.deinit();

    tx.gso = config.gso_enabled and datagram.probeGso(fd);

    var last_sweep_us: u64 = recovery.nowUs();

    while (true) {
        const count = rx.recv(fd) catch continue;

        for (0..count) |i| {
            const dg = rx.get(i);
            serveDatagram(handler, table, dg, &tx, fd, config, null);
        }

        // Flush once per recv batch: the SendBatch coalesces every reply in the batch into one flush.
        tx.flush(fd) catch {};

        // Time-driven maintenance (loss recovery + idle eviction), interval-gated. This blocking-recv
        // loop (ASYNC / POOL / MIXED) has no wait timeout, so the sweep advances while traffic keeps
        // arriving; a fully silent worker parks in recv until the next datagram, acceptable off the
        // benchmark path (the EPOLL / URING workers carry the timeout wake for a total lull).
        const now_us = recovery.nowUs();
        if (now_us -| last_sweep_us >= maintenance_interval_us) {
            sweepMaintenance(table, &tx, fd, config, now_us, null);
            tx.flush(fd) catch {};
            last_sweep_us = now_us;
        }
    }
}

/// The single-worker recv loop on the calling thread (ASYNC / POOL / MIXED).
pub fn runSingle(comptime handler: core.HandlerFn, config: Http3ServerConfig) !void {
    if (!datagram.is_linux) {
        logSystem(config, "HTTP/3 requires the Linux datagram path", .{});
        return;
    }

    logSystem(config, "listening on {s}:{d} (single worker)", .{ config.ip, config.port });
    workerLoop(handler, config, false, 0);
}

/// One SO_REUSEPORT blocking-recvmmsg worker per core (POOL / MIXED, which ADR-050 defines as multi-core
/// everywhere). Each worker binds the same port with SO_REUSEPORT, pins to its CPU, and owns its own CID
/// table (shared-nothing), so the kernel load-balances connections by 4-tuple. The .EPOLL / .URING
/// siblings add readiness / completion on top of the same per-core shape (epoll.zig / uring.zig).
pub fn runMulti(comptime handler: core.HandlerFn, config: Http3ServerConfig) !void {
    if (!datagram.is_linux) {
        logSystem(config, "HTTP/3 requires the Linux datagram path", .{});
        return;
    }

    const want = effectiveWorkers(config);
    logSystem(config, "listening on {s}:{d} ({d} workers, SO_REUSEPORT + recvmmsg)", .{ config.ip, config.port, want });

    const threads = try config.allocator.alloc(std.Thread, want);
    defer config.allocator.free(threads);

    var spawned: usize = 0;
    for (0..want) |i| {
        threads[i] = std.Thread.spawn(.{ .stack_size = config.worker_stack_size_bytes }, workerLoop, .{ handler, config, true, i }) catch break;
        spawned += 1;
    }

    for (threads[0..spawned]) |t| t.join();
}

/// Process one received datagram: demux + decrypt, then drive the matching handshake or response step.
/// Shared by the recvmmsg worker loop (workerLoop) and the EPOLL worker loop (workerLoopEpoll). When
/// `stats` is non-null its request counter is bumped on a decrypted 1-RTT request (the epoll loop passes
/// it, the recvmmsg loop passes null).
pub fn serveDatagram(comptime handler: core.HandlerFn, table: *ConnTable, dg: datagram.Datagram, tx: *datagram.SendBatch, fd: std.posix.socket_t, config: Http3ServerConfig, stats: ?*WorkerStats) void {
    if (stats) |st| st.conns = table.count;

    switch (processDatagram(table, dg.data, config.cid_len, config.max_datagram_size, config.initial_window_packets)) {
        .client_hello => |n| {
            logSystem(config, "decrypted client Initial, parsed ClientHello ({d} bytes)", .{n});
            sendServerHello(table, dg.data, tx, fd, dg.from, config);
        },
        .initial_opened => |pn| logSystem(config, "decrypted client Initial, packet number {d} (ClientHello incomplete)", .{pn}),
        .parse_alert => logSystem(config, "decrypted client Initial but ClientHello parse raised an alert", .{}),
        .decrypt_failed => logSystem(config, "long-header Initial failed to decrypt under the Initial keys", .{}),
        .handshake_opened => logSystem(config, "decrypted client Handshake packet (handshake keys correct, validated live)", .{}),
        .request_opened => {
            if (stats) |st| st.requests += 1;

            logSystem(config, "decrypted client 1-RTT request (application keys correct, validated live)", .{});
            sendResponse(handler, table, dg.data, tx, fd, dg.from, config.cid_len, config, stats);
        },
        else => {},
    }
}

/// Scale `num / den` to hundredths for a "{d}.{d:0>2}" fixed-point display. Zero when den is 0.
fn ratioParts(num: u64, den: u64) struct { whole: u64, frac: u64 } {
    if (den == 0) return .{ .whole = 0, .frac = 0 };

    const scaled = num * 100 / den;

    return .{ .whole = scaled / 100, .frac = scaled % 100 };
}

/// How often (in epoll wakes) a Debug build dumps the per-worker counters. Internal, not a knob: the
/// dump exists only to localize behavior during a local Debug probe and compiles out of Release.
const stats_dump_every_wakes: u64 = 512;

/// Per-worker recv / drain / send counters for the EPOLL loop. Debug builds dump them to stderr every
/// stats_dump_every_wakes wakes to localize a closed-loop run: datagrams-per-wake and requests-per-wake
/// show whether a worker drains real batches or ping-pongs one packet at a time (the closed-loop latency
/// signature), packets-per-flush shows the send coalescing factor. The dump compiles out of Release
/// entirely (comptime gate), so a benchmark pays nothing, prints nothing, and there is no field or env
/// knob to set. Worker-owned, so no atomics. packets / flushes undercount slightly when a sub-batch
/// auto-flushes mid-fill, enough for the ratio. Both the epoll worker (epoll.zig) and the io_uring
/// worker (uring.zig) own one and pass it to serveDatagram, so this module exposes it (pub).
pub const WorkerStats = struct {
    worker_id: usize,
    wakes: u64 = 0,
    datagrams: u64 = 0,
    requests: u64 = 0,
    packets: u64 = 0,
    flushes: u64 = 0,
    /// Microseconds this worker spent parked in submit_and_wait (blocked for a completion), summed over
    /// the run. wall - block_us approximates the worker's on-CPU time, so block_us / wall is how idle a
    /// worker was: a high value with few datagrams means the worker is waiting for work, not saturated.
    block_us: u64 = 0,
    /// recovery.nowUs() at loop entry, set by registerWorkerStats. The diagnostic dump computes wall
    /// time as now - start_us. Zero means the worker never registered (dump skips it).
    start_us: u64 = 0,
    /// recovery.nowUs() captured just before the current submit_and_wait / epoll_wait, or 0 when the
    /// worker is not currently parked. The dump adds the in-progress wait (now - wait_enter_us) to
    /// block_us so a snapshot taken while every worker is idle-blocked (e.g. SIGTERM after the load
    /// stops) does not misreport that still-uncounted parked time as on-CPU time.
    wait_enter_us: u64 = 0,
    /// Times pumpStream had more of a large body to send but the client's flow control (per-stream
    /// MAX_STREAM_DATA or the connection-wide MAX_DATA) left no room, so the response stalled until the
    /// client raised a limit. A high count relative to requests is the fingerprint of flow-control
    /// pacing: the server sits idle waiting for credit instead of being CPU or send bound.
    fc_blocked: u64 = 0,
    /// Times pumpStream had more body to send but the connection's congestion window (bytes already in
    /// flight) left no room, so the send waits for an ACK to free the window. This is the healthy
    /// self-clocking back-pressure (the counterpart to fc_blocked), the fingerprint that the RFC 9002
    /// congestion control is pacing the body rather than the client's flow control gating it.
    cwnd_blocked: u64 = 0,
    /// MAX_DATA frames (0x10, connection-wide send credit) received from clients.
    max_data_recv: u64 = 0,
    /// MAX_STREAM_DATA frames (0x11, per-stream send credit) received from clients.
    max_stream_data_recv: u64 = 0,
    /// This worker's ConnTable.count as of its last processed datagram: how many distinct connections
    /// this worker owns right now. Distinguishes an uneven-SO_REUSEPORT-distribution problem (a busy
    /// worker legitimately owns most connections) from a stall problem (an idle worker owns connections
    /// that stopped producing traffic): compare `conns` against `req` across workers in the same dump.
    conns: u64 = 0,

    /// A worker's derived timing at a given instant, the numbers the diagnostic dump reports.
    pub const Snapshot = struct {
        wall_us: u64,
        active_us: u64,
        active_pct: u64,
    };

    /// Derive wall / on-CPU time from the raw counters at `now_us` (a recovery.nowUs() reading). Pure,
    /// so the dump's arithmetic is testable without signals or file descriptors. Saturating subtraction
    /// throughout: a block_us that briefly exceeds wall (measured across a nowUs pair) reads as 0 active
    /// rather than underflowing.
    ///
    /// Param:
    /// now_us - u64 (the current monotonic time, same base as start_us / block_us)
    ///
    /// Return:
    /// - Snapshot (wall_us, active_us, and active_pct = active as a percent of wall, 0 when wall is 0)
    pub fn snapshot(self: *const WorkerStats, now_us: u64) Snapshot {
        const wall_us = now_us -| self.start_us;

        // Count an in-progress park: block_us is only committed after a wait returns, so a worker
        // currently parked has uncounted blocked time that would otherwise read as on-CPU.
        var block = self.block_us;
        if (self.wait_enter_us != 0) block +|= now_us -| self.wait_enter_us;

        const active_us = wall_us -| block;
        const active_pct = if (wall_us > 0) active_us * 100 / wall_us else 0;

        return .{ .wall_us = wall_us, .active_us = active_us, .active_pct = active_pct };
    }

    /// Dump the counters every stats_dump_every_wakes wakes, Debug builds only (a no-op in Release).
    pub fn maybeDump(self: *const WorkerStats) void {
        if (comptime !diag_enabled) return;
        if (self.wakes == 0 or self.wakes % stats_dump_every_wakes != 0) return;

        const dgw = ratioParts(self.datagrams, self.wakes);
        const reqw = ratioParts(self.requests, self.wakes);
        const pktf = ratioParts(self.packets, self.flushes);

        var buf: [320]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "zix h3 w{d}: wakes={d} dg={d} req={d} pkt={d} flush={d} | dg/wake={d}.{d:0>2} req/wake={d}.{d:0>2} pkt/flush={d}.{d:0>2}\n", .{
            self.worker_id, self.wakes, self.datagrams, self.requests, self.packets, self.flushes,
            dgw.whole,      dgw.frac,   reqw.whole,     reqw.frac,     pktf.whole,   pktf.frac,
        }) catch return;

        _ = linux.write(2, line.ptr, line.len);
    }
};

// --------------------------------------------------------------- //

/// The most workers the diagnostic registry tracks. One per core on any realistic host, so this is a
/// generous fixed cap that keeps the registry allocation-free.
const max_diag_workers = 512;

/// The per-worker diagnostic (counters, SIGUSR1 / SIGTERM / SIGINT dump) is compiled in only outside
/// ReleaseSafe / ReleaseFast, so a production build installs no signal handler and pays no dump cost.
pub const diag_enabled = builtin.mode != .ReleaseSafe and builtin.mode != .ReleaseFast;

/// Registry of live worker stats, so a signal handler can dump every worker's counters without the
/// workers cooperating (they may all be parked in submit_and_wait when the signal arrives). Each worker
/// publishes a pointer to its own stack-resident WorkerStats once, at loop entry. The pointer stays
/// valid for the process lifetime because a worker thread lives that long.
var g_diag_stats: [max_diag_workers]?*WorkerStats = @splat(null);
var g_diag_count: std.atomic.Value(usize) = .init(0);
var g_diag_installed: std.atomic.Value(bool) = .init(false);

/// Publish this worker's stats to the diagnostic registry and stamp its start time. Call once, at the
/// top of a worker loop, before the loop begins. Over the fixed cap the worker is simply not tracked
/// (the dump still covers every worker up to the cap).
///
/// Param:
/// stats - *WorkerStats (the worker's own counters, must outlive the process, i.e. loop-local)
///
/// Return:
/// - void
pub fn registerWorkerStats(stats: *WorkerStats) void {
    if (comptime !diag_enabled) return;

    stats.start_us = recovery.nowUs();

    const idx = g_diag_count.fetchAdd(1, .acq_rel);
    if (idx < max_diag_workers) g_diag_stats[idx] = stats;
}

/// Install the diagnostic-dump signal handlers once per process. SIGUSR1 dumps every worker's counters
/// and keeps running (sample mid-benchmark), SIGTERM / SIGINT dump then exit (the natural stop dumps
/// too). Idempotent: a second call is a no-op. Called from the run entry point before workers spawn.
///
/// Note:
/// - The dump reads worker counters without locking. u64 loads on the target are atomic, so a value is
///   never torn, only possibly one wake stale, which does not matter for a coarse per-worker snapshot.
pub fn installDiagnosticDump() void {
    if (comptime !diag_enabled) return;

    if (g_diag_installed.swap(true, .acq_rel)) return;

    const act = linux.Sigaction{
        .handler = .{ .handler = diagSignalHandler },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.USR1, &act, null);
    _ = linux.sigaction(linux.SIG.TERM, &act, null);
    _ = linux.sigaction(linux.SIG.INT, &act, null);
}

/// The signal handler: dump all workers, then exit unless the signal was SIGUSR1 (dump and continue).
/// Uses only stack-buffer formatting and raw writes, so it is safe to run in signal context.
fn diagSignalHandler(sig: linux.SIG) callconv(.c) void {
    dumpAllWorkerStats();

    if (sig != linux.SIG.USR1) linux.exit_group(0);
}

/// Write every registered worker's counters to stderr as one line each, then a totals line. The header
/// line names the fields. active_us = wall - block_us is the on-CPU estimate, active_pct = active_us
/// as a percent of wall, which is the per-worker CPU utilization the drop across bench runs is about.
fn dumpAllWorkerStats() void {
    const count = @min(g_diag_count.load(.acquire), max_diag_workers);
    const now = recovery.nowUs();

    var buf: [384]u8 = undefined;
    const header = "zix h3 diag: per-worker (active_pct=on-CPU/wall, dg/wake=recv batch, fc=flow-control stalls, cwnd=congestion-window waits, md/msd=MAX_DATA/MAX_STREAM_DATA recv, conns=owned connections)\n";
    _ = linux.write(2, header.ptr, header.len);

    var total_active_us: u64 = 0;
    var total_datagrams: u64 = 0;
    var total_requests: u64 = 0;
    var total_fc_blocked: u64 = 0;
    var active_workers: usize = 0;

    for (g_diag_stats[0..count]) |maybe_stats| {
        const stats = maybe_stats orelse continue;
        if (stats.start_us == 0) continue;

        const snap = stats.snapshot(now);
        const dgw = ratioParts(stats.datagrams, stats.wakes);

        total_active_us += snap.active_us;
        total_datagrams += stats.datagrams;
        total_requests += stats.requests;
        total_fc_blocked += stats.fc_blocked;
        if (stats.datagrams > 0) active_workers += 1;

        const line = std.fmt.bufPrint(&buf, "  w{d}: active={d}ms({d}%) wall={d}ms wakes={d} dg={d} req={d} pkt={d} dg/wake={d}.{d:0>2} fc={d} cwnd={d} md={d} msd={d} conns={d}\n", .{
            stats.worker_id,  snap.active_us / 1000, snap.active_pct,     snap.wall_us / 1000,        stats.wakes,
            stats.datagrams,  stats.requests,        stats.packets,       dgw.whole,                  dgw.frac,
            stats.fc_blocked, stats.cwnd_blocked,    stats.max_data_recv, stats.max_stream_data_recv, stats.conns,
        }) catch continue;

        _ = linux.write(2, line.ptr, line.len);
    }

    const totals = std.fmt.bufPrint(&buf, "  TOTAL: active={d}ms across {d} workers with traffic, dg={d} req={d} fc_stalls={d}\n", .{
        total_active_us / 1000, active_workers, total_datagrams, total_requests, total_fc_blocked,
    }) catch return;

    _ = linux.write(2, totals.ptr, totals.len);
}

// --------------------------------------------------------------- //

/// Build and send the server's ServerHello Initial in reply to a decrypted ClientHello (handshake
/// step 2). Idempotent per connection: sent once, skipped on retransmits.
fn sendServerHello(table: *ConnTable, data: []const u8, tx: *datagram.SendBatch, fd: std.posix.socket_t, peer: std.posix.sockaddr.in6, config: Http3ServerConfig) void {
    const hdr = packet.parseLongHeader(data) catch return;
    if (hdr.packet_type != 0) return;

    const dcid = demux.ConnId.fromSlice(hdr.dcid);
    const conn = table.find(&dcid) orelse return;

    // Stamp liveness even on a retransmitted Initial: the peer is alive, so the maintenance sweep must
    // not treat a still-handshaking connection as idle.
    conn.peer_addr = peer;
    conn.last_activity_us = recovery.nowUs();

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
        conn.ack_delay_exponent = tp.ack_delay_exponent;
        conn.client_max_udp_payload = tp.max_udp_payload_size;
    }

    // Choose our Source Connection ID (the client will use it as its Destination CID) and the fresh
    // per-connection randoms.
    const cid_len: usize = @min(config.cid_len, 20);
    var scid_bytes: [20]u8 = undefined;
    _ = std.os.linux.getrandom(&scid_bytes, cid_len, 0);
    conn.our_scid = demux.ConnId.fromSlice(scid_bytes[0..cid_len]);

    // Index the connection under the SCID we issued too: the client uses it as its Destination CID for
    // every 1-RTT packet, so this makes those resolve in O(1) instead of a per-packet linear scan.
    table.addAlias(conn.our_scid, conn);

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

/// Expand a request `accept-encoding` into a plain slice: Huffman-decoded into `scratch` when a custom
/// literal value arrived Huffman-coded, otherwise the value as decoded (the common indexed form,
/// `gzip, deflate, br`, is already plain). The slice is only read during the handler call, so a
/// caller-owned stack scratch is enough. Returns empty on a malformed Huffman code, which the handler
/// then treats as no accept-encoding (identity).
fn decodeAcceptEncoding(scratch: []u8, req: request.DecodedRequest) []const u8 {
    if (req.accept_encoding_huffman) {
        const len = huffman.decode(scratch, req.accept_encoding) orelse return "";

        return scratch[0..len];
    }

    return req.accept_encoding;
}

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

/// The total HTTP/3 stream length for a response: the prefix (HEADERS + DATA header) plus the body. The
/// content coding is part of the prefix (one field line), so it must match the coding the pump emits or
/// the flow-control accounting would drift by a byte.
fn streamContentLen(status: u16, content_encoding: response.ContentEncoding, body: []const u8) usize {
    var buf: [32]u8 = undefined;
    const prefix_len = response.buildStreamPrefix(&buf, status, content_encoding, body.len) orelse 0;

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

/// Apply the acknowledgment content of a decrypted 1-RTT payload: an ACK frame (0x02 / 0x03) drives RTT
/// sampling, range retirement, loss detection and retransmission, congestion control, and send-stream
/// retirement (RFC 9002, Connection.onAckFrame). Every other frame is walked past. Run BEFORE request
/// registration in sendResponse: a stream is now freed on ack (not on send), so an ACK that finishes an
/// earlier stream must free its slot here, in time for a request riding the same datagram to claim it,
/// or the pool (sized to the client's stream concurrency) could refuse it with a spurious 500.
fn applyAcks(conn: *Connection, payload: []const u8) void {
    var pos: usize = 0;
    while (pos < payload.len) {
        const type_vi = varint.read(payload[pos..]) catch break;
        const frame_type = type_vi.value;

        if (frame_type == 0x02 or frame_type == 0x03) {
            const parsed = flow.parseAck(payload[pos..], conn.ack_delay_exponent) catch break;
            conn.onAckFrame(parsed, recovery.nowUs());
            pos += parsed.consumed;
            continue;
        }

        if (request.isStreamFrameType(frame_type)) {
            const stream = request.parseStreamFrame(payload[pos..]) orelse break;
            pos += stream.consumed;
            continue;
        }

        if (frame_type == 0x1c or frame_type == 0x1d) {
            // The peer is closing (RFC 9000 10.2): move to draining so the maintenance sweep evicts the
            // connection promptly and frees its slot, instead of holding it to the idle timeout. No
            // frames after CONNECTION_CLOSE are processed.
            conn.close_state = close.closeTransition(conn.close_state, .recv_close) orelse conn.close_state;
            break;
        }

        const skipped = request.skipFrame(payload[pos..]) orelse break;
        pos += skipped;
    }
}

/// Apply the flow-control credit of a decrypted 1-RTT payload: MAX_DATA (0x10) raises the
/// connection-wide send limit, MAX_STREAM_DATA (0x11) raises a tracked stream's limit (a limit only ever
/// increases, RFC 9000 4.1, so a smaller value is ignored). An ACK frame is parsed only to walk past it
/// (applyAcks already handled it). Run AFTER request registration so a MAX_STREAM_DATA riding the same
/// packet as the request it unblocks lands on the just-registered stream.
fn applyStreamCredit(conn: *Connection, payload: []const u8, stats: ?*WorkerStats) void {
    var pos: usize = 0;
    while (pos < payload.len) {
        const type_vi = varint.read(payload[pos..]) catch break;
        const frame_type = type_vi.value;

        if (frame_type == 0x02 or frame_type == 0x03) {
            const parsed = flow.parseAck(payload[pos..], conn.ack_delay_exponent) catch break;
            pos += parsed.consumed;
            continue;
        }

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
            if (stats) |st| st.max_data_recv += 1;
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
            if (stats) |st| st.max_stream_data_recv += 1;
            pos = p;
            continue;
        }

        const skipped = request.skipFrame(payload[pos..]) orelse break;
        pos += skipped;
    }
}

/// The stream offset the pump may reach this round: the flow-control ceiling (`fc_limit`), capped so the
/// connection never holds more than a congestion window of bytes in flight (RFC 9002 7) and never more
/// than `window_cap` (the in-flight ceiling in bytes, from config.max_inflight_packets clamped to the
/// sent-range ring capacity, so a range is never overwritten while still awaiting acknowledgment). Pure,
/// so the gate that stops the whole-body burst is testable without a socket.
///
/// Param:
/// fc_limit - usize (the flow-control reachable offset: stream / connection MAX_DATA, capped at content)
/// sent - usize (the stream offset already sent, the floor this round starts from)
/// congestion_window - u64 (conn.cc.congestion_window, the NewReno window in bytes)
/// bytes_in_flight - u64 (conn.bytes_in_flight, stream bytes sent but not yet acknowledged)
/// window_cap - u64 (the in-flight ceiling in bytes: in-flight packets allowed times max_datagram_size)
///
/// Return:
/// - usize (the offset the pump may send up to, never below `sent`)
fn pumpLimit(fc_limit: usize, sent: usize, congestion_window: u64, bytes_in_flight: u64, window_cap: u64) usize {
    const window = @min(congestion_window, window_cap);
    const cwnd_room = window -| bytes_in_flight;
    const ceiling = sent + @as(usize, @intCast(@min(cwnd_room, window_cap)));

    return @min(fc_limit, ceiling);
}

/// Send as much of a large response stream as flow control and the congestion window now permit,
/// fragmenting it into STREAM frames across 1-RTT packets (RFC 9000 19.8) and advancing the stream's
/// sent offset. The connection's first response packet carries HANDSHAKE_DONE + the server control
/// SETTINGS, and the first packet sent this call carries the pending ACK. A completed stream frees its
/// slot. Returns true when at least one packet was sent.
fn pumpStream(conn: *Connection, stream: *SendStream, tx: *datagram.SendBatch, fd: std.posix.socket_t, peer: std.posix.sockaddr.in6, ack_pending: *?u64, max_streams_pending: *?u64, config: Http3ServerConfig, stats: ?*WorkerStats) bool {
    var prefix_buf: [32]u8 = undefined;
    const prefix_len = response.buildStreamPrefix(&prefix_buf, stream.status, stream.content_encoding, stream.body.len) orelse {
        stream.active = false;
        return false;
    };
    const prefix = prefix_buf[0..prefix_len];

    // The reachable offset: the stream's own flow limit, capped by the connection-wide remaining
    // credit. Credit is charged against high_water (the highest offset ever reached), not `sent`
    // directly: a loss retransmission rewinds `sent` backward to resend an already-charged range, and
    // that resend must not charge the connection-wide budget a second time (RFC 9000 4.1 counts
    // distinct stream offset, not bytes handed to sendmsg).
    const conn_remaining = if (conn.client_max_data > conn.conn_data_sent) conn.client_max_data - conn.conn_data_sent else 0;
    const fc_limit = @min(stream.content_len, @min(stream.stream_limit, stream.high_water + conn_remaining));

    // Never hold more than a congestion window of stream bytes in flight, so a multi-packet body
    // self-clocks to the client's ACKs instead of dumping the whole body in one burst (which overruns
    // the client's socket buffer and strands the drops with no timely retransmit). The window ceiling is
    // config.max_inflight_packets, clamped to the sent-range ring capacity so an in-flight range is never
    // overwritten. bytes_in_flight already counts this stream's earlier sends plus any sibling stream
    // pumped before it this round, so the window is shared connection-wide, not per-stream.
    const window_cap = @min(config.max_inflight_packets, max_sent_ranges) * config.max_datagram_size;
    const limit = pumpLimit(fc_limit, stream.sent, conn.cc.congestion_window, conn.bytes_in_flight, window_cap);

    if (limit <= stream.sent) {
        // More body remains but no room this round. Separate the two back-pressure sources so a
        // diagnostic dump tells throttling by the client (flow control credit) from throttling by our
        // own pacing (congestion window). A finished stream (sent reached content_len) counts as
        // neither.
        if (stream.sent < stream.content_len) {
            if (stats) |st| {
                if (fc_limit <= stream.sent) st.fc_blocked += 1 else st.cwnd_blocked += 1;
            }
        }

        return false;
    }

    // The wire datagram size for this connection: the smaller of the configured size, what the client
    // will accept (RFC 9000 18.2), and the compile-time ceiling. A larger datagram carries more stream
    // bytes per packet, so a big response goes out as fewer packets, cutting the per-packet header /
    // AEAD / ACK work that dominates a big-response run. The chunk is that size minus the room a sealed
    // packet needs for its frames and tag, optionally capped by an explicit config.max_stream_chunk.
    const dgram: usize = @intCast(conn.sendDatagramSize(config.max_datagram_size, max_send_datagram_size));
    var chunk_budget = dgram - per_packet_frame_reserve;
    if (config.max_stream_chunk != 0) chunk_budget = @min(chunk_budget, config.max_stream_chunk);

    var payload: [max_send_datagram_size]u8 = undefined;
    var sent_any = false;
    while (stream.sent < limit) {
        const chunk = @min(chunk_budget, limit - stream.sent);
        const is_last = (stream.sent + chunk == stream.content_len); // FIN only when fully sent

        var pos: usize = 0;

        if (!conn.first_response_sent) {
            payload[pos] = 0x1e; // HANDSHAKE_DONE
            pos += 1;

            // Server control stream (id 3): stream type 0x00 then an empty SETTINGS frame.
            payload[pos] = 0x0a; // STREAM | LEN
            pos += 1;
            pos += varint.write(payload[pos..], 3);
            pos += varint.write(payload[pos..], 3);
            payload[pos] = 0x00;
            payload[pos + 1] = 0x04;
            payload[pos + 2] = 0x00;
            pos += 3;

            conn.first_response_sent = true;
        }

        if (ackTake(ack_pending)) |largest| pos += response.buildAck(payload[pos..], largest);

        if (maxStreamsTake(max_streams_pending)) |granted| pos += response.buildMaxStreams(payload[pos..], granted);

        // STREAM frame on the request stream: type OFF | LEN (| FIN), id, offset, length, then data.
        payload[pos] = 0x0e | @as(u8, if (is_last) 0x01 else 0x00);
        pos += 1;
        pos += varint.write(payload[pos..], stream.stream_id);
        pos += varint.write(payload[pos..], stream.sent);
        pos += varint.write(payload[pos..], chunk);
        copyStreamSlice(prefix, stream.body, stream.sent, payload[pos..][0..chunk]);
        pos += chunk;

        sealAndQueue(conn, tx, fd, peer, payload[0..pos], .{ .stream_id = stream.stream_id, .offset = stream.sent, .length = @intCast(chunk) });

        const offset_after = stream.sent + chunk;
        if (offset_after > stream.high_water) {
            conn.conn_data_sent += offset_after - stream.high_water;
            stream.high_water = offset_after;
        }
        stream.sent = offset_after;
        stream.unacked += chunk;
        sent_any = true;
    }

    // A fully-sent stream is not freed here: it stays active until its packets are acknowledged
    // (Connection.onAckFrame retires it once unacked reaches 0), so a tail packet lost after the last
    // byte went out is still found and retransmitted by the loss rewind.
    if (stream.complete()) logSystem(config, "stream {d} fully sent ({d} bytes), awaiting ack", .{ stream.stream_id, stream.content_len });

    return sent_any;
}

/// Seal a 1-RTT payload into a short packet directly in the send batch's slot (no scratch buffer, no
/// copy: the AEAD writes the packet where sendmmsg / GSO will read it), flushing the batch first when
/// it has no room so the reply is never dropped. `retransmit` is the SendStream byte range this packet
/// carries, recorded for loss detection (Connection.recordSentRange), or null for a packet that
/// carries no SendStream data (a coalesced small response or a bare ACK): those have no retransmission
/// yet, a known gap noted in rnd/http3-uring-throughput-plan.md.
fn sealAndQueue(conn: *Connection, tx: *datagram.SendBatch, fd: std.posix.socket_t, peer: std.posix.sockaddr.in6, payload: []const u8, retransmit: ?SentRangeInfo) void {
    const needed = payload.len + protection.short_seal_overhead_max;

    // Reserve the batch's free tail and seal into it. A full batch (no room for a packet this size)
    // flushes first, then reserves from the reset batch, which always has room for one packet.
    const slot = tx.reserve(needed) orelse blk: {
        tx.flush(fd) catch return;
        break :blk tx.reserve(needed) orelse return;
    };

    const reply = protection.sealShort(slot, conn.app_keys.server, conn.peer_scid.slice(), conn.app_pn, payload) catch return;
    const packet_number = conn.app_pn;
    conn.app_pn += 1;

    // Commit only after a successful seal: a seal error leaves the reserved tail uncommitted (used /
    // count unmoved), so the packet number is not consumed and nothing partial is ever sent.
    if (retransmit) |info| conn.recordSentRange(packet_number, recovery.nowUs(), info);

    tx.commit(peer, reply.len);
}

/// Build and send the HTTP/3 responses for the 1-RTT payload captured on the connection. A connection
/// multiplexes many requests, each on its own client bidi stream, and one packet can coalesce several:
/// a small response goes out in one packet, a large one is registered as a send stream and fragmented
/// across packets within the client's flow control, resumed as MAX_STREAM_DATA / MAX_DATA arrive. A
/// packet carrying no work is acknowledged so the client stops retransmitting.
fn sendResponse(handler: core.HandlerFn, table: *ConnTable, data: []const u8, tx: *datagram.SendBatch, fd: std.posix.socket_t, peer: std.posix.sockaddr.in6, cid_len: usize, config: Http3ServerConfig, stats: ?*WorkerStats) void {
    if (data.len < 1 + cid_len) return;

    const dcid = demux.ConnId.fromSlice(data[1 .. 1 + cid_len]);
    const conn = findConn(table, &dcid) orelse return;
    if (!conn.app_ready) return;

    // Stamp liveness for the maintenance sweep: the peer address so a timer-driven retransmit has a
    // destination, and the activity time so a live connection is never evicted as idle.
    conn.peer_addr = peer;
    conn.last_activity_us = recovery.nowUs();

    const payload_view = conn.app_payload_buf[0..conn.app_payload_len];

    // The honest ACK (with ranges) is built in the prologue below from conn.ack. The pump carries none.
    var ack_pending: ?u64 = null;

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

    // Apply the client's ACKs first: retire acknowledged ranges, grow the window, rewind any lost stream
    // for retransmit, and free the slot of any stream this ACK fully retires. Done before the
    // registration loop so a request riding the same datagram as the finishing ACK finds the freed slot
    // (stream credit, MAX_DATA / MAX_STREAM_DATA, is applied after registration).
    applyAcks(conn, payload_view);

    // Coalesce small responses into one 1-RTT packet: pack each response's STREAM frame back to back,
    // sealing once per packet instead of once per response. A recv datagram carries many requests, so
    // baseline collapses dozens of AEAD seals and short headers into one. Large bodies still register a
    // send stream the pump fragments below.
    var pbuf: [COALESCE_PAYLOAD_MAX]u8 = undefined;
    var plen: usize = 0;

    // Prologue on the first packet: the ACK, the connection's one-time HANDSHAKE_DONE and server
    // control SETTINGS, and a due MAX_STREAMS. Consumed here so the pump and the seal below do not
    // repeat them. If this datagram carried no request, the prologue alone is the bare-ACK packet.
    if (conn.ack.have_largest) plen += response.buildAckRanges(pbuf[plen..], conn.ack.largest_pn, conn.ack.received_mask);
    if (!conn.first_response_sent) {
        pbuf[plen] = 0x1e; // HANDSHAKE_DONE
        plen += 1;
        _ = response.writeStreamFrame(&pbuf, &plen, 3, false, &[_]u8{ 0x00, 0x04, 0x00 }); // control: SETTINGS
        conn.first_response_sent = true;
    }
    if (maxStreamsTake(&max_streams_pending)) |granted| plen += response.buildMaxStreams(pbuf[plen..], granted);

    for (reqs[0..count]) |stream_req| {
        // A retransmit of a request already being streamed: leave its progress, the pump continues it.
        if (conn.findSendStream(stream_req.stream_id) != null) continue;

        var ae_scratch: [128]u8 = undefined;
        var req = core.Request{
            .method = stream_req.request.method,
            .path = decodePath(conn, stream_req.request),
            .accept_encoding = decodeAcceptEncoding(&ae_scratch, stream_req.request),
        };
        var res = core.Response{};
        handler(&req, &res);

        var content: [1024]u8 = undefined;
        const content_len = response.buildRequestStreamContent(&content, res.status, res.content_encoding, res.body) orelse {
            // A body too large for one packet: register a send stream the pump fragments within flow
            // control, or answer 500 (packed like a small response) when no slot is free.
            if (conn.reserveSendStream(stream_req.stream_id)) |slot| {
                slot.* = .{
                    .active = true,
                    .stream_id = stream_req.stream_id,
                    .status = res.status,
                    .body = res.body,
                    .content_encoding = res.content_encoding,
                    .content_len = streamContentLen(res.status, res.content_encoding, res.body),
                    .sent = 0,
                    .stream_limit = conn.client_max_stream_data,
                };
            } else {
                const five = response.buildRequestStreamContent(&content, 500, .identity, "") orelse continue;
                packStreamFrame(conn, tx, fd, peer, &pbuf, &plen, stream_req.stream_id, content[0..five]);
            }
            continue;
        };

        packStreamFrame(conn, tx, fd, peer, &pbuf, &plen, stream_req.stream_id, content[0..content_len]);
    }

    // Apply this packet's flow-control credit after registering requests, so a MAX_STREAM_DATA that
    // rides the same packet as the request it unblocks lands on the just-registered stream. The ACKs in
    // this payload were already applied above (applyAcks), before the slots were reserved.
    applyStreamCredit(conn, payload_view, stats);

    // Seal the coalesced response packet (prologue plus packed small responses), before the pump so the
    // client sees the ACK and HANDSHAKE_DONE first.
    if (plen > 0) sealAndQueue(conn, tx, fd, peer, pbuf[0..plen], null);

    // Pump every active large stream. The ACK and MAX_STREAMS were consumed into the coalesced packet,
    // so ack_pending / max_streams_pending are null here, the pump carries only stream data. The worker
    // loop flushes the SendBatch once per recv batch, so this call leaves replies queued, not flushed.
    for (&conn.send_streams) |*stream| {
        if (stream.active) _ = pumpStream(conn, stream, tx, fd, peer, &ack_pending, &max_streams_pending, config, stats);
    }
}

/// Append a response STREAM frame (with FIN) to the coalesced packet, sealing the full packet and
/// starting a fresh one when the frame no longer fits. A single response always fits an empty packet
/// (its content is capped below the budget), so the retry cannot loop.
fn packStreamFrame(conn: *Connection, tx: *datagram.SendBatch, fd: std.posix.socket_t, peer: std.posix.sockaddr.in6, pbuf: []u8, plen: *usize, stream_id: u64, content: []const u8) void {
    if (response.writeStreamFrame(pbuf, plen, stream_id, true, content)) return;

    sealAndQueue(conn, tx, fd, peer, pbuf[0..plen.*], null);
    plen.* = 0;
    _ = response.writeStreamFrame(pbuf, plen, stream_id, true, content);
}

// --------------------------------------------------------------- //

/// How often a worker runs the maintenance sweep (RFC 9002 6.2 loss recovery when no ACK arrives, plus
/// RFC 9000 10.1 idle eviction), in microseconds. Coarse on purpose: a Probe Timeout is an RTT plus
/// backoff (many milliseconds) and idle eviction is on the order of seconds, so a sweep every few
/// milliseconds recovers a lost tail promptly while its cost (one scan of the per-worker connection
/// table) stays negligible against the datagram rate. A worker arms this wake only while it owns at
/// least one connection, so a fully idle worker still parks indefinitely and stays off the CPU.
pub const maintenance_interval_us: u64 = 5_000;

/// Resume every active send stream on `conn` after a Probe Timeout rewound them, queuing the packets into
/// `tx` for the caller to flush. A pure retransmit carries only stream data, so it takes no pending ACK
/// or MAX_STREAMS (those ride a fresh request's reply). The peer address comes from the connection
/// (conn.peer_addr): a timer-driven resend has no incoming datagram to carry it.
fn resumeStreams(conn: *Connection, tx: *datagram.SendBatch, fd: std.posix.socket_t, config: Http3ServerConfig, stats: ?*WorkerStats) void {
    var ack_pending: ?u64 = null;
    var max_streams_pending: ?u64 = null;

    for (&conn.send_streams) |*stream| {
        if (stream.active) _ = pumpStream(conn, stream, tx, fd, conn.peer_addr, &ack_pending, &max_streams_pending, config, stats);
    }
}

/// Run one time-driven maintenance pass over every live connection this worker owns (shared by the epoll
/// and io_uring workers, each calling it at most once per maintenance_interval_us). For each connection:
/// retransmit a flight whose Probe Timeout fired (the tail-loss recovery an ack-clocked path cannot do on
/// its own, RFC 9002 6.2), and evict one whose peer has gone (RFC 9000 10.1) so its table slot is
/// reclaimed instead of pinned for the worker's life. Without this, a lost tail leaves a connection
/// wedged (bytes stuck in flight, window collapsed) and the slot never frees, which is what collapsed
/// EPOLL static-h3 across bench runs. Leaves retransmitted packets queued in `tx`; the caller flushes.
pub fn sweepMaintenance(table: *ConnTable, tx: *datagram.SendBatch, fd: std.posix.socket_t, config: Http3ServerConfig, now_us: u64, stats: ?*WorkerStats) void {
    const max_idle_us: u64 = @as(u64, config.max_idle_ms) * 1000; // ms to us

    for (0..ConnTable.slot_capacity) |slot| {
        const conn = table.at(slot) orelse continue;

        const result = conn.onMaintenance(now_us, max_idle_us);
        if (result.resend) resumeStreams(conn, tx, fd, config, stats);
        if (result.idle) _ = table.remove(&conn.dcid);
    }

    if (stats) |st| st.conns = table.count;
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

test "zix test: processDatagram demuxes a long-header Initial by DCID" {
    var table = ConnTable{};

    // A crafted Initial long header: 0xc3, version 1, 8-byte DCID, 4-byte SCID, one payload byte.
    const initial = [_]u8{ 0xc3, 0x00, 0x00, 0x00, 0x01, 0x08, 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08, 0x04, 0x11, 0x22, 0x33, 0x44, 0x00 };
    _ = processDatagram(&table, &initial, 8, 1200, 10);

    const dcid = demux.ConnId.fromSlice(&[_]u8{ 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08 });
    try std.testing.expectEqual(@as(usize, 1), table.count);
    try std.testing.expect(table.find(&dcid) != null);

    // A second datagram for the same connection reuses the slot, not a new one.
    _ = processDatagram(&table, &initial, 8, 1200, 10);
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

test "zix test: pumpLimit caps the send at the congestion window, the window cap, and flow control" {
    // window_cap here is 128 packets * 1200 = 153600 bytes (the default max_inflight_packets window).
    const cap = 153_600;

    // Nothing in flight, a huge flow-control ceiling: the initial 12000-byte congestion window is the
    // binding cap, so the pump sends the initial window, not the whole body.
    try std.testing.expectEqual(@as(usize, 12_000), pumpLimit(1_000_000, 0, 12_000, 0, cap));

    // Flow control tighter than the window: flow control wins (the client granted only 5000 bytes).
    try std.testing.expectEqual(@as(usize, 5_000), pumpLimit(5_000, 0, 12_000, 0, cap));

    // A congestion window larger than the window cap is clamped to the cap (153600), so an in-flight
    // packet is never overwritten before loss detection can see it.
    try std.testing.expectEqual(@as(usize, 153_600), pumpLimit(1_000_000, 0, 1_000_000, 0, cap));

    // The whole window is already outstanding: the ceiling collapses to the current offset (limit <=
    // sent), which the caller reads as the cwnd-blocked signal and stops until an ACK frees the window.
    try std.testing.expectEqual(@as(usize, 3_000), pumpLimit(1_000_000, 3_000, 12_000, 12_000, cap));

    // Partial room: 4000 of a 12000 window in flight leaves 8000, so from offset 3000 the pump may
    // reach 11000, still under the flow-control ceiling.
    try std.testing.expectEqual(@as(usize, 11_000), pumpLimit(1_000_000, 3_000, 12_000, 4_000, cap));
}

test "zix test: applyStreamCredit raises the connection and stream limits" {
    const dcid = [_]u8{ 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08 };
    var conn = Connection.init(&dcid, 1200, 10);
    conn.send_streams[0] = .{ .active = true, .stream_id = 0, .stream_limit = 1000 };

    // MAX_DATA (0x10) = 5000 then MAX_STREAM_DATA (0x11) for stream 0 = 9000.
    var stats = WorkerStats{ .worker_id = 0 };
    const payload = [_]u8{ 0x10, 0x53, 0x88, 0x11, 0x00, 0x63, 0x28 };
    applyStreamCredit(&conn, &payload, &stats);

    try std.testing.expectEqual(@as(u64, 5000), conn.client_max_data);
    try std.testing.expectEqual(@as(u64, 9000), conn.send_streams[0].stream_limit);

    // Each credit update is counted for the diagnostic dump (one MAX_DATA, one MAX_STREAM_DATA).
    try std.testing.expectEqual(@as(u64, 1), stats.max_data_recv);
    try std.testing.expectEqual(@as(u64, 1), stats.max_stream_data_recv);

    // A smaller advertisement never lowers an existing limit (RFC 9000 4.1).
    const lower = [_]u8{ 0x11, 0x00, 0x40, 0x64 }; // MAX_STREAM_DATA stream 0 = 100
    applyStreamCredit(&conn, &lower, &stats);
    try std.testing.expectEqual(@as(u64, 9000), conn.send_streams[0].stream_limit);
    try std.testing.expectEqual(@as(u64, 2), stats.max_stream_data_recv);
}

test "zix test: applyAcks feeds a real ACK frame into Connection.onAckFrame" {
    const dcid = [_]u8{ 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08 };
    var conn = Connection.init(&dcid, 1200, 10);
    conn.recordSentRange(10, recovery.nowUs(), .{ .stream_id = 0, .offset = 0, .length = 100 });

    // ACK (0x02): largest=10, delay=0, range_count=0, first_ack_range=3 -> acks [7, 10].
    const payload = [_]u8{ 0x02, 0x0a, 0x00, 0x00, 0x03 };
    applyAcks(&conn, &payload);

    try std.testing.expect(conn.rtt.has_sample);
    try std.testing.expect(!conn.sent_ranges[0].in_flight);
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

test "zix test: ratioParts scales num/den to hundredths and guards a zero denominator" {
    // 3/2 = 1.50, 64/32 = 2.00 (the datagrams-per-wake the stats line reports).
    try std.testing.expectEqual(@as(u64, 1), ratioParts(3, 2).whole);
    try std.testing.expectEqual(@as(u64, 50), ratioParts(3, 2).frac);
    try std.testing.expectEqual(@as(u64, 2), ratioParts(64, 32).whole);
    try std.testing.expectEqual(@as(u64, 0), ratioParts(64, 32).frac);

    // A zero denominator (no wakes yet) reports 0.00 instead of dividing by zero.
    try std.testing.expectEqual(@as(u64, 0), ratioParts(0, 0).whole);
    try std.testing.expectEqual(@as(u64, 0), ratioParts(5, 0).frac);
}

test "zix test: WorkerStats.maybeDump only reads, never mutates the counters" {
    // A wake count that is not a dump multiple: maybeDump must leave every counter unchanged (it only
    // reads them to format the line). The dump itself is Debug-only and compiled out of Release.
    var stats = WorkerStats{ .worker_id = 0, .wakes = 100, .datagrams = 200 };
    stats.maybeDump();

    try std.testing.expectEqual(@as(u64, 100), stats.wakes);
    try std.testing.expectEqual(@as(u64, 200), stats.datagrams);
}

test "zix test: WorkerStats.snapshot derives wall, on-CPU time, and utilization percent" {
    // start at 1_000us, sampled at 11_000us -> 10_000us wall, blocked 9_000us -> 1_000us on CPU = 10%.
    const busy = WorkerStats{ .worker_id = 0, .start_us = 1_000, .block_us = 9_000 };
    const snap = busy.snapshot(11_000);
    try std.testing.expectEqual(@as(u64, 10_000), snap.wall_us);
    try std.testing.expectEqual(@as(u64, 1_000), snap.active_us);
    try std.testing.expectEqual(@as(u64, 10), snap.active_pct);

    // Blocked longer than wall (a nowUs pair straddling the sample) saturates to 0 active, never underflows.
    const over = WorkerStats{ .worker_id = 1, .start_us = 1_000, .block_us = 50_000 };
    const snap_over = over.snapshot(11_000);
    try std.testing.expectEqual(@as(u64, 0), snap_over.active_us);
    try std.testing.expectEqual(@as(u64, 0), snap_over.active_pct);

    // Zero wall (never advanced) reports 0 percent instead of dividing by zero.
    const fresh = WorkerStats{ .worker_id = 2, .start_us = 5_000 };
    try std.testing.expectEqual(@as(u64, 0), fresh.snapshot(5_000).active_pct);

    // A worker currently parked (wait_enter_us set) has its in-progress park counted as blocked, not
    // on-CPU: without this a dump taken while every worker idles (SIGTERM after the load stops) would
    // misreport the still-uncommitted parked time as active. Here committed block is 0 but the worker
    // entered the wait at 2_000 and it is now 11_000, so all 9_000us of wall is blocked, 0 active.
    const parked = WorkerStats{ .worker_id = 3, .start_us = 2_000, .block_us = 0, .wait_enter_us = 2_000 };
    const snap_parked = parked.snapshot(11_000);
    try std.testing.expectEqual(@as(u64, 9_000), snap_parked.wall_us);
    try std.testing.expectEqual(@as(u64, 0), snap_parked.active_us);
    try std.testing.expectEqual(@as(u64, 0), snap_parked.active_pct);
}

test "zix test: registerWorkerStats stamps a start time and adds the worker to the dump registry" {
    const before = g_diag_count.load(.acquire);

    var stats = WorkerStats{ .worker_id = 4242 };
    registerWorkerStats(&stats);

    // The worker now has a monotonic start time and is one more entry in the registry, so a later
    // signal-driven dump reaches it.
    try std.testing.expect(stats.start_us > 0);
    try std.testing.expectEqual(before + 1, g_diag_count.load(.acquire));
    try std.testing.expect(g_diag_stats[before].? == &stats);
}
