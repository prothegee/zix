//! ZIX Http1 compress
//!
//! ### file: src/zix/tcp/http1/compress.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Per-worker compression policy: on or off, size floor, output cap.
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
const Config = @import("Config.zig");
const policy = @import("../../utils/compression/policy.zig");

// --------------------------------------------------------- //
// Private:

/// Default cap on one compressed response.
const GZIP_OUT_SIZE: usize = 256 * 1024;

// --------------------------------------------------------- //
// Public:

/// Whether response compression is enabled for this worker. Off unless the
/// server installs it from config.compress.
pub threadlocal var tl_compression: bool = false;

/// Body size floor for compression, installed from
/// config.compression_min_size.
pub threadlocal var tl_compression_min_size: usize = policy.MIN_SIZE_DEFAULT;

/// Compressed-output cap, installed from config.compression_max_out. A
/// compressed result above this is discarded and the response is sent
/// uncompressed.
pub threadlocal var tl_compression_max_out: usize = GZIP_OUT_SIZE;

/// Install the compression policy for this worker. Called once per worker at
/// startup.
///
/// Param:
/// enabled - bool (compress responses at all)
/// min_size - usize (body size floor)
/// max_out - usize (compressed-output cap)
pub fn setCompression(enabled: bool, min_size: usize, max_out: usize) void {
    tl_compression = enabled;
    tl_compression_min_size = min_size;
    tl_compression_max_out = max_out;
}

/// Install the compression policy for this worker from the server config.
///
/// Note:
/// - Runs once per worker at start, never per request.
///
/// Param:
/// config - Config (compress, compression_min_size, compression_max_out)
pub fn installWorker(config: Config) void {
    setCompression(config.compress, config.compression_min_size, config.compression_max_out);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http1: compress, installs the policy" {
    setCompression(true, 128, 4096);
    defer setCompression(false, policy.MIN_SIZE_DEFAULT, GZIP_OUT_SIZE);

    try std.testing.expect(tl_compression);
    try std.testing.expectEqual(@as(usize, 128), tl_compression_min_size);
    try std.testing.expectEqual(@as(usize, 4096), tl_compression_max_out);
}

test "zix http1: compress, turns off with zero bounds" {
    setCompression(true, 128, 4096);
    defer setCompression(false, policy.MIN_SIZE_DEFAULT, GZIP_OUT_SIZE);

    setCompression(false, 0, 0);

    try std.testing.expect(!tl_compression);
    try std.testing.expectEqual(@as(usize, 0), tl_compression_min_size);
    try std.testing.expectEqual(@as(usize, 0), tl_compression_max_out);
}

test "zix http1: compress, installWorker copies the config knobs" {
    defer setCompression(false, policy.MIN_SIZE_DEFAULT, GZIP_OUT_SIZE);

    installWorker(.{
        .io = std.testing.io,
        .ip = "127.0.0.1",
        .port = 0,
        .dispatch_model = .ASYNC,
        .compress = true,
        .compression_min_size = 512,
        .compression_max_out = 2048,
    });

    try std.testing.expect(tl_compression);
    try std.testing.expectEqual(@as(usize, 512), tl_compression_min_size);
    try std.testing.expectEqual(@as(usize, 2048), tl_compression_max_out);
}

test "zix http1: compress, installWorker keeps compression off by default" {
    setCompression(true, 1, 1);
    defer setCompression(false, policy.MIN_SIZE_DEFAULT, GZIP_OUT_SIZE);

    installWorker(.{
        .io = std.testing.io,
        .ip = "127.0.0.1",
        .port = 0,
        .dispatch_model = .ASYNC,
    });

    try std.testing.expect(!tl_compression);
    try std.testing.expectEqual(policy.MIN_SIZE_DEFAULT, tl_compression_min_size);
}

