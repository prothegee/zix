//! Integration tests: zix.Http SSE (Server-Sent Events)
//! Covers public API surface added in http_sse implementation:
//!   - TEXT_EVENT_STREAM content type string value
//!   - SseWriter wire format for all three write methods (via public zix.Http.SseWriter)
//!   - Response.streaming field defaults to false (no live server needed)

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

test "zix integration: TEXT_EVENT_STREAM content type string" {
    const ct: zix.Http.ContentType = .TEXT_EVENT_STREAM;
    try std.testing.expectEqualStrings("text/event-stream", ct.asString());
}

test "zix integration: SseWriter writeEvent wire format" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const sse = zix.Http.SseWriter{ .out = &w };
    try sse.writeEvent("ping");
    const expected = "data: ping\n\n";
    try std.testing.expectEqualSlices(u8, expected, buf[0..expected.len]);
}

test "zix integration: SseWriter writeNamedEvent wire format" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const sse = zix.Http.SseWriter{ .out = &w };
    try sse.writeNamedEvent("update", "99");
    const expected = "event: update\ndata: 99\n\n";
    try std.testing.expectEqualSlices(u8, expected, buf[0..expected.len]);
}

test "zix integration: SseWriter comment wire format" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const sse = zix.Http.SseWriter{ .out = &w };
    try sse.comment("keepalive");
    const expected = ": keepalive\n";
    try std.testing.expectEqualSlices(u8, expected, buf[0..expected.len]);
}

test "zix integration: Response.streaming defaults to false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const res = zix.Http.Response.init(undefined, undefined, arena.allocator(), 32);
    try std.testing.expect(!res.streaming);
}
