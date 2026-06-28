//! zix udp config

const std = @import("std");

// --------------------------------------------------------- //

const Logger = @import("../logger/logger.zig").Logger;

/// The dispatch model, shared with the TCP engines (`src/tcp/config.zig`). Reused so the UDP engine
/// names concurrency the same way the rest of the family does.
pub const DispatchModel = @import("../tcp/config.zig").DispatchModel;

/// Port binding mode: governs how the port is sourced at init time.
/// Validation happens at init(), not at run(). Enforces "explicit over implicit."
pub const PortMode = enum(u8) {
    /// Port is read from CLI args (--port / --bind-port / --server-port) at runtime.
    /// Falls back to config.port default if the arg is absent, never fails for a missing arg.
    CONFIGURABLE,
    /// Port must be set explicitly and non-zero in the config struct.
    /// No CLI arg parsing. Fails at init() with error.PortNotConfigured if port is zero.
    REQUIRED,
};

// --------------------------------------------------------- //

/// Wire endianness applied transparently on every send and receive.
/// Set once in config, no manual conversion needed in user code.
/// Must match across all clients and the server for correct decoding.
pub const Endianness = enum(u8) {
    /// Same machine only, unsafe across platforms or languages.
    NATIVE,
    /// Recommended for cross-language clients (Go, C++, Rust) on modern hardware.
    LITTLE,
    /// Network byte order, use when interoperating with legacy or internet protocols.
    BIG,
};

// --------------------------------------------------------- //

pub const UdpServerConfig = struct {
    /// Io backend for the server. Caller-provided. Must outlive the server.
    io: std.Io,
    /// Backing allocator. Typed path: the client list and broadcast peer snapshots. Raw path
    /// (`zix.Udp.Raw`): the recv / send batches and the worker-thread array. Caller owns, must
    /// outlive the server.
    /// Note:
    /// - must be a general-purpose allocator (e.g. std.heap.smp_allocator).
    ///   ArenaAllocator is not suitable: broadcast peer snapshots are allocated and freed per
    ///   packet, ArenaAllocator.free() is a no-op, so each snapshot leaks until the server stops.
    allocator: std.mem.Allocator,
    /// Bind address.
    ip: []const u8,
    /// Bind port. Must be non-zero for REQUIRED. Used as fallback default for CONFIGURABLE.
    port: u16,
    /// How the port is sourced: REQUIRED (config struct) or CONFIGURABLE (CLI args with fallback).
    port_mode: PortMode = .REQUIRED,
    /// Wire endianness applied on every send and receive.
    endianness: Endianness = .LITTLE,
    /// Milliseconds of silence before a client is considered disconnected (idle connection timeout).
    conn_timeout_ms: i64 = 5000,
    /// Receive poll interval in milliseconds, controls disconnect check frequency.
    poll_timeout_ms: i64 = 2000,
    /// Send 0x06 ACK byte back to sender on successful packet receipt.
    auto_ack: bool = false,
    /// Send 0x15 NACK byte back to sender on malformed or oversized packet.
    error_report: bool = false,
    /// Echo the received packet back to the sender as-is.
    auto_echo: bool = false,
    /// Relay the received packet to all connected clients.
    broadcast: bool = false,
    /// Optional logger. When non-null, the server calls logger.system() for lifecycle events
    /// and logger.packet() for each received datagram. Caller owns. Must outlive the server.
    logger: ?*Logger = null,

    // Datagram-transport knobs (ADR-049), used by the raw-bytes path (`zix.Udp.Raw`). The typed
    // messaging path runs a single async receive loop: it folds a non-ASYNC `dispatch_model` with a
    // notice and does not use the batch / worker knobs.

    /// Concurrency model for the raw path. `.EPOLL` / `.URING` run per-core SO_REUSEPORT workers
    /// (the recvmmsg loop). `.ASYNC` / `.POOL` / `.MIXED` run a single worker. URING currently folds
    /// to the recvmmsg loop (true io_uring submission is a later phase). Same enum as the TCP engines.
    /// Required: the caller must set it explicitly (no default).
    dispatch_model: DispatchModel,
    /// Worker count for the per-core models. 0 means one per available CPU.
    workers: usize = 0,
    /// Set SO_REUSEADDR + SO_REUSEPORT so multiple workers can bind the same port and the kernel
    /// load-balances datagrams across them.
    reuse_address: bool = false,
    /// recvmmsg batch size: datagrams received per syscall on the raw path.
    recv_batch: usize = 32,
    /// sendmmsg batch size: replies coalesced per flush on the raw path.
    send_batch: usize = 32,
    /// Maximum datagram size for the raw path, the receive buffer per slot. The typed path uses
    /// `@sizeOf(Packet)` instead. 1500 is the common Ethernet MTU.
    max_recv_buf: usize = 1500,
    /// SO_BUSY_POLL spin window in microseconds for the raw path's UDP socket (.EPOLL / .URING
    /// per-core workers). The kernel busy-spins this long before sleeping the worker, trading CPU for
    /// lower recvmmsg wake-up latency on saturated benchmarks. Default 0 leaves it unset, so the
    /// current CPU profile is unchanged. Mirrors zix.Http1's busy_poll_us. No-op when the kernel
    /// lacks SO_BUSY_POLL.
    busy_poll_us: u32 = 0,
    /// Worker thread stack size in bytes for the per-core raw workers (.EPOLL / .URING). Thread
    /// stacks are demand-paged, so this costs little RSS until the depth is used.
    worker_stack_size_bytes: usize = 512 * 1024,
    /// Enable UDP GSO (UDP_SEGMENT) on the send path: consecutive same-destination replies in a flush
    /// are coalesced into one sendmsg per group, so the kernel segments them into wire datagrams from
    /// one syscall. Default false, so the send path is the plain sendmmsg. Probed at worker start and
    /// left off when the kernel (older than 4.18) lacks support. Helps multi-packet same-peer bursts;
    /// a one-datagram-per-peer batch sees no benefit.
    gso_enabled: bool = false,
};

