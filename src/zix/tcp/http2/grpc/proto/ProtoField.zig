//! ZIX Http2 Grpc proto ProtoField
//!
//! ### file: src/zix/tcp/http2/grpc/proto/ProtoField.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One protobuf field read from a message: its number, wire type, and value.
//!
//! ### note:
//!
//! WT_VARINT puts the value in value_u64 with an empty payload.
//! Every other wire type puts the bytes in payload and leaves value_u64 at 0.
//! payload points into the message buffer, it is not copied.
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

/// Field number from the .proto definition.
field_number: u32,
/// Wire type id (see wire_type.zig).
wire_type: u3,
/// Raw bytes for WT_LEN, WT_I64, and WT_I32. Empty for WT_VARINT.
payload: []const u8,
/// Decoded value for WT_VARINT. 0 for other wire types.
value_u64: u64,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 grpc proto: ProtoField, holds a varint field" {
    const field: Self = .{
        .field_number = 2,
        .wire_type = 0,
        .payload = &.{},
        .value_u64 = 42,
    };

    try std.testing.expectEqual(@as(u32, 2), field.field_number);
    try std.testing.expectEqual(@as(u64, 42), field.value_u64);
    try std.testing.expectEqual(@as(usize, 0), field.payload.len);
}

test "zix http2 grpc proto: ProtoField, payload points into the source" {
    const src = "hello";

    const field: Self = .{
        .field_number = 1,
        .wire_type = 2,
        .payload = src[0..],
        .value_u64 = 0,
    };

    try std.testing.expectEqual(@intFromPtr(src.ptr), @intFromPtr(field.payload.ptr));
}

