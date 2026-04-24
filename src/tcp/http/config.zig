//! zix http server config

const std = @import("std");

pub const HttpServerConfig = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    ip: []const u8,
    port: u16,
    max_kernel_backlog: usize = 1024 * 4,
    max_client_request: usize = 1024 * 4,
    max_allocator_size: usize = 1024 * 4,
    max_client_response: usize = 1024 * 4,
    public_dir: []const u8 = "",
    public_dir_upload: []const u8 = "u",
    response_timeout_ms: u32 = 30_000,
};
