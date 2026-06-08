//! zix http1 server configuration

const DispatchModel = @import("../config.zig").DispatchModel;

/// HTTP/1 server configuration.
pub const Http1ServerConfig = struct {
    /// std.Io handle from process.io.
    io: @import("std").Io,
    /// Bind address.
    ip: []const u8,
    /// Bind port. Must be non-zero.
    port: u16,
    /// Connection dispatch model. Default: .ASYNC.
    dispatch_model: DispatchModel = .ASYNC,
    /// TCP listen backlog.
    kernel_backlog: u31 = 1024,
    /// Max bytes to buffer per request header block.
    max_recv_buf: usize = 16 * 1024,
    /// Max output size for gzip-compressed responses.
    max_gzip_out: usize = 256 * 1024,
    /// Accept thread count (0 = cpu_count). Ignored by .ASYNC.
    workers: usize = 0,
    /// Pool thread count (0 = max(10, cpu_count * 2)). Used by .POOL only.
    pool_size: usize = 0,
};
