//! Integration tests: SseWriter wire format verified over a connected descriptor pair.

const std = @import("std");
const zix = @import("zix");

/// A pair whose write end the writer targets and whose read end the assertion reads back.
/// This replaced a memfd, which only exists on Linux: the pair needs no seek and works anywhere.
fn makePair() !zix.utils.socket_pair.Pair {
    return zix.utils.socket_pair.Pair.open(std.testing.allocator);
}

// --------------------------------------------------------- //

test "zix integration: SseWriter writeEvent, data line wire format" {
    var pair = try makePair();
    defer pair.deinit();
    const fd = pair.fds[0];

    const sse = zix.Http.SseWriter{ .fd = fd };
    try sse.writeEvent("ping");

    var buf: [64]u8 = undefined;
    const n = try zix.utils.fd_io.readOnce(pair.fds[1], &buf);
    try std.testing.expectEqualStrings("data: ping\n\n", buf[0..n]);
}

test "zix integration: SseWriter writeNamedEvent, event + data lines wire format" {
    var pair = try makePair();
    defer pair.deinit();
    const fd = pair.fds[0];

    const sse = zix.Http.SseWriter{ .fd = fd };
    try sse.writeNamedEvent("update", "99");

    var buf: [64]u8 = undefined;
    const n = try zix.utils.fd_io.readOnce(pair.fds[1], &buf);
    try std.testing.expectEqualStrings("event: update\ndata: 99\n\n", buf[0..n]);
}

test "zix integration: SseWriter comment, comment line wire format" {
    var pair = try makePair();
    defer pair.deinit();
    const fd = pair.fds[0];

    const sse = zix.Http.SseWriter{ .fd = fd };
    try sse.comment("keepalive");

    var buf: [64]u8 = undefined;
    const n = try zix.utils.fd_io.readOnce(pair.fds[1], &buf);
    try std.testing.expectEqualStrings(": keepalive\n", buf[0..n]);
}
