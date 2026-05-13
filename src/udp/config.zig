//! zix udp config

// --------------------------------------------------------- //

/// Port binding mode — governs how the port is sourced at init time.
/// Validation happens at init(), not at run(). Enforces "explicit over implicit."
pub const PortMode = enum(u8) {
    /// Port is read from CLI args (--port / --bind-port / --server-port) at runtime.
    /// Falls back to config.port default if the arg is absent — never fails for a missing arg.
    CONFIGURABLE,
    /// Port must be set explicitly and non-zero in the config struct.
    /// No CLI arg parsing. Fails at init() with error.PortNotConfigured if port is zero.
    REQUIRED,
};

// --------------------------------------------------------- //

/// Wire endianness applied transparently on every send and receive.
/// Set once in config — no manual conversion needed in user code.
/// Must match across all clients and the server for correct decoding.
pub const Endianness = enum(u8) {
    /// Same machine only — unsafe across platforms or languages.
    NATIVE,
    /// Recommended for cross-language clients (Go, C++, Rust) on modern hardware.
    LITTLE,
    /// Network byte order — use when interoperating with legacy or internet protocols.
    BIG,
};

// --------------------------------------------------------- //

pub const UdpServerConfig = struct {
    /// Backing allocator for client list and broadcast peer snapshots. Caller owns must outlive the server.
    /// NOTE: must be a general-purpose allocator (e.g. std.heap.smp_allocator).
    ///       ArenaAllocator is not suitable: broadcast peer snapshots are allocated and freed per
    ///       packet — ArenaAllocator.free() is a no-op, so each snapshot leaks until the server stops.
    allocator: std.mem.Allocator,
    /// Bind address.
    ip: []const u8,
    /// Bind port. Must be non-zero for REQUIRED. Used as fallback default for CONFIGURABLE.
    port: u16,
    /// How the port is sourced — REQUIRED (config struct) or CONFIGURABLE (CLI args with fallback).
    port_mode: PortMode = .REQUIRED,
    /// Wire endianness applied on every send and receive.
    endianness: Endianness = .LITTLE,
    /// Milliseconds of silence before a client is considered disconnected.
    disconnect_timeout_ms: i64 = 5000,
    /// Receive poll interval in milliseconds — controls disconnect check frequency.
    poll_timeout_ms: i64 = 2000,
    /// Send 0x06 ACK byte back to sender on successful packet receipt.
    auto_ack: bool = false,
    /// Send 0x15 NACK byte back to sender on malformed or oversized packet.
    error_report: bool = false,
    /// Echo the received packet back to the sender as-is.
    auto_echo: bool = false,
    /// Relay the received packet to all connected clients.
    broadcast: bool = false,
};

// --------------------------------------------------------- //

pub const UdpClientConfig = struct {
    /// Server address to send packets to.
    server_ip: []const u8,
    /// Server port. Must be non-zero for REQUIRED. Used as fallback default for CONFIGURABLE.
    server_port: u16,
    /// Local bind port — server uses this to send responses back.
    bind_port: u16,
    /// How the ports are sourced — REQUIRED (config struct) or CONFIGURABLE (CLI args with fallback).
    port_mode: PortMode = .REQUIRED,
    /// Wire endianness — must match the server's endianness config.
    endianness: Endianness = .LITTLE,
    /// If true: send one packet then exit.
    send_once: bool = false,
    /// Milliseconds between sends in the run loop.
    send_every: u64 = 99,
};

// --------------------------------------------------------- //

const std = @import("std");

// RFC 768: port 0 is reserved and must not be used for binding.
// init() enforces this — port 0 in config yields error.PortNotConfigured.
// These tests verify that defaults are safe and that enum representations are stable.

test "zix test: UdpServerConfig, default field values" {
    const cfg = UdpServerConfig{
        .allocator = std.testing.allocator,
        .ip = "127.0.0.1",
        .port = 9100,
    };
    try std.testing.expectEqual(std.testing.allocator.ptr, cfg.allocator.ptr);
    try std.testing.expectEqualStrings("127.0.0.1", cfg.ip);
    try std.testing.expectEqual(@as(u16, 9100), cfg.port);
    try std.testing.expectEqual(PortMode.REQUIRED, cfg.port_mode);
    try std.testing.expectEqual(Endianness.LITTLE, cfg.endianness);
    try std.testing.expectEqual(@as(i64, 5000), cfg.disconnect_timeout_ms);
    try std.testing.expectEqual(@as(i64, 2000), cfg.poll_timeout_ms);
    try std.testing.expect(!cfg.auto_ack);
    try std.testing.expect(!cfg.error_report);
    try std.testing.expect(!cfg.auto_echo);
    try std.testing.expect(!cfg.broadcast);
}

test "zix test: UdpClientConfig, default field values" {
    const cfg = UdpClientConfig{ .server_ip = "127.0.0.1", .server_port = 9100, .bind_port = 9101 };
    try std.testing.expectEqualStrings("127.0.0.1", cfg.server_ip);
    try std.testing.expectEqual(@as(u16, 9100), cfg.server_port);
    try std.testing.expectEqual(@as(u16, 9101), cfg.bind_port);
    try std.testing.expectEqual(PortMode.REQUIRED, cfg.port_mode);
    try std.testing.expectEqual(Endianness.LITTLE, cfg.endianness);
    try std.testing.expect(!cfg.send_once);
    try std.testing.expectEqual(@as(u64, 99), cfg.send_every);
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
