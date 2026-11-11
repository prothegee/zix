//! ZIX Http2 Grpc GrpcPath
//!
//! ### file: src/zix/tcp/http2/grpc/GrpcPath.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The two parts of a gRPC path: /<package.Service>/<Method>.
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

/// Service part, package included (e.g. "helloworld.Greeter").
package_service: []const u8,
/// Method part (e.g. "SayHello").
method: []const u8,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 grpc: GrpcPath, keeps both parts" {
    const grpc_path: Self = .{
        .package_service = "helloworld.Greeter",
        .method = "SayHello",
    };

    try std.testing.expectEqualStrings("helloworld.Greeter", grpc_path.package_service);
    try std.testing.expectEqualStrings("SayHello", grpc_path.method);
}

