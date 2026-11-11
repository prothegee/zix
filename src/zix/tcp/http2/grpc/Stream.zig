//! ZIX Http2 Grpc Stream
//!
//! ### file: src/zix/tcp/http2/grpc/Stream.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One gRPC request stream: decoded headers and the buffered body.
//!
//! ### note:
//!
//! body and header_scratch are borrowed slices sized from ServeOpts, so the
//! fixed part stays small whatever max_body is. The owner sets them before
//! the first open.
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
const frame = @import("../frame.zig");
const Header = @import("../hpack/Header.zig");
const StreamState = @import("../stream_state.zig").StreamState;

// --------------------------------------------------------- //
// Fields:

id: u31 = 0,
state: StreamState = .IDLE,
headers: [frame.MAX_HEADERS]Header = undefined,
header_count: usize = 0,
/// Body storage, borrowed from the owner.
body: []u8 = &.{},
body_len: usize = 0,
/// HPACK string storage for headers, borrowed from the owner.
header_scratch: []u8 = &.{},
end_headers: bool = false,
end_stream: bool = false,
/// Freelist link, valid only while the stream sits idle in a pool.
next_free: ?*Self = null,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Reset for a new stream id. The borrowed buffers stay.
pub fn open(self: *Self, sid: u31) void {
    self.id = sid;
    self.state = .OPEN;
    self.header_count = 0;
    self.body_len = 0;
    self.end_headers = false;
    self.end_stream = false;
}

/// The decoded headers.
pub fn headerList(self: *const Self) []const Header {
    return self.headers[0..self.header_count];
}

/// The body bytes received so far.
pub fn bodyBytes(self: *const Self) []const u8 {
    return self.body[0..self.body_len];
}

/// Append DATA bytes to the body.
///
/// Param:
/// data - []const u8 (DATA payload, padding removed)
///
/// Return:
/// - bool (false when data does not fit, nothing is copied)
pub fn appendBody(self: *Self, data: []const u8) bool {
    if (data.len > self.body.len - self.body_len) return false;

    @memcpy(self.body[self.body_len..][0..data.len], data);
    self.body_len += data.len;

    return true;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 grpc: Stream, defaults to IDLE and empty" {
    const stream: Self = .{};

    try std.testing.expectEqual(StreamState.IDLE, stream.state);
    try std.testing.expectEqual(@as(usize, 0), stream.body.len);
    try std.testing.expect(stream.next_free == null);
}

test "zix http2 grpc: Stream, open resets the request" {
    var body: [8]u8 = undefined;
    var stream: Self = .{
        .body = &body,
        .body_len = 3,
        .header_count = 2,
        .end_headers = true,
        .end_stream = true,
    };

    stream.open(5);

    try std.testing.expectEqual(@as(u31, 5), stream.id);
    try std.testing.expectEqual(StreamState.OPEN, stream.state);
    try std.testing.expectEqual(@as(usize, 0), stream.body_len);
    try std.testing.expectEqual(@as(usize, 0), stream.header_count);
    try std.testing.expect(!stream.end_headers);
    try std.testing.expect(!stream.end_stream);
    try std.testing.expectEqual(@as(usize, 8), stream.body.len);
}

test "zix http2 grpc: Stream, appendBody collects the body" {
    var body: [8]u8 = undefined;
    var stream: Self = .{
        .body = &body,
    };

    try std.testing.expect(stream.appendBody("abc"));
    try std.testing.expect(stream.appendBody("de"));

    try std.testing.expectEqualStrings("abcde", stream.bodyBytes());
}

test "zix http2 grpc: Stream, appendBody past the cap copies nothing" {
    var body: [4]u8 = undefined;
    var stream: Self = .{
        .body = &body,
    };

    try std.testing.expect(stream.appendBody("abc"));
    try std.testing.expect(!stream.appendBody("de"));

    try std.testing.expectEqualStrings("abc", stream.bodyBytes());
}

test "zix http2 grpc: Stream, headerList covers the decoded headers" {
    var stream: Self = .{};
    stream.headers[0] = .{
        .name = ":path",
        .value = "/svc.Svc/Method",
    };
    stream.header_count = 1;

    try std.testing.expectEqual(@as(usize, 1), stream.headerList().len);
    try std.testing.expectEqualStrings(":path", stream.headerList()[0].name);
}

