//! ZIX http1 websocket pump
//!
//! ### file: src/zix/tcp/http1/websocket/pump.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The WebSocket frame loop: one pass for .EPOLL, a staged pass for .URING,
//! and a blocking loop for .ASYNC.
//!
//! ### note:
//!
//! Every model runs the same frame loop: text and binary go to on_frame, ping
//! is auto-ponged, close is auto-echoed, and a frame larger than payload_buf
//! answers close 1009. A partial trailing frame is left for the next read.
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
const reader = @import("../reader.zig");
const frame = @import("frame.zig");
const send = @import("send.zig");
const Opcode = @import("opcode.zig").Opcode;
const WsFrameFn = @import("frame_fn.zig").WsFrameFn;
const WsPumpResult = @import("WsPumpResult.zig");
const WsRingPumpResult = @import("WsRingPumpResult.zig");
const WsSendSink = @import("WsSendSink.zig");

// --------------------------------------------------------- //
// Private:

/// Close payload with status 1009 (message too big), big-endian.
const CLOSE_MESSAGE_TOO_BIG = [2]u8{ 0x03, 0xF1 };

/// Send a control frame. Best effort: a failed write marks the sink failed,
/// and the pump reads that as close.
fn sendControl(fd: std.posix.fd_t, opcode: Opcode, payload: []const u8) void {
    send.sendFD(fd, opcode, payload) catch |err| switch (err) {
        error.ZixHttp1_WebSocketSend_BrokenPipe,
        error.ZixHttp1_WebSocketSend_HeadBuild,
        => {},
    };
}

/// Parse and dispatch every complete frame in data, in order. The caller
/// installs the send sink.
fn runFrames(
    fd: std.posix.fd_t,
    data: []const u8,
    payload_buf: []u8,
    on_frame: WsFrameFn,
) WsPumpResult {
    var offset: usize = 0;

    while (offset < data.len) {
        const parsed = frame.parseFrame(data[offset..], payload_buf) catch |err| switch (err) {
            error.ZixHttp1_WebSocketFrame_PayloadTooLarge => {
                sendControl(fd, .close, &CLOSE_MESSAGE_TOO_BIG);

                return .{
                    .consumed = offset,
                    .close = true,
                };
            },
        };
        const result = parsed orelse break;

        offset += result.consumed;

        switch (result.frame.opcode) {
            .text, .binary => on_frame(
                fd,
                @intFromEnum(result.frame.opcode),
                result.frame.payload,
            ),
            .ping => sendControl(fd, .pong, result.frame.payload),
            .close => {
                sendControl(fd, .close, &.{});

                return .{
                    .consumed = offset,
                    .close = true,
                };
            },
            .pong, .continuation => {},
            _ => {},
        }
    }

    return .{
        .consumed = offset,
        .close = false,
    };
}

// --------------------------------------------------------- //
// Public:

/// Run one pass over data and write every reply in one write.
///
/// Param:
/// fd - std.posix.fd_t
/// data - []const u8 (raw bytes received so far)
/// payload_buf - []u8 (unmask buffer, sets the largest accepted payload)
/// out_buf - []u8 (staging for the coalesced write)
/// on_frame - WsFrameFn
///
/// Return:
/// - WsPumpResult
pub fn pump(
    fd: std.posix.fd_t,
    data: []const u8,
    payload_buf: []u8,
    out_buf: []u8,
    on_frame: WsFrameFn,
) WsPumpResult {
    var sink: WsSendSink = .{
        .fd = fd,
        .buf = out_buf,
    };
    send.tl_send_sink = &sink;
    defer send.tl_send_sink = null;

    const result = runFrames(fd, data, payload_buf, on_frame);
    sink.flush();

    return .{
        .consumed = result.consumed,
        .close = result.close or sink.failed,
    };
}

