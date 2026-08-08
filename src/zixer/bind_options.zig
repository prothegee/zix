//! zixer bind options: what the daemon already settled before a site binds

const conn_buffer = @import("conn_buffer.zig");
const process_gate = @import("process_gate.zig");
const static_cached = @import("static_cached.zig");

/// The main.cfg values a site needs at bind time.
///
/// Note:
/// - workers is the resolved count, not the raw main.cfg value: the daemon
///   turns 0 into the thread count once, at start, see worker_count.zig.
/// - Only a serving tcp site spends workers. A bare bound listener has no
///   accept loop, and the quic edge and the udp forward each own one
///   socket whose connection state is keyed to it.
/// - max_recv_buf is the daemon default. A site file may name its own,
///   which is why the edge resolves the pair rather than reading this one
///   directly, see conn_buffer.resolve.
/// - The three process_ values are daemon defaults the same way, resolved
///   against the site file by process_gate.resolve. A limit of 0 is the
///   gate off, which is what a daemon that never asked for one carries.
/// - public_dir_cache_ttl_ms is a daemon default too, resolved against the
///   site file by static_cached.resolveTtl. The entry count has no site
///   override: the cache table is one per process, so only main.cfg sizes it.
pub const BindOptions = struct {
    kernel_backlog: u31 = 1024,
    workers: usize = 1,
    max_recv_buf: usize = conn_buffer.DEFAULT_BYTES,
    process_limit: usize = 0,
    process_queue_len: usize = 0,
    process_queue_timeout_ms: u32 = process_gate.DEFAULT_TIMEOUT_MS,
    public_dir_cache_ttl_ms: u32 = static_cached.DEFAULT_TTL_MS,
    public_dir_cache_max_entries: u32 = static_cached.DEFAULT_MAX_ENTRIES,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

const std = @import("std");

test "zix zixer: bind options, the defaults are one worker and the buffer default" {
    const options = BindOptions{};

    try std.testing.expectEqual(@as(u31, 1024), options.kernel_backlog);
    try std.testing.expectEqual(@as(usize, 1), options.workers);
    try std.testing.expectEqual(conn_buffer.DEFAULT_BYTES, options.max_recv_buf);
}

test "zix zixer: bind options, the daemon default stays inside the buffer range" {
    const options = BindOptions{};

    try std.testing.expect(conn_buffer.inRange(options.max_recv_buf));
}

test "zix zixer: bind options, the process gate defaults to off" {
    const options = BindOptions{};

    try std.testing.expectEqual(@as(usize, 0), options.process_limit);
    try std.testing.expectEqual(@as(usize, 0), options.process_queue_len);
    try std.testing.expectEqual(process_gate.DEFAULT_TIMEOUT_MS, options.process_queue_timeout_ms);

    const settings = process_gate.Settings{
        .limit = options.process_limit,
        .queue_len = options.process_queue_len,
        .timeout_ms = options.process_queue_timeout_ms,
    };
    try std.testing.expect(!settings.armed());
}

test "zix zixer: bind options, the static cache defaults to off with room reserved" {
    const options = BindOptions{};

    try std.testing.expectEqual(@as(u32, 0), options.public_dir_cache_ttl_ms);
    try std.testing.expectEqual(static_cached.DEFAULT_MAX_ENTRIES, options.public_dir_cache_max_entries);

    // A daemon that never asked for caching resolves every site to off.
    try std.testing.expectEqual(@as(u32, 0), static_cached.resolveTtl(null, options.public_dir_cache_ttl_ms));
}
