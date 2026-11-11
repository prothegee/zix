//! ZIX Http2 Grpc
//!
//! ### file: src/zix/tcp/http2/grpc/Grpc.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Zix Grpc namespace: the gRPC h2c server, its frame helpers, and the
//! protobuf wire helpers.
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
const cache = @import("cache.zig");
const content_type = @import("content_type.zig");
const field = @import("proto/field.zig");
const path = @import("path.zig");
const prefix = @import("frame/prefix.zig");
const router = @import("router.zig");
const send = @import("frame/send.zig");
const varint = @import("proto/varint.zig");
const wire_type = @import("proto/wire_type.zig");

// --------------------------------------------------------- //
// Public:

pub const Server = @import("server.zig");
pub const ServerConfig = @import("Config.zig");
pub const DispatchModel = @import("../../../shared/dispatch.zig").Model;
pub const HandlerFn = @import("handler.zig").HandlerFn;
pub const Route = router.Route;
pub const Router = router.Router;
pub const ServeOpts = @import("ServeOpts.zig");
pub const serveConn = @import("serve.zig").serveConn;
pub const Request = @import("Request.zig");
pub const Response = @import("Response.zig");
pub const Context = @import("Context.zig");
pub const Status = @import("status.zig").GrpcStatus;
pub const ContentType = content_type.GrpcContentType;
pub const detectContentType = content_type.detectContentType;
pub const Path = @import("GrpcPath.zig");
pub const parsePath = path.parsePath;

/// Per-worker unary response cache, opt-in via ServerConfig.response_cache.
pub const ResponseCache = @import("../../../utils/cache/ResponseCache.zig");
pub const setCache = cache.setCache;
pub const cacheTtl = cache.cacheTtl;

pub const Prefix = @import("frame/GrpcPrefix.zig");
pub const readPrefix = prefix.readGrpcPrefix;
pub const writePrefix = prefix.writeGrpcPrefix;
pub const sendHeadersFD = send.sendGrpcHeadersFD;
pub const sendDataFD = send.sendGrpcDataFD;
pub const sendTrailerFD = send.sendGrpcTrailerFD;
pub const sendErrorFD = send.sendGrpcErrorFD;

pub const WT_VARINT = wire_type.WT_VARINT;
pub const WT_I64 = wire_type.WT_I64;
pub const WT_LEN = wire_type.WT_LEN;
pub const WT_I32 = wire_type.WT_I32;
pub const encodeVarint = varint.encodeVarint;
pub const decodeVarint = varint.decodeVarint;
pub const encodeString = field.encodeString;
pub const encodeInt32 = field.encodeInt32;
pub const encodeDouble = field.encodeDouble;
pub const decodeDouble = field.decodeDouble;
pub const ProtoField = @import("proto/ProtoField.zig");
pub const MessageReader = @import("proto/MessageReader.zig");

pub const parseTimeout = @import("timeout.zig").parseTimeout;

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn probeHandler(_: *Request, _: *Response, _: *Context) anyerror!void {}

test "zix http2 grpc: Grpc, exposes the engine types" {
    _ = @This().Server;
    _ = @This().ServerConfig;
    _ = @This().Route;
    _ = @This().Router;
    _ = @This().Request;
    _ = @This().Response;
    _ = @This().Context;
    _ = @This().ServeOpts;
}

test "zix http2 grpc: Grpc, HandlerFn takes the request trio" {
    const handler: @This().HandlerFn = probeHandler;

    try std.testing.expect(handler == &probeHandler);
}

test "zix http2 grpc: Grpc, Server.init builds a server for a Router" {
    const routes = @This().Router(&[_]@This().Route{
        .{
            .path = "/svc.Svc/Method",
            .handler = probeHandler,
        },
    });

    var server = @This().Server.init(routes, .{
        .io = std.testing.io,
        .ip = "127.0.0.1",
        .port = 9036,
        .dispatch_model = .ASYNC,
    });
    defer server.deinit();

    try std.testing.expectEqual(@as(u16, 9036), server.config.port);
}

test "zix http2 grpc: Grpc, Status keeps the gRPC code values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(@This().Status.OK));
    try std.testing.expectEqual(@as(u8, 8), @intFromEnum(@This().Status.RESOURCE_EXHAUSTED));
}

test "zix http2 grpc: Grpc, writePrefix round-trips through readPrefix" {
    var buf: [5]u8 = undefined;
    @This().writePrefix(&buf, false, 42);

    const read = try @This().readPrefix(&buf);

    try std.testing.expectEqual(@as(u32, 42), read.msg_len);
}

test "zix http2 grpc: Grpc, encodeString reads back through MessageReader" {
    var buf: [32]u8 = undefined;
    const len = try @This().encodeString(1, "zix", &buf);

    var reader = @This().MessageReader.init(buf[0..len]);
    const got = (try reader.next()).?;

    try std.testing.expectEqual(@as(u32, 1), got.field_number);
    try std.testing.expectEqual(@This().WT_LEN, got.wire_type);
}

test "zix http2 grpc: Grpc, parseTimeout reads seconds as nanoseconds" {
    try std.testing.expectEqual(@as(u64, 1_000_000_000), try @This().parseTimeout("1S"));
}

test "zix http2 grpc: Grpc, parsePath splits service and method" {
    const parsed = @This().parsePath("/pkg.Svc/Method").?;

    try std.testing.expectEqualStrings("Method", parsed.method);
}

test "zix http2 grpc: Grpc, shares the dispatch model" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(@This().DispatchModel.ASYNC));
}