// --------------------------------------------------------- //

pub const UdpClientConfig = struct {
    /// Server address to send packets to.
    ip: []const u8,
    /// Server port. Must be non-zero for REQUIRED. Used as fallback default for CONFIGURABLE.
    server_port: u16,
    /// Local bind address. Defaults to loopback. Set to "0.0.0.0" to accept responses on all interfaces.
    bind_ip: []const u8 = "127.0.0.1",
    /// Local bind port, server uses this to send responses back.
    bind_port: u16,
    /// How the ports are sourced: REQUIRED (config struct) or CONFIGURABLE (CLI args with fallback).
    port_mode: PortMode = .REQUIRED,
    /// Wire endianness, must match the server's endianness config.
    endianness: Endianness = .LITTLE,
    /// If true: send one packet then exit.
    send_once: bool = false,
    /// Milliseconds between sends in the run loop.
    send_every: u64 = 99,
    /// Socket receive timeout in milliseconds (SO_RCVTIMEO). 0 = disabled.
    recv_timeout_ms: u32 = 0,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

// RFC 768: port 0 is reserved and must not be used for binding.
// init() enforces this, port 0 in config yields error.PortNotConfigured.
// These tests verify that defaults are safe and that enum representations are stable.

test "zix test: UdpServerConfig, default field values" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cfg = UdpServerConfig{
        .io = threaded.io(),
        .allocator = std.testing.allocator,
        .ip = "127.0.0.1",
        .port = 9100,
        .dispatch_model = .ASYNC,
    };
    try std.testing.expectEqual(std.testing.allocator.ptr, cfg.allocator.ptr);
    try std.testing.expectEqualStrings("127.0.0.1", cfg.ip);
    try std.testing.expectEqual(@as(u16, 9100), cfg.port);
    try std.testing.expectEqual(PortMode.REQUIRED, cfg.port_mode);
    try std.testing.expectEqual(Endianness.LITTLE, cfg.endianness);
    try std.testing.expectEqual(@as(i64, 5000), cfg.conn_timeout_ms);
    try std.testing.expectEqual(@as(i64, 2000), cfg.poll_timeout_ms);
    try std.testing.expect(!cfg.auto_ack);
    try std.testing.expect(!cfg.error_report);
    try std.testing.expect(!cfg.auto_echo);
    try std.testing.expect(!cfg.broadcast);
}

test "zix test: UdpServerConfig, datagram-transport defaults (ADR-049)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const cfg = UdpServerConfig{
        .io = threaded.io(),
        .allocator = std.testing.allocator,
        .ip = "127.0.0.1",
        .port = 9100,
        .dispatch_model = .ASYNC,
    };
    try std.testing.expectEqual(DispatchModel.ASYNC, cfg.dispatch_model);
    try std.testing.expectEqual(@as(usize, 0), cfg.workers);
    try std.testing.expect(!cfg.reuse_address);
    try std.testing.expectEqual(@as(usize, 32), cfg.recv_batch);
    try std.testing.expectEqual(@as(usize, 32), cfg.send_batch);
    try std.testing.expectEqual(@as(usize, 1500), cfg.max_recv_buf);
    try std.testing.expectEqual(@as(u32, 0), cfg.busy_poll_us);
    try std.testing.expectEqual(@as(usize, 512 * 1024), cfg.worker_stack_size_bytes);
}

test "zix test: UdpClientConfig, default field values" {
    const cfg = UdpClientConfig{ .ip = "127.0.0.1", .server_port = 9100, .bind_port = 9101 };
    try std.testing.expectEqualStrings("127.0.0.1", cfg.ip);
    try std.testing.expectEqual(@as(u16, 9100), cfg.server_port);
    try std.testing.expectEqualStrings("127.0.0.1", cfg.bind_ip);
    try std.testing.expectEqual(@as(u16, 9101), cfg.bind_port);
    try std.testing.expectEqual(PortMode.REQUIRED, cfg.port_mode);
    try std.testing.expectEqual(Endianness.LITTLE, cfg.endianness);
    try std.testing.expect(!cfg.send_once);
    try std.testing.expectEqual(@as(u64, 99), cfg.send_every);
    try std.testing.expectEqual(@as(u32, 0), cfg.recv_timeout_ms);
}

test "zix test: PortMode, enum backing values are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(PortMode.CONFIGURABLE));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(PortMode.REQUIRED));
}

test "zix test: Endianness enum backing values are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Endianness.NATIVE));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Endianness.LITTLE));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(Endianness.BIG));
}
