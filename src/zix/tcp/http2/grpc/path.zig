//! ZIX Http2 Grpc path
//!
//! ### file: src/zix/tcp/http2/grpc/path.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Read the gRPC path from request headers and split it into service and method.
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
const GrpcPath = @import("GrpcPath.zig");
const Header = @import("../hpack/Header.zig");

// --------------------------------------------------------- //
// Public:

/// Split a /<package.Service>/<Method> path.
///
/// Param:
/// path - []const u8 (the :path value)
///
/// Return:
/// - GrpcPath
/// - null when the path has no service or no method
pub fn parsePath(path: []const u8) ?GrpcPath {
    if (path.len < 2 or path[0] != '/') return null;

    const rest = path[1..];
    const slash = std.mem.lastIndexOfScalar(u8, rest, '/') orelse return null;
    if (slash == 0 or slash + 1 >= rest.len) return null;

    return .{
        .package_service = rest[0..slash],
        .method = rest[slash + 1 ..],
    };
}

/// The :path pseudo-header value.
///
/// Param:
/// headers - []const Header (decoded request headers)
///
/// Return:
/// - []const u8 (the :path value, "/" when absent)
pub fn headerPath(headers: []const Header) []const u8 {
    for (headers) |header| {
        if (std.mem.eql(u8, header.name, ":path")) return header.value;
    }

    return "/";
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 grpc: path, parsePath splits service and method" {
    const grpc_path = parsePath("/helloworld.Greeter/SayHello").?;

    try std.testing.expectEqualStrings("helloworld.Greeter", grpc_path.package_service);
    try std.testing.expectEqualStrings("SayHello", grpc_path.method);
}

test "zix http2 grpc: path, parsePath keeps a nested service" {
    const grpc_path = parsePath("/a/b.Svc/Method").?;

    try std.testing.expectEqualStrings("a/b.Svc", grpc_path.package_service);
    try std.testing.expectEqualStrings("Method", grpc_path.method);
}

test "zix http2 grpc: path, parsePath without a service returns null" {
    try std.testing.expect(parsePath("/SayHello") == null);
}

test "zix http2 grpc: path, parsePath with a trailing slash returns null" {
    try std.testing.expect(parsePath("/pkg.Svc/") == null);
}

test "zix http2 grpc: path, parsePath without a leading slash returns null" {
    try std.testing.expect(parsePath("pkg.Svc/Method") == null);
}

test "zix http2 grpc: path, parsePath too short returns null" {
    try std.testing.expect(parsePath("") == null);
    try std.testing.expect(parsePath("/") == null);
}

test "zix http2 grpc: path, parsePath with an empty service returns null" {
    try std.testing.expect(parsePath("//Method") == null);
}

test "zix http2 grpc: path, headerPath finds the path" {
    const headers = [_]Header{
        .{
            .name = ":method",
            .value = "POST",
        },
        .{
            .name = ":path",
            .value = "/svc.Svc/Method",
        },
    };

    try std.testing.expectEqualStrings("/svc.Svc/Method", headerPath(&headers));
}

test "zix http2 grpc: path, headerPath without a path falls back to root" {
    const headers = [_]Header{
        .{
            .name = ":method",
            .value = "POST",
        },
    };

    try std.testing.expectEqualStrings("/", headerPath(&headers));
}

