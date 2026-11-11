//! ZIX Http2 Grpc content type
//!
//! ### file: src/zix/tcp/http2/grpc/content_type.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Detect the gRPC message encoding from the request content-type.
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
const Header = @import("../hpack/Header.zig");

// --------------------------------------------------------- //
// Public:

/// Message encoding named by the content-type.
pub const GrpcContentType = enum {
    PROTO,
    JSON,
    UNKNOWN,
};

/// Detect the gRPC content-type from request headers.
///
/// Note:
/// - Bare `application/grpc` is protobuf, as the gRPC spec says.
///
/// Param:
/// headers - []const Header (decoded request headers)
///
/// Return:
/// - GrpcContentType (UNKNOWN when no gRPC content-type is present)
pub fn detectContentType(headers: []const Header) GrpcContentType {
    for (headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "content-type")) continue;

        if (std.mem.startsWith(u8, header.value, "application/grpc+json")) return .JSON;
        if (std.mem.startsWith(u8, header.value, "application/grpc")) return .PROTO;
    }

    return .UNKNOWN;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn oneHeader(name: []const u8, value: []const u8) [1]Header {
    return .{
        .{
            .name = name,
            .value = value,
        },
    };
}

test "zix http2 grpc: content_type, proto" {
    const headers = oneHeader("content-type", "application/grpc+proto");

    try std.testing.expectEqual(GrpcContentType.PROTO, detectContentType(&headers));
}

test "zix http2 grpc: content_type, json" {
    const headers = oneHeader("content-type", "application/grpc+json");

    try std.testing.expectEqual(GrpcContentType.JSON, detectContentType(&headers));
}

test "zix http2 grpc: content_type, no subtype is PROTO" {
    const headers = oneHeader("content-type", "application/grpc");

    try std.testing.expectEqual(GrpcContentType.PROTO, detectContentType(&headers));
}

test "zix http2 grpc: content_type, header name is case-insensitive" {
    const headers = oneHeader("Content-Type", "application/grpc");

    try std.testing.expectEqual(GrpcContentType.PROTO, detectContentType(&headers));
}

test "zix http2 grpc: content_type, non gRPC value is UNKNOWN" {
    const headers = oneHeader("content-type", "application/json");

    try std.testing.expectEqual(GrpcContentType.UNKNOWN, detectContentType(&headers));
}

test "zix http2 grpc: content_type, without the header is UNKNOWN" {
    try std.testing.expectEqual(GrpcContentType.UNKNOWN, detectContentType(&.{}));
}

