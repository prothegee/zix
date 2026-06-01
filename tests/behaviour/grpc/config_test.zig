//! Behaviour tests: gRPC config defaults, type contracts, codec roundtrips.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix behaviour: GrpcServerConfig defaults" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = zix.Grpc.ServerConfig{ .io = io, .ip = "127.0.0.1", .port = 8083 };

    try std.testing.expectEqual(zix.Grpc.DispatchModel.ASYNC, cfg.dispatch_model);
    try std.testing.expectEqual(@as(u31, 1024), cfg.kernel_backlog);
    try std.testing.expectEqual(@as(usize, 0), cfg.workers);
    try std.testing.expectEqual(@as(usize, 0), cfg.pool_size);
    try std.testing.expectEqual(@as(usize, 16), cfg.max_streams);
    try std.testing.expectEqual(@as(u32, 16384), cfg.max_frame_size);
    try std.testing.expectEqual(@as(usize, 65536), cfg.max_body);
}

test "zix behaviour: GrpcClientConfig basic fields" {
    const cfg = zix.Grpc.ClientConfig{ .ip = "127.0.0.1", .port = 8083 };
    try std.testing.expectEqualStrings("127.0.0.1", cfg.ip);
    try std.testing.expectEqual(@as(u16, 8083), cfg.port);
}

test "zix behaviour: GrpcStatus enum values are correct" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(zix.Grpc.Status.OK));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(zix.Grpc.Status.CANCELLED));
    try std.testing.expectEqual(@as(u8, 12), @intFromEnum(zix.Grpc.Status.UNIMPLEMENTED));
    try std.testing.expectEqual(@as(u8, 16), @intFromEnum(zix.Grpc.Status.UNAUTHENTICATED));
}

test "zix behaviour: GrpcContext.recvMessage empty body returns null" {
    var ctx = zix.Grpc.Context{
        .fd = 0,
        .stream_id = 1,
        ._body = &.{},
        ._pos = 0,
        ._hdr_sent = false,
        ._sent_bytes = 0,
        ._grpc_status = 0,
    };
    try std.testing.expect(ctx.recvMessage() == null);
}

test "zix behaviour: GrpcPrefix roundtrip" {
    var buf: [5]u8 = undefined;
    zix.Grpc.writePrefix(&buf, false, 1024);
    const p = try zix.Grpc.readPrefix(&buf);
    try std.testing.expect(!p.compress);
    try std.testing.expectEqual(@as(u32, 1024), p.msg_len);
}

test "zix behaviour: parsePath valid path" {
    const p = zix.Grpc.parsePath("/helloworld.Greeter/SayHello").?;
    try std.testing.expectEqualStrings("helloworld.Greeter", p.package_service);
    try std.testing.expectEqualStrings("SayHello", p.method);
}

test "zix behaviour: parseTimeout seconds" {
    try std.testing.expectEqual(@as(?u64, 2_000_000_000), zix.Grpc.parseTimeout("2S"));
}
