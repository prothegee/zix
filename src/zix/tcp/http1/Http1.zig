//! ZIX Http1
//!
//! ### file: src/zix/tcp/http1/Http1.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Zix Http1 namespace
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

const router = @import("router.zig");

const std = @import("std");

// --------------------------------------------------------- //
// Public:

pub const Server = @import("Server.zig");
pub const DispatchModel = @import("../../shared/dispatch.zig").Model;
pub const HandlerFn = @import("handler.zig").HandlerFn;

pub const Route = router.Route;
pub const Router = router.Router;
pub const RouteKind = router.RouteKind;
pub const PathParam = @import("PathParam.zig");

pub const Request = @import("Request.zig");
pub const Response = @import("Response.zig");
pub const Context = @import("Context.zig");
pub const HeaderSize = @import("header.zig").Size;

pub const Method = @import("../../utils/http/method.zig");
pub const Status = @import("../../utils/http/status.zig");
pub const Content = @import("../../utils/http/content.zig");
pub const ContentType = Content.Type;

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn probeHandler(_: *Request, _: *Response, _: *Context) anyerror!void {}

test "zix http1: Http1, exposes the engine types" {
    _ = @This().Server;
    _ = @This().Route;
    _ = @This().Router;
    _ = @This().Request;
    _ = @This().Response;
    _ = @This().Context;
}

test "zix http1: Http1, HandlerFn takes the request trio" {
    const handler: @This().HandlerFn = probeHandler;

    try std.testing.expect(handler == &probeHandler);
}

test "zix http1: Http1, PathParam holds a name and value" {
    const param: @This().PathParam = .{
        .name = "id",
        .value = "42",
    };

    try std.testing.expectEqualStrings("id", param.name);
    try std.testing.expectEqualStrings("42", param.value);
}

test "zix http1: Http1, Method maps a token to its code" {
    try std.testing.expectEqual(@This().Method.Code.GET, @This().Method.enumFromString("GET"));
}

test "zix http1: Http1, Method falls back to GET on an unknown token" {
    try std.testing.expectEqual(@This().Method.Code.GET, @This().Method.enumFromString("BREW"));
}

test "zix http1: Http1, Status names its code" {
    try std.testing.expectEqualStrings("Not Found", @This().Status.stringFromEnum(.NOT_FOUND));
    try std.testing.expectEqual(@as(u16, 404), @intFromEnum(@This().Status.Code.NOT_FOUND));
}

test "zix http1: Http1, HeaderSize maps a tier to its cap" {
    const size: @This().HeaderSize = .MINIMAL;

    try std.testing.expectEqual(@as(usize, 16), size.value());
}

test "zix http1: Http1, HeaderSize keeps a custom cap" {
    const size: @This().HeaderSize = .{ .CUSTOM = 40 };

    try std.testing.expectEqual(@as(usize, 40), size.value());
}

test "zix http1: Http1, ContentType is the Content type enum" {
    try std.testing.expect(@This().ContentType == @This().Content.Type);
}

test "zix http1: Http1, Content resolves a media type" {
    try std.testing.expectEqual(
        @as(?@This().ContentType, .APPLICATION_JSON),
        @This().Content.typeFromString("application/json"),
    );
}

test "zix http1: Http1, Content falls back on an unknown media type" {
    try std.testing.expectEqual(
        @as(?@This().ContentType, null),
        @This().Content.typeFromString("application/x-unknown-zix"),
    );
}

test "zix http1: Http1, shares the dispatch model" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(@This().DispatchModel.ASYNC));
}

