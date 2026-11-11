//! ZIX Http2 Grpc frame GrpcPrefix
//!
//! ### file: src/zix/tcp/http2/grpc/frame/GrpcPrefix.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The 5-byte gRPC message prefix: compress flag plus message length.
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

// --------------------------------------------------------- //
// Fields:

/// True when the message payload is compressed (wire flag 1).
compress: bool,
/// Message payload length in octets, the prefix itself not included.
msg_len: u32,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 grpc frame: GrpcPrefix, keeps its fields" {
    const prefix: Self = .{
        .compress = true,
        .msg_len = 42,
    };

    try std.testing.expect(prefix.compress);
    try std.testing.expectEqual(@as(u32, 42), prefix.msg_len);
}

test "zix http2 grpc frame: GrpcPrefix, holds the largest message length" {
    const prefix: Self = .{
        .compress = false,
        .msg_len = std.math.maxInt(u32),
    };

    try std.testing.expect(!prefix.compress);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), prefix.msg_len);
}

