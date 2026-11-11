//! ZIX Http2 Grpc proto wire_type
//!
//! ### file: src/zix/tcp/http2/grpc/proto/wire_type.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Protobuf wire type ids, the low 3 bits of every field tag.
//!
//! ### note:
//!
//! Only these 4 are supported. Group types 3 and 4 are deprecated and rejected by the reader.
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
// Public:

/// Varint value (int32, int64, uint, bool, enum).
pub const WT_VARINT: u3 = 0;

/// Fixed 8 bytes, little-endian (double, fixed64).
pub const WT_I64: u3 = 1;

/// Length-prefixed bytes (string, bytes, nested message).
pub const WT_LEN: u3 = 2;

/// Fixed 4 bytes, little-endian (float, fixed32).
pub const WT_I32: u3 = 5;

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 grpc proto: wire_type, ids match the protobuf encoding" {
    try std.testing.expectEqual(@as(u3, 0), WT_VARINT);
    try std.testing.expectEqual(@as(u3, 1), WT_I64);
    try std.testing.expectEqual(@as(u3, 2), WT_LEN);
    try std.testing.expectEqual(@as(u3, 5), WT_I32);
}

