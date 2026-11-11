//! ZIX Http2 send_best_effort
//!
//! ### file: src/zix/tcp/http2/send_best_effort.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Connection frames sent best effort: GOAWAY, RST_STREAM, WINDOW_UPDATE, 413.
//!
//! ### note:
//!
//! - A failed write is dropped on purpose. A broken socket shows up on the
//!   next read, and the connection loop ends there.
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
const control = @import("control.zig");
const writer = @import("writer.zig");

// --------------------------------------------------------- //
// Public:

/// Send GOAWAY, best effort.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// last_stream_id - u31 (the highest stream this server processed)
/// error_code - u32 (frame.ERR_* code)
///
/// Return:
/// - void
pub fn goaway(fd: std.posix.fd_t, last_stream_id: u31, error_code: u32) void {
    control.sendGoawayFD(fd, last_stream_id, error_code) catch |err| switch (err) {
        // Best effort: the connection is closing either way.
        error.ZixHttp2_Control_BrokenPipe,
        error.ZixHttp2_Control_TooManySettings,
        error.ZixHttp2_Control_UnexpectedEOF,
        error.ZixHttp2_Control_Overflow,
        error.ZixHttp2_Control_BufferFull,
        => {},
    };
}

/// Send RST_STREAM, best effort.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// sid - u31 (the stream to reset)
/// error_code - u32 (frame.ERR_* code)
///
/// Return:
/// - void
pub fn rstStream(fd: std.posix.fd_t, sid: u31, error_code: u32) void {
    control.sendRstStreamFD(fd, sid, error_code) catch |err| switch (err) {
        // Best effort: a broken socket shows up on the next read.
        error.ZixHttp2_Control_BrokenPipe,
        error.ZixHttp2_Control_TooManySettings,
        error.ZixHttp2_Control_UnexpectedEOF,
        error.ZixHttp2_Control_Overflow,
        error.ZixHttp2_Control_BufferFull,
        => {},
    };
}

/// Send WINDOW_UPDATE, best effort.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// sid - u31 (0 for the connection window, otherwise the stream)
/// increment - usize (bytes to credit, at most one frame payload)
///
/// Return:
/// - void
pub fn windowUpdate(fd: std.posix.fd_t, sid: u31, increment: usize) void {
    control.sendWindowUpdateFD(fd, sid, @intCast(increment)) catch |err| switch (err) {
        // Best effort: a broken socket shows up on the next read.
        error.ZixHttp2_Control_BrokenPipe,
        error.ZixHttp2_Control_TooManySettings,
        error.ZixHttp2_Control_UnexpectedEOF,
        error.ZixHttp2_Control_Overflow,
        error.ZixHttp2_Control_BufferFull,
        => {},
    };
}

/// Answer a stream with 413 and an empty body, best effort.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// sid - u31 (the stream to answer)
///
/// Return:
/// - void
pub fn sendTooLarge(fd: std.posix.fd_t, sid: u31) void {
    writer.sendResponseFD(fd, sid, 413, "text/plain", "") catch |err| switch (err) {
        // Best effort: a broken socket shows up on the next read.
        error.ZixHttp2_Writer_BrokenPipe,
        error.ZixHttp2_Writer_UnexpectedEOF,
        error.ZixHttp2_Writer_Overflow,
        error.ZixHttp2_Writer_BufferFull,
        => {},
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const builtin = @import("builtin");
const frame = @import("frame.zig");
const pair = @import("../../utils/socket/pair.zig");
const FrameHeader = @import("FrameHeader.zig");
const Header = @import("hpack/Header.zig");
const HpackDecoder = @import("hpack/HpackDecoder.zig");

fn isLinux() bool {
    if (comptime builtin.target.os.tag == .linux) return true;

    std.log.info("this test drives a Linux socket pair, test skipped", .{});

    return false;
}

/// Read one frame the sender wrote: its header and payload.
fn readFrame(fd: std.posix.fd_t, payload: []u8) !FrameHeader {
    var head: [frame.FRAME_HEADER_LEN]u8 = undefined;
    _ = try std.posix.read(fd, &head);

    const header = frame.parseFrameHeader(&head);
    if (header.length > 0) _ = try std.posix.read(fd, payload[0..header.length]);

    return header;
}

/// A descriptor no process has open, so every write to it fails.
const CLOSED_FD: i32 = -1;

test "zix http2: send_best_effort, goaway writes GOAWAY with the code" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    goaway(fds[1], 7, frame.ERR_PROTOCOL_ERROR);

    var payload: [64]u8 = undefined;
    const header = try readFrame(fds[0], &payload);

    try std.testing.expectEqual(frame.FRAME_TYPE_GOAWAY, header.frame_type);
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, payload[0..4], .big));
    try std.testing.expectEqual(
        frame.ERR_PROTOCOL_ERROR,
        std.mem.readInt(u32, payload[4..8], .big),
    );
}

test "zix http2: send_best_effort, rstStream writes RST_STREAM on the stream" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    rstStream(fds[1], 3, frame.ERR_REFUSED_STREAM);

    var payload: [64]u8 = undefined;
    const header = try readFrame(fds[0], &payload);

    try std.testing.expectEqual(frame.FRAME_TYPE_RST_STREAM, header.frame_type);
    try std.testing.expectEqual(@as(u31, 3), header.stream_id);
    try std.testing.expectEqual(
        frame.ERR_REFUSED_STREAM,
        std.mem.readInt(u32, payload[0..4], .big),
    );
}

test "zix http2: send_best_effort, windowUpdate writes the increment" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    windowUpdate(fds[1], 5, 1000);

    var payload: [64]u8 = undefined;
    const header = try readFrame(fds[0], &payload);

    try std.testing.expectEqual(frame.FRAME_TYPE_WINDOW_UPDATE, header.frame_type);
    try std.testing.expectEqual(@as(u31, 5), header.stream_id);
    try std.testing.expectEqual(@as(u32, 1000), std.mem.readInt(u32, payload[0..4], .big));
}

test "zix http2: send_best_effort, sendTooLarge answers 413 and ends the stream" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    sendTooLarge(fds[1], 1);

    var payload: [256]u8 = undefined;
    const header = try readFrame(fds[0], &payload);

    var decoder = HpackDecoder.init();
    var headers: [frame.MAX_HEADERS]Header = undefined;
    var scratch: [256]u8 = undefined;
    const count = try decoder.decode(payload[0..header.length], &headers, &scratch);

    try std.testing.expectEqual(frame.FRAME_TYPE_HEADERS, header.frame_type);
    try std.testing.expect((header.flags & frame.FLAG_END_STREAM) != 0);
    try std.testing.expectEqualStrings(":status", headers[0].name);
    try std.testing.expectEqualStrings("413", headers[0].value);
    try std.testing.expect(count >= 1);
}

test "zix http2: send_best_effort, a closed fd is ignored" {
    if (!isLinux()) return;

    goaway(CLOSED_FD, 0, frame.ERR_NO_ERROR);
    rstStream(CLOSED_FD, 1, frame.ERR_CANCEL);
    windowUpdate(CLOSED_FD, 0, 1);
    sendTooLarge(CLOSED_FD, 1);
}

