//! ZIX Http1 SSE writer
//!
//! ### file: src/zix/tcp/http1/SseWriter.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Writes Server-Sent Events frames to a connection.
//! 
//! ### note:
//! 
//! n/a
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
const writer = @import("writer.zig");

// --------------------------------------------------------- //
// Fields:

fd: std.posix.fd_t,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// ZIX Http1 SSE writer error
pub const Error = error {
    ZixHttp1_SseWriter_BrokenPipe,
};

fn writeRaw(fd: std.posix.fd_t, bytes: []const u8) Error!void {
    writer.writeAllFD(fd, bytes) catch |err| switch (err) {
        error.ZixHttp1_Writer_BrokenPipe,
        error.ZixHttp1_Writer_HeadBuild,
        => return Error.ZixHttp1_SseWriter_BrokenPipe,
    };
}

/// Sends: data: <data>\n\n
pub fn writeEvent(self: Self, data: []const u8) Error!void {
    try writeRaw(self.fd, "data: ");
    try writeRaw(self.fd, data);
    try writeRaw(self.fd, "\n\n");
}

/// Sends: event: <event>\ndata: <data>\n\n
pub fn writeNamedEvent(self: Self, event: []const u8, data: []const u8) Error!void {
    try writeRaw(self.fd, "event: ");
    try writeRaw(self.fd, event);
    try writeRaw(self.fd, "\ndata: ");
    try writeRaw(self.fd, data);
    try writeRaw(self.fd, "\n\n");
}

/// Sends: : <text>\n  (comment / keepalive heartbeat)
pub fn comment(self: Self, text: []const u8) Error!void {
    try writeRaw(self.fd, ": ");
    try writeRaw(self.fd, text);
    try writeRaw(self.fd, "\n");
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../utils/socket/pair.zig");

test "zix http1: SseWriter, frames an event" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const sse = Self{ .fd = fds[0] };
    try sse.writeEvent("hello");
    try sse.comment("ping");

    var buf: [64]u8 = undefined;
    const n = try std.posix.read(fds[1], &buf);

    try std.testing.expectEqualStrings("data: hello\n\n: ping\n", buf[0..n]);
}

test "zix http1: SseWriter, frames a named event" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const sse = Self{ .fd = fds[0] };
    try sse.writeNamedEvent("tick", "1");

    var buf: [64]u8 = undefined;
    const n = try std.posix.read(fds[1], &buf);

    try std.testing.expectEqualStrings("event: tick\ndata: 1\n\n", buf[0..n]);
}

