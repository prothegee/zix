//! ZIX Http1 Config
//!
//! ### file: src/zix/tcp/http1/Config.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Server configuration for one Http1 instance.
//! 
//! ### note:
//! 
//! n/a
//! 
//! ---------------------------------------------------------
//! 
//! ### licenses:
//! 
//! - BSD-3-Clause
//! 
//! ### copyright:
//! 
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//! 
//! ### contributors:
//! 
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const DispatchModel = @import("../../shared/dispatch.zig").Model;
const Logger = @import("../../logger/Logger.zig");

// --------------------------------------------------------- //
// Fields:

io: std.Io,
ip: []const u8,
port: u16,
// TODO: tls: ?Tls = null,
// TODO: tls_port: u16,
// TODO: tls_redirect: bool = false,
logger: ?*Logger = null,
dispatch_model: DispatchModel,
workers: usize = 0,
worker_stack_size_bytes: usize = 1 * 1024,
// worker_stack_compress_bytes: usize = 2 * 1024 * 1024,
compress_worker_stack_size_bytes: usize = 2 * 1024 * 1024,
kernel_backlog: u31 = 1 * 1024,
// Response cache sizing, applied when the cache is on.
max_entries: u32 = 256,
max_value_bytes: u32 = 16 * 1024,

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1: Config, applies defaults" {
    const config: @This() = .{
        .io = std.testing.io,
        .ip = "127.0.0.1",
        .port = 8080,
        .dispatch_model = .ASYNC,
    };

    try std.testing.expectEqual(@as(usize, 0), config.workers);
    try std.testing.expectEqual(@as(usize, 1024), config.worker_stack_size_bytes);
    try std.testing.expectEqual(@as(u31, 1024), config.kernel_backlog);
    try std.testing.expectEqual(@as(?*Logger, null), config.logger);
    try std.testing.expectEqual(
        @as(usize, 2 * 1024 * 1024),
        config.compress_worker_stack_size_bytes,
    );
}

test "zix http1: Config, keeps an explicit dispatch model" {
    const config: @This() = .{
        .io = std.testing.io,
        .ip = "0.0.0.0",
        .port = 1,
        .dispatch_model = .URING,
        .workers = 4,
    };

    try std.testing.expectEqual(DispatchModel.URING, config.dispatch_model);
    try std.testing.expectEqual(@as(usize, 4), config.workers);
}

