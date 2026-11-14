//! ZIX http1 tls feed state
//!
//! ### file: src/zix/tcp/http1/tls_feed/State.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Request bytes held across TLS records for one connection, and the rule that
//! decides when a request is served, waits, or is refused.
//!
//! ### note:
//!
//! A body that cannot fit the buffer is never buffered: the head is parked, the
//! body bytes are counted as they arrive and dropped, and the parked request is
//! served once the count reaches the declared length. The buffer bounds the
//! head, not the body, so connection memory stays flat at any upload size.
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
const Step = @import("step.zig").Step;

// --------------------------------------------------------- //
// Fields:

/// Live bytes in the caller's buffer.
filled: usize = 0,
/// Body bytes still owed by the peer for a body too large to buffer.
drain: usize = 0,
/// Body bytes of the draining request counted so far.
drain_received: usize = 0,
/// Head bytes parked at the front of the buffer while the body drains.
/// Non-zero means a request waits for its body to finish arriving.
pending_head_len: usize = 0,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Whether a request was part way through arriving.
///
/// Note:
/// - A peer that hangs up here is owed an answer. One that leaves between
///   requests is owed nothing.
///
/// Return:
/// - bool
pub fn inFlight(self: Self) bool {
    return self.filled > 0 or self.pending_head_len > 0;
}

/// Take body bytes for a draining request: two adds and no copy.
///
/// Param:
/// plaintext - []const u8 (bytes just decrypted)
///
/// Return:
/// - []const u8 (what is left after the body took its share)
pub fn takeDrain(self: *Self, plaintext: []const u8) []const u8 {
    const taken = @min(plaintext.len, self.drain);
    self.drain -= taken;
    self.drain_received += taken;

    return plaintext[taken..];
}

/// Expose the parked head again once the drain reaches zero, so the next
/// classify serves the request the drain was for.
pub fn releaseParked(self: *Self) void {
    self.filled = self.pending_head_len;
}

/// Copy what fits of an arriving chunk into the buffer.
///
/// Note:
/// - A chunk can be larger than the buffer, so the caller loops: copy what
///   fits, serve what completed, come back for the rest.
///
/// Param:
/// buf - []u8 (the connection's request buffer)
/// plaintext - []const u8 (bytes just decrypted)
///
/// Return:
/// - []const u8 (what did not fit, empty when it all did)
pub fn fill(self: *Self, buf: []u8, plaintext: []const u8) []const u8 {
    const take = @min(plaintext.len, buf.len - self.filled);
    @memcpy(buf[self.filled..][0..take], plaintext[0..take]);
    self.filled += take;

    return plaintext[take..];
}

/// Whether the buffer is full with no whole request in it. Only an oversized
/// head causes this, because a body drains instead.
pub fn headOverflowed(self: Self, buf_len: usize) bool {
    return self.filled >= buf_len;
}

/// Decide what to do with the request at the front of the buffer.
///
/// Note:
/// - Call only with a fully parsed head. An incomplete head is the caller's
///   wait, since the parser reports it.
/// - The parked branch comes first: a request re-entering after its drain has
///   its body counted already.
///
/// Param:
/// body_offset - usize (bytes of head, the body starts here)
/// content_length - usize (the declared body length)
/// buf_len - usize (capacity of the connection's request buffer)
/// max_request_body - usize (declared bodies past this are refused, 0 removes the check)
///
/// Return:
/// - Step
pub fn classify(
    self: *Self,
    body_offset: usize,
    content_length: usize,
    buf_len: usize,
    max_request_body: usize,
) Step {
    if (self.pending_head_len > 0) {
        const received = self.drain_received;
        self.pending_head_len = 0;
        self.drain_received = 0;

        return .{
            .SERVE = .{
                .body_len = 0,
                .received = received,
                .request_len = body_offset,
            },
        };
    }

    // Refused on the declared length alone, before a byte of the body is counted.
    if (max_request_body != 0 and content_length > max_request_body) return .REFUSE_BODY;

    const total = body_offset + content_length;

    if (total <= self.filled) {
        return .{
            .SERVE = .{
                .body_len = content_length,
                .received = content_length,
                .request_len = total,
            },
        };
    }

    if (total > buf_len) {
        // Larger than the buffer can ever hold: park the head, count the rest.
        const present_body = self.filled - body_offset;
        self.drain = content_length - present_body;
        self.drain_received = present_body;
        self.pending_head_len = body_offset;
        self.filled = 0;
    }

    return .WAIT;
}

