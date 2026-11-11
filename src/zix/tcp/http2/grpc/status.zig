//! ZIX Http2 Grpc status
//!
//! ### file: src/zix/tcp/http2/grpc/status.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! gRPC canonical status codes, sent in the grpc-status trailer.
//!
//! ### note:
//!
//! The enum is non-exhaustive: a code read from a peer past 16 still converts.
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

/// gRPC canonical status codes (grpc.io/docs/guides/status-codes/).
pub const GrpcStatus = enum(u8) {
    OK = 0,
    CANCELLED = 1,
    UNKNOWN = 2,
    INVALID_ARGUMENT = 3,
    DEADLINE_EXCEEDED = 4,
    NOT_FOUND = 5,
    ALREADY_EXISTS = 6,
    PERMISSION_DENIED = 7,
    RESOURCE_EXHAUSTED = 8,
    FAILED_PRECONDITION = 9,
    ABORTED = 10,
    OUT_OF_RANGE = 11,
    UNIMPLEMENTED = 12,
    INTERNAL = 13,
    UNAVAILABLE = 14,
    DATA_LOSS = 15,
    UNAUTHENTICATED = 16,
    _,
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const CodeCase = struct {
    status: GrpcStatus,
    code: u8,
};

const CODE_CASES = [_]CodeCase{
    .{
        .status = .OK,
        .code = 0,
    },
    .{
        .status = .CANCELLED,
        .code = 1,
    },
    .{
        .status = .UNKNOWN,
        .code = 2,
    },
    .{
        .status = .INVALID_ARGUMENT,
        .code = 3,
    },
    .{
        .status = .DEADLINE_EXCEEDED,
        .code = 4,
    },
    .{
        .status = .NOT_FOUND,
        .code = 5,
    },
    .{
        .status = .ALREADY_EXISTS,
        .code = 6,
    },
    .{
        .status = .PERMISSION_DENIED,
        .code = 7,
    },
    .{
        .status = .RESOURCE_EXHAUSTED,
        .code = 8,
    },
    .{
        .status = .FAILED_PRECONDITION,
        .code = 9,
    },
    .{
        .status = .ABORTED,
        .code = 10,
    },
    .{
        .status = .OUT_OF_RANGE,
        .code = 11,
    },
    .{
        .status = .UNIMPLEMENTED,
        .code = 12,
    },
    .{
        .status = .INTERNAL,
        .code = 13,
    },
    .{
        .status = .UNAVAILABLE,
        .code = 14,
    },
    .{
        .status = .DATA_LOSS,
        .code = 15,
    },
    .{
        .status = .UNAUTHENTICATED,
        .code = 16,
    },
};

test "zix http2 grpc: GrpcStatus, each code maps to its canonical value" {
    for (CODE_CASES) |case| {
        try std.testing.expectEqual(case.code, @intFromEnum(case.status));
    }
}

test "zix http2 grpc: GrpcStatus, each canonical value maps back to its code" {
    for (CODE_CASES) |case| {
        const status: GrpcStatus = @enumFromInt(case.code);

        try std.testing.expectEqual(case.status, status);
    }
}

test "zix http2 grpc: GrpcStatus, OK is the zero value" {
    const zeroed = std.mem.zeroes(GrpcStatus);

    try std.testing.expectEqual(GrpcStatus.OK, zeroed);
}

test "zix http2 grpc: GrpcStatus, unknown code past 16 keeps its value" {
    const status: GrpcStatus = @enumFromInt(17);

    try std.testing.expectEqual(@as(u8, 17), @intFromEnum(status));
}

test "zix http2 grpc: GrpcStatus, max u8 code keeps its value" {
    const status: GrpcStatus = @enumFromInt(255);

    try std.testing.expectEqual(@as(u8, 255), @intFromEnum(status));
}

