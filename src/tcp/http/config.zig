//! zix http server config

const std = @import("std");
const HeaderSize = @import("response.zig").HeaderSize;

// --------------------------------------------------------- //

/// Configuration for an HTTP server instance.
/// Pass to Http.Server.init(). Fields without defaults (io, allocator, ip, port) are required.
pub const HttpServerConfig = struct {
    /// Event-loop backend. Caller owns and must not deinit while the server is running.
    io: std.Io,
    /// Backing allocator for router storage. Caller owns; must outlive the server.
    /// NOTE: ArenaAllocator is suitable here — routes are append-only and never individually freed.
    ///       The entire arena is deinited together with server.deinit(), freeing all routes in one shot.
    allocator: std.mem.Allocator,
    /// Bind address.
    ip: []const u8,
    /// Bind port. Must be non-zero.
    port: u16,
    /// TCP listen backlog — maximum pending connections queued by the kernel before accept().
    max_kernel_backlog: usize = 1024 * 4,
    /// Read buffer size in bytes per request. Requests exceeding this are rejected.
    max_client_request: usize = 1024 * 4,
    /// Initial arena capacity in bytes per connection. Grows automatically if exceeded.
    max_allocator_size: usize = 1024 * 4,
    /// Write buffer size in bytes per response.
    max_client_response: usize = 1024 * 4,
    /// Maximum custom response headers per request (default: .COMMON = 32).
    /// The backing buffer is arena-allocated per request to exactly this size.
    /// See docs/headers.md and zix.HeaderSize for tier guidance.
    max_response_headers: HeaderSize = .COMMON,
    /// Root directory for static file serving. Empty string disables static serving.
    public_dir: []const u8 = "",
    /// Upload subdirectory relative to public_dir. Receives multipart uploads.
    public_dir_upload: []const u8 = "u",
    /// Milliseconds before an idle or unresponsive connection is closed.
    response_timeout_ms: u32 = 30_000,
    /// Number of accept threads (model 2 only).
    /// 0 (default) = 2 accept threads — enough to saturate the kernel accept queue.
    /// 1           = single-threaded mode, uses the caller's io directly (model 1).
    /// N           = exactly N accept threads.
    workers: usize = 0,
    /// Number of pool threads (model 2 only).
    /// 0 (default) = max(10, cpu_count * 2) — mirrors khttp's thread-pool sizing.
    /// N           = exactly N pool threads.
    pool_size: usize = 0,
};

// --------------------------------------------------------- //
