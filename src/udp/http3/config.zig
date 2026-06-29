//! zix HTTP/3 server config.
//!
//! What:
//! - `Http3ServerConfig`: the UDP substrate knobs restated flat (ADR-049 / ADR-050 contract) plus the
//!   QUIC and HTTP/3 knobs. The TLS context is the sanctioned by-pointer exception (the caller owns it
//!   and it must outlive the server).

const std = @import("std");

const Logger = @import("../../logger/logger.zig").Logger;
const Tls = @import("../../tls/Tls.zig");

/// The dispatch model, shared with the TCP engines and the UDP raw path (ADR-050). For HTTP/3,
/// `.ASYNC` / `.POOL` / `.MIXED` run a single-worker recv with internal CID demux, and `.EPOLL` /
/// `.URING` run one SO_REUSEPORT worker per core, the kernel load-balancing connections by 4-tuple.
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

    /// Concurrency model. ASYNC / POOL / MIXED run a single worker, EPOLL / URING run one
    /// SO_REUSEPORT worker per core (RC3 multicore), the kernel load-balancing by 4-tuple.
    /// Required: the caller must set it explicitly (no default).
    dispatch_model: DispatchModel,
    /// Worker count for the per-core models (EPOLL / URING). 0 means one per available CPU.
    workers: usize = 0,
    /// recvmmsg batch size: datagrams received per syscall.
    recv_batch: usize = 32,
    /// sendmmsg batch size: packets coalesced per flush.
    send_batch: usize = 32,
    /// Maximum datagram size, the receive buffer per slot. 1500 is the common Ethernet MTU.
    max_recv_buf: usize = 1500,
    /// SO_BUSY_POLL spin window in microseconds for the per-core UDP socket (EPOLL / URING). The
    /// kernel busy-spins this long before sleeping the worker, trading CPU for lower recvmmsg wake-up
    /// latency on saturated benchmarks. Default 0 leaves it unset, so the current CPU profile is
    /// unchanged. Mirrors zix.Http1's busy_poll_us. No-op when the kernel lacks SO_BUSY_POLL.
    busy_poll_us: u32 = 0,
    /// Worker thread stack size in bytes for the per-core workers (EPOLL / URING). Thread stacks are
    /// demand-paged, so this costs little RSS until the depth is used.
    worker_stack_size_bytes: usize = 512 * 1024,
    /// Requested SO_RCVBUF in bytes for each per-core UDP socket. A worker drains datagrams in recvmmsg
    /// batches, so the kernel buffer must hold a burst arriving between batches: a small buffer drops
    /// the overflow, which surfaces as loss and retransmits on a syscall-bound run. The kernel caps the
    /// request at net.core.rmem_max (silently), so an oversized value is clamped, never an error. 0
    /// leaves the kernel default. 4 MiB is a broad QUIC default that sits under typical rmem_max.
    socket_rcvbuf: usize = 4 * 1024 * 1024,
    /// Requested SO_SNDBUF in bytes for each per-core UDP socket. Sized so a coalesced GSO send flight
    /// is never throttled by a small send buffer. Capped at net.core.wmem_max. 0 leaves the default.
    socket_sndbuf: usize = 4 * 1024 * 1024,
    /// Enable UDP GSO (UDP_SEGMENT) on the send path: a multi-packet response flight to one peer is
    /// coalesced into one sendmsg, so the kernel segments it into wire datagrams from one syscall.
    /// Default true: HTTP/3 is syscall-bound on the send path and a response flight is multi-packet,
    /// so GSO is a broad win (static-h3 throughput up, baseline-h3 CPU down). Probed at worker start
    /// and disabled automatically on kernels older than 4.18, falling back to the plain sendmmsg path.
    gso_enabled: bool = true,

    // QUIC / HTTP-3 knobs.

    /// TLS 1.3 context: cert / key / ALPN. QUIC requires TLS 1.3. Caller owns, must outlive the
    /// server. Null is rejected at init (QUIC has no cleartext mode).
    tls: ?*Tls.Context = null,
    /// The server-issued connection ID length in bytes (RFC 9000 5.1). A fixed length enables the
    /// future per-core CID steering (ADR-049 phase 3).
    cid_len: u8 = 8,
    /// Idle timeout in milliseconds (RFC 9000 10.1).
    max_idle_ms: u32 = 30000,
    /// Maximum concurrent request streams (RFC 9000 4.6).
    max_streams: u32 = 128,
    /// Datagram size in bytes used for new connections (the initial congestion-window basis, RFC 9000).
    /// 1200 is the QUIC minimum. Keep at or below the path MTU to avoid fragmentation.
    max_datagram_size: u64 = 1200,
    /// Max STREAM-frame payload bytes per 1-RTT packet. Tie to max_datagram_size.
    max_stream_chunk: usize = 1200,
    /// Whether to forbid connection migration (RFC 9000 transport parameter disable_active_migration).
    disable_active_migration: bool = false,

    /// Optional logger. When non-null, the server calls logger.system() for lifecycle events.
    logger: ?*Logger = null,
};

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

test "zix test: Http3ServerConfig default field values" {
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
    try std.testing.expectEqual(@as(usize, 512 * 1024), cfg.worker_stack_size_bytes);
    try std.testing.expect(cfg.gso_enabled); // default on: GSO is a broad HTTP/3 win
    try std.testing.expectEqual(@as(usize, 4 * 1024 * 1024), cfg.socket_rcvbuf);
    try std.testing.expectEqual(@as(usize, 4 * 1024 * 1024), cfg.socket_sndbuf);
    try std.testing.expectEqual(@as(u8, 8), cfg.cid_len);
    try std.testing.expectEqual(@as(u32, 30000), cfg.max_idle_ms);
    try std.testing.expectEqual(@as(u32, 128), cfg.max_streams);
    try std.testing.expectEqual(@as(u64, 1200), cfg.max_datagram_size);
    try std.testing.expectEqual(@as(usize, 1200), cfg.max_stream_chunk);
    try std.testing.expect(cfg.tls == null);
}
