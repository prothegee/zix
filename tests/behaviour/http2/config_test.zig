//! Behaviour tests: Http2ServerConfig observable defaults, HandlerFn assignment, frame constants.

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix behaviour: Http2ServerConfig dispatch_model is required and stored as set" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = zix.Http2.ServerConfig{ .io = io, .ip = "127.0.0.1", .port = 8082, .dispatch_model = .ASYNC };
    try std.testing.expectEqual(zix.Http2.DispatchModel.ASYNC, cfg.dispatch_model);
}

test "zix behaviour: Http2ServerConfig max_streams defaults to 16" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = zix.Http2.ServerConfig{ .io = io, .ip = "127.0.0.1", .port = 8082, .dispatch_model = .ASYNC };
    try std.testing.expectEqual(@as(usize, 16), cfg.max_streams);
}

test "zix behaviour: Http2ServerConfig max_frame_size defaults to 16384" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg = zix.Http2.ServerConfig{ .io = io, .ip = "127.0.0.1", .port = 8082, .dispatch_model = .ASYNC };
    try std.testing.expectEqual(@as(u32, 16384), cfg.max_frame_size);
}

test "zix behaviour: Http2 HandlerFn can be assigned to a local variable" {
    const h: zix.Http2.HandlerFn = struct {
        fn f(
            method: []const u8,
            headers: []const zix.Http2.Header,
            body: []const u8,
            fd: std.posix.fd_t,
            sid: u31,
        ) void {
            _ = method;
            _ = headers;
            _ = body;
            _ = fd;
            _ = sid;
        }
    }.f;
    _ = h;
}

test "zix behaviour: Http2 PREFACE length is 24" {
    try std.testing.expectEqual(@as(usize, 24), zix.Http2.PREFACE.len);
}

test "zix behaviour: Http2 ERR_NO_ERROR is zero" {
    try std.testing.expectEqual(@as(u32, 0), zix.Http2.ERR_NO_ERROR);
}

test "zix behaviour: Http2 FLAG_END_STREAM and FLAG_END_HEADERS are distinct" {
    try std.testing.expect(zix.Http2.FLAG_END_STREAM != zix.Http2.FLAG_END_HEADERS);
}
