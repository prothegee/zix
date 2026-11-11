//! ZIX Http2 Stream
//!
//! ### file: src/zix/tcp/http2/Stream.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One request stream on a blocking HTTP/2 connection: decoded headers and body.
//!
//! ### note:
//!
//! - A stream is about 70 KiB, so a connection allocates its stream table once
//!   on the heap and reuses each entry. Never put one on the stack.
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
const frame = @import("frame.zig");
const Header = @import("hpack/Header.zig");
const StreamState = @import("stream_state.zig").StreamState;

// --------------------------------------------------------- //
// Fields:

id: u31,
state: StreamState,
headers: [frame.MAX_HEADERS]Header,
header_count: usize,
body: [BODY_BUF_SIZE]u8,
body_len: usize,
/// String storage the HPACK decoder writes header names and values into.
header_scratch: [HEADER_SCRATCH_SIZE]u8,
end_headers: bool,
end_stream: bool,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Request body bytes one stream can hold. A larger body is shed with 413.
pub const BODY_BUF_SIZE: usize = 64 * 1024;

/// HPACK string scratch per stream.
pub const HEADER_SCRATCH_SIZE: usize = 4096;

/// Reset the stream and open it for sid.
///
/// Param:
/// sid - u31 (the stream id from the HEADERS frame)
///
/// Return:
/// - void
pub fn open(self: *Self, sid: u31) void {
    self.* = std.mem.zeroes(Self);

    self.id = sid;
    self.state = .OPEN;
}

/// The headers decoded so far.
pub fn headerList(self: *const Self) []const Header {
    return self.headers[0..self.header_count];
}

/// The body bytes received so far.
pub fn bodyBytes(self: *const Self) []const u8 {
    return self.body[0..self.body_len];
}

/// Append DATA payload to the body.
///
/// Param:
/// data - []const u8 (one DATA frame payload, padding already removed)
///
/// Return:
/// - true when the bytes were appended
/// - false when they do not fit, nothing is appended
pub fn appendBody(self: *Self, data: []const u8) bool {
    if (data.len > self.body.len - self.body_len) return false;

    @memcpy(self.body[self.body_len..][0..data.len], data);
    self.body_len += data.len;

    return true;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn testStream() !*Self {
    return std.testing.allocator.create(Self);
}

test "zix http2: Stream, open resets and sets the id" {
    const stream = try testStream();
    defer std.testing.allocator.destroy(stream);

    stream.body_len = 9;
    stream.header_count = 3;
    stream.end_stream = true;
    stream.open(5);

    try std.testing.expectEqual(@as(u31, 5), stream.id);
    try std.testing.expectEqual(StreamState.OPEN, stream.state);
    try std.testing.expectEqual(@as(usize, 0), stream.body_len);
    try std.testing.expectEqual(@as(usize, 0), stream.header_count);
    try std.testing.expect(!stream.end_stream);
}

test "zix http2: Stream, appendBody accumulates bytes" {
    const stream = try testStream();
    defer std.testing.allocator.destroy(stream);

    stream.open(1);

    try std.testing.expect(stream.appendBody("ab"));
    try std.testing.expect(stream.appendBody("cd"));
    try std.testing.expectEqualStrings("abcd", stream.bodyBytes());
}

test "zix http2: Stream, appendBody past the cap appends nothing" {
    const stream = try testStream();
    defer std.testing.allocator.destroy(stream);

    stream.open(1);
    stream.body_len = BODY_BUF_SIZE - 1;

    try std.testing.expect(!stream.appendBody("xy"));
    try std.testing.expectEqual(BODY_BUF_SIZE - 1, stream.body_len);
    try std.testing.expect(stream.appendBody("x"));
    try std.testing.expectEqual(BODY_BUF_SIZE, stream.body_len);
}

test "zix http2: Stream, appendBody accepts an empty payload" {
    const stream = try testStream();
    defer std.testing.allocator.destroy(stream);

    stream.open(1);

    try std.testing.expect(stream.appendBody(""));
    try std.testing.expectEqual(@as(usize, 0), stream.bodyBytes().len);
}

test "zix http2: Stream, headerList covers header_count" {
    const stream = try testStream();
    defer std.testing.allocator.destroy(stream);

    stream.open(1);
    stream.headers[0] = .{
        .name = ":method",
        .value = "GET",
    };
    stream.header_count = 1;

    try std.testing.expectEqual(@as(usize, 1), stream.headerList().len);
    try std.testing.expectEqualStrings("GET", stream.headerList()[0].value);
}