/// Like pump, but leaves the replies staged in out_buf for the .URING engine
/// to submit as one ring send.
///
/// Note:
/// - When the replies overflow out_buf mid-pass, the full batch is written to
///   fd directly. That is safe because the ring has no send in flight during a
///   pump pass. Only the trailing bytes come back as staged.
///
/// Param:
/// fd - std.posix.fd_t
/// data - []const u8 (raw bytes received so far)
/// payload_buf - []u8 (unmask buffer, sets the largest accepted payload)
/// out_buf - []u8 (staging for the ring send)
/// on_frame - WsFrameFn
///
/// Return:
/// - WsRingPumpResult
pub fn pumpRing(
    fd: std.posix.fd_t,
    data: []const u8,
    payload_buf: []u8,
    out_buf: []u8,
    on_frame: WsFrameFn,
) WsRingPumpResult {
    var sink: WsSendSink = .{
        .fd = fd,
        .buf = out_buf,
    };
    send.tl_send_sink = &sink;
    defer send.tl_send_sink = null;

    const result = runFrames(fd, data, payload_buf, on_frame);

    return .{
        .consumed = result.consumed,
        .close = result.close or sink.failed,
        .staged = sink.len,
    };
}

/// Drive a WebSocket on the calling thread until the peer leaves.
///
/// Note:
/// - Used by .ASYNC, which owns one connection per task. Reads block, so the
///   task parks between frames.
/// - A frame that cannot fit in recv_buf can never complete, so the
///   connection ends instead of waiting on bytes that never fit.
///
/// Param:
/// fd - std.posix.fd_t (the promoted connection)
/// on_frame - WsFrameFn
/// recv_buf - []u8 (holds raw frame bytes)
/// payload_buf - []u8 (unmask buffer, sets the largest accepted payload)
/// out_buf - []u8 (staging for the coalesced write)
///
/// Return:
/// - void once the peer hung up, sent close, or a write failed
pub fn serveBlocking(
    fd: std.posix.fd_t,
    on_frame: WsFrameFn,
    recv_buf: []u8,
    payload_buf: []u8,
    out_buf: []u8,
) void {
    var filled: usize = 0;

    while (filled < recv_buf.len) {
        const got = reader.readOnceFD(fd, recv_buf[filled..]) catch |err| switch (err) {
            error.ZixHttp1_Reader_Closed,
            error.ZixHttp1_Reader_HeaderTooLarge,
            error.ZixHttp1_Reader_ReadFailed,
            error.ZixHttp1_Reader_SetBufFailed,
            => return,
        };
        if (got == 0) return;

        filled += got;

        const result = pump(fd, recv_buf[0..filled], payload_buf, out_buf, on_frame);
        if (result.close) return;

        if (result.consumed > 0) {
            const rest = filled - result.consumed;

            std.mem.copyForwards(u8, recv_buf[0..rest], recv_buf[result.consumed..filled]);
            filled = rest;
        }
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../../utils/socket/pair.zig");

threadlocal var test_frames: usize = 0;
threadlocal var test_last: [64]u8 = undefined;
threadlocal var test_last_len: usize = 0;

fn testCount(_: std.posix.fd_t, _: u8, payload: []const u8) void {
    test_frames += 1;
    test_last_len = @min(payload.len, test_last.len);
    @memcpy(test_last[0..test_last_len], payload[0..test_last_len]);
}

fn testEcho(fd: std.posix.fd_t, opcode: u8, payload: []const u8) void {
    send.sendFD(fd, @enumFromInt(opcode), payload) catch |err| switch (err) {
        error.ZixHttp1_WebSocketSend_BrokenPipe,
        error.ZixHttp1_WebSocketSend_HeadBuild,
        => {},
    };
}

/// Build a masked client frame with a 7-bit length.
fn testMaskedFrame(out: []u8, opcode: Opcode, payload: []const u8) usize {
    const mask = [4]u8{ 0x12, 0x34, 0x56, 0x78 };

    out[0] = 0x80 | @intFromEnum(opcode);
    out[1] = 0x80 | @as(u8, @intCast(payload.len));
    @memcpy(out[2..6], &mask);
    for (payload, 0..) |byte, i| out[6 + i] = byte ^ mask[i % 4];

    return 6 + payload.len;
}

fn testReadExact(fd: std.posix.fd_t, out: []u8) !void {
    var got: usize = 0;
    while (got < out.len) {
        const n = try reader.readOnceFD(fd, out[got..]);
        if (n == 0) return error.TestReadClosed;
        got += n;
    }
}

fn testReset() void {
    test_frames = 0;
    test_last_len = 0;
}

test "zix http1 websocket: pump, dispatches a text frame" {
    testReset();

    var data: [32]u8 = undefined;
    const len = testMaskedFrame(&data, .text, "hey");
    var payload_buf: [32]u8 = undefined;
    var out_buf: [32]u8 = undefined;
    const result = pump(-1, data[0..len], &payload_buf, &out_buf, testCount);

    try std.testing.expectEqual(len, result.consumed);
    try std.testing.expect(!result.close);
    try std.testing.expectEqualStrings("hey", test_last[0..test_last_len]);
}

test "zix http1 websocket: pump, echoes in one coalesced write" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var data: [32]u8 = undefined;
    var len = testMaskedFrame(&data, .text, "ab");
    len += testMaskedFrame(data[len..], .text, "cd");
    var payload_buf: [32]u8 = undefined;
    var out_buf: [32]u8 = undefined;
    const result = pump(fds[0], data[0..len], &payload_buf, &out_buf, testEcho);

    var out: [8]u8 = undefined;
    try testReadExact(fds[1], &out);

    try std.testing.expectEqual(len, result.consumed);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x81, 2, 'a', 'b', 0x81, 2, 'c', 'd' },
        &out,
    );
}

