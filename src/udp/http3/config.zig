//! zix HTTP/3 server config.
//!
//! What:
//! - `Http3ServerConfig`: the UDP substrate knobs restated flat (ADR-049 / ADR-050 contract) plus the
//!   QUIC and HTTP/3 knobs. The TLS context is the sanctioned by-pointer exception (the caller owns it
//!   and it must outlive the server).

const std = @import("std");

const Logger = @import("../../logger/logger.zig").Logger;
const Tls = @import("../../tls/Tls.zig");

/// The dispatch model, shared with the TCP engines and the UDP raw path (ADR-050). `.ASYNC` runs a
/// single-worker recv with internal CID demux. `.POOL` / `.MIXED` / `.EPOLL` / `.URING` run one
/// SO_REUSEPORT worker per core, the kernel load-balancing connections by 4-tuple.
pub const DispatchModel = @import("../../tcp/config.zig").DispatchModel;

pub const Http3ServerConfig = struct {
    /// Io backend for the server. Caller-provided, must outlive the server.
    io: std.Io,
    /// Backing allocator. Must be a general-purpose allocator (e.g. std.heap.smp_allocator).
    allocator: std.mem.Allocator,
    /// Bind address.
    ip: []const u8,
    /// Bind port. Must be non-zero.
    port: u16,

    // UDP substrate knobs (ADR-049), restated flat. Used by the recv path.

    /// Concurrency model. ASYNC runs a single worker. POOL / MIXED / EPOLL / URING run one
    /// SO_REUSEPORT worker per core (multicore), the kernel load-balancing by 4-tuple.
    /// Required: the caller must set it explicitly (no default).
    dispatch_model: DispatchModel,
    /// Worker count for the per-core models (EPOLL / URING). 0 means one per available CPU.
    workers: usize = 0,
    /// Worker thread stack size in bytes for the per-core workers (EPOLL / URING). Thread stacks are
    /// demand-paged, so this costs little RSS until the depth is used.
    worker_stack_size_bytes: usize = 512 * 1024,
    /// SO_BUSY_POLL spin window in microseconds for the per-core UDP socket (EPOLL / URING): the
    /// kernel busy-spins this long before sleeping the worker, trading CPU for lower recvmmsg wake-up
    /// latency. Default 0 leaves it unset. No-op when the kernel lacks SO_BUSY_POLL.
    busy_poll_us: u32 = 0,
    /// Attach SO_ATTACH_REUSEPORT_CBPF steering (.EPOLL / .URING): socket index = receiving CPU mod
    /// workers per packet instead of the 4-tuple hash. Warning: keep it false on QUIC, per-packet
    /// steering breaks flow affinity (throughput drops, requests still succeed). Pre-4.5 kernel = silent no-op.
    reuseport_cbpf: bool = false,
    /// recvmmsg batch size: datagrams received per syscall.
    recv_batch: usize = 32,
    /// sendmmsg batch size: packets coalesced per flush.
    send_batch: usize = 32,
    /// Maximum datagram size, the receive buffer per slot. 1500 is the common Ethernet MTU.
    max_recv_buf: usize = 1500,
    /// Requested SO_RCVBUF in bytes per per-core UDP socket. The kernel buffer must hold the burst
    /// arriving between recvmmsg batches, a small buffer drops the overflow (loss and retransmits).
    /// Silently capped at net.core.rmem_max. 0 keeps the kernel default. 4 MiB is a broad QUIC default.
    socket_rcvbuf: usize = 4 * 1024 * 1024,
    /// Requested SO_SNDBUF in bytes for each per-core UDP socket. Sized so a coalesced GSO send flight
    /// is never throttled by a small send buffer. Capped at net.core.wmem_max. 0 leaves the default.
    socket_sndbuf: usize = 4 * 1024 * 1024,
    /// Enable UDP GSO (UDP_SEGMENT) on the send path: a multi-packet response flight to one peer is
    /// coalesced into one sendmsg and segmented by the kernel. Default true: HTTP/3 is syscall-bound
    /// and response flights are multi-packet. Probed at worker start, falls back to sendmmsg pre-4.18.
    gso_enabled: bool = true,

    // QUIC / HTTP-3 knobs.

    /// The server-issued connection ID length in bytes (RFC 9000 5.1). A fixed length enables the
    /// future per-core CID steering (ADR-049 phase 3).
    cid_len: u8 = 8,
    /// Idle timeout in milliseconds (RFC 9000 10.1).
    max_idle_ms: u32 = 30000,
    /// Maximum concurrent request streams (RFC 9000 4.6).
    max_streams: u32 = 128,
    /// Target wire size in bytes for a 1-RTT datagram: larger = fewer packets for a big response
    /// (less header / AEAD / ACK work), also the congestion-window basis. Effective = min(this, the
    /// client's max_udp_payload_size, 16 KiB). Default 1200 (QUIC minimum) is path-safe, raise on known-large MTU.
    max_datagram_size: u64 = 1200,
    /// Explicit cap on STREAM-frame payload bytes per 1-RTT packet. 0 (default) derives it from the
    /// datagram size (minus frame and tag room), so raising max_datagram_size alone widens packets.
    /// Set non-zero only to cap the payload below what the datagram size allows.
    max_stream_chunk: usize = 0,
    /// Response packets a connection keeps in flight before waiting for ACKs: the congestion-window
    /// ceiling (RFC 9002) and loss-detection ring depth. Larger = fewer ACK-clocked rounds for a big
    /// response at more bookkeeping (128 at 1200 = ~153 KiB). Clamped to the ring cap (max_sent_ranges).
    max_inflight_packets: usize = 128,
    /// Initial congestion window in packets, the first flight before any ACK (RFC 9002 7.2, RFC
    /// default 10). Default 32 (~38 KiB at 1200) cuts ACK-clocked rounds. Raise to cover a whole
    /// response on a trusted path, keep modest on a lossy one. Burst = min(this, max_inflight, ring cap).
    initial_window_packets: usize = 32,
    /// TLS 1.3 context: cert / key / ALPN. QUIC requires TLS 1.3. Caller owns, must outlive the
    /// server. Null is rejected at run (QUIC has no cleartext mode).
    tls: ?*Tls.Context = null,
    /// Optional logger. When non-null, the server calls logger.system() for lifecycle events.
    logger: ?*Logger = null,
};

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