/// Drop a served request, keeping pipelined bytes at the front.
///
/// Param:
/// buf - []u8 (the connection's request buffer)
/// request_len - usize (bytes the served request consumed)
pub fn consume(self: *Self, buf: []u8, request_len: usize) void {
    const remaining = self.filled - request_len;
    if (remaining > 0) {
        std.mem.copyForwards(u8, buf[0..remaining], buf[request_len..self.filled]);
    }

    self.filled = remaining;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const HEAD_FORMAT = "POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n";

/// What a driven feed observed.
const Observed = struct {
    served: usize = 0,
    last_received: u64 = 0,
    last_body_len: usize = 0,
    refused_body: bool = false,
    refused_head: bool = false,
    peak_filled: usize = 0,
    bytes_copied: u64 = 0,
};

const ParsedTestHead = struct {
    body_offset: usize,
    content_length: usize,
};

fn headLen(body_len: usize) !usize {
    var probe: [128]u8 = undefined;
    const head = try std.fmt.bufPrint(&probe, HEAD_FORMAT, .{body_len});

    return head.len;
}

fn buildRequest(buf: []u8, body_len: usize) ![]const u8 {
    const head = try std.fmt.bufPrint(buf, HEAD_FORMAT, .{body_len});
    @memset(buf[head.len..][0..body_len], 'A');

    return buf[0 .. head.len + body_len];
}

/// Minimal head parse: what is under test is the decision after it.
fn testParse(bytes: []const u8) ?ParsedTestHead {
    const terminator = std.mem.indexOf(u8, bytes, "\r\n\r\n") orelse return null;

    var content_length: usize = 0;
    var headers = std.mem.splitSequence(u8, bytes[0..terminator], "\r\n");
    while (headers.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) continue;

        const value = std.mem.trim(u8, line[colon + 1 ..], " ");
        content_length = std.fmt.parseInt(usize, value, 10) catch |err| switch (err) {
            else => 0,
        };
    }

    return .{
        .body_offset = terminator + 4,
        .content_length = content_length,
    };
}

/// Drive a whole request through the state, in chunks, the way both TLS paths do.
fn driveFeed(
    state: *Self,
    buf: []u8,
    bytes: []const u8,
    chunk: usize,
    max_body: usize,
) Observed {
    var seen: Observed = .{};
    var offset: usize = 0;

    while (offset < bytes.len) {
        const end = @min(offset + chunk, bytes.len);
        var rest = bytes[offset..end];
        offset = end;

        while (true) {
            if (state.drain > 0) {
                rest = state.takeDrain(rest);
                if (state.drain > 0) break;

                state.releaseParked();
            } else {
                if (rest.len == 0) break;

                if (state.headOverflowed(buf.len)) {
                    seen.refused_head = true;

                    return seen;
                }

                const before = state.filled;
                rest = state.fill(buf, rest);
                seen.bytes_copied += state.filled - before;
                seen.peak_filled = @max(seen.peak_filled, state.filled);
            }

            while (state.filled > 0) {
                const parsed = testParse(buf[0..state.filled]) orelse break;
                const step = state.classify(
                    parsed.body_offset,
                    parsed.content_length,
                    buf.len,
                    max_body,
                );

                switch (step) {
                    .SERVE => |serve| {
                        seen.served += 1;
                        seen.last_received = serve.received;
                        seen.last_body_len = serve.body_len;
                        state.consume(buf, serve.request_len);
                    },
                    .WAIT => break,
                    .REFUSE_BODY => {
                        seen.refused_body = true;

                        return seen;
                    },
                    .REFUSE_HEAD => {
                        seen.refused_head = true;

                        return seen;
                    },
                }
            }
        }
    }

    return seen;
}

test "zix http1: State, serves a body that fits the buffer" {
    var buf: [4096]u8 = undefined;
    var wire: [4096]u8 = undefined;
    var state: Self = .{};

    const seen = driveFeed(&state, &buf, try buildRequest(&wire, 100), 64, 0);

    try std.testing.expectEqual(@as(usize, 1), seen.served);
    try std.testing.expectEqual(@as(u64, 100), seen.last_received);
    try std.testing.expectEqual(@as(usize, 100), seen.last_body_len);
}

test "zix http1: State, counts a body past the buffer instead of holding it" {
    const body_len: usize = 190000;

    var buf: [1024]u8 = undefined;
    const wire = try std.testing.allocator.alloc(u8, body_len + 256);
    defer std.testing.allocator.free(wire);

    var state: Self = .{};
    const seen = driveFeed(&state, &buf, try buildRequest(wire, body_len), 16384, 0);

    try std.testing.expectEqual(@as(usize, 1), seen.served);
    try std.testing.expectEqual(@as(u64, body_len), seen.last_received);
    try std.testing.expectEqual(@as(usize, 0), seen.last_body_len);
    try std.testing.expect(seen.bytes_copied <= buf.len);
}

test "zix http1: State, holds the boundary body" {
    var wire: [4096]u8 = undefined;

    var exact: usize = 1024 - try headLen(1024);
    while (try headLen(exact) + exact != 1024) exact = 1024 - try headLen(exact);

    var buf: [1024]u8 = undefined;
    var state: Self = .{};
    const seen = driveFeed(&state, &buf, try buildRequest(&wire, exact), 512, 0);

    try std.testing.expectEqual(@as(usize, 1), seen.served);
    try std.testing.expectEqual(exact, seen.last_body_len);
}

