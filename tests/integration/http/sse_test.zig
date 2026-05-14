//! Integration tests: SseWriter wire format using a real std.Io.Writer.fixed buffer.

const std = @import("std");
const zix = @import("zix");

test "zix integration: SseWriter writeEvent, data line wire format" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const sse = zix.Http.SseWriter{ .out = &w };
    try sse.writeEvent("ping");
    const expected = "data: ping\n\n";
    try std.testing.expectEqualSlices(u8, expected, buf[0..expected.len]);
}

test "zix integration: SseWriter writeNamedEvent, event + data lines wire format" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const sse = zix.Http.SseWriter{ .out = &w };
    try sse.writeNamedEvent("update", "99");
    const expected = "event: update\ndata: 99\n\n";
    try std.testing.expectEqualSlices(u8, expected, buf[0..expected.len]);
}

test "zix integration: SseWriter comment, comment line wire format" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const sse = zix.Http.SseWriter{ .out = &w };
    try sse.comment("keepalive");
    const expected = ": keepalive\n";
    try std.testing.expectEqualSlices(u8, expected, buf[0..expected.len]);
}
