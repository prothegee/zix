//! zix http server config

const std = @import("std");
const HeaderSize = @import("response.zig").HeaderSize;
const RequestHeaderSize = @import("parser.zig").RequestHeaderSize;
const Logger = @import("../../logger/logger.zig").Logger;
pub const DispatchModel = @import("../config.zig").DispatchModel;

// --------------------------------------------------------- //

/// Configuration for an HTTP server instance.
/// Pass to Http.Server.init(). Fields without defaults (ip, port) are required.
pub const HttpServerConfig = struct {
    /// Optional caller-provided io backend. When non-null the server uses it directly
    /// (async_limit and stack_size in InitOptions are respected). When null the server
    /// creates an internal std.Io.Threaded with stack_size = 512KB.
    io: ?std.Io = null,
    /// Bind address.
    ip: []const u8,
    /// Bind port. Must be non-zero.
    port: u16,
    /// Connection dispatch model. Selects between POOL, ASYNC, and MIXED.
    /// Default: .ASYNC (single accept thread, io.async() per connection).
    dispatch_model: DispatchModel = .ASYNC,
    /// TCP listen backlog — maximum pending connections queued by the kernel before accept().
    max_kernel_backlog: usize = 1024 * 4,
    /// Read buffer size in bytes per request. Requests exceeding this are rejected with 431.
    max_client_request: usize = 1024 * 4,
    /// Initial arena capacity in bytes per connection. Grows automatically if exceeded.
    max_allocator_size: usize = 1024 * 4,
    /// Write buffer size in bytes per response.
    max_client_response: usize = 1024 * 4,
    /// Maximum request headers accepted per request. Requests exceeding this are rejected with 431.
    /// CUSTOM values above 64 are silently capped at the parser storage limit (64).
    /// See RequestHeaderSize for tier guidance.
    max_request_headers: RequestHeaderSize = .LARGE,
    /// Maximum custom response headers per request (default: .COMMON = 32).
    /// The backing buffer is arena-allocated per request to exactly this size.
    /// See docs/headers.md and zix.HeaderSize for tier guidance.
    max_response_headers: HeaderSize = .COMMON,
    /// Root directory for static file serving. Empty string disables static serving.
    public_dir: []const u8 = "",
    /// Upload subdirectory relative to public_dir. Receives multipart uploads.
    public_dir_upload: []const u8 = "u",
    /// Network-level connection guard (Layer D: ConnRegistry eviction).
    /// 0 = disabled. When non-zero, connections exceeding this lifetime are shut down
    /// by the background timer thread.
    /// Should be >= handler_timeout_ms to avoid cutting off an in-flight response.
    conn_timeout_ms: u32 = 0,
    /// Per-handler execution budget (Layer B: ctx.isExpired / ctx.timedOut).
    /// 0 = disabled. When non-zero, ctx.deadline is set before each handler dispatch.
    /// Handlers opt in by checking ctx.isExpired() between expensive steps.
    handler_timeout_ms: u32 = 0,
    /// Number of accept threads.
    /// 0 (default) = cpu_count accept threads.
    /// N           = exactly N accept threads.
    /// Ignored by .ASYNC (always 1 accept thread).
    workers: usize = 0,
    /// Number of pool threads. Only used by .POOL dispatch model.
    /// 0 (default) = max(10, cpu_count * 2) — minimum 10, scales with core count.
    /// N           = exactly N pool threads.
    /// Ignored by .ASYNC and .MIXED.
    pool_size: usize = 0,
    /// Optional logger. When non-null, the server calls logger.access() after each
    /// response and injects a pointer into ctx.logger for handler use.
    /// Caller owns the Logger and must ensure it outlives the server.
    logger: ?*Logger = null,
};