test "zix http1 websocket: pump, answers ping with pong" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    testReset();

    var data: [32]u8 = undefined;
    const len = testMaskedFrame(&data, .ping, "p");
    var payload_buf: [32]u8 = undefined;
    var out_buf: [32]u8 = undefined;
    const result = pump(fds[0], data[0..len], &payload_buf, &out_buf, testCount);

    var out: [3]u8 = undefined;
    try testReadExact(fds[1], &out);

    try std.testing.expect(!result.close);
    try std.testing.expectEqual(@as(usize, 0), test_frames);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x8A, 1, 'p' }, &out);
}

test "zix http1 websocket: pump, echoes close and stops" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    testReset();

    var data: [32]u8 = undefined;
    var len = testMaskedFrame(&data, .close, "");
    const close_len = len;
    len += testMaskedFrame(data[len..], .text, "late");
    var payload_buf: [32]u8 = undefined;
    var out_buf: [32]u8 = undefined;
    const result = pump(fds[0], data[0..len], &payload_buf, &out_buf, testCount);

    var out: [2]u8 = undefined;
    try testReadExact(fds[1], &out);

    try std.testing.expect(result.close);
    try std.testing.expectEqual(close_len, result.consumed);
    try std.testing.expectEqual(@as(usize, 0), test_frames);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x88, 0 }, &out);
}

test "zix http1 websocket: pump, leaves a partial frame for the next read" {
    testReset();

    var data: [32]u8 = undefined;
    var len = testMaskedFrame(&data, .text, "one");
    const first_len = len;
    len += testMaskedFrame(data[len..], .text, "two");
    var payload_buf: [32]u8 = undefined;
    var out_buf: [32]u8 = undefined;
    const result = pump(-1, data[0 .. len - 1], &payload_buf, &out_buf, testCount);

    try std.testing.expectEqual(first_len, result.consumed);
    try std.testing.expectEqual(@as(usize, 1), test_frames);
    try std.testing.expect(!result.close);
}

test "zix http1 websocket: pump, answers 1009 to a frame too large" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    testReset();

    var data: [32]u8 = undefined;
    const len = testMaskedFrame(&data, .text, "toolong");
    var payload_buf: [4]u8 = undefined;
    var out_buf: [32]u8 = undefined;
    const result = pump(fds[0], data[0..len], &payload_buf, &out_buf, testCount);

    var out: [4]u8 = undefined;
    try testReadExact(fds[1], &out);

    try std.testing.expect(result.close);
    try std.testing.expectEqual(@as(usize, 0), result.consumed);
    try std.testing.expectEqual(@as(usize, 0), test_frames);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x88, 2, 0x03, 0xF1 }, &out);
}

