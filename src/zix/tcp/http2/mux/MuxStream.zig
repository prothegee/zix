//! ZIX Http2 mux MuxStream
//!
//! ### file: src/zix/tcp/http2/mux/MuxStream.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One request stream on a mux connection: decoded headers, body, send window.
//!
//! ### note:
//!
//! - The body and header scratch buffers belong to the per-worker pool. They
//!   are allocated once and kept across borrows, reset never frees them.
//! - pending_body points into memory that must outlive the stream (a process
//!   lifetime cache). The stream stays borrowed until it drains.
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
/// String storage the HPACK decoder writes header names and values into.
header_scratch: []u8 = &.{},
body: []u8 = &.{},
body_len: usize = 0,
end_headers: bool = false,
end_stream: bool = false,
/// The peer's remaining receive window for this stream (RFC 7540 section 6.9).
send_window: i64 = frame.DEFAULT_INITIAL_WINDOW,
/// Unsent tail of a response body that a send window held back.
pending_body: []const u8 = &.{},
/// Whether END_STREAM rides the last frame of pending_body.
pending_end: bool = false,
/// Pool freelist link, valid only while the stream sits idle in the pool.
next_free: ?*Self = null,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Reset every field to its default, keeping the two pooled buffers.
pub fn reset(self: *Self) void {
    const body = self.body;
    const header_scratch = self.header_scratch;

    self.* = .{};
    self.body = body;
    self.header_scratch = header_scratch;
}

/// Reset the stream and open it for sid.
///
/// Param:
/// sid - u31 (the stream id from the HEADERS frame)
/// send_window - i64 (the peer's SETTINGS_INITIAL_WINDOW_SIZE)
///
/// Return:
/// - void
pub fn open(self: *Self, sid: u31, send_window: i64) void {
    self.reset();

    self.id = sid;
    self.state = .OPEN;
    self.send_window = send_window;
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

/// Whether a response body is waiting for a window to grow.
pub fn isParked(self: *const Self) bool {
    return self.pending_body.len > 0;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn testStream(body: []u8, scratch: []u8) Self {
    return .{
        .body = body,
        .header_scratch = scratch,
    };
}

test "zix http2 mux: MuxStream, defaults read as an idle stream" {
    const stream: Self = .{};

    try std.testing.expectEqual(StreamState.IDLE, stream.state);
    try std.testing.expectEqual(@as(i64, frame.DEFAULT_INITIAL_WINDOW), stream.send_window);
    try std.testing.expect(!stream.isParked());
}

test "zix http2 mux: MuxStream, reset keeps the pooled buffers" {
    var body: [8]u8 = undefined;
    var scratch: [4]u8 = undefined;
    var stream = testStream(&body, &scratch);

    stream.id = 9;
    stream.body_len = 3;
    stream.pending_body = "tail";
    stream.reset();

    try std.testing.expectEqual(@as(u31, 0), stream.id);
    try std.testing.expectEqual(@as(usize, 0), stream.body_len);
    try std.testing.expect(!stream.isParked());
    try std.testing.expectEqual(@as(usize, 8), stream.body.len);
    try std.testing.expectEqual(@as(usize, 4), stream.header_scratch.len);
}

test "zix http2 mux: MuxStream, open sets the id and send window" {
    var body: [8]u8 = undefined;
    var scratch: [4]u8 = undefined;
    var stream = testStream(&body, &scratch);

    stream.open(5, 100);

    try std.testing.expectEqual(@as(u31, 5), stream.id);
    try std.testing.expectEqual(StreamState.OPEN, stream.state);
    try std.testing.expectEqual(@as(i64, 100), stream.send_window);
}

test "zix http2 mux: MuxStream, appendBody fills the buffer exactly" {
    var body: [4]u8 = undefined;
    var scratch: [4]u8 = undefined;
    var stream = testStream(&body, &scratch);

    try std.testing.expect(stream.appendBody("ab"));
    try std.testing.expect(stream.appendBody("cd"));
    try std.testing.expectEqualStrings("abcd", stream.bodyBytes());
}

test "zix http2 mux: MuxStream, appendBody past the buffer appends nothing" {
    var body: [4]u8 = undefined;
    var scratch: [4]u8 = undefined;
    var stream = testStream(&body, &scratch);

    try std.testing.expect(stream.appendBody("abc"));
    try std.testing.expect(!stream.appendBody("de"));
    try std.testing.expectEqualStrings("abc", stream.bodyBytes());
}

test "zix http2 mux: MuxStream, headerList is empty before decode" {
    const stream: Self = .{};

    try std.testing.expectEqual(@as(usize, 0), stream.headerList().len);
}

