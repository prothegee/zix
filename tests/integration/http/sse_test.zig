//! Integration tests: SseWriter wire format verified via an in-memory fd.

const std = @import("std");
const zix = @import("zix");

fn makeMemFd() !std.posix.fd_t {
    return std.posix.memfd_create("sse_test", std.os.linux.MFD.CLOEXEC);
}

fn seekToStart(fd: std.posix.fd_t) void {
    _ = std.posix.system.lseek(fd, 0, std.os.linux.SEEK.SET);
}

fn closefd(fd: std.posix.fd_t) void {
    _ = std.posix.system.close(fd);
}

// --------------------------------------------------------- //

test "zix integration: SseWriter writeEvent, data line wire format" {
    const fd = try makeMemFd();
    defer closefd(fd);

    const sse = zix.Http.SseWriter{ .fd = fd };
    try sse.writeEvent("ping");

    seekToStart(fd);
    var buf: [64]u8 = undefined;
    const n = try std.posix.read(fd, &buf);
    try std.testing.expectEqualStrings("data: ping\n\n", buf[0..n]);
}

test "zix integration: SseWriter writeNamedEvent, event + data lines wire format" {
    const fd = try makeMemFd();
    defer closefd(fd);

    const sse = zix.Http.SseWriter{ .fd = fd };
    try sse.writeNamedEvent("update", "99");

    seekToStart(fd);
    var buf: [64]u8 = undefined;
    const n = try std.posix.read(fd, &buf);
    try std.testing.expectEqualStrings("event: update\ndata: 99\n\n", buf[0..n]);
}

test "zix integration: SseWriter comment, comment line wire format" {
    const fd = try makeMemFd();
    defer closefd(fd);

    const sse = zix.Http.SseWriter{ .fd = fd };
    try sse.comment("keepalive");

    seekToStart(fd);
    var buf: [64]u8 = undefined;
    const n = try std.posix.read(fd, &buf);
    try std.testing.expectEqualStrings(": keepalive\n", buf[0..n]);
}