test "zix http1 websocket: pump, ignores pong and continuation" {
    testReset();

    var data: [32]u8 = undefined;
    var len = testMaskedFrame(&data, .pong, "");
    len += testMaskedFrame(data[len..], .continuation, "x");
    var payload_buf: [32]u8 = undefined;
    var out_buf: [32]u8 = undefined;
    const result = pump(-1, data[0..len], &payload_buf, &out_buf, testCount);

    try std.testing.expectEqual(len, result.consumed);
    try std.testing.expectEqual(@as(usize, 0), test_frames);
}

test "zix http1 websocket: pump, closes on a failed write" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    _ = std.posix.system.close(fds[1]);

    var data: [32]u8 = undefined;
    const len = testMaskedFrame(&data, .text, "x");
    var payload_buf: [32]u8 = undefined;
    var out_buf: [32]u8 = undefined;
    const result = pump(fds[0], data[0..len], &payload_buf, &out_buf, testEcho);

    try std.testing.expect(result.close);
}

test "zix http1 websocket: pumpRing, stages replies without writing" {
    var data: [32]u8 = undefined;
    const len = testMaskedFrame(&data, .text, "ring");
    var payload_buf: [32]u8 = undefined;
    var out_buf: [32]u8 = undefined;
    const result = pumpRing(-1, data[0..len], &payload_buf, &out_buf, testEcho);

    try std.testing.expectEqual(len, result.consumed);
    try std.testing.expectEqual(@as(usize, 6), result.staged);
    try std.testing.expectEqualStrings("ring", out_buf[2..6]);
}

test "zix http1 websocket: pumpRing, stages close 1009 for a frame too large" {
    var data: [32]u8 = undefined;
    const len = testMaskedFrame(&data, .text, "toolong");
    var payload_buf: [2]u8 = undefined;
    var out_buf: [32]u8 = undefined;
    const result = pumpRing(-1, data[0..len], &payload_buf, &out_buf, testEcho);

    try std.testing.expect(result.close);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x88, 2, 0x03, 0xF1 },
        out_buf[0..result.staged],
    );
}

test "zix http1 websocket: serveBlocking, echoes until close" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var data: [32]u8 = undefined;
    var len = testMaskedFrame(&data, .text, "hi");
    len += testMaskedFrame(data[len..], .close, "");
    _ = std.posix.system.write(fds[1], &data, len);

    var recv_buf: [64]u8 = undefined;
    var payload_buf: [32]u8 = undefined;
    var out_buf: [32]u8 = undefined;
    serveBlocking(fds[0], testEcho, &recv_buf, &payload_buf, &out_buf);

    var out: [6]u8 = undefined;
    try testReadExact(fds[1], &out);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 2, 'h', 'i', 0x88, 0 }, &out);
}

test "zix http1 websocket: serveBlocking, returns when the peer hangs up" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    _ = std.posix.system.close(fds[1]);

    var recv_buf: [64]u8 = undefined;
    var payload_buf: [32]u8 = undefined;
    var out_buf: [32]u8 = undefined;

    serveBlocking(fds[0], testEcho, &recv_buf, &payload_buf, &out_buf);
}

test "zix http1 websocket: serveBlocking, stops when recv_buf is full" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var data: [32]u8 = undefined;
    const len = testMaskedFrame(&data, .text, "abcdefgh");
    _ = std.posix.system.write(fds[1], &data, len - 1);

    var recv_buf: [8]u8 = undefined;
    var payload_buf: [32]u8 = undefined;
    var out_buf: [32]u8 = undefined;

    serveBlocking(fds[0], testEcho, &recv_buf, &payload_buf, &out_buf);
}

