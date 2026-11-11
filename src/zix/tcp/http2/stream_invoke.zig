//! ZIX Http2 stream_invoke
//!
//! ### file: src/zix/tcp/http2/stream_invoke.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Turn a finished stream into a Request and invoke the handler on it.
//!
//! ### note:
//!
//! - A stream whose body is short of (or past) its own content-length is reset
//!   with PROTOCOL_ERROR and never reaches the handler (RFC 9113 section 8.1.1).
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
const control = @import("control.zig");
const frame = @import("frame.zig");
const handler = @import("handler.zig");
const stream_body = @import("stream_body.zig");
const Header = @import("hpack/Header.zig");
const Request = @import("Request.zig");
const ServeOpts = @import("ServeOpts.zig");
const Stream = @import("Stream.zig");

// --------------------------------------------------------- //
// Public:

/// Build the request view over decoded headers and a body.
///
/// Note:
/// - The two pseudo-headers have distinct lengths (":path" 5, ":method" 7),
///   so the scan switches on length first and compares at most once.
/// - A missing :method reads as GET, a missing :path reads as "/".
///
/// Param:
/// headers - []const Header (the stream's decoded headers)
/// body - []const u8 (the stream's body bytes)
///
/// Return:
/// - Request (borrows headers and body, valid while the stream is)
pub fn buildRequest(headers: []const Header, body: []const u8) Request {
    var method: []const u8 = "GET";
    var raw_path: []const u8 = "/";

    for (headers) |header| {
        switch (header.name.len) {
            5 => if (std.mem.eql(u8, header.name, ":path")) {
                raw_path = header.value;
            },
            7 => if (std.mem.eql(u8, header.name, ":method")) {
                method = header.value;
            },
            else => {},
        }
    }

    const split = Request.splitPath(raw_path);

    return .{
        .method = method,
        .path = split.path,
        .query = split.query,
        .headers = headers,
        .body = body,
    };
}

/// Invoke the handler for a stream whose END_STREAM has arrived, unless its
/// body does not match the content-length it declared.
///
/// Note:
/// - The caller frees the stream slot either way.
///
/// Param:
/// handler_fn - handler.HandlerFn (the route or top-level handler)
/// stream - *const Stream (the stream whose request side just closed)
/// fd - std.posix.fd_t (the connection)
/// opts - ServeOpts (serve limits carried to the handler trio)
/// io - std.Io (the worker io)
/// peer_max_frame_size - u32 (largest DATA frame the peer accepts)
///
/// Return:
/// - void
pub fn invokeWhole(
    handler_fn: handler.HandlerFn,
    stream: *const Stream,
    fd: std.posix.fd_t,
    opts: ServeOpts,
    io: std.Io,
    peer_max_frame_size: u32,
) void {
    if (!stream_body.isWhole(stream.headerList(), stream.body_len)) {
        control.sendRstStreamFD(
            fd,
            stream.id,
            frame.ERR_PROTOCOL_ERROR,
        ) catch |err| switch (err) {
            // Best effort: the peer went away. The connection loop sees the
            // broken socket on its next read.
            error.ZixHttp2_Control_BrokenPipe,
            error.ZixHttp2_Control_TooManySettings,
            error.ZixHttp2_Control_UnexpectedEOF,
            error.ZixHttp2_Control_Overflow,
            error.ZixHttp2_Control_BufferFull,
            => {},
        };

        return;
    }

    var req = buildRequest(stream.headerList(), stream.bodyBytes());

    handler.invokeHandler(handler_fn, &req, fd, stream.id, io, opts, peer_max_frame_size);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../utils/socket/pair.zig");
const Context = @import("Context.zig");
const Response = @import("Response.zig");

threadlocal var tl_calls: usize = 0;
threadlocal var tl_seen_method: [8]u8 = undefined;
threadlocal var tl_seen_method_len: usize = 0;
threadlocal var tl_seen_body_len: usize = 0;

fn probeHandler(req: *Request, res: *Response, _: *Context) anyerror!void {
    tl_calls += 1;
    tl_seen_method_len = @min(req.method.len, tl_seen_method.len);
    @memcpy(tl_seen_method[0..tl_seen_method_len], req.method[0..tl_seen_method_len]);
    tl_seen_body_len = req.body.len;

    try res.sendText("ok");
}

fn testStream(sid: u31) !*Stream {
    const stream = try std.testing.allocator.create(Stream);
    stream.open(sid);

    return stream;
}

fn addHeader(stream: *Stream, name: []const u8, value: []const u8) void {
    stream.headers[stream.header_count] = .{
        .name = name,
        .value = value,
    };
    stream.header_count += 1;
}

fn readFrameType(fd: std.posix.fd_t) !u8 {
    var buf: [frame.FRAME_HEADER_LEN]u8 = undefined;
    const got = try std.posix.read(fd, &buf);
    if (got < buf.len) return error.ZixTest_ShortRead;

    return frame.parseFrameHeader(&buf).frame_type;
}

test "zix http2: stream_invoke, buildRequest reads pseudo-headers" {
    const stream = try testStream(1);
    defer std.testing.allocator.destroy(stream);

    addHeader(stream, ":method", "POST");
    addHeader(stream, ":path", "/items?page=2");
    _ = stream.appendBody("abc");

    const req = buildRequest(stream.headerList(), stream.bodyBytes());

    try std.testing.expectEqualStrings("POST", req.method);
    try std.testing.expectEqualStrings("/items", req.path);
    try std.testing.expectEqualStrings("page=2", req.query);
    try std.testing.expectEqualStrings("abc", req.body);
}

test "zix http2: stream_invoke, buildRequest without pseudo-headers falls back" {
    const stream = try testStream(1);
    defer std.testing.allocator.destroy(stream);

    const req = buildRequest(stream.headerList(), stream.bodyBytes());

    try std.testing.expectEqualStrings("GET", req.method);
    try std.testing.expectEqualStrings("/", req.path);
}

test "zix http2: stream_invoke, whole body reaches the handler" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const stream = try testStream(1);
    defer std.testing.allocator.destroy(stream);

    addHeader(stream, ":method", "POST");
    addHeader(stream, "content-length", "3");
    _ = stream.appendBody("abc");

    tl_calls = 0;
    invokeWhole(probeHandler, stream, fds[0], .{}, std.testing.io, frame.DEFAULT_MAX_FRAME_SIZE);

    try std.testing.expectEqual(@as(usize, 1), tl_calls);
    try std.testing.expectEqual(@as(usize, 3), tl_seen_body_len);
    try std.testing.expectEqualStrings("POST", tl_seen_method[0..tl_seen_method_len]);
    try std.testing.expectEqual(frame.FRAME_TYPE_HEADERS, try readFrameType(fds[1]));
}

test "zix http2: stream_invoke, short body is reset" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const stream = try testStream(1);
    defer std.testing.allocator.destroy(stream);

    addHeader(stream, "content-length", "100");
    _ = stream.appendBody("abc");

    tl_calls = 0;
    invokeWhole(probeHandler, stream, fds[0], .{}, std.testing.io, frame.DEFAULT_MAX_FRAME_SIZE);

    try std.testing.expectEqual(@as(usize, 0), tl_calls);
    try std.testing.expectEqual(frame.FRAME_TYPE_RST_STREAM, try readFrameType(fds[1]));
}

