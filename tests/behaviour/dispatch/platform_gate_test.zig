//! Behaviour tests for the DispatchModel platform gate (ADR-065).
//!
//! What:
//! - .EPOLL and .URING are Linux-only. Off Linux an engine's run() returns
//!   error.ZixDispatchModelUnsupported instead of silently serving a different model, so a caller
//!   never believes it got the model it asked for. .ASYNC is the only portable model.
//! - The gate is one shared predicate (zix.utils.dispatch_support.isSupported) that every engine
//!   consults, so these tests assert the contract once for the whole tree. They cover the predicate
//!   and the enum shape only: calling run() to observe a rejection needs a non-Linux target, and a
//!   test that can never execute where it is developed is not worth its skip line.

const std = @import("std");
const builtin = @import("builtin");
const zix = @import("zix");

const dispatch_support = zix.utils.dispatch_support;

/// True when this build targets Linux, where all three models are available.
const linux_target = builtin.os.tag == .linux;

// --------------------------------------------------------- //

fn noopHttp1(_: *zix.Http1.Request, _: *zix.Http1.Response, _: *zix.Http1.Context) anyerror!void {}

fn noopHttp(_: *zix.Http.Request, _: *zix.Http.Response, _: *zix.Http.Context) anyerror!void {}

fn noopHttp2(_: *zix.Http2.Request, _: *zix.Http2.Response, _: *zix.Http2.Context) anyerror!void {}

fn noopGrpc(_: *zix.Grpc.Request, _: *zix.Grpc.Response, _: *zix.Grpc.Context) anyerror!void {}

fn noopTcp(stream: std.Io.net.Stream, io: std.Io) void {
    stream.close(io);
}

// --------------------------------------------------------- //

test "zix behaviour: DispatchModel is one shared type across every engine namespace" {
    try std.testing.expectEqual(zix.Tcp.DispatchModel, zix.Http.DispatchModel);
    try std.testing.expectEqual(zix.Tcp.DispatchModel, zix.Http1.DispatchModel);
    try std.testing.expectEqual(zix.Tcp.DispatchModel, zix.Http2.DispatchModel);
    try std.testing.expectEqual(zix.Tcp.DispatchModel, zix.Grpc.DispatchModel);
    try std.testing.expectEqual(zix.Tcp.DispatchModel, zix.Fix.DispatchModel);
    try std.testing.expectEqual(zix.Tcp.DispatchModel, zix.Udp.DispatchModel);
    try std.testing.expectEqual(zix.Tcp.DispatchModel, zix.Http3.DispatchModel);
}

/// Names every model through an exhaustive switch with no else prong, so a fourth variant would
/// break the build here. Written without @typeInfo so it reads the same on every Zig version.
fn modelLabel(model: zix.Tcp.DispatchModel) []const u8 {
    return switch (model) {
        .ASYNC => "ASYNC",
        .EPOLL => "EPOLL",
        .URING => "URING",
    };
}

test "zix behaviour: DispatchModel carries exactly ASYNC, EPOLL, URING" {
    try std.testing.expectEqualStrings("ASYNC", modelLabel(.ASYNC));
    try std.testing.expectEqualStrings("EPOLL", modelLabel(.EPOLL));
    try std.testing.expectEqualStrings("URING", modelLabel(.URING));

    try std.testing.expectEqualStrings("ASYNC", @tagName(zix.Tcp.DispatchModel.ASYNC));
    try std.testing.expectEqualStrings("EPOLL", @tagName(zix.Tcp.DispatchModel.EPOLL));
    try std.testing.expectEqualStrings("URING", @tagName(zix.Tcp.DispatchModel.URING));
}

test "zix behaviour: the dropped POOL and MIXED names resolve to nothing" {
    try std.testing.expect(std.meta.stringToEnum(zix.Tcp.DispatchModel, "POOL") == null);
    try std.testing.expect(std.meta.stringToEnum(zix.Tcp.DispatchModel, "MIXED") == null);
    try std.testing.expectEqual(zix.Tcp.DispatchModel.ASYNC, std.meta.stringToEnum(zix.Tcp.DispatchModel, "ASYNC").?);
}

test "zix behaviour: DispatchModel backing values are gapless with ASYNC as the zero value" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(zix.Tcp.DispatchModel.ASYNC));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(zix.Tcp.DispatchModel.EPOLL));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(zix.Tcp.DispatchModel.URING));

    // A zero-initialized config lands on the portable model, never a Linux-only one.
    const zero: zix.Tcp.DispatchModel = @enumFromInt(0);
    try std.testing.expectEqual(zix.Tcp.DispatchModel.ASYNC, zero);
}

test "zix behaviour: isSupported accepts ASYNC on every platform" {
    try std.testing.expect(dispatch_support.isSupported(.ASYNC));
}

test "zix behaviour: isSupported gates EPOLL and URING on the target os" {
    try std.testing.expectEqual(linux_target, dispatch_support.isSupported(.EPOLL));
    try std.testing.expectEqual(linux_target, dispatch_support.isSupported(.URING));
}

test "zix behaviour: the rejected model is named in the log line, not just the error" {
    try std.testing.expectEqualStrings("EPOLL", dispatch_support.rejectedName(.EPOLL));
    try std.testing.expectEqualStrings("URING", dispatch_support.rejectedName(.URING));
}

// --------------------------------------------------------- //

test "zix behaviour: ASYNC config is accepted by every engine on this platform" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // init never validates the model (run does), so this asserts the portable model is a legal
    // value everywhere and leaves the accept loops unstarted.
    var tcp = try zix.Tcp.Server.init(noopTcp, .{ .io = io, .ip = "127.0.0.1", .port = 9360, .dispatch_model = .ASYNC });
    defer tcp.deinit();
    try std.testing.expectEqual(zix.Tcp.DispatchModel.ASYNC, tcp.config.dispatch_model);

    var http1 = zix.Http1.Server.init(noopHttp1, .{ .io = io, .ip = "127.0.0.1", .port = 9361, .dispatch_model = .ASYNC });
    defer http1.deinit();
    try std.testing.expectEqual(zix.Tcp.DispatchModel.ASYNC, http1.config.dispatch_model);

    var http2 = zix.Http2.Server.init(noopHttp2, .{ .io = io, .ip = "127.0.0.1", .port = 9362, .dispatch_model = .ASYNC });
    defer http2.deinit();
    try std.testing.expectEqual(zix.Tcp.DispatchModel.ASYNC, http2.config.dispatch_model);

    var fix = try zix.Fix.Server.init(null, .{ .io = io, .ip = "127.0.0.1", .port = 9363, .comp_id = "ZIX", .dispatch_model = .ASYNC });
    defer fix.deinit();
    try std.testing.expectEqual(zix.Tcp.DispatchModel.ASYNC, fix.config.dispatch_model);
}

test "zix behaviour: the grpc engine takes the shared model on its Router-typed server" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const Routes = [_]zix.Grpc.Route{
        .{ .path = "/zix.Test/Noop", .handler = noopGrpc },
    };
    var server = zix.Grpc.Server.init(zix.Grpc.Router(&Routes), .{
        .io = threaded.io(),
        .ip = "127.0.0.1",
        .port = 9364,
        .dispatch_model = .ASYNC,
    });
    defer server.deinit();

    try std.testing.expectEqual(zix.Tcp.DispatchModel.ASYNC, server.config.dispatch_model);
}