test "zix http3: Http3ServerConfig default field values" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cfg = Http3ServerConfig{
        .io = threaded.io(),
        .allocator = std.testing.allocator,
        .ip = "127.0.0.1",
        .port = 9063,
        .dispatch_model = .ASYNC,
    };
    try std.testing.expectEqual(DispatchModel.ASYNC, cfg.dispatch_model);
    try std.testing.expectEqual(@as(usize, 32), cfg.recv_batch);
    try std.testing.expectEqual(@as(usize, 1500), cfg.max_recv_buf);
    try std.testing.expectEqual(@as(u32, 0), cfg.busy_poll_us);
    try std.testing.expect(!cfg.reuseport_cbpf);
    try std.testing.expectEqual(@as(usize, 512 * 1024), cfg.worker_stack_size_bytes);
    try std.testing.expect(cfg.gso_enabled); // default on: GSO is a broad HTTP/3 win
    try std.testing.expectEqual(@as(usize, 4 * 1024 * 1024), cfg.socket_rcvbuf);
    try std.testing.expectEqual(@as(usize, 4 * 1024 * 1024), cfg.socket_sndbuf);
    try std.testing.expectEqual(@as(u8, 8), cfg.cid_len);
    try std.testing.expectEqual(@as(u32, 30000), cfg.max_idle_ms);
    try std.testing.expectEqual(@as(u32, 128), cfg.max_streams);
    try std.testing.expectEqual(@as(u64, 1200), cfg.max_datagram_size);
    try std.testing.expectEqual(@as(usize, 0), cfg.max_stream_chunk);
    try std.testing.expectEqual(@as(usize, 128), cfg.max_inflight_packets);
    try std.testing.expectEqual(@as(usize, 32), cfg.initial_window_packets);
    try std.testing.expect(cfg.tls == null);
}
