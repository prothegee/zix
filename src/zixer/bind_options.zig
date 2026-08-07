//! zixer bind options: what the daemon already settled before a site binds

const conn_buffer = @import("conn_buffer.zig");

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
pub const BindOptions = struct {
    kernel_backlog: u31 = 1024,
    workers: usize = 1,
    max_recv_buf: usize = conn_buffer.DEFAULT_BYTES,
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
