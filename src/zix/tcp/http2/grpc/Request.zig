//! ZIX Http2 Grpc Request
//!
//! ### file: src/zix/tcp/http2/grpc/Request.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Read-only view of one inbound gRPC call: path, headers, and messages.
//!
//! ### note:
//!
//! Messages are read through the Context, which owns the body and its cursor.
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
const Context = @import("Context.zig");
const Header = @import("../hpack/Header.zig");

// --------------------------------------------------------- //
// Fields:

/// Full gRPC path of this call (e.g. "/pkg.Svc/Method").
path: []const u8,
/// Decoded request headers, valid for the duration of the handler call.
headers: []const Header,
/// The call context that owns the body.
_ctx: *Context,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// One request header value by name (case-insensitive).
///
/// Return:
/// - ?[]const u8 (null when the header is absent)
pub fn header(self: Self, name: []const u8) ?[]const u8 {
    for (self.headers) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry.value;
    }

    return null;
}

/// Read the next request message. See Context.recvMessage.
///
/// Return:
/// - ?[]const u8 (null when every whole message was read)
pub fn recvMessage(self: Self) ?[]const u8 {
    return self._ctx.recvMessage();
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const builtin = @import("builtin");
const prefix = @import("frame/prefix.zig");

const TEST_FD: std.posix.fd_t = if (builtin.os.tag == .windows)
    std.os.windows.INVALID_HANDLE_VALUE
else
    -1;

const TEST_HEADERS = [_]Header{
    .{
        .name = ":path",
        .value = "/svc.Svc/Method",
    },
    .{
        .name = "content-type",
        .value = "application/grpc",
    },
};

test "zix http2 grpc: Request, header is case-insensitive" {
    var ctx = Context.init(std.testing.io, std.testing.allocator, TEST_FD, 1, &.{});
    const req: Self = .{
        .path = "/svc.Svc/Method",
        .headers = &TEST_HEADERS,
        ._ctx = &ctx,
    };

    try std.testing.expectEqualStrings("application/grpc", req.header("Content-Type").?);
}

test "zix http2 grpc: Request, header absent returns null" {
    var ctx = Context.init(std.testing.io, std.testing.allocator, TEST_FD, 1, &.{});
    const req: Self = .{
        .path = "/svc.Svc/Method",
        .headers = &TEST_HEADERS,
        ._ctx = &ctx,
    };

    try std.testing.expect(req.header("grpc-timeout") == null);
}

test "zix http2 grpc: Request, recvMessage reads through the context" {
    var body: [7]u8 = undefined;
    prefix.writeGrpcPrefix(body[0..prefix.PREFIX_LEN], false, 2);
    @memcpy(body[prefix.PREFIX_LEN..], "hi");

    var ctx = Context.init(std.testing.io, std.testing.allocator, TEST_FD, 1, &body);
    const req: Self = .{
        .path = "/svc.Svc/Method",
        .headers = &.{},
        ._ctx = &ctx,
    };

    try std.testing.expectEqualStrings("hi", req.recvMessage().?);
    try std.testing.expect(req.recvMessage() == null);
}