test "zix http1: State, drains a body one byte past the boundary" {
    var wire: [4096]u8 = undefined;

    var exact: usize = 1024 - try headLen(1024);
    while (try headLen(exact) + exact != 1024) exact = 1024 - try headLen(exact);

    var buf: [1024]u8 = undefined;
    var state: Self = .{};
    const seen = driveFeed(&state, &buf, try buildRequest(&wire, exact + 1), 512, 0);

    try std.testing.expectEqual(@as(usize, 1), seen.served);
    try std.testing.expectEqual(@as(usize, 0), seen.last_body_len);
    try std.testing.expectEqual(@as(u64, exact + 1), seen.last_received);
}

test "zix http1: State, keeps a request pipelined behind a drained body" {
    const body_len: usize = 60000;
    const follow = "GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n";

    var buf: [1024]u8 = undefined;
    const wire = try std.testing.allocator.alloc(u8, body_len + 256 + follow.len);
    defer std.testing.allocator.free(wire);

    var state: Self = .{};
    const upload = try buildRequest(wire, body_len);
    @memcpy(wire[upload.len..][0..follow.len], follow);

    const seen = driveFeed(&state, &buf, wire[0 .. upload.len + follow.len], 16384, 0);

    try std.testing.expectEqual(@as(usize, 2), seen.served);
    try std.testing.expectEqual(@as(u64, 0), seen.last_received);
}

test "zix http1: State, refuses a declared body past the limit" {
    var buf: [1024]u8 = undefined;
    var wire: [4096]u8 = undefined;
    var state: Self = .{};

    const head = try std.fmt.bufPrint(&wire, HEAD_FORMAT, .{65536});
    const seen = driveFeed(&state, &buf, head, 512, 8192);

    try std.testing.expect(seen.refused_body);
    try std.testing.expectEqual(@as(usize, 0), seen.served);
    try std.testing.expectEqual(@as(usize, 0), state.drain);
}

test "zix http1: State, refuses a head larger than the buffer" {
    var buf: [128]u8 = undefined;
    var state: Self = .{};

    var long_head: [512]u8 = undefined;
    @memset(&long_head, 'H');

    const seen = driveFeed(&state, &buf, &long_head, 512, 0);

    try std.testing.expect(seen.refused_head);
    try std.testing.expectEqual(@as(usize, 0), seen.served);
}

test "zix http1: State, answers the same however the records were chopped" {
    const body_len: usize = 40000;

    const wire = try std.testing.allocator.alloc(u8, body_len + 256);
    defer std.testing.allocator.free(wire);

    for ([_]usize{ 1, 7, 512, 16384, 65536 }) |chunk| {
        var buf: [1024]u8 = undefined;
        var state: Self = .{};

        const seen = driveFeed(&state, &buf, try buildRequest(wire, body_len), chunk, 0);

        try std.testing.expectEqual(@as(usize, 1), seen.served);
        try std.testing.expectEqual(@as(u64, body_len), seen.last_received);
        try std.testing.expect(seen.peak_filled <= buf.len);
    }
}

test "zix http1: State, holds the same memory for 50 KB and 2 MiB uploads" {
    const small_body: usize = 50000;
    const large_body: usize = 2 * 1024 * 1024;

    const wire = try std.testing.allocator.alloc(u8, large_body + 256);
    defer std.testing.allocator.free(wire);

    var buf: [1024]u8 = undefined;
    var small_state: Self = .{};
    const small_seen = driveFeed(
        &small_state, &buf, try buildRequest(wire, small_body), 16384, 0,
    );

    var large_state: Self = .{};
    const large_seen = driveFeed(
        &large_state, &buf, try buildRequest(wire, large_body), 16384, 0,
    );

    try std.testing.expectEqual(@as(u64, large_body), large_seen.last_received);
    try std.testing.expect(large_seen.peak_filled - small_seen.peak_filled <= 2);
}

test "zix http1: State, reports in flight only while a request is arriving" {
    var state: Self = .{};
    try std.testing.expect(!state.inFlight());

    state.filled = 40;
    try std.testing.expect(state.inFlight());

    state.filled = 0;
    state.pending_head_len = 49;
    try std.testing.expect(state.inFlight());
}

test "zix http1: State, drain takes only the body" {
    var state: Self = .{
        .drain = 10,
        .pending_head_len = 49,
    };

    const rest = state.takeDrain("0123456789GET /ping");

    try std.testing.expectEqual(@as(usize, 0), state.drain);
    try std.testing.expectEqual(@as(usize, 10), state.drain_received);
    try std.testing.expectEqualStrings("GET /ping", rest);
}

test "zix http1: State, consume slides pipelined bytes to the front" {
    var buf: [16]u8 = undefined;
    @memcpy(buf[0..10], "aaaabbbbbb");
    var state: Self = .{ .filled = 10 };

    state.consume(&buf, 4);

    try std.testing.expectEqual(@as(usize, 6), state.filled);
    try std.testing.expectEqualStrings("bbbbbb", buf[0..6]);
}

