//! zix http server config

const std = @import("std");
const HeaderSize = @import("response.zig").HeaderSize;

pub const HttpServerConfig = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    ip: []const u8,
    port: u16,
    max_kernel_backlog: usize = 1024 * 4,
    max_client_request: usize = 1024 * 4,
    max_allocator_size: usize = 1024 * 4,
    max_client_response: usize = 1024 * 4,
    /// Maximum custom response headers per request (default: .COMMON = 32).
    /// The backing buffer is arena-allocated per request to exactly this size.
    /// See docs/headers.md and zix.HeaderSize for tier guidance.
    max_response_headers: HeaderSize = .COMMON,
    public_dir: []const u8 = "",
    public_dir_upload: []const u8 = "u",
    response_timeout_ms: u32 = 30_000,
};
