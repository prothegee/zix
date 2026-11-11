//! ZIX Http2 Response
//!
//! ### file: src/zix/tcp/http2/Response.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Handler write path for one HTTP/2 stream: status, content type, and body.
//!
//! ### note:
//!
//! A thin builder over writer.sendResponseFD, so the wire bytes match a handler
//! that calls the writer directly.
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
const builtin = @import("builtin");
const writer = @import("writer.zig");

// --------------------------------------------------------- //
// Fields:

/// Connection fd. Every write lands here.
fd: std.posix.fd_t,
/// HTTP/2 stream id this response belongs to.
sid: u31,
status: u16 = 200,
/// Content-Type. Empty omits the header.
content_type: []const u8 = "",
/// Set once a send is attempted, so the engine does not answer a second time
/// when the handler then returns an error.
sent: bool = false,
/// Body bytes handed to the last send, for the access record.
///
/// Note:
/// - A handler that frames its own bytes through the writer is not counted.
bytes_written: usize = 0,

const Self = @This();

// --------------------------------------------------------- //
// Private:

fn writerError(err: writer.Error) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixHttp2_Writer_BrokenPipe => Error.ZixHttp2_Response_BrokenPipe,
        error.ZixHttp2_Writer_UnexpectedEOF => Error.ZixHttp2_Response_UnexpectedEOF,
        error.ZixHttp2_Writer_Overflow => Error.ZixHttp2_Response_Overflow,
        error.ZixHttp2_Writer_BufferFull => Error.ZixHttp2_Response_BufferFull,
    };
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 response error
pub const Error = error {
    ZixHttp2_Response_BrokenPipe,
    ZixHttp2_Response_UnexpectedEOF,
    ZixHttp2_Response_Overflow,
    ZixHttp2_Response_BufferFull,
};

/// Set the response status code.
pub fn setStatus(self: *Self, status: u16) void {
    self.status = status;
}

/// Set the Content-Type.
pub fn setContentType(self: *Self, content_type: []const u8) void {
    self.content_type = content_type;
}

/// Send body with the current status and Content-Type.
///
/// Param:
/// body - []const u8 (response body, may be empty)
///
/// Return:
/// - void when the response was sent
/// - Error.ZixHttp2_Response_BufferFull when the header block does not fit
/// - Error.ZixHttp2_Response_BrokenPipe on a write error
pub fn send(self: *Self, body: []const u8) Error!void {
    self.sent = true;
    self.bytes_written = body.len;

    return writer.sendResponseFD(
        self.fd,
        self.sid,
        self.status,
        self.content_type,
        body,
    ) catch |err| writerError(err);
}

/// Send body as application/json.
pub fn sendJson(self: *Self, body: []const u8) Error!void {
    self.content_type = "application/json";

    return self.send(body);
}

/// Send body as text/plain.
pub fn sendText(self: *Self, body: []const u8) Error!void {
    self.content_type = "text/plain";

    return self.send(body);
}

/// Send a 204 No Content response with an empty body.
pub fn sendNoContent(self: *Self) Error!void {
    self.status = 204;

    return self.send("");
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../utils/socket/pair.zig");

const TEST_FD: std.posix.fd_t = if (builtin.os.tag == .windows)
    std.os.windows.INVALID_HANDLE_VALUE
else
    -1;

const TestPair = struct {
    fds: [2]std.posix.fd_t,

    fn open() !TestPair {
        var fds: [2]std.posix.fd_t = undefined;
        try pair.open(std.testing.io, &fds);

        return .{ .fds = fds };
    }

    fn close(self: TestPair) void {
        _ = std.posix.system.close(self.fds[0]);
        _ = std.posix.system.close(self.fds[1]);
    }

    fn readAll(self: TestPair, buf: []u8) ![]u8 {
        const got = try std.posix.read(self.fds[0], buf);

        return buf[0..got];
    }
};

test "zix http2: Response, defaults to 200 with no content type" {
    const res: Self = .{
        .fd = TEST_FD,
        .sid = 3,
    };

    try std.testing.expectEqual(@as(u16, 200), res.status);
    try std.testing.expectEqual(@as(u31, 3), res.sid);
    try std.testing.expectEqualStrings("", res.content_type);
    try std.testing.expect(!res.sent);
}

test "zix http2: Response, setStatus changes the status" {
    var res: Self = .{
        .fd = TEST_FD,
        .sid = 1,
    };
    res.setStatus(404);

    try std.testing.expectEqual(@as(u16, 404), res.status);
}

test "zix http2: Response, setContentType changes the content type" {
    var res: Self = .{
        .fd = TEST_FD,
        .sid = 1,
    };
    res.setContentType("text/html");

    try std.testing.expectEqualStrings("text/html", res.content_type);
}

test "zix http2: Response, send matches writer.sendResponseFD" {
    const via_res = try TestPair.open();
    defer via_res.close();

    const via_writer = try TestPair.open();
    defer via_writer.close();

    var res: Self = .{
        .fd = via_res.fds[1],
        .sid = 1,
    };
    res.setStatus(201);
    res.setContentType("text/plain");
    try res.send("hello");

    try writer.sendResponseFD(via_writer.fds[1], 1, 201, "text/plain", "hello");

    var res_buf: [256]u8 = undefined;
    var writer_buf: [256]u8 = undefined;

    try std.testing.expectEqualSlices(
        u8,
        try via_writer.readAll(&writer_buf),
        try via_res.readAll(&res_buf),
    );
}

test "zix http2: Response, send records sent and bytes_written" {
    const test_pair = try TestPair.open();
    defer test_pair.close();

    var res: Self = .{
        .fd = test_pair.fds[1],
        .sid = 1,
    };
    try res.send("hello");

    try std.testing.expect(res.sent);
    try std.testing.expectEqual(@as(usize, 5), res.bytes_written);
}

test "zix http2: Response, sendJson sets application/json" {
    const test_pair = try TestPair.open();
    defer test_pair.close();

    var res: Self = .{
        .fd = test_pair.fds[1],
        .sid = 1,
    };
    try res.sendJson("{\"ok\":true}");

    try std.testing.expectEqualStrings("application/json", res.content_type);
}

test "zix http2: Response, sendText sets text/plain" {
    const test_pair = try TestPair.open();
    defer test_pair.close();

    var res: Self = .{
        .fd = test_pair.fds[1],
        .sid = 1,
    };
    try res.sendText("hi");

    try std.testing.expectEqualStrings("text/plain", res.content_type);
}

test "zix http2: Response, sendNoContent sets 204 with an empty body" {
    const test_pair = try TestPair.open();
    defer test_pair.close();

    var res: Self = .{
        .fd = test_pair.fds[1],
        .sid = 1,
    };
    try res.sendNoContent();

    try std.testing.expectEqual(@as(u16, 204), res.status);
    try std.testing.expectEqual(@as(usize, 0), res.bytes_written);
}

test "zix http2: Response, send on a closed peer is BrokenPipe" {
    const test_pair = try TestPair.open();
    _ = std.posix.system.close(test_pair.fds[0]);
    defer _ = std.posix.system.close(test_pair.fds[1]);

    var res: Self = .{
        .fd = test_pair.fds[1],
        .sid = 1,
    };

    try std.testing.expectError(Error.ZixHttp2_Response_BrokenPipe, res.send("x"));
    try std.testing.expect(res.sent);
}

