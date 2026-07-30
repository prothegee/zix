//! Integration tests: SseStream event parsing over a socketpair.

const std = @import("std");
const zix = @import("zix");

/// A connected pair for the tests below, portable across every supported platform.
fn makePair() ![2]std.posix.fd_t {
    const pair = try zix.utils.socket_pair.Pair.open(std.testing.allocator);

    return pair.fds;
}

fn closefd(fd: std.posix.fd_t) void {
    zix.utils.fd_io.close(fd);
}

// --------------------------------------------------------- //

test "zix integration: SseStream.next parses a data-only event" {
    const fds = try makePair();
    defer closefd(fds[0]);
    defer closefd(fds[1]);

    zix.utils.fd_io.writeAll(fds[1], "data: hello\n\n") catch {};

    var stream = zix.Http.SseStream{
        .fd = fds[0],
        .read_buf = undefined,
        .read_len = 0,
        .read_pos = 0,
    };

    var buf: [256]u8 = undefined;
    const event = try stream.next(&buf);

    try std.testing.expect(event != null);
    try std.testing.expectEqualStrings("hello", event.?.data);
    try std.testing.expectEqual(null, event.?.event);
    try std.testing.expectEqual(null, event.?.id);
    try std.testing.expectEqual(null, event.?.retry);
}

test "zix integration: SseStream.next parses a named event with data" {
    const fds = try makePair();
    defer closefd(fds[0]);
    defer closefd(fds[1]);

    zix.utils.fd_io.writeAll(fds[1], "event: update\ndata: 42\n\n") catch {};

    var stream = zix.Http.SseStream{
        .fd = fds[0],
        .read_buf = undefined,
        .read_len = 0,
        .read_pos = 0,
    };

    var buf: [256]u8 = undefined;
    const event = try stream.next(&buf);

    try std.testing.expect(event != null);
    try std.testing.expectEqualStrings("42", event.?.data);
    try std.testing.expectEqualStrings("update", event.?.event.?);
}

test "zix integration: SseStream.next joins multiple data lines with newline" {
    const fds = try makePair();
    defer closefd(fds[0]);
    defer closefd(fds[1]);

    zix.utils.fd_io.writeAll(fds[1], "data: line1\ndata: line2\n\n") catch {};

    var stream = zix.Http.SseStream{
        .fd = fds[0],
        .read_buf = undefined,
        .read_len = 0,
        .read_pos = 0,
    };

    var buf: [256]u8 = undefined;
    const event = try stream.next(&buf);

    try std.testing.expect(event != null);
    try std.testing.expectEqualStrings("line1\nline2", event.?.data);
}

test "zix integration: SseStream.next returns null on clean EOF with no data" {
    const fds = try makePair();
    defer closefd(fds[0]);

    closefd(fds[1]);

    var stream = zix.Http.SseStream{
        .fd = fds[0],
        .read_buf = undefined,
        .read_len = 0,
        .read_pos = 0,
    };

    var buf: [256]u8 = undefined;
    const event = try stream.next(&buf);

    try std.testing.expectEqual(null, event);
}

test "zix integration: SseStream.next parses id and retry fields" {
    const fds = try makePair();
    defer closefd(fds[0]);
    defer closefd(fds[1]);

    zix.utils.fd_io.writeAll(fds[1], "id: abc\nretry: 5000\ndata: payload\n\n") catch {};

    var stream = zix.Http.SseStream{
        .fd = fds[0],
        .read_buf = undefined,
        .read_len = 0,
        .read_pos = 0,
    };

    var buf: [256]u8 = undefined;
    const event = try stream.next(&buf);

    try std.testing.expect(event != null);
    try std.testing.expectEqualStrings("payload", event.?.data);
    try std.testing.expectEqualStrings("abc", event.?.id.?);
    try std.testing.expectEqual(@as(u32, 5000), event.?.retry.?);
}
